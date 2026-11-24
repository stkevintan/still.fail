// An account's database: its tables, and the migrations that bring a database to this version, in
// order, by `PRAGMA user_version`. A database a newer core wrote (its version past ours) is opened to be read only.
//
// Each table keeps the station's payload of a row as JSON (`json`), passed through as it is, so a field a station adds
// needs no migration; next to it, the columns the core finds, sorts and filters rows by, and the fields that change
// often on their own (a thread's read position), which are columns only and updated in place.
import type { Sql } from "../host.ts";

/// The version this core writes.
export const VERSION = 1;

/// Each migration takes a database from the version before it to its own (index + 1).
export const MIGRATIONS: string[] = [
  `
  CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

  -- The account's own: its /v1/me ('me'), its signed-in devices ('login_sessions'), an operator's lists ('admin/<list>').
  CREATE TABLE IF NOT EXISTS account_doc (name TEXT PRIMARY KEY, json TEXT NOT NULL, confirmed INTEGER);
  CREATE TABLE IF NOT EXISTS workspace (id TEXT PRIMARY KEY, json TEXT NOT NULL, confirmed INTEGER);

  -- A station's single answers: its overview, footprint, usage.
  CREATE TABLE IF NOT EXISTS station (
    address TEXT NOT NULL, kind TEXT NOT NULL, json TEXT NOT NULL, confirmed INTEGER,
    PRIMARY KEY (address, kind)
  );
  CREATE TABLE IF NOT EXISTS slack_app (station TEXT NOT NULL, connect TEXT NOT NULL, json TEXT NOT NULL, confirmed INTEGER, PRIMARY KEY (station, connect));

  -- Which of a station's lists have been read (an empty one is not one never read), when, and how often its rows changed.
  CREATE TABLE IF NOT EXISTS list (station TEXT NOT NULL, list TEXT NOT NULL, confirmed INTEGER, rev INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (station, list));

  -- The chats the viewer's sidebar lists (archived = 0) and the archived ones (1), as GET /chats gives them.
  -- (desk: what the 奏 page listed; no longer written, left so that an older core reading the database still can.)
  CREATE TABLE IF NOT EXISTS chat (
    station TEXT NOT NULL, id TEXT NOT NULL, archived INTEGER NOT NULL, ord REAL NOT NULL,
    thread INTEGER, session TEXT, client_key TEXT,
    last_active INTEGER NOT NULL DEFAULT 0, pinned_at INTEGER,
    unread INTEGER, mine INTEGER NOT NULL DEFAULT 0, running INTEGER NOT NULL DEFAULT 0,
    tone TEXT, asks INTEGER NOT NULL DEFAULT 0, desk INTEGER NOT NULL DEFAULT 0,
    json TEXT NOT NULL,
    PRIMARY KEY (station, archived, id)
  );
  CREATE INDEX IF NOT EXISTS chat_recent ON chat (archived, pinned_at DESC, last_active DESC);
  CREATE INDEX IF NOT EXISTS chat_ord ON chat (station, archived, ord);
  CREATE INDEX IF NOT EXISTS chat_thread ON chat (station, thread) WHERE thread IS NOT NULL;
  CREATE INDEX IF NOT EXISTS chat_session ON chat (station, session);
  CREATE INDEX IF NOT EXISTS chat_running ON chat (station) WHERE running = 1;
  CREATE INDEX IF NOT EXISTS chat_marked ON chat (station) WHERE archived = 0 AND (tone IS NOT NULL OR asks = 1);
  CREATE INDEX IF NOT EXISTS chat_desk ON chat (station) WHERE archived = 0 AND desk = 1;

  -- Agents: the summary (GET /sessions, session events), listed while not archived; the detail (GET /sessions/:key) but
  -- its threads, which are the thread rows it takes part in (thread_member).
  CREATE TABLE IF NOT EXISTS session (
    station TEXT NOT NULL, key TEXT NOT NULL, listed INTEGER NOT NULL DEFAULT 0, ord REAL NOT NULL DEFAULT 0,
    last_active INTEGER, process TEXT, connect TEXT, archived_at INTEGER, turns INTEGER,
    summary TEXT, detail TEXT,
    PRIMARY KEY (station, key)
  );
  CREATE INDEX IF NOT EXISTS session_listed ON session (station, listed, ord);

  -- Threads (GET /threads, a session's detail, thread events); last, read and unread are columns only.
  CREATE TABLE IF NOT EXISTS thread (
    station TEXT NOT NULL, id INTEGER NOT NULL, listed INTEGER NOT NULL DEFAULT 0,
    last INTEGER, read INTEGER, unread INTEGER,
    sort_at INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL DEFAULT 0,
    surface TEXT, first_member TEXT,
    json TEXT NOT NULL,
    PRIMARY KEY (station, id)
  );
  CREATE INDEX IF NOT EXISTS thread_listed ON thread (station, listed, sort_at DESC, created_at DESC, id DESC);
  CREATE INDEX IF NOT EXISTS thread_first ON thread (station, first_member);
  CREATE TABLE IF NOT EXISTS thread_member (station TEXT NOT NULL, session TEXT NOT NULL, thread INTEGER NOT NULL, PRIMARY KEY (station, session, thread));
  CREATE INDEX IF NOT EXISTS thread_member_thread ON thread_member (station, thread);

  -- A thread's messages and a session's transcript, item by item.
  CREATE TABLE IF NOT EXISTS entry (station TEXT NOT NULL, thread INTEGER NOT NULL, n INTEGER NOT NULL, json TEXT NOT NULL, PRIMARY KEY (station, thread, n)) WITHOUT ROWID;
  CREATE TABLE IF NOT EXISTS transcript (station TEXT NOT NULL, session TEXT NOT NULL, i INTEGER NOT NULL, json TEXT NOT NULL, PRIMARY KEY (station, session, i)) WITHOUT ROWID;

  -- Jobs: as each is now (job events, a session's detail), open = among the station's open ones (GET /jobs, with chat).
  CREATE TABLE IF NOT EXISTS job (
    station TEXT NOT NULL, id TEXT NOT NULL, session TEXT, open INTEGER NOT NULL DEFAULT 0, ord REAL NOT NULL DEFAULT 0,
    chat TEXT, json TEXT NOT NULL,
    PRIMARY KEY (station, id)
  );
  CREATE INDEX IF NOT EXISTS job_open ON job (station, open, ord);

  -- What this device did and its station has not confirmed yet (views/local.ts), and what is being written here.
  CREATE TABLE IF NOT EXISTS outbox (station TEXT NOT NULL, thread INTEGER NOT NULL, json TEXT NOT NULL, PRIMARY KEY (station, thread));
  CREATE TABLE IF NOT EXISTS pending (key TEXT PRIMARY KEY, station TEXT NOT NULL, json TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS first (station TEXT NOT NULL, session TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY (station, session));
  CREATE TABLE IF NOT EXISTS changing (station TEXT NOT NULL, id INTEGER NOT NULL, json TEXT NOT NULL, PRIMARY KEY (station, id));
  CREATE TABLE IF NOT EXISTS draft (station TEXT NOT NULL, chat TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY (station, chat));

  -- What this device keeps of a workspace: a new chat's picks (choose.ts), chats' links (refs.ts).
  CREATE TABLE IF NOT EXISTS workspace_pref (workspace TEXT NOT NULL, key TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY (workspace, key));
  `,
];

// An entry's part in what was said (`e` the entry row): whether it says something (a message, or an edit of one), the
// message it is of, when that was said (a message's own time), and its words.
const kind = (e: string) => `json_extract(${e}.json, '$.kind')`;
const SAYS = (e: string) => `(${kind(e)} = 'message' OR (${kind(e)} = 'edit' AND json_type(${e}.json, '$.target') = 'integer'))`;
const SEQ = (e: string) => `(CASE ${kind(e)} WHEN 'message' THEN ${e}.n ELSE json_extract(${e}.json, '$.target') END)`;
const AT = (e: string) => `(CASE ${kind(e)} WHEN 'message' THEN json_extract(${e}.json, '$.at') END)`;
const TEXT = (e: string) => `coalesce(CASE json_type(${e}.json, '$.text') WHEN 'text' THEN json_extract(${e}.json, '$.text') END, '')`;
// The latest words win, whichever came first (a thread's older pages are read after its newer ones).
const UPSERT = `ON CONFLICT (station, thread, seq) DO UPDATE SET
  text = CASE WHEN excluded.n >= said.n THEN excluded.text ELSE said.text END,
  n = max(said.n, excluded.n),
  at = coalesce(excluded.at, said.at)`;

