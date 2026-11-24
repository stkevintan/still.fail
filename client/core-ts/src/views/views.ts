// The views: what one screen shows, put together from the account and station topics so the UI does no
// joining, filtering or grouping (Views). A view watches the topics it is built from; any change
// of them only invalidates it, and the store has it computed when its coalesced emission goes out. What a person did
// here and their station has not confirmed yet (local.ts) is laid over what the stations hold.
import { Effect } from "effect";
import { work } from "../work.ts";
import type { Inner } from "../core.ts";
import type { Data } from "../data.ts";
import type { ChatFound, Derive, HeadRow } from "../db/account.ts";
import { KEPT, type ListRow } from "../db/kept.ts";
import { CHAT_READS } from "../db/chat-reads.ts";
import type { Host, SqlValue } from "../host.ts";
import type { Runner } from "../runtime.ts";
import type { Store } from "../store.ts";
import type { Owner } from "../core/routing.ts";
import * as chatTabs from "../chat-tabs.ts";
import * as decisions from "../decisions.ts";
import { merge } from "../entries.ts";
import { lowerBound } from "../ordered.ts";
import { CoreError } from "../error.ts";
import * as format from "../format.ts";
import { current as lang, t } from "../i18n.ts";
import * as jobs from "../jobs.ts";
import * as looks from "../looks.ts";
import { conformTy, defaultOf, shapedBeside, shapeKey, textKey } from "../conform.ts";
import { LISTED_CHAT } from "../shapes/schema.ts";
import * as present from "../present.ts";
import { topicKey, type Topic } from "../protocol.ts";
import * as refs from "../refs.ts";
import { computed, Marks, untracked, type Derived } from "../reactive.ts";
import { Moments } from "../clock.ts";
import { chatOfLink, chatsLinked, personWords } from "../refLinks.ts";
import { timed } from "../spent.ts";
import type { Value, Watch } from "../store.ts";
import { arr as arrU, deepFreeze, equal, get as getU, isObject, shaped, shapedAs, sharedValue } from "../util.ts";
import { ofAddress } from "../workspace.ts";
import { presentHistory } from "../history.ts";
import { sentFrom, sentHead } from "../sent-from.ts";
export { sentFrom };
import { archiveHintOf, badgeKindsOf, failsGoneOf, jobsSeenOf, type ArchiveHint } from "../prefs.ts";
import { stationFeature } from "../features.ts";
import { markdown, markdownHere, mdKey, type MdStore } from "../markdown.ts";
import { heardFiles, type Said } from "../elsewhere.ts";
import { isImage, near, placeFiles } from "../placed.ts";
import { KINDS as THING_KINDS, OUTLINE_FOUND, isVideo, mediaDays, thingsHaving, thingsOf, wordsOf } from "../things.ts";
import { archive, archiveSearch } from "./archive.ts";
import { Local, PENDING_PREFIX } from "./local.ts";
import { askAnswers } from "./vault.ts";
import * as logins from "../station/machine-logins.ts";
import { StationAddr } from "../station/addr.ts";
import type { LinkDiag } from "../station/link.ts";
import { relayHost, type PeerDiag } from "../mesh.ts";
import { stationsGuard } from "./lock.ts";
import * as marks from "./marks.ts";
import { lineForViewer, noTurnBegun, stageFields } from "../chat-stage.ts";
import { usageView } from "./usage.ts";
import { usageSummary } from "./usage-summary.ts";
import { agentRates } from "./agent-rates.ts";
import { fleetView } from "./fleet.ts";
import { stationUpdates } from "./station-updates.ts";
import { STALE_BUILD_MS } from "../station/oldest.ts";
import { chatsCard, usageCard } from "./rail-cards.ts";
import { resourcesView } from "./resources.ts";
import { stationProfileSummary, workspaceProfiles } from "./profiles.ts";
import { profilesOverview } from "./profiles-overview.ts";
import { settingsView } from "./settings.ts";
import { waysView, type WaysView } from "./ways.ts";
import { keptWays } from "./ways-stations.ts";
import { admin, sources as adminSources } from "./admin.ts";
import { attention, choices, find, models, quotaFor, runnableOn, runtimes, servingIn } from "./models.ts";
import * as brief from "./brief.ts";
import * as xshare from "./xshare.ts";
import * as memberships from "./memberships.ts";
import * as publish from "./publish.ts";
import { type SearchSource, searchView, stationTopic } from "./search.ts";

/// An hour, in ms (the Profile overview is made again at each).
const HOUR = 3_600_000;

// deno-lint-ignore no-explicit-any
type J = any;
const arr = (v: unknown): J[] => arrU(v) ?? [];
const get = (v: unknown, k: string): J => getU(v, k);
const str = (v: J): string | null => (typeof v === "string" ? v : null);
const u64 = (v: J): number | null => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null);

/// Database values are frozen all through and can be shared; copy an unfrozen value before a view keeps it.
/// The reasons a failed turn's notice offers 重试 for (station actor.ts `AGAIN`).
const AGAIN = ["network", "model", "other", "exited"];
const sharedOrCopied = (v: J): J => v !== null && typeof v === "object" && Object.isFrozen(v) ? v : structuredClone(v);

const DAY_MS = 86_400_000;
/// A chat's key among the first windows told (Views `setChatWindow`): its station, and its thread or its agent's
/// session as its page names it.
function chatWindowKey(station: string, thread: number | null, session: string | null): string {
  return `${station}\u0001${thread ?? ""}\u0001${session ?? ""}`;
}

/// How many of a chat list's rows go out while it has not been told its window (`chats.window`, Views `chatsWindow`):
/// what a page showed of it first before the app said how many it shows (only tests and replays of old runs ask so).
export const WINDOW_UNTOLD = 50;

/// (`stationsWhole` is the core's own: a scope's stations, each its page with the models it can run, as `stations` was
/// before its items were rows. choose.ts reads it for a model's choice and its borrowing; no UI asks it, and protocol.ts
/// does not offer it.)
const VIEW_TOPICS = new Set(["chats", "chatRow", "chatSearch", "search", "stations", "station", "stationPart", "stationsWhole", "profiles", "profilesWhole", "profilesOverview", "profile", "connects", "connect", "connectCandidates", "chat", "history", "agentCard", "stationNet", "stationDiag", "archive", "workspaceMarks", "chatJobs", "chatLetters", "chatThings", "chatOutline", "chatSubchats", "imageNear", "longJobs", "usage", "agentRates", "fleet", "railCard", "stationUpdates", "settings", "resources", "adminList", "adminItem", "adminOverview", "adminRelays", "workspaceWays"]);

/// What a chat row's columns say that the views find rows by (db/account.ts): how urgent it is for its person
/// (workspace marks), whether it asks something of them, what its agents are doing as its list's row says it.
export const chatDerive: Derive = {
  tone: marks.rowTone,
  asks: (row) => {
    const d = decisions.asked(row);
    return d !== null && !decisions.dismissed(d);
  },
  state: (row) => present.rowState(arr(get(row, "agents"))),
  watched: (row) => present.watches(arr(get(row, "agents"))),
};

/// A station's overview and host reading as its row and its page show them (Views `#stationShownOf`).
type StationShown = { full: Derived<J>; profile: Derived<J>; settings: Derived<J>; host: Derived<J>; row: Derived<J>; acceptAutoChats: Derived<boolean>; hostRow: Derived<J>; unreadable: Derived<boolean>; offered: Derived<J[]>; judge: (o: J) => boolean };

/// A station of a scope, as the workspace lists it.
/// `joined`: the station's home is another workspace, this one it joined.
export type StationInfo = { address: string; id: string; name: string; emoji: string | null; icon: string | null; online: boolean; lastSeen: J; version: J; joined: boolean };

/// Whether a station is taken for down: its link found it so, or — not found out yet this time — it was, last.
export function down(link: J): boolean {
  const state = get(link, "state");
  // (gone for its update: down from the moment it goes, as it will be a while)
  if (state !== "online" && get(link, "cause") === "updating") return true;
  return state === "offline" || (state === "connecting" && get(link, "last") === "offline");
}

function linkValue(v: Value | undefined): J {
  if (v === undefined) return { state: "connecting", message: null };
  if ("err" in v) return { state: "error", message: v.err.message };
  const cause = get(v.ok, "cause");
  const catching = get(v.ok, "catching");
  const old = get(v.ok, "old");
  return { state: get(v.ok, "state") ?? "connecting", message: get(v.ok, "message") ?? null, last: get(v.ok, "last") ?? null, ...(get(v.ok, "hostUnreadable") === true ? { hostUnreadable: true } : {}), ...(get(v.ok, "retrying") === true ? { retrying: true } : {}), ...(typeof cause === "string" ? { cause } : {}), ...(typeof catching === "number" ? { catching } : {}), ...(old === "station" || old === "app" ? { old } : {}) };
}

const stationOnline = (v: Value | undefined): boolean => !down(linkValue(v));
/// The viewer's `archiveHint` of the prefs (an error: none): what the chat list reads of them, made again only as it
/// changes, not as the app writes another pref (`workspace`, at every switch of workspace).
const archiveHintIn = (v: Value | undefined): ArchiveHint => archiveHintOf(v !== undefined && "ok" in v ? (v.ok ?? null) : null);
/// The failures of a station's chats its viewer let go (the prefs' `failsGone` of its workspace, as views/marks.ts
/// `failureOf` names them), which a row's stage reads (chat-stage.ts `needsViewer`): one picker a station, so that the
/// store keeps what it picked while the prefs say the same of it.
const goneIns = new Map<string, (v: Value | undefined) => readonly string[]>();
function goneIn(station: string): (v: Value | undefined) => readonly string[] {
  let pick = goneIns.get(station);
  if (pick === undefined) {
    pick = (v) => [...failsGoneOf(v !== undefined && "ok" in v ? (v.ok ?? null) : null, ofAddress(station))].filter((k) => k.startsWith(`${station}/`)).sort();
    goneIns.set(station, pick);
  }
  return pick;
}
/// What a chat's page reads of the prefs (its side panel's tabs, the station updates let be), so that another of them
/// written (the workspace, at every switch of it) makes no chat again.
const chatPrefsIn = (v: Value | undefined): J => {
  const prefs = v !== undefined && "ok" in v ? v.ok : null;
  return { chatTabs: get(prefs, "chatTabs"), stationUpdatesDismissed: get(prefs, "stationUpdatesDismissed") };
};

/// The station updates let be of the prefs (`stationUpdatesDismissed`: a version a station, as a chat's notice of it
/// keeps it), what the offer of the stations' newer releases reads of them.
const updatesDismissedIn = (v: Value | undefined): J => get(v !== undefined && "ok" in v ? v.ok : null, "stationUpdatesDismissed");

/// A station taken for down, in words, as its link says why (link.ts DownCause): the device's network, the station, or
/// the way between them, or its update.
export function downWords(link: J, name: string): string {
  const cause = get(link, "cause");
  if (cause === "updating") return t("core-views.station.updating", { name });
  if (cause === "network") return t("core-views.station.offline_network", { name });
  if (cause === "unreached") return t("core-views.station.unreachable", { name });
  if (cause === "lock") return t("core-views.station.lock", { name });
  return t("core-views.station.offline", { name });
}

/// What a station's link makes of each of its chats' rows: offline, in words (and gone for its update), or its link
/// coming back; nothing while it is linked. Said once for the station (ChatsView `stations`), not on each row.
export function rowWords(s: StationInfo, link: J): J {
  if (!s.online) return { offline: downWords(link, s.name), ...(get(link, "cause") === "updating" ? { updating: true } : {}) };
  const state = str(get(link, "state")) ?? "connecting";
  if (state === "error") return { reconnecting: t("core-views.station.retrying", { name: s.name }) };
  if (state === "reconnecting") return { reconnecting: t("core-views.station.reconnecting_now", { name: s.name }) };
  return {};
}

/// A row as its station's state (rowWords) makes it: offline, it is not swiped away; gone for its update, its second line
/// says so in place of where its agents were (what one needs of the viewer kept), as it is back by itself in a while.
/// The app does the same with the list's rows (apps/mbui sfbase `station_on`); the core for those it lists elsewhere.
export function stationOn(row: J, words: J): J {
  const offline = str(get(words, "offline"));
  const reconnecting = str(get(words, "reconnecting"));
  if (offline === null && reconnecting === null) return row;
  const out: J = { ...row };
  if (offline !== null) {
    out.offline = offline;
    delete out.swipeArchive;
    delete out.swipeAsk;
  }
  if (reconnecting !== null) out.reconnecting = reconnecting;
  if (get(words, "updating") === true) {
    out.updating = true;
    if (out.stateLead !== "need") {
      out.stateText = offline;
      for (const k of ["stateLead", "stateLeadText", "stateRest", "stateAbout"]) delete out[k];
    }
  }
  return out;
}

/// The list with each row as its station's state makes it (stationOn): for what lists its rows elsewhere (a search).
function stationsOn(chats: J): J {
  const words = new Map(arr(get(chats, "stations")).map((s) => [str(get(s, "station")) ?? "", s]));
  if (![...words.values()].some((w) => get(w, "offline") !== undefined || get(w, "reconnecting") !== undefined)) return chats;
  return { ...chats, days: arr(get(chats, "days")).map((d) => ({ ...d, items: arr(get(d, "items")).map((row) => stationOn(row, words.get(str(get(row, "station")) ?? ""))) })) };
}

/// What a search found among a list's rows (refs.search's `items`), each as its station's state makes it (stationOn): as
/// stationsOn would have made them, the rows it did not find left as they are.
function foundOn(chats: J, found: J): J {
  const words = new Map(arr(get(chats, "stations")).map((s) => [str(get(s, "station")) ?? "", s]));
  if (![...words.values()].some((w) => get(w, "offline") !== undefined || get(w, "reconnecting") !== undefined)) return found;
  return { ...found, items: arr(get(found, "items")).map((row) => stationOn(row, words.get(str(get(row, "station")) ?? ""))) };
}

/// Which of a list's rows went and came since it was last made (`#chats`): `whole` when it was made again whole.
type RowsChanged = { whole: boolean; gone: J[]; come: J[] };
/// How many rows going and coming a list's days take one by one (`#daysOf`); more, they are made again whole.
const ROWS_PUT_ALONE = 32;
/// How many messages' links to chats are kept found (views.ts `#chatsLinked`): more than a chat's page shows.
const LINKS_KEPT = 512;

/// A station's rows as its records `listed` make them (`make`), from what `was` (its records then) made: the same
/// records in the same order taken as they were, walking both, a record put in or taken out stepped over (a chat moved
/// to the top is one row taken out and one put in), the rest made. What went and came is said in `changes`.
function keptBetween(was: J[], made: (J | null)[], listed: J[], make: (raw: J) => J | null): { made: (J | null)[]; gone: J[]; come: J[] } {
  const out: (J | null)[] = [];
  const gone: J[] = [];
  const come: J[] = [];
  const put = (raw: J) => {
    const row = make(raw);
    if (row !== null) come.push(row);
    out.push(row);
  };
  const drop = (j: number) => {
    const row = made[j];
    if (row !== null && row !== undefined) gone.push(row);
  };
  let i = 0;
  let j = 0;
  while (i < listed.length && j < was.length) {
    if (listed[i] === was[j]) {
      out.push(made[j] ?? null);
      i++;
      j++;
    } else if (j + 1 < was.length && listed[i] === was[j + 1]) drop(j++);
    else if (i + 1 < listed.length && listed[i + 1] === was[j]) put(listed[i++]);
    else {
      drop(j++);
      put(listed[i++]);
    }
  }
  while (j < was.length) drop(j++);
  while (i < listed.length) put(listed[i++]);
  return { made: out, gone, come };
}

/// A list's rows not made yet (`#chats`), each a frozen stand-in for its record carrying only what the list reads of a
/// row before it goes out (`lastActiveAt` for its order and days, its pinned moment in `pinnedAt`, `station` and `state`
/// for its glyph), to what makes its row once and keeps it. A row is made as something shows it (`firstRows`): a list
/// of 420 chats made all of them, 55 ms in one block, to send a page of 50 (Hermes, 2026-11-11). None goes out.
const unmade = new WeakMap<object, () => J>();
/// What a chat's whole row (`chatRow`, views.ts #chatRow `whole` and #rowMenu) says that its list's row is made without:
/// what is read only as the row is pressed, held, swiped or pointed at (the rest of the two is one: views.test.ts).
const WHOLE_ONLY = ["watch", "swipeAsk", "decision", "mayShare", "mayPublish", "mayMove", "slackUrl", "slackApp", "feishuUrl", "commaUrl", "commaApp"];
/// What a chat list's row holds (#listRow) besides what its shape declares (schema.ts LISTED_CHAT), each for what reads it
/// in the core (`store.value`, a row as made): nothing else of its record is copied into it, nor worked out for it.
/// (A search's, the `@` menu's and a share's chats are a list's rows sent as ChatItem: `search`, `chatSearch`, `shareIn`,
/// what wholeFor puts on them besides.)
export const LIST_ROW_READ: Record<string, string> = {
  lastActiveAt: "#days and #daysOf (its order, its day); refs.search (ranked by it); ChatItem `time` (present.times)",
  origin: "share-in.ts open (a Slack or Feishu chat takes nothing shared in from here)",
  xshare: "refs.withOutside (those shared with the workspace first); ChatItem",
  kept: "ChatItem",
  muted: "ChatItem",
  // (worked out for `settled` anyway; no code reads it of a list's row now, views.test.ts holds it the core's)
  archivable: "whether it goes with one tap whatever the viewer's archiveHint (views.test.ts)",
};
/// A chat list's row's keys at most: its shape's and what the core reads of it (LIST_ROW_READ), with its record's moments
/// a search's ChatItem says in words (`time`: present.times).
export const LIST_ROW_KEYS: ReadonlySet<string> = new Set([...LISTED_CHAT, ...Object.keys(LIST_ROW_READ), ...present.TIME_KEYS]);
/// Of those, what a row takes of its record as it is (its values shared, frozen), before what it works out of it is put.
const LIST_ROW_TAKEN = [...LIST_ROW_KEYS].filter((k) => !["agents", "last", "people", "creator", "pinned", "opener", "station", "stationName"].includes(k));

let listRowShapes: string | null = null;

/// What a chat list's row is made with besides its record (#listRow), as the key its row is kept by beside its record
/// (db/kept.ts KEPT.listRow): how it is made (its `making`, which test/list-rows.test.ts's digest holds) and the shape it goes out as (`ListedChat` and every shape
/// it reaches, conform.ts shapeKey), the language and the product it says itself in, its station (its address, its
/// name, its mark where there are several), the viewer, the workspace's members, who the viewer is in Slack there (its
/// overview's part, `slackUsers`) and the viewer's `archiveHint`. A row is taken as kept only under the key in force;
/// test/list-rows.test.ts holds that a row made otherwise under another of any of these has another key.
export function listRowKey(s: StationInfo, mark: { emoji: string | null; icon: string | null } | null, me: J, slackUsers: string[], members: J[], hint: ArchiveHint, gone: readonly string[] = []): string {
  return textKey(JSON.stringify([KEPT.listRow.making, (listRowShapes ??= shapeKey("ListedChat")), lang(), brand.name(), s.address, s.name, mark, me, slackUsers, membersKey(members), hint, gone]));
}

/// A workspace's members as a key (conform.ts textKey), once for each list of them (a workspace's is shared and never
/// changed in place): its stations' keys say it, not each its whole list again.
const membersKeys = new WeakMap<object, string>();
function membersKey(members: J[]): string {
  let k = membersKeys.get(members);
  if (k === undefined) membersKeys.set(members, (k = textKey(JSON.stringify(members))));
  return k;
}

/// A row read back from its column beside its record (`whole`, and as it goes out, `sent`), made what a row #listRow
/// made is: frozen all through, what it goes out as beside it (conform.ts shapedBeside), so that it is neither made nor
/// shaped again.
export function listRowTaken(row: ListRow): void {
  deepFreeze(row);
  shapedBeside(row.whole, "ListedChat", row.sent);
}

let profileRowShapes: string | null = null;

/// What a station's accounts' rows are made with besides its part (#profileRowsMade), as the key they are kept by
/// beside it (db/kept.ts KEPT.profileRow): how they are made (its `making`, which test/profile-rows.test.ts's digest
/// holds), the shapes they are made through (the
/// overview's, whose `Profile` each is decorated as, and the row's, `ProfileRow`), the language and the product they
/// are said in. Nothing of the station (its name, whether it is up) nor of the others: that is the list's merge across
/// stations (profiles.ts workspaceProfiles), made as it is read. test/profile-rows.test.ts holds that rows made
/// otherwise have another key, and that a station renamed or gone down changes only what the merge makes.
export function profileRowKey(): string {
  return textKey(JSON.stringify([KEPT.profileRow.making, (profileRowShapes ??= `${shapeKey("Overview")}/${shapeKey("ProfileRow")}`), lang(), brand.name()]));
}

/// What the list's merge (profiles.ts workspaceProfiles) and an account's row (ProfileRow, RowProfile) read of a
/// station's decorated profile: what a station's rows keep of each (#profileRowsMade).
const PROFILE_ROW_FIELDS = [
  "id", "name", "email", "runtime", "access", "enabled", "share", "trouble", "checkText", "checkTone", "usedBy", "serves", "workspaces", "machine",
  "providerMark", "usesText", "kindText", "planText", "quota", "shareable",
] as const;
/// Of an allowance, what a row draws (RowQuota), its windows' `resetsAt` beside (what its refills are said of at read).
const ROW_QUOTA_FIELDS = ["state", "detail", "creditsText", "windows"] as const;
const ROW_WINDOW_FIELDS = ["label", "scope", "mark", "left", "level", "resetsAt"] as const;

const picked = (v: J, keys: readonly string[]): J => {
  const out: J = {};
  for (const k of keys) if (isObject(v) && k in v) out[k] = v[k];
  return out;
};

/// A station's accounts' rows of its decorated part (`shown`, the overview's shape): its profiles each as kept, what
/// its sharing and its reach say (what the merge reads of the part), no time in words and no window's refills.
function profileRowsOf(shown: J): J {
  const profiles = arr(get(shown, "profiles")).map((p) => {
    const row = picked(p, PROFILE_ROW_FIELDS);
    if (isObject(row.trouble)) row.trouble = picked(row.trouble, ["title", "action"]);
    if (isObject(row.quota)) {
      const q = picked(row.quota, ROW_QUOTA_FIELDS);
      if (Array.isArray(q.windows)) q.windows = q.windows.map((w: J) => picked(w, ROW_WINDOW_FIELDS));
      row.quota = q;
    }
    return row;
  });
  // (whether a share of it can follow the workspace's whitelist, and whether it is on that whitelist, said only where
  // so: every station's rows are read for the list and its overview, and these are false on most)
  return {
    profiles, sharing: get(shown, "sharing") ?? null,
    ...(get(shown, "shareAllowAuto") === true ? { shareAllowAuto: true } : {}),
    ...(get(get(shown, "autoChats"), "enabled") === true ? { autoChats: { enabled: true } } : {}),
    mesh: isObject(get(shown, "mesh")) ? { reached: get(shown, "mesh").reached ?? null } : null,
  };
}

/// What a window of a kept row says as it goes out: its refills in words, made of its `resetsAt` and now alone (present.ts
/// refillsOf), nothing else of it walked.
function windowShown(w: J, c: present.Clock): J {
  const { resetsAt, ...rest } = w;
  return { ...rest, ...present.rowRefillsOf(resetsAt, w.left, c.now) };
}

/// Where a row's chat came from, for one from a connect (`connect`): its mark's kind and its words (Slack · team ·
/// #channel; 飞书 · tenant · group; Comma · Group). Null for one that came from none. (Both makers of a row: #chatRow,
/// #listRow.)
function originOf(connect: J, origin: J): { originKind: string; originText: string } | null {
  if (connect === undefined || connect === null) return null;
  const o = origin ?? null;
  const text = (k: string) => (typeof get(o, k) === "string" && o[k] !== "" ? (o[k] as string) : null);
  const channelName = text("channelName");
  // A Feishu chat's: its group by name, no #.
  const feishu = text("surface")?.startsWith("feishu:") === true || format.isFeishuChat(text("channel") ?? "");
  // A Comma Task's: Comma and the Group, no place (a Task is not in a channel).
  const comma = text("surface")?.startsWith("comma:") === true;
  // A group connect's: its conversation by name (a group's, a private chat's other member's), no #.
  const group = text("surface")?.startsWith("group:") === true;
  const place = comma || (text("channel") === null && channelName === null) ? null : format.placeName(text("surface") ?? "slack", text("channel") ?? "", channelName ?? "");
  return {
    originKind: comma ? "comma" : group ? "group" : feishu ? "feishu" : "slack",
    originText: [comma ? "Comma" : group ? t("core-views.group") : feishu ? t("core-views.feishu") : "Slack", text("teamName"), place].filter((x) => x !== null).join(" · "),
  };
}

/// What a row says of being archived, of `stood` (its record with its card and mark as decisions.presentRow says them):
/// kept by the viewer (`kept`); archived with one tap whenever nothing is left in it (`archivable`); offered to archive
/// (faded) as the viewer's `archiveHint` says (`settled`). Only what is so. (Both makers of a row.)
function archivingOf(stood: J, hint: ArchiveHint): J {
  const out: J = {};
  if (get(stood, "archiveReminderDismissed") === true) out.kept = true;
  if (present.archivable(stood)) {
    out.archivable = true;
    if (present.offered(stood, hint)) out.settled = true;
  }
  return out;
}

/// A row's state line (present.rowStateLine) as its fields: its words, the message they are about, what leads them and
/// what follows. Only what it says. (Both makers of a row.)
function stateLineOf(line: ReturnType<typeof present.rowStateLine>): J {
  const out: J = {};
  if (line === null) return out;
  out.stateText = line[0];
  if (line[1] !== null) out.stateAbout = line[1];
  const lead = line[3];
  if (lead !== null) {
    out.stateLead = lead.kind;
    if (lead.text !== undefined) out.stateLeadText = lead.text;
    out.stateRest = lead.rest;
  }
  return out;
}

/// What a station's list rows are made with besides their records (#listRow), and the key they are kept by.
type Around = { s: StationInfo; mark: { emoji: string | null; icon: string | null } | null; me: J; slackUsers: string[]; members: J[]; hint: ArchiveHint; gone: readonly string[]; key: string };

/// What a list read first (#head) that is a row kept beside its record, not its record: by itself (#chats `keptRow`).
const headKept = new WeakMap<object, HeadRow>();
/// A row kept beside its record as a list's window read it (#window), the same object while the row is the one kept:
/// what the list made of it before is taken again (keptBetween).
const headsOf = new WeakMap<object, HeadRow>();
function headOf(station: string, id: string, pinnedAt: number | null, row: ListRow): HeadRow {
  let h = headsOf.get(row);
  if (h === undefined || h.station !== station || h.id !== id || h.pinnedAt !== pinnedAt) {
    h = { station, id, pinnedAt, row, record: undefined };
    headsOf.set(row, h);
    headKept.set(h, h);
    keptWholes.add(row.whole);
  }
  return h;
}
/// Rows kept beside their records as a list read them (#head): what is shown of each is read of it.
const keptWholes = new WeakSet<object>();

/// A list's item as it goes out: its row, made now if it was not yet.
const madeRow = (item: J): J => (isObject(item) ? unmade.get(item)?.() : undefined) ?? item;
/// A list's day with its first `n` rows made (`madeRow`), kept by the day while it is asked the same `n`: a day all of
/// whose rows were made is itself, as it was before rows were made late.
const madeDays = new WeakMap<object, { n: number; day: J }>();
function madeDay(d: J, n: number): J {
  const kept = madeDays.get(d);
  if (kept !== undefined && kept.n === n) return kept.day;
  const items = arr(get(d, "items"));
  const rows = items.slice(0, n).map(madeRow);
  const day = n === items.length && rows.every((r, i) => r === items[i]) ? d : { ...d, items: rows };
  madeDays.set(d, { n, day });
  // (a day made is itself made, each of its `n` rows: asked again, it is taken as it is)
  if (day !== d) madeDays.set(day, { n, day });
  return day;
}

/// What a chat list is made of that no station's link says (Views #chatsMade): its stations, its days, how many more it
/// has and how many in all, which stations' rows run and how many rows do, the stations not read yet, and each station's
/// rows read (`ok`) or failed; or, its stations not known, what the workspace says (`value`).
type ChatsMade = { value: Value | undefined } | { stations: StationInfo[]; me: J; days: J[]; more: number; total: number; running: Set<string>; runningRows: number; unread: string[]; reads: Map<string, "ok" | { err: J }> };
/// How many lists' #chatsMade are kept (those shown, a rail's count, a search's whole list, and the last ones left).
const CHATS_MADE_KEPT = 8;

/// A chat list's key among the windows (Views `chatsWindow`): its topic's params, said or left to their defaults.
/// Which chats a list is of: those shown (`visible`), those hidden, both (`all`), or both and those an agent leads too
/// (`found`: a search typed into, the one way to them besides their opener's info; the user, 2026-11-17).
type Visibility = "visible" | "hidden" | "all" | "found";
const windowKey = (list: Topic): string => JSON.stringify([list.scope, list.mine === true, list.watching === true, list.hidden === true]);

/// The list with its first `window` rows, in their days, and how many more it has (`more`): what a page shows of it,
/// its window raised as it is scrolled to the rest (a list of 1400 chats went whole as the app opened, 2026-11-08).
/// What the core works out of the list (its marks, its search, its cards) is of the whole of it (`wholeRows`). Only the
/// rows it gives are made (`madeRow`).
function firstRows(chats: J, window: number): J {
  let left = window;
  let more = 0;
  const was = arr(get(chats, "days"));
  const days: J[] = [];
  for (const d of was) {
    const items = arr(get(d, "items"));
    if (left <= 0) {
      more += items.length;
      continue;
    }
    const n = Math.min(left, items.length);
    days.push(madeDay(d, n));
    more += items.length - n;
    left -= n;
  }
  if (more > 0) return { ...chats, days, more };
  return days.every((d, i) => d === was[i]) ? chats : { ...chats, days };
}

/// The whole list with every row made: what reads the list besides a page (a search, the `@` menu, a share's choice).
/// The chats' rail card reads the list as it is: it counts by each row's `state` alone.
const wholeRows = (chats: J): J => firstRows(chats, Infinity);

/// What a station's row reads of its overview (OverviewRow), of what the database keeps of it beside it
/// (`station_part.row`: db/schema.ts overviewRowOf, those four as the overview has them): its row is made again only as
/// these change, not with each of its profiles' quota or its decisions.
const rowOf = (o: J): J => ({ viewer: o.viewer, counts: o.counts, ...(o.disk != null ? { disk: o.disk } : {}), ...(o.drive != null ? { drive: o.drive } : {}) });

/// The id of what judges whether this core can read a station's overview, its verdicts kept by it (db/kept.ts
/// KEPT.overviewFit): how an overview is judged (its `making`: `unreadable`, decorated, then put through `Overview`;
/// another whenever what decorating one makes could fit otherwise with the shapes as they are) and the `Overview` shape's as declared, with every shape it reaches (conform.ts
/// shapeKey). Made once, as it is first needed (0.6 ms in Node for its 17.7 KB). Not the app's build: the core does not
/// know it until the device tells it, a development build keeps one through many changes, and a new build that changed
/// no shape keeps its verdicts.
let overviewFit: string | null = null;
export const OVERVIEW_FIT = (): string => (overviewFit ??= `${KEPT.overviewFit.making}.${shapeKey("Overview")}`);

/// Whether a station's versions offer the 测试版 switch.
export function betaOffered(overview: J, accountInBeta: () => boolean): boolean {
  const station = arr(get(overview, "updates")).find((v) => get(v, "id") === "station");
  const channel = get(station, "channel");
  if (channel === "beta") return true;
  if (typeof channel === "string") return accountInBeta();
  return false;
}

/// The session keys taking part in a thread.
export function members(thread: J): string[] {
  return arr(get(thread, "sessions")).flatMap((m) => (typeof get(m, "session") === "string" ? [m.session] : []));
}


/// Whether a message is a letter: what two chats' agents wrote each other (session_send), as its station marked it
/// (`letter`: which way, and the other chat); from a station before that, one another chat's agent wrote to this chat,
/// headed `来自 …：`, by an agent that is not one of this chat's (`keys`). The first message of a chat such an agent opened
/// is not: it is what the chat is about.
export function isLetter(message: J, keys: ReadonlySet<string>): boolean {
  if (isObject(message.letter)) return true;
  if (message.authorKind !== "agent" || keys.has(str(message.author) ?? "")) return false;
  const sent = sentHead(str(message.text) ?? "");
  return sent !== null && !sent.opened;
}

/// Which way a letter (isLetter) went and the other chat, as its station marked it; from a station before that, coming
/// in from the chat its heading names.
export function letterWay(message: J): { way: "in" | "out"; title: string; link: string | null } {
  const marked = message.letter;
  if (isObject(marked) && typeof marked.title === "string") {
    return { way: marked.way === "out" ? "out" : "in", title: marked.title, link: str(marked.link) };
  }
  const sent = sentHead(str(message.text) ?? "");
  return { way: "in", title: sent?.title ?? "", link: sent?.link ?? null };
}

/// A letter's words without the heading its station wrote (`来自 …：`, `发给 …：`): the page says which chat.
export function letterWords(text: string): string {
  const at = text.indexOf("\n\n");
  return at < 0 ? text : text.slice(at + 2);
}

/// A chat's letters as their page shows them (`chatLetters`): by the other chat, the one written with last first, each
/// with its letters both ways in the order written (`way`).
export function lettersByChat(letters: { message: J; way: "in" | "out"; title: string; link: string | null }[]): J[] {
  const chats = new Map<string, { title: string; link: string | null; letters: J[]; last: number }>();
  for (const l of letters) {
    const key = l.link ?? `\u0000${l.title}`;
    const was = chats.get(key);
    const letter = { ...l.message, way: l.way };
    // (by when written: letters from before their own log are entries, numbered among the chat's, those of it in it)
    const at = u64(l.message.createdAt) ?? 0;
    chats.set(key, was === undefined ? { title: l.title, link: l.link, letters: [letter], last: at } : { ...was, letters: [...was.letters, letter], last: Math.max(was.last, at) });
  }
  return [...chats.values()].sort((a, b) => b.last - a.last).map(({ title, link, letters }) => {
    const last = letters.at(-1)!;
    // In brief, as a row of the page's list has it: the last letter's words on a line, said by this chat's agent when
    // it went out (one coming in is the row's own chat's).
    const words = format.plainText(str(last.text) ?? "").replace(/\s+/g, " ").trim();
    const said = last.way === "out" ? t("core-views.letters.out", { name: str(get(last.by, "name")) ?? "", text: words }) : words;
    return { key: link ?? title, title, link, letters, last: said, lastActiveAt: u64(last.createdAt) ?? 0 };
  });
}

/// A failure notice that may fold with the same said next to it: one line, no install, no run change.
function foldable(m: J): boolean {
  return m.system === true && isObject(m.notice) && m.notice.failed === true && m.install === undefined && m.notice.short === undefined && m.notice.lines === undefined;
}

/// What `foldNotices` made of a run, by its first message: the run it was made of, the same objects, and what it made.
const foldMade = new WeakMap<object, { run: J[]; out: J }>();

/// still.fail's failures said in the same words one after another, folded into one (the user, 2026-11-16: eleven
/// 与模型服务的连接中断 filled the screen): the first's `seq` and `ts`, so its row stays the one it was as more come,
/// with how many (`count`) and the last's `seq` (`lastSeq`), what is acted on and read up to; the last's time, failure
/// in words (`detail`) and what may be done of it. Their details may differ (another request, another error): what is
/// shown closed is the same. Not across what was sent elsewhere after one of them (`after`: the seqs it follows).
export function foldNotices(messages: J[], after?: ReadonlySet<number>): J[] {
  let folded: J[] | null = null;
  for (let i = 0; i < messages.length;) {
    const first = messages[i]!;
    let j = i + 1;
    if (foldable(first)) {
      const words = first.notice.words;
      const profile = str(first.profile) ?? "";
      while (j < messages.length && foldable(messages[j]!) && messages[j]!.notice.words === words && (str(messages[j]!.profile) ?? "") === profile && !(after?.has(u64(messages[j - 1]!.seq) ?? -1) ?? false)) j++;
    }
    if (j - i < 2) {
      if (folded !== null) folded.push(first);
      i = j;
      continue;
    }
    folded ??= messages.slice(0, i);
    const run = messages.slice(i, j);
    const was = foldMade.get(first);
    if (was !== undefined && was.run.length === run.length && was.run.every((m, k) => m === run[k])) folded.push(was.out);
    else {
      const last = run[run.length - 1]!;
      const notice: J = { ...first.notice, count: run.length };
      const lastSeq = u64(last.seq);
      if (lastSeq !== null) notice.lastSeq = lastSeq;
      delete notice.detail;
      for (let k = run.length - 1; k >= 0; k--) {
        const detail = str(run[k]!.notice.detail);
        if (detail !== null && detail !== "") {
          notice.detail = detail;
          break;
        }
      }
      for (const mark of ["retrySession", "againSession", "reassignSession"]) {
        delete notice[mark];
        for (let k = run.length - 1; k >= 0; k--) {
          const v = run[k]!.notice[mark];
          if (v !== undefined) {
            notice[mark] = v;
            break;
          }
        }
      }
      const out: J = { ...first, notice };
      if (last.createdAt !== undefined) out.createdAt = last.createdAt;
      if (run.some((m) => m.reportable === true)) out.reportable = true;
      if (run.some((m) => m.asked === true)) out.asked = true;
      const shared = sharedValue(out);
      foldMade.set(first, { run, out: shared });
      folded.push(shared);
    }
    i = j;
  }
  return folded ?? messages;
}

/// The last seq a message shown stands for: a folded notice's last (`lastSeq`), else its own.
export function endSeq(m: J): number | null {
  return u64(get(get(m, "notice"), "lastSeq")) ?? u64(get(m, "seq"));
}

/// The notices that a runtime is not installed, said where they matter: under the viewer's message that waits for it
/// (its `blocked`, the last such before them) rather than as notices of their own; once it is installed they are gone
/// (what waited went on). One with none of the viewer's waiting before it stays a notice, with installing it.
export function blockedUnder(messages: J[]): J[] {
  const gone = new Set<number>();
  const blocked = new Map<number, J>();
  for (let i = 0; i < messages.length; i++) {
    const install = messages[i]!.install;
    if (!isObject(install)) continue;
    let j = i - 1;
    while (j >= 0 && !(messages[j]!.mine === true && messages[j]!.waiting === true)) j--;
    if (j >= 0) blocked.set(j, install);
    if (j >= 0 || install.state === "installed") gone.add(i);
  }
  if (gone.size === 0) return messages;
  return messages.flatMap((m, i) => (gone.has(i) ? [] : blocked.has(i) ? [{ ...m, blocked: blocked.get(i) }] : [m]));
}

/// Another chat's title as a letter or a message its agent sent names it: without the mentions its first words began
/// with (as chatTitle has it), else those mentions named.
export function cleanLetterTitle(raw: string, bots: [string, string][], members_: J[]): string {
  const bare = withoutMentions(raw).replace(/\s+/g, " ").trim();
  return bare !== "" ? bare : present.mentions(raw, bots, members_).replace(/^@/, "");
}

