// Documents, station overview parts, workspace preferences, drafts, and unconfirmed local tables (account.ts).
import type { SqlValue } from "../host.ts";
import type { Topic } from "../protocol.ts";
import { isObject } from "../util.ts";
import { work } from "../work.ts";
import { type DbEnv, type Doc, type J, K, frozen, parse } from "./collection.ts";
import { ensureOverviewParts, HOT_PART_COLUMNS, overviewProfilesOf, PART_COLUMNS, partRev, PROFILE_PART_COLUMNS, PROFILE_PART_SET } from "./schema.ts";

export class DocsStore {
  readonly #env: DbEnv;
  /// Whether each overview's part the chat list reads is kept (`station_part`; it could not be made without room).
  #parts = false;
  /// Whether cold profile columns live in `station_part_profiles` (vs legacy `station_part` on an older read-only DB).
  #profileParts = false;
  /// Which table holds each overview part column this database keeps (`station_part` or `station_part_profiles`).
  readonly #tableOf = new Map<string, "station_part" | "station_part_profiles">();
  /// The profiles read of each station's overview, one by one (overviewProfile): let go of as its profiles change.
  readonly #profilesRead = new Map<string, Set<string>>();

  constructor(env: DbEnv) {
    this.#env = env;
  }

  openParts(readOnly: boolean): void {
    const sql = this.#env.sql;
    if (!readOnly) {
      try {
        ensureOverviewParts(sql);
        this.#parts = true;
        this.#profileParts = true;
        for (const [column] of HOT_PART_COLUMNS) this.#tableOf.set(column, "station_part");
        for (const [column] of PROFILE_PART_COLUMNS) this.#tableOf.set(column, "station_part_profiles");
      } catch {
        // No room to make it: each part is read of its overview, by SQLite, this time.
      }
      return;
    }
    this.#parts = sql.all("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'station_part'").length > 0;
    for (const r of this.#parts ? sql.all("PRAGMA table_info(station_part)") : []) this.#tableOf.set(String(r[1]), "station_part");
    this.#profileParts = sql.all("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'station_part_profiles'").length > 0;
    for (const r of this.#profileParts ? sql.all("PRAGMA table_info(station_part_profiles)") : []) this.#tableOf.set(String(r[1]), "station_part_profiles");
  }

  /// The account's own documents (`me`, `login_sessions`, `admin/<list>`).
  accountDoc(name: string): J {
    return this.#doc(K("acct", name), "SELECT json FROM account_doc WHERE name = ?", [name]);
  }

  putAccountDoc(name: string, value: J, confirmed: number | null, topic: Topic | null): void {
    this.#putDoc(K("acct", name), value, { table: "account_doc", keys: ["name"], of: [name], confirmed }, topic);
  }

  dropAccountDoc(name: string, topic: Topic | null): void {
    this.#dropDoc(K("acct", name), "DELETE FROM account_doc WHERE name = ?", [name], topic);
  }

  workspace(id: string): J {
    return this.#doc(K("ws", id), "SELECT json FROM workspace WHERE id = ?", [id]);
  }

  putWorkspace(id: string, value: J, confirmed: number | null): void {
    this.#putDoc(K("ws", id), value, { table: "workspace", keys: ["id"], of: [id], confirmed }, { topic: "workspace", workspace: id });
  }

  dropWorkspace(id: string): void {
    this.#dropDoc(K("ws", id), "DELETE FROM workspace WHERE id = ?", [id], { topic: "workspace", workspace: id });
  }

  workspaceIds(): string[] {
    return this.#env.sql.all("SELECT id FROM workspace").map((r) => String(r[0]));
  }

  /// A station's overview or usage.
  stationDoc(station: string, kind: string): J {
    const key = K("st", station, kind);
    const read = kind === "overview" && !this.#env.cache.has(key);
    const v = this.#doc(key, "SELECT json FROM station WHERE address = ? AND kind = ?", [station, kind]);
    if (read && v !== undefined) work.overviewsRead++;
    return v;
  }

  putStationDoc(station: string, kind: string, value: J, confirmed: number | null, topic: Topic | null): void {
    const doc = { table: "station", keys: ["address", "kind"], of: [station, kind], confirmed };
    this.#putDoc(K("st", station, kind), value, doc, topic, kind === "overview" ? (put) => this.#overviewWritten(station, put) : undefined);
  }

  dropStationDoc(station: string, kind: string, topic: Topic | null): void {
    const drop = () => this.#dropDoc(K("st", station, kind), "DELETE FROM station WHERE address = ? AND kind = ?", [station, kind], topic);
    if (kind === "overview") this.#overviewWritten(station, drop);
    else drop();
  }

  /// What the chat list reads of a station's overview (schema.ts overviewPartOf), undefined while none is held: kept
  /// beside it (`station_part`, by triggers), not the overview, which is not read.
  overviewPart(station: string): J {
    return this.#overviewColumn(station, "part");
  }

  /// What a station's row reads of its overview (schema.ts overviewRowOf), undefined while none is held or it is not an
  /// object: kept beside its part (`station_part.row`), not in it, so the chat list reads and parses what it did.
  overviewRow(station: string): J {
    return this.#overviewColumn(station, "row");
  }

  /// What a chat's page reads of its station's overview (schema.ts overviewChatOf), undefined while none is held or it
  /// is not an object: kept beside its part (`station_part.chat`), not the overview, which is not read.
  overviewChat(station: string): J {
    return this.#overviewColumn(station, "chat");
  }

  /// The stations a station took the place of (schema.ts overviewFormerlyOf), undefined while no overview is held:
  /// kept beside its part (`station_part.formerly`).
  overviewFormerly(station: string): J {
    return this.#overviewColumn(station, "formerly");
  }

  /// A station's own software as its overview lists it (schema.ts overviewSoftwareOf), undefined while no overview is
  /// held or it lists none: kept beside its part (`station_part.software`).
  overviewSoftware(station: string): J {
    return this.#overviewColumn(station, "software");
  }

  /// What the workspace's profiles read of a station's overview (schema.ts overviewProfiledOf), undefined while no
  /// overview is held: kept beside its part (`station_part.profiled`).
  overviewProfiled(station: string): J {
    return this.#overviewColumn(station, "profiled");
  }

  /// What the connects' list and a connect's page read of a station's overview (schema.ts overviewConnectsOf),
  /// undefined while no overview is held: kept beside its part (`station_part.connects`).
  overviewConnects(station: string): J {
    return this.#overviewColumn(station, "connects");
  }

  /// What the settings' automatic decisions and archiving read of a station's overview (schema.ts overviewSettingsOf),
  /// undefined while no overview is held or it is not an object: kept beside its part (`station_part.settings`).
  overviewSettings(station: string): J {
    return this.#overviewColumn(station, "settings");
  }

  /// The profile `id` of a station's overview, whole, undefined where it has none such (schema.ts overviewProfilesOf):
  /// that one alone read out of the column of its profiles by SQLite, not the overview, nor its other profiles.
  overviewProfile(station: string, id: string): J {
    const key = K("profile", station, id);
    if (this.#env.cache.has(key)) return this.#env.cache.get(key) ?? undefined;
    let read = this.#profilesRead.get(station);
    if (read === undefined) this.#profilesRead.set(station, (read = new Set()));
    read.add(id);
    const path = `$.${JSON.stringify(id)}`;
    const table = this.#tableOf.get("profiles");
    const kept = table !== undefined ? this.#env.sql.all(`SELECT profiles IS NOT NULL, profiles -> ? FROM ${table} WHERE address = ?`, [path, station])[0] : undefined;
    const r = kept !== undefined && kept[0] === 1
      ? kept[1]
      : this.#env.sql.all(`SELECT (${overviewProfilesOf("st.json")}) -> ? FROM station AS st WHERE st.address = ? AND st.kind = 'overview' AND json_valid(st.json)`, [path, station])[0]?.[0];
    const text = typeof r === "string" ? r : undefined;
    if (text !== undefined) {
      work.overviewParts++;
      work.overviewPartChars += text.length;
    }
    const v = text === undefined ? undefined : frozen(JSON.parse(text));
    this.#env.cache.set(key, v ?? null);
    return v;
  }

  /// Column `column` of a station's part (schema.ts PART_COLUMNS), parsed, kept till it changes.
  #overviewColumn(station: string, column: string): J {
    const key = K(column, station);
    if (this.#env.cache.has(key)) return this.#env.cache.get(key) ?? undefined;
    const text = this.#columnText(station, column);
    if (text !== undefined) {
      work.overviewParts++;
      work.overviewPartChars += text.length;
    }
    const v = text === undefined ? undefined : frozen(JSON.parse(text));
    this.#env.cache.set(key, v ?? null);
    return v;
  }

  /// Column `column` of a station's part as the database holds it; where it holds none (it could not keep the parts,
  /// a database a newer core wrote, or a core from before the column keeps the parts now by its own triggers: a web
  /// page still open from before), made of the overview by SQLite as it is read.
  #columnText(station: string, column: string): string | undefined {
    const table = this.#tableOf.get(column);
    const kept = table !== undefined ? this.#env.sql.all(`SELECT ${column} FROM ${table} WHERE address = ?`, [station])[0] : undefined;
    if (typeof kept?.[0] === "string") return kept[0];
    const of = PART_COLUMNS.find(([c]) => c === column)![1];
    const r = this.#env.sql.all(`SELECT ${of("st.json")} FROM station AS st WHERE st.address = ? AND st.kind = 'overview' AND json_valid(st.json)`, [station])[0];
    return typeof r?.[0] === "string" ? r[0] : undefined;
  }

  /// Whether a station's overview is held: by its key alone, its JSON not read.
  overviewHeld(station: string): boolean {
    const held = this.#env.cache.get(K("st", station, "overview"));
    if (held !== undefined) return held !== null;
    return this.#env.sql.all("SELECT 1 FROM station WHERE address = ? AND kind = 'overview'", [station]).length > 0;
  }

  /// What each column of a station's part is now, as its revision says it (schema.ts partRev): -1 where it holds no text
  /// (none held, or the overview not an object), its revision where it holds one, null where nothing says (a row a core
  /// that knows nothing of them put in, or a database that keeps no parts). A few numbers: no text read.
  #partRevs(station: string): (number | null)[] {
    if (!this.#parts) return PART_COLUMNS.map(() => null);
    const r = this.#profileParts
      ? this.#env.sql.all(
          `SELECT ${PART_COLUMNS.map(([c]) => {
            const a = PROFILE_PART_SET.has(c) ? "pp" : "p";
            return `CASE WHEN ${a}.${partRev(c)} IS NOT NULL AND ${a}.${c} IS NULL THEN -1 ELSE ${a}.${partRev(c)} END`;
          }).join(", ")} FROM station_part p LEFT JOIN station_part_profiles pp ON pp.address = p.address WHERE p.address = ?`,
          [station],
        )[0]
      : this.#env.sql.all(`SELECT ${PART_COLUMNS.map(([c]) => `CASE WHEN ${partRev(c)} IS NOT NULL AND ${c} IS NULL THEN -1 ELSE ${partRev(c)} END`).join(", ")} FROM station_part WHERE address = ?`, [station])[0];
    return PART_COLUMNS.map((_, i) => (r === undefined ? -1 : typeof r[i] === "number" ? r[i] : null));
  }

  /// The overview written or dropped by `write`, its part with it (the triggers): said only where a column of the part
  /// changed (its revision moved, or nothing says it did not), as `$overview-<column>` (what the chat list reads,
  /// `$overview-part`; a station's row, `$overview-row`; a chat's page, `$overview-chat`; a link to a chat,
  /// `$overview-formerly`), what the cache holds of it let go and read again as a reader asks (#overviewColumn); and
  /// where the overview is not what it was, as `$overview-fit`. What is kept beside the overview and its part
  /// (db/kept.ts: its verdict, its accounts' rows) is made again of them as they are written, a column read for it only
  /// where a value kept is to be made again.
  #overviewWritten(station: string, write: () => void): void {
    this.#env.write(() => {
      const before = this.#partRevs(station);
      const key = K("st", station, "overview");
      const was = this.#env.cache.get(key);
      const overview = this.#env.kept.writing("station", [station]);
      const profiled = this.#env.kept.writing("station_part_profiles", [station]);
      write();
      const after = this.#partRevs(station);
      for (const [i, [column]] of PART_COLUMNS.entries()) {
        if (before[i] !== null && after[i] !== null && before[i] === after[i]) continue;
        // (its profiles read one by one, not parsed whole: each read again of them)
        if (column === "profiles") for (const id of this.#profilesRead.get(station) ?? []) this.#env.cache.delete(K("profile", station, id));
        else this.#env.cache.delete(K(column, station));
        if (column === "profiled") this.#env.kept.wrote(profiled, () => this.#overviewColumn(station, column));
        this.#env.tell({ topic: `$overview-${column}`, station });
      }
      const now = this.#env.cache.get(key);
      if (now === was && now !== undefined) return;
      this.#env.tell({ topic: "$overview-fit", station });
      this.#env.kept.wrote(overview, () => (isObject(now) ? now : undefined));
    });
  }

  /// At most `most` of a station's documents whose kind starts with `prefix`, the latest confirmed: the others go.
  boundStationDocs(station: string, prefix: string, most: number): void {
    const kinds = this.#env.sql.all("SELECT kind FROM station WHERE address = ? AND substr(kind, 1, ?) = ? ORDER BY confirmed DESC", [station, prefix.length, prefix]);
    for (const [kind] of kinds.slice(most)) this.dropStationDoc(station, String(kind), null);
  }

  slackApp(station: string, connect: string): J {
    return this.#doc(K("slack", station, connect), "SELECT json FROM slack_app WHERE station = ? AND connect = ?", [station, connect]);
  }

  putSlackApp(station: string, connect: string, value: J, confirmed: number | null): void {
    this.#putDoc(K("slack", station, connect), value, { table: "slack_app", keys: ["station", "connect"], of: [station, connect], confirmed }, { topic: "slackApp", station, connect });
  }

  draft(station: string, chat: string): J {
    return this.#doc(K("draft", station, chat), "SELECT json FROM draft WHERE station = ? AND chat = ?", [station, chat]);
  }

  putDraft(station: string, chat: string, value: J | undefined): void {
    const topic = { topic: "draft", station, chat };
    if (value === undefined) this.#dropDoc(K("draft", station, chat), "DELETE FROM draft WHERE station = ? AND chat = ?", [station, chat], topic);
    else this.#putDoc(K("draft", station, chat), value, { table: "draft", keys: ["station", "chat"], of: [station, chat] }, topic);
  }

  workspacePref(workspace: string, key: string): J {
    return this.#doc(K("wpref", workspace, key), "SELECT json FROM workspace_pref WHERE workspace = ? AND key = ?", [workspace, key]);
  }

  putWorkspacePref(workspace: string, key: string, value: J | undefined, topic: Topic | null = null): void {
    if (value === undefined) this.#dropDoc(K("wpref", workspace, key), "DELETE FROM workspace_pref WHERE workspace = ? AND key = ?", [workspace, key], topic);
    else this.#putDoc(K("wpref", workspace, key), value, { table: "workspace_pref", keys: ["workspace", "key"], of: [workspace, key] }, topic);
  }

  /// What this device did and its station has not confirmed (views/local.ts): every row of one of its tables.
  locals(table: "outbox" | "pending" | "first" | "changing"): [string, string, J][] {
    const key = table === "outbox" ? "thread" : table === "pending" ? "key" : table === "first" ? "session" : "id";
    return this.#env.sql.all(`SELECT station, ${key}, json FROM ${table} ORDER BY station, ${key}`).map((r) => [String(r[0]), String(r[1]), parse(r[2])]);
  }

  putLocal(table: "outbox" | "pending" | "first" | "changing", station: string, key: string, value: J | undefined): void {
    this.#env.write(() => {
      const column = table === "outbox" ? "thread" : table === "pending" ? "key" : table === "first" ? "session" : "id";
      const k: SqlValue = table === "outbox" || table === "changing" ? Number(key) : key;
      if (value === undefined) this.#env.run(`DELETE FROM ${table} WHERE station = ? AND ${column} = ?`, [station, k]);
      else if (table === "pending") this.#env.run("INSERT OR REPLACE INTO pending (key, station, json) VALUES (?, ?, ?)", [key, station, JSON.stringify(value)]);
      else this.#env.run(`INSERT OR REPLACE INTO ${table} (station, ${column}, json) VALUES (?, ?, ?)`, [station, k, JSON.stringify(value)]);
    });
  }

  #doc(key: string, select: string, params: SqlValue[]): J {
    if (this.#env.cache.has(key)) return this.#env.cache.get(key) ?? undefined;
    const row = this.#env.sql.all(select, params)[0];
    const value = row ? frozen(parse(row[0])) : undefined;
    this.#env.cache.set(key, value ?? null);
    return value;
  }

  /// A document put (`doc`: its table, the columns of its key and their values, and when its source confirmed it where
  /// the table keeps that, null where it did not now), `around` the write where one is given (what its triggers make
  /// beside it: #overviewWritten). Whether it is the same as the one held is SQLite's to say, by a number: no document's
  /// text comes back to be compared. The same: only when it was confirmed changes. Another, or none held: it is put,
  /// kept in the cache as it is, and told.
  #putDoc(key: string, value: J, doc: Doc, topic: Topic | null, around?: (put: () => void) => void): void {
    this.#env.write(() => {
      const json = JSON.stringify(value);
      const where = doc.keys.map((c) => `${c} = ?`).join(" AND ");
      const same = doc.confirmed === undefined
        ? this.#env.sql.all(`SELECT json = ? FROM ${doc.table} WHERE ${where}`, [json, ...doc.of])[0]
        : this.#env.sql.all(`SELECT json = ?, confirmed FROM ${doc.table} WHERE ${where}`, [json, ...doc.of])[0];
      if (same?.[0] === 1) {
        if (doc.confirmed !== undefined && doc.confirmed !== null && same[1] !== doc.confirmed) this.#env.run(`UPDATE ${doc.table} SET confirmed = ? WHERE ${where}`, [doc.confirmed, ...doc.of]);
        return;
      }
      const columns = [...doc.keys, "json", ...(doc.confirmed === undefined ? [] : ["confirmed"])];
      const values = [...doc.of, json, ...(doc.confirmed === undefined ? [] : [doc.confirmed])];
      const put = () => {
        this.#env.run(
          doc.confirmed === undefined
            // (a workspace's value kept in place: a station's cursor is written with every burst of its events, and
            // REPLACE would write its row's index again each time)
            ? doc.table === "workspace_pref"
              ? `INSERT INTO ${doc.table} (${columns.join(", ")}) VALUES (${columns.map(() => "?").join(", ")}) ON CONFLICT (${doc.keys.join(", ")}) DO UPDATE SET json = excluded.json`
              : `INSERT OR REPLACE INTO ${doc.table} (${columns.join(", ")}) VALUES (${columns.map(() => "?").join(", ")})`
            : `INSERT INTO ${doc.table} (${columns.join(", ")}) VALUES (${columns.map(() => "?").join(", ")}) ON CONFLICT (${doc.keys.join(", ")}) DO UPDATE SET json = excluded.json, confirmed = coalesce(excluded.confirmed, confirmed)`,
          values,
        );
        this.#env.cache.set(key, frozen(JSON.parse(json)));
        if (topic) this.#env.tell(topic);
      };
      if (around === undefined) put();
      else around(put);
    });
  }

  #dropDoc(key: string, del: string, params: SqlValue[], topic: Topic | null): void {
    this.#env.write(() => {
      if (this.#env.run(del, params) > 0 && topic) this.#env.tell(topic);
      this.#env.cache.set(key, null);
    });
  }
}