/// What was said in the threads, for finding messages by their words (`said`): each message's latest text (an edit's
/// replaces it), kept by triggers on `entry`, so whatever writes entries keeps it, a core that knows nothing of it too.
/// Searched by scanning it (a few MB of words: no index, as a workspace's search builds none). Not a migration (a
/// version bump would leave an older core the database only to read): made where missing at every open, filled once
/// from the entries held.
export function ensureSaid(sql: Sql): void {
  const had = sql.all("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'said'").length > 0;
  sql.exec("BEGIN IMMEDIATE");
  try {
    sql.exec(`
      CREATE TABLE IF NOT EXISTS said (
        id INTEGER PRIMARY KEY, station TEXT NOT NULL, thread INTEGER NOT NULL, seq INTEGER NOT NULL,
        n INTEGER NOT NULL, at INTEGER, text TEXT NOT NULL,
        UNIQUE (station, thread, seq)
      );
      -- A message's edits, by the message (for when the entry its words came from goes).
      CREATE INDEX IF NOT EXISTS entry_edit ON entry (station, thread, json_extract(json, '$.target')) WHERE json_extract(json, '$.kind') = 'edit';
      -- What people said in a chat, by number (account.ts peopleEntries: a chat's outline reads those alone, not its
      -- agents' replies).
      CREATE INDEX IF NOT EXISTS entry_person ON entry (station, thread, n) WHERE json_extract(json, '$.kind') = 'message' AND json_extract(json, '$.authorKind') = 'person';
      CREATE TRIGGER IF NOT EXISTS said_put AFTER INSERT ON entry WHEN ${SAYS("new")}
      BEGIN
        INSERT INTO said (station, thread, seq, n, at, text) VALUES (new.station, new.thread, ${SEQ("new")}, new.n, ${AT("new")}, ${TEXT("new")})
        ${UPSERT};
      END;
      -- The entry a message's words came from gone: its words are those of what is left of it (nothing, when it went).
      CREATE TRIGGER IF NOT EXISTS said_drop AFTER DELETE ON entry WHEN ${SAYS("old")}
      BEGIN
        DELETE FROM said WHERE station = old.station AND thread = old.thread AND seq = ${SEQ("old")} AND n = old.n;
        INSERT INTO said (station, thread, seq, n, at, text)
        SELECT * FROM (
          SELECT e.station, e.thread, e.n AS seq, e.n, ${AT("e")}, ${TEXT("e")} FROM entry e
          WHERE e.station = old.station AND e.thread = old.thread AND e.n = ${SEQ("old")} AND ${kind("e")} = 'message'
          UNION ALL
          SELECT e.station, e.thread, json_extract(e.json, '$.target'), e.n, NULL, ${TEXT("e")} FROM entry e
          WHERE e.station = old.station AND e.thread = old.thread AND json_extract(e.json, '$.target') = ${SEQ("old")} AND json_extract(e.json, '$.kind') = 'edit'
        )
        WHERE NOT EXISTS (SELECT 1 FROM said WHERE station = old.station AND thread = old.thread AND seq = ${SEQ("old")})
        ORDER BY 4
        ${UPSERT};
      END;
    `);
    if (!had) {
      // Oldest first, as they came.
      sql.exec(`
        INSERT INTO said (station, thread, seq, n, at, text)
        SELECT e.station, e.thread, ${SEQ("e")}, e.n, ${AT("e")}, ${TEXT("e")} FROM entry e
        WHERE ${SAYS("e")}
        ORDER BY e.station, e.thread, e.n
        ${UPSERT};
      `);
    }
    sql.exec("COMMIT");
  } catch (e) {
    try {
      sql.exec("ROLLBACK");
    } catch {
      // Rolled back already.
    }
    throw e;
  }
  dropSaidIndex(sql);
}

/// What the chat list reads of a station's overview, the JSON `j` (views.ts #chats), as SQL: who the viewer is in Slack
/// (`slackUsers`, its strings), each connect's id, kind, connection state and Slack workspace and Feishu domain (a row's
/// signature, its menu's links there; one not an object as it is), and how many agents its station runs (`running`, its
/// state's line and the glyph's count). A field not there is null. Made by SQLite itself, so that the triggers below
/// keep it whoever writes the overview; `ORDER BY` keeps each list in its order; json() takes a subquery's answer as
/// JSON again (a scalar subquery loses that it is, and would be put in as a string). `j` is qualified by its table:
/// json_each has a hidden column `json` of its own.
export const overviewPartOf = (j: string) => `json_object(
  'running', ${j} -> '$.counts.running',
  'interrupted', ${j} -> '$.interrupted',
  'slackUsers', CASE WHEN json_type(${j}, '$.slackUsers') = 'array'
    THEN json((SELECT json_group_array(u.value ORDER BY u.key) FROM json_each(${j}, '$.slackUsers') AS u WHERE u.type = 'text'))
    ELSE json_array() END,
  'connects', CASE WHEN json_type(${j}, '$.connects') = 'array'
    THEN json((SELECT json_group_array(CASE c.type WHEN 'object' THEN json_object(
        'id', c.value -> '$.id',
        'kind', c.value -> '$.kind',
        'connection', CASE json_type(c.value, '$.connection') WHEN 'object'
          THEN json_object('state', c.value -> '$.connection.state', 'workspace', c.value -> '$.connection.workspace')
          ELSE c.value -> '$.connection' END,
        'feishu', CASE json_type(c.value, '$.feishu') WHEN 'object'
          THEN json_object('domain', c.value -> '$.feishu.domain')
          ELSE c.value -> '$.feishu' END)
      ELSE ${j} -> c.fullkey END ORDER BY c.key) FROM json_each(${j}, '$.connects') AS c))
    ELSE json_array() END)`;

/// What a station's row reads of its overview, the JSON `j` (views.ts rowOf, OverviewRow), as SQL: its `viewer` and
/// `counts`, its `disk` and `drive` where they are not null, each as the overview has it, one absent left out; NULL
/// where the overview is not an object. Kept apart from the chat list's part (`station_part.row`), which the list reads
/// and parses for every station of a workspace as it is first shown: the row's fields in it made that 1.4-1.7 KB a
/// station for 0.8-1.1 KB (the real-size workspace), and the list's first answer later by as much.
export const overviewRowOf = (j: string) => `CASE WHEN json_type(${j}) = 'object'
    THEN json((SELECT json_group_object(o.key, ${j} -> o.fullkey) FROM json_each(${j}) AS o
      WHERE o.key IN ('viewer', 'counts') OR (o.key IN ('disk', 'drive', 'autoChats') AND o.type <> 'null')))
    END`;

/// What a chat's page reads of its station's overview, the JSON `j` (views.ts #chatOverview: its agents' connects,
/// `#peopleOf`, `#shown`, `#whereIn`, `#sentElsewhere`, its station's update and context, the `beta` features it runs:
/// `canTerminal`), as SQL: its `connects`, `disk`, `slackUsers`, `updates`, `feedback`, `context` and `features`, each
/// as the overview has it, one absent left out; NULL
/// where the overview is not an object. Kept apart from the list's part and the row's (`station_part.chat`): a chat's
/// first answer read the whole overview of its station (25-27 KB of the real-size workspace's). Its agents' accounts
/// are not in it: each agent's own profile is read alone (overviewProfilesOf).
export const overviewChatOf = (j: string) => `CASE WHEN json_type(${j}) = 'object'
    THEN json((SELECT json_group_object(o.key, ${j} -> o.fullkey) FROM json_each(${j}) AS o
      WHERE o.key IN ('connects', 'disk', 'slackUsers', 'updates', 'feedback', 'context', 'features', 'move')))
    END`;

/// The fields of an overview a chat's page reads (overviewChatOf), for where it is made of an overview in the core (one
/// shown with what is being done to it here: data.ts overviewChat).
export const OVERVIEW_CHAT = ["connects", "disk", "slackUsers", "updates", "feedback", "context", "features", "move"] as const;