/// Who said a Slack message an agent was given: their name, else their Slack id (a bot's mention, `<@U…>`, named as
/// its bot without the `@`), else Slack.
export function elsewhereSenderName(s: Said, bots: [string, string][], members_: J[]): string {
  if (s.who) return present.mentions(s.who, bots, members_);
  if (s.user) return /^<@[A-Z0-9]+>$/.test(s.user) ? present.mentions(s.user, bots, members_).replace(/^@/, "") : present.mentions(s.user, bots, members_);
  return "Slack";
}

/// A message as a chat shows it: whether it is the viewer's, still.fail's own notice, who said it, mentions named.
/// (`profileName`: the name of the profile a notice is about, where it is known: said in its words)
export function shownMessage(message: J, agents: J[], viewer: J, slackUsers: string[], members_: J[], bots: [string, string][], creator: J, profileName: string | null = null): J {
  const m: J = { ...message };
  const card = decisions.ofMessage(message);
  if (card !== null) m.card = decisions.labelAssignee(card, viewer, members_, creator);
  const kind = str(m.authorKind) ?? "";
  const author = str(m.author) ?? "";
  const saidName = str(m.authorName) || null;
  m.mine = kind === "person" && present.isViewer(viewer, author, slackUsers);
  m.system = isStationAuthor(kind);
  if (kind === "agent") {
    const agent = agents.find((a) => get(get(a, "session"), "key") === author);
    const session = agent ? agent.session : undefined;
    const identity = m.agentIdentity ?? null;
    const model = str(get(identity, "model"));
    const sent = agent === undefined ? sentFrom(str(m.text) ?? "") : null;
    if (sent !== null) {
      const [raw, link, rest] = sent;
      const title = cleanLetterTitle(raw, bots, members_);
      m.text = rest;
      m.by = { name: title, from: link, maker: model !== null ? present.maker(model) : null };
    } else {
      // Before its session is read: the model and runtime the station gave with the message.
      const said = str(m.authorModel);
      const runtime = str(get(identity, "runtime")) ?? str(m.authorRuntime) ?? get(session, "runtime") ?? null;
      const otherRuntime = session !== undefined && str(m.authorRuntime) !== null && str(m.authorRuntime) !== str(get(session, "runtime"));
      m.by = {
        name: identity !== null ? format.agentLabel(model, str(get(identity, "effort"))) : otherRuntime ? (saidName ?? (said !== null ? format.agentLabel(said, null) : format.runtimeLabel(runtime))) : (str(get(session, "agentText")) ?? saidName ?? "agent"),
        agent: agent ? author : null,
        maker: identity !== null ? present.maker(model) : otherRuntime || session === undefined ? present.maker(said) : (session.maker ?? null),
        runtime,
      };
    }
  } else if (isStationAuthor(kind)) {
    m.by = { name: brandName() };
    m.notice = noticeOf(str(m.text) ?? "", str(m.profile) !== null, profileName);
    // Its run changed: what changed as the viewer reads it, in place of the station's words.
    const change = runChangeOf(m.change);
    if (change !== null) m.notice = { ...m.notice, ...change };
    delete m.change;
  }
  else {
    const member = members_.find((x) => typeof get(x, "email") === "string" && x.email.toLowerCase() === author.toLowerCase());
    const name = present.memberName(members_, author) ?? saidName ?? (author === "local" ? t("core-views.local_author") : author);
    // A Slack person's own picture, as their Slack shows it; else their workspace account's.
    const picture = str(m.authorPicture) || str(get(member, "picture")) || null;
    m.by = { name, picture };
  }
  if (kind === "person" || kind === "agent") m.text = present.mentions(str(m.text) ?? "", bots, members_);
  return m;
}

import * as brand from "../brand.ts";
import { noticeOf } from "../notice.ts";
import { runChangeOf } from "../run-change.ts";
import { isOwnSurface, isStationAuthor, withoutMentions } from "../titles.ts";
export { noticeOf };
const brandName = () => brand.name();

/// The pictures of the Slack people a session heard, by their Slack id, as the station gives them: those who wrote in its
/// threads (`participants`), and its threads' people and starters; and of its station's bots (`connects`), another
/// agent's words it was given.
function slackPictures(session: J, threads: J[], connects: J[]): Map<string, string> {
  const pictures = new Map<string, string>();
  for (const c of connects) {
    const conn = get(c, "connection");
    const bot = str(get(conn, "botUserId")) ?? str(get(get(conn, "workspace"), "botUserId"));
    const picture = str(get(c, "botImage")) || str(get(get(conn, "workspace"), "botImage"));
    if (bot !== null && picture) pictures.set(bot, picture);
  }
  const people = [...arr(get(session, "participants")), ...threads.flatMap((th) => [...arr(get(th, "people")), get(th, "creator")])];
  for (const p of people) {
    const id = str(get(p, "id"));
    const picture = str(get(p, "picture"));
    if (id === null || picture === null || picture === "" || !id.startsWith("slack:")) continue;
    const user = id.slice(id.lastIndexOf(":") + 1);
    if (!pictures.has(user)) pictures.set(user, picture);
  }
  return pictures;
}

/// The Slack workspaces a station's connects are signed in to, by team: their names and links.
function slackWorkspaces(overview: J): Map<string, format.SlackWorkspace> {
  const workspaces = new Map<string, format.SlackWorkspace>();
  for (const c of arr(get(overview, "connects"))) {
    if (get(c, "kind") === "feishu") {
      const id = str(get(c, "id"));
      if (id !== null) workspaces.set(`feishu:${id}`, { name: str(get(c, "team")) ?? "", url: format.feishuApplink(str(get(get(c, "feishu"), "domain"))) });
      continue;
    }
    const conn = get(c, "connection");
    const s = get(conn, "state");
    const seen = s === "connected" || s === "reconnecting" ? get(conn, "workspace") : undefined;
    const team = str(get(seen, "teamId"));
    if (team === null) continue;
    const name = str(get(seen, "team")) ?? str(get(c, "team")) ?? "";
    const url = str(get(seen, "url")) || null;
    if (!workspaces.has(team)) workspaces.set(team, { name, url });
  }
  return workspaces;
}

/// Whether the viewer added something: its creator's id, or email in any case, is theirs.
function isMine(me: J, creator: J): boolean {
  if (!isObject(creator)) return false;
  const id = get(creator, "id");
  if (id !== undefined && id !== null && id === get(me, "id")) return true;
  const email = (v: J) => (typeof get(v, "email") === "string" && v.email !== "" ? (v.email as string).toLowerCase() : null);
  const mine = email(me);
  return mine !== null && email(creator) === mine;
}

/// A connect's sessions as its page shows them (ConnectView): its latest dozen, the one it delivers into, how many of
/// its run, the ways it could change.
function connectSessions(connect: J, sessions: J[], threads: J[]): J {
  const id = str(get(connect, "id")) ?? "";
  const strOf = (v: J, k: string) => str(get(v, k)) ?? "";
  const at = (v: J) => (typeof get(v, "lastActiveAt") === "number" ? v.lastActiveAt : 0);
  const shown = (s: J) => {
    const c = present.session(s);
    const key = strOf(c, "key");
    const thread = threads.find((th) => arr(get(th, "sessions")).some((m) => get(m, "session") === key));
    c.chat = thread !== undefined ? (get(thread, "id") ?? null) : null;
    return c;
  };
  const boundTo = (s: J) => arr(get(s, "boundTo")).some((c) => c === id);
  const own = sessions.filter((s) => strOf(s, "connect") === id).sort((a, b) => at(b) - at(a)).slice(0, 12).map(shown);
  const running = sessions.filter((s) => (strOf(s, "connect") === id || boundTo(s)) && strOf(s, "process") === "running").length;
  const current = str(get(connect, "session"));
  const bound = sessions.find((s) => current !== null && strOf(s, "key") === current);
  return { sessions: own, bound: bound !== undefined ? shown(bound) : null, running, changes: present.modeChanges(connect, running) };
}

/// The sessions a connect could deliver into instead (ConnectCandidates): its station's of its runtime, the latest
/// first, each its title, how it was made and by which connect, its turns, when it was last active and the other
/// connects it delivers for; and whether it is the one now.
function connectCandidates(connect: J, connects: J[], sessions: J[], clock: present.Clock): J[] {
  const id = str(get(connect, "id")) ?? "";
  const strOf = (v: J, k: string) => str(get(v, k)) ?? "";
  const at = (v: J) => (typeof get(v, "lastActiveAt") === "number" ? v.lastActiveAt : 0);
  const nameOf = (c: string) => {
    const n = strOf(connects.find((x) => strOf(x, "id") === c), "name");
    return n !== "" ? n : c;
  };
  const current = str(get(connect, "session"));
  const runtime = str(get(get(connect, "bind"), "runtime")) ?? "";
  return sessions
    .filter((s) => strOf(s, "runtime") === runtime)
    .sort((a, b) => at(b) - at(a))
    .map((s) => {
      const others = arr(get(s, "boundTo"))
        .filter((x): x is string => typeof x === "string" && x !== id)
        .map(nameOf);
      let description = [
        strOf(s, "scope") === "all" ? t("core-views.connect.single") : t("core-views.connect.from_thread"),
        nameOf(strOf(s, "connect")),
        t("core-views.connect.turns", { n: u64(get(s, "turns")) ?? 0 }),
        format.relativeTime(at(s), clock.now, clock.offsetMin),
      ].join(" · ");
      if (others.length > 0) description += ` · ${t("core-views.connect.also_used", { names: others.join(t("core-views.list_separator")) })}`;
      return { key: strOf(s, "key"), titleText: str(get(present.session(s), "titleText")) ?? "", description, current: strOf(s, "key") === current };
    });
}

/// What the connects' list reads of a station's overview (`undefined`: not read): its connects, the Slack apps not
/// taken yet, whether it has a profile (`profiled`, none known while it cannot be read), why it could not be read
/// (`err`). Its rows are made again only as these change, not with each quota or decision of its overview.
const connectsPartOf = (v: Value | undefined): J => {
  if (v === undefined) return undefined;
  if ("err" in v) return { err: v.err.message };
  const o = v.ok as J;
  return { connects: arr(get(o, "connects")), slackApps: arr(get(o, "slackApps")), profiled: !isObject(o) || arr(get(o, "profiles")).length > 0 };
};

/// The parts of a station's overview its page asks alone (`stationPart`) that are of its settings (data.ts
/// overviewSettings): made of those alone.
const SETTINGS_PARTS = new Set(["automaticDecisions", "archiving"]);

/// What the views are put together with: the core's store and data, and what the accounts say of a workspace.
export type ViewsEnv = {
  host: Host;
  runner: Runner;
  store: Store;
  data: Data;
  /// The email of the signed-in account that reaches a workspace.
  emailOf: (workspace: string) => string | null;
  /// Whether that account is in the beta.
  betaOf: (workspace: string) => boolean;
  /// That account's sub; none where not given.
  subOf?: (workspace: string) => string | null;
  /// Other workspaces owned by the same signed-in account as `workspace` (for cross-workspace vault reactivity).
  otherWorkspacesOf?: (workspace: string) => string[];
  /// What still.fail calls the relay at a host.
  relayName: (host: string) => string | null;
  /// Every workspace the signed-in accounts are in (xshare.ts); none where not given.
  places?: () => xshare.Place[];
  /// A chat's sharing asked here (`chat.xshare`) and not answered yet.
  xshareAsked?: (station: string, session: string) => xshare.Asked | undefined;
  /// The name of the home workspace of a station a workspace joined, when the viewer is in it (memberships.ts).
  homeName?: (workspace: string, id: string) => string | null;
  /// Safe mode in a workspace as its stations' rows say it (views/lock.ts `stationsGuard`); none where not given.
  guard?: (workspace: string) => { protects: (id: string) => boolean; can: () => boolean } | null;
  /// Whether a workspace's notices are heard of on this device (`notify.set` `workspaces`); every one where not given.
  heard?: (workspace: string) => boolean;
  /// A topic a view watches shown again (its owner asked to bring it up to date, store.ts `resume`).
  resume?: (topic: Topic) => void;
  /// A topic a view watches became idle (its owner may cancel in-flight work without discarding cached state).
  idle?: (topic: Topic) => void;
  /// How much of a chat is on the device (station/topics.ts `held`); none where not given.
  held?: (station: string, thread: number) => { held: number; of: number; whole: boolean };
  /// A login of a station's as its station last told it (station/machine-logins.ts): the program it is to (gh, gcloud)
  /// and, under way, when it runs out of time; null where it has not been told. What 待处理 says of a login's card.
  loginOf?: (station: string, id: string) => { name: string; ends: number | null } | null;
  /// How agents' requests about vault items are answered on this device, from the vault as the core holds it
  /// (views/vault.ts askAnswers): each `{answer, lasts?}`, in the order asked.
  vaultAnswers?: (workspace: string, asks: VaultAskOf[]) => J[];
  /// How a workspace's members' devices reach its stations (views/ways.ts), from `/v1/me`; undefined while no account's
  /// is held.
  ways?: (workspace: string) => WaysView | undefined;
  /// Whether a station's topic with no value yet waits on the station for what it shows (station/topics.ts `waits`);
  /// none does where not given.
  waits?: (topic: Topic) => boolean;
  /// Local reconnect diagnostics of a station's link (`station/link.ts` `Link.diag`).
  linkDiag?: (station: string) => LinkDiag | null;
  /// Local mesh dial diagnostics of a station (`mesh.ts` `Mesh.diag`).
  peerDiag?: (station: string) => PeerDiag | null;
  /// Whether still.fail cloud is currently unreachable (`status.cloudDown`).
  cloudDown?: () => boolean;
};

/// An agent's request about a vault item a card names (`card.vault`), and whether it is one to keep a secret.
export type VaultAskOf = { request: string; save: boolean; browse?: boolean; crossWs?: string };

/// The request card `card` names and says what it asks (`vaultAsk`); null for any other.
function vaultAskOf(card: J): VaultAskOf | null {
  const request = typeof get(card, "vault") === "string" ? (card.vault as string) : null;
  const ask = get(card, "vaultAsk");
  if (request === null || request === "" || !isObject(ask)) return null;
  const crossWs = str(get(get(ask, "cross"), "workspace"));
  // (a request to rename an item is answered as one to keep: written into the vault, by a device set up)
  return {
    request,
    save: get(ask, "save") !== undefined || get(ask, "describe") !== undefined || get(ask, "remove") !== undefined,
    ...(get(ask, "browse") !== undefined ? { browse: true } : {}),
    ...(crossWs !== null && crossWs !== "" ? { crossWs } : {}),
  };
}

/// The views' environment in a core.
export function envOf(core: Inner): ViewsEnv {
  const owner = (workspace: string) => core.workspaces.of(workspace).owner;
  return {
    host: core.host,
    runner: core.runner,
    store: core.store,
    data: core.data,
    waits: (topic) => core.stationTopics.waits(topic),
    linkDiag: (station) => core.stations.link(station)?.diag ?? null,
    peerDiag: (station) => {
      try {
        return core.stations.wire.diag?.(StationAddr.parse(station)) ?? null;
      } catch {
        return null;
      }
    },
    cloudDown: () => core.status.cloudDown(),
    held: (station, thread) => core.stationTopics.held(station, thread),
    loginOf: (station, id) => {
      const l = logins.held(core.stations.link(station)).logins.find((x) => x.id === id);
      if (!l || typeof l.name !== "string" || l.name === "") return null;
      const active = l.endedAt === undefined || l.endedAt === null;
      return { name: l.name, ends: active && typeof l.expiresAt === "number" && l.expiresAt > 0 ? l.expiresAt : null };
    },
    emailOf: (workspace) => {
      const sub = owner(workspace);
      return sub === null ? null : (core.accounts.list().find((a) => a.sub === sub)?.email ?? null);
    },
    betaOf: (workspace) => {
      const sub = owner(workspace);
      return sub !== null && get(get(core.data.record("me", sub), "user"), "beta") === true;
    },
    otherWorkspacesOf: (workspace) => {
      const out: string[] = [];
      for (const [otherWs] of core.workspaces.owned()) {
        if (otherWs !== workspace) out.push(otherWs);
      }
      return out;
    },
    subOf: owner,
    places: () => xshare.places(core),
    resume: (topic) => core.router.resume(topic),
    idle: (topic) => core.router.idle(topic),
    xshareAsked: (station, session) => xshare.asked(core, station, session),
    homeName: (workspace, id) => memberships.homeName(core, workspace, id),
    guard: (workspace) => stationsGuard(core, workspace),
    vaultAnswers: (workspace, asks) => askAnswers(core, workspace, asks),
    heard: (workspace) => core.attention?.attend.heard(workspace) ?? true,
    ways: (workspace) => {
      for (const account of core.accounts.list()) {
        const me = core.data.record("me", account.sub);
        const relays = arr(get(me, "relay_urls")).filter((u): u is string => typeof u === "string");
        if (relays.length === 0) continue;
        const names = get(me, "relay_names");
        const by = Object.fromEntries((keptWays(core, workspace)?.relays ?? []).flatMap((r) => (r.by ? [[r.url, r.by]] : [])));
        return waysView(relays, isObject(names) ? names : {}, core.cloudSync.workspaceRelays(workspace), core.cloudSync.workspaceOff(workspace), by);
      }
      return undefined;
    },
    relayName: (host) => {
      for (const account of core.accounts.list()) {
        const names = get(core.data.record("me", account.sub), "relay_names");
        if (!isObject(names)) continue;
        for (const [url, name] of Object.entries(names)) {
          try {
            if (new URL(url).host === host && typeof name === "string") return name;
          } catch {
            // Not an address.
          }
        }
      }
      return null;
    },
  };
}

/// What people said in a chat as far as it is on the device (`#peopleSaid`), as read at its log's change `rev`: their
/// messages merged, by seq (`order`, in order), and the entries that edit each message held, by the message.
/// `changed` counts the times what it holds changed (a message come, gone or edited), so what is made of it is made
/// again only then.
type PeopleSaid = { rev: number; changed: number; messages: Map<number, J>; order: number[]; edits: Map<number, number[]> };

/// A chat's outline as last made (`#chatOutline`): of what, and its days.
type OutlineIndex = { kept: PeopleSaid; changed: number; mine: unknown; offset: number; today: number; days: J[]; count: number; others: boolean };

/// How long a row of a chat's outline says what was said (`chat.outline.rows` `words`), in columns at most (a character
/// from U+1100 on, Chinese, Japanese, Korean, an emoji, two; then `…`): one line of its panel (420 pt less its margins,
/// at 13 pt: some 30 Chinese characters, 60 Latin ones), a little over so it ends at the panel's edge. So its words are
/// a few bytes a column at most as UTF-8 (a line of Chinese 99), and a hundred rows of long ones stay under 32 KB as JSON.
const OUTLINE_WORDS = 64;