/// An overview's profiles (the JSON `j`), each whole, by its id, as SQL: what a chat's agent reads of the one it runs
/// on, read by its key (account.ts overviewProfile: `profiles -> '$."<id>"'`, SQLite taking that one of them), never
/// the station's every profile (13 KB of the 17 of a chat's part, #5634, for its one or two agents); `{}` where it has
/// none. A profile with no id is no agent's.
export const overviewProfilesOf = (j: string) => `CASE WHEN json_type(${j}, '$.profiles') = 'array'
    THEN json((SELECT json_group_object(p.value ->> '$.id', p.value) FROM json_each(${j}, '$.profiles') AS p
      WHERE p.type = 'object' AND json_type(p.value, '$.id') = 'text'))
    ELSE json_object() END`;

/// The stations a station took the place of, as its overview says (`copies.formerly`, its strings), the JSON `j`, as
/// SQL: what a link to a chat of one of them is taken to (views.ts `stationNow`), read of every station of a
/// workspace as a chat with links in it is made; `[]` where it says none. Kept in a column of its own
/// (`station_part.formerly`): read of the chat's part, it was 17 KB parsed a station for these few bytes.
export const overviewFormerlyOf = (j: string) => `CASE WHEN json_type(${j}, '$.copies.formerly') = 'array'
    THEN json((SELECT json_group_array(f.value ORDER BY f.key) FROM json_each(${j}, '$.copies.formerly') AS f WHERE f.type = 'text'))
    ELSE json_array() END`;

/// What the workspace's profiles read of a station's overview, the JSON `j` (views.ts `#profilesView`: profiles.ts
/// `workspaceProfiles`, and the machines' own logins offered beside them), as SQL: its `profiles` in their order, its
/// `sharing` (and whether a share can follow the workspace's whitelist, `shareAllowAuto`, and whether it is on that whitelist,
/// `autoChats`), its `mesh` (whether still.fail cloud reached it) and its `machineLogins`, each as the overview has it, one
/// absent left out; NULL where the overview is not an object. Kept in a column of its own (`station_part.profiled`):
/// the list read every station's whole overview and decorated a copy of it for these (15 of the 32 ms the core spent
/// after a workspace was switched to on 小屏, in Hermes on a Mac Studio, 2026-11-12).
export const overviewProfiledOf = (j: string) => `CASE WHEN json_type(${j}) = 'object'
    THEN json((SELECT json_group_object(o.key, ${j} -> o.fullkey) FROM json_each(${j}) AS o
      WHERE o.key IN ('profiles', 'sharing', 'shareAllowAuto', 'autoChats', 'mesh', 'machineLogins')))
    END`;

/// The station's own software of an overview, the JSON `j` (its `updates`' entry of id `station`), as SQL: what the
/// workspace's offer of its stations' newer releases reads (views/station-updates.ts): what runs and what is out (of
/// which channel), whether it updates itself, can be updated from here and how its update goes, each as the overview has it (null where
/// it says none); NULL where it lists no such entry. Kept in a column of its own (`station_part.software`): read of
/// the overview, every station's whole for a few fields, as the sidebar's offer stands on every screen.
export const overviewSoftwareOf = (j: string) => `(SELECT json_object('version', u.value -> '$.version', 'latest', u.value -> '$.latest',
      'newer', u.value -> '$.newer', 'channel', u.value -> '$.channel', 'auto', u.value -> '$.auto', 'updatable', u.value -> '$.updatable', 'state', u.value -> '$.state',
      'percent', u.value -> '$.percent', 'progress', u.value -> '$.progress', 'message', u.value -> '$.message', 'builtAt', ${j} -> '$.builtAt')
    FROM json_each(CASE json_type(${j}, '$.updates') WHEN 'array' THEN ${j} ELSE '{"updates":[]}' END, '$.updates') AS u
    WHERE u.type = 'object' AND json_type(u.value, '$.id') = 'text' AND json_extract(u.value, '$.id') = 'station' LIMIT 1)`;

/// The fields of an overview the workspace's profiles read (overviewProfiledOf), for where they are made of an overview
/// in the core (one shown with what is being done to it here: data.ts overviewProfiled).
export const OVERVIEW_PROFILED = ["profiles", "sharing", "shareAllowAuto", "autoChats", "mesh", "machineLogins"] as const;

/// What the connects' list and a connect's page read of a station's overview, the JSON `j` (views.ts connectsPartOf,
/// #connectOf), as SQL: its `connects` and `slackApps` (each `[]` where not a list), whether it has a profile
/// (`profiled`: true where the overview is not an object, as nothing can be said of it) and whether its connects may
/// change runtime (`connectRuntimeChange`). Kept in a column of its own (`station_part.connects`): the settings page
/// read every station's whole overview for these, some 150 KB of a phone's each, as it first opened.
export const overviewConnectsOf = (j: string) => `CASE WHEN json_type(${j}) = 'object'
    THEN json_object(
      'connects', json(CASE json_type(${j}, '$.connects') WHEN 'array' THEN ${j} -> '$.connects' ELSE '[]' END),
      'slackApps', json(CASE json_type(${j}, '$.slackApps') WHEN 'array' THEN ${j} -> '$.slackApps' ELSE '[]' END),
      'profiled', json(CASE WHEN json_type(${j}, '$.profiles') = 'array' AND json_array_length(${j}, '$.profiles') > 0 THEN 'true' ELSE 'false' END),
      'connectRuntimeChange', json(CASE json_type(${j}, '$.connectRuntimeChange') WHEN 'true' THEN 'true' ELSE 'false' END))
    ELSE json_object('connects', json('[]'), 'slackApps', json('[]'), 'profiled', json('true'), 'connectRuntimeChange', json('false')) END`;

/// What the settings' automatic decisions and archiving read of a station's overview, the JSON `j` (views.ts
/// `settings`, `stationPart` of these two; present.ts overview decorates them of themselves alone), as SQL: its
/// `automaticDecisions` and `archiving`, each as the overview has it, one absent left out; NULL where the overview is
/// not an object. Kept in a column of its own (`station_part.settings`): those pages read and decorated every
/// station's whole overview for them.
export const overviewSettingsOf = (j: string) => `CASE WHEN json_type(${j}) = 'object'
    THEN json((SELECT json_group_object(o.key, ${j} -> o.fullkey) FROM json_each(${j}) AS o
      WHERE o.key IN ('automaticDecisions', 'archiving')))
    END`;

/// The fields of an overview the settings read (overviewSettingsOf), for where they are made of an overview in the
/// core (one shown with what is being done to it here: data.ts overviewSettings).
export const OVERVIEW_SETTINGS = ["automaticDecisions", "archiving"] as const;

/// Small, frequently changing columns of an overview's part kept in `station_part`.
export const HOT_PART_COLUMNS: [string, (j: string) => string][] = [
  ["part", overviewPartOf],
  ["row", overviewRowOf],
  ["chat", overviewChatOf],
  ["formerly", overviewFormerlyOf],
  ["software", overviewSoftwareOf],
  ["connects", overviewConnectsOf],
  ["settings", overviewSettingsOf],
];
/// Large, cold profile columns kept apart in `station_part_profiles` so high-frequency `part`/`row`/`chat` updates
/// never rewrite 100–200 KB of unchanged profile overflow pages.
export const PROFILE_PART_COLUMNS: [string, (j: string) => string][] = [
  ["profiles", overviewProfilesOf],
  ["profiled", overviewProfiledOf],
];
/// Each column of an overview's part (`station_part` and `station_part_profiles`) and how SQLite makes it of the overview's JSON.
export const PART_COLUMNS: [string, (j: string) => string][] = [["part", overviewPartOf], ["row", overviewRowOf], ["chat", overviewChatOf], ["formerly", overviewFormerlyOf], ["profiles", overviewProfilesOf], ["profiled", overviewProfiledOf], ["software", overviewSoftwareOf], ["connects", overviewConnectsOf], ["settings", overviewSettingsOf]];
export const PROFILE_PART_SET = new Set(PROFILE_PART_COLUMNS.map(([c]) => c));
export const partTableOf = (column: string): "station_part" | "station_part_profiles" => (PROFILE_PART_SET.has(column) ? "station_part_profiles" : "station_part");
/// The revision of a column of the part (`<column>_rev`), beside it: raised by the triggers as its text changes, so that
/// a write is told what of the part changed by a few numbers, the texts not read (account.ts #overviewWritten). NULL
/// where no trigger of this core counted it (a row a core that knows nothing of them put in).
export const partRev = (column: string) => `${column}_rev`;
/// What makes each column of one part table (`station_part` or `station_part_profiles`) of the overview `j` (`address`
/// its station, `from` what the overview is read of; `key` the station as the second statement says it): the row kept
/// in place where there is one, each column's revision raised where its text is another; one put in now counted from 0.
const partPutTable = (table: string, cols: [string, (j: string) => string][], j: string, address: string, from: string, key: string): [string, string] => [
  `INSERT INTO ${table} (address, ${cols.map(([c]) => c).join(", ")}) SELECT ${address}, ${cols.map(([, of]) => of(j)).join(", ")} ${from}
        ON CONFLICT (address) DO UPDATE SET ${cols.map(([c]) => `${c} = excluded.${c}, ${partRev(c)} = coalesce(${table}.${partRev(c)}, 0) + (${table}.${c} IS NOT excluded.${c})`).join(", ")}
        WHERE ${cols.map(([c]) => `${table}.${c} IS NOT excluded.${c}`).join(" OR ")}`,
  `UPDATE ${table} SET ${cols.map(([c]) => `${partRev(c)} = 0`).join(", ")} WHERE address = ${key} AND ${partRev(cols[0][0])} IS NULL`,
];
const triggerPutTable = (table: string, cols: [string, (j: string) => string][]) =>
  partPutTable(table, cols, "new.json", "new.address", "WHERE json_valid(new.json)", "new.address").map((s) => `${s};`).join("\n        ");

/// Guard for `station_part_profiles_set`: skip parsing/updating profile columns entirely when none of the fields
/// `overviewProfilesOf` / `overviewProfiledOf` read changed.
/// (each field of OVERVIEW_PROFILED, which holds `profiles` too: one added there is watched here, else the part would
/// keep what it was, a station's whitelist turned on never reaching the profiles)
const PROFILE_FIELDS_CHANGED =
  "(NOT json_valid(old.json) OR NOT json_valid(new.json) OR json_type(old.json) IS NOT 'object' OR json_type(new.json) IS NOT 'object'" +
  OVERVIEW_PROFILED.map((k) => ` OR (old.json -> '$.${k}') IS NOT (new.json -> '$.${k}')`).join("") + ")";

/// The triggers keeping each overview's hot (`station_part`) and cold profile (`station_part_profiles`) parts as it
/// changes or goes, whoever writes it, by name, as sqlite_master keeps them (no `IF NOT EXISTS`: SQLite keeps the
/// statement without it). An overview that is not JSON has none.
const overviewTriggers = (): [string, string][] => [
  ["station_part_put", `CREATE TRIGGER station_part_put AFTER INSERT ON station WHEN new.kind = 'overview'
      BEGIN
        DELETE FROM station_part WHERE address = new.address AND NOT json_valid(new.json);
        DELETE FROM station_part_profiles WHERE address = new.address AND NOT json_valid(new.json);
        ${triggerPutTable("station_part", HOT_PART_COLUMNS)}
        ${triggerPutTable("station_part_profiles", PROFILE_PART_COLUMNS)}
      END`],
  ["station_part_set", `CREATE TRIGGER station_part_set AFTER UPDATE OF json ON station WHEN new.kind = 'overview' AND old.json IS NOT new.json
      BEGIN
        DELETE FROM station_part WHERE address = new.address AND NOT json_valid(new.json);
        DELETE FROM station_part_profiles WHERE address = new.address AND NOT json_valid(new.json);
        ${triggerPutTable("station_part", HOT_PART_COLUMNS)}
      END`],
  ["station_part_profiles_set", `CREATE TRIGGER station_part_profiles_set AFTER UPDATE OF json ON station WHEN new.kind = 'overview' AND old.json IS NOT new.json AND ${PROFILE_FIELDS_CHANGED}
      BEGIN
        DELETE FROM station_part_profiles WHERE address = new.address AND NOT json_valid(new.json);
        ${triggerPutTable("station_part_profiles", PROFILE_PART_COLUMNS)}
      END`],
  ["station_part_drop", `CREATE TRIGGER station_part_drop AFTER DELETE ON station WHEN old.kind = 'overview'
      BEGIN
        DELETE FROM station_part WHERE address = old.address;
      END`],
  // (a name of its own: a core from before the profiles' table makes `station_part_drop` again as its own, and this
  // one stays, so an overview it deletes leaves no profiles behind)
  ["station_part_profiles_drop", `CREATE TRIGGER station_part_profiles_drop AFTER DELETE ON station WHEN old.kind = 'overview'
      BEGIN
        DELETE FROM station_part_profiles WHERE address = old.address;
      END`],
];

/// A statement as compared with sqlite_master's: its spaces and line breaks one space.
const spaced = (s: string) => s.replace(/\s+/g, " ").trim();

/// Each station's overview's part the chat list reads (overviewPartOf), what a station's row reads (overviewRowOf, its
/// own column), what a chat's page reads (overviewChatOf), the stations it took the place of (overviewFormerlyOf), its
/// profiles by id (overviewProfilesOf) and what the workspace's profiles read of it (overviewProfiledOf), kept beside
/// it in `station_part` (small, frequent columns) and `station_part_profiles` (large, cold profile columns): they
/// read a few hundred bytes, or a chat's page some of the overview, not an overview of some 150 KB (nor walk its pages
/// to a column after it, nor rewrite 100–200 KB of unchanged profiles on every hot-column tick). Kept by triggers on
/// `station`, as `said` is, so a core that knows nothing of it (a web page still open from before, an app put back to
/// an older one) keeps it too: nothing it holds is older than its overview.
/// Each row is kept in place as the overview is written, each column beside its revision (partRev), raised where its
/// text is another, so a write is told what changed without a text read; an older core's triggers put the row in anew,
/// its revisions none, and what reads them takes that as anything changed.
/// (What is made of an overview and kept beside it, whether this core can read it, is db/kept.ts's.) Made where missing
/// at every open, as `said`; a trigger whose statement is not this core's (an earlier core's, without a column of
/// these) made again, the columns added where they are not there, and every part made again with them; overviews
/// from before get theirs at once, SQLite reading them itself (no overview crosses to the core). An older core opening
/// the database after keeps these triggers (one before the row's: it makes its own only where they are missing), or
/// makes its own again in place of them (one since: these are not its statements), every part with them, the columns
/// it does not know left empty: what is read of one is then made of the overview by SQLite as it is read (account.ts
/// #columnText), till this core opens it again. Either reads of a part the fields it knows (its `part`, as it was).
export function ensureOverviewParts(sql: Sql): void {
  sql.exec("BEGIN IMMEDIATE");
  try {
    sql.exec(`
      CREATE TABLE IF NOT EXISTS station_part (address TEXT PRIMARY KEY, part TEXT NOT NULL, row TEXT, chat TEXT, formerly TEXT, profiles TEXT);
      CREATE TABLE IF NOT EXISTS station_part_profiles (address TEXT PRIMARY KEY, profiles TEXT, profiles_rev INTEGER, profiled TEXT, profiled_rev INTEGER);
    `);
    const had = new Map(sql.all("SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'station'").map((r) => [String(r[0]), String(r[1])]));
    let remade = false;
    // (a table an earlier core made: the columns it has not added, every part made again with them)
    const columns = sql.all("PRAGMA table_info(station_part)").map((r) => r[1]);
    for (const [column, type] of HOT_PART_COLUMNS.flatMap(([c]) => [[c, "TEXT"], [partRev(c), "INTEGER"]])) {
      if (columns.includes(column)) continue;
      sql.exec(`ALTER TABLE station_part ADD COLUMN ${column} ${type}`);
      remade = true;
    }
    const profileCols = sql.all("PRAGMA table_info(station_part_profiles)").map((r) => r[1]);
    for (const [column, type] of PROFILE_PART_COLUMNS.flatMap(([c]) => [[c, "TEXT"], [partRev(c), "INTEGER"]])) {
      if (profileCols.includes(column)) continue;
      sql.exec(`ALTER TABLE station_part_profiles ADD COLUMN ${column} ${type}`);
      remade = true;
    }
    for (const [name, statement] of overviewTriggers()) {
      const was = had.get(name);
      if (was !== undefined && spaced(was) === spaced(statement)) continue;
      if (was !== undefined) {
        sql.exec(`DROP TRIGGER ${name}`);
        remade = true;
      }
      sql.exec(statement);
    }
    // (an earlier core's parts: all made again, of the overviews, by SQLite, also shedding legacy profiles blobs from station_part)
    if (remade) {
      sql.exec("DELETE FROM station_part");
      sql.exec("DELETE FROM station_part_profiles");
    }
    // (asked first by the rows' keys alone: an overview is read only where its part is missing)
    const missingHot = sql.all("SELECT s.address FROM station s WHERE s.kind = 'overview' AND NOT EXISTS (SELECT 1 FROM station_part p WHERE p.address = s.address)");
    const [putHot, countedHot] = partPutTable("station_part", HOT_PART_COLUMNS, "st.json", "st.address", "FROM station AS st WHERE st.address = ? AND st.kind = 'overview' AND json_valid(st.json)", "?");
    for (const [address] of missingHot) {
      sql.run(putHot, [address]);
      sql.run(countedHot, [address]);
    }
    const missingProfiles = sql.all("SELECT s.address FROM station s WHERE s.kind = 'overview' AND NOT EXISTS (SELECT 1 FROM station_part_profiles p WHERE p.address = s.address)");
    const [putProfiles, countedProfiles] = partPutTable("station_part_profiles", PROFILE_PART_COLUMNS, "st.json", "st.address", "FROM station AS st WHERE st.address = ? AND st.kind = 'overview' AND json_valid(st.json)", "?");
    for (const [address] of missingProfiles) {
      sql.run(putProfiles, [address]);
      sql.run(countedProfiles, [address]);
    }
    sql.exec("COMMIT");
  } catch (e) {
    try {
      sql.exec("ROLLBACK");
    } catch {
      // Rolled back already.
    }
    throw e;
  }
}