/// A local day as a chat's outline knows it (`OutlineDay` `date`): 2026-11-09.
function outlineDate(ms: number, offsetMin: number): string {
  const [y, m, d] = format.local(ms, offsetMin);
  return `${String(y).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

/// What a person said of what they quoted, on one line, where a message is only quotes with their comments (the
/// composer's `comment`: its words are there, its own text empty): the first comment that has words, else "".
function quoteComment(message: J): string {
  for (const q of arr(message.quotes)) {
    const words = (str(get(q, "comment")) ?? "").replace(/\s+/g, " ").trim();
    if (words !== "") return words;
  }
  return "";
}

/// Words cut to `max` columns (`OUTLINE_WORDS`: a character from U+1100 on two), `…` after where cut.
function cutWords(words: string, max: number): string {
  let columns = 0;
  let at = 0;
  for (const c of words) {
    columns += c.codePointAt(0)! >= 0x1100 ? 2 : 1;
    if (columns > max) return `${words.slice(0, at)}…`;
    at += c.length;
  }
  return words;
}

/// How much of a line of a message found goes before the words found in a chat's outline (`chat.outline.find`), at
/// most; the whole of it is then cut as a row's words are (`OUTLINE_WORDS` columns, `…` where the line goes on): one
/// line, as the app shows it.
/// (`chat.find`'s own excerpt keeps refs.ts's lengths.)
const SNIPPET_LEAD = 12;

/// The views a core shows, as an owner of their topics.
export class Views implements Owner {
  /// The list rows made from each record (with what else they were made with), so a row whose record did not change
  /// is not made again (rule 7). Kept as long as the record is.
  readonly #rowsMade = new WeakMap<object, { sig: string; list: string; row: J }>();
  /// The key each station's rows are kept by (listRowKey), with what it was made of: made again only as one of those is
  /// another (the members, the station's part as read, the same objects while they are the same).
  readonly #listKeys = new Map<string, { of: unknown[]; key: string }>();
  /// What each station's rows are made with besides their records as they are written (#aroundOf), with what it was
  /// made of.
  readonly #arounds = new Map<string, { of: unknown[]; around: Around | null }>();
  /// Rows a list made as it read them, to be kept beside their records once what pages wait for is out (#keepMade).
  #toKeep: { station: string; record: J; key: string; whole: J | null }[] = [];
  /// Each record's whole row (`chatRow`, #wholeOf) as #rowsMade keeps its list's row; and a list's row given what only
  /// the whole one says (#wholeFor), by the list's row, while that whole row is the same.
  readonly #wholeMade = new WeakMap<object, { sig: string; row: J }>();
  readonly #wholeGiven = new WeakMap<object, { whole: J; out: J }>();
  /// A chat's messages as shown (`#shown`), by the message each was made of, and what else it was made with.
  readonly #shownMade = new WeakMap<object, { by: unknown; waiting: boolean; out: J }>();
  /// Each list's rows as its stations' records made them last time, by the list (`#chats`).
  readonly #chatsKept = new Map<string, Map<string, { listed: J[]; made: (J | null)[]; sig: string; failedKey: string }>>();
  /// Each list's rows and days as #chatsMade makes them, by the list and its window: a computed that reads no link.
  readonly #chatsMadeKept = new Map<string, Derived<ChatsMade>>();
  /// Each list's days as they were last made, from which rows (`#daysOf`).
  readonly #daysKept = new Map<string, { rows: J[]; days: J[]; today: number; offset: number }>();
  /// A row's local day by its time (`#days`), while the zone's offset now is `#daysZone`.
  #dayOf = new WeakMap<object, [number, number]>();
  #daysZone: number | null = null;
  /// What parts of a view were last made with, by the view (`#steady`).
  readonly #steadied = new Map<string, unknown>();
  readonly #core: ViewsEnv;
  readonly local: Local;
  /// The device's data, as the views read it (archive.ts).
  get data(): Data {
    return this.#core.data;
  }
  /// Per live view, the topics it watches.
  readonly #views = new Map<string, { topic: Topic; watches: Map<string, Watch>; opening: boolean }>();
  /// Each chat's first window as its page told it (`chat.window`), by station, thread and session.
  readonly #chatWindows = new Map<string, number>();
  /// The latest chats' things read (`#things`), by station and thread, with what they were read from.
  readonly #thingsKept = new Map<string, Derived<{ messages: J[]; things: ReturnType<typeof thingsOf>; whole: boolean; title: unknown } | null>>();
  /// Names of the sessions shown in live rates, recomputed only when the underlying chat or session changes.
  readonly #rateNames = new Map<string, Derived<{ title: string | null; model: string | null; chat: string | null }>>();
  /// A chat's outline's rows (`outlineRows`), by the message each was made of, and what else it was made with.
  readonly #outlineMade = new WeakMap<object, { by: unknown; offset: number; item: J }>();
  /// A chat's outline's message's day and whether it is the viewer's (`#chatOutline`), by the message, and what else
  /// it was made with.
  readonly #outlineDay = new WeakMap<object, { mine: unknown; offset: number; date: string; ms: number | null; viewer: boolean }>();
  /// The chats' outlines last made (`#chatOutline`), by station and thread.
  readonly #outlineKept = new Map<string, OutlineIndex>();
  /// What people said in the chats whose outlines were made lately (`#peopleSaid`), by station and thread.
  readonly #peopleKept = new Map<string, PeopleSaid>();
  readonly #updateNoticesOpen = new Set<string>();
  /// The threads chats copy what is sent from here to (`ccOn`), by `<station> <thread> <to>`.
  readonly #cc = new Set<string>();
  /// When what a view says next changes on its own (a chat's jobs counting seconds, a prompt cache going cold).
  readonly #moments: Moments;
  /// The scopes whose stations' rows are being loaded (the list showed its first screen meanwhile).
  readonly #loading = new Set<string>();
  /// Since when each station up has had no host reading (by address): unanswered that long, it is said to be silent.
  readonly #hostless = new Map<string, number>();
  /// Each station's overview and host reading as the stations' list shows them (and its overview as the profiles' page
  /// reads it), each a computed: made again only as the station said something new, or the overview's times in words
  /// changed (present.ts reads the clock by their grain): a host reading of one station, every few seconds from each,
  /// made every station's anew, the list and the new chat's view after it (50-80 ms a time on a phone, 2026-10-31).
  readonly #stationShown = new Map<string, StationShown>();
  /// Each workspace's mark (views/marks.ts `workspaceMark`), a computed with what of the prefs it reads (`prefsOf`, one
  /// function for each, by which the store keeps that part): made again only as its own rows or that part change. Made
  /// in the one topic that asks for the workspace shown, every workspace's was made anew at every switch (13-20 ms in
  /// Hermes, 2 workspaces of 420 chats, 2026-11-11).
  readonly #marks = new Map<string, Derived<J>>();
  /// What reads how the vault of a workspace answers agents' requests (a chat's cards): made again as it changes.
  readonly #vaultSeen = new Marks();
  /// What reads what the views keep of their own (an update notice open, copying to a thread, a scope's rows loaded, a
  /// list's window).
  readonly #seen = new Marks();
  /// How many rows of each chat list go out (`chats.window`), by the list (windowKey): its own, kept while its topic
  /// is (let go of, until it is evicted), so a list opened again later starts from what it is told then.
  readonly #windows = new Map<string, number>();

  constructor(core: ViewsEnv) {
    this.#core = core;
    this.#moments = new Moments(() => core.host.nowMs(), core.runner);
    this.local = new Local(core.data, () => core.host.nowMs());
    this.local.load();
    // Whether this core can read an overview, judged as it is written (#stationShownOf `judge`) and kept beside it:
    // `stations` reads the verdict, not the overview.
    // (its shapes' id made as it is first read, not at the start)
    core.data.makes(KEPT.overviewFit, {
      key: () => OVERVIEW_FIT(),
      make: ([station], o) => {
        try {
          return this.#stationShownOf(station).judge(o);
        } catch {
          // (not judged: judged again as it is read)
          return null;
        }
      },
    });
    // A chat list's row kept beside its record (`chat_row`), made again as that is written once a list read it: a list
    // reads it, not the record.
    core.data.makes(KEPT.listRow, {
      key: ([station]) => untracked(() => this.#aroundOf(station)?.key ?? null),
      make: ([station], record) => untracked(() => this.#keptMade(station, record)),
      taken: listRowTaken,
    });
    // A station's accounts' rows kept beside its overview's part (`profile_row`), made again as that is written once a
    // list read them: the list reads them, not the part, and decorates no profile.
    core.data.makes(KEPT.profileRow, {
      key: () => untracked(profileRowKey),
      make: ([station], profiled) => untracked(() => this.#profileRowsMade(station, profiled)),
      taken: deepFreeze,
    });
  }

  owns(topic: Topic): boolean {
    return VIEW_TOPICS.has(topic.topic);
  }

  // ── what the views watch ──

  start(view: Topic): void {
    // A chat's first value waits for what it is made of alone: what only keeps it current as it shows (the chats its
    // messages link to, as their stations' lists have them) is watched once that value has gone out (`opened`). Found
    // in all its messages as it started and again as it was made, that was 2.3-5.5 ms in Hermes before a chat switched
    // to could go out (a Mac Studio, 2026-11-12). What it is made of is still worked out each time it is made, as
    // before: a chat asked by its session, or one whose thread the device has not got yet, learns its thread and its
    // agents after it started, and has no value to go out till they are watched.
    const opening = view.topic === "chat";
    this.#views.set(topicKey(view), { topic: view, watches: new Map(), opening });
    this.#sync(view);
    this.#core.store.invalidate(view);
  }

  /// A view's first value went out: what it keeps watched from now on (`start`).
  opened(view: Topic): void {
    const live = this.#views.get(topicKey(view));
    if (live === undefined || !live.opening) return;
    live.opening = false;
    untracked(() => this.#sync(view));
  }

  /// Shown again while it was kept: a search asks its stations again (what they hold changes; station/sync.ts
  /// `searchShown`), what they found before shown meanwhile.
  resume(view: Topic): void {
    if (view.topic !== "search" && view.topic !== "archive" && view.topic !== "chatSubchats") return;
    const live = this.#views.get(topicKey(view));
    for (const key of live?.watches.keys() ?? []) {
      const topic = JSON.parse(key) as Topic;
      if (topic.topic === "stationSearch") this.#core.resume?.(topic);
    }
  }

  idle(view: Topic): void {
    if (view.topic !== "search" && view.topic !== "archive" && view.topic !== "chatSubchats") return;
    const live = this.#views.get(topicKey(view));
    for (const key of live?.watches.keys() ?? []) {
      const topic = JSON.parse(key) as Topic;
      if (topic.topic === "stationSearch" && !this.searchShownNow(topic)) this.#core.idle?.(topic);
    }
  }

  /// Whether a station's search (`stationSearch`) is subscribed to, or of a search a UI subscribes to now: one let go is kept a while
  /// (EVICT_AFTER_MS) with its watches, and is not asked again for them (each words typed was one).
  searchShownNow(topic: Topic): boolean {
    if (this.#core.store.subscribed(topic)) return true;
    const key = topicKey(topic);
    for (const live of this.#views.values()) {
      if ((live.topic.topic === "search" || live.topic.topic === "archive" || live.topic.topic === "chatSubchats") && live.watches.has(key) && this.#core.store.subscribed(live.topic)) return true;
    }
    return false;
  }

  stop(view: Topic): void {
    const key = topicKey(view);
    const live = this.#views.get(key);
    this.#views.delete(key);
    // (nothing holds the list any more: told again as it is asked again)
    if (view.topic === "chats") this.#windows.delete(windowKey(view));
    // (nor the chat: its page tells its first window again before it asks it again)
    if (view.topic === "chat") this.#chatWindows.delete(chatWindowKey(String(view.station), u64(view.thread), str(view.session) ?? null));
    if (view.topic === "chat" || view.topic === "chatOutline") {
      const st = String(view.station);
      for (const k of [...this.#steadied.keys()]) {
        if (k.startsWith(`shown\u0001${st}\u0001`) || k.startsWith(`outline\u0001${st}\u0001`) || k.startsWith(`outlineRows\u0001${st}\u0001`)) this.#steadied.delete(k);
      }
    }
    for (const w of live?.watches.values() ?? []) w.drop();
  }

  // ── agents' requests about vault items, on their cards ──

  /// The vault of workspace `ws` (null: any) changed as this core holds it (views/vault.ts): what its cards say is
  /// made again.
  vaultChanged(ws: string | null): void {
    if (ws === null) this.#vaultSeen.touch();
    else this.#vaultSeen.touch(ws);
  }

  /// Card `card` of a message in workspace `ws` as the clients draw it, an agent's request about a vault item it names
  /// answered: how it is answered on this device (`vaultAsk.answer`, `lasts`: the vault as the core holds it, so the
  /// card is whole with its message and no client asks for more), and, decided here, how it went before its station
  /// says so (`status`, `scope`). Any other card as it is.
  #vaultCard(card: J, ws: string): J {
    const one = vaultAskOf(card);
    if (one === null) return card;
    this.#vaultSeen.read(ws);
    if (one.browse) {
      for (const otherWs of this.#core.otherWorkspacesOf?.(ws) ?? []) this.#vaultSeen.read(otherWs);
    } else if (one.crossWs !== undefined) {
      this.#vaultSeen.read(one.crossWs);
    }
    const shown: J = { ...card.vaultAsk, ...(this.#core.vaultAnswers?.(ws, [one])[0] ?? {}) };
    const done = this.local.vaultOutcome(one.request);
    if (done !== undefined && shown.status === undefined) {
      shown.status = done.status;
      if (done.scope !== undefined) shown.scope = done.scope;
      if (done.timeout !== undefined) { shown.approvedTimeoutKind = done.timeout.kind; shown.approvedTimeoutSeconds = done.timeout.seconds; }
      if (done.browse !== undefined) shown.browse = { ...(isObject(shown.browse) ? shown.browse : {}), ...done.browse };
    }
    return { ...card, vaultAsk: shown };
  }

  /// A chat's view (`out`) with its messages' vault cards answered (`#vaultCard`).
  #vaultCards<V extends Value | undefined>(view: Topic, out: V): V {
    if (out === undefined || !("ok" in out) || !isObject(out.ok) || !Array.isArray(out.ok.messages)) return out;
    const ws = ofAddress(String(view.station ?? ""));
    const cards = (out.ok.messages as J[]).flatMap((m): [string, J][] => (isObject(m) && vaultAskOf(get(m, "card")) !== null ? [[ws, m.card]] : []));
    if (cards.length === 0) return out;
    const messages = (out.ok.messages as J[]).map((m) => (isObject(m) && vaultAskOf(get(m, "card")) !== null ? { ...m, card: this.#vaultCard(m.card, ws) } : m));
    return { ...out, ok: { ...(out.ok as J), messages } } as V;
  }

  #live(): Topic[] {
    return [...this.#views.values()].map((v) => v.topic);
  }

  /// The live pages showing a chat: by its thread, or by its agent once the chat is the agent's.
  chatViews(station: string, thread: number): Topic[] {
    return this.#live().filter((view) => {
      if (view.topic !== "chat" || view.station !== station) return false;
      if (view.thread === thread) return true;
      if (typeof view.thread === "number" || typeof view.session !== "string") return false;
      if (view.session.startsWith(PENDING_PREFIX)) return this.local.pendingThread(station, view.session) === thread;
      return this.boundThread(station, view.session) === thread;
    });
  }

  /// A message on its way to a chat: shown in it at once, as `sending`; `after` is the chat's newest entry now.
  outboxAdd(station: string, thread: number, message: J): string {
    const after = u64(get(this.ok({ topic: "thread", station, thread }), "last")) ?? 0;
    return this.local.outboxAdd(station, thread, message, after);
  }

  /// The station has the message as entry `seq` (see Local.outboxSent).
  outboxSent(station: string, thread: number, id: string, seq: number): void {
    this.local.outboxSent(station, thread, id, seq, this.chatViews(station, thread).length > 0);
  }

  #noticeOpen(station: string): boolean {
    this.#seen.read(`notice ${station}`);
    return this.#updateNoticesOpen.has(station);
  }

  updateNoticeOpen(station: string, open: boolean): void {
    if (open) this.#updateNoticesOpen.add(station);
    else this.#updateNoticesOpen.delete(station);
    this.#seen.touch(`notice ${station}`);
  }

  /// Watches what the view needs now and lets go of the rest.
  #sync(view: Topic): void {
    const live = this.#views.get(topicKey(view));
    if (!live) return;
    const wanted = new Map(this.#sources(view, live.opening).map((t) => [topicKey(t), t] as [string, Topic]));
    for (const [key, w] of [...live.watches]) {
      if (!wanted.has(key)) {
        live.watches.delete(key);
        w.drop();
      }
    }
    for (const [key, topic] of wanted) {
      if (live.watches.has(key)) continue;
      // Keep sources prefetched; the values the view actually reads schedule its updates.
      const watch = this.#core.store.watch(topic, () => {});
      // Released meanwhile (a watch's start can stop the view).
      if (this.#views.get(topicKey(view)) !== live) {
        watch.drop();
        return;
      }
      live.watches.set(key, watch);
    }
  }

  /// The topics a view is built from, given what is known now; `opening`, what its first value reads alone (`start`).
  #sources(view: Topic, opening = false): Topic[] {
    const topics: Topic[] = [];
    const station = typeof view.station === "string" ? view.station : "";
    // (and its station's screens, for its bar's way to them)
    if (view.topic === "chat") topics.push({ topic: "prefs" }, { topic: "screens", station });
    let scope: string;
    let perStation: (station: string) => Topic[];
    switch (view.topic) {
      case "chats":
      case "chatSearch":
        scope = (view.scope ?? view.workspace) as string;
        perStation = (s) => [{ topic: "chatRows", station: s }, { topic: "overview", station: s }, { topic: "link", station: s }];
        break;
      case "chatRow":
        // (one chat's row whole: its record is read alone, by its key, not the station's rows; the viewer's workspaces
        // its menu names, the prefs its archive hint is of)
        scope = ofAddress(station);
        perStation = () => [];
        topics.push({ topic: "prefs" }, { topic: "workspaces" });
        break;
      case "search": {
        scope = view.scope as string;
        // With words, what each station finds (views/search.ts).
        const typed = String(view.query ?? "").trim() !== "";
        perStation = (s) => [{ topic: "chatRows", station: s }, { topic: "overview", station: s }, { topic: "link", station: s }, ...(typed ? [stationTopic(s, view)] : [])];
        break;
      }
      case "stations":
      case "stationsWhole":
        scope = view.scope as string;
        perStation = (s) => [{ topic: "link", station: s }, { topic: "overview", station: s }, { topic: "host", station: s }, { topic: "way", station: s }];
        break;
      case "station":
        scope = view.scope as string;
        perStation = (s) => (s === view.station ? [{ topic: "link", station: s }, { topic: "overview", station: s }, { topic: "host", station: s }, { topic: "way", station: s }] : []);
        break;
      case "stationPart":
        scope = view.scope as string;
        perStation = (s) => (s === view.station ? [{ topic: "overview", station: s }] : []);
        break;
      case "stationUpdates":
        // (each station's own software, of what is kept beside its overview: views/station-updates.ts; the versions let be)
        scope = view.scope as string;
        perStation = (s) => [{ topic: "link", station: s }, { topic: "overview", station: s }];
        topics.push({ topic: "prefs" });
        break;
      case "settings":
        scope = view.scope as string;
        perStation = (s) => [{ topic: "link", station: s }, { topic: "overview", station: s }];
        break;
      case "profiles":
      case "profilesWhole":
        scope = view.scope as string;
        perStation = (s) => [{ topic: "link", station: s }, { topic: "overview", station: s }];
        break;
      case "profilesOverview":
        // (and each station's accounts' last hours, read while the overview shows: its `profilePace`)
        scope = view.scope as string;
        perStation = (s) => [{ topic: "link", station: s }, { topic: "overview", station: s }, { topic: "profilePace", station: s }];
        break;
      case "archive":
        scope = view.scope as string;
        perStation = (s) => [{ topic: "archivedRows", station: s }, { topic: "link", station: s }, ...(typeof view.q === "string" && view.q.trim() !== "" ? [archiveSearch(s, view.q)] : [])];
        break;
      case "longJobs":
        scope = view.scope as string;
        // With the sidebar rows of the stations whose chats run tasks there (`#ranFrom`).
        perStation = (s) => [
          { topic: "jobs", station: s },
          { topic: "screens", station: s },
          { topic: "terminals", station: s },
          ...arr(this.ok({ topic: "jobs", station: s })).flatMap((j) => {
            const owner = jobs.remoteOwner(str(get(j, "session")) ?? "");
            return owner === null ? [] : [{ topic: "chatRows", station: owner.station }];
          }),
        ];
        break;
      case "usage":
        scope = view.scope as string;
        // (and its accounts, as the profiles page reads them: each subscription's allowance)
        perStation = (s) => [{ topic: "stationUsage", station: s }, { topic: "link", station: s }, { topic: "overview", station: s }];
        break;
      case "agentRates":
        scope = view.scope as string;
        perStation = (s) => [{ topic: "stationRates", station: s }];
        break;
      case "fleet":
        // (the card shared of the agents at work: views/fleet.ts)
        scope = view.scope as string;
        perStation = (s) => [{ topic: "chatRows", station: s }, { topic: "archivedRows", station: s }, { topic: "jobs", station: s }, { topic: "overview", station: s }, { topic: "link", station: s }, { topic: "host", station: s }, { topic: "way", station: s }, { topic: "stationUsage", station: s }];
        break;
      case "railCard": {
        // (the cards over the rail's places: views/rail-cards.ts) what the place's card is made of
        scope = view.scope as string;
        const place = view.place;
        perStation = (s) => [
          { topic: "chatRows", station: s },
          { topic: "overview", station: s },
          { topic: "link", station: s },
          ...(place === "chats" ? [{ topic: "archivedRows", station: s }] : []),
          ...(place === "usage" ? [{ topic: "stationUsage", station: s }] : []),
        ];
        if (place === "chats") topics.push({ topic: "prefs" }, { topic: "workspaces" });
        break;
      }
      case "resources":
        scope = view.scope as string;
        // One station's (its page's 进程), or every station's.
        perStation = (s) => (view.station === undefined || view.station === s ? [{ topic: "stationResources", station: s }] : []);
        break;
      case "connects":
        scope = view.scope as string;
        // (each row made of its station's overview alone: a session's turn, or a new one, is nothing of a list's)
        perStation = (s) => [{ topic: "overview", station: s }];
        break;
      case "connect":
        scope = view.scope as string;
        perStation = (s) => (s === view.station ? [{ topic: "overview", station: s }, { topic: "sessions", station: s }, { topic: "threads", station: s }] : []);
        break;
      case "connectCandidates":
        scope = view.scope as string;
        perStation = (s) => (s === view.station ? [{ topic: "overview", station: s }, { topic: "sessions", station: s }] : []);
        break;
      case "chatJobs":
        return [{ topic: "chat", station, thread: view.thread ?? null, session: view.session ?? null, ...(view.compact === true ? { compact: true } : {}) }];
      // (one account: of the workspace's profiles, which follow its stations)
      case "profile":
        return [{ topic: "profilesWhole", scope: view.scope }];
      // (an image of a chat steps through all of its, as far as it is on the device: its `letters`, all its entries)
      case "imageNear":
        return [
          { topic: "chat", station, thread: view.thread ?? null, session: view.session ?? null },
          ...(typeof view.thread === "number" ? [{ topic: "letters", station, thread: view.thread }] : []),
        ];
      // (and each pull request's card, for its title and how it stands)
      case "chatThings":
        return [
          { topic: "chat", station, thread: view.thread, session: null },
          { topic: "letters", station, thread: view.thread },
          { topic: "workspace", workspace: ofAddress(station) },
          ...(this.#things(station, view.thread as number)?.things.pulls ?? []).map((p): Topic => ({ topic: "linkPreview", station, url: p.url! })),
        ];
      // (who its people are; its messages read as held, never asked for: `chat.bring` does)
      case "chatOutline":
        return [{ topic: "overview", station }, { topic: "workspace", workspace: ofAddress(station) }];
      case "chatSubchats": {
        const ws = ofAddress(station);
        const out: Topic[] = [
          { topic: "chatRows", station },
          { topic: "archivedRows", station },
          { topic: "link", station },
        ];
        const parent = this.#parentRow(station, u64(view.thread), str(view.session));
        const trimmed = String(view.q ?? "").trim();
        const stationsSeen = new Set<string>();
        for (const o of arr(get(parent, "opened"))) {
          const there = str(get(o, "station"));
          const at = there !== null && there !== "" ? `${ws}/${there}` : station;
          if (stationsSeen.has(at)) continue;
          stationsSeen.add(at);
          if (at !== station) {
            out.push({ topic: "chatRows", station: at }, { topic: "archivedRows", station: at }, { topic: "link", station: at });
          }
          if (trimmed !== "") {
            out.push({ topic: "stationSearch", station: at, q: trimmed, kind: "chat,message", limit: 200 });
          }
        }
        return out;
      }
      case "chatLetters":
        return [
          { topic: "chat", station, thread: view.thread, session: null },
          { topic: "letters", station, thread: view.thread },
          { topic: "workspace", workspace: ofAddress(station) },
        ];
      case "workspaceMarks":
        return this.#marksSources();
      // (what `/v1/me` says, as the workspaces list is made from it)
      case "workspaceWays":
        return [{ topic: "workspaces" }];
      case "agentCard":
        return [
          { topic: "live", station, key: view.key },
          { topic: "session", station, key: view.key },
          { topic: "sessions", station },
          { topic: "chatRows", station },
          { topic: "overview", station },
          { topic: "workspace", workspace: ofAddress(station) },
        ];
      case "stationNet":
        return [{ topic: "net", station }];
      case "stationDiag":
        return [{ topic: "link", station }, { topic: "net", station }, { topic: "workspace", workspace: ofAddress(station) }];
      case "history":
        return [
          { topic: "live", station, key: view.key },
          { topic: "session", station, key: view.key },
          { topic: "overview", station },
          { topic: "workspace", workspace: ofAddress(station) },
        ];
      case "chat": {
        const session = typeof view.session === "string" ? view.session : null;
        if (typeof view.thread !== "number" && session !== null && session.startsWith(PENDING_PREFIX)) {
          topics.push({ topic: "overview", station });
          const thread = this.local.pendingThread(station, session);
          if (typeof thread === "number") return this.#sources({ topic: "chat", station, thread, session: null }, opening);
          topics.push({ topic: "link", station }, { topic: "workspace", workspace: ofAddress(station) });
          return topics;
        }
        if (typeof view.thread !== "number" && session !== null) {
          const bound = this.boundThread(station, session);
          if (bound !== null) return this.#sources({ topic: "chat", station, thread: bound, session: null }, opening);
        }
        if (typeof view.thread !== "number") {
          // (an agent with no chat of its own here, one that has only been in Slack: what it shows, what it heard and
          // said there, is read from its history, `#sentElsewhere`; so its history is held as one shown is, its latest
          // page first: left to the sync's sweep of every agent's, on a station of many it came long after the page
          // opened, the page empty meanwhile)
          if (session !== null) {
            const data = this.#core.data;
            const anchor = data.conversationOf(station, session);
            const row = data.chatForSession(station, session) ?? (anchor !== session ? data.chatNamed(station, anchor)?.row : undefined);
            const keys: string[] = [];
            const add = (k: unknown) => {
              if (typeof k === "string" && k !== "" && !keys.includes(k)) keys.push(k);
            };
            for (const a of arr(get(row, "agents"))) add(get(a, "key"));
            add(anchor);
            add(session);
            for (const key of keys) topics.push({ topic: "session", station, key }, { topic: "live", station, key });
          }
          topics.push(
            { topic: "threads", station },
            { topic: "chatRows", station },
            { topic: "sessions", station },
            { topic: "overview", station },
            { topic: "link", station },
            { topic: "workspace", workspace: ofAddress(station) },
          );
          return topics;
        }
        const thread = view.thread as number;
        const kept = () => {
          const t0 = get(this.ok({ topic: "thread", station, thread }), "thread");
          return isObject(t0) ? t0 : null;
        };
        for (const key of members(this.threadOf(station, thread) ?? kept())) topics.push({ topic: "session", station, key });
        topics.push(
          { topic: "threads", station },
          { topic: "sessions", station },
          { topic: "thread", station, thread },
          { topic: "chatRows", station },
          { topic: "overview", station },
          { topic: "link", station },
          { topic: "workspace", workspace: ofAddress(station) },
          // Its sharing names the viewer's other workspaces.
          { topic: "workspaces" },
        );
        // The chats its messages link to, as their stations' lists have them (#linkedChats, each its row alone). Not the
        // archive: shown, a station's archive is read from it whole (sync.ts archivedShown), its thousands of rows the
        // most of opening a chat with a link in it (0.63 s on a phone, 2026-10-31); one archived meanwhile is said so
        // as the chat is made again.
        if (opening) return topics;
        for (const s of this.#linkedStations(station, arr(get(this.ok({ topic: "thread", station, thread }), "entries")))) {
          if (s !== station) topics.push({ topic: "chatRows", station: s });
        }
        return topics;
      }
      default:
        if (view.topic.startsWith("admin")) return adminSources(view);
        return topics;
    }
    if (view.topic === "chats" || view.topic === "longJobs") topics.push({ topic: "prefs" });
    topics.push({ topic: "workspace", workspace: scope });
    // (a station another workspace lent: its home's name)
    if (view.topic === "stations" || view.topic === "station" || view.topic === "stationsWhole") topics.push({ topic: "workspaces" });
    for (const s of this.stations(scope) ?? []) {
      topics.push({ topic: "link", station: s.address });
      if (s.online) topics.push(...perStation(s.address));
    }
    // The `@` menu's other workspaces (`elsewhere`): their chats too, once something is typed.
    if (view.topic === "chatSearch" && view.elsewhere === true && String(view.query ?? "").trim() !== "") {
      topics.push({ topic: "workspaces" });
      for (const place of this.#core.places?.() ?? []) {
        if (place.id === scope) continue;
        topics.push({ topic: "workspace", workspace: place.id });
        for (const s of this.stations(place.id) ?? []) {
          topics.push({ topic: "link", station: s.address });
          if (s.online) topics.push(...perStation(s.address));
        }
      }
    }
    return topics;
  }

  // ── what the views read ──

  /// Whether a workspace's notices are heard of on this device.
  heard(workspace: string): boolean {
    return this.#core.heard?.(workspace) ?? true;
  }

  ok(topic: Topic): J {
    const v = this.#core.store.value(topic);
    return v && "ok" in v ? v.ok : undefined;
  }

  value(topic: Topic): Value | undefined {
    return this.#core.store.value(topic);
  }

  /// The scope's stations; undefined until the workspace has been read (an error: none to show).
  stations(scope: string): StationInfo[] | undefined {
    const v = this.value({ topic: "workspace", workspace: scope });
    if (v === undefined || !("ok" in v)) return v === undefined ? undefined : [];
    return arr(get(v.ok, "stations")).flatMap((s) => {
      const id = str(get(s, "id"));
      if (id === null) return [];
      const address = `${scope}/${id}`;
      return [{ address, id, name: str(get(s, "name")) ?? id, emoji: str(get(s, "emoji")) || null, icon: str(get(s, "icon")) || null, online: this.#core.store.select({ topic: "link", station: address }, stationOnline), lastSeen: get(s, "last_seen") ?? null, version: get(s, "version") ?? null, joined: get(s, "joined") === true }];
    });
  }

  /// The scope's stations by their address and name alone, the same array while those are the same: what reads no more
  /// of them (a workspace's mark, views/marks.ts) is not made again as a station's link comes and goes, which
  /// `stations` says of each (`online`). A workspace switched to has its stations' links tried anew: each going from
  /// offline to connecting made both workspaces' marks again, 4-7 ms in Hermes on a Mac Studio at a workspace of real
  /// size (2026-11-11).
  readonly #stationsNamed = new Map<string, Derived<{ address: string; name: string }[]>>();
  /// A login of a station's, as its station last told it (null: not told): its program, when it runs out of time.
  loginOf(station: string, id: string): { name: string; ends: number | null } | null {
    return this.#core.loginOf?.(station, id) ?? null;
  }

  stationsNamed(scope: string): { address: string; name: string }[] {
    let kept = this.#stationsNamed.get(scope);
    if (kept === undefined) {
      let last: { address: string; name: string }[] | undefined;
      kept = computed(() => {
        const v = this.value({ topic: "workspace", workspace: scope });
        const next = v !== undefined && "ok" in v
          ? arr(get(v.ok, "stations")).flatMap((s) => {
            const id = str(get(s, "id"));
            return id === null ? [] : [{ address: `${scope}/${id}`, name: str(get(s, "name")) ?? id }];
          })
          : [];
        return last !== undefined && equal(last, next) ? last : (last = next);
      });
      this.#stationsNamed.set(scope, kept);
    }
    return kept.get();
  }

  /// Rate events are frequent, while names change rarely. Keep the reads separate from the rate's computation, so an
  /// update does not query every displayed session again or push the other views' reads out of the chat cache.
  #rateName(station: string, key: string): { title: string | null; model: string | null; chat: string | null } {
    const id = JSON.stringify([station, key]);
    let kept = this.#rateNames.get(id);
    if (kept === undefined) kept = computed(() => {
      const chat = this.#core.data.chatNamedOfAgent(station, key);
      const session = this.#core.data.listedSummary(station, key);
      const model = str(get(session, "model"));
      return { title: chat?.title ?? str(get(session, "title")), model: model === null ? null : format.agentLabel(model, null), chat: chat?.id ?? null };
    });
    this.#rateNames.delete(id);
    this.#rateNames.set(id, kept);
    if (this.#rateNames.size > 64) this.#rateNames.delete(this.#rateNames.keys().next().value!);
    return kept.get();
  }

  /// The station a link names now (`<workspace>/<station>`): one that took a lost one's place, where that is the one
  /// named (its overview's `copies.formerly`, kept beside it: data.ts overviewFormerly); the one named otherwise.
  stationNow(address: string): string {
    const at = address.lastIndexOf("/");
    if (at < 0) return address;
    const scope = address.slice(0, at);
    const id = address.slice(at + 1);
    for (const s of this.stations(scope) ?? []) {
      if (s.id === id) continue;
      const formerly = this.#core.data.overviewFormerly(s.address);
      if (Array.isArray(formerly) && formerly.includes(id)) return s.address;
    }
    return address;
  }

  #stationsOr(scope: string): StationInfo[] | Value | undefined {
    const v = this.value({ topic: "workspace", workspace: scope });
    if (v === undefined) return undefined;
    if ("err" in v) return v;
    return this.stations(scope);
  }

  /// The stations whose chats what was said in a chat on `station` links to (its entries' words): its own, and those of
  /// the viewer's workspaces online.
  #linkedStations(station: string, entries: J[]): string[] {
    work.linkScans++;
    const out: string[] = [];
    for (const e of entries) {
      if (!mayLink(e)) continue;
      const text = str(get(e, "text")) ?? "";
      for (const linked of this.#chatsLinked(text, station)) {
        const c = { ...linked, station: this.stationNow(linked.station) };
        if (out.includes(c.station)) continue;
        if (c.station === station || (this.stations(ofAddress(c.station)) ?? []).some((s) => s.address === c.station && s.online)) out.push(c.station);
      }
    }
    return out;
  }

  /// The chats `text`, said in a chat on `station`, links to, as their stations' lists have them: each found its link,
  /// its title as its row says it, and whether it is archived (archivedRows), said so. One no list has is left out.
  /// Each its row alone, read where it is kept: a station's whole lists, its archive's thousands of rows, read for a
  /// link were most of what opening a chat that has one took (0.65-0.83 s on a phone, 2026-10-31).
  /// Each its row's columns alone (data.ts chatLinked): no record read, parsed nor frozen for a link. `now`: the stations
  /// links name now (stationNow), found once for the chat being drawn.
  #linkedChats(station: string, text: string, now?: Map<string, string>): J[] {
    if (!text.includes("/chats/") && !text.includes("/o/")) return [];
    return this.#chatsLinked(text, station).flatMap((linked) => {
      let at = now?.get(linked.station);
      if (at === undefined) {
        at = this.stationNow(linked.station);
        now?.set(linked.station, at);
      }
      const c = { ...linked, station: at };
      const found = this.#core.data.chatLinked(c.station, c.id);
      if (found === undefined || (found.archived && !found.archivedMark)) return [];
      const thread = u64(found.thread ?? null);
      return [{ href: c.href, title: found.title || t("core-views.new_chat"), ...(thread !== null ? { thread } : {}), ...(found.archived ? { archived: true, note: t("core-views.search.archived") } : {}) }];
    });
  }

  /// The title of the chat `link` names (a still.fail link or a chat's page, as an agent's chat tools take it; a page
  /// naming no station, `…/chats/<key>`, one of `here`'s), as its station's lists have it (data.ts chatLinked: its row's
  /// columns alone); undefined for one no list has. A chat named but never titled is 新对话, as its row says it.
  chatTitleOfLink(link: string, here?: string): string | undefined {
    const of = chatOfLink(link) ?? (here === undefined ? undefined : this.#chatsLinked(link, here)[0]) ?? null;
    if (of === null) return undefined;
    const found = this.#core.data.chatLinked(this.stationNow(of.station), of.id);
    return found === undefined ? undefined : found.title || t("core-views.new_chat");
  }

  /// The links to chats `text`, said in a chat on `station`, has (chatsLinked), found once while it is among the last
  /// `LINKS_KEPT` looked through: a chat's messages are looked through again each time it is made, and finding them
  /// is most of what that takes.
  readonly #linksFound = new Map<string, ReturnType<typeof chatsLinked>>();
  #chatsLinked(text: string, station: string): ReturnType<typeof chatsLinked> {
    const key = `${station}\u0001${text}`;
    const was = this.#linksFound.get(key);
    if (was !== undefined) return was;
    const found = sharedValue(chatsLinked(text, station));
    if (this.#linksFound.size >= LINKS_KEPT) this.#linksFound.delete(this.#linksFound.keys().next().value!);
    this.#linksFound.set(key, found);
    return found;
  }

  /// Who is looking: the account that reaches the workspace.
  me(scope: string): J {
    const email = this.#core.emailOf(scope);
    return { id: email, email };
  }

  #betaOf(scope: string): boolean {
    return this.#core.betaOf(scope);
  }

  relayName(host: string): string | null {
    return this.#core.relayName(host);
  }

  /// A part of the prefs (store.ts `select`): what reads it is made again only as that part changes. `pick` is kept,
  /// not made at each call: the store keeps the part by it.
  prefsPart<T>(pick: (value: Value | undefined) => T): T {
    return this.#core.store.select({ topic: "prefs" }, pick);
  }

  /// A workspace's mark (views/marks.ts `workspaceMark`), kept for the workspace (`#marks`): the same object while
  /// what it is made of says the same.
  markOf(workspace: string): J {
    let kept = this.#marks.get(workspace);
    if (kept === undefined) {
      const pick = marks.prefsOf(workspace);
      let last: J;
      kept = computed(() => {
        const next = marks.workspaceMark(this, this.local, workspace, this.prefsPart(pick));
        return last !== undefined && equal(last, next) ? last : (last = next);
      });
      this.#marks.set(workspace, kept);
    }
    return kept.get();
  }

  /// The rows of these stations that ask something of their person or are unread (views/marks.ts).
  marked(stations: string[]): [string, J][] {
    return this.#core.data.marked(stations);
  }

  /// A chat's record by its thread on a station (none: not listed there), for what is kept here of it alone (a message
  /// that did not go: views/marks.ts).
  chatOfThread(station: string, thread: number): J {
    return this.#core.data.chatOfThread(station, thread) ?? null;
  }

  /// The chat an agent's item has: the still.fail chat bound to it, as the station's items say, or its threads do.
  boundThread(station: string, key: string): number | null {
    const data = this.#core.data;
    const fromRows = u64(get(data.chatForSession(station, key), "thread"));
    if (fromRows !== null) return fromRows;
    const anchor = data.conversationOf(station, key);
    if (anchor !== key) {
      const fromNamed = u64(get(data.chatNamed(station, anchor)?.row, "thread"));
      if (fromNamed !== null) return fromNamed;
      const anchorThread = data.threadOf(station, anchor);
      if (anchorThread !== null) return anchorThread;
      const own = arr(get(this.ok({ topic: "session", station, key: anchor }), "threads")).find((t) => isOwnSurface(str(get(t, "surface")) ?? ""));
      const fromDetail = u64(get(own, "id"));
      if (fromDetail !== null) return fromDetail;
    }
    return data.threadOf(station, key);
  }

  /// A thread among the station's (null when it lists none such, or its threads were never read).
  threadOf(station: string, id: number): J {
    const data = this.#core.data;
    if (typeof id !== "number") return null;
    return data.listed(station, "threads") ? (data.listedThread(station, id) ?? null) : null;
  }

  /// The station's link as `{ state, message, last, retrying }`.
  link(station: string): J {
    return linkValue(this.value({ topic: "link", station }));
  }

  #clock(): present.Clock {
    const now = this.#core.host.nowMs();
    return { now, offsetMin: this.#core.host.utcOffsetMin(now) };
  }

  /// The names of a workspace's stations by id (none until the workspace has been read).
  stationNames(scope: string): Map<string, string> {
    return new Map((this.stations(scope) ?? []).map((s) => [s.id, s.name]));
  }

  /// A station's name as its workspace has it, else its id.
  stationName(station: string): string {
    const at = station.indexOf("/");
    if (at < 0) return "";
    const found = this.stations(station.slice(0, at))?.find((s) => s.address === station);
    return found ? found.name : station.slice(at + 1);
  }

  /// Whether a station is offline, as its workspace says.
  offline(station: string): boolean {
    const at = station.indexOf("/");
    if (at < 0) return false;
    return this.stations(station.slice(0, at))?.find((s) => s.address === station)?.online === false;
  }

  /// A station's sidebar row of a thread or an agent, as changes from here have it; undefined while the station's rows
  /// were never read (null: none such).
  #row(station: string, by: { thread: number } | { session: string }): J | null | undefined {
    const data = this.#core.data;
    if (!data.listed(station, "chats")) return undefined;
    this.local.settle(station, data.rowsRev(station));
    const raw = "thread" in by ? data.chatOfThread(station, by.thread) : data.chatForSession(station, by.session);
    return raw === undefined ? null : this.local.asChanging(station, raw);
  }

  // ── computing ──

  /// Whether a view with no value yet waits on a station for what it shows (store.ts `waits`): a chat whose messages it
  /// opens with are not on the device. Not what it is built from but not computed yet this turn (that comes as soon as
  /// it is): the device is asked, not the thread's topic.
  waits(view: Topic): boolean {
    if (view.topic !== "chat" || typeof view.station !== "string") return false;
    const station = view.station;
    let thread: number | null = typeof view.thread === "number" ? view.thread : null;
    const session = typeof view.session === "string" ? view.session : null;
    if (thread === null && session !== null) {
      const pending = session.startsWith(PENDING_PREFIX) ? this.local.pendingThread(station, session) : this.boundThread(station, session);
      thread = typeof pending === "number" ? pending : null;
    }
    return thread !== null && this.#core.waits?.({ topic: "thread", station, thread }) === true;
  }

  compute(view: Topic): Value | undefined {
    const live = this.#views.get(topicKey(view));
    if (live === undefined) return undefined;
    timed(`${view.topic}.sources`, () => untracked(() => this.#sync(view)));
    const out = timed(`${view.topic}.make`, () => this.#compute(view));
    if (view.topic !== "chat" || out === undefined || !("ok" in out)) return out;
    const v = out.ok as J;
    const station = view.station as string;
    if (isObject(v.link)) v.connection = looks.linkShown(v.link, this.stationName(station));
    const overview = this.#chatOverview(station);
    const prefs = this.prefsPart(chatPrefsIn);
    const workspace = this.ok({ topic: "workspace", workspace: ofAddress(station) }) ?? null;
    const role = get(workspace, "role");
    const manager = role === "owner" || role === "admin";
    // Its side panel's tabs, as kept on this device for it by its page's key (chat-tabs.ts).
    const session = typeof view.thread === "number" ? null : typeof view.session === "string" ? view.session : null;
    const kept = get(get(prefs, "chatTabs"), `${station}:${session ?? view.thread}`);
    v.tabs = chatTabs.tabsOf(kept, arr(v.agents), v.noChat === true, session);
    const dismissed = get(get(prefs, "stationUpdatesDismissed"), station);
    v.stationUpdate = looks.stationUpdate(overview, v, typeof dismissed === "string" ? dismissed : null, this.#noticeOpen(station), manager, this.stationName(station));
    if (Array.isArray(v.outbox)) v.outbox = looks.outboxWaits(looks.outboxShown(v.outbox), v.stationUpdate);
    // The screens of the machine it runs on, a press away from its bar: its own display first (screens.ts screensView),
    // each marked while an agent drives it; and whether a browser tab or terminal may be opened there (`canBrowser`, `canTerminal`).
    const screensHeld = this.ok({ topic: "screens", station });
    const screens = arr(get(screensHeld, "screens")).map((s) => ({ id: s.id, kind: s.kind, title: s.title, line: s.line, ...(s.agent === true ? { agent: true } : {}) }));
    if (screens.length > 0) v.screens = screens;
    if (v.offline !== true && get(screensHeld, "browser") === true && get(screensHeld, "control") === true) v.canBrowser = true;
    if (v.offline !== true && stationFeature(overview, "terminal") && role !== "viewer") v.canTerminal = true;
    if (v.offline === true) {
      v.offlineNote = looks.offlineNote(v.link, this.stationName(station));
      if (get(v.link, "cause") === "updating") v.updating = true;
      if (Array.isArray(v.outbox)) v.outbox = looks.outboxHeld(v.outbox);
    }
    // Going to another station now (its overview's `move.chats`): its composer shut, saying where, till it is there.
    const moving = looks.movingOf(get(get(overview, "move"), "chats"), [...(session === null ? [] : [session]), ...arr(v.agents).map((a) => str(get(get(a, "session"), "key")) ?? "")], (id) => this.stationName(`${ofAddress(station)}/${id}`));
    if (moving !== null) v.moving = moving;
    // Its agent's prompt cache over: said over the composer, computed again as the next one's is over.
    const context = get(overview, "context");
    const above = get(context, "afreshAbove");
    const [cold, coldIn] = v.archived === true ? [null, Infinity] : brief.cacheCold(v.agents, this.#core.host.nowMs(), get(context, "afreshWhenCold") === true, typeof above === "number" ? above : undefined);
    if (cold !== null) v.cacheCold = cold;
    this.#againIn(coldIn);
    // Its sharing with the viewer's other workspaces, as asked here meanwhile.
    const shared = xshare.shown({ places: this.#core.places?.() ?? [], asked: (session) => this.#core.xshareAsked?.(station, session), me: str(get(v.me, "email")) }, station, v.thread);
    if (shared !== null) v.xshare = shared;
    // Whether the viewer may draw it as a picture (分享图片).
    const published = publish.shown(typeof role === "string" ? role : null, v.thread);
    if (published !== null) v.publish = published;
    return out;
  }

  #compute(view: Topic): Value | undefined {
    switch (view.topic) {
      case "chats": {
        const chats = this.#chats(view.scope as string, view.mine === true, view.watching === true, view.hidden === true ? "hidden" : "visible", this.chatsWindow(view));
        // (its days are the window's first rows made already, #chatsOf: `firstRows` of them again would give them as they are)
        return chats;
      }
      case "chatRow":
        return this.#wholeRow(view.station as string, view.session as string);
      case "search": {
        const chats = this.#chatsWhole(view.scope as string, false, false, String(view.query ?? "").trim() ? "found" : "visible");
        if (chats === undefined || !("ok" in chats)) return chats;
        return searchView(this.#searchSource, stationsOn(wholeRows(chats.ok)), view);
      }
      case "chatSearch": {
        const listed = this.#chatsWhole(view.scope as string, false, false, String(view.query ?? "").trim() ? "all" : "visible");
        if (listed === undefined || !("ok" in listed)) return listed;
        // (each row as its station's state makes it, of those it finds alone: stationsOn, foundOn)
        const rows = wholeRows(listed.ok);
        const elsewhere = view.elsewhere === true && String(view.query ?? "").trim() !== "";
        // The chats opened on this device first, the latest first, then the rest by when they were last active (refs.ts).
        const opened = refs.openedIn(this.#core.data, view.scope as string);
        const found = foundOn(rows, refs.search(rows, view.query as string, view.station as string | undefined, view.exclude as string | undefined, elsewhere ? undefined : (view.limit as number | undefined), opened));
        // With something typed (`elsewhere`, the `@` menu), those of the viewer's other workspaces whose title has it
        // too, each saying whose, ranked so as not to crowd this workspace's (refs.ts withOutside).
        if (elsewhere) {
          const others: J[] = [];
          for (const place of this.#core.places?.() ?? []) {
            if (place.id === view.scope) continue;
            const theirs = this.#chatsWhole(place.id, false, false, "all");
            if (theirs === undefined || !("ok" in theirs)) continue;
            const theirRows = wholeRows(theirs.ok);
            for (const item of arr(foundOn(theirRows, refs.search(theirRows, view.query as string, undefined, undefined, undefined, refs.openedIn(this.#core.data, place.id))).items)) others.push({ ...item, outside: place.name, ...xshare.markOf(place, "outside") });
          }
          found.items = refs.withOutside(arr(found.items), others, view.query as string, view.scope as string, view.limit as number | undefined);
        }
        // (what it lists whole, as its rows were before the list's were what a row draws: wholeFor)
        found.items = arr(found.items).map((i) => this.wholeFor(i));
        if (typeof view.messages === "number" && view.messages > 0) {
          found.messages = this.#foundMessages(stationsOn(rows), view);
          found.words = refs.terms(view.query as string);
        }
        return { ok: found };
      }
      case "stations":
        return this.#stationsOf(view.scope as string, "row");
      case "stationsWhole":
        return this.#stationsOf(view.scope as string, "whole");
      case "station": {
        const one = this.#stationsOf(view.scope as string, "page", view.station as string);
        if (one === undefined || !("ok" in one)) return one;
        return { ok: (one.ok as J[])[0] ?? null };
      }
      case "stationPart": {
        // As its page's overview has it: the same object, made once for both.
        const stations = this.#stationsOr(view.scope as string);
        if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
        if (!stations.some((s) => s.address === view.station)) return { ok: null };
        // (the automatic decisions and archiving of what is kept of them beside the overview, made as the whole makes
        // them: never the whole)
        const parts = this.#stationShownOf(view.station as string);
        return { ok: get(SETTINGS_PARTS.has(view.part as string) ? parts.settings.get() : parts.full.get(), view.part as string) ?? null };
      }
      case "profiles": {
        // What goes out is the rows (ProfileRow), shaped here beside the value the list made (conform.ts shapedBeside, as
        // a chat list's kept row goes out): taken as they are where `profiles` goes out (output.ts), neither copied,
        // decorated again nor walked by its shape there. Copying, decorating and shaping the whole value at output was
        // 4.7 ms of the 17 that `profiles` took after a workspace was switched to on 小屏 (Hermes, Mac Studio,
        // 2026-11-12). The list is made of each station's rows kept beside its part (#profileRowsView), not of its
        // profiles decorated: what the core's readers read whole is `profilesWhole`'s.
        const listed = this.#profileRowsView(view.scope as string);
        if (listed !== undefined && "ok" in listed && isObject(listed.ok)) {
          const rows = conformTy("ProfilesView", listed.ok);
          if ("ok" in rows && isObject(rows.ok)) shapedBeside(listed.ok, "ProfilesView", sharedValue(rows.ok) as object);
        }
        return listed;
      }
      // (the workspace's accounts whole: what an account's page (`profile`) reads, made only as something asks it)
      case "profilesWhole":
        return this.#profilesView(view.scope as string);
      case "profile":
        return this.#profileOf(view);
      case "profilesOverview": {
        // The Profile overview's pools (views/profiles-overview.ts) of the accounts as the list's rows keep them (each
        // window's percent left and its refill's moment: no overview decorated whole) and their stations' hours, made
        // again as either changes and at each quarter hour (its hours, and its models' speed a quarter apart, are the
        // clock's).
        const stations0 = this.#stationsOr(view.scope as string);
        if (stations0 === undefined || !Array.isArray(stations0)) return stations0 as Value | undefined;
        const key = profileRowKey();
        const listed = workspaceProfiles(stations0.map((s) => ({ station: s.address, id: s.id, name: s.name, online: s.online, joined: s.joined, overview: this.#profileRowsOfStation(s.address, key) })));
        const now = this.#core.host.nowMs();
        this.#againIn(HOUR / 4 - (now % (HOUR / 4)));
        const stations = new Map(stations0.map((s) => [s.address, s.online]));
        const pace = (station: string) => (stations.get(station) === true ? this.ok({ topic: "profilePace", station }) : undefined);
        return { ok: profilesOverview(arr(listed.items), pace, now, this.#core.host.utcOffsetMin(now)) };
      }
      case "settings": {
        // Each station's name, whether it is up and its overview: what the settings say of them, not their pages.
        const stations = this.#stationsOr(view.scope as string);
        if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
        // (of the automatic decisions and archiving kept beside each overview, decorated as the whole decorates them:
        // never the whole, of some 150 KB a phone's each)
        return { ok: settingsView(stations.map((s) => ({ name: s.name, online: s.online, overview: this.#stationShownOf(s.address).settings.get() }))) };
      }
      case "connects":
        return this.#connects(view.scope as string, view.mine === true);
      case "connect":
        return this.#connectOf(view.scope as string, view.station as string, view.id as string, "page");
      case "connectCandidates":
        return this.#connectOf(view.scope as string, view.station as string, view.id as string, "candidates");
      case "chat": {
        work.chats++;
        const station = view.station as string;
        // (its agents' Markdown read once on the device: kept by the chat it is read for)
        const draw = <V extends Value | undefined>(out: V) => {
          const thread = out !== undefined && "ok" in out ? u64(get(get(out.ok, "thread"), "id")) : null;
          const of = thread !== null ? `t:${thread}` : typeof view.thread === "number" ? `t:${view.thread}` : `s:${String(view.session ?? "")}`;
          const held = (session: string, name: string) => this.#core.data.hasKeptFile(station, session, name, "thumb") || this.#core.data.hasKeptFile(station, session, name, "poster");
          // (the station each link names now, found once for all of its messages' links: each a walk of its workspace's
          // stations)
          const now = new Map<string, string>();
          const shown = timed("chat.draw", () => drawn(out, (path) => this.local.uploadOf(station, path), this.#core.data.mdStore(station, of), (text) => timed("chat.links", () => this.#linkedChats(station, text, now)), held));
          return timed("chat.vault", () => this.#vaultCards(view, shown));
        };
        if (typeof view.thread === "number") return draw(this.#chat(station, view.thread));
        const session = typeof view.session === "string" ? view.session : null;
        if (session === null) return { err: CoreError.invalid(t("core-views.error.chat_needs_thread")) };
        if (session.startsWith(PENDING_PREFIX)) return draw(this.#pendingChat(station, session) ?? { err: new CoreError("http_404", t("core-views.error.no_chat"), 404) });
        const bound = this.boundThread(station, session);
        const out = bound !== null ? this.#chat(station, bound) : this.#unchatted(station, session);
        const waiting = this.local.firstOutbox(station, session);
        if (waiting.length === 0 || out === undefined || !("ok" in out)) return draw(out);
        const v = out.ok as J;
        if (Array.isArray(v.outbox)) v.outbox.push(...waiting);
        return draw(out);
      }
      case "chatLetters":
        return this.#chatLetters(view.station as string, view.thread as number);
      case "chatThings":
        return this.#chatThings(view.station as string, view.thread as number, typeof view.q === "string" ? view.q : "");
      case "chatOutline":
        return timed("chat.outline", () => this.#chatOutline(view.station as string, view.thread as number));
      case "chatSubchats":
        return this.#chatSubchats(view.station as string, u64(view.thread), str(view.session), typeof view.q === "string" ? view.q : "");
      case "history":
        return this.#history(view.station as string, view.key as string);
      case "stationNet": {
        // A station's connection with every figure, sampled while this is shown (station/topics.ts).
        const net = this.ok({ topic: "net", station: view.station as string });
        return { ok: net === undefined ? null : present.net(net, (h) => this.relayName(h)) };
      }
      case "stationDiag":
        return { ok: this.#stationDiag(view.station as string) };
      case "agentCard": {
        const agent = this.agent(view.station as string, view.key as string);
        if (agent === null) return undefined;
        const live = this.value({ topic: "live", station: view.station as string, key: view.key as string });
        return { ok: brief.card(agent, live !== undefined && "ok" in live ? live.ok : null, this.stationNames(ofAddress(view.station as string))) };
      }
      case "archive":
        return archive(this, this.local, view.scope as string, this.#core.host, typeof view.q === "string" ? view.q : "", typeof view.limit === "number" ? view.limit : 0);
      case "workspaceMarks":
        return marks.marks(this);
      case "chatJobs": {
        const chat = this.value({ topic: "chat", station: view.station, thread: view.thread ?? null, session: view.session ?? null, ...(view.compact === true ? { compact: true } : {}) });
        if (chat === undefined || !("ok" in chat)) return chat;
        const [value, next] = jobs.chatJobs(chat.ok, this.#clock(), view.summary === true);
        this.#againIn(next);
        return { ok: value };
      }
      case "imageNear": {
        const chat = this.value({ topic: "chat", station: view.station, thread: view.thread ?? null, session: view.session ?? null });
        if (chat === undefined || !("ok" in chat)) return chat;
        // All of the chat's held, where it has a thread (its page holds a window of it); the outbox's after them.
        const whole = typeof view.thread === "number" ? this.#things(view.station as string, view.thread) : null;
        const messages = whole?.messages.map((m) => {
          const seq = u64(m.seq);
          const outgoing = seq === null ? undefined : this.local.outgoing(view.station as string, view.thread as number, seq);
          return outgoing === undefined ? m : { ...m, outgoing };
        });
        return { ok: near(whole === null ? chat.ok : { messages, outbox: get(chat.ok, "outbox") }, view.path as string, view.at as string | undefined) };
      }
      case "workspaceWays": {
        const ways = this.#core.ways?.(view.workspace as string);
        return ways === undefined ? undefined : { ok: ways };
      }
      case "adminList":
      case "adminItem":
      case "adminOverview":
      case "adminRelays": {
        const now = this.#core.host.nowMs();
        return admin(view, (account, list) => this.value({ topic: "admin", account, list }), now, this.#core.host.utcOffsetMin(now));
      }
      case "usage": {
        const scope = view.scope as string;
        const stations = this.#stationsOr(scope);
        if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
        const sources = stations.map((s) => ({ address: s.address, name: s.name, online: s.online, value: s.online ? this.value({ topic: "stationUsage", station: s.address }) : undefined }));
        const members_ = arr(get(this.ok({ topic: "workspace", workspace: scope }), "members"));
        const now = this.#core.host.nowMs();
        const listed = this.#profilesView(scope);
        const accounts = listed !== undefined && "ok" in listed ? arr(get(listed.ok, "items")) : [];
        const offset = this.#core.host.utcOffsetMin(now);
        const summary = usageSummary(sources, now, offset, String(get(this.ok({ topic: "workspace", workspace: scope }), "name") ?? ""));
        return { ok: { ...usageView(sources, typeof view.days === "number" ? view.days : 7, now, offset, this.me(scope), members_, { split: view.split, only: view.only, day: view.day }, accounts), ...(summary !== null ? { summary } : {}) } };
      }
      case "agentRates": {
        const stations = this.#stationsOr(view.scope as string);
        if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
        return { ok: agentRates(stations.map((s) => ({
          address: s.address, name: s.name, value: this.ok({ topic: "stationRates", station: s.address }),
          named: (key: string) => this.#rateName(s.address, key),
        }))) };
      }
      case "fleet": {
        const scope = view.scope as string;
        const stations = this.#stationsOr(scope);
        if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
        // what they did over the last 7 days, as the usage page has it
        const sources = stations.map((s) => ({ address: s.address, name: s.name, online: s.online, value: s.online ? this.value({ topic: "stationUsage", station: s.address }) : undefined }));
        const now = this.#core.host.nowMs();
        const usage = usageView(sources, 7, now, this.#core.host.utcOffsetMin(now), this.me(scope), arr(get(this.ok({ topic: "workspace", workspace: scope }), "members")));
        // A shareable poster must not present the stations that have answered as the whole workspace.
        if (get(usage, "detailsPreparing") === true) return undefined;
        // the subscriptions, as the profiles page lists them
        const listed = this.#profilesView(scope);
        const profiles = listed !== undefined && "ok" in listed ? arr(get(listed.ok, "items")) : [];
        // the chats at work, when each archived one was archived (as the archive has it: views/archive.ts), the jobs (the
        // tasks other stations' chats run there now), the tasks they ran there before
        // (of their chats' columns: those at work, whether one was active today, when those archived since a week before
        // were, the chat a session is in)
        const offset = this.#core.host.utcOffsetMin(now);
        const today = format.localDay(now, offset) * DAY_MS - offset * 60_000;
        const archivedOn = this.#archivedDays(stations.map((s) => s.address), today - 8 * DAY_MS, offset);
        const data = this.#core.data;
        const read = stations.map((s) => {
          const work = data.chatCounted(CHAT_READS.atWork, { station: s.address, from: today, to: today + DAY_MS });
          return {
            station: s.address,
            online: s.online && !down(this.link(s.address)),
            today: work.some((r) => r[2] === 1),
            running: work.filter((r) => r[0] !== null).map((r) => String(r[0])),
            chatOf: (session: string) => data.chatNamedOfAgent(s.address, session)?.id ?? null,
            archived: archivedOn.get(s.address) ?? [],
            jobs: arr(this.ok({ topic: "jobs", station: s.address })),
            // the tasks other stations' chats ran here, as its usage says them (a station from before says none)
            runs: arr(get(this.ok({ topic: "stationUsage", station: s.address }), "remoteRuns"))
              .filter((r) => typeof get(r, "at") === "number" && typeof get(r, "session") === "string")
              .map((r) => ({ at: get(r, "at") as number, session: get(r, "session") as string, ...(typeof get(r, "count") === "number" ? { count: get(r, "count") as number } : {}) })),
            // its chats' calls, by day, chat, profile and model, as the usage page reads them
            calls: arr(get(this.ok({ topic: "stationUsage", station: s.address }), "rows")),
          };
        });
        return { ok: fleetView(read, profiles, usage, now, offset) };
      }
      case "stationUpdates": {
        // (an owner's or an admin's alone: nobody else can update a station)
        const scope = view.scope as string;
        const stations = this.#stationsOr(scope);
        if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
        const role = get(this.ok({ topic: "workspace", workspace: scope }), "role");
        const manages = role === "owner" || role === "admin";
        const data = this.#core.data;
        // (a version let be on a chat's notice of it, 不再提醒此版本, is not offered here either unless stale > 7d)
        const dismissed = this.prefsPart(updatesDismissedIn);
        const now = untracked(() => this.#core.host.nowMs());
        const list = manages
          ? stations.map((s) => {
              const software = data.overviewSoftware(s.address);
              if (isObject(software) && get(software, "updatable") === true) {
                const builtAt = get(software, "builtAt");
                if (typeof builtAt === "number" && Number.isFinite(builtAt) && builtAt > 0) {
                  this.#moments.reached(builtAt + STALE_BUILD_MS, true);
                }
              }
              return { station: s.address, name: s.name, online: s.online && !down(this.link(s.address)), software, dismissed: str(get(dismissed, s.address)) };
            })
          : [];
        return { ok: stationUpdates(list, now) };
      }
      case "railCard": {
        const scope = view.scope as string;
        // (the list's count of its rows at work, as its window counts them: none of its rows read)
        const now = this.#core.host.nowMs();
        const offset = this.#core.host.utcOffsetMin(now);
        const online = (this.stations(scope) ?? []).filter((s) => s.online);
        switch (view.place) {
          case "chats": {
            const { value: chats, running } = this.#chatsOf(scope, false, false, "visible", 0, true);
            if (chats === undefined || !("ok" in chats)) return chats;
            const mark = marks.workspaceIds(this.ok({ topic: "workspaces" })).includes(scope) ? this.markOf(scope) : undefined;
            // when each archived chat was, as the archive has it (views/archive.ts): today's, counted of their columns
            const today = format.localDay(now, offset) * DAY_MS - offset * 60_000;
            const archived = [...this.#archivedDays(online.map((s) => s.address), today, offset).values()].flat();
            return { ok: chatsCard(running, mark, archived, now, offset) };
          }
          case "usage": {
            const stations = this.#stationsOr(scope);
            if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
            const sources = stations.map((s) => ({ address: s.address, name: s.name, online: s.online, value: s.online ? this.value({ topic: "stationUsage", station: s.address }) : undefined }));
            return { ok: usageCard(usageView(sources, 7, now, offset, this.me(scope), arr(get(this.ok({ topic: "workspace", workspace: scope }), "members")))) };
          }
        }
        return undefined;
      }
      case "resources": {
        const stations = this.#stationsOr(view.scope as string);
        if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
        const sources = stations.filter((s) => view.station === undefined || s.address === view.station)
          .map((s) => ({ address: s.address, name: s.name, online: s.online, value: s.online ? this.value({ topic: "stationResources", station: s.address }) : undefined }));
        return { ok: resourcesView(sources, this.#core.host.nowMs(), looks.waitNote) };
      }
      case "longJobs": {
        const stations = this.#stationsOr(view.scope as string);
        if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
        const several = stations.length > 1;
        // Whose each is (jobs.ts `mineOf`): in a workspace of one, all the viewer's; where others are members, what
        // the viewer's own chats run (`mine` of their columns) and their own views, a shared station's others' (its
        // simulators the viewer's where a view of theirs is on it). (Machines that only run tasks, a member's own, are
        // no station of the list: the workspace's `rigs`.)
        const members = arr(get(this.ok({ topic: "workspace", workspace: view.scope as string }), "members"));
        const multi = members.length > 1;
        const email = this.#core.emailOf(view.scope as string)?.toLowerCase();
        // Each in the chat its session's row is, from the sidebar held, listed or archived (the station names it no
        // more), the chat it is among the agents of where it has none of its own (`chat_agent`).
        const named = (address: string, j: J): J => {
          const chat = get(j, "chat");
          if (chat !== undefined && chat !== null) {
            if (!multi) return j;
            // (the station named its chat: whose it is, of that row's columns)
            const id = str(get(chat, "id"));
            return { ...j, mine: id !== null && this.#core.data.chatOfJob(address, id)?.mine === true };
          }
          const session = str(get(j, "session"));
          // (its id, title, whether it is archived and the viewer's, of their columns alone)
          const found = session === null ? undefined : this.#core.data.chatOfJob(address, session);
          const mine = !multi || found?.mine === true;
          return found === undefined ? (mine ? j : { ...j, mine }) : { ...j, chat: { id: found.id, title: found.title, archived: found.archived }, ...(mine ? {} : { mine }) };
        };
        const open = stations.filter((s) => s.online).map((s) => [s.address, several ? s.name : null, arr(this.ok({ topic: "jobs", station: s.address })).map((j) => named(s.address, j as J))] as [string, string | null, J[]]);
        // Their simulators, open terminals and the views of their screens too (jobs.ts `longScreens`, `longTerminals`).
        const screens = stations.filter((s) => s.online).map((s) => [s.address, several ? s.name : null, arr(get(this.ok({ topic: "screens", station: s.address }), "screens")), !multi] as jobs.HeldScreens);
        const terminals = stations.filter((s) => s.online).map((s) => [
          s.address,
          several ? s.name : null,
          arr(get(this.ok({ topic: "terminals", station: s.address }), "terminals")).map((item) => {
            const chat = str(get(item, "chat"));
            const found = chat === null ? undefined : this.#core.data.chatTitled(s.address, chat);
            // Old runners only kept a display name. Attribute it only when the roster identifies one opener.
            const recorded = str(get(item, "byEmail"));
            const by = str(get(item, "by"));
            const matches = !recorded && by ? members.filter((m) => (m.name || m.email) === by) : [];
            const opener = recorded || (matches.length === 1 ? str(matches[0].email) : null);
            const mine = members.length === 1 || (!!email && opener?.toLowerCase() === email);
            return { ...item, mine, ...(found ? { chatObj: { id: found.id, title: found.title, archived: found.archived } } : {}) };
          }),
        ] as jobs.HeldTerminals);
        const prefs = this.ok({ topic: "prefs" }) ?? null;
        const bell = { on: badgeKindsOf(prefs).services, seen: jobsSeenOf(prefs, view.scope as string) };
        const clock = this.#clock();
        // Asked again as the next of them has been up an hour, or as how long one has says something else (nothing else
        // would say it: present.ts NO_TICK).
        const next = jobs.longNext(open, screens, clock.now, terminals);
        if (next !== null) this.#againIn(next);
        return { ok: jobs.longJobs(open, clock, (session) => this.#ranFrom(stations, session, multi), bell, screens, terminals) };
      }
    }
    return undefined;
  }

  /// The chat on another of the scope's stations a task here runs for (`jobs.remoteOwner`), as that station's sidebar
  /// has it: the one its session names, else one it takes part in (data.ts chatOfJob); the viewer's where that chat is
  /// (`multi`: others are members) or where nobody else is.
  #ranFrom(stations: StationInfo[], session: string, multi: boolean): jobs.From | null {
    const owner = jobs.remoteOwner(session);
    const station = owner && stations.find((s) => s.address === owner.station);
    if (!owner || !station) return null;
    const row = this.#core.data.chatOfJob(station.address, owner.session);
    return { name: station.name, chat: row === undefined ? null : { id: row.id, title: row.title, archived: row.archived, station: station.address }, mine: !multi || row?.mine === true };
  }

  /// When the chats of `stations` marked archived were, from `from` on (their `archived_at`: the mark's moment, else their
  /// last activity, as archive.ts has it), by station: for each a moment of its local day (`offset` minutes east of
  /// UTC, format.ts localDay), as many as were archived on it, counted by SQLite; what reads them by their day reads
  /// them as it would their own moments.
  #archivedDays(stations: string[], from: number, offset: number): Map<string, number[]> {
    const out = new Map<string, number[]>();
    if (stations.length === 0) return out;
    // (each station's counted and kept by itself: a chat archived on one counts no other again)
    for (const station of stations) {
      const days: number[] = [];
      for (const [, day, n] of this.#core.data.chatCounted(CHAT_READS.archivedCount, { station, threads: [], sessions: [], from, offset: offset * 60_000, day: DAY_MS })) {
        if (day === null || typeof day !== "number") continue;
        const at = day * DAY_MS - offset * 60_000 + DAY_MS / 2;
        for (let i = 0; i < Number(n); i++) days.push(at);
      }
      if (days.length > 0) out.set(station, days);
    }
    return out;
  }

  /// Whether a station's list is known, never its rows: read, `{ ok: null }`; not read yet, what its topic says (an error,
  /// or nothing), which reads none of its rows then (data.ts shared: a list never read has none to load).
  listKnown(station: string, kind: "chats" | "archived"): Value | undefined {
    if (this.#core.data.listed(station, kind)) return { ok: null };
    return this.value({ topic: kind === "chats" ? "chatRows" : "archivedRows", station });
  }

  /// Has what is being computed made again in `ms` (clock.ts `reached`).
  #againIn(ms: number): void {
    if (Number.isFinite(ms)) this.#moments.reached(untracked(() => this.#core.host.nowMs()) + Math.ceil(ms));
  }

  /// Re-checks waiting deadline moments against the wall clock (e.g. after wake/reconnect).
  checkMoments(): void {
    this.#moments.check();
  }

  // ── the chat list ──

  /// A scope's chat list as a page shows it: its first `first` rows (its window), and how many more it has (`more`). Read
  /// as a window over the index, never a station's rows whole (#chatsOf `windowed`).
  #chats(scope: string, mine: boolean, watching: boolean, visibility: Visibility, first: number): Value | undefined {
    return this.#chatsOf(scope, mine, watching, visibility, first, true).value;
  }

  /// A scope's chat list whole, every row of it: what search, chatSearch and a share's choice read till each chat has
  /// what finds it kept beside it (scripts/whole-lists.ts). `first`: how many rows a page shows of it first, what is read
  /// of its stations' records for its first screen while they are not loaded (#head).
  #chatsWhole(scope: string, mine: boolean, watching: boolean, visibility: Visibility = "visible", first = WINDOW_UNTOLD): Value | undefined {
    return this.#chatsOf(scope, mine, watching, visibility, first, false).value;
  }

  /// `windowed`: its first `first` rows alone, read as the list's order has them through the index (data.ts chatFound,
  /// db/chat-reads.ts `window`), those overlaid here read apart by their keys and made as the list makes them (local.ts
  /// overlaid), how many it shows and which stations' rows run counted by SQLite (`counts`); a row kept beside its record
  /// taken from the cache where held, its text read only where not. Else the stations' rows whole (#chatsWhole).
  /// With it, how many of its rows run (their `state`: `running`), counted of a windowed list.
  /// Its rows and days are made apart from what its stations' links say (#chatsMade, a computed kept by the list and its
  /// window), so that a link's state, its catching up (each batch of it on its way back, 14 in a minute, each making a
  /// phone's list again whole: 1,170 ms, 2026-11-18) or its speed makes again only what is said of the stations here.
  #chatsOf(scope: string, mine: boolean, watching: boolean, visibility: Visibility, first: number, windowed: boolean): { value: Value | undefined; running: number } {
    // (and by the local day and the zone's offset: its days are made again as either is another, #daysOf, whatever made
    // the list again then, the clock's turn at midnight, a zone changed)
    const host = this.#core.host;
    const nowMs = host.nowMs();
    const offset = host.utcOffsetMin(nowMs);
    const key = `${scope}\u0001${mine}\u0001${watching}\u0001${visibility}\u0001${windowed}\u0001${first}\u0001${Math.floor((nowMs + offset * 60_000) / DAY_MS)}\u0001${offset}`;
    let kept = this.#chatsMadeKept.get(key);
    if (kept === undefined) kept = computed(() => this.#chatsMade(scope, mine, watching, visibility, first, windowed));
    this.#chatsMadeKept.delete(key);
    this.#chatsMadeKept.set(key, kept);
    // (a few lists': those shown, and the last ones left)
    for (const k of this.#chatsMadeKept.keys()) if (this.#chatsMadeKept.size > CHATS_MADE_KEPT) this.#chatsMadeKept.delete(k);
    const made = kept.get();
    if ("value" in made) return { value: made.value, running: 0 };
    const { stations, me, days, more, total, running, runningRows, unread, reads } = made;
    const data = this.#core.data;
    const states: J[] = [];
    // Each station in trouble: its state, its line, the words said once when every one says the same (the device's
    // network; this app or page too old for them), and its address.
    const troubles: [string, string, string | null, string][] = [];
    // The stations find this core too old (link.ts TooOld `app`): a web page is reloaded, an app updated.
    const appOld = this.#core.host.appKeys === true ? t("core-views.station.appOld") : t("core-views.station.pageOld");
    let loading = false;
    // Catching up on what changed while away (station/sync.ts `#catching`): whether a station has yet to say what, and
    // how many chats are left to bring the latest of.
    let checking = false;
    let behind = 0;
    for (const s of stations) {
      const read = reads.get(s.address);
      const part = data.overviewPart(s.address);
      let state: string;
      let message: J = null;
      if (!s.online) state = "offline";
      else {
        const link = this.link(s.address);
        const linkState = str(link.state) ?? "connecting";
        if (read !== undefined && read !== "ok") [state, message] = ["error", read.err];
        else if (read === "ok") {
          if (linkState === "error") [state, message] = ["error", link.message];
          else if (linkState === "reconnecting") [state, message] = ["connecting", link.message];
          else state = "online";
        } else {
          loading = true;
          if (linkState === "error") [state, message] = ["error", link.message];
          else state = "connecting";
        }
      }
      if (s.online) {
        const link = this.link(s.address);
        const catching = typeof link.catching === "number" ? (link.catching as number) : null;
        if (link.state === "connecting" && link.retrying !== true) checking = true;
        else if (link.state === "online" && catching !== null) {
          if (catching < 0) checking = true;
          else behind += catching;
        }
      }
      if (state === "offline") troubles.push(["offline", downWords(this.link(s.address), s.name), get(this.link(s.address), "cause") === "network" ? t("core-views.station.network") : null, s.address]);
      else if (state === "error") {
        // Answered that one side is too old (link.ts TooOld): what to update, not 无法连接.
        const old = get(this.link(s.address), "old");
        if (old === "app") troubles.push(["error", appOld, appOld, s.address]);
        else if (old === "station") troubles.push(["incompatible", t("core-views.station.incompatible_named", { name: s.name }), null, s.address]);
        else troubles.push(["error", t("core-views.station.unreachable", { name: s.name }), null, s.address]);
      } else if (state === "connecting" && read === "ok") troubles.push(["reconnecting", t("core-views.station.reconnecting", { name: s.name }), null, s.address]);
      else if (state === "online" && get(this.link(s.address), "hostUnreadable") === true) troubles.push(["incompatible", t("core-views.station.incompatible_named", { name: s.name }), null, s.address]);
      const cause = state === "offline" ? get(this.link(s.address), "cause") : undefined;
      // Refused for a security mode: why.
      if (cause === "lock") message = get(this.link(s.address), "message") ?? null;
      const now = looks.doing(state, cause, part === undefined ? undefined : { counts: { running: get(part, "running") } });
      states.push({ station: s.address, id: s.id, name: s.name, state, message, ...(typeof cause === "string" ? { cause } : {}), ...now, ...rowWords(s, this.link(s.address)) });
    }
    let trouble: J = null;
    if (troubles.length === 1) trouble = { text: troubles[0][1], state: troubles[0][0], retry: false, station: troubles[0][3] };
    else if (troubles.length > 1) {
      const worst = ["error", "offline", "reconnecting", "incompatible"].find((w) => troubles.some(([s]) => s === w)) ?? "offline";
      // Every one down as the device's network is, or finding this app too old: that, once, and not as so many stations
      // amiss.
      const once = troubles[0][2];
      const same = once !== null && troubles.every(([, , w]) => w === once);
      trouble = { text: same ? once : t("core-views.station.troubles", { n: troubles.length }), state: worst, retry: false };
    }
    const glyph = windowed ? looks.glyphOf(states, stations.map((s) => s.address).filter((a) => running.has(a))) : looks.glyph(states, days);
    const note = looks.listNote(states, windowed ? total > 0 : days.length > 0, loading, unread);
    const ws = this.ok({ topic: "workspace", workspace: scope });
    const count = Array.isArray(get(ws, "members")) ? ws.members.length : null;
    // (one station still to say: how many are left is not known yet)
    const syncing = checking ? t("core-views.station.syncing") : behind > 0 ? t("core-views.station.syncing_left", { n: behind }) : null;
    const interrupted: J[] = [];
    for (const s of stations) {
      if (!s.online) continue;
      const raw = get(this.#core.data.overviewPart(s.address), "interrupted");
      const count = u64(get(raw, "count")) ?? 0;
      if (count <= 0) continue;
      const chats = arr(get(raw, "items")).flatMap((item) => {
        const key = str(get(item, "key"));
        if (!key) return [];
        const thread = u64(get(item, "thread"));
        const title = str(get(item, "title")) ?? "";
        return [{ key, ...(thread !== null ? { thread } : {}), title }];
      });
      interrupted.push({ station: s.address, stationName: s.name, count, chats });
    }
    return { value: { ok: { me, stations: states, loading, days, trouble, members: count, leading: "agents", glyph, note, ...(syncing !== null ? { syncing } : {}), ...(more > 0 ? { more } : {}), ...(interrupted.length > 0 ? { interrupted } : {}) } }, running: runningRows };
  }

  /// What #chatsOf makes of a list that no station's link says: its stations, its days (its first `first` rows where
  /// `windowed`) and how many more it has, how many it has and which stations' rows run, and whether each station's
  /// rows were read (`reads`: read, its error, or not yet). Read in a computed (#chatsMadeKept), it reads no link: what
  /// the stations' links say is said of it by #chatsOf alone.
  #chatsMade(scope: string, mine: boolean, watching: boolean, visibility: Visibility, first: number, windowed: boolean): ChatsMade {
    const stations = this.#stationsOr(scope);
    if (stations === undefined || !Array.isArray(stations)) return { value: stations as Value | undefined };
    let runningRows = 0;
    const data = this.#core.data;
    const me = this.me(scope);
    const workspace = this.ok({ topic: "workspace", workspace: scope });
    const members_ = arr(get(workspace, "members"));
    // (written out once for every station's rows' signature: `sig` below)
    let membersJson: string | null = null;
    const hint = this.#core.store.select({ topic: "prefs" }, archiveHintIn);
    const reads = new Map<string, "ok" | { err: J }>();
    const rows: J[] = [];
    // The rows each station's records made last time (`keptBetween`), and which of them changed since.
    const listKey = `${scope}\u0001${mine}\u0001${watching}\u0001${visibility}\u0001${windowed}`;
    let keptLists = this.#chatsKept.get(listKey);
    if (keptLists) {
      this.#chatsKept.delete(listKey);
      this.#chatsKept.set(listKey, keptLists);
    } else {
      this.#chatsKept.set(listKey, (keptLists = new Map()));
      while (this.#chatsKept.size > CHATS_MADE_KEPT) this.#chatsKept.delete(this.#chatsKept.keys().next().value!);
    }
    let whole = false;
    const gone: J[] = [];
    const come: J[] = [];
    const unread: string[] = [];
    // The first screen first: while the stations' rows are not loaded, and they are more than the list shows first
    // (its window, and one more to know it has more), those are read by one query, and the rest are loaded after, a
    // station at a time.
    const known = stations.filter((s) => data.listed(s.address, "chats")).map((s) => s.address);
    const unloaded = known.filter((s) => !data.loaded({ topic: "chatRows", station: s }));
    const heads = first + 1;
    // Whether the list shows a record, as `make` below decides it of each before its row is made: what the first
    // screen's records are read by (#head), so a list of some of its stations' chats (the viewer's own, the hidden,
    // the watched, none of those being archived here) opens on its window of them, not on those of them among the
    // first of all.
    const shows = (station: string, raw: J): boolean => {
      // (a row kept beside its record: the viewer's own, where only those were read)
      if (mine && !keptWholes.has(raw) && get(raw, "mine") !== true) return false;
      if (this.local.beingArchived(station, raw)) return false;
      const shown = this.local.asChanging(station, raw);
      if ((visibility === "visible" || visibility === "hidden") && (get(shown, "hidden") === true) !== (visibility === "hidden")) return false;
      // (a chat an agent leads is in no list but a search: its opener's info leads to it, the user 2026-11-17)
      if (visibility !== "found" && decisions.led(shown)) return false;
      return !watching || present.watches(arr(get(shown, "agents")));
    };
    // (the key each station's rows are kept by beside their records, where they are read so: listRowKey)
    const keyOf = (s: StationInfo): string => this.#listKeyOf(s, stations.length > 1, me, members_, hint);
    const head = !windowed && unloaded.length > 0 && data.chatCount(unloaded) > heads
      ? this.#head(scope, known, heads, mine, shows, watching ? new Map() : new Map(stations.filter((s) => known.includes(s.address)).map((s) => [s.address, keyOf(s)])))
      : null;
    // The window: what it reads of each station, its rows in the list's order (a row kept beside its record, else its
    // record) then those overlaid here; each station's count and whether one of its rows runs, but those overlaid.
    const win = windowed ? this.#window(stations.filter((s) => known.includes(s.address)), mine, watching, visibility, first, watching ? new Map() : new Map(stations.filter((s) => known.includes(s.address)).map((s) => [s.address, keyOf(s)]))) : null;
    // (what the window shows of each station, and which stations' rows run: those overlaid and asked here added below)
    let total = 0;
    const running = new Set<string>();
    for (const s of stations) {
      const read = win !== null
        ? (data.listed(s.address, "chats") ? ({ ok: win.items.get(s.address) ?? [] } as Value) : this.listKnown(s.address, "chats"))
        : head !== null && data.listed(s.address, "chats") ? ({ ok: head.get(s.address) ?? [] } as Value) : this.value({ topic: "chatRows", station: s.address }); // whole-lists: #chatsWhole
      if (!(read && "ok" in read)) unread.push(s.address);
      if (read && "ok" in read) reads.set(s.address, "ok");
      else if (read && "err" in read) reads.set(s.address, { err: read.err.message });
      // What the list reads of its station's overview, kept beside it (account.ts overviewPart): not the whole of it,
      // the largest record there is (3.25 ms of the list's 21.8 ms in Hermes, five stations read and parsed, 2026-11-11),
      // and the list made again only as this changes, not with each quota, usage or job of the overview.
      const part = data.overviewPart(s.address);
      if (read && "ok" in read) {
        const slackUsers = arr(get(part, "slackUsers")).filter((u): u is string => typeof u === "string");
        this.local.settle(s.address, data.rowsRev(s.address));
        // (the window's rows as they were, the same rows: the list it made them into last time, so that they are taken
        // as they were by one comparison, `was.listed === listed` below)
        const was = keptLists.get(s.address);
        const read_ = arr(read.ok);
        const listed = was !== undefined && was.listed !== read_ && was.listed.length === read_.length && read_.every((r, i) => r === was.listed[i]) ? was.listed : read_;
        const asked = [...this.local.pendingRows(s.address), ...this.local.restoringRows(s.address).filter((row) => {
          const thread = get(row, "thread");
          const session = get(row, "session");
          return (typeof thread === "number" ? data.chatOfThread(s.address, thread) : data.chatForSession(s.address, String(session ?? ""))) === undefined;
        })];
        // What failed to go in the station's chats, once for the list (looked up for each row, 1400 of them, on every
        // change of one: 2026-11-08).
        const failed = this.local.failedOutboxes(s.address);
        // (and the chats made here whose first words are on their way: #unsentRow)
        const going = this.local.goingFirsts(s.address);
        // What a row is made with besides its record: a row whose record and these are as they were is the one made
        // before (rule 7: the list redoes only the rows that changed). Not its station's link: what that makes of a row
        // goes once for the station (`stations`, stationOn), not on each of its rows. Nor what only its whole row
        // reads (#wholeOf: the menu's connects and the viewer's role and workspaces, the clock its time is said by).
        // Its station's emoji and icon only with several stations (with one, it says nothing).
        const mark = stations.length > 1 ? { emoji: s.emoji, icon: s.icon } : null;
        // (the members: those of them it names, its own, `rowSig`; all of them for the list's kept rows, `sig`, which
        // each row then looks at again)
        const base = JSON.stringify([s.address, s.name, mark, me, slackUsers, watching, hint]);
        // (as JSON.stringify([base, members_]) writes it, the members written out once for all the stations)
        const sig = `[${JSON.stringify(base)},${(membersJson ??= JSON.stringify(members_))}]`;
        // (the base as it is and the members after a character JSON never leaves unescaped, U+0001: one signature for one
        // pair, as JSON.stringify([base, members]) was, without writing the base out again escaped for each row)
        const rowSig = (shown: J) => `${base}\u0001${JSON.stringify(present.rowMembers(shown, members_))}`;
        // A row kept beside its record (#head): its stand-in, the row it stands for as it is; one changing or asked
        // here, made of its record as it is read (what a row kept beside it is never made with: #keepable).
        const keptRow = (h: HeadRow): J | null => {
          work.listed++;
          const whole = h.row!.whole;
          if (this.local.beingArchived(s.address, whole)) return null;
          const asked = typeof whole.clientKey !== "string" && typeof whole.session === "string" && this.local.pendingKey(s.address, whole.session) !== undefined;
          if (asked || this.local.asChanging(s.address, whole) !== whole) {
            const record = data.chat(s.address, h.id);
            return record === undefined ? null : make(record);
          }
          if (visibility === "visible" && whole.hidden === true) return null;
          if (visibility === "hidden" && whole.hidden !== true) return null;
          if (visibility !== "found" && decisions.led(whole)) return null;
          const standIn: J = { lastActiveAt: whole.lastActiveAt, station: s.address, state: h.row!.state };
          if (h.pinnedAt !== null) {
            pinnedAt.set(standIn, h.pinnedAt);
            pinnedAt.set(whole, h.pinnedAt);
          }
          Object.freeze(standIn);
          let shownRow: J;
          unmade.set(standIn, () => (shownRow ??= this.#unsentRow(s.address, whole, failed, whole, going)));
          return standIn;
        };
        // (the key its rows are kept by beside their records: none for a list of the watched, whose rows are made)
        const key = watching ? null : keyOf(s);
        // One record's row, or null where the list does not show it.
        const make = (raw: J): J | null => {
          const h = headKept.get(raw);
          if (h !== undefined) return keptRow(h);
          work.listed++;
          if (mine && get(raw, "mine") !== true) return null;
          if (this.local.beingArchived(s.address, raw)) return null;
          const shown = this.local.asChanging(s.address, raw);
          if (visibility === "visible" && get(shown, "hidden") === true) return null;
          if (visibility === "hidden" && get(shown, "hidden") !== true) return null;
          if (visibility !== "found" && decisions.led(shown)) return null;
          // Only a frozen row (db/account.ts) is surely as it was when its row was made.
          const keepable = isObject(shown) && Object.isFrozen(shown);
          const kept = keepable ? this.#rowsMade.get(shown) : undefined;
          // (held by the list's signature where that is as it was, every row of it then; its own, of the members it
          // names, worked out only where the list's changed: for each of 420 records at every making of a list it was
          // a signature a record)
          let own_: string | undefined;
          const own = () => (own_ ??= rowSig(shown));
          const holds = (k: { sig: string; list: string; row: J } | undefined): boolean => {
            if (k === undefined) return false;
            if (k.list === sig) return true;
            if (k.sig !== own()) return false;
            // (held by the list as it is now: looked at once for this change of the list's)
            this.#rowsMade.set(shown, { sig: k.sig, list: sig, row: k.row });
            return true;
          };
          if (kept !== undefined && holds(kept)) return kept.row === null ? null : this.#unsentRow(s.address, kept.row, failed, shown, going);
          const row = (): J => {
            // (kept beside its record under the key in force, where it was read or kept this run; else made, and kept)
            const keeps = key !== null && shown === raw && this.#keepable(s.address, raw);
            const kept = keeps ? data.kept(KEPT.listRow, [s.address, String(raw.id)], key) : undefined;
            const made = kept !== undefined ? kept.whole : this.#chatRow(s, shown, me, slackUsers, members_, watching, mark, hint, false, this.#goneOf(s.address));
            // Frozen all through: a row made once and shared from then on (output.ts takes it as it is). What it took of
            // its record as it is was frozen all through with it (db/account.ts `frozen` freezes a part after all of
            // its own): deepFreeze stops there, and walks only what was made here.
            if (made !== null && kept === undefined) {
              deepFreeze(made);
              if (keeps) this.#keepMade(s.address, raw, key, made);
            }
            // (one read as kept is its JSON: when it was pinned, as #chatRow says of one it makes, or a list made again
            // of it puts it among its day's)
            if (made !== null && typeof shown.pinned === "number") pinnedAt.set(made, shown.pinned);
            if (keepable) this.#rowsMade.set(shown, { sig: own(), list: sig, row: made });
            return made;
          };
          if (!keepable || get(shown, "pending") === true) {
            const made = row();
            return made === null ? null : this.#unsentRow(s.address, made, failed, shown, going);
          }
          // Kept, its row is made as something shows it (`unmade`): until then a stand-in, the list not showing it
          // decided as its row would (#chatRow: watching, one nobody watches).
          const agents = arr(get(shown, "agents"));
          if (watching && !present.watches(agents)) {
            this.#rowsMade.set(shown, { sig: own(), list: sig, row: null });
            return null;
          }
          const standIn: J = { lastActiveAt: shown.lastActiveAt, station: s.address, state: present.rowState(agents) };
          if (typeof shown.pinned === "number") pinnedAt.set(standIn, shown.pinned);
          Object.freeze(standIn);
          let shownRow: J;
          unmade.set(standIn, () => {
            if (shownRow === undefined) {
              const again = this.#rowsMade.get(shown);
              shownRow = this.#unsentRow(s.address, again !== undefined && holds(again) && again.row !== null ? again.row : row(), failed, shown, going);
            }
            return shownRow;
          });
          return standIn;
        };
        // What the station's rows were made into last time, kept while nothing here changes how a row is made (no row
        // asked for, archived or changed from here; its failed messages and what rows are made with as they were): then
        // only the records between the same ones at both ends are made again, so a chat that changed costs its row
        // (each change of one made all of a station's 1400 again, 2026-11-08).
        const failedKey = JSON.stringify([[...failed].map(([thread, m]) => [thread, get(m, "id"), get(m, "text")]), [...going]]);
        const quiet = head === null && asked.length === 0 && this.local.rowsQuiet(s.address);
        let made: (J | null)[];
        if (quiet && was !== undefined && was.sig === sig && was.failedKey === failedKey) {
          if (was.listed === listed) made = was.made;
          else {
            const between = keptBetween(was.listed, was.made, listed, make);
            made = between.made;
            gone.push(...between.gone);
            come.push(...between.come);
          }
        } else {
          made = listed.map(make);
          whole = true;
        }
        if (quiet) keptLists.set(s.address, { listed, made, sig, failedKey });
        else keptLists.delete(s.address);
        for (const raw of asked) {
          const row = make(raw);
          if (row !== null) {
            rows.push(row);
            total++;
            if (get(row, "state") === "run") {
              running.add(s.address);
              runningRows++;
            }
          }
        }
        for (const row of made) if (row !== null) rows.push(row);
        if (win !== null) {
          const counted = win.counts.get(s.address);
          total += counted?.n ?? 0;
          if (counted?.runs === true) running.add(s.address);
          runningRows += counted?.running ?? 0;
          // (those overlaid here, made as the list makes them: what the counts left out)
          listed.forEach((raw, i) => {
            if (!win.apart.has(raw) || made[i] === null) return;
            total++;
            if (get(made[i], "state") !== "run") return;
            running.add(s.address);
            runningRows++;
          });
        }
      }
    }
    let days = this.#daysOf(listKey, rows, { whole, gone, come });
    // (the window's first rows of what it read, in the list's order; how many more it has, of the counts)
    let more = 0;
    if (win !== null) {
      const cut = firstRows({ days }, first);
      days = arr(cut.days);
      const shown = days.reduce((n, d) => n + arr(get(d, "items")).length, 0);
      more = total - shown;
    }
    return { stations, me, days, more, total, running, runningRows, unread, reads };
  }

  /// What a chat list's window reads of `stations` (#chatsOf `windowed`): of each, its first rows in the list's order
  /// (`items`: a row kept beside its record under its station's key in `keys`, as a HeadRow, else its record; at most
  /// `first` of them in all), then its rows overlaid here (`apart`: what local.ts overlaid names, every one, each its
  /// record); and of each its count and whether one of its rows runs, of the rows the window is of but those overlaid.
  #window(stations: StationInfo[], mine: boolean, watching: boolean, visibility: Visibility, first: number, keys: Map<string, string>): { items: Map<string, J[]>; apart: Set<J>; counts: Map<string, { n: number; runs: boolean; running: number }> } {
    const data = this.#core.data;
    const addresses = stations.map((s) => s.address);
    const threads: string[] = [];
    const sessions: string[] = [];
    for (const a of addresses) {
      const o = this.local.overlaid(a);
      for (const t0 of o.threads) threads.push(`${a}\u0001${t0}`);
      for (const k of o.sessions) sessions.push(`${a}\u0001${k}`);
    }
    const p = { stations: addresses, mine, hidden: visibility === "hidden" ? 1 : visibility === "all" || visibility === "found" ? 2 : 0, watching, threads, sessions, limit: first } as const;
    const items = new Map<string, J[]>();
    const counts = new Map<string, { n: number; runs: boolean; running: number }>();
    const apart = new Set<J>();
    if (addresses.length === 0) return { items, apart, counts };
    // (each station's in its own order, as its rows were listed whole: by their place, then their ids)
    const placed = new Map<string, { item: J; ord: number; id: string }[]>();
    const put = (station: string, item: J, ord: SqlValue, id: string) => {
      let list = placed.get(station);
      if (list === undefined) placed.set(station, (list = []));
      list.push({ item, ord: typeof ord === "number" ? ord : 0, id });
    };
    // (the rows kept beside their records read of them alone, from the cache where held; the records of the rest. A
    // record held already is taken as it is, kept beside it or not: what the list made of it before is taken again)
    // (the stations' rows in the list's order, across their databases: each read its own first. The window's answer is
    // of their keys and columns alone, read again only as a write changes what of a row it reads (chat-reads.ts `by`):
    // each row's record or kept row is taken by its own key, so a chat that changes and moves nothing is told by its key)
    const found = data.chatFound(CHAT_READS.window, p, () => false);
    const place = new Map(addresses.map((a, i) => [a, i]));
    const shown = [...found].sort((a, b) => {
      const pa = typeof a.cols[0] === "number";
      const pb = typeof b.cols[0] === "number";
      if (pa !== pb) return pa ? -1 : 1;
      if (pa && a.cols[0] !== b.cols[0]) return (b.cols[0] as number) - (a.cols[0] as number);
      const la = typeof a.cols[1] === "number" ? a.cols[1] : 0;
      const lb = typeof b.cols[1] === "number" ? b.cols[1] : 0;
      if (la !== lb) return lb - la;
      return (place.get(a.station) ?? -1) - (place.get(b.station) ?? -1);
    }).slice(0, first);
    for (const f of shown) f.record = data.heldChat(f.station, f.id);
    const notHeld = shown.filter((f) => f.record === undefined);
    const kept = data.keptMany(KEPT.listRow, notHeld.map((f) => [f.station, f.id]), notHeld.map((f) => keys.get(f.station) ?? ""));
    data.chatRecords(notHeld.filter((_, i) => kept[i] === undefined));
    const keptOf = new Map(notHeld.map((f, i) => [f, kept[i]]));
    for (const f of shown) {
      const row = keptOf.get(f);
      if (row !== undefined) put(f.station, headOf(f.station, f.id, typeof f.cols[0] === "number" ? f.cols[0] : null, row), f.cols[2], f.id);
      else if (f.record !== undefined) put(f.station, f.record, f.cols[2], f.id);
    }
    if (threads.length > 0 || sessions.length > 0) {
      for (const f of data.chatFound(CHAT_READS.overlaid, { stations: addresses, archived: false, threads, sessions })) {
        if (f.record === undefined) continue;
        apart.add(f.record);
        put(f.station, f.record, f.cols[0], f.id);
      }
    }
    for (const [station, list] of placed) {
      list.sort((a, b) => a.ord - b.ord || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
      items.set(station, list.map((x) => x.item));
    }
    // (each station's counted alone, kept by itself: one station's chat starting its work reads that station's again)
    for (const station of addresses) {
      const r = data.chatCounted(CHAT_READS.counts, { station, mine, hidden: p.hidden, watching, threads, sessions })[0];
      if (r !== undefined) counts.set(station, { n: Number(r[0] ?? 0), runs: r[1] === 1, running: Number(r[2] ?? 0) });
    }
    return { items, apart, counts };
  }

  /// The messages a search's words find in the chats the sidebar lists (those `refs.search` would list, by the same
  /// station and exclusion), newest first, at most `view.messages`: each with its chat's row, who said it and its line.
  /// What the search (views/search.ts) reads of the views.
  readonly #searchSource: SearchSource = {
    moved: (station, thread) => this.#core.data.movedThread(station, thread) !== undefined,
    value: (topic) => this.value(topic),
    ok: (topic) => this.ok(topic),
    stations: (scope) => this.stations(scope),
    foundMessages: (chats, view) => this.#foundMessages(chats, view),
    whole: (row) => this.wholeFor(row),
    me: (scope) => this.me(scope),
    clock: () => this.#clock(),
  };

  #foundMessages(chats: J, view: Topic): J[] {
    const words = refs.terms(view.query as string);
    if (words.length === 0) return [];
    const scope = view.scope as string;
    const rows = new Map<string, J>();
    for (const item of arr(get(chats, "days")).flatMap((d) => arr(get(d, "items")))) {
      if (get(item, "pending") === true || typeof item.thread !== "number") continue;
      if (typeof view.station === "string" && item.station !== view.station) continue;
      if (typeof view.exclude === "string" && (item.id === view.exclude || item.session === view.exclude)) continue;
      rows.set(`${item.station}\u0001${item.thread}`, item);
    }
    const stations = [...new Set([...rows.values()].map((i) => i.station as string))];
    const wanted = view.messages as number;
    const data = this.#core.data;
    const me = this.me(scope);
    const members_ = arr(get(this.ok({ topic: "workspace", workspace: scope }), "members"));
    const clock = this.#clock();
    const out: J[] = [];
    // Those of chats not listed (archived) are passed over: some more are asked for.
    for (const hit of data.findSaid(stations, words, wanted * 3)) {
      const chat = rows.get(`${hit.station}\u0001${hit.thread}`);
      if (!chat) continue;
      const entry = data.logRange("entry", hit.station, String(hit.thread), hit.seq, hit.seq).get(hit.seq);
      const slackUsers = arr(get(this.ok({ topic: "overview", station: hit.station }), "slackUsers")).filter((u): u is string => typeof u === "string");
      const by = isObject(entry) ? present.lastBy({ last: entry, agents: chat.agents }, me, slackUsers, members_) : null;
      const message: J = { station: hit.station, thread: hit.thread, seq: hit.seq, by: str(get(by, "name")) ?? "", ...refs.excerpt(hit.text, words) };
      if (hit.at !== null) message.createdAt = hit.at;
      // Its chat's row as the list made it (frozen), whole (wholeFor).
      out.push({ chat: this.wholeFor(chat), ...(present.times(message, clock) as J) });
      if (out.length >= wanted) break;
    }
    return out;
  }

  /// The key the rows of station `s` are kept by beside their records (listRowKey), made again only as what it is made
  /// of is another: one short string a station, not a row.
  #listKeyOf(s: StationInfo, several: boolean, me: J, members: J[], hint: ArchiveHint): string {
    const part = this.#core.data.overviewPart(s.address);
    const gone = this.#goneOf(s.address);
    const of: unknown[] = [s.address, s.name, several ? s.emoji : null, several ? s.icon : null, several, get(me, "email"), members, part, hint, gone, lang(), brand.name()];
    const was = this.#listKeys.get(s.address);
    if (was !== undefined && was.of.length === of.length && was.of.every((x, i) => x === of[i])) return was.key;
    const slackUsers = arr(get(part, "slackUsers")).filter((u): u is string => typeof u === "string");
    const key = listRowKey(s, several ? { emoji: s.emoji, icon: s.icon } : null, me, slackUsers, members, hint, gone);
    this.#listKeys.set(s.address, { of, key });
    return key;
  }

  /// The failures of `station`'s chats the viewer let go (goneIn), as its rows' stage reads them.
  #goneOf(station: string): readonly string[] {
    return this.#core.store.select({ topic: "prefs" }, goneIn(station));
  }

  /// What a row of `station`'s list is made with besides its record, as a list makes it (#chats), and its key; null while
  /// its workspace or the station in it is not read.
  #aroundOf(station: string): Around | null {
    // (as many times as records are written: made again only as what it is made of is another, the workspace's value,
    // the station's part, the prefs, the language, the viewer)
    const scope = ofAddress(station);
    const ws = this.value({ topic: "workspace", workspace: scope });
    const of: unknown[] = [ws === undefined ? undefined : "ok" in ws ? ws.ok : ws, this.#core.data.overviewPart(station), this.#core.store.select({ topic: "prefs" }, archiveHintIn), this.#goneOf(station), this.#core.emailOf(scope), lang(), brand.name()];
    const was = this.#arounds.get(station);
    if (was !== undefined && was.of.every((x, i) => x === of[i])) return was.around;
    const around = this.#aroundMade(station);
    this.#arounds.set(station, { of, around });
    return around;
  }

  #aroundMade(station: string): Around | null {
    const scope = ofAddress(station);
    const stations = this.#stationsOr(scope);
    if (stations === undefined || !Array.isArray(stations)) return null;
    const s = stations.find((x) => x.address === station);
    if (s === undefined) return null;
    const me = this.me(scope);
    const members = arr(get(this.ok({ topic: "workspace", workspace: scope }), "members"));
    const hint = this.#core.store.select({ topic: "prefs" }, archiveHintIn);
    const slackUsers = arr(get(this.#core.data.overviewPart(station), "slackUsers")).filter((u): u is string => typeof u === "string");
    const mark = stations.length > 1 ? { emoji: s.emoji, icon: s.icon } : null;
    return { s, mark, me, slackUsers, members, hint, gone: this.#goneOf(station), key: this.#listKeyOf(s, stations.length > 1, me, members, hint) };
  }

  /// Whether a record's list row is one kept beside it: made of it and of what the key says alone. Not one changing here
  /// (an overlay: local.ts asChanging, being archived), asked here (pending, its key here: #placeOf), nor opened from
  /// another chat (its opener's title and whether it is archived are that chat's record's: #opener), made as it is read.
  #keepable(station: string, record: J): boolean {
    if (!isObject(record) || !Object.isFrozen(record) || record.pending === true) return false;
    if (str(get(get(record, "opener"), "session")) !== null) return false;
    if (typeof record.clientKey !== "string" && typeof record.session === "string" && this.local.pendingKey(station, record.session) !== undefined) return false;
    return !this.local.beingArchived(station, record) && this.local.asChanging(station, record) === record;
  }

  /// A record's list row as it is written (db/kept.ts `wrote`): what #chats makes of it (#listRow, frozen), as it
  /// goes out (`ListedChat`, beside it), what its stand-in says; null where it is not kept (#keepable) or its station's
  /// surroundings are not read.
  #keptMade(station: string, record: J): ListRow | null {
    const a = this.#aroundOf(station);
    if (a === null || !this.#keepable(station, record)) return null;
    const whole = this.#listRow(a.s, record, a.me, a.slackUsers, a.members, a.mark, a.hint, a.gone);
    deepFreeze(whole);
    const sent = conformTy("ListedChat", whole);
    if (!("ok" in sent) || !isObject(sent.ok)) return null;
    const row = { state: present.rowState(arr(get(record, "agents"))), whole, sent: sent.ok };
    listRowTaken(row);
    return row;
  }

  /// A row a list made as it read it (`whole`), or one it read the record of and did not make (null: made then, as it
  /// would have been), kept beside its record once what pages wait for is out (`answered`): what the next list reads
  /// under the same key.
  #keepMade(station: string, record: J, key: string, whole: J | null): void {
    this.#toKeep.push({ station, record, key, whole });
    if (this.#toKeep.length > 1) return;
    const store = this.#core.store;
    this.#core.runner.fork(
      Effect.gen({ self: this }, function* () {
        yield* store.answered();
        // (those made first: one read and made too is not made again)
        const kept = [...this.#toKeep.filter((k) => k.whole !== null), ...this.#toKeep.filter((k) => k.whole === null)];
        this.#toKeep = [];
        for (const k of kept) {
          const id = String(k.record.id);
          if (this.#core.data.kept(KEPT.listRow, [k.station, id], k.key) !== undefined) continue;
          if (k.whole === null) {
            // (made as a list makes it, under the key in force then: where that is another, by the next list)
            const made = untracked(() => (this.#aroundOf(k.station)?.key === k.key ? this.#keptMade(k.station, k.record) : null));
            if (made !== null) this.#core.data.keep(KEPT.listRow, [k.station, id], k.record, k.key, made);
            continue;
          }
          const sent = conformTy("ListedChat", k.whole);
          if (!("ok" in sent) || !isObject(sent.ok)) continue;
          deepFreeze(sent.ok);
          shapedBeside(k.whole, "ListedChat", sent.ok);
          this.#core.data.keep(KEPT.listRow, [k.station, id], k.record, k.key, { state: present.rowState(arr(get(k.record, "agents"))), whole: k.whole, sent: sent.ok });
        }
      }),
    );
  }

  /// The rows a scope's list shows on top (`n` of them: its window and one more, to know it has more; 2026-11-11, 80
  /// whatever it showed, 9.5 ms of a list's 12.5 in Hermes making and putting out 50 rows of them on a first open), by
  /// station, while its stations' rows load: one is loaded after another, the list computed again after each. They are
  /// the first records the list shows (`shows`; `mine`, read of the viewer's own alone): where fewer than `n` of those
  /// read are, twice as many are read, until `n` show or there are no more.
  /// Each read its row kept beside its record under its station's key (`keys`, listRowKey) where there is one: then its
  /// record is not read (db/account.ts listHead), and the list takes the row as it is (#chats `keptRow`).
  #head(scope: string, stations: string[], n: number, mine: boolean, shows: (station: string, raw: J) => boolean, keys: Map<string, string>): Map<string, J[]> {
    const data = this.#core.data;
    const out = new Map<string, J[]>();
    let limit = n;
    const item = (h: HeadRow): J => {
      if (h.row === null) {
        // (one not kept under its key: kept after the list's first value, made then where the list did not make it)
        const key = keys.get(h.station);
        if (key !== undefined && this.#keepable(h.station, h.record)) this.#keepMade(h.station, h.record, key, null);
        return h.record;
      }
      headKept.set(h, h);
      keptWholes.add(h.row.whole);
      return h;
    };
    const shown = (h: HeadRow): boolean => shows(h.station, h.row === null ? h.record : h.row.whole);
    let read = data.listHead(stations, limit, mine, keys);
    while (read.length >= limit && read.reduce((k, h) => k + (shown(h) ? 1 : 0), 0) < n) {
      limit *= 2;
      read = data.listHead(stations, limit, mine, keys);
    }
    for (const h of read) out.set(h.station, [...(out.get(h.station) ?? []), item(h)]);
    // (its stations' rows loaded behind the first screen: what shows them is made again then)
    this.#seen.read(`loaded ${scope}`);
    if (!this.#loading.has(scope)) {
      this.#loading.add(scope);
      const store = this.#core.store;
      this.#core.runner.fork(
        Effect.gen({ self: this }, function* () {
          for (const station of stations) {
            yield* Effect.yieldNow;
            // (after what pages wait for: made as a switch of workspace answers its first screen, a station's rows a
            // turn went ahead of each answer after the list's, 2.3-3.5 ms each in Hermes, 2026-11-11)
            yield* store.answered();
            data.shared({ topic: "chatRows", station });
          }
          this.#loading.delete(scope);
          this.#seen.touch(`loaded ${scope}`);
        }),
      );
    }
    return out;
  }

  /// A station's row as the list shows it (null: not in this list; made by #listRow); `whole`, as its own `chatRow` gives
  /// it, its record cloned and worked out whole, with what a press, a hold, a swipe or a pointer reads of it besides (its
  /// watch, its swipe's question, its card: the menu's are #rowMenu's), which the list's rows are made without.
  #chatRow(s: StationInfo, raw: J, me: J, slackUsers: string[], members_: J[], watching: boolean, mark: { emoji: string | null; icon: string | null } | null, hint: ArchiveHint, whole = false, gone: readonly string[] = []): J {
    work.rows++;
    if (!whole) return watching && !present.watches(arr(get(raw, "agents"))) ? null : this.#listRow(s, raw, me, slackUsers, members_, mark, hint, gone);
    work.rowsCloned++;
    let row = structuredClone(raw);
    Object.assign(row, this.#placeOf(s, raw, mark));
    const agents = arr(row.agents);
    const watch = present.rowWatch(agents);
    if (watch !== null) {
      work.watches++;
      row.watch = watch;
    } else if (watching) return null;
    row.state = present.rowState(agents);
    if (Array.isArray(row.agents)) row.agents = row.agents.map((agent: J) => present.session(agent));
    const origin = originOf(row.connect, row.origin);
    if (origin !== null) Object.assign(row, origin);
    if (isObject(row.last)) {
      const text = format.cleanText(format.plainText(str(row.last.text) ?? ""));
      row.last.preview = text === "" ? t("core-views.file") : text;
    }
    Object.assign(row, present.rowPeople(row, me, slackUsers, members_));
    const by = present.lastBy(row, me, slackUsers, members_);
    if (by !== null) {
      row.last.by = by;
      const name = str(by.name) ?? "";
      by.label = typeof by.state === "string" ? t("core-views.by_label", { name, state: present.badgeText(by.state) }) : name;
      by.maker = present.maker(str(by.model));
    }
    row = decisions.presentRow(row, me);
    Object.assign(row, archivingOf(row, hint));
    // A swipe is the viewer's own choice: every made chat can be archived this way while its station is there (its
    // station's state, `stationOn`), regardless of the chat's state or whether it is recommended for archiving.
    if (row.pending !== true) {
      row.swipeArchive = true;
      // (one someone else started: archiving it archives it for everyone in the workspace)
      work.swipeAsks++;
      const shown = get(row.creator, "shown");
      const starter = isObject(shown) && get(shown, "mine") !== true ? str(get(shown, "name")) : null;
      const ask = present.swipeAsk(agents, starter, typeof row.hidden === "boolean");
      if (ask !== null) row.swipeAsk = ask;
    }
    Object.assign(row, stateLineOf(lineForViewer(present.rowStateLine(row), raw, me, members_)));
    Object.assign(row, stageFields(raw, me, { gone, failureOf: () => marks.failureOf(s.address, raw) }));
    const opener = this.#opener(s.address, raw);
    if (opener !== null) row.opener = opener;
    else delete row.opener;
    if (typeof raw.pinned === "number") pinnedAt.set(row, raw.pinned);
    return row;
  }

  /// Where a row's chat is, of its record (`raw`): its station, by name and, with several, by its mark (`mark`); whether
  /// the viewer pinned it (true, in the order they pinned it in: pinnedAt; one unpinned says false); the key a chat made
  /// here was asked for by, kept as long as this device keeps it (its station says it only a while, CLIENT_KEY_KEPT_MS:
  /// the row and the page opened by it are one chat all along). (Both makers of a row: #chatRow, #listRow.)
  #placeOf(s: StationInfo, raw: J, mark: { emoji: string | null; icon: string | null } | null): J {
    const out: J = {};
    if (raw.pinned !== undefined) out.pinned = typeof raw.pinned === "number";
    out.station = s.address;
    out.stationName = s.name;
    if (typeof raw.clientKey !== "string" && typeof raw.session === "string") {
      const key = this.local.pendingKey(s.address, raw.session);
      if (key !== undefined) out.clientKey = key;
    }
    if (mark?.emoji) out.stationEmoji = mark.emoji;
    if (mark?.icon) out.stationIcon = mark.icon;
    return out;
  }

  /// A chat list's row (#chatRow, not `whole`), made as what it is: what its row draws and what the core reads of it
  /// (LIST_ROW_KEYS) out of its record, the values it takes as they are the record's (shared, frozen: a record was
  /// cloned whole into each row, three quarters of it never sent, 2026-11-11), the rest made here: its agents, its last
  /// line, its people as the row draws them. What only its whole row says (its card, its agents' summaries, who said its
  /// last line by name) is not worked out for it; what its state line and mark are worked out of is read of the record.
  #listRow(s: StationInfo, raw: J, me: J, slackUsers: string[], members_: J[], mark: { emoji: string | null; icon: string | null } | null, hint: ArchiveHint, gone: readonly string[]): J {
    const row: J = {};
    for (const k of LIST_ROW_TAKEN) {
      const v = raw[k];
      if (v !== undefined) row[k] = sharedOrCopied(v);
    }
    Object.assign(row, this.#placeOf(s, raw, mark));
    const agents = arr(raw.agents);
    if (raw.agents !== undefined) row.agents = Array.isArray(raw.agents) ? agents.map((a: J) => present.listedAgent(a)) : sharedOrCopied(raw.agents);
    const origin = originOf(raw.connect, raw.origin);
    if (origin !== null) Object.assign(row, origin);
    // Its last line: what it draws of it (RowMessage) and no more.
    const last = raw.last;
    if (isObject(last)) {
      const text = format.cleanText(format.plainText(str(last.text) ?? ""));
      const made: J = {};
      if (last.seq !== undefined) made.seq = last.seq;
      made.by = { mine: present.lastByMine(raw, me, slackUsers) };
      made.preview = text === "" ? t("core-views.file") : text;
      row.last = made;
    } else if (last !== undefined) row.last = last;
    // Its people as its pictures draw them (RowPerson, RowCreator).
    if (raw.people !== undefined || raw.creator !== undefined) {
      const people = present.rowPeople({ people: raw.people, creator: raw.creator }, me, slackUsers, members_);
      row.peopleText = people.peopleText;
      row.people = arr(people.people).map((p: J) => {
        if (!isObject(p)) return p;
        const shown = get(p, "shown");
        const out: J = {};
        if (p.id !== undefined) out.id = p.id;
        if (p.email !== undefined) out.email = p.email;
        out.shown = isObject(shown) ? { name: shown.name, picture: shown.picture, mine: shown.mine } : shown;
        return out;
      });
      if (isObject(raw.creator)) row.creator = get(people.creator, "id") !== undefined ? { id: people.creator.id } : {};
      else if (raw.creator !== undefined) row.creator = sharedOrCopied(raw.creator);
    }
    // Where it stands (its mark, its tone, its state line, whether it is offered to archive), worked out of its record as
    // a whole row's are (decisions.presentRow, present.rowStateLine), its agents' states said as that line reads them.
    const read: J = {
      thread: raw.thread, unread: raw.unread, pinned: raw.pinned, card: raw.card, decision: raw.decision, need: raw.need,
      creator: raw.creator, opener: raw.opener,
      archiveReminderDismissed: raw.archiveReminderDismissed, archiveReviewed: raw.archiveReviewed, archiveRecommended: raw.archiveRecommended,
      agents: Array.isArray(raw.agents) ? agents.map((a: J) => present.agentStated(a)) : raw.agents, state: present.rowState(agents),
    };
    const stood = decisions.presentRow(read, me);
    if ("state" in stood) row.state = stood.state;
    else delete row.state;
    if (stood.tone !== undefined) row.tone = stood.tone;
    Object.assign(row, archivingOf(stood, hint));
    if (row.pending !== true) row.swipeArchive = true;
    Object.assign(row, stateLineOf(lineForViewer(present.rowStateLine(stood), raw, me, members_)));
    // Its column on the board and what it says of its own (chat-stage.ts): of its record and who looks alone (a chat
    // it leads, a background job, said on its record by its station: `opened`, an agent's `waitingAsync`).
    Object.assign(row, stageFields(raw, me, { gone, failureOf: () => marks.failureOf(s.address, raw) }));
    const opener = this.#opener(s.address, raw);
    if (opener !== null) row.opener = opener;
    if (typeof raw.pinned === "number") pinnedAt.set(row, raw.pinned);
    return row;
  }

  /// A chat's row whole, as its own topic gives it (`chatRow {station, session}`; `session` its agent's session, else its
  /// row's id as a link names it): its record made by the maker the list's rows were made by before they were what a row
  /// draws (#chatRow `whole`, #rowMenu: #wholeOf), with what failed to go in it (#unsentRow), as its station's list has
  /// it now. A chat asked for here and not made yet as the list has it. Null where its station lists no such chat (in its
  /// archive, being archived from here, gone); none yet while the station's chats were never listed. Read of the device
  /// alone: one record by its key, not the station's list.
  #wholeRow(station: string, session: string): Value | undefined {
    const stations = this.#stationsOr(ofAddress(station));
    if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
    const s = stations.find((x) => x.address === station);
    if (s === undefined) return { ok: null };
    const data = this.#core.data;
    if (!data.listed(station, "chats")) return undefined;
    this.local.settle(station, data.rowsRev(station));
    const raw: J = data.chatForSession(station, session)
      ?? this.local.pendingRows(station).find((r) => get(r, "session") === session || get(r, "clientKey") === session);
    if (raw === undefined || this.local.beingArchived(station, raw)) return { ok: null };
    const row = this.#wholeOf(s, stations.length > 1, this.local.asChanging(station, raw));
    return { ok: row === null ? null : this.#unsentRow(station, row, undefined, raw) };
  }

  /// A record's row whole (#wholeRow), made with what the list's are (#chats) and what only it reads besides: the menu's
  /// (the viewer's role here, their workspaces, its station's connects, #rowMenu). Kept with its record while those are
  /// as they were.
  #wholeOf(s: StationInfo, several: boolean, shown: J): J | null {
    const scope = ofAddress(s.address);
    const me = this.me(scope);
    const workspace = this.ok({ topic: "workspace", workspace: scope });
    const members_ = arr(get(workspace, "members"));
    // What a row's menu offers besides the list's own (#rowMenu): the viewer's role here, their workspaces (with their role
    // in each, as sharing reads it: xshare.ts shown).
    const menu = { role: str(get(workspace, "role")), places: (this.#core.places?.() ?? []).map((p) => [p.id, p.role] as const) };
    const hint = this.#core.store.select({ topic: "prefs" }, archiveHintIn);
    const part = this.#core.data.overviewPart(s.address);
    const slackUsers = arr(get(part, "slackUsers")).filter((u): u is string => typeof u === "string");
    // (its connects: a Slack or Feishu row's link there, #rowMenu)
    const connects = arr(get(part, "connects"));
    const mark = several ? { emoji: s.emoji, icon: s.icon } : null;
    const sig = JSON.stringify([s.address, s.name, mark, me, slackUsers, members_, hint, menu, connects.map((c) => [c.id, c.kind, get(get(c, "connection"), "state"), get(get(c, "connection"), "workspace"), get(get(c, "feishu"), "domain")])]);
    const keepable = isObject(shown) && Object.isFrozen(shown);
    const kept = keepable ? this.#wholeMade.get(shown) : undefined;
    if (kept !== undefined && kept.sig === sig) return kept.row;
    const made = this.#chatRow(s, shown, me, slackUsers, members_, false, mark, hint, true, this.#goneOf(s.address));
    if (made !== null) {
      Object.assign(made, this.#rowMenu(s.address, shown, me, menu, connects));
      deepFreeze(made);
    }
    if (keepable) this.#wholeMade.set(shown, { sig, row: made });
    return made;
  }

  /// A list's row (as a list or a search has it, what they put on it kept) with what only its whole row says besides
  /// (WHOLE_ONLY: its menu's, its swipe's question while it is swiped, its watch, its card), made for that chat alone as
  /// `chatRow` makes it: for what sends a list's rows as ChatItem (search, chatSearch, share-in.ts), for the rows they
  /// show. As it is where its station lists no such chat (one a station's search found in its archive).
  wholeFor(item: J): J {
    if (!isObject(item) || item.pending === true || typeof item.station !== "string" || typeof item.session !== "string") return item;
    const value = this.#wholeRow(item.station, item.session);
    const whole = value !== undefined && "ok" in value ? value.ok : null;
    if (!isObject(whole) || whole.id !== item.id) return item;
    const given = this.#wholeGiven.get(item);
    if (given !== undefined && given.whole === whole) return given.out;
    const extra: J = {};
    for (const k of WHOLE_ONLY) if (whole[k] !== undefined && !(k === "swipeAsk" && item.swipeArchive !== true)) extra[k] = whole[k];
    const out = Object.keys(extra).length === 0 ? item : Object.freeze({ ...item, ...extra });
    this.#wholeGiven.set(item, { whole, out });
    return out;
  }

  /// What a row's menu offers besides the list's own, as its page's "…" does from its `ChatView` (`xshare`, `publish`,
  /// `slackUrl`, `feishuUrl`): a row's menu and the page's are one. Shared with the viewer's other workspaces by its
  /// starter or an owner or admin (xshare.ts shown); a picture of it published by any but a read-only member (publish.ts
  /// shown); to another station, by an owner or admin (`move.start`); a Slack or Feishu thread's link there, by its
  /// connect (#whereIn).
  #rowMenu(station: string, raw: J, me: J, menu: { role: string | null; places: (readonly [string, string | null])[] }, connects: J[]): J {
    work.rowMenus++;
    const out: J = {};
    if (get(raw, "pending") === true) return out;
    const scope = ofAddress(station);
    const email = str(get(me, "email"));
    const starter = email !== null && str(get(get(raw, "creator"), "id")) === email;
    const role = menu.places.find(([id]) => id === scope)?.[1] ?? null;
    if (menu.places.some(([id]) => id !== scope) && (starter || role === "owner" || role === "admin")) out.mayShare = true;
    if (typeof raw.thread === "number" && menu.role !== "viewer") out.mayPublish = true;
    // (to another station of its workspace: by its owners and admins, as the station's POST /move takes it)
    if (menu.role === "owner" || menu.role === "admin") out.mayMove = true;
    const id = str(get(raw, "connect"));
    const c = id === null ? undefined : connects.find((x) => str(get(x, "id")) === id);
    if (c !== undefined && isObject(raw.origin)) {
      const o = raw.origin as J;
      const kind = str(get(c, "kind"));
      const surface = kind === "feishu" ? `feishu:${id}` : kind === "comma" ? `comma:${id}` : "slack";
      const where = this.#whereIn(station, [{ connect: c }], surface, str(o.channel) ?? "", str(o.channelName) ?? "", str(o.threadTs) ?? "", connects, get(o, "links"));
      if (where.slackUrl !== null) out.slackUrl = where.slackUrl;
      if (where.slackApp !== null) out.slackApp = where.slackApp;
      if (where.feishuUrl !== null) out.feishuUrl = where.feishuUrl;
      if (where.commaUrl !== null) out.commaUrl = where.commaUrl;
      if (where.commaApp !== null) out.commaApp = where.commaApp;
    }
    return out;
  }

  /// Priority order for opened/sub-chats: failed, need/decision/block, active/waiting/watching, ended, archived.
  #openedRank(o: J): number {
    if (o.archived === true) return 4;
    if (o.mark === "failed") return 0;
    if (o.stateLead === "need" || o.stateLead === "decision" || o.mark === "block") return 1;
    if (o.mark === "run" || o.stateLead === "wait" || o.stateLead === "watch") return 2;
    return 3;
  }

  /// Resolves a parent chat's row by thread or session (including pending `new:` keys and archived chats).
  #parentRow(station: string, thread: number | null, session: string | null): J | null | undefined {
    const resolvedThread = thread !== null ? thread : session !== null ? (session.startsWith(PENDING_PREFIX) ? (this.local.pendingThread(station, session) ?? null) : this.boundThread(station, session)) : null;
    if (resolvedThread !== null) {
      const byThread = this.#row(station, { thread: resolvedThread });
      if (isObject(byThread)) return byThread;
    }
    if (session !== null) {
      const bySession = this.#row(station, { session });
      if (isObject(bySession)) return bySession;
      const named = this.#core.data.chatNamed(station, session);
      if (isObject(named?.row)) return named.row;
    }
    return null;
  }

  #openedEntries(station: string, raw: J): { item: J; at: string; row: J | undefined; thread: number | null; idx: number }[] {
    const items: { item: J; at: string; row: J | undefined; thread: number | null; idx: number }[] = [];
    const rawOpened = arr(get(raw, "opened"));
    const ws = ofAddress(station);
    for (let idx = 0; idx < rawOpened.length; idx++) {
      const o = rawOpened[idx];
      const session = str(get(o, "session"));
      if (session === null) continue;
      const there = str(get(o, "station"));
      const at = there !== null && there !== "" ? `${ws}/${there}` : station;
      const found = this.#core.data.chatNamed(at, session);
      const row = found?.row as J | undefined;
      const title = str(get(row, "title")) || str(get(o, "title")) || t("core-views.new_chat");
      const out: J = { station: at, session, title };
      if (isObject(row)) {
        const state = this.#openedState(row);
        if (state.mark !== null) out.mark = state.mark;
        if (state.text !== null) {
          out.stateText = state.text;
          if (state.lead !== null) out.stateLead = state.lead;
        }
      }
      if (found?.archived === true) {
        out.archived = true;
        out.note = t("core-views.search.archived");
      }
      if (get(o, "led") === true) out.led = true;
      items.push({ item: out, at, row, thread: u64(get(row, "thread")), idx });
    }
    return items;
  }

  /// The chats a chat's agent opened (its station's row's `opened`), as their lists have them: each on its station, titled
  /// as its row is (else as it was given), where it stands as its row's second line says it (what it needs of the viewer,
  /// a card, done), its mark; one in its station's archive said so. Ordered by priority (failed, need/block, at work or
  /// waiting on its own work, ended, archived), newest created first within the same priority. Ended is done and also
  /// an agent stopped without saying so (idle, aborted): the app folds all of them away together (`subchat_is_done`).
  #opened(station: string, raw: J): J[] {
    return this.#openedEntries(station, raw)
      .sort((a, b) => this.#openedRank(a.item) - this.#openedRank(b.item) || b.idx - a.idx)
      .map((x) => x.item);
  }

  /// Filtered sub-chats and opened chats of a chat (`chatSubchats` topic): matches title, state line, local SQLite
  /// `said` messages (indexed per sub-chat thread), and online stations' `stationSearch` results.
  #chatSubchats(station: string, thread: number | null, session: string | null, q: string): Value {
    const words = refs.terms(q);
    const parent = this.#parentRow(station, thread, session);
    if (!isObject(parent)) return { ok: { items: [], words, reading: false } };
    const entries = this.#openedEntries(station, parent);
    if (words.length === 0) {
      const items = entries
        .sort((a, b) => this.#openedRank(a.item) - this.#openedRank(b.item) || b.idx - a.idx)
        .map((x) => x.item);
      return { ok: { items, words: [], reading: false } };
    }
    const targets: { station: string; thread: number }[] = [];
    const subStations = new Set<string>();
    for (const e of entries) {
      subStations.add(e.at);
      if (e.thread !== null) targets.push({ station: e.at, thread: e.thread });
    }
    const localHits = this.#core.data.findSaidInThreads(targets, words);
    const trimmed = q.trim();
    const remoteByThread = new Map<string, { text: string; msg: boolean }>();
    const remoteBySession = new Map<string, { text: string; msg: boolean }>();
    let reading = false;
    for (const at of subStations) {
      const online = this.#core.store.select({ topic: "link", station: at }, stationOnline);
      if (!online) continue;
      const answer = this.value({ topic: "stationSearch", station: at, q: trimmed, kind: "chat,message", limit: 200 });
      if (answer === undefined) {
        reading = true;
        continue;
      }
      if ("err" in answer) continue;
      for (const group of arr(get(answer.ok, "groups"))) {
        const k = str(get(group, "kind"));
        if (k !== "message" && k !== "chat") continue;
        const isMsg = k === "message";
        for (const hit of arr(get(group, "hits"))) {
          const text = str(hit.text);
          if (text === null || text === "") continue;
          const hitThread = u64(hit.thread);
          if (hitThread !== null) {
            const tk = `${at}\u0001${hitThread}`;
            const prev = remoteByThread.get(tk);
            if (prev === undefined || (isMsg && !prev.msg)) remoteByThread.set(tk, { text, msg: isMsg });
          }
          const hitChat = str(hit.chat);
          if (hitChat !== null && hitChat !== "") {
            const sk = `${at}\u0001${hitChat}`;
            const prev = remoteBySession.get(sk);
            if (prev === undefined || (isMsg && !prev.msg)) remoteBySession.set(sk, { text, msg: isMsg });
          }
        }
      }
    }
    const matched: { item: J; titleHit: boolean; idx: number }[] = [];
    for (const e of entries) {
      const titleLow = String(e.item.title ?? "").toLowerCase();
      const titleHit = words.every((w) => titleLow.includes(w));
      const stateText = typeof e.item.stateText === "string" ? e.item.stateText : null;
      const stateHit = stateText !== null && words.every((w) => stateText.toLowerCase().includes(w));
      const lastText = str(get(get(e.row, "last"), "text"));
      const lastHit = lastText !== null && words.every((w) => lastText.toLowerCase().includes(w));
      const localHit = e.thread !== null ? localHits.get(`${e.at}\u0001${e.thread}`) : undefined;
      const remoteHit = (e.thread !== null ? remoteByThread.get(`${e.at}\u0001${e.thread}`) : undefined) ?? remoteBySession.get(`${e.at}\u0001${e.item.session}`);
      const bodyText = localHit?.text ?? remoteHit?.text ?? (lastHit ? lastText! : undefined);
      if (!titleHit && !stateHit && bodyText === undefined) continue;
      const out: J = { ...e.item };
      const explainText = !titleHit
        ? stateHit && e.item.archived !== true
          ? undefined
          : bodyText ?? (stateHit ? stateText! : undefined)
        : undefined;
      if (explainText !== undefined) {
        const ex = refs.excerpt(explainText, words);
        if (ex.text !== "") {
          out.foundText = ex.text;
          out.foundMarks = ex.marks;
        }
      }
      matched.push({ item: out, titleHit, idx: e.idx });
    }
    matched.sort((a, b) => Number(b.titleHit) - Number(a.titleHit) || this.#openedRank(a.item) - this.#openedRank(b.item) || b.idx - a.idx);
    return { ok: { items: matched.map((m) => m.item), words, reading } };
  }

  /// Where a chat a chat's agent opened stands (#opened): its mark and its row's second line, made of its record alone
  /// (and the words of the language they are said in), so kept by the record, the same object while it does not change.
  /// A chat that leads many is made again on each change while its agent is working: each of them was copied whole and
  /// presented again every time.
  readonly #openedStates = new WeakMap<object, { lang: string; mark: string | null; text: string | null; lead: string | null }>();
  #openedState(row: J): { mark: string | null; text: string | null; lead: string | null } {
    const said = lang();
    const was = this.#openedStates.get(row);
    if (was !== undefined && was.lang === said) return was;
    const agents = arr(row.agents);
    // (presentRow and the presenting of each agent copy what they change: the record is read, never written;
    // unread is cleared on this shallow copy so led sub-chats read by their leader still report settled done state)
    const shown = decisions.presentRow({ ...row, unread: false, agents: agents.map((a: J) => present.session(a)) });
    const line = present.rowStateLine(shown);
    const made = { lang: said, mark: present.rowState(agents), text: line === null ? null : line[0], lead: line === null || line[3] === null ? null : line[3].kind };
    this.#openedStates.set(row, made);
    return made;
  }

  /// The chat an agent opened a row's chat from (its station's `opener`), as its list has it: on its station (the row's
  /// own when the station names none), titled as its row is, else as it was called then; one in its archive is said
  /// so. Null for a chat a person started.
  #opener(station: string, raw: J): J | null {
    const o = get(raw, "opener");
    const session = str(get(o, "session"));
    if (session === null) return null;
    const there = str(get(o, "station"));
    const at = there !== null && there !== "" ? `${ofAddress(station)}/${there}` : station;
    // (its title and whether it is archived alone, of their columns)
    const found = this.#core.data.chatTitled(at, session);
    const title = found?.title || str(get(o, "title")) || t("core-views.new_chat");
    return { station: at, session, title, text: t("core-views.opener", { title }), ...(found?.archived === true ? { archived: true, note: t("core-views.search.archived") } : {}),
      // (it leads this one: chat_create for me. What it asks is its leader's, and the board shows it under its leader)
      ...(get(o, "led") === true ? { led: true } : {}) };
  }

  /// The chain of led parent chats (`opener.led === true` traced upward), root first, ending with its direct opener.
  /// Empty when the chat is not led (zero DB reads for ordinary chats and chats opened for a person).
  #openers(station: string, raw: J): J[] {
    const first = get(raw, "opener");
    if (get(first, "led") !== true || str(get(first, "session")) === null) return [];
    const MAX_OPENERS = 8;
    const seen = new Set<string>();
    const mark = (st: string, id: string | null) => { if (id !== null && id !== "") seen.add(`${st}\u0001${id}`); };
    mark(station, str(get(raw, "id")));
    mark(station, str(get(raw, "session")));
    const chain: J[] = [];
    let cur: J = raw;
    let curStation = station;
    while (chain.length < MAX_OPENERS) {
      const o = get(cur, "opener");
      if (get(o, "led") !== true) break;
      const session = str(get(o, "session"));
      if (session === null) break;
      const there = str(get(o, "station"));
      const at = there !== null && there !== "" ? `${ofAddress(curStation)}/${there}` : curStation;
      const key = `${at}\u0001${session}`;
      if (seen.has(key)) break;
      const found = this.#core.data.chatNamed(at, session);
      const parentRow = found?.row as J | undefined;
      const parentId = isObject(parentRow) ? str(get(parentRow, "id")) : null;
      const parentSession = isObject(parentRow) ? str(get(parentRow, "session")) : null;
      if ((parentId !== null && seen.has(`${at}\u0001${parentId}`)) || (parentSession !== null && seen.has(`${at}\u0001${parentSession}`))) break;
      seen.add(key);
      mark(at, parentId);
      mark(at, parentSession);
      const title = str(get(parentRow, "title")) || str(get(o, "title")) || t("core-views.new_chat");
      chain.push({
        station: at, session, title, text: t("core-views.opener", { title }),
        ...(found?.archived === true ? { archived: true, note: t("core-views.search.archived") } : {}),
        led: true,
      });
      if (!isObject(parentRow)) break;
      cur = parentRow;
      curStation = at;
    }
    return chain.reverse();
  }

  /// A row whose chat has a message sent here that did not go: marked red, its second line saying which (`unsent`: drawn
  /// in red), before
  /// anything its agents do (the message waits in the chat to be sent again or dropped). Else, a chat made here (the
  /// board's draft started, a new chat's page) whose first words are still on their way (`going`, local.ts
  /// goingFirsts) while its station lists it with its agent seated and no turn begun (`record`'s agents): at work
  /// (进行中), not ended (待收口) till its turn runs. Only those: a chat seated and asked nothing that was not made here
  /// (a connect's, waiting for a person's first message) stays as its record says.
  #unsentRow(station: string, row: J, failed?: Map<number, J>, record?: J, going?: ReadonlySet<number>): J {
    const thread = typeof row.thread === "number" ? row.thread : null;
    const key = row.pending === true && typeof row.clientKey === "string" ? row.clientKey : null;
    const unsent = failed !== undefined && thread !== null && key === null ? failed.get(thread) : this.local.unsent(station, thread, key);
    if (unsent === undefined) {
      if (row.stage !== undefined || thread === null || key !== null || record === undefined) return row;
      if (!(going ?? this.local.goingFirsts(station)).has(thread) || !noTurnBegun(record)) return row;
      const { archiveRead: _archiveRead, ...rest } = row;
      const atWork: J = { ...rest, stage: "run" };
      deepFreeze(atWork);
      const pinned = pinnedAt.get(row);
      if (pinned !== undefined) pinnedAt.set(atWork, pinned);
      return atWork;
    }
    const text = format.cleanText(format.plainText(str(unsent.text) ?? ""));
    const { stateAbout: _stateAbout, stateLead: _stateLead, stateLeadText: _stateLeadText, stateRest: _stateRest, ...rest } = row;
    // (it needs the viewer: chat-stage.ts needsViewer)
    const marked: J = { ...rest, tone: "alert", unsent: true, stage: "wait", stateText: t("core-views.unsent", { text: text === "" ? t("core-views.file") : text }) };
    deepFreeze(marked);
    const pinned = pinnedAt.get(row);
    if (pinned !== undefined) pinnedAt.set(marked, pinned);
    return marked;
  }

  /// A row's local calendar day, kept with it while the zone is as it was (the zone's offset at each row's time was
  /// asked of the host for each of 1400 rows on every change of one, 2026-11-08).
  #dayOfRow(row: J): number {
    const host = this.#core.host;
    const ms = typeof row.lastActiveAt === "number" ? row.lastActiveAt : 0;
    const kept = this.#dayOf.get(row);
    if (kept !== undefined && kept[0] === ms) return kept[1];
    const d = Math.floor((ms + host.utcOffsetMin(ms) * 60_000) / DAY_MS);
    this.#dayOf.set(row, [ms, d]);
    return d;
  }

  /// The rows' days kept (`#dayOfRow`) while the zone's offset now is `offset`: let go as it changes.
  #zone(offset: number): void {
    if (this.#daysZone === offset) return;
    this.#daysZone = offset;
    this.#dayOf = new WeakMap();
  }

  /// Rows newest first, grouped by the viewer's local calendar day; the pinned above them all.
  #days(rows: J[]): J[] {
    const host = this.#core.host;
    const at = (row: J) => (typeof row.lastActiveAt === "number" ? row.lastActiveAt : 0);
    const pinned = rows.filter((row) => pinnedAt.has(row));
    const when = (row: J) => pinnedAt.get(row) ?? 0;
    pinned.sort((a, b) => when(b) - when(a) || at(b) - at(a));
    const now = host.nowMs();
    const offset = host.utcOffsetMin(now);
    this.#zone(offset);
    work.listed += rows.length;
    const rest = rows.filter((row) => !pinnedAt.has(row)).map((row) => ({ row, time: at(row), day: this.#dayOfRow(row) }));
    rest.sort((a, b) => b.day - a.day || b.time - a.time);
    const today = Math.floor((now + offset * 60_000) / DAY_MS);
    const days: [number, number, J[]][] = [];
    for (const { row, time, day: d } of rest) {
      const last = days[days.length - 1];
      if (last && last[0] === d) last[2].push(row);
      else days.push([d, time, [row]]);
    }
    const out: J[] = [];
    if (pinned.length > 0) out.push({ daysAgo: -1, at: at(pinned[0]), label: t("core-views.pinned"), pinned: true, items: pinned });
    for (const [d, ti, items] of days) out.push({ daysAgo: today - d, at: ti, label: format.dayLabel(ti, now, offset), items });
    return out;
  }

  /// A list's days (`#days`), made from the last ones where only a few rows went and came (`changes`): those rows are
  /// taken out of and put into their days, the other days kept as they were.
  #daysOf(key: string, rows: J[], changes: RowsChanged): J[] {
    const host = this.#core.host;
    const now = host.nowMs();
    const offset = host.utcOffsetMin(now);
    const today = Math.floor((now + offset * 60_000) / DAY_MS);
    this.#zone(offset);
    const last = this.#daysKept.get(key);
    const few = changes.gone.length + changes.come.length <= ROWS_PUT_ALONE;
    const pinnedChanged = changes.gone.some((r) => pinnedAt.has(r)) || changes.come.some((r) => pinnedAt.has(r));
    let days: J[];
    if (last !== undefined && !changes.whole && few && !pinnedChanged && last.today === today && last.offset === offset && last.rows.length - changes.gone.length + changes.come.length === rows.length) {
      days = last.days.slice();
      work.listed += changes.gone.length + changes.come.length;
      const at = (row: J) => (typeof row.lastActiveAt === "number" ? row.lastActiveAt : 0);
      const dayAt = (d: number) => days.findIndex((g) => g.pinned !== true && g.daysAgo === today - d);
      for (const row of changes.gone) {
        const i = dayAt(this.#dayOfRow(row));
        const items: J[] = i < 0 ? [] : days[i].items;
        const j = items.indexOf(row);
        if (j < 0) {
          days = this.#days(rows);
          this.#daysKept.delete(key);
          this.#daysKept.set(key, { rows, days, today, offset });
          while (this.#daysKept.size > 16) this.#daysKept.delete(this.#daysKept.keys().next().value!);
          return days;
        }
        const left = items.filter((_, k) => k !== j);
        if (left.length === 0) days.splice(i, 1);
        else days[i] = { ...days[i], items: left, at: at(left[0]) };
      }
      for (const row of changes.come) {
        const d = this.#dayOfRow(row);
        const time = at(row);
        const i = dayAt(d);
        if (i < 0) {
          // A day of its own, among the days newest first (after the pinned).
          let k = 0;
          while (k < days.length && (days[k].pinned === true || days[k].daysAgo < today - d)) k++;
          days.splice(k, 0, { daysAgo: today - d, at: time, label: format.dayLabel(time, now, offset), items: [row] });
          continue;
        }
        const items: J[] = days[i].items;
        let k = 0;
        while (k < items.length && at(items[k]) >= time) k++;
        const put = [...items.slice(0, k), row, ...items.slice(k)];
        days[i] = { ...days[i], items: put, at: at(put[0]) };
      }
    } else days = this.#days(rows);
    this.#daysKept.delete(key);
    this.#daysKept.set(key, { rows, days, today, offset });
    while (this.#daysKept.size > 16) this.#daysKept.delete(this.#daysKept.keys().next().value!);
    return days;
  }

  // ── stations and connects ──

  /// The accounts need the stations' identities, availability and decorated profiles, not their changing host
  /// readings or network routes. The usage view uses these same accounts for their allowances.
  #profilesView(scope: string): Value | undefined {
    const stations = this.#stationsOr(scope);
    if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
    const listed = workspaceProfiles(stations.map((s) => ({
      station: s.address,
      id: s.id,
      name: s.name,
      online: s.online,
      joined: s.joined,
      overview: this.#stationShownOf(s.address).profile.get(),
    })));
    // What the Profile place lists beside them: each up station's own logins it could take as a profile (it read them of
    // every station's whole overview in the list, then asked each station for them after it had opened).
    const machineLogins = stations.flatMap((s) => {
      const logins = s.online ? this.#stationShownOf(s.address).offered.get() : [];
      return logins.length > 0 ? [{ station: s.address, stationName: s.name, logins }] : [];
    });
    return { ok: { ...listed, machineLogins } };
  }

  /// The workspace's accounts' list (`profiles`): each station's accounts' rows as kept beside its overview's part
  /// (db/kept.ts KEPT.profileRow, under profileRowKey), else made of that part and kept so, merged across the
  /// stations (profiles.ts workspaceProfiles: their names, whether each is up, an account's copies on several) as it is
  /// read, its windows' refills said of now; what each up station's own logins offer beside, as before. The list
  /// decorates no profile where its stations' rows are kept.
  #profileRowsView(scope: string): Value | undefined {
    const stations = this.#stationsOr(scope);
    if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
    const key = profileRowKey();
    const ins = stations.map((s) => ({ station: s.address, id: s.id, name: s.name, online: s.online, joined: s.joined, overview: this.#profileRowsOfStation(s.address, key) }));
    const listed = workspaceProfiles(ins);
    const c = this.#clock();
    const items = arr(listed.items).map((e) => {
      const q = get(get(e, "profile"), "quota");
      if (!isObject(q) || !Array.isArray(q.windows) || q.windows.length === 0) return e;
      return { ...e, profile: { ...e.profile, quota: { ...q, windows: q.windows.map((w: J) => windowShown(w, c)) } } };
    });
    const machineLogins = stations.flatMap((s, i) => {
      const logins = s.online ? this.#offeredOf(ins[i]!.overview, c) : [];
      return logins.length > 0 ? [{ station: s.address, stationName: s.name, logins }] : [];
    });
    // (whether the viewer manages the workspace, of what #stationsOr read of it: the list's 多选 is its owners' and admins')
    const role = get(this.ok({ topic: "workspace", workspace: scope }), "role");
    return { ok: { ...listed, items, machineLogins, ...(role === "owner" || role === "admin" ? { manages: true } : {}) } };
  }

  /// A station's own logins offered for a profile, as the list shows them beside its rows (#profileRowsView): its
  /// overview's `machineLogins` as its rows keep them (#profileRowsMade), decorated as the overview's are (their
  /// allowances in words) and put through its shape, the profiles not touched; kept for the logins read while their
  /// words hold (present.ts `made`).
  #offeredOf(rows: J, c: present.Clock): J[] {
    const logins = get(rows, "machineLogins");
    if (!Array.isArray(logins) || logins.length === 0) return [];
    const made = present.made(this.#offeredShown, logins, c, () => {
      // (offered as the overview's decoration says it, of its profiles as the station's rows keep them)
      const shown = present.times({ machineLogins: present.loginsOffered(structuredClone(logins), arr(get(rows, "profiles"))) }, c);
      const shaped = asShaped("Overview", { ...overviewDefaults(), ...(shown as J) });
      return arr(get(shaped, "machineLogins")).filter((l) => get(l, "offered") === true);
    });
    return present.taken(made);
  }

  #offeredShown = new WeakMap<object, present.Made<J[]>>();

  /// A station's accounts' rows (#profileRowsView): kept beside its part under `key`, else made of the part it holds
  /// (none while its overview is not read) and kept beside it.
  #profileRowsOfStation(station: string, key: string): J {
    const kept = this.#core.data.kept(KEPT.profileRow, [station], key);
    if (kept !== undefined) return kept;
    const profiled = this.#core.data.overviewProfiled(station);
    if (!isObject(profiled)) return undefined;
    let made = this.#profileRowsKept.get(profiled);
    if (made === undefined || made.key !== key) {
      const rows = this.#profileRowsMade(station, profiled);
      if (rows === null) return undefined;
      made = { key, rows };
      this.#profileRowsKept.set(profiled, made);
      const keep = made;
      untracked(() => this.#core.data.keep(KEPT.profileRow, [station], profiled, key, keep.rows));
    }
    return made.rows;
  }

  /// A station's accounts' rows as the list would make them of its part now, and the key they would be kept by (tests:
  /// test/profile-rows.test.ts holds that rows made otherwise are kept by another key).
  profileRowsNow(station: string): { key: string; rows: J } | null {
    const rows = untracked(() => this.#profileRowsMade(station, this.#core.data.overviewProfiled(station)));
    return rows === null ? null : { key: profileRowKey(), rows };
  }

  /// Rows made of a part read (#profileRowsOfStation), by that part, while it is not kept (the overview shown with
  /// what is being done to it here, a database that keeps none).
  #profileRowsKept = new WeakMap<object, { key: string; rows: J }>();

  /// A station's accounts' rows of its overview's part `profiled` (the overview's `profiles`, `sharing`, `mesh`): each
  /// profile decorated as its page has it (present.ts profile, its allowance's windows in words), shaped as the
  /// overview's, then what the list reads of it kept (profileRowsOf): no time in words, no window's refills, nothing of
  /// the station but its part, and its machine's own logins as the part has them (what #offeredOf offers beside the rows,
  /// of these). What #stationShownOf's `profile` decorates for the whole list, made here once for the rows as the part
  /// is written (db/kept.ts `wrote`) or first read.
  #profileRowsMade(station: string, profiled: J): J | null {
    if (!isObject(profiled)) return null;
    work.profileRows++;
    const shown = present.decorate({ topic: "overview", station }, structuredClone(profiled), this.#clock());
    const shaped = asShaped("Overview", isObject(shown) ? { ...overviewDefaults(), ...shown } : shown);
    if (shaped === null) return null;
    const rows = { ...profileRowsOf(shaped), machineLogins: get(profiled, "machineLogins") ?? null };
    deepFreeze(rows);
    return rows;
  }

  /// One account of a workspace (`profile`): its entry of the workspace's profiles as the core holds them whole (the
  /// list sends each its row, ProfileRow), found by its key, or by a profile of it on a station (any of its members);
  /// null where none is.
  #profileOf(view: Topic): Value | undefined {
    const all = this.value({ topic: "profilesWhole", scope: view.scope });
    if (all === undefined || "err" in all) return all;
    const key = str(view.key);
    const station = str(view.station);
    const id = str(view.id);
    const found = arr(get(all.ok, "items")).find((e) =>
      key !== null ? get(e, "key") === key : arr(get(e, "members")).some((m) => get(m, "station") === station && get(m, "profileId") === id));
    return { ok: found ?? null };
  }

  /// Which of a workspace's stations the viewer may change the mode of, as the cloud has it (cloud/src/directory/stations.ts
  /// `setStationMode`): workspace owners and admins may convert any whole station, and a member may convert one they added.
  #mayChangeMode(scope: string): (id: string) => boolean {
    const ws = this.ok({ topic: "workspace", workspace: scope });
    const sub = this.#core.subOf?.(scope) ?? null;
    if (sub === null || !isObject(ws)) return () => false;
    const role = get(ws, "role");
    if (role === "owner" || role === "admin") return () => true;
    const by = new Map(arr(get(ws, "stations")).map((s) => [str(get(s, "id")), str(get(s, "enrolled_by"))] as const));
    return (id) => by.get(id) === sub;
  }

  /// A scope's stations, made in one place for the three ways they are asked: `row`, each as a list shows it
  /// (StationRow, the `stations` topic), of nothing a row does not send (its overview's four parts, its host's line and
  /// meters: no profiles, no models, no quota by the minute); `page`, each as its page shows it (StationView, the `station`
  /// topic, `only` that one), all but the models it can run; `whole`, a page with those (`stationsWhole`, the core's own).
  /// Computed again when one of its stations has been silent long enough to say so.
  #stationsOf(scope: string, kind: "row" | "page" | "whole", only?: string): Value | undefined {
    const stations = this.#stationsOr(scope);
    if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
    const c = this.#clock();
    let silentNext = Infinity;
    const byId = new Map(stations.map((s) => [String(s.id), s]));
    const mine = this.#mayChangeMode(scope);
    const guard = this.#core.guard?.(scope) ?? null;
    const row = kind === "row";
    const items = stations.filter((s) => only === undefined || s.address === only).map((s) => {
      const parts = this.#stationShownOf(s.address);
      // A row reads only its overview's parts it shows (`undefined`: not read; null: not readable here), and whether
      // this core can read the rest: it says so as its page does, its overview none, as before it was a row.
      const rowOverview = row ? parts.row.get() : undefined;
      const read = row ? rowOverview : this.ok({ topic: "overview", station: s.address });
      const shown = row ? (parts.unreadable.get() ? null : (rowOverview ?? null)) : parts.full.get();
      const hostRaw = this.ok({ topic: "host", station: s.address });
      const host = parts.host.get();
      // What it says that this core cannot read (a station newer than the app): the row stays, saying so, and the other
      // stations' are not lost with it.
      const unreadable = (read !== undefined && shown === null) || (isObject(hostRaw) && host === null);
      const overview = read !== undefined && shown === null ? undefined : read;
      let summary: string;
      const cause = get(this.link(s.address), "cause");
      if (!s.online && cause === "updating") summary = t("core-views.station.updating_short");
      else if (!s.online && cause === "network") summary = t("core-views.station.network");
      else if (!s.online && cause === "unreached") summary = t("core-views.station.unreachable_short");
      else if (!s.online && cause === "lock") summary = t("core-views.station.lock_short");
      else if (!s.online) {
        summary = typeof s.lastSeen === "number" ? t("core-views.station.offline_since", { ago: format.relativeTime(s.lastSeen * 1000, c.now, c.offsetMin) }) : t("core-views.station.offline_short");
      } else if (unreadable) summary = t("core-views.station.incompatible_short");
      else if (host !== null) {
        const running = u64(get(get(overview, "counts"), "running")) ?? 0;
        const what = str(host.identity) || str(host.os) || "";
        // What its agents do first: a narrow card cuts the line short at its end.
        summary = `${running > 0 ? t("core-views.station.running", { n: running }) : t("core-views.station.idle")} · ${what}`;
      } else summary = t("core-views.station.connecting");
      // How it is reached alone, not its figures (they change with each reading: the `stationNet` view has them).
      const way = this.ok({ topic: "way", station: s.address });
      const state = str(this.link(s.address).state);
      // Up without a host reading for SILENT_MS: said to be silent (the cloud says it is up, nothing answers).
      let silent = false;
      if (s.online && host === null && !unreadable) {
        const since = this.#hostless.get(s.address) ?? c.now;
        this.#hostless.set(s.address, since);
        silent = c.now - since >= SILENT_MS;
        if (!silent) silentNext = Math.min(silentNext, since + SILENT_MS - c.now);
      } else this.#hostless.delete(s.address);
      const blocked = !s.online && cause === "lock" && typeof get(this.link(s.address), "message") === "string" ? (get(this.link(s.address), "message") as string) : null;
      const running = u64(get(get(overview, "counts"), "running")) ?? 0;
      const unprotected = guard !== null && !guard.protects(String(s.id));
      const can = unprotected && guard!.can();
      const item: J = {
        station: s.address,
        id: s.id,
        name: s.name,
        ...(s.emoji ? { emoji: s.emoji } : {}),
        ...(s.icon ? { icon: s.icon } : {}),
        summary,
        face: looks.face(s.online, overview),
        line: !s.online && cause === "lock" ? t("core-views.station.lock_short") : s.online && unreadable ? t("core-views.station.incompatible_short") : looks.stationLine(s.online, host),
        online: s.online,
        reconnecting: s.online && state !== "online" && state !== "error",
        ...stationState(s.online, blocked !== null || cause === "updating", summary, typeof s.lastSeen === "number" ? s.lastSeen : null, read !== undefined, running, c),
        problems: stationProblems(s.online, silent, blocked, typeof s.lastSeen === "number", cause === "updating", unreadable, typeof cause === "string" ? cause : null),
        // Not named by its workspace's safe mode: its 保护 where it is shown, where the viewer could protect it from here
        // (the user, 2026-11-15: 「在 station 这里要能点成受保护」, 「不需要写不受保护」: the button alone, no words).
        ...(unprotected && can && s.online ? { protect: true } : {}),
        // Down for a security mode: why, in place of the page's 离线 words.
        ...(blocked !== null ? { blocked } : {}),
        lastSeen: s.lastSeen,
        version: s.version,
        overview: shown,
        host: row ? parts.hostRow.get() : host,
        way: way === undefined ? null : present.way(way, (h) => this.relayName(h)),
        ...(s.joined ? { joined: true, home: this.#core.homeName?.(scope, s.id) ?? null } : {}),
        mine: mine(s.id),
        ...((row ? !parts.unreadable.get() && parts.acceptAutoChats.get() : get(get(overview, "autoChats"), "enabled") === true) ? { acceptAutoChats: true } : {}),
      };
      if (row) return item;
      const serving = overview !== undefined ? servingIn(overview, scope, s.joined === true) : overview;
      item.link = this.link(s.address);
      // What this workspace's chats run on: the profiles open to it.
      item.runtimes = runtimes(serving);
      Object.assign(item, stationProfileSummary(shown, s, byId));
      item.betaOffered = betaOffered(overview, () => this.#betaOf(scope));
      // The models it can run, each with each of its accounts' quota by the minute: only a model's choice reads them
      // (choose.ts, through `stationsWhole`). In every list's item they were most of its bytes (463 KB of a phone's,
      // 2026-11-10), each decoded on the app's frame thread each time it was said.
      if (kind === "whole") item.models = models(serving, c.now);
      return item;
    });
    this.#againIn(silentNext);
    return { ok: items };
  }

  /// Local connection diagnostics for one station (`stationDiag`).
  #stationDiag(station: string): J {
    const ws = ofAddress(station);
    const id = station.includes("/") ? station.slice(station.indexOf("/") + 1) : station;
    const workspace = this.ok({ topic: "workspace", workspace: ws });
    const st = arr(get(workspace, "stations")).find((x) => str(get(x, "id")) === id);
    const link = this.link(station);
    const net = this.ok({ topic: "net", station });
    const linkDiag = this.#core.linkDiag?.(station) ?? null;
    const peerDiag = this.#core.peerDiag?.(station) ?? null;
    const cloudDown = linkDiag?.cloudDown ?? this.#core.cloudDown?.() ?? false;
    const c = this.#clock();
    return stationDiagView({
      station,
      id,
      name: str(get(st, "name")) ?? id,
      version: str(get(st, "version")),
      lastSeenSec: typeof get(st, "lastSeen") === "number" ? (get(st, "lastSeen") as number) : null,
      link,
      linkDiag,
      peerDiag,
      net: net === undefined ? null : present.net(net, (h) => this.relayName(h)),
      cloudDown,
      clock: c,
      relayName: (h) => this.relayName(h),
    });
  }

  /// A station's decorated overview, what of it the workspace's profiles read decorated (`profile`: its kept part,
  /// station_part.profiled), and its host reading, as its list's item shows them: made once for every view that shows
  /// them, again as they or their times in words change.
  #stationShownOf(station: string): StationShown {
    let kept = this.#stationShown.get(station);
    if (kept) return kept;
    const overview: Topic = { topic: "overview", station };
    // What is made of an overview record is kept with it (the same frozen object while the record is unchanged): `full`
    // and `profile` take one decorated overview, and a computed read again after it was let go takes it again, while its
    // words about time hold (present.ts `made`); whether it can be read, which no clock changes, for as long as the
    // record is kept. Each made it anew: `stations` decorated every station's whole overview for that one boolean (12–13 ms
    // of its 14–16 ms in Hermes for 5 stations of 150 KB each), `profiles` all of them again (11.7–13 ms of 19–20 ms),
    // both again as a workspace was come back to a minute after it was left with no overview changed. `profile` is made
    // of what the profiles read of it alone (data.ts overviewProfiled), never of the whole overview: decorating a copy
    // of each station's whole for them was 10.7 of the 15 ms their list took to make after a workspace was switched to
    // on 小屏 (Hermes, Mac Studio, 2026-11-12).
    const shown = new WeakMap<object, present.Made<J>>();
    const readable = new WeakMap<object, boolean>();
    const decorate = (o: J, c: present.Clock, part: false | "profiled" | "settings" = false): J => {
      if (part === "profiled") work.profiledParts++;
      else if (part === "settings") work.settingsParts++;
      else work.overviews++;
      const shownOf = present.decorate(overview, structuredClone(o), c);
      // (a part put through the overview's shape as the whole is, the rest of it the shape's defaults, which nothing
      // reading it reads: its profiles, sharing, mesh and machines' logins, or its automatic decisions and archiving, as
      // the whole would have them)
      return asShaped("Overview", part !== false && isObject(shownOf) ? { ...overviewDefaults(), ...shownOf } : shownOf);
    };
    const decorated = (read: () => J, part: false | "profiled" | "settings" = false) => computed(() => {
      const o = read();
      if (o === undefined) return null;
      // (its times in words, by the minute)
      const c = this.#clock();
      return isObject(o) ? present.taken(present.made(shown, o, c, () => decorate(o, c, part))) : decorate(o, c, part);
    });
    kept = {
      full: decorated(() => this.ok(overview)),
      profile: decorated(() => this.#core.data.overviewProfiled(station), "profiled"),
      // Its automatic decisions and archiving as the whole has them (present.ts overview decorates them of themselves
      // alone), of what is kept of them beside the overview (data.ts overviewSettings), never of the whole; null where
      // this core cannot read the whole (`full` would be null), as `unreadable` says it.
      settings: (() => {
        const part = decorated(() => this.#core.data.overviewSettings(station), "settings");
        return computed(() => (kept!.unreadable.get() ? null : part.get()));
      })(),
      host: computed(() => {
        const h = this.ok({ topic: "host", station });
        return h === undefined ? null : asShaped("Host", present.host(h));
      }),
      // What its row shows of them: its overview's parts (undefined: not read), its machine's line and meters. Read of
      // what the database keeps beside the overview (data.ts overviewRow), never the overview.
      row: computed(() => {
        const o = this.#core.data.overviewRow(station);
        return isObject(o) ? asShaped("OverviewRow", rowOf(o)) : undefined;
      }),
      acceptAutoChats: computed(() => get(get(this.#core.data.overviewRow(station), "autoChats"), "enabled") === true),
      hostRow: computed(() => {
        const h = kept!.host.get();
        return h === null ? null : asShaped("HostRow", { identity: h.identity, os: h.os, meters: h.meters, egressText: h.egressText ?? "" });
      }),
      // Its overview is read and this core cannot read it (its page says so): a boolean, so that what reads it is made
      // again only as that changes (reactive.ts: a computed whose value is the same tells its readers nothing), not
      // with each quota or decision of a station it can read. As kept beside the overview, judged as it was written
      // (data.ts overviewFit): its overview neither read nor decorated. Where none is kept for this core's shapes (a
      // database from before, an overview another core wrote, shapes changed by an update, one shown with what is
      // being done to it here), judged as it is read, and kept.
      unreadable: computed(() => {
        const verdict = this.#core.data.overviewFit(station);
        if (verdict === undefined) return false;
        if (verdict !== null) return !verdict;
        const o = this.ok(overview);
        if (o === undefined) return false;
        if (!isObject(o)) return kept!.full.get() === null;
        const fits = kept!.judge(o);
        untracked(() => this.#core.data.keep(KEPT.overviewFit, [station], o, OVERVIEW_FIT(), fits));
        return !fits;
      }),
      // Its machine's own logins offered for a profile, as its page has them (the same list while they are equal: the
      // profiles' page is not made again with each other change of its overview): of what the profiles read of it,
      // which holds them and the profiles whose runtimes take them (present.ts overview `taken`).
      offered: (() => {
        let last: J[] = [];
        return computed(() => {
          const next = arr(get(kept!.profile.get(), "machineLogins")).filter((l) => get(l, "offered") === true);
          return equal(last, next) ? last : (last = next);
        });
      })(),
      // Whether this core can read an overview of it (an object), as its page would show it: decorated (kept for its
      // record, which `full` and `profile` take as made) and put through its shape.
      judge: (o) => {
        let fits = readable.get(o);
        if (fits === undefined) {
          const c = untracked(() => this.#clock());
          fits = present.made(shown, o, c, () => decorate(o, c)).value !== null;
          readable.set(o, fits);
        }
        return fits;
      },
    };
    this.#stationShown.set(station, kept);
    return kept;
  }

  /// A scope's connects as a list shows them (ConnectRow), every station's up, all or the viewer's (`mine`): made of
  /// each station's connects alone (connectsPartOf), so a session's turn, a new one or its overview's quota sends a list
  /// nothing. One's page is `connect` (#connectOf).
  #connects(scope: string, mine: boolean): Value | undefined {
    const stations = this.#stationsOr(scope);
    if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
    const me = this.me(scope);
    const members_ = arr(get(this.ok({ topic: "workspace", workspace: scope }), "members"));
    const items: J[] = [];
    const waiting: string[] = [];
    const failing: { station: string; name: string; message: string }[] = [];
    // The Slack apps the viewer made that no connect has taken yet (a station's overview has those alone: one a connect
    // takes is let go of there), each on its station; and whether the first step is a profile: a connect runs a
    // profile's model, and no station has one (each read). Whatever `mine` is.
    const slackApps: J[] = [];
    let noProfile = stations.length > 0;
    for (const s of stations) {
      const part = this.#connectsPart(s.address);
      if (part === undefined || "err" in part || part.profiled) noProfile = false;
      if (part !== undefined && !("err" in part)) for (const app of part.slackApps) slackApps.push({ station: s.address, stationName: s.name, app });
      if (!s.online) continue;
      if (part === undefined) {
        waiting.push(s.name);
        continue;
      }
      if ("err" in part) {
        failing.push({ station: s.address, name: s.name, message: part.err });
        continue;
      }
      for (const connect of part.connects as J[]) {
        const shown = this.#connectShown(connect, me, members_, mine);
        if (shown !== null) items.push({ station: s.address, stationName: s.name, connect: shown });
      }
    }
    return { ok: { me, items, wait: looks.waitNote(waiting, failing, items.length === 0), slackApps, noProfile } };
  }

  /// Connect `connect` as it is shown (Connect): its owner said as the viewer `me` knows them among the workspace's
  /// `members`; null where only the viewer's are asked (`mine`) and it is another's.
  #connectShown(connect: J, me: J, members: J[], mine: boolean): J {
    const id = get(get(connect, "createdBy"), "id");
    const creator = id !== undefined ? { id, email: id } : null;
    if (mine && !isMine(me, creator)) return null;
    const shown = present.connect(connect);
    if (shown.createdBy !== undefined) shown.createdBy = present.person(shown.createdBy, me, members);
    return shown;
  }

  /// What the connects read of a station's overview (connectsPartOf): of what is kept of it beside the overview
  /// (data.ts overviewConnects), never the whole; where none is held, why not as the overview's topic says it.
  #connectsPart(station: string): J {
    const kept = this.#core.data.overviewConnects(station);
    return kept !== undefined ? kept : this.#core.store.select({ topic: "overview", station }, connectsPartOf);
  }

  /// One connect of a scope's station, by its id: its page (`page`, ConnectView) or the sessions its choice of one lists
  /// (`candidates`, ConnectCandidates). None while its station's overview is not read, why where it could not be; null
  /// where the scope has no such station up, or it no such connect.
  #connectOf(scope: string, station: string, id: string, kind: "page" | "candidates"): Value | undefined {
    const stations = this.#stationsOr(scope);
    if (stations === undefined || !Array.isArray(stations)) return stations as Value | undefined;
    const s = stations.find((x) => x.address === station);
    if (s === undefined || !s.online) return { ok: null };
    // (of what is kept of its overview beside it, data.ts overviewConnects: never the whole)
    const kept = this.#core.data.overviewConnects(station);
    const v = kept !== undefined ? { ok: kept } : this.value({ topic: "overview", station });
    if (v === undefined || "err" in v) return v;
    const connects = arr(get(v.ok, "connects"));
    const connect = connects.find((c) => str(get(c, "id")) === id);
    if (connect === undefined) return { ok: null };
    const sessions = arr(this.ok({ topic: "sessions", station }));
    if (kind === "candidates") return { ok: { candidates: connectCandidates(connect, connects, sessions, this.#clock()) } };
    const me = this.me(scope);
    const members_ = arr(get(this.ok({ topic: "workspace", workspace: scope }), "members"));
    const threads = arr(this.ok({ topic: "threads", station }));
    return { ok: { station, stationName: s.name, connect: this.#connectShown(connect, me, members_, false), runtimeChanges: get(v.ok, "connectRuntimeChange") === true, ...connectSessions(connect, sessions, threads) } };
  }

  // ── a chat ──

  #chat(station: string, id: number): Value | undefined {
    const pageV = this.value({ topic: "thread", station, thread: id });
    if (pageV === undefined) return undefined;
    if ("err" in pageV) return pageV;
    const page = pageV.ok as J;
    const data = this.#core.data;
    const listed = data.listed(station, "threads");
    if (!listed) {
      const threadsV = this.value({ topic: "threads", station });
      if (threadsV !== undefined && "err" in threadsV) return threadsV;
    }
    // Its summary as the station lists it, else as held (one not in the list read last: made since, elsewhere or while
    // away, or told before that list came back), else not known yet. A chat not in the list held is not one gone: that
    // is the station's to say (sync.ts #threadGone, the page's error); it said so at once of a chat made since
    // (2026-11-09).
    const summary = (listed ? data.listedThread(station, id) : undefined) ?? (isObject(page.thread) ? page.thread : undefined);
    if (summary === undefined) return undefined;
    // (a copy of its top alone: what is put in it here is `people` and `creator`, made anew; the rest is shared as read)
    const thread: J = { ...(summary as Record<string, unknown>) };
    const agents = timed("chat.agents", () => this.#agentsOf(station, thread));
    // What two chats' agents wrote each other is not said in it: it has a page of its own (`chatLetters`).
    const keys = new Set(members(thread));
    const all: J[] = merge(arr(page.entries));
    const said = all.filter((m) => !isLetter(m, keys));
    const letters = Math.max(u64(get(thread, "letters")) ?? 0, all.length - said.length);
    const whom = this.#peopleOf(station, agents);
    const { scope, viewer, members_, bots } = whom;
    const waiting = agents.reduce((max, a) => Math.max(max, u64(get(a.session, "pending")) ?? 0), 0);
    const peopleSeqs = said.filter((m) => m.authorKind === "person").flatMap((m) => (u64(m.seq) !== null ? [m.seq as number] : []));
    const waits = peopleSeqs.slice(Math.max(peopleSeqs.length - waiting, 0));
    const written = said.filter((m) => m.authorKind === "person").flatMap((m) => (u64(m.seq) !== null ? [[m.seq as number, str(m.text) ?? ""] as [number, string]] : []));
    let messages = timed("chat.shown", () => this.#shown(station, thread, agents, said, waits, whom));
    // The station binds a capacity retry, and a failed turn, to the notice that announced it. Only that notice offers
    // cancelling the retry, or trying again, and only while that agent still stands there: an old notice must never
    // stop or start later work in the same chat.
    for (const agent of agents) {
      const session = get(agent, "session");
      const turn = get(session, "lastTurn");
      const about = get(turn, "about");
      const key = str(get(session, "key"));
      const detail = str(get(turn, "detail")) ?? "";
      const outcome = get(turn, "outcome");
      if (key === undefined || (outcome !== "failed" && outcome !== "completed" && outcome !== "aborted") || get(about, "thread") !== id) continue;
      // Waiting to retry at capacity: 取消; else one that failed for the provider or the connection, or one the station
      // stopped asking for a state (回复即可继续), or one cut off by a non-update station restart, and is still where the
      // session stands (nothing ran or was sent since): 重试, as a reply would (station actor.ts `retryable`).
      const status = present.sessionStatus(session);
      const mark = outcome === "failed" && detail.startsWith("overloaded:") && present.waiting(session) !== null ? "retrySession"
        : outcome === "failed" && status === "failed" && AGAIN.some((reason) => detail.startsWith(`${reason}:`)) ? "againSession"
        // Its allowance asked again showed a limit its words did not name: 重新分配账号 (actor.ts `LIMIT_SHOWN`).
        : outcome === "failed" && status === "failed" && detail.startsWith("limit:") ? "reassignSession"
        : outcome === "completed" && status === "unexpected" ? "againSession"
        : outcome === "aborted" && status === "aborted" && detail === "other: cut off by restart" ? "againSession" : null;
      if (mark === null) continue;
      const at = messages.findIndex((m) => m.system === true && m.seq === get(about, "seq") && m.ts === get(about, "ts"));
      const notice = messages[at];
      if (notice && isObject(notice.notice)) messages[at] = { ...notice, notice: { ...notice.notice, [mark]: key } };
    }
    // A sent message leaves the outbox as its own entry (or anything later) arrives; before the station answered
    // with its seq, it is the viewer's first message since it was sent with the same words.
    const newest = u64(page.last);
    const mine = written.filter(([seq]) => messages.some((m) => m.seq === seq && m.mine === true));
    let past = 0;
    const list = this.local.outbox(station, id).map((m) => ({ ...m }));
    const kept: J[] = [];
    for (const m of list) {
      // Queued messages have not reached the station; equal text cannot acknowledge them.
      if (m.queued || m.uploads?.length) { kept.push(m); continue; }
      const seq = u64(m.seq);
      if (seq !== null) {
        past = Math.max(past, seq);
        const arrived = newest !== null && newest >= seq;
        if (arrived) this.local.remember(station, id, seq, String(m.id));
        else kept.push(m);
        continue;
      }
      const after = Math.max(u64(m.after) ?? 0, past);
      m.after = after;
      const text = str(m.text) ?? "";
      const found = mine.find(([s, said]) => s > after && said.trim() === text.trim());
      if (found) {
        past = found[0];
        this.local.remember(station, id, found[0], String(m.id));
      } else kept.push(m);
    }
    this.local.outboxSettle(station, id, kept);
    const outbox = structuredClone(kept);
    for (const [i, m] of messages.entries()) {
      const seq = u64(m.seq);
      if (seq === null) continue;
      const outgoing = this.local.outgoing(station, id, seq);
      if (outgoing !== undefined && m.outgoing !== outgoing) messages[i] = { ...m, outgoing };
    }
    const people = (Array.isArray(thread.people) ? thread.people : []).map((p: J) => present.person(p, viewer, members_));
    if (Array.isArray(thread.people)) thread.people = people;
    if (thread.creator !== undefined) thread.creator = present.person(thread.creator, viewer, members_);
    const strOf = (v: J, k: string) => str(get(v, k)) ?? "";
    const { place, slackUrl, slackApp, feishuUrl, commaUrl, commaApp } = this.#whereIn(station, agents, strOf(thread, "surface"), strOf(thread, "channel"), strOf(thread, "channelName"), strOf(thread, "threadTs"), undefined, get(thread, "links"));
    // (a Slack thread's agents with no chat of their own here are listed by their session alone, its row's thread null)
    let found = this.#row(station, { thread: id });
    for (const key of found === null ? members(thread) : []) {
      const alone = this.#row(station, { session: key });
      if (alone !== null && alone !== undefined && alone.thread === null) {
        found = alone;
        break;
      }
    }
    // what is asked here, let go from here (忽略): said let go at once, as its station will say it (back if refused)
    const asking = found !== undefined && found !== null ? decisions.asked(found) : null;
    const lettingGo = found !== undefined && found !== null && asking !== null && this.local.lettingGo(station, id, u64(asking.seq) ?? -1);
    const row = lettingGo ? decisions.withLetGo(found) : (found ?? undefined);
    const open = (d: J) => !this.local.answered(station, id, u64(d.seq) ?? 0);
    let pendingCard: [number, boolean] | null | undefined;
    if (found !== undefined) {
      const d = row !== undefined ? decisions.ofRow(row) : null;
      pendingCard = d !== null && open(d) ? [u64(d.seq) ?? 0, decisions.dismissed(d)] : null;
    }
    messages.splice(0, messages.length, ...decisions.inMessages(messages, pendingCard, outbox.filter((m) => m.state !== "failed")));
    const elsewhere = timed("chat.elsewhere", () => this.#sentElsewhere(station, thread, agents, messages, u64(page.first) !== null && page.first > 1, page.end === false, { members: members_, bots }));
    // (folded once what each notice is bound to, and what was sent elsewhere after which, is known of them one by one)
    messages = foldNotices(messages, new Set(elsewhere.flatMap((s) => (u64(s.after) !== null ? [s.after as number] : []))));
    const title = row !== undefined && row.title !== undefined ? row.title : typeof page.title === "string" ? page.title : format.chatTitle(thread);
    const view: J = {
      me: this.me(scope),
      place,
      slackUrl,
      ...(slackApp !== null ? { slackApp } : {}),
      ...(feishuUrl !== null ? { feishuUrl } : {}),
      ...(commaUrl !== null ? { commaUrl } : {}),
      ...(commaApp !== null ? { commaApp } : {}),
      title,
      people,
      agents: answeredAt(agents, messages, outbox),
      messages,
      elsewhere,
      more: u64(page.first) !== null && page.first > 1,
      newer: page.end === false,
      firstEntry: u64(page.first),
      ...(page.older === "reading" || page.older === "failed" ? { older: page.older } : {}),
      ...(page.older === "failed" && typeof page.olderFailed === "string" ? { olderFailed: page.olderFailed } : {}),
      lastEntry: u64(page.last),
      at: page.at ?? null,
      atOffset: page.atOffset ?? null,
      caught: page.caught ?? null,
      told: Array.isArray(page.told) ? page.told : null,
      outbox,
      link: this.link(station),
      offline: this.offline(station),
      thread,
      archived: thread.hiddenAt !== undefined && thread.hiddenAt !== null,
    };
    const archived = this.local.archivedChanging(station, id, null);
    if (archived !== null) view.archived = archived;
    if (row !== undefined && row.pinned !== undefined) view.pinned = typeof row.pinned === "number";
    const opener = row !== undefined ? this.#opener(station, row) : null;
    if (opener !== null) view.opener = opener;
    const openers = row !== undefined ? this.#openers(station, row) : [];
    if (openers.length > 0) view.openers = openers;
    // the chats it opened, each where it stands, for its bar's list of them
    const opened = row !== undefined ? this.#opened(station, row) : [];
    if (opened.length > 0) {
      view.opened = opened;
      view.openedText = t("core-views.opened", { n: opened.length });
    }
    const sessions = arr(view.agents).flatMap((a) => (a.session !== undefined ? [a.session] : []));
    const watch = present.rowWatch(sessions);
    if (watch !== null) view.watch = watch;
    const card = row !== undefined ? decisions.ofRow(row) : null;
    if (card !== null && open(card)) view.decision = decisions.shown(card);
    // Its row as this page has it: read, for showing it reads it. Whether it was read before it was opened changes
    // nothing here (where it stands, its archive): opening a chat only raises what is brought first, so the page is
    // as it would be at once, not a moment after its read is told (the user, 2026-11-09).
    const seen = row !== undefined ? { ...row, unread: false } : undefined;
    if (seen !== undefined && present.archivable(seen) && view.archived !== true) view.archivable = true;
    // Where it stands, as its row's second line says it (what an agent needs, why it stopped, what it waits on, done):
    // said at the end of its messages too. A card waiting is not: it shows in the chat itself; nor what an agent waits
    // on: its activity under the messages says it, with how long it has waited. An agent this page's summary has at
    // work (it says at once that it took a message) is at work, whatever the shared row read after says; and nothing
    // is said while the viewer's words are on their way: the turn it tells of no longer stands. Nor once they are in
    // the chat, until one of its agents has had a turn since (`unheard`): that an agent took them comes by another
    // read than the chat's page, and between the two the line of the turn before came back, gone again as the agent
    // set to work (the user, 2026-11-10: 「有个结束的提示，发消息后会出现，然后 agent 开始行动就消失」). Their
    // station's times both: a message's, a turn's.
    const sending = outbox.some((m) => m.state !== "failed");
    const held = (a: J) => {
      const s = agents.find((b) => get(b.session, "key") === a.key)?.session;
      const status = s !== undefined ? present.shownStatus(s) : null;
      return status === "queued" || (status === "running" && present.waiting(s) === null) ? s : present.session(a);
    };
    const sentAt = messages.reduce((at: number, m) => (typeof m.outgoing === "string" ? Math.max(at, u64(m.createdAt) ?? 0) : at), 0);
    const since = (s: unknown): boolean => {
      const turn = get(s, "lastTurn");
      return (u64(get(turn, "startedAt")) ?? 0) >= sentAt || (u64(get(turn, "endedAt")) ?? 0) >= sentAt;
    };
    const unheard = sentAt > 0 && !agents.some((a) => since(a.session)) && !(seen !== undefined && arr(seen.agents).some(since));
    const shown = seen !== undefined && Array.isArray(seen.agents) && !sending && !unheard ? { ...seen, agents: seen.agents.map(held) } : null;
    const line = shown !== null ? present.rowStateLine(shown, false, (agent) => {
      const status = present.shownStatus(agent);
      // A stop is already announced in the conversation; its status still remains on the list row.
      if (status === "aborted") return true;
      if (status !== "failed" && status !== "unexpected") return false;
      // Only the notice explicitly recorded for this turn can replace its state. Do not mistake another agent's
      // notice (or an earlier one) for it; when the notice isn't loaded the state remains visible.
      const about = present.stateAbout(agent, u64(thread.id) ?? null);
      return about !== null && messages.some((m: J) => (u64(m.seq) ?? Infinity) <= about && about <= (endSeq(m) ?? -1) && get(get(m, "notice"), "failed") === true);
    }) : null;
    // What it needed of a person, let go by the viewer (忽略): kept, said as let go, in place of what its row says
    const letGo = shown !== null ? present.rowLetGoNeed(shown) : null;
    if (letGo !== null) {
      view.stateText = t("core-logic.decisions.dismissedNeed", { text: letGo });
      view.stateLead = "dismissed";
      view.stateRest = letGo;
    } else if (line !== null && line[3]?.kind !== "wait") {
      view.stateText = line[0];
      const lead = line[3];
      if (lead !== null) {
        view.stateLead = lead.kind;
        view.stateRest = lead.rest;
      }
    }
    // What is asked here and not decided yet (a card, or an agent needing a person): the page leads to each. A card is
    // let go under its post (`asked`), with its options; an agent's need where the chat's end says what it needs
    // (`stateAsk`), the reminder the viewer reads, else under the post that asks.
    view.asks = row !== undefined && view.archived !== true
      ? decisions.undecided(row).filter((d) => u64(d.seq) !== null && open(d)).map((d) => decisions.askOf(row, d, view.me))
      : [];
    for (const ask of view.asks) {
      if (!ask.card && view.stateLead === "need") {
        view.stateAsk = ask.seq;
        continue;
      }
      const at = messages.findIndex((x) => u64(get(x, "seq")) === ask.seq);
      // (on a copy: a message drawn is kept as it was drawn)
      if (at >= 0 && isObject(messages[at])) messages[at] = { ...messages[at], asked: true };
    }
    // The bell to what waits floats over the list's end only while that is out of view there: one at the end itself
    // (the line saying what an agent needs, or the last post with nothing after it) shows whenever the end does, so
    // the end keeps clear of the bell only for another. Else a need coming in would push the chat up for nothing.
    const lastSeq = messages.length > 0 ? endSeq(messages[messages.length - 1]) : null;
    const atEnd = (seq: number) => view.newer !== true && (seq === view.stateAsk || (seq === lastSeq && arr(outbox).length === 0 && view.stateText === undefined));
    if (view.asks.some((a: J) => !atEnd(a.seq))) view.askClear = true;
    if (letters > 0) view.letters = letters;
    // Its Slack, Feishu, Comma and group threads, where what is sent can be copied (`chat.cc`), each ticked or not.
    const ccTo = arr(get(thread, "cc")).flatMap((o) => {
      const to = u64(get(o, "thread"));
      const place = format.placeName(strOf(o, "surface"), strOf(o, "channel"), strOf(o, "channelName"));
      if (to === null || place === null) return [];
      const via = format.placeKind(strOf(o, "surface"), strOf(o, "channel"));
      return [{ thread: to, place, via, on: this.ccOn(station, id, to) }];
    });
    if (ccTo.length > 0) view.cc = ccTo;
    return { ok: view };
  }

  /// A chat's agents: those its thread names that are known, as its page and its messages read them (`agent`'s
  /// `forChat`).
  #agentsOf(station: string, thread: J): J[] {
    return members(thread).flatMap((key) => {
      const a = this.agent(station, key, true);
      return a === null ? [] : [a];
    });
  }

  /// Who a chat's messages are told apart by: the viewer, its workspace's members, the Slack names a mention may be.
  #peopleOf(station: string, agents: J[]): { scope: string; viewer: J; slackUsers: string[]; members_: J[]; bots: [string, string][] } {
    const scope = ofAddress(station);
    const viewer = this.me(scope);
    const slackUsers = arr(get(this.#chatOverview(station), "slackUsers")).filter((u): u is string => typeof u === "string");
    const members_ = arr(get(this.ok({ topic: "workspace", workspace: scope }), "members"));
    const bots = agents.flatMap((a) => {
      const b = a.connect !== undefined ? present.botOf(a.connect) : null;
      return b === null ? [] : [b];
    }).concat(this.#core.data.slackNames(station));
    return { scope, viewer, slackUsers, members_, bots };
  }

  /// A chat's messages (`said`: its entries merged, letters left out) as its page shows each (shownMessage): the
  /// viewer's those with seqs in `waits` still waiting for its agents; a notice that a runtime is not installed with
  /// installing it, as the station's updates have it now (or under the viewer's message that waits for it); a failure
  /// notice one to report where the station takes bug reports.
  #shown(station: string, thread: J, agents: J[], said: J[], waits: number[], people = this.#peopleOf(station, agents)): J[] {
    const { scope, viewer, slackUsers, members_, bots } = people;
    const updates = arr(get(this.#chatOverview(station), "updates"));
    const role = get(this.ok({ topic: "workspace", workspace: scope }), "role");
    const manages = role === "owner" || role === "admin";
    const reports = get(this.#chatOverview(station), "feedback") === true;
    // What each message is shown as follows from it and from this (the chat's people and the station's state): while
    // this is as it was, a message made before is the one shown, so a new message costs that message.
    // (of its agents, what shownMessage reads of them: who each is, not what each did since)
    const who = agents.map((a) => [get(a.session, "key"), get(a.session, "runtime"), get(a.session, "agentText"), get(a.session, "maker")]);
    // (the names of the profiles its notices are about, each read alone (data.ts overviewProfile), as they say them)
    const named = this.#profileNames(station, said);
    const by = this.#steady(`shown\u0001${station}\u0001${String(thread.id)}`, [who, viewer, slackUsers, members_, bots, thread.creator, updates, manages, reports, named]);
    const messages = said.map((raw) => {
      const waiting = u64(raw.seq) !== null && waits.includes(raw.seq as number);
      const was = this.#shownMade.get(raw);
      if (was !== undefined && was.by === by && was.waiting === waiting) return was.out;
      work.messages++;
      const profile = str(raw.profile);
      const m = shownMessage(raw, agents, viewer, slackUsers, members_, bots, thread.creator, profile !== null ? (named[profile] ?? null) : null);
      const out: J = { ...m, waiting };
      const install = m.system === true && typeof m.runtime === "string" ? present.installView(m.runtime, updates, manages) : null;
      if (install !== null) out.install = install;
      else if (reports && m.system === true && u64(m.seq) !== null && (str(m.text) ?? "").startsWith("⚠️")) out.reportable = true;
      this.#shownMade.set(raw, { by, waiting, out: sharedValue(out) });
      return out;
    });
    return blockedUnder(messages);
  }

  /// The names of the station's profiles still.fail's notices among `said` are about (their `profile`), by id: each
  /// profile read alone (data.ts overviewProfile), never the whole overview; one not known, or unnamed, left out.
  #profileNames(station: string, said: J[]): Record<string, string> {
    const out: Record<string, string> = {};
    const asked = new Set<string>();
    for (const m of said) {
      const id = str(m.profile);
      if (id === null || id === "" || asked.has(id) || !isStationAuthor(m.authorKind)) continue;
      asked.add(id);
      const name = str(get(this.#core.data.overviewProfile(station, id), "name"));
      if (name !== null && name !== "") out[id] = name;
    }
    return out;
  }

  /// `value` as it was for `key` the last time, when it is equal to it: what is made of it can be kept by its identity.
  #steady<T>(key: string, value: T): T {
    const was = this.#steadied.get(key) as T | undefined;
    if (was !== undefined && equal(was, value)) {
      this.#steadied.delete(key);
      this.#steadied.set(key, was);
      return was;
    }
    this.#steadied.delete(key);
    this.#steadied.set(key, value);
    while (this.#steadied.size > 64) this.#steadied.delete(this.#steadied.keys().next().value!);
    return value;
  }

  /// Chat `id`'s messages as its page draws them (`ChatView.messages`), from `entries` as its station reads them (GET
  /// /threads/:id/entries): a picture of the chat draws them as its list does (publish.ts). Nothing of the page's own
  /// is in them: none waits, nothing is on its way, nothing is asked.
  listed(station: string, id: number, entries: unknown[]): J[] {
    const thread = this.#core.data.listedThread(station, id) ?? get(this.ok({ topic: "thread", station, thread: id }), "thread") ?? {};
    const agents = this.#agentsOf(station, thread);
    const keys = new Set(members(thread));
    const messages = foldNotices(decisions.inMessages(this.#shown(station, thread, agents, merge(entries).filter((m) => !isLetter(m, keys)), []), null));
    const out = drawn({ ok: { agents, messages } }, (path) => this.local.uploadOf(station, path), this.#core.data.mdStore(station, `t:${id}`));
    const ws = ofAddress(station);
    return arr(get(out.ok, "messages")).map((m) => (isObject(m) && vaultAskOf(get(m, "card")) !== null ? { ...m, card: this.#vaultCard(m.card, ws) } : m));
  }

  /// Whether what is sent to a chat from here is copied to its Slack or Feishu thread `to` (`chat.cc`): off until ticked,
  /// for as long as the app runs.
  ccOn(station: string, thread: number, to: number): boolean {
    this.#seen.read(`cc ${station} ${thread}`);
    return this.#cc.has(`${station} ${thread} ${to}`);
  }

  /// The threads what is sent to a chat from here is copied to now.
  ccTo(station: string, thread: number): number[] {
    this.#seen.read(`cc ${station} ${thread}`);
    const prefix = `${station} ${thread} `;
    return [...this.#cc].filter((k) => k.startsWith(prefix)).map((k) => Number(k.slice(prefix.length)));
  }

  /// How many of the messages of chat `thread` of `station` its page opens on at its end (station/topics.ts #opening),
  /// as its page told it (`chat.window`, by its thread or by its agent's session bound to it); null, not told: a page
  /// of its entries, as before.
  chatFirstRows(station: string, thread: number): number | null {
    let rows: number | null = null;
    for (const [key, told] of this.#chatWindows) {
      const [s, th, session] = key.split("\u0001");
      if (s !== station) continue;
      if (th === String(thread) || (session !== "" && this.boundThread(station, session) === thread)) rows = Math.max(rows ?? 0, told);
    }
    return rows;
  }

  /// A chat's page says how many of its messages it opens on at its end (`chat.window`): as many as fill its screen,
  /// told before the chat is asked; it asks more before them once it is read back and less than a screen of them is
  /// above what shows (`chat.older` with its `rows`).
  setChatWindow(station: string, thread: number | null, session: string | null, rows: number): void {
    this.#chatWindows.set(chatWindowKey(station, thread, session), rows);
  }

  /// How many of chat list `list`'s rows go out (`chatsWindow`'s): as it was told, WINDOW_UNTOLD where it was not.
  chatsWindow(list: Topic): number {
    const key = windowKey(list);
    this.#seen.read(`window ${key}`);
    return this.#windows.get(key) ?? WINDOW_UNTOLD;
  }

  /// Chat list `list` (its topic `chats`, asked or about to be) shows `rows` of its rows (`chats.window`): its first
  /// rows that many, said as a screen asks it; told again while the list is kept, it only grows (a page that showed
  /// more as it was scrolled, or another reading it too, keeps them). What shows the list is made again with them: its
  /// keyed value goes out as the rows added (collections.ts), not whole.
  setChatsWindow(list: Topic, rows: number): void {
    const key = windowKey(list);
    const was = this.#windows.get(key);
    const now = was === undefined ? rows : Math.max(was, rows);
    if (now === was) return;
    this.#windows.set(key, now);
    this.#seen.touch(`window ${key}`);
  }

  /// A scope's chats as its list `chats {scope}` has them, every row made (not its window: what reads the list besides
  /// a page, a share's choice of a chat).
  chatsWhole(scope: string): Value | undefined {
    const chats = this.#chatsWhole(scope, false, false);
    if (chats === undefined || !("ok" in chats)) return chats;
    return { ok: wholeRows(chats.ok) };
  }

  /// Copying to a chat's thread `to` ticked or not: its pages show it.
  setCc(station: string, thread: number, to: number, on: boolean): void {
    const key = `${station} ${thread} ${to}`;
    if (on === this.#cc.has(key)) return;
    if (on) this.#cc.add(key);
    else this.#cc.delete(key);
    this.#seen.touch(`cc ${station} ${thread}`);
  }


  /// What a chat's agents and other chats' wrote each other (`chatLetters`), all of it as far as it is on the device
  /// (`whole` once all is): by the other chat, as lettersByChat has them, each named as the chat's page names its
  /// messages, with the chat's title.
  #chatLetters(station: string, id: number): Value | undefined {
    const chat = this.value({ topic: "chat", station, thread: id, session: null });
    if (chat === undefined || "err" in chat) return chat;
    const held = this.value({ topic: "letters", station, thread: id });
    if (held === undefined || "err" in held) return held;
    const view = chat.ok as J;
    const thread = view.thread as J;
    const keys = new Set(members(thread));
    const agents = arr(view.agents);
    const { viewer, members_, bots } = this.#peopleOf(station, agents);
    // Those kept as entries before letters had their own log, and those of it (`letters`), in the order written.
    const written = [...merge(arr(get(held.ok, "entries"))).filter((m) => isLetter(m, keys)), ...merge(arr(get(held.ok, "letters")))];
    const at = (m: J) => u64(m.createdAt) ?? 0;
    written.sort((a, b) => at(a) - at(b));
    const letters = written.flatMap((m) => {
      if (!isLetter(m, keys)) return [];
      const way = letterWay(m);
      const l = { ...way, title: cleanLetterTitle(way.title, bots, members_) };
      const shown: J = { ...shownMessage({ ...m, text: letterWords(str(m.text) ?? "") }, agents, viewer, [], members_, bots, thread.creator), waiting: false };
      // Coming in: by the agent of the chat it came from, named by that chat.
      if (l.way === "in") shown.by = { name: t("core-views.letters.their", { chat: l.title }), from: l.link, maker: get(shown.by, "maker") ?? null };
      return [{ message: shown, ...l }];
    });
    // Each chat's letters drawn as the chat's page draws its messages (their Markdown, their files).
    const chats = lettersByChat(letters).map((c) => {
      const out = drawn({ ok: { agents, messages: c.letters } }, (path) => this.local.uploadOf(station, path), this.#core.data.mdStore(station, `t:${id}`));
      return { ...c, letters: arr(get(out.ok, "messages")) };
    });
    return { ok: { title: view.title, chats, whole: get(held.ok, "whole") === true } };
  }

  /// A chat's messages as far as they are on the device (its `letters` topic: all its entries held), those that say
  /// something besides words (a file, a web link) drawn as its page draws them (`drawn`), and its things read from them
  /// (things.ts); a computed, made again only as what it reads changes. Null until its chat and its entries are read.
  #things(station: string, id: number): { messages: J[]; things: ReturnType<typeof thingsOf>; whole: boolean; title: unknown } | null {
    const key = `${station}/${id}`;
    let made = this.#thingsKept.get(key);
    if (made === undefined) made = computed(() => this.#thingsMade(station, id));
    this.#thingsKept.delete(key);
    this.#thingsKept.set(key, made);
    // (a few chats': those open, and the last ones left)
    for (const k of this.#thingsKept.keys()) if (this.#thingsKept.size > 6) this.#thingsKept.delete(k);
    return made.get();
  }

  #thingsMade(station: string, id: number): { messages: J[]; things: ReturnType<typeof thingsOf>; whole: boolean; title: unknown } | null {
    const chat = this.value({ topic: "chat", station, thread: id, session: null });
    const held = this.value({ topic: "letters", station, thread: id });
    if (chat === undefined || !("ok" in chat) || held === undefined || !("ok" in held)) return null;
    const view = chat.ok as J;
    const thread = view.thread as J;
    const keys = new Set(members(thread));
    const agents = arr(view.agents);
    const scope = ofAddress(station);
    const viewer = this.me(scope);
    const members_ = arr(get(this.ok({ topic: "workspace", workspace: scope }), "members"));
    const some = merge(arr(get(held.ok, "entries"))).filter((m) => {
      if (isLetter(m, keys) || isStationAuthor(m.authorKind)) return false;
      return (Array.isArray(m.attachments) && m.attachments.length > 0) || (str(m.text) ?? "").includes("://");
    });
    const shown = some.map((m) => shownMessage(m, agents, viewer, [], members_, [], thread?.creator));
    const out = drawn({ ok: { agents, messages: shown } }, (path) => this.local.uploadOf(station, path), this.#core.data.mdStore(station, `t:${id}`));
    const messages = arr(get(out.ok, "messages"));
    const value = { messages, things: thingsOf(messages), whole: get(held.ok, "whole") === true, title: view.title };
    return value;
  }

  /// What was said in a chat besides words (`chatThings`), as far as it is on the device (`whole` once all is): its
  /// pictures and videos, files, web links and pull requests, each the latest first, how many of each, those of each
  /// that have the words `q` (all of them without any), the pictures and videos also by the day and the message they were
  /// sent with (`mediaDays`). A pull request says what its card says of it (its title, how it
  /// stands, its checks, when it last changed) once its station has read it.
  #chatThings(station: string, id: number, q: string): Value | undefined {
    const chat = this.value({ topic: "chat", station, thread: id, session: null });
    if (chat === undefined || "err" in chat) return chat;
    const held = this.value({ topic: "letters", station, thread: id });
    if (held === undefined || "err" in held) return held;
    const read = this.#things(station, id);
    if (read === null) return undefined;
    const clock = this.#clock();
    const pulls = read.things.pulls.map((p) => {
      const card = this.ok({ topic: "linkPreview", station, url: p.url! });
      if (get(card, "kind") !== "github_pull_request") return p;
      const changed = u64(get(card, "updatedAt"));
      const checks = get(card, "checks");
      return {
        ...p,
        title: str(get(card, "title")) ?? "",
        ...(typeof get(card, "state") === "string" ? { state: get(card, "state") } : {}),
        ...(isObject(checks) ? { checks } : {}),
        ...(changed !== null && changed > 0 ? { updatedAt: changed, time: { updatedAt: present.stamp(changed, clock) } } : {}),
      };
    });
    const all = { ...read.things, pulls };
    const words = refs.terms(q);
    const counts = Object.fromEntries(THING_KINDS.map((k) => [k, all[k].length]));
    const found = Object.fromEntries(THING_KINDS.map((k) => [k, thingsHaving(all[k], words)])) as typeof all;
    const days = mediaDays(found.media, (ms) => format.dayLabel(ms, clock.now, clock.offsetMin), (ms) => format.clock(ms, clock.offsetMin));
    return { ok: { title: read.title, whole: read.whole, counts, ...found, mediaDays: days } };
  }

  /// A chat's messages as far as they are on the device (its entries held, in order), merged.
  #heldMessages(station: string, id: number, of: number): J[] {
    const held = this.#core.data.logRange("entry", station, String(id), 1, of);
    return merge([...held.keys()].sort((a, b) => a - b).map((n) => held.get(n)));
  }

  /// What people said in a chat (`authorKind` person) as far as it is on the device, their messages merged (entries.ts),
  /// in order. Read whole once; then only the entries put in its log since (`Data.logPutSince`), so an agent's message
  /// changing as it works costs that entry, not the chat's every one; whole again where what changed is not known.
  #peopleSaid(station: string, id: number, of: number): PeopleSaid {
    const key = `${station}/${id}`;
    const data = this.#core.data;
    let kept = this.#peopleKept.get(key);
    const since = data.logPutSince("entry", station, String(id), kept?.rev ?? 0);
    const read = (n: number): J => data.logRange("entry", station, String(id), n, n).get(n);
    // A message as its entry and its edits held make it; null for one not a person's (or not held).
    const made = (seq: number, edits: Map<number, number[]>): J | null => {
      const entry = read(seq);
      if (get(entry, "kind") !== "message" || get(entry, "authorKind") !== "person") return null;
      return merge([entry, ...(edits.get(seq) ?? []).map(read)])[0] ?? null;
    };
    if (kept === undefined || since.put === null) {
      // (their messages and the edits of those alone, found by their indexes: not the agents' replies, most of a chat)
      const { held, edits } = data.peopleEntries(station, id, of);
      const people = merge([...held.keys()].sort((a, b) => a - b).map((n) => held.get(n))).filter((m) => m.authorKind === "person");
      kept = { rev: since.rev, changed: (kept?.changed ?? 0) + 1, messages: new Map(people.map((m) => [m.seq as number, m])), order: people.map((m) => m.seq as number), edits };
    } else if (since.rev !== kept.rev) {
      const { messages, order, edits } = kept;
      const again = new Set<number>();
      for (const n of since.put) {
        const e = read(n);
        if (get(e, "kind") === "edit" && typeof get(e, "target") === "number") {
          const of_ = edits.get(e.target) ?? [];
          if (!of_.includes(n)) edits.set(e.target, [...of_, n].sort((a, b) => a - b));
          again.add(e.target);
        } else again.add(n);
      }
      for (const seq of again) {
        const m = made(seq, edits);
        const at = lowerBound(order, seq);
        if (m === null) {
          if (messages.delete(seq)) {
            order.splice(at, 1);
            kept.changed++;
          }
          continue;
        }
        if (messages.get(seq) === m) continue;
        if (!messages.has(seq)) order.splice(at, 0, seq);
        messages.set(seq, m);
        kept.changed++;
      }
      kept.rev = since.rev;
    }
    this.#peopleKept.delete(key);
    this.#peopleKept.set(key, kept);
    // (a few chats': those open, and the last ones left)
    for (const k of this.#peopleKept.keys()) if (this.#peopleKept.size > 6) this.#peopleKept.delete(k);
    return kept;
  }

  /// A chat's outline (`chatOutline`): which messages people said in it, the viewer and anyone else (`authorKind`
  /// person, as its page tells its rows apart: not an agent's, not still.fail's notice), by the local day, oldest first,
  /// as far as the chat is on the device (`chat.bring` reads the rest; this asks for nothing). An index only: what each
  /// says and who said it are `chat.outline.rows`', so an agent at work, or a message's words edited, changes nothing
  /// of it. Made again only as a person's message comes or goes, the viewer or the zone changes, or a day goes by.
  #chatOutline(station: string, id: number): Value | undefined {
    const held = this.#core.held?.(station, id);
    const summary = this.#core.data.thread(station, id) as J;
    if (held === undefined || (summary === undefined && held.held === 0)) return undefined;
    const { viewer, slackUsers } = this.#peopleOf(station, []);
    const mine = this.#steady(`outline\u0001${station}\u0001${id}`, [viewer, slackUsers]);
    const clock = this.#clock();
    const today = format.localDay(clock.now, clock.offsetMin);
    const kept = this.#peopleSaid(station, id, held.of);
    const key = `${station}/${id}`;
    let index = this.#outlineKept.get(key);
    if (index === undefined || index.kept !== kept || index.changed !== kept.changed || index.mine !== mine || index.offset !== clock.offsetMin || index.today !== today) {
      const days: { date: string; day: string; seqs: number[] }[] = [];
      const byDate = new Map<string, { date: string; day: string; seqs: number[] }>();
      let others = false;
      for (const seq of kept.order) {
        const raw = kept.messages.get(seq) as J;
        let d = this.#outlineDay.get(raw);
        if (d === undefined || d.mine !== mine || d.offset !== clock.offsetMin) {
          const ms = u64(raw.createdAt);
          d = { mine, offset: clock.offsetMin, date: ms !== null ? outlineDate(ms, clock.offsetMin) : "", ms, viewer: present.isViewer(viewer, str(raw.author) ?? "", slackUsers) };
          this.#outlineDay.set(raw, d);
        }
        if (!d.viewer) others = true;
        // (a day once, though what was said on it came apart: its key is its date)
        let day = byDate.get(d.date);
        if (day === undefined) {
          day = { date: d.date, day: d.ms !== null ? format.dayLabel(d.ms, clock.now, clock.offsetMin) : "", seqs: [] };
          byDate.set(d.date, day);
          days.push(day);
        }
        day.seqs.push(seq);
      }
      // (what is sent is never written: the store keeps it)
      index = { kept, changed: kept.changed, mine, offset: clock.offsetMin, today, days: days.map((d) => sharedValue(d)), count: kept.order.length, others };
      this.#outlineKept.delete(key);
      this.#outlineKept.set(key, index);
      for (const k of this.#outlineKept.keys()) if (this.#outlineKept.size > 6) this.#outlineKept.delete(k);
    }
    return { ok: { days: index.days, count: index.count, others: index.others, ...held } };
  }

  /// The rows of a chat's outline for `seqs` (`chat.outline.rows`): each a person's message as the outline shows it
  /// (who, when, its first words on a line cut to `OUTLINE_WORDS`), in the order asked, read from what the device holds
  /// (it asks nothing); one not held, or not a person's, left out. A row is made again only as its message or who it is
  /// shown by changes.
  outlineRows(station: string, id: number, seqs: readonly number[]): J {
    const of = this.#core.held?.(station, id).of ?? this.#core.data.logSpan("entry", station, String(id))?.max ?? 0;
    const kept = this.#peopleSaid(station, id, of);
    const summary = this.#core.data.thread(station, id) as J;
    const { viewer, slackUsers, members_, bots } = this.#peopleOf(station, []);
    const by = this.#steady(`outlineRows\u0001${station}\u0001${id}`, [viewer, slackUsers, members_, bots, get(summary, "creator") ?? null]);
    const clock = this.#clock();
    const rows = seqs.flatMap((seq) => {
      const raw = kept.messages.get(seq);
      if (raw === undefined) return [];
      const was = this.#outlineMade.get(raw);
      if (was !== undefined && was.by === by && was.offset === clock.offsetMin) return [was.item];
      const m = shownMessage(raw, [], viewer, slackUsers, members_, bots, get(summary, "creator"));
      const at = u64(m.createdAt);
      const words = wordsOf(m) || quoteComment(m);
      const item = sharedValue({
        seq: m.seq, mine: m.mine === true, author: str(m.author) ?? "", by: m.by,
        words: words === "" && arr(m.attachments).length > 0 ? t("core-views.file") : cutWords(words, OUTLINE_WORDS),
        clock: at !== null ? format.clock(at, clock.offsetMin) : "",
      });
      this.#outlineMade.set(raw, { by, offset: clock.offsetMin, item });
      return [item];
    });
    return { rows };
  }

  /// What a chat's outline lists for what was looked for (`chat.outline.find`): the messages `found` (station/topics.ts
  /// `found`), agents' too but not what two chats' agents wrote each other (not in the chat), the newest
  /// `OUTLINE_FOUND` of them, each with who said it and the line of it that has the words, cut to one line of the panel
  /// as a row's are; `total` how many were found, `more` how many older ones are not listed. Its `days` are the index's
  /// kind of day (`OutlineDay`: `date` the local date, "" where when is not known, `day` its heading), oldest first,
  /// each date once (one that came apart joined), with `items` its rows for `seqs`:
  /// `{ words, days: [{ date, day, items: [{ seq, mine, author, by, agent, system, clock, snippet }] }], total, more,
  /// held, of, whole }`.
  outlineFound(station: string, id: number, f: { words: string[]; found: { seq: number }[]; held: number; of: number; whole: boolean }): J {
    const summary = this.#core.data.thread(station, id) as J;
    const agents = this.#agentsOf(station, summary);
    const keys = new Set(members(summary));
    const { viewer, slackUsers, members_, bots } = this.#peopleOf(station, agents);
    const messages = new Map(this.#heldMessages(station, id, f.of).map((m) => [m.seq as number, m]));
    const clock = this.#clock();
    const all = f.found.flatMap(({ seq }) => {
      const raw = messages.get(seq);
      return raw === undefined || isLetter(raw, keys) ? [] : [raw];
    });
    const listed = all.slice(Math.max(0, all.length - OUTLINE_FOUND));
    const rows = listed.map((raw) => {
      const m = shownMessage(raw, agents, viewer, slackUsers, members_, bots, get(summary, "creator"));
      const at = u64(m.createdAt);
      return {
        at, seq: m.seq, mine: m.mine === true, author: str(m.author) ?? "", by: m.by, agent: m.authorKind === "agent", system: m.system === true,
        clock: at !== null ? format.clock(at, clock.offsetMin) : "", snippet: cutWords(refs.excerpt(str(m.text) ?? "", f.words, SNIPPET_LEAD, OUTLINE_WORDS + 1).text, OUTLINE_WORDS),
      };
    });
    const days: { date: string; day: string; items: J[] }[] = [];
    const byDate = new Map<string, { date: string; day: string; items: J[] }>();
    for (const { at, ...row } of rows) {
      const date = at !== null ? outlineDate(at, clock.offsetMin) : "";
      let day = byDate.get(date);
      if (day === undefined) {
        day = { date, day: at !== null ? format.dayLabel(at, clock.now, clock.offsetMin) : "", items: [] };
        byDate.set(date, day);
        days.push(day);
      }
      day.items.push(row);
    }
    return { words: f.words, days, total: all.length, more: all.length - listed.length, held: f.held, of: f.of, whole: f.whole };
  }

  /// What a chat's agents said in Slack and were given from it (not this chat's own thread), each after the message it
  /// followed. Only what falls in the window of messages shown (`more`/`newer`: the chat goes on before/after it): the
  /// rest comes with its page. A Slack message given to several of its agents shows once. With no chat (`thread`
  /// null), all of it, each before any message.
  #sentElsewhere(station: string, thread: J, agents: J[], messages: J[], more: boolean, newer: boolean, people: { members: J[]; bots: [string, string][] }): J[] {
    const own = thread === null ? null : `${str(get(thread, "channel")) ?? ""}/${str(get(thread, "threadTs")) ?? ""}`;
    const first = u64(messages[0]?.createdAt);
    const last = u64(messages.at(-1)?.createdAt);
    if ((more || newer) && (first === null || last === null)) return [];
    const overview = this.#chatOverview(station);
    const workspaces = slackWorkspaces(overview);
    const connects = arr(get(overview, "connects"));
    const offsetMin = this.#core.host.utcOffsetMin(this.#core.host.nowMs());
    const out: J[] = [];
    const heard = new Set<string>();
    // Whose workspace keeps a file heard with a message: the session given it (a person's file, put in its uploads), or
    // the station's agent whose workspace its path is in (another agent's post in the same thread names its own
    // uploads). Asked of the hearer's session, another agent's file answered 404, shown as 暂时无法预览 for good
    // (pengxiao, 2026-11-16). The station's sessions read only once a file is not the hearer's.
    let others: J[] | null = null;
    const keeper = (path: string, hearer: J, key: string): string => {
      const within = (ws: string | null) => ws !== null && ws !== "" && path.startsWith(`${ws}/`);
      if (within(str(get(hearer, "workspace")))) return key;
      others ??= arr(this.ok({ topic: "sessions", station }));
      return str(get(others.find((s) => within(str(get(s, "workspace")))), "key")) ?? key;
    };
    for (const a of agents) {
      const key = str(get(a.session, "key"));
      if (key === null) continue;
      const said = this.#core.data.slackSaid(station, key).filter((s) => s.to !== own && !(more && s.at < first!) && !(newer && s.at >= last!));
      if (said.length === 0) continue;
      const threads = arr(get(this.ok({ topic: "session", station, key }), "threads"));
      const agent = { name: str(get(a.session, "agentText")) ?? "agent", agent: key, maker: get(a.session, "maker") ?? null, runtime: get(a.session, "runtime") ?? null };
      const pictures = slackPictures(a.session, threads, connects);
      for (const s of said) {
        // Another chat's agent's letter kept by a core before they were left out (elsewhere.ts `readItem`): never said
        // in Slack.
        if (!s.out && s.who === null) {
          const sent = sentHead(s.text);
          if (sent !== null && !sent.opened) continue;
        }
        // What the tool refused on its way to a thread its session is not in went nowhere (a chat_post to a mistyped
        // address, `CHT/…` for `CHAT/…`): it is not shown as sent to Slack.
        if (s.out && s.refused && !threads.some((th) => `${str(get(th, "channel"))}/${str(get(th, "threadTs"))}` === s.to)) continue;
        if (!s.out) {
          const id = `${s.user ?? ""} ${s.to} ${s.at}`;
          if (heard.has(id)) continue;
          heard.add(id);
        }
        let after = 0;
        for (const m of messages) {
          if (typeof m.createdAt !== "number" || m.createdAt > s.at) break;
          after = m.seq;
        }
        let place: J = s.to === "" ? null : format.place(threads, s.to, offsetMin, workspaces);
        if (place === null && s.to !== "") {
          // A message of its own in a channel, before its ts is known.
          const channel = s.to.split("/")[0]!;
          const named = threads.find((th) => get(th, "channel") === channel && typeof get(th, "channelName") === "string");
          const surface = str(get(named, "surface")) || "slack";
          place = { name: format.placeName(surface, channel, str(get(named, "channelName")) ?? "") ?? `#${channel}`, surface: format.placeKind(surface, channel) };
        }
        // (a bot is said as its mention, `<@U…>`)
        const picture = s.out || s.user === null ? undefined : pictures.get(s.user.replace(/^<@(.+)>$/, "$1"));
        const by = s.out ? structuredClone(agent) : { name: elsewhereSenderName(s, people.bots, people.members), ...(picture !== undefined ? { picture } : {}) };
        // A person's files are listed after their words, as the agent was given them: drawn as files, kept in the
        // workspace that holds them (`keeper`).
        const words = s.out ? { text: s.text, files: [] } : heardFiles(s.text);
        const text = present.mentions(words.text, people.bots, people.members);
        const item: J = { key: `${key}/${s.i}/${s.k}`, after, createdAt: s.at, text, place, failed: s.failed, by };
        if (words.files.length > 0) item.attachments = words.files.map((f) => ({ ...f, owner: keeper(f.path, a.session, key) }));
        if (!s.out) item.received = true;
        out.push(item);
      }
    }
    return out.sort((a, b) => a.createdAt - b.createdAt);
  }

  /// A pending chat's page: its station's chat once made and read, else what is known here.
  #pendingChat(station: string, key: string): Value | undefined | null {
    const chat = this.local.pending(key);
    if (!chat) return null;
    if (chat.made) {
      const view = this.#chat(station, chat.made[1]);
      if (view !== undefined && "ok" in view) {
        (view.ok as J).key = chat.made[0];
        return view;
      }
    }
    const outbox = chat.made ? structuredClone(this.local.outbox(station, chat.made[1])) : structuredClone(chat.queue);
    return {
      ok: {
        me: this.me(ofAddress(station)),
        thread: null,
        // named by no one yet: what its station will call it till then (chatTitle)
        title: t("core-views.new_chat"),
        people: [],
        agents: [],
        messages: [],
        more: false,
        outbox,
        link: this.link(station),
        offline: this.offline(station),
        pending: chat.made === null,
        key: chat.made ? chat.made[0] : null,
        failed: chat.failed,
      },
    };
  }

  /// An agent of a chat: its session, the connect that started it, its profile, turns and threads, the models it can
  /// move to and the accounts that can run them. The core's own, whole (choose.ts, `agentCard`): a chat sends of it what
  /// its page reads (its shape, ChatAgent), the rest dropped as it goes out. As a chat's page and its messages read it
  /// (`forChat`), made of what that reads of its station's overview, kept beside it (#chatOverview), not the overview,
  /// and without the models it can move to and the accounts that can run them (`choices`, `profiles`), which no chat
  /// reads: those are a model control's, asked as it opens (choose.ts).
  agent(station: string, key: string, forChat = false): J {
    const v = this.value({ topic: "session", station, key });
    let detail: J;
    if (v !== undefined && "ok" in v) detail = v.ok;
    else if (v !== undefined) return null;
    else {
      const data = this.#core.data;
      if (data.listed(station, "sessions")) {
        const found = data.listedSummary(station, key);
        if (found === undefined) return null;
        detail = { session: found };
      } else {
        const agent = this.#rowAgent(station, key);
        if (agent === null) return null;
        detail = { session: agent };
      }
    }
    const now = this.#core.host.nowMs();
    const session = present.session(get(detail, "session") ?? null);
    const overview = forChat ? this.#chatOverviewFor(station, str(get(session, "profile"))) : this.ok({ topic: "overview", station });
    const connect = present.connect(find(get(overview, "connects"), get(session, "connect")));
    const profile = present.profile(find(get(overview, "profiles"), get(session, "profile")));
    const runnable = runnableOn(overview, session, now);
    let account: J = runnable.find((p) => p.current === true) ?? null;
    if (account === null && isObject(profile)) {
      account = { id: profile.id ?? null, name: profile.name ?? null, current: true, kind: get(profile.access, "kind") ?? null, runtime: profile.runtime ?? null, quota: quotaFor(profile.quota ?? null, str(get(session, "model")) ?? str(profile.model) ?? null) };
      if (typeof profile.providerMark === "string") account.mark = profile.providerMark;
      if (typeof profile.planText === "string" && profile.planText !== "") account.planText = profile.planText;
    }
    // Its latest turn as its summary has it (its detail may list only the latest turns, read before this one began);
    // else the last its detail lists.
    const turns = arr(get(detail, "turns"));
    const lastTurn = get(get(detail, "session"), "lastTurn") ?? turns[turns.length - 1];
    const since = isObject(lastTurn) && (lastTurn.endedAt === undefined || lastTurn.endedAt === null) ? (lastTurn.startedAt ?? null) : null;
    return {
      status: present.shownStatus(session),
      badge: present.markOf(session),
      session,
      connect,
      profile,
      ...(forChat ? {} : { profiles: runnableOn(overview, session, now), choices: choices(overview, session, now) }),
      account,
      attention: attention(overview, session, now),
      since,
      wait: present.watching(session) ? null : present.waiting(session),
      turns: sharedOrCopied(get(detail, "turns") ?? []),
      threads: sharedOrCopied(get(detail, "threads") ?? []),
      jobs: sharedOrCopied(get(detail, "jobs") ?? []),
    };
  }

  /// What a chat's page reads of station `station`'s overview (schema.ts OVERVIEW_CHAT: its agents' accounts and
  /// connects, who the viewer is in Slack, its updates, whether it takes bug reports, its context), kept beside it
  /// (data.ts overviewChat): the overview whole is not read, and a change to the rest of it (its processes, its
  /// automatic decisions, a sign-in's step) makes no chat again.
  #chatOverview(station: string): J {
    return this.#core.data.overviewChat(station);
  }

  /// What a chat's agent that runs on profile `profile` reads of its station's overview: the chat's part, and of the
  /// station's profiles that one alone (data.ts overviewProfile), read by its id. What its page shows of an agent's
  /// account is that profile's (its name and what is left of it, `account` of those running its model the current
  /// one): the others are what a model control's panel shows (`pick`, asked as it opens).
  #chatOverviewFor(station: string, profile: string | null | undefined): J {
    const part = this.#chatOverview(station);
    if (!isObject(part)) return part;
    const own = typeof profile === "string" ? this.#core.data.overviewProfile(station, profile) : undefined;
    return { ...part, profiles: own === undefined ? [] : [own] };
  }

  /// An agent as its sidebar row lists it, with the connect its row came from.
  #rowAgent(station: string, key: string): J {
    const row: J = this.#core.data.chatForSession(station, key);
    const agent = arr(get(row, "agents")).find((a) => get(a, "key") === key);
    if (agent === undefined) return null;
    const out = structuredClone(agent);
    if (typeof get(row, "connect") === "string") out.connect = row.connect;
    return out;
  }

  /// Where a Slack or Feishu thread is, in words (placeName), and its link in Slack (while one of `agents`' Slack
  /// connects is signed in; `slackApp` into Slack's app) or in Feishu: none of them for a still.fail chat.
  /// (`connects`: its station's, where they were read; else its overview's)
  #whereIn(station: string, agents: J[], surface: string, channel: string, channelName: string, threadTs: string, connects?: J[], rawLinks?: unknown): { place: string | null; slackUrl: string | null; slackApp: string | null; feishuUrl: string | null; commaUrl: string | null; commaApp: string | null } {
    const strOf = (v: J, k: string) => str(get(v, k)) ?? "";
    const feishu = surface.startsWith("feishu:") || format.isFeishuChat(channel);
    // (a Comma Task is in no channel, and opens in no Slack: originOf's rule)
    const comma = surface.startsWith("comma:");
    const slack = !isOwnSurface(surface) && !feishu && !comma;
    const place = comma ? null : format.placeName(surface, channel, channelName);
    // A Feishu chat opens in Feishu (Lark's own app for its connect's).
    const feishuConnect = (connects ?? arr(get(this.#chatOverview(station), "connects"))).find((c) => `feishu:${strOf(c, "id")}` === surface);
    const feishuUrl = feishu ? format.feishuChatUrl(format.feishuApplink(str(get(get(feishuConnect, "feishu"), "domain"))), channel) : null;
    const commaLink = comma ? format.commaLinks(rawLinks) : { url: null, app: null };
    let workspaceUrl: string | null = null;
    let team = "";
    for (const a of agents) {
      const c = a.connect;
      if (strOf(c, "kind") !== "slack") continue;
      const conn = get(c, "connection");
      const state = get(conn, "state");
      if ((state === "connected" || state === "reconnecting") && typeof get(get(conn, "workspace"), "url") === "string") {
        workspaceUrl = conn.workspace.url;
        team = strOf(conn.workspace, "teamId");
        break;
      }
    }
    const slackUrl = slack && workspaceUrl !== null ? `${workspaceUrl}archives/${channel}/p${threadTs.replaceAll(".", "")}` : null;
    const slackApp = slackUrl !== null && team !== "" ? format.slackAppUrl(team, channel, threadTs, threadTs) : null;
    return { place, slackUrl, slackApp, feishuUrl, commaUrl: commaLink.url, commaApp: commaLink.app };
  }

  /// The page of an item whose agent has no chat yet.
  #unchatted(station: string, key: string): Value | undefined {
    const data = this.#core.data;
    const anchor = data.conversationOf(station, key);
    if (anchor === key && this.agent(station, key) === null) {
      const detail = this.value({ topic: "session", station, key });
      if (detail === undefined) return undefined;
      // (the station has no such session: the chat is not there, said so, whatever the station's words for it)
      const none = new CoreError("http_404", t("core-views.error.no_chat"), 404);
      return { err: "err" in detail && detail.err.status !== 404 ? detail.err : none };
    }
    const found = this.#row(station, { session: key });
    if (found === undefined && this.listKnown(station, "chats") === undefined) return undefined;
    const archivedFound = found === null ? data.chatNamed(station, anchor) : undefined;
    const row = found ?? archivedFound?.row;
    const agentKeys: string[] = [];
    const addKey = (k: unknown) => {
      if (typeof k === "string" && k !== "" && !agentKeys.includes(k)) agentKeys.push(k);
    };
    for (const a of arr(get(row, "agents"))) addKey(get(a, "key"));
    addKey(anchor);
    addKey(key);
    if (anchor !== key && this.agent(station, anchor) === null) {
      const anchorDetail = this.value({ topic: "session", station, key: anchor });
      if (anchorDetail === undefined) return undefined;
    }
    const agents: J[] = [];
    for (const k of agentKeys) {
      const a = this.agent(station, k);
      if (a !== null) agents.push(a);
    }
    if (agents.length === 0) {
      const detail = this.value({ topic: "session", station, key });
      if (detail === undefined) return undefined;
      const none = new CoreError("http_404", t("core-views.error.no_chat"), 404);
      return { err: "err" in detail && detail.err.status !== 404 ? detail.err : none };
    }
    if (row === undefined) {
      const threads = this.value({ topic: "threads", station });
      if (threads === undefined) return undefined;
      if ("err" in threads) return threads;
    }
    const archived = this.local.archivedChanging(station, null, anchor)
      ?? (anchor !== key ? this.local.archivedChanging(station, null, key) : null)
      ?? (archivedFound?.archived === true || agents.some((a) => get(a.session, "archivedAt") !== undefined && get(a.session, "archivedAt") !== null));
    // An agent (or merged conversation) that has only been in Slack: what was said there is all it has to show.
    const members_ = arr(get(this.ok({ topic: "workspace", workspace: ofAddress(station) }), "members"));
    const bots = agents.flatMap((a) => {
      const bot = a.connect !== undefined ? present.botOf(a.connect) : null;
      return bot === null ? [] : [bot];
    }).concat(this.#core.data.slackNames(station));
    const elsewhere = this.#sentElsewhere(station, null, agents, [], false, false, { members: members_, bots });
    // No chat at all, as their details say: none here, none in Slack (a Slack thread has no chat here either), not archived.
    const details = agentKeys.map((k) => this.value({ topic: "session", station, key: k }));
    const noChat = !archived && details.length > 0 && details.every((d) => d !== undefined && "ok" in d && arr(get(d.ok, "threads")).length === 0);
    // Where the Slack or Feishu thread it came from is (the row's origin), as a chat's page says its own.
    const origin = get(row, "origin");
    const strOf = (v: J, k: string) => str(get(v, k)) ?? "";
    const primaryConnect = agents.find((a) => isObject(a.connect))?.connect;
    const surface = isObject(origin) && isObject(primaryConnect) ? `${strOf(primaryConnect, "kind")}:${strOf(primaryConnect, "id")}` : "";
    const where = isObject(origin) ? this.#whereIn(station, agents, surface, strOf(origin, "channel"), strOf(origin, "channelName"), strOf(origin, "threadTs"), undefined, get(origin, "links")) : null;
    return {
      ok: {
        me: this.me(ofAddress(station)),
        thread: null,
        ...(where !== null && where.place !== null ? { place: where.place, slackUrl: where.slackUrl, ...(where.slackApp !== null ? { slackApp: where.slackApp } : {}) } : {}),
        ...(where !== null && where.feishuUrl !== null ? { feishuUrl: where.feishuUrl } : {}),
        ...(where !== null && where.commaUrl !== null ? { commaUrl: where.commaUrl } : {}),
        ...(where !== null && where.commaApp !== null ? { commaApp: where.commaApp } : {}),
        ...(noChat ? { noChat: true } : {}),
        title: row !== undefined && row.title !== undefined ? row.title : t("core-views.new_chat"),
        people: [],
        archived,
        agents,
        messages: [],
        elsewhere,
        more: false,
        outbox: [],
        link: this.link(station),
        offline: this.offline(station),
      },
    };
  }

  // ── an agent's history ──

  #history(station: string, key: string): Value | undefined {
    const live = this.value({ topic: "live", station, key });
    if (live === undefined || "err" in live) return live;
    const detail = this.ok({ topic: "session", station, key });
    const session = get(detail, "session") ?? null;
    const threads = arr(get(detail, "threads"));
    const overview = this.ok({ topic: "overview", station });
    const connect = find(get(overview, "connects"), get(session, "connect"));
    const connection = get(connect, "connection");
    const state = get(connection, "state");
    const signedIn = state === "connected" || state === "reconnecting";
    const botUserId = signedIn ? str(get(connection, "botUserId")) : null;
    const botName = str(get(connect, "name")) ?? str(get(session, "connect")) ?? "";
    const slackUsers = arr(get(overview, "slackUsers")).filter((u): u is string => typeof u === "string");
    const members_ = arr(get(this.ok({ topic: "workspace", workspace: ofAddress(station) }), "members"));
    const workspaces = slackWorkspaces(overview);
    const now = this.#core.host.nowMs();
    const md = this.#core.data.mdStore(station, `s:${key}`);
    return {
      // What its calls used, from its stream while it works, else from its summary (brief.ts `usageNow`).
      ok: presentHistory({ ...(live.ok as object), usage: brief.usageNow(session, live.ok) }, {
        workspaces,
        threads,
        members: members_,
        slackUsers,
        botUserId,
        botName,
        slackNames: this.#core.data.slackNames(station),
        runtime: str(get(session, "runtime")) ?? "claude",
        started: typeof get(session, "runtimeSessionId") === "string",
        offsetMin: this.#core.host.utcOffsetMin(now),
        now,
        stations: this.stationNames(ofAddress(station)),
        chatTitle: (link) => this.chatTitleOfLink(link, station),
        turnOpen: isObject(get(session, "lastTurn")) && typeof get(get(session, "lastTurn"), "endedAt") !== "number",
        ...(md !== undefined ? { md } : {}),
      }),
    };
  }

  // ── workspace marks ──

  #marksSources(): Topic[] {
    const topics: Topic[] = [{ topic: "workspaces" }, { topic: "prefs" }];
    for (const id of marks.workspaceIds(this.ok({ topic: "workspaces" }))) {
      topics.push({ topic: "workspace", workspace: id });
      for (const s of this.stations(id) ?? []) {
        topics.push({ topic: "link", station: s.address });
        if (s.online) topics.push({ topic: "chatRows", station: s.address });
      }
    }
    return topics;
  }
}

/// When each pinned list row was pinned (the rows say only `pinned: true`).
const pinnedAt = new WeakMap<object, number>();

/// `value` put through shape `ty` once, as it would go out, and marked so (`shaped`: shared, never changed, not copied or
/// shaped again where it goes out inside another value as `ty`; where another struct is said there, made as that one,
/// once: conform.ts `reshaped`); null when it does not fit (the station's row says so).
/// An overview of nothing but its shape's defaults (conform.ts `defaultOf`), made once: what a part of one is put
/// through the overview's shape with (#stationShownOf `profile`).
let overviewDefaultsMade: J = null;
function overviewDefaults(): J {
  overviewDefaultsMade ??= sharedValue(defaultOf("Overview"));
  return overviewDefaultsMade;
}

function asShaped(ty: string, value: J): J {
  const out = conformTy(ty, value);
  if (!("ok" in out) || out.ok === null || typeof out.ok !== "object") return null;
  shaped.add(sharedValue(out.ok));
  shapedAs.set(out.ok, ty);
  return out.ok;
}

/// What a chat's page draws by each message, decided here so the page only draws it: the chats it
/// links to (`linked`: each its title and whether it is archived), whether the
/// agent who said it is one of the chat's (its name opens its history), whose workspace keeps each of its files (and the
/// outbox's) and which of them went up from here after it was sent (`uploadOf`: their pictures are still here), which of an agent's files its text places (placed.ts), and what its
/// agents sent to Slack or were given there after it (`elsewhere`; the chat's own `elsewhere` keeps what came before
/// its first message), and which of the viewer's go close together with their next one, its time under that one (`followed`, `joined`).
/// `held`: whether a file's picture (an image's thumbnail, a video's still) is kept on the device, by its owner and
/// name (`held: true` on it: the app's first page waits for it as for the rest of what it shows, a decode away).
/// Whether a message's or an entry's words may link to a chat, kept with it (its words looked through once, not on
/// each change of its chat: 50 replies' words read through on each, 2026-11-08).
const linking = new WeakMap<object, boolean>();
function mayLink(m: J): boolean {
  if (!isObject(m)) return false;
  let may = linking.get(m);
  if (may === undefined) {
    const text = str(m.text) ?? "";
    linking.set(m, (may = text.includes("/chats/") || text.includes("/o/")));
  }
  return may;
}

/// A message as drawn (`drawn`), by the message shown: what it was drawn with (its files as drawn and what each was drawn
/// with, `drawn` fileParts; the chats it links to; who it is by, and whether that is one of the chat's agents; its words
/// as read), and how.
const drawnMade = new WeakMap<object, { files: J; fileParts: unknown[] | null; chats: J[]; by: J; byHere: boolean; tree: unknown; out: J }>();
/// A message that links to no chat (never drawn: `chats` goes out only where it has some).
const NO_CHATS: J[] = Object.freeze([]) as unknown as J[];

/// Whether a message's files are drawn with what they were (`drawn` fileParts): each of the same, by reference.
function sameParts(a: unknown[] | null, b: unknown[] | null): boolean {
  if (a === null || b === null) return a === b;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function drawn<V extends Value | undefined>(out: V, uploadOf: (path: unknown) => string | undefined, md?: MdStore, linked?: (text: string) => J[], held?: (session: string, name: string) => boolean): V {
  if (out === undefined || !("ok" in out) || !isObject(out.ok)) return out;
  // Everything said here goes on copies: what the view is made of may be the core's kept values, frozen (a message's
  // files, the outbox's), and writing on one of them threw and took the core down.
  const view = { ...(out.ok as J) };
  const agents = arr(view.agents);
  const keys = new Set(agents.map((a) => str(get(a.session, "key"))).filter((k): k is string => k !== null));
  // An agent's message's files are its own session's even when the chat's agents leave it out (its detail not had):
  // asked of another agent's session they answered 404, shown as 暂时无法预览 for good (左子健, 2026-11-08).
  const owner = (path: unknown, author: string | null) => {
    const by = typeof path === "string" ? agents.find((a) => path.startsWith(`${str(get(a.session, "workspace")) ?? "\0"}/`)) : undefined;
    return str(get(by?.session, "key")) ?? author ?? str(get(agents[0]?.session, "key"));
  };
  // What each of a message's files is drawn with, three a file: whose workspace keeps it, its upload here and whether its
  // picture is kept (null: not a list of files).
  const fileParts = (files: unknown, author: string | null): unknown[] | null => {
    if (!Array.isArray(files)) return null;
    const parts: unknown[] = [];
    for (const f of files) {
      if (!isObject(f)) {
        parts.push(null, undefined, false);
        continue;
      }
      const key = owner(get(f, "path"), author);
      // One sent from here before it was up: its picture is still here, under its upload's id.
      const upload = uploadOf(get(f, "path"));
      const path = str(get(f, "path")) ?? "";
      const kept = key !== null && held !== undefined && path !== "" && held(key, path.slice(path.lastIndexOf("/") + 1));
      parts.push(key, upload, kept);
    }
    return parts;
  };
  const ownOf = (files: unknown, parts: unknown[] | null): J => {
    if (parts === null || !Array.isArray(files)) return files;
    return files.map((f, i) => {
      if (!isObject(f)) return f;
      const key = parts[i * 3] as string | null;
      const upload = parts[i * 3 + 1] as string | undefined;
      const kept = parts[i * 3 + 2] === true;
      return key !== null || upload !== undefined ? { ...f, ...(key !== null ? { owner: key } : {}), ...(upload !== undefined ? { upload } : {}), ...(kept ? { held: true } : {}) } : f;
    });
  };
  const own = (files: unknown, author: string | null = null): J => ownOf(files, fileParts(files, author));
  const here = (by: J): J => {
    const agent = str(get(by, "agent"));
    return agent !== null && keys.has(agent) ? { ...by, here: true } : by;
  };
  // The words read as Markdown that are not read here this run: their trees read of the device at once, in one
  // statement (data.ts `mdStore`), not one a message as each is drawn; each text's key worked out once.
  const mdWords = (m: J): string | null => (isObject(m.notice) ? (str(m.notice.words) ?? "") : m.authorKind === "person" ? null : (str(m.text) ?? ""));
  const keyed = new Map<string, string>();
  if (md?.preload !== undefined) {
    for (const m of arr(view.messages)) {
      const text = isObject(m) ? mdWords(m) : null;
      if (text !== null && !keyed.has(text) && !markdownHere(text)) keyed.set(text, mdKey(text));
    }
    if (keyed.size > 0) md.preload([...keyed.values()]);
  }
  const messages: J[] = arr(view.messages).map((m) => {
    if (!isObject(m)) return m;
    // Drawn before (`was`, by the message, the same object while it does not change): what it is drawn with that is as
    // it was is what it was drawn with then, not made again, so that it is known the same by its reference (a file's
    // copy, its links, who it is by): one change of a chat made every message's anew and walked them all to find them
    // equal (13-22 ms of a chat drawn, its Markdown read already, 2026-11-18).
    const was = drawnMade.get(m);
    const parts = fileParts(m.attachments, m.authorKind === "agent" ? str(m.author) : null);
    const files = was !== undefined && sameParts(was.fileParts, parts) ? was.files : ownOf(m.attachments, parts);
    // The chats it links to, each with its title (one linked bare reads as it) and whether it is archived.
    const linking = linked !== undefined && mayLink(m) ? linked(str(m.text) ?? "") : NO_CHATS;
    const chats = was !== undefined && (linking.length === 0 ? was.chats.length === 0 : equal(was.chats, linking)) ? was.chats : linking;
    const agent = str(get(m.by, "agent"));
    const byHere = agent !== null && keys.has(agent);
    const by = was !== undefined && was.byHere === byHere ? was.by : byHere ? { ...(m.by as J), here: true } : m.by;
    // A person's words are drawn as they wrote them and place nothing: their files are all below them. An agent's are
    // Markdown, read here (once: markdown.ts keeps it by the words; read again as its reader changes); still.fail's
    // notice's are too, as its pill says them (noticeOf: a chat it opened is a link to it).
    const words = mdWords(m);
    const tree = words === null ? null : markdown(words, md, keyed.get(words));
    // Drawn as before while what it is drawn with is (its files, its links, who it is by, its words as read): the
    // same object.
    if (was !== undefined && ((was.files === files && was.chats === chats && was.by === by && was.tree === tree) || equal([was.files, was.chats, was.by, was.tree], [files, chats, by, tree]))) return was.out;
    const out: J = { ...m, by, attachments: files };
    if (chats.length > 0) out.chats = chats;
    if (isObject(m.notice)) out.notice = { ...m.notice, md: tree };
    else if (m.authorKind === "person") out.words = personWords(str(m.text) ?? "");
    else {
      out.md = tree;
      if (Array.isArray(files) && files.length > 0) {
        const { placed } = placeFiles(str(m.text) ?? "", files as J[]);
        if (placed.size > 0) out.placed = [...placed.keys()];
      }
    }
    drawnMade.set(m, { files, fileParts: parts, chats, by, byHere, tree, out: sharedValue(out) });
    return out;
  });
  view.messages = messages;
  if (Array.isArray(view.outbox)) view.outbox = view.outbox.map((o: J) => (isObject(o) ? goingUp({ ...o, attachments: own(o.attachments), ...(typeof o.text === "string" && o.text !== "" ? { words: personWords(o.text) } : {}) }) : o));
  const elsewhere = arr(view.elsewhere);
  if (elsewhere.length > 0) {
    // (a folded notice's last seq too: what was sent after its last is after it)
    const bySeq = new Map(messages.flatMap((m, i) => [[u64(m.seq), i] as const, [endSeq(m), i] as const]));
    const first: J[] = [];
    const after = new Map<number, J[]>();
    for (const item of elsewhere) {
      const s = isObject(item) ? { ...item, by: here(item.by) } : item;
      // Before the first message (0), or after one shown; after one outside the window, not shown with it.
      const at = bySeq.get(u64(s.after));
      if (u64(s.after) === 0) first.push(s);
      else if (at !== undefined) after.set(at, [...(after.get(at) ?? []), s]);
    }
    // (on copies: a message drawn is kept as it was drawn, for the next time)
    for (const [i, items] of after) messages[i] = { ...messages[i], elsewhere: [...(messages[i].elsewhere ?? []), ...items] };
    view.elsewhere = first;
  }
  // The viewer's messages sent one after another, in their bubbles: close together, the time only under the last of
  // them, while each one's is within FOLLOWED_MS of the time shown under a later one (nothing else between them: no
  // one else's, nothing sent to Slack). Those still on their way count; one not sent stands apart.
  const outbox = view.newer === true ? [] : arr(view.outbox);
  const all: J[] = [...messages, ...outbox];
  // What is sent from here would follow the last of them (the viewer's own, nothing sent to Slack after it) until
  // FOLLOWED_MS past its time: the page lays its words out so the frame they are sent, before their row is here (that
  // row come late, the list went up further than it ends and back, 2026-11-10).
  const last = all[all.length - 1];
  if (view.newer !== true && last !== undefined && last.elsewhere === undefined && (all.length > messages.length ? last.state !== "failed" : last.mine === true)) {
    const at = u64(last.createdAt);
    if (at !== null) view.joinsUntil = at + FOLLOWED_MS;
  }
  const followed = new Set<number>();
  let shownAt: number | null = null;
  for (let i = all.length - 1; i >= 0; i--) {
    const m = all[i];
    const at = u64(m.createdAt);
    const mine = i >= messages.length ? m.state !== "failed" : m.mine === true;
    if (!mine || at === null) { shownAt = null; continue; }
    if (shownAt !== null && m.elsewhere === undefined && shownAt - at <= FOLLOWED_MS) followed.add(i);
    else shownAt = at;
  }
  if (followed.size > 0) {
    const marked = all.map((m, i) => (followed.has(i) || followed.has(i - 1) ? { ...m, ...(followed.has(i) ? { followed: true } : {}), ...(followed.has(i - 1) ? { joined: true } : {}) } : m));
    view.messages = marked.slice(0, messages.length);
    if (outbox.length > 0) view.outbox = marked.slice(messages.length);
  }
  return { ...out, ok: view } as V;
}

/// An outgoing message's files still going up (`uploads`) as its row draws them: an image or a video among its files at
/// once, in its place and shape, drawn from the picture this device has of it (`upload`; on no station yet, its path
/// names the upload), as its message draws it once up, not a card that turns into it then; any other a card saying how
/// far, as it is a card once up. While any goes up, 正在上传 under it (`waits`), unless something else holds it, and how far all
/// of them together are (`progress`, 正在上传 42%) once each says how much of it the station has (a station's file
/// copied across says nothing until it is there). Every byte gone and its station not yet saying it has them all (its
/// answer can take seconds more), 等待 station 确认收到, not 100% (it read as stuck, zuozijian 2026-11-09).
function goingUp(o: J): J {
  const { uploads, ...rest } = o as Record<string, unknown>;
  const going = arr(uploads).filter((u) => isObject(u));
  if (going.length === 0) return rest;
  const pictured = going.filter((u) => isImage(str(u.name) ?? "") || isVideo(str(u.name) ?? ""));
  const shown = pictured.map((u) => ({ name: u.name, path: `upload:${u.id}`, size: u.size, ...(u.width && u.height ? { width: u.width, height: u.height } : {}), upload: u.id }));
  const cards = going.filter((u) => !pictured.includes(u));
  const size = going.reduce((n, u) => n + (u64(u.size) ?? 0), 0);
  const told = going.every((u) => u64(u.sent) !== null) && size > 0;
  const progress = told ? Math.min(going.reduce((n, u) => n + u64(u.sent)!, 0) / size, 1) : null;
  return {
    ...rest,
    attachments: [...arr(o.attachments), ...shown],
    ...(cards.length > 0 ? { uploads: cards } : {}),
    ...(o.state === "sending" && typeof o.waits !== "string"
      ? progress === null ? { waits: t("common.uploading") }
        : progress >= 1 ? { waits: t("common.uploadConfirming"), progress }
        : { waits: t("core-views.outbox.uploading", { percent: Math.floor(progress * 100) }), progress }
      : {}),
  };
}

/// How far apart the viewer's messages sent one after another still go together, one time under the last.
const FOLLOWED_MS = 5 * 60_000;

/// How long a station up may go without a host reading before it is said to be silent.
const SILENT_MS = 15_000;

/// How a station is in a few words, as its page's head and its card say it: down for a security
/// mode, its line; away, when it was last online (or never); up, connecting until its overview is read, then its
/// agents at work (`busy`) or idle.
export function stationState(online: boolean, saysWhy: boolean, summary: string, lastSeen: number | null, read: boolean, running: number, c: present.Clock): { stateText: string; stateBusy: boolean } {
  if (!online && saysWhy) return { stateText: summary, stateBusy: false };
  if (!online) {
    return { stateText: lastSeen !== null ? t("core-views.station.last_online", { time: format.relativeTime(lastSeen * 1000, c.now, c.offsetMin) }) : t("core-views.station.never_online"), stateBusy: false };
  }
  if (!read) return { stateText: t("core-views.station.connecting"), stateBusy: false };
  return running > 0 ? { stateText: t("core-views.station.running_agents", { n: running }), stateBusy: true } : { stateText: t("core-views.station.idle"), stateBusy: false };
}

/// What may be wrong with a station, each in words, worst first: silent though up, down for
/// a security mode (why), away (red once it has been online, else amber: never connected). Up and saying what this core
/// cannot read comes first: it explains the rest.
export function stationProblems(online: boolean, silent: boolean, blocked: string | null, seen: boolean, updating = false, unreadable = false, cause: string | null = null): { key: string; level: string; text: string }[] {
  if (online && unreadable) return [{ key: "incompatible", level: "amber", text: t("core-views.station.incompatible", { name: brand.name() }) }];
  if (online && silent) return [{ key: "silent", level: "amber", text: t("core-views.station.silent", { name: brand.name() }) }];
  if (!online && blocked !== null) return [{ key: "blocked", level: "red", text: blocked }];
  // Gone for its update: back by itself once it is done.
  if (!online && updating) return [{ key: "updating", level: "amber", text: t("core-views.station.updating_back") }];
  if (!online) {
    if (cause === "network") return [{ key: "away", level: "red", text: t("core-views.station.away_network", { name: brand.name() }) }];
    if (cause === "unreached") return [{ key: "away", level: "red", text: t("core-views.station.away_unreached", { name: brand.name() }) }];
    return [{ key: "away", level: seen ? "red" : "amber", text: seen ? t("core-views.station.away", { name: brand.name() }) : t("core-views.station.never_connected", { name: brand.name() }) }];
  }
  return [];
}

function clockSeconds(ms: number, offsetMin: number): string {
  const [, , , , h, m] = format.local(ms, offsetMin);
  const s = ((Math.floor(ms / 1000) % 60) + 60) % 60;
  const two = (n: number) => String(n).padStart(2, "0");
  return `${two(h)}:${two(m)}:${two(s)}`;
}

/// Builds a bounded `StationDiag` value from local link, mesh, cached net and workspace info.
export function stationDiagView(input: {
  station: string;
  id: string;
  name: string;
  version: string | null;
  lastSeenSec: number | null;
  link: J;
  linkDiag: LinkDiag | null;
  peerDiag: PeerDiag | null;
  net: J | null;
  cloudDown: boolean;
  clock: present.Clock;
  relayName: (host: string) => string | null;
}): J {
  const { id, name, version, lastSeenSec, link, linkDiag, peerDiag, net, cloudDown, clock, relayName } = input;
  const linkState = str(get(link, "state")) ?? "connecting";
  const linkCause = str(get(link, "cause"));
  const isDown = down(link);
  let cause: string;
  if (isDown) {
    if (linkCause === "network" || linkCause === "unreached" || linkCause === "station" || linkCause === "lock" || linkCause === "updating") cause = linkCause;
    else cause = cloudDown ? "network" : "station";
  } else if (linkState === "error") {
    cause = "error";
  } else {
    cause = "silent";
  }
  const summary = t(`core-views.station.diag.summary.${cause}`, { name: brand.name() });
  const msg = str(get(link, "message"));
  const detail = msg !== null && msg !== "" ? msg : (linkDiag?.lastEnd ?? null);
  const lastOnlineMs = lastSeenSec !== null ? lastSeenSec * 1000 : (linkDiag?.downAt ?? null);
  const lastOnlineText =
    lastOnlineMs !== null
      ? t("core-views.station.diag.last_online", {
          ago: format.relativeTime(lastOnlineMs, clock.now, clock.offsetMin),
          clock: format.clock(lastOnlineMs, clock.offsetMin),
        })
      : null;
  const cloudStatus = cloudDown ? t("core-views.station.diag.cloud_down") : t("core-views.station.diag.cloud_ok");
  let retryText: string | null = null;
  if (linkDiag !== null && linkDiag.misses > 0) {
    if (linkDiag.retryAt !== null) {
      const time = clockSeconds(linkDiag.retryAt, clock.offsetMin);
      retryText = linkDiag.slowBackoff
        ? t("core-views.station.diag.retry_slow", { n: linkDiag.misses, time })
        : t("core-views.station.diag.retry_at", { n: linkDiag.misses, time });
    } else {
      retryText = t("core-views.station.diag.retry_misses", { n: linkDiag.misses });
    }
  }
  const lastNetPath = str(get(net, "path"));
  const lastNetRtt = str(get(get(net, "rtt"), "text"));
  const lastNetText = lastNetPath !== null && lastNetPath !== "" ? (lastNetRtt !== null && lastNetRtt !== "" ? `${lastNetPath} · ${lastNetRtt}` : lastNetPath) : null;
  const seenAddr = new Set<string>();
  const addresses: string[] = [];
  for (const a of [...(peerDiag?.lan ?? []), ...(peerDiag?.tailnet ?? [])]) {
    if (typeof a === "string" && a !== "" && !seenAddr.has(a)) {
      seenAddr.add(a);
      addresses.push(a);
      if (addresses.length >= 8) break;
    }
  }
  const wayName = (via: string): string => {
    if (via === "main") return t("core-views.station.diag.way.main");
    if (via === "main+addresses") return t("core-views.station.diag.way.main_addresses");
    if (via === "lan") return t("core-views.station.diag.way.lan");
    if (via === "tailnet") return t("core-views.station.diag.way.tailnet");
    if (via === "fenced") return t("core-views.station.diag.way.fenced");
    if (via.startsWith("relay:")) {
      const host = via.slice(6);
      return relayName(host) ?? host;
    }
    return via;
  };
  const ways: { name: string; status: string; resultText: string }[] = [];
  if (peerDiag !== null && peerDiag.attempts.length > 0) {
    for (const a of peerDiag.attempts.slice(0, 12)) {
      const status = a.outcome === "ok" ? "ok" : a.outcome === "no_answer" ? "timeout" : a.outcome === "refused" ? "refused" : a.outcome === "interrupted" ? "down" : "error";
      const stage = t(`core-views.station.diag.stage.${a.stage}`);
      const ms = format.duration(a.totalMs);
      const base = t(`core-views.station.diag.outcome.${a.outcome}`, { stage, ms });
      const resultText = a.error && (a.outcome === "error" || a.outcome === "refused") ? `${base} · ${a.error}` : base;
      ways.push({ name: wayName(a.via), status, resultText });
    }
  } else if (peerDiag !== null && peerDiag.relays.length > 0) {
    for (const r of peerDiag.relays.slice(0, 12)) {
      const host = relayHost(r.url);
      ways.push({
        name: relayName(host) ?? host,
        status: r.connected ? "ok" : "down",
        resultText: r.connected ? t("core-views.station.diag.relay_up") : t("core-views.station.diag.relay_down"),
      });
    }
  }
  const lines: string[] = [
    `Station: ${name} (${id})${version ? ` v${version}` : ""}`,
    `Cause: ${cause} — ${summary}`,
    `Cloud: ${cloudStatus}`,
  ];
  if (lastOnlineText !== null) lines.push(`Last online: ${lastOnlineText}`);
  if (lastNetText !== null) lines.push(`Last route: ${lastNetText}`);
  if (addresses.length > 0) lines.push(`Addresses: ${addresses.join(", ")}`);
  if (retryText !== null) lines.push(`Retry: ${retryText}`);
  if (detail !== null) lines.push(`Detail: ${detail}`);
  if (ways.length > 0) {
    lines.push("Routes:");
    for (const w of ways) lines.push(`  - [${w.status}] ${w.name}: ${w.resultText}`);
  }
  return {
    cause,
    summary,
    detail,
    lastOnlineText,
    cloudStatus,
    retryText,
    lastNetText,
    addresses,
    ways,
    copyText: lines.join("\n"),
  };
}


/// The chat's agents (`agents`), each whose card was answered from here at work (queued) from the moment the answer
/// is sent: while the answer is on its way (`outbox`: one quoting the card, or any under it as the chat's last word),
/// and once it is here (`messages`, the viewer's last) till a turn of the agent's begins after it, as its station says
/// once it has taken the answer. So its activity comes in with the answer, the card folding and the answer coming on
/// one way of the list, not a moment after as the station tells it (the user, 2026-11-09: 「点选项时「处理中」立刻出来」).
export function answeredAt(agents: J[], messages: J[], outbox: J[]): J[] {
  const cardBy = (m: J | undefined): string | null => (m !== undefined && isObject(m.card) ? str(get(m.by, "agent")) : null);
  const cards = new Map<string, string>();
  for (const m of messages) {
    const by = cardBy(m);
    if (by !== null && typeof m.ts === "string") cards.set(m.ts, by);
  }
  if (cards.size === 0) return agents;
  const said = messages.filter((m) => m.system !== true);
  const quoted = (m: J): string[] => arr(m.quotes).flatMap((q) => {
    const by = get(q, "role") === "agent" && typeof get(q, "ts") === "string" ? cards.get(q.ts) : undefined;
    return by === undefined ? [] : [by];
  });
  const waiting = new Map<string, number>();
  for (const m of outbox) {
    if (m.state === "failed") continue;
    const under = cardBy(said[said.length - 1]);
    for (const by of [...quoted(m), ...(under !== null ? [under] : [])]) waiting.set(by, Infinity);
  }
  const last = said[said.length - 1];
  if (last !== undefined && last.mine === true) {
    const under = cardBy(said[said.length - 2]);
    for (const by of [...quoted(last), ...(under !== null ? [under] : [])]) if (!waiting.has(by)) waiting.set(by, u64(last.createdAt) ?? 0);
  }
  if (waiting.size === 0) return agents;
  return agents.map((a) => {
    const key = str(get(a.session, "key"));
    const since = key !== null ? waiting.get(key) : undefined;
    if (since === undefined || a.status === "running" || a.status === "queued") return a;
    // Once the station has reported a failed start for the delivered answer, it is no longer at work on it.
    // A new answer still in the outbox can begin another attempt, so it retains the immediate queued state.
    if (since !== Infinity && a.status === "failed" && get(a.session, "startFailed") === true && (u64(get(a.session, "pending")) ?? 0) > 0) return a;
    const began = u64(get(get(a.session, "lastTurn"), "startedAt"));
    return began !== null && began >= since ? a : { ...a, status: "queued" };
  });
}