/// How this core derives a chat record's columns beyond those every core writes (CHAT_COLUMNS, `state`): another number
/// whenever one of them would come out otherwise of the same record, so that rows derived before are derived again.
/// `CHAT_MADE_ALT` is an equivalent marker that `PUT_CHAT`'s `ON CONFLICT DO UPDATE` alternates with `CHAT_MADE` so
/// `chat_made_set` (`WHEN old.made IS new.made`) skips this core's own upserts while still catching in-place JSON
/// updates from older cores that leave `made` untouched.
export const CHAT_MADE = 2;
export const CHAT_MADE_ALT = -2;

/// The columns of a chat's record that SQLite makes of its JSON (`j`, an expression of it), as the record is put and as a
/// row another core put is derived again: whether it is hidden; whether an agent leads it (chat_create for itself: its
/// `opener.led`, shown in no list but from its opener's info); its title; whether it is marked archived, and when
/// (archive.ts: the mark's `at`, else its last activity; null where that is not a number). What reads by them reads what
/// the JS reading the record would (views.ts, archive.ts, fleet.ts): list-rows.test.ts holds each to it. What only the
/// core says of a record (`state`, `watched`: what its agents do, whether one keeps watch) is the core's (Derive).
export const CHAT_COLUMNS: [name: string, of: (j: string) => string][] = [
  ["hidden", (j) => `(json_type(${j}, '$.hidden') IS 'true')`],
  ["led", (j) => `(json_type(${j}, '$.opener.led') IS 'true')`],
  ["title", (j) => `(CASE json_type(${j}, '$.title') WHEN 'text' THEN json_extract(${j}, '$.title') END)`],
  ["archived_mark", (j) => `(json_type(${j}, '$.archived') IS 'object')`],
  ["archived_at", (j) => `(CASE WHEN json_type(${j}, '$.archived') IS NOT 'object' THEN NULL
    WHEN coalesce(json_type(${j}, '$.archived.at'), 'null') = 'null' THEN (CASE WHEN json_type(${j}, '$.lastActiveAt') IN ('integer', 'real') THEN json_extract(${j}, '$.lastActiveAt') END)
    WHEN json_type(${j}, '$.archived.at') IN ('integer', 'real') THEN json_extract(${j}, '$.archived.at') END)`],
];

/// The chats each agent's session is among the agents of (its row's `agents[].key`), listed or archived: what finds the
/// chat a session takes part in without reading the station's rows (screens.ts chatOf, views.ts #ranFrom, fleet.ts).
/// Kept by triggers on `chat`, as `chat_row` is, so whoever writes a record (an older core too) keeps it.
const chatAgentKeysOf = (row: "new" | "old") => `SELECT json_extract(a.value, '$.key')
        FROM json_each(CASE json_type(${row}.json, '$.agents') WHEN 'array' THEN ${row}.json ELSE '{"agents":[]}' END, '$.agents') AS a
        WHERE json_type(CASE a.type WHEN 'object' THEN a.value ELSE '{}' END, '$.key') = 'text'`;
const chatAgentsOf = (row: "new" | "old") => `INSERT INTO chat_agent (station, session, archived, id)
        SELECT DISTINCT ${row}.station, json_extract(a.value, '$.key'), ${row}.archived, ${row}.id
        FROM json_each(CASE json_type(${row}.json, '$.agents') WHEN 'array' THEN ${row}.json ELSE '{"agents":[]}' END, '$.agents') AS a
        WHERE json_type(CASE a.type WHEN 'object' THEN a.value ELSE '{}' END, '$.key') = 'text'
          AND NOT EXISTS (SELECT 1 FROM chat_agent WHERE station = ${row}.station AND session = json_extract(a.value, '$.key') AND archived = ${row}.archived AND id = ${row}.id);`;
const chatTriggers = (): [string, string][] => [
  ["chat_agent_put", `CREATE TRIGGER chat_agent_put AFTER INSERT ON chat
      BEGIN
        DELETE FROM chat_agent WHERE station = new.station AND archived = new.archived AND id = new.id AND session NOT IN (${chatAgentKeysOf("new")});
        ${chatAgentsOf("new")}
      END`],
  ["chat_agent_set", `CREATE TRIGGER chat_agent_set AFTER UPDATE OF station, archived, id, json ON chat
      WHEN old.station IS NOT new.station OR old.archived IS NOT new.archived OR old.id IS NOT new.id OR (old.json -> '$.agents') IS NOT (new.json -> '$.agents')
      BEGIN
        DELETE FROM chat_agent WHERE station = old.station AND archived = old.archived AND id = old.id
          AND (old.station IS NOT new.station OR old.archived IS NOT new.archived OR old.id IS NOT new.id OR session NOT IN (${chatAgentKeysOf("new")}));
        ${chatAgentsOf("new")}
      END`],
  ["chat_agent_drop", `CREATE TRIGGER chat_agent_drop AFTER DELETE ON chat
      BEGIN
        DELETE FROM chat_agent WHERE station = old.station AND archived = old.archived AND id = old.id;
      END`],
  // (a record's JSON changed in place: this core's writer alternates `made` between CHAT_MADE and CHAT_MADE_ALT so
  // `old.made IS NOT new.made`; another core leaves `made` untouched, so its columns are made of it again at once, and
  // it is marked to be derived again at the next open)
  ["chat_made_set", `CREATE TRIGGER chat_made_set AFTER UPDATE OF json ON chat
      WHEN old.made IS new.made
      BEGIN
        UPDATE chat SET made = NULL, ${CHAT_COLUMNS.map(([c, of]) => `${c} = ${of("new.json")}`).join(", ")} WHERE rowid = new.rowid;
      END`],
];

/// What deriving a database's chat columns again took at its open (ensureChatColumns): the rows SQLite derived, those
/// whose JSON was read here (`state`), the bytes of that JSON. Zero where nothing was to be derived.
export type ChatColumnsMade = { rows: number; read: number; bytes: number };

/// The columns of a chat's record that only this core can say (`state`, `watched`: through Derive) or that SQLite
/// makes of its JSON (CHAT_COLUMNS), each row marked with the derivation it was made by (`made`, CHAT_MADE), and the
/// chats each session takes part in (`chat_agent`). This core's writer puts them with every record (account.ts
/// #putChatRow). An older core's write puts its own columns only, `made` left NULL; and every core opens its database
/// alone (locking_mode EXCLUSIVE, every host), so what an older core wrote is all there before this one reads anything:
/// at every open the rows whose `made` is not CHAT_MADE are derived again, SQLite making its columns itself (no JSON
/// crosses to the core for them), the core reading only those rows' agents for `state` and `watched` (present.rowState
/// and present.watches read no more). Whether there are any is asked of
/// the index on `made` alone. `chat_agent` is kept by triggers (SQL says all of it), made again whole where a trigger
/// was missing or not this core's. Made where missing at every open, as `said`.
export function ensureChatColumns(sql: Sql, derive: (agents: unknown) => { state: string | null; watched: boolean }): ChatColumnsMade {
  sql.exec("BEGIN IMMEDIATE");
  try {
    const has = new Set(sql.all("PRAGMA table_info(chat)").map((r) => String(r[1])));
    for (const column of ["state", "watched", "made", ...CHAT_COLUMNS.map(([c]) => c)]) if (!has.has(column)) sql.exec(`ALTER TABLE chat ADD COLUMN ${column}`);
    // The indexes the declared reads are found by (chat-reads.ts; chat-plans.test.ts holds each read's plan to its
    // bound): `chat_listed` the window's counts and the chats at work, of it alone; `chat_marks` the marked rows, of it
    // alone (in the place of `chat_marked`, which held their stations only; `chat_running` and `chat_desk`, which no read
    // reads any more, go: each cost every write); `chat_client` a chat by the key it was
    // asked for here by; `chat_archive` the archive's newest in its order, across stations; `chat_archived_at` the
    // archive's counts, of it alone. Partial, each holds only the rows its reads are of; one read of an index alone has
    // every column its statement names in it, those of the index's own WHERE too (SQLite takes it as covering only so),
    // and is searched by more terms than `chat_ord` (`chat_archived_at`'s `archived_mark`: else the device's SQLite
    // took `chat_ord`, and the table's rows).
    // (`chat_listed` from before `led` was among its columns: made again with it)
    const listedWas = sql.all("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'chat_listed'");
    if (listedWas.length > 0 && !/\bled\b/.test(String(listedWas[0]![0]))) sql.exec("DROP INDEX chat_listed");
    // (`chat_recent`, the window's walk, as the first schema made it: of every row, archived too, and no column the
    // window filters by, so each row it walked past (another station's, one an agent leads, not the viewer's) read the
    // table's page, its JSON inline, 168 ms of a list made on a phone, 2026-11-18. Made again partial and covering)
    const recentWas = sql.all("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'chat_recent'");
    if (recentWas.length > 0 && !/WHERE archived = 0/.test(String(recentWas[0]![0]))) sql.exec("DROP INDEX chat_recent");
    // (`chat_archive`, the archive's walk, as it was made before: of its order alone, so each archived row it walked
    // (another station's, one read apart, a tie of its order) read the table's page, its JSON inline: 248 ms of the
    // archive's place on a phone, 2026-11-19. Made again partial and covering)
    const archiveWas = sql.all("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'chat_archive'");
    if (archiveWas.length > 0 && !/\bstation\b/.test(String(archiveWas[0]![0]))) sql.exec("DROP INDEX chat_archive");
    // (`chat_unmade`, a partial index over unmade rows alone: 0 index writes on steady-state chat upserts that alternate
    // `made` between CHAT_MADE and CHAT_MADE_ALT, and an empty covering index to check at open. `chat_made` is the
    // name of the whole index of a core from before, which makes it again where it is missing and asks by it: left
    // to it under that name, never made partial there (its `made < ?` would read the table whole), and dropped here)
    const unmade = `made IS NULL OR made NOT IN (${CHAT_MADE}, ${CHAT_MADE_ALT})`;
    sql.exec("DROP INDEX IF EXISTS chat_made");
    sql.exec(`
      CREATE INDEX IF NOT EXISTS chat_recent ON chat (archived, pinned_at DESC, last_active DESC, station, ord, id, mine, hidden, led, watched, thread, session) WHERE archived = 0;
      CREATE INDEX IF NOT EXISTS chat_unmade ON chat (made) WHERE ${unmade};
      CREATE INDEX IF NOT EXISTS chat_archived_at ON chat (station, archived, archived_mark, archived_at DESC, thread, session) WHERE archived_mark = 1;
      CREATE INDEX IF NOT EXISTS chat_archive ON chat (archived, archived_mark, coalesce(archived_at, 0) DESC, station, ord, id, thread, session) WHERE archived = 1 AND archived_mark = 1;
      CREATE INDEX IF NOT EXISTS chat_listed ON chat (station, archived, state, mine, hidden, led, watched, last_active, thread, session, id) WHERE archived = 0;
      CREATE INDEX IF NOT EXISTS chat_marks ON chat (station, archived, id, tone, asks) WHERE archived = 0 AND (tone IS NOT NULL OR asks = 1);
      DROP INDEX IF EXISTS chat_marked;
      DROP INDEX IF EXISTS chat_running;
      DROP INDEX IF EXISTS chat_desk;
      CREATE INDEX IF NOT EXISTS chat_client ON chat (station, client_key) WHERE client_key IS NOT NULL;
      CREATE TABLE IF NOT EXISTS chat_agent (station TEXT NOT NULL, session TEXT NOT NULL, archived INTEGER NOT NULL, id TEXT NOT NULL, PRIMARY KEY (station, session, archived, id)) WITHOUT ROWID;
      CREATE INDEX IF NOT EXISTS chat_agent_row ON chat_agent (station, archived, id);
    `);
    const had = new Map(sql.all("SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'chat'").map((r) => [String(r[0]), String(r[1])]));
    let remade = false;
    for (const [name, statement] of chatTriggers()) {
      const was = had.get(name);
      if (was !== undefined && spaced(was) === spaced(statement)) continue;
      if (was !== undefined) sql.exec(`DROP TRIGGER ${name}`);
      sql.exec(statement);
      remade = true;
    }
    if (remade) {
      sql.exec("DELETE FROM chat_agent");
      sql.exec(`INSERT OR IGNORE INTO chat_agent (station, session, archived, id)
        SELECT c.station, json_extract(a.value, '$.key'), c.archived, c.id
        FROM chat AS c, json_each(CASE json_type(c.json, '$.agents') WHEN 'array' THEN c.json ELSE '{"agents":[]}' END, '$.agents') AS a
        WHERE json_type(CASE a.type WHEN 'object' THEN a.value ELSE '{}' END, '$.key') = 'text'`);
    }
    const out: ChatColumnsMade = { rows: 0, read: 0, bytes: 0 };
    // (by the partial covering index `chat_unmade` alone: literal predicate matches the index WHERE, no table row read)
    const any = sql.all(`SELECT 1 FROM chat WHERE ${unmade} LIMIT 1`).length > 0;
    if (any) {
      out.rows = sql.run(`UPDATE chat SET ${CHAT_COLUMNS.map(([c, of]) => `${c} = ${of("chat.json")}`).join(", ")} WHERE ${unmade}`);
      for (;;) {
        // (of each its agents alone, as SQLite reads them of its JSON)
        const page = sql.all(`SELECT rowid, json_extract(json, '$.agents') FROM chat WHERE ${unmade} LIMIT 256`);
        if (page.length === 0) break;
        for (const [rowid, agents] of page) {
          out.read++;
          out.bytes += typeof agents === "string" ? agents.length : 0;
          const d = derive(typeof agents === "string" ? JSON.parse(agents) : agents);
          sql.run("UPDATE chat SET state = ?, watched = ?, made = ? WHERE rowid = ?", [d.state, d.watched ? 1 : 0, CHAT_MADE, rowid as number]);
        }
      }
    }
    sql.exec("COMMIT");
    return out;
  } catch (e) {
    try {
      sql.exec("ROLLBACK");
    } catch {
      // Rolled back already.
    }
    throw e;
  }
}

/// A thread's letters (what its agents and other chats' wrote each other), item by item: their own log beside its
/// entries (the station's GET /threads/:id/letters, numbered from 1 in it). Made where missing at every open, as `said`.
export function ensureLetters(sql: Sql): void {
  sql.exec("CREATE TABLE IF NOT EXISTS letter (station TEXT NOT NULL, thread INTEGER NOT NULL, n INTEGER NOT NULL, json TEXT NOT NULL, PRIMARY KEY (station, thread, n)) WITHOUT ROWID");
}

/// Where a station said a chat of its went (`moved`: station/src/replica/handover.ts, its `409 moved`, `GET /moved`,
/// `chat-moved`): by the station it left (`station`, its address) and the chat's session, the station it is on now (its
/// address), its thread on the one it left (`thread`) and there (`there`); `came`, said by the one it went to (its row's
/// `from`, account.ts `#came`), not by the one it left. A chat that came back has no row. Made where missing at every
/// open, as `said`.
export function ensureMoved(sql: Sql): void {
  sql.exec("CREATE TABLE IF NOT EXISTS moved (station TEXT NOT NULL, session TEXT NOT NULL, there_station TEXT NOT NULL, thread INTEGER, there INTEGER, at INTEGER, came INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (station, session)) WITHOUT ROWID");
}

/// Minimal per-station sidecar for `POST /changed/shared`: only row digest and re-projection inputs (no raw shared row,
/// no `mineOf`, no `answeredBy`), per-station viewer identity/language/build metadata (`shared_meta`), and keyed viewer
/// marks (`shared_mark`) so cold-start mark diffs re-project only changed rows by index. Made where missing at every
/// open, as `said` and `moved`.
export function ensureSharedSidecar(sql: Sql): void {
  sql.exec(`
    CREATE TABLE IF NOT EXISTS shared_sidecar (
      station TEXT NOT NULL,
      id TEXT NOT NULL,
      digest TEXT NOT NULL,
      said TEXT,
      named TEXT,
      quoted_only INTEGER NOT NULL DEFAULT 0,
      local_admin INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (station, id)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS shared_mark (
      station TEXT NOT NULL,
      kind TEXT NOT NULL,
      k TEXT NOT NULL,
      v TEXT NOT NULL,
      PRIMARY KEY (station, kind, k)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS shared_meta (
      station TEXT PRIMARY KEY,
      me TEXT NOT NULL,
      selves TEXT NOT NULL,
      lang TEXT NOT NULL,
      hidden_known INTEGER NOT NULL DEFAULT 0,
      muted_known INTEGER NOT NULL DEFAULT 0,
      no_route_build TEXT
    ) WITHOUT ROWID;
  `);
}

/// What is kept of each log (a thread's entries, `entry`; an agent's transcript, `transcript`) as the device holds
/// within its room (data.ts KEPT): when its chat was last opened here, and whether its items were let go for room.
/// Made where missing at every open, as `said`.
export function ensureKept(sql: Sql): void {
  sql.exec("CREATE TABLE IF NOT EXISTS log_use (kind TEXT NOT NULL, station TEXT NOT NULL, id TEXT NOT NULL, opened INTEGER, evicted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (kind, station, id))");
}

/// What each log keeps (a thread's entries, `entry`, by its thread; a session's transcript, `transcript`, by its
/// session), in characters of their JSON, as `sum(length(json))` of its rows says it: what the device's page of what it
/// keeps reads (account.ts cacheUsage), which summed every row of both, overflow pages and all, as the settings page
/// first opened (some hundreds of ms of a phone's, 2026-11-16). Kept by triggers on the two tables, whoever writes them
/// (an older core too): before a row is put in, what a row it replaces (INSERT OR REPLACE deletes it firing no delete
/// trigger) took goes; then what it takes comes; a row deleted takes what it took away. A log whose bytes come to 0
/// has no row. `log_bytes_done`: the stations (`''`: all) whose logs of a table were counted whole once
/// (account.ts countLogs), the only ones the triggers keep counting: a station's logs are counted before they are read,
/// as they first are, never as the database opens; what changes of one not counted yet is nothing of the counts. Made where missing at every open, as `said`; a trigger that is not
/// this core's (missing, or another's statement) made again and every count let go with it, to be counted anew.
export const LOG_TABLES = { entry: "thread", transcript: "session" } as const;
const logTriggers = (): [string, string][] =>
  (Object.entries(LOG_TABLES) as [string, string][]).flatMap(([table, key]) => {
    // (only where the station's logs of the table are counted: one not counted yet is counted whole as it is, so a
    // change before that is nothing of the counts, and a station whose rows all went before nothing counted it)
    const counted = (row: "new" | "old") => `EXISTS (SELECT 1 FROM log_bytes_done AS d WHERE d.tbl = '${table}' AND d.station IN ('', ${row}.station))`;
    const add = (row: "new" | "old", sign: "" | "-", from = "") =>
      `INSERT INTO log_bytes (tbl, station, id, bytes) SELECT '${table}', ${row}.station, ${row}.${key}, ${sign}length(${from === "" ? `${row}.json` : "w.json"}) ${from === "" ? "WHERE" : `${from} AND`} ${counted(row)}
          ON CONFLICT (tbl, station, id) DO UPDATE SET bytes = bytes + excluded.bytes;`;
    const gone = (row: "new" | "old") => `DELETE FROM log_bytes WHERE tbl = '${table}' AND station = ${row}.station AND id = ${row}.${key} AND bytes = 0;`;
    const n = table === "entry" ? "n" : "i";
    return [
      [`log_bytes_${table}_was`, `CREATE TRIGGER log_bytes_${table}_was BEFORE INSERT ON ${table}
      BEGIN
        ${add("new", "-", `FROM ${table} AS w WHERE w.station = new.station AND w.${key} = new.${key} AND w.${n} = new.${n}`)}
      END`],
      [`log_bytes_${table}_put`, `CREATE TRIGGER log_bytes_${table}_put AFTER INSERT ON ${table}
      BEGIN
        ${add("new", "")}
        ${gone("new")}
      END`],
      [`log_bytes_${table}_set`, `CREATE TRIGGER log_bytes_${table}_set AFTER UPDATE ON ${table}
      BEGIN
        ${add("old", "-")}
        ${gone("old")}
        ${add("new", "")}
        ${gone("new")}
      END`],
      [`log_bytes_${table}_drop`, `CREATE TRIGGER log_bytes_${table}_drop AFTER DELETE ON ${table}
      BEGIN
        ${add("old", "-")}
        ${gone("old")}
      END`],
    ];
  });

export function ensureLogBytes(sql: Sql): void {
  sql.exec("BEGIN IMMEDIATE");
  try {
    sql.exec(`
      CREATE TABLE IF NOT EXISTS log_bytes (tbl TEXT NOT NULL, station TEXT NOT NULL, id NOT NULL, bytes INTEGER NOT NULL, PRIMARY KEY (tbl, station, id)) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS log_bytes_done (tbl TEXT NOT NULL, station TEXT NOT NULL, PRIMARY KEY (tbl, station)) WITHOUT ROWID;
    `);
    const had = new Map(sql.all("SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name IN ('entry', 'transcript')").map((r) => [String(r[0]), String(r[1])]));
    let remade = false;
    for (const [name, statement] of logTriggers()) {
      const was = had.get(name);
      if (was !== undefined && spaced(was) === spaced(statement)) continue;
      if (was !== undefined) sql.exec(`DROP TRIGGER ${name}`);
      sql.exec(statement);
      remade = true;
    }
    // (a trigger missing or not this core's: what was counted may have missed a write)
    if (remade) sql.exec("DELETE FROM log_bytes; DELETE FROM log_bytes_done;");
    sql.exec("COMMIT");
  } catch (e) {
    try {
      sql.exec("ROLLBACK");
    } catch {
      // Rolled back already.
    }
    throw e;
  }
}

/// What a chat shows small (an image's thumbnail, a video's poster), kept on the device as its station sent it (base64,
/// as the calls answer it): a file sent never changes, and a chat opened again, the app started anew, shows it without
/// reading it again (on a slow link a chat of screenshots took seconds). `size`: the characters of `bytes`; `used`: when
/// it was last shown (to the day), the least lately shown let go first past FILES_KEPT (account.ts). Both ahead of
/// `bytes`, so what is counted and let go is read without the images. Made as the first is kept (account.ts).
export function ensureFilesKept(sql: Sql): void {
  sql.exec(`CREATE TABLE IF NOT EXISTS file_kept (
    station TEXT NOT NULL, session TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, type TEXT NOT NULL,
    size INTEGER NOT NULL, used INTEGER NOT NULL, bytes TEXT NOT NULL, PRIMARY KEY (station, session, name, kind)
  ); CREATE INDEX IF NOT EXISTS file_kept_used ON file_kept (used);`);
}

/// The trees of what agents said (markdown.ts), as read here: a chat's page shows its Markdown read, and reading it is
/// a substantial part of opening a chat, so it is read once on the
/// device, not again each time the app starts. By the text's key (markdown.ts mdKey: the reading that made it, so a
/// core that reads otherwise reads afresh); `of`, the chat (`t:<thread>`) or agent (`s:<session>`) it was read for,
/// let go with it; `size` and `used` as file_kept's (the least lately shown let go first past MD_KEPT, account.ts).
/// Made as the first is kept.
export function ensureMdKept(sql: Sql): void {
  sql.exec(`CREATE TABLE IF NOT EXISTS md_kept (
    station TEXT NOT NULL, key TEXT NOT NULL, of TEXT NOT NULL, size INTEGER NOT NULL, used INTEGER NOT NULL,
    json TEXT NOT NULL, PRIMARY KEY (station, key)
  ) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS md_kept_used ON md_kept (used); CREATE INDEX IF NOT EXISTS md_kept_of ON md_kept (station, of);`);
}

/// What agents said in Slack and heard from it, read from their transcripts as they are written (elsewhere.ts): kept
/// beyond the transcript's items (let go for room, they are still shown in their chats). Made where missing at every
/// open, as `said`; answers whether it was made now (to be filled from the transcripts held).
export function ensureSlackSaid(sql: Sql): boolean {
  const had = sql.all("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'slack_said'").length > 0;
  sql.exec(`CREATE TABLE IF NOT EXISTS slack_said (
    station TEXT NOT NULL, session TEXT NOT NULL, i INTEGER NOT NULL, k INTEGER NOT NULL, out INTEGER NOT NULL, call TEXT,
    user TEXT, who TEXT, at INTEGER NOT NULL, dest TEXT NOT NULL, text TEXT NOT NULL, failed INTEGER NOT NULL DEFAULT 0,
    refused INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (station, session, i, k)
  )`);
  // `refused`: the tool itself refused the call (its result an error, not Slack's answer), so nothing left the station.
  // Added after the table was: then it is filled again, so that what was kept as failed says which it was.
  const added = had && !sql.all("PRAGMA table_info(slack_said)").some((c) => c[1] === "refused");
  if (added) sql.exec("ALTER TABLE slack_said ADD COLUMN refused INTEGER NOT NULL DEFAULT 0");
  return !had || added;
}

/// The Slack people a station's agents heard from (`slack_said`'s rows heard with a name), one row a person by their
/// Slack id (a bot's mention, `<@U…>`, its id out of it): when they were first heard, and their name as last heard and
/// when. Kept as `slack_said` is written (account.ts `#heardWho`), so naming them reads these rows, never what was said
/// (every message a station's agents ever heard, read whole as each chat was shown). Made where missing at every open;
/// answers whether it was made now (to be filled from `slack_said`). The index finds a person's rows in `slack_said`
/// again as some of them go.
export function ensureSlackWho(sql: Sql): boolean {
  const had = sql.all("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'slack_who'").length > 0;
  sql.exec(`CREATE TABLE IF NOT EXISTS slack_who (
    station TEXT NOT NULL, user TEXT NOT NULL, first INTEGER NOT NULL, who TEXT NOT NULL, at INTEGER NOT NULL,
    PRIMARY KEY (station, user)
  ) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS slack_said_user ON slack_said (station, user)`);
  return !had;
}

/// The full-text index an earlier core kept of `said` (`said_index`, FTS5) taken away: a row's words went from it only
/// as its segments merged, so a chat's messages let go and read again over and over left it some 200 times the words it
/// found (86 MB for 0.46 MB on a Mac), the room it took letting go the messages themselves.
function dropSaidIndex(sql: Sql): void {
  const has = (name: string) => sql.all("SELECT 1 FROM sqlite_master WHERE name = ?", [name]).length > 0;
  for (const trigger of ["said_index_put", "said_index_drop", "said_index_set"]) if (has(trigger)) sql.exec(`DROP TRIGGER ${trigger}`);
  try {
    if (has("said_index")) sql.exec("DROP TABLE said_index");
  } catch {
    // A build without FTS5 cannot take it away: left as it is, nothing writes or reads it.
  }
}

const sessionDetailTriggers = (): [string, string][] => [
  ["session_detail_sync_ins", `CREATE TRIGGER session_detail_sync_ins AFTER INSERT ON session WHEN new.detail IS NOT NULL
      BEGIN
        DELETE FROM session_detail WHERE station = new.station AND key = new.key;
      END`],
  ["session_detail_sync_upd", `CREATE TRIGGER session_detail_sync_upd AFTER UPDATE OF detail ON session WHEN new.detail IS NOT NULL
      BEGIN
        DELETE FROM session_detail WHERE station = new.station AND key = new.key;
      END`],
  ["session_detail_sync_del", `CREATE TRIGGER session_detail_sync_del AFTER DELETE ON session
      BEGIN
        DELETE FROM session_detail WHERE station = old.station AND key = old.key;
      END`],
];

/// Keeps each session's large detail JSON out of the `session` row so summary upserts never rewrite its overflow pages.
/// Triggers invalidate `session_detail` if an older core writes `session.detail` or deletes the parent `session` row.
export function ensureSessionDetail(sql: Sql): void {
  sql.exec("BEGIN IMMEDIATE");
  try {
    sql.exec("CREATE TABLE IF NOT EXISTS session_detail (station TEXT NOT NULL, key TEXT NOT NULL, detail TEXT NOT NULL, PRIMARY KEY (station, key))");
    const had = new Map(sql.all("SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'session'").map((r) => [String(r[0]), String(r[1])]));
    const want = sessionDetailTriggers();
    const same = want.every(([name, body]) => had.has(name) && spaced(had.get(name)!) === spaced(body));
    if (!same) {
      for (const [name] of want) sql.exec(`DROP TRIGGER IF EXISTS ${name}`);
      sql.exec("DELETE FROM session_detail WHERE NOT EXISTS (SELECT 1 FROM session s WHERE s.station = session_detail.station AND s.key = session_detail.key AND s.detail IS NULL)");
      for (const [, body] of want) sql.exec(body);
    }
    sql.exec("COMMIT");
  } catch (e) {
    try {
      sql.exec("ROLLBACK");
    } catch {
      // Rolled back already.
    }
    throw e;
  }
}

/// How many free pages `giveBackRoomStep` returns to the OS at once (about 1 MB at SQLite's 4 KB page size).
export const ROOM_BACK_PAGES = 256;

/// One step of giving unused pages back to the device: what is let go (an earlier core's search index, transcripts past
/// KEPT) left its pages free in the file, which stayed as large as it ever was (a phone's at 150 MB once the index was
/// gone). A database made before is rewritten once (VACUUM) to keep its free pages at the end (auto_vacuum
/// INCREMENTAL); then only those free are cut off, `pages` at a time, and the WAL is truncated once no free pages
/// remain. Answers whether more free pages remain for a following step.
export function giveBackRoomStep(sql: Sql, pages = ROOM_BACK_PAGES, minFree = 1): boolean {
  const one = (q: string) => Number(sql.all(q)[0]?.[0] ?? 0);
  if (one("PRAGMA auto_vacuum") !== 2) {
    sql.exec("PRAGMA auto_vacuum = INCREMENTAL");
    sql.exec("VACUUM");
    sql.all("PRAGMA wal_checkpoint(TRUNCATE)");
    return false;
  }
  const before = one("PRAGMA freelist_count");
  if (before < minFree) return false;
  sql.exec(`PRAGMA incremental_vacuum(${Math.max(1, Math.floor(pages))})`);
  const after = one("PRAGMA freelist_count");
  if (after > 0 && after < before) return true;
  if (after < before) sql.all("PRAGMA wal_checkpoint(TRUNCATE)");
  return false;
}

/// The room the database's file holds and no longer uses given back to the device whole.
export function giveBackRoom(sql: Sql): void {
  while (giveBackRoomStep(sql, 0x7fffffff)) {}
}

/// The database's version.
export function versionOf(sql: Sql): number {
  const v = sql.all("PRAGMA user_version")[0]?.[0];
  return typeof v === "number" ? v : 0;
}

/// Brings the database to VERSION, each migration in a transaction of its own. A database past it is left as it is:
/// false then (it is read only).
export function migrate(sql: Sql): boolean {
  let version = versionOf(sql);
  if (version > VERSION) return false;
  while (version < VERSION) {
    sql.exec("BEGIN IMMEDIATE");
    try {
      sql.exec(MIGRATIONS[version]);
      sql.exec(`PRAGMA user_version = ${version + 1}`);
      sql.exec("COMMIT");
    } catch (e) {
      try {
        sql.exec("ROLLBACK");
      } catch {
        // Rolled back already.
      }
      throw e;
    }
    version++;
  }
  return true;
}
