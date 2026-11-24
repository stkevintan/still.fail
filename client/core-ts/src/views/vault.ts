// The vault on this device: the vaults and items a workspace's stations hold, kept here as they do
// (only ciphertext and signatures), what the pages show of them, and what a person does with them. Keys live in the
// system's secure storage (Host `secureGet`…: an app's; a web page has none and is refused); a vault's key, once
// unsealed, is kept in memory UNLOCK_MS. Nothing a station or the cloud says is trusted for a key: a vault's version
// counts once its owner's device signed it and a box key once its device did, both checked against the workspace's
// lock, itself checked entry by entry here (vault/lock-check.ts).
//
// What this device signs is kept here first (its SQLite, ciphertext only) and is the person's own copy: every station of
// the workspace keeps a backup of each vault (its ciphertext and signatures, never a key or the recovery words), so that
// an agent on any of them may ask for its secrets. A vault is written on its host (`at`, the station it is on), and the
// latest version held anywhere is brought to each station that lacks it (`spread`, `?copy=1`), as it is read or written
// here. Where no station can take a write now (none in the workspace, none online, none holding vaults yet:
// `localFallback`), it is kept here alone and brought to each as it is next read (`readStation`, `spreadAll`); a
// station's refusal by the rules (a conflict, an invalid version) still fails the write.
//
// Topics:
//   vaults {workspace}            the vaults this person is in, whether this device is set up, requests to approve
//   vaultItems {workspace, vault} a vault's items: names once it is unlocked (the listed ones' always)
//   vaultUses {workspace, vault, item}  an item's uses by agents (the requests decided), the latest first
//   (`lockPrompts` `asks`, views/lock.ts: members' devices set up that wait on this one for a vault's key, every
//   workspace's, wherever the person is: `vault.addDevice {vault, device}` gives it, `vault.hidePrompt` puts one away
//   until that device asks again; `vaultAsks` here)
//
// Without security mode the library is plain ( 不加锁的库): each station keeps the person's items as they
// are (`vault/plain`), shown as one vault, `plain`; the calls below take it as they take a vault, with nothing to
// encrypt, sign or ask the person for. Security mode on, what is left of it is moved into their vault (`migrate`).
// Calls (vault.<name> {workspace, …}):
//   setup                         this device's box key (made once), its certificate published; the recovery words
//                                 the first time (`{words}`, shown once: never kept); one's own vault made when one
//                                 has none (`{made}`)
//   create {name, station?}       a vault of one's own, keyed for each of one's devices set up
//   delete {vault}                a vault of one's own deleted, its items with it (the person asked when it holds any)
//   addDevice {vault, device?}    the vault's key sealed for members' devices set up since (its owner signs; done by
//                                 itself too whenever the owner's device unseals it, and as their certificates come
//                                 while it is unsealed here)
//   ask                           this device's certificate published anew (set up already): the owner's devices
//                                 prompted for its key (`lockPrompts` `asks`), or given it at once where one holds it
//   hidePrompt {device, at?}      that device's prompt put away (the one shown, its certificate's `at`), until it
//                                 asks again
//   prompts                       the devices waiting on this one for a key (`lockPrompts` `asks`), as a call
//   putItem {vault, id?, plain, listing?}  an item written (a new one without `id`)
//   deleteItem {vault, item}      an item deleted
//   open {item}                   an item's plaintext (asks the person, unless its vault is unlocked)
//   recover {words}               this device keyed into one's vaults by the recovery words
//   approve {request, scope, typed?}  an agent's request granted: the item sealed to it, signed; a request to keep a
//                                 secret (secret_save) approved: written into one's vault (`scope` unused); one the
//                                 person types in, with what they typed (`typed: {secret, username?}`, an object: never
//                                 kept among what is `doing`)
//   setLasts {vault, lasts}       the longest grant of the vault's items that say none (its owner signs; the plain
//                                 library's told to each station keeping it)
//   deny {request}                turned down, signed
//   migrate                       the plain library's items moved into one's own vault, encrypted (security mode on)
//   oauthBegin {vault, provider, back, request?}  a service's sign-in page (`{url}`) for the person to sign in to it as
//                                 themselves, coming back to `back` (vault/oauth.ts); for an agent's request to keep
//                                 one (secret_save `oauth`), its card approved with the token as it comes
//   oauthComplete {query}         what the browser came back with: their token written into `vault` (`{name}`)
//   lock                          the unlocked keys forgotten now
//   state                         the `vaults` topic's value, as a call
import { Effect, Option, Semaphore } from "effect";
import type { Inner } from "../core.ts";
import { ulid } from "../accounts.ts";
import { handlers } from "../core/execute.ts";
import type { Call } from "../core/calls.ts";
import type { Owner } from "../core/routing.ts";
import { CoreError, asCoreError } from "../error.ts";
import { t } from "../i18n.ts";
import { type Entry, Signer, entryHash } from "../lock.ts";
import { OTHERS_MS, answersOf, askPerson, baseOf, tookOrRefused, deviceText, deviceVerifyCode, held as lockHeld, inForceOf, leftIn, lockSeen, movedHere, onBoundPerson, view as workspaceView, nameOf as workspaceName, signerKnown, signerOf, stateOf } from "./lock.ts";
import { checkChain, crypto as personCrypto } from "../personal-lock.ts";
import * as prefs from "../prefs.ts";
import { workspaceIds } from "./marks.ts";
import type { Topic } from "../protocol.ts";
import { StationAddr } from "../station/addr.ts";
import { Priority } from "../sync/scheduler.ts";
import type { SpanContext } from "../trace.ts";
import { get, isObject, utf8 } from "../util.ts";
import {
  type BoxCert, type BrowseAnswer, type CrossListing, type Deny, type Grant, type Item, type Listing, type Plain, type Request, type Save, type Scope, type Vault,
  SCOPES, TAG, allows, boxPublic, decrypt, encryptWith, fromWords, grantContext, itemContext, keyContext, openSeal, recoveryPair, saveContext, rulesCrypto, sealWith, sign, toWords,
} from "../vault/crypto.ts";
// @ts-ignore: the MoonBit build's JS, untyped
import * as rules from "../../../../rules/js/rules.js";
import { type Checked, type Device as LockDevice, checkLock } from "../vault/lock-check.ts";
import * as oauth from "../vault/oauth.ts";
import { ofAddress } from "../workspace.ts";
import { stamp } from "../present.ts";
import type { VaultOutcome } from "./local.ts";
import { aboutText, describeText, fileBytes, howText, itemWords, kindText, modeText, shownFields, statusWords } from "../vault-words.ts";
import { timed } from "../spent.ts";

// deno-lint-ignore no-explicit-any
type J = any;
type Of = Extract<Call, { kind: "vault" }>;

/// How long a vault's key stays unsealed in memory after it was last unsealed.
export const UNLOCK_MS = 5 * 60_000;
/// How long a write by the owner's device waits for its vault to be keyed anew first (`#writable`).
const REKEY_WAIT_MS = 1_500;
/// How long a vault's or item's write waits on one station, where another holds the vault too, before trying the next.
const WRITE_TRY_MS = 3_000;
/// The secure storage's box key (X25519, asks the person to be read), and its public half where the app keeps the
/// rest (no asking needed to know it).
export const BOX_KEY = "vault-box";
export const BOX_PUB = "vault-box-pub";
/// How long a grant lasts: one use or an hour; a chat's until the chat is archived, which the station ends it at (30
/// days at most).
const GRANT_SECS: Record<Scope, number> = { once: 3600, hour: 3600, chat: 30 * 86400 };

/// What the workspace's stations hold, as held here (the `vault` record of the workspace): the vaults by id and the
/// station each is on, the box certificates by device, the requests waiting and the station each came from, and the
/// stations that hold no vault (a code: `vault_needs_lock`, `http_404` for one from before).
type Held = {
  vaults: Record<string, Vault>; at: Record<string, string>; boxes: Record<string, BoxCert>; requests: Record<string, Request>; asked: Record<string, string>; refused: Record<string, string>;
  /// What each station holds of each vault (by vault, then station): its version and its items' (by id); the stations
  /// that answered what vaults they hold (those a copy may be brought to).
  on: Record<string, Record<string, Holding>>; keeps: string[];
  /// The plain library's items by id (without their fields) and the station each is on; the stations that keep one;
  /// the longest grant of its items that say none, as said last on any of them.
  plain: Record<string, PlainRow>; plainOn: string[]; plainLasts?: { lasts: Scope; at: number };
  /// The uses of each vault's items (`<station>/<vault>`), as the station keeping it said them, the latest first.
  uses: Record<string, Use[]>;
  /// The devices whose prompt for a key was put away here (`vault.hidePrompt`), by device: the certificate's `at` it
  /// was put away at (one published since, asking again, is shown).
  hidden: Record<string, number>;
  /// A later version of a vault a station told than the one held, that the lock as held here does not take yet, by
  /// vault: this device's lock behind the station's (a device let in again, given the key in the version written for it
  /// before it heard it was in the lock). Taken as the lock comes (`vaultCome`); nothing else would tell it again.
  later?: Record<string, Vault>;
  /// The last version held of a vault under each earlier key, by vault, then by epoch: what unseals an earlier key for
  /// this device (its `keys`), and what the lock took then, while items written under that key are left to be written
  /// again under the vault's (`carryOn`: a keying anew stopped half-way). Let go once nothing sits under it
  /// (`settleBefore`).
  before?: Record<string, Record<string, Vault>>;
  /// Non-safe-mode teammates' personal chains returned by `GET /vault/boxes` (folded & verified locally in
  /// `personalLockOf`; never replaces this person's own pinned personal lock).
  memberChains?: Record<string, Entry[]>;
  /// Non-safe-mode workspace member roles returned by `GET /vault/boxes`.
  memberRoles?: Record<string, string>;
  /// Cross-workspace personal secret uses recorded on each station of this workspace (by station id).
  crossUses?: Record<string, CrossUse[]>;
};

/// A vault's version a station holds, and its items' versions; the signatures of those (`sig`, `sigs`): which of two of
/// one number it holds (written on two stations at once), so the one every station keeps is brought where it is not.
type Holding = { seq: number; items: Record<string, number>; sig?: string; sigs?: Record<string, string> };

/// An item of the plain library as a station lists it (vault/plain.ts `shown`), and where it is.
type PlainRow = { id: string; owner: string; version: number; kind: string; name: string; notes: string; listing?: Listing; at: number; deleted?: true; station: string };
/// A use as a station says it (vault/secrets.ts `Use`).
type Use = { item: string; at: number; session: string; chatTitle: string | null; mode: string; command: string | null; hosts: string[]; denied: boolean };
/// A cross-workspace use as a station says it (GET /vault/cross-uses).
type CrossUse = { at: number; request: string; sourceWorkspace: string; sourceVault: string; item: string; session: string; chatTitle?: string; mode: string; command?: string; hosts: string[]; denied?: true };

/// The id the plain library goes by where a vault's would.
export const PLAIN = "plain";

/// This core's unsealed vault keys (by `<vault>/<epoch>`, until when), the lock as checked and the box key's public
/// half once known. The signing key's id is the lock's (`signerOf`), told as it is made, not read here once.
type Mem = {
  keys: Map<string, { key: Uint8Array; until: number }>; checked: Map<string, { at: string; lock: Checked | CoreError }>; box: string | null | undefined;
  /// Each vault's giving under way (one at a time); the version of each a station refused as no vault (not given
  /// again until it moves on).
  giving: Map<string, ReturnType<typeof Semaphore.makeUnsafe>>; refused: Map<string, number>;
  /// By workspace, the devices and members this device took out of its lock in this run at a person's asking
  /// (`tookOut`): a vault waiting to be keyed anew for one of them may read the box key to be keyed anew (`rekeyGone`).
  out: Map<string, Set<string>>;
  /// The box key made one at a time (`ensureBoxKey`): two workspaces, or 开启 and `autoBox` at once, never make two.
  boxInit: ReturnType<typeof Semaphore.makeUnsafe>;
  /// The workspaces whose `autoBox` runs now (one at a time each: a read, an event and the lock coming all set it going).
  autoBoxing: Set<string>;
  /// The workspaces whose stations `vaultCome` read for `autoBox`, nothing of the vaults held yet (once a run).
  cameRead: Set<string>;
  /// Other workspaces already refreshed in background by `browseCandidates` during this core run.
  browseRead: Set<string>;
};
const mems = new WeakMap<Inner, Mem>();
const mem = (inner: Inner): Mem => {
  let m = mems.get(inner);
  if (!m) mems.set(inner, (m = { keys: new Map(), checked: new Map(), box: undefined, giving: new Map(), refused: new Map(), out: new Map(), boxInit: Semaphore.makeUnsafe(1), autoBoxing: new Set(), cameRead: new Set(), browseRead: new Set() }));
  return m;
};

const EMPTY: Held = { vaults: {}, at: {}, boxes: {}, requests: {}, asked: {}, refused: {}, on: {}, keeps: [], plain: {}, plainOn: [], uses: {}, hidden: {} };
const arr = (v: unknown): J[] => (Array.isArray(v) ? v : []);
const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
const nowS = (inner: Inner) => Math.floor(inner.host.nowMs() / 1000);
const fail = (code: string, message: string) => Effect.fail(new CoreError(code, message));

/// A station write failure that means the station cannot back up this version now (offline, no link, 5xx, handing over,
/// old station 404, or lock not pinned there yet), as opposed to a protocol conflict (`vault_conflict`) or rules refusal
/// (`vault_invalid`, `vault_not_owner`, etc.): the device keeps what it signed locally and spreads it once a station can.
const localFallback = (e: CoreError) =>
  e.status === undefined || e.status >= 500 || e.status === 408 || e.status === 429 || e.status === 404 || e.code === "vault_needs_lock" || e.code === "vault_handover";

function held(inner: Inner, ws: string): Held {
  const h = inner.data.record("vault", ws);
  return isObject(h) ? { ...EMPTY, ...(h as Partial<Held>) } : EMPTY;
}

/// The held record changed by `change` (on a copy), and what shows it told.
function change(inner: Inner, ws: string, f: (h: Held) => void): void {
  const h = structuredClone(held(inner, ws)) as Held;
  f(h);
  inner.data.put("vault", ws, h);
  keepTook(inner, ws);
  changed(inner, ws);
}

function items(inner: Inner, ws: string, vault: string): Record<string, Item> {
  const v = inner.data.record("vaultItems", `${ws}/${vault}`);
  return isObject(v) ? (v as Record<string, Item>) : {};
}

function changeItems(inner: Inner, ws: string, vault: string, f: (items: Record<string, Item>) => void): void {
  const all = structuredClone(items(inner, ws, vault)) as Record<string, Item>;
  f(all);
  inner.data.put("vaultItems", `${ws}/${vault}`, all);
  changed(inner, ws);
}

function changed(inner: Inner, ws: string): void {
  lockSeen(inner).touch(`vault ${ws}`, "prompts");
  // (the requests' cards in the chats: shown again where how they are answered here changed)
  inner.views?.vaultChanged(ws);
}

const view = (inner: Inner, ws: string): J => inner.data.shared({ topic: "workspace", workspace: ws });
const stationsOf = (inner: Inner, ws: string): { id: string; name: string }[] => arr(get(view(inner, ws), "stations")).filter((s) => typeof s?.id === "string");

/// The workspace's lock as held here, checked (the same while its head does not move); an error says why it is none.
/// Where its chain moved, the state in force (views/lock.ts `inForceOf`, the same object while what it is made of
/// stands), as a station's vaults go by it (station/src/cloud/state.ts `Cloud.locked`): while it waits for the root's
/// log or its `open`, a state that names nobody (no vault shown, no key given, nobody asked), as a station's then.
function lockOf(inner: Inner, ws: string): Checked | CoreError {
  // (no safe mode: the person's own lock, which the vault is kept by all the same: `personalLockOf`)
  if (!safeMode(inner, ws)) return personalLockOf(inner, ws);
  const h = inner.data.record("lock", ws);
  const entries = isObject(h) && Array.isArray(h.entries) ? (h.entries as Entry[]) : [];
  const head = isObject(h) ? str(get(h.head, "hash")) : null;
  if (entries.length === 0 || head === null) return new CoreError("vault_needs_lock", t("core-misc.vault.needsLock"));
  const force = inForceOf(inner, ws);
  // (where the chain moved, off is a statement, not an entry of it: the workspace off, as a chain disabled is)
  if (force.said === "off") return new CoreError("vault_needs_lock", t("core-misc.vault.needsLock"));
  // (moved: the state in force or, made of nothing the rules give, none that checks out; never the chain at the move)
  if (force.said !== "chain") return force.checked ?? new CoreError("vault_lock_invalid", "the workspace's lock does not check out: no state in force");
  return chainChecked(inner, ws, entries, head);
}

/// Whether `ws`'s vault goes by its workspace's lock (safe mode), by the lock held here and checked entry by entry
/// (never by a `disable` no owner signed, which a fold alone would take): a chain not turned off, or, moved, its state
/// in force not off; one that does not check out counts as on (nothing is let in by it). With none held, the workspace's
/// view's word (the cloud's), as `lockSafe` has it.
function safeMode(inner: Inner, ws: string): boolean {
  const h = inner.data.record("lock", ws);
  const entries = isObject(h) && Array.isArray(h.entries) ? (h.entries as Entry[]) : [];
  const head = isObject(h) ? str(get(h.head, "hash")) : null;
  if (entries.length === 0 || head === null) return get(workspaceView(inner, ws), "locked") === true;
  if (movedHere(inner, ws)) return inForceOf(inner, ws).said !== "off";
  const c = chainChecked(inner, ws, entries, head);
  return c instanceof CoreError || !c.disabled;
}

/// `ws`'s chain held, checked (the same while its head does not move); an error says why it does not check out.
function chainChecked(inner: Inner, ws: string, entries: Entry[], head: string): Checked | CoreError {
  const m = mem(inner);
  const at = `${head}/${entries.length}`;
  const had = m.checked.get(ws);
  if (had?.at === at) return had.lock;
  let lock: Checked | CoreError;
  try {
    lock = timed("vault.lock", () => checkLock(entries, nowS(inner)));
  } catch (e) {
    lock = asCoreError(e);
  }
  m.checked.set(ws, { at, lock });
  return lock;
}

/// Whether `ws` keeps the plain library: never now. A vault is encrypted and kept by its person's own devices whether the
/// workspace is in safe mode or not (「一律走个人加密密钥库」): what a station still keeps of a plain library from before
/// is only read to be moved into one's vault and deleted there (`migrate`: `openPlain`, `deletePlain`), never written,
/// approved from or shown as a vault of its own.
const plainMode = (_inner: Inner, _ws: string): boolean => false;

const isWorkspaceAdmin = (lock: Checked, sub: string): boolean => {
  const r = lock.members.get(sub);
  return r === "owner" || r === "admin";
};

const canManage = (lock: Checked, v: Vault, sub: string): boolean =>
  v.scope === "workspace"
    ? v.members.includes(sub) && isWorkspaceAdmin(lock, sub)
    : v.owner === sub;

/// Teammates' personal chains and workspace member roles for non-safe-mode lock folding: starts from station-synced
/// `memberRoles` and overlays authoritative cloud workspace `members` roles; never includes `sub`'s own chain.
function personalExtras(inner: Inner, ws: string, sub: string): { memberChains: Record<string, readonly Entry[]>; memberRoles: Record<string, string> } {
  const h = held(inner, ws);
  const memberRoles: Record<string, string> = {};
  for (const [mSub, mRole] of Object.entries(h.memberRoles ?? {})) {
    if (typeof mRole === "string" && mRole !== "") memberRoles[mSub] = mRole;
  }
  for (const m of arr(get(view(inner, ws), "members"))) {
    const mSub = str(get(m, "sub"));
    const mRole = str(get(m, "role"));
    if (mSub !== null && mSub !== "" && mRole !== null && mRole !== "") memberRoles[mSub] = mRole;
  }
  const memberChains: Record<string, readonly Entry[]> = {};
  for (const [mSub, mChain] of Object.entries(h.memberChains ?? {})) {
    if (mSub !== sub && Array.isArray(mChain) && mChain.length > 0) memberChains[mSub] = mChain;
  }
  return { memberChains, memberRoles };
}

/// The lock a workspace's vault goes by where it is not in safe mode, as its stations make it (station/src/cloud/
/// vault-lock.ts): the person's own lock, as pinned here, its app devices with the signers its entries said, under a
/// genesis of none (`""`, no chain of the workspace's), plus teammates' personal chains folded and verified locally.
/// The same object while the lock pinned, teammates' chains and member roles do not move. Their lock begun nowhere
/// yet (`none`): one naming none of their devices, so a secret to keep is shown and 开启 begins it (`Vaults.setup`);
/// this device outside it or replaced: an error, the page offering to be approved there.
const personalLocks = new WeakMap<Inner, Map<string, { at: string; lock: Checked | CoreError }>>();
function personalLockOf(inner: Inner, ws: string): Checked | CoreError {
  const sub = inner.workspaces.owner(ws);
  if (sub === null) return new CoreError("vault_no_account", t("core-misc.vault.notTrusted"));
  const personal = inner.adb.personal();
  if (typeof personal.standing !== "function" || typeof personal.pinnedOf !== "function") return new CoreError("vault_no_account", t("core-misc.vault.notTrusted"));
  const standing = personal.standing(sub);
  if (standing === "outside" || standing === "replaced") return new CoreError("vault_personal_outside", t("core-misc.vault.notTrusted"));
  const entries = personal.pinnedOf(sub);
  const last = entries[entries.length - 1];
  const { memberChains, memberRoles } = personalExtras(inner, ws, sub);
  const chainSig = Object.keys(memberChains).sort().map((k) => {
    const ch = memberChains[k]!;
    const tail = ch[ch.length - 1];
    let h = "bad";
    if (isObject(tail)) {
      try {
        h = entryHash(tail as Entry);
      } catch {
        h = "bad";
      }
    }
    return `${k}:${ch.length}:${h}`;
  }).join(",");
  const roleSig = Object.keys(memberRoles).sort().map((k) => `${k}:${memberRoles[k]!}`).join(",");
  const at = `${standing}/${sub}/${entries.length}/${last === undefined ? "" : entryHash(last)}|${chainSig}|${roleSig}`;
  let of = personalLocks.get(inner);
  if (of === undefined) personalLocks.set(inner, (of = new Map()));
  const had = of.get(ws);
  if (had?.at === at) return had.lock;
  const lock = personalChecked(ws, sub, entries, memberChains, memberRoles);
  of.set(ws, { at, lock });
  return lock;
}

/// `sub`'s own lock of `entries` (none: one naming no device) merged with verified teammates' personal chains and
/// workspace roles as a vault's lock of workspace `ws` (`personalLockOf`).
function personalChecked(
  ws: string,
  sub: string,
  entries: readonly Entry[],
  memberChains?: Record<string, readonly Entry[]>,
  memberRoles?: Record<string, string>,
): Checked | CoreError {
  const ownRole = memberRoles?.[sub] ?? "owner";
  const members = new Map<string, string>([[sub, ownRole]]);
  if (memberRoles) {
    for (const [mSub, mRole] of Object.entries(memberRoles)) {
      if (mSub !== sub && typeof mRole === "string" && mRole !== "") members.set(mSub, mRole);
    }
  }
  const devices = new Map<string, LockDevice>();
  const signKeys = new Map<string, string[]>();
  const signed = new Set<string>([sub]);
  let head = "";
  if (entries.length > 0) {
    const out = timed("vault.personal", () => rules.person_fold_js(entries, sub, personCrypto)) as J;
    if ("error" in out) return new CoreError("vault_lock_invalid", `the person's own lock does not check out: ${out.error}`);
    head = String(out.head);
    const ds = out.devices as { id: string; sign_key?: string; sign_keys?: string[] }[];
    for (const d of ds) {
      devices.set(d.id, { id: d.id, sub, kind: "app" as const, ...(typeof d.sign_key === "string" ? { sign_key: d.sign_key } : {}), own: true });
      signKeys.set(d.id, Array.isArray(d.sign_keys) ? d.sign_keys : []);
    }
  }
  if (memberChains) {
    for (const [mSub, mChain] of Object.entries(memberChains)) {
      if (mSub === sub || !Array.isArray(mChain) || mChain.length === 0) continue;
      try {
        const mout = timed("vault.personal", () => rules.person_fold_js(mChain, mSub, personCrypto)) as J;
        if (!("error" in mout) && Array.isArray(mout.devices)) {
          for (const d of mout.devices as { id: string; sign_key?: string; sign_keys?: string[] }[]) {
            if (typeof d?.id !== "string" || devices.has(d.id)) continue;
            devices.set(d.id, { id: d.id, sub: mSub, kind: "app" as const, ...(typeof d.sign_key === "string" ? { sign_key: d.sign_key } : {}), own: true });
            signKeys.set(d.id, Array.isArray(d.sign_keys) ? d.sign_keys : []);
          }
          if (!members.has(mSub)) members.set(mSub, memberRoles?.[mSub] ?? "member");
          signed.add(mSub);
        }
      } catch {
        // Ignore a single malformed teammate chain without affecting other members or this device's lock.
      }
    }
  }
  return {
    ws, head, genesis: "", members, devices, passkeys: new Map(), signed, signKeys, origins: [], rp_id: "", disabled: false, cloudKeys: null,
  };
}

/// Whether `ws`'s vault goes by its person's own lock that this device's person has not begun anywhere yet: 开启 begins
/// it (`Vaults.setup`), and a secret to keep is turned down with no lock of theirs (`Vaults.deny`).
function personalNone(inner: Inner, ws: string): boolean {
  if (safeMode(inner, ws)) return false;
  const sub = inner.workspaces.owner(ws);
  return sub !== null && inner.adb.personal().standing(sub) === "none";
}

/// Whether a certificate is of an app device in the lock that is its person's own (lock-check.ts Device `own`: one an
/// admin put in under their name is given no key, by itself or asked), signed by its own key; whose device it is.
function certOwner(lock: Checked, cert: BoxCert): string | null {
  return rules.cert_ok_js(lock, cert, false, rulesCrypto) === null ? lock.devices.get(cert.device)!.sub : null;
}

/// The app device of the lock that signs with `key`, where it is its person's own (no other's signature counts).
const ownSigner = (lock: Checked, key: unknown) => [...lock.devices.values()].find((x) => x.kind === "app" && x.own && x.sign_key === key);

/// Whether a vault's version is one the stations take (rules/, as station/src/vault/crypto.ts `vaultOk` checks a copy
/// brought from another station): signed by one of its owner's own app devices in the lock, its members in the lock,
/// each of its keys for a member's own device. Found once for each lock and version.
const trust = new WeakMap<Checked, WeakMap<Vault, boolean>>();
function trusted(lock: Checked, v: Vault): boolean {
  let of = trust.get(lock);
  if (!of) trust.set(lock, (of = new WeakMap()));
  let ok = of.get(v);
  if (ok === undefined) of.set(v, (ok = rules.vault_ok_js(lock, null, v, true, rulesCrypto) === null));
  return ok;
}

/// The lock as it stood when it last took vault version `v`: the lock as it is where it takes it, else the longest
/// prefix of the chain held that does (a version keyed for a device or member taken out since), else none. Found once
/// for each chain and version: a lock held is replaced whole as it moves on, never changed in place (a version by its
/// vault, number and signature, as what is held of the vaults is made anew at every change to any of them): the pages
/// ask it on every view of the vaults (`waitingAs`).
const took = new WeakMap<readonly Entry[], Map<string, Checked | null>>();
/// How many prefixes of a lock `tookAs` has checked: a count only, that the tests read (what it finds is kept).
export const waitingChecks = { count: 0 };
function tookAs(inner: Inner, ws: string, v: Vault): Checked | null {
  const lock = lockOf(inner, ws);
  if (!(lock instanceof CoreError) && trusted(lock, v)) return lock;
  // (no safe mode: the prefixes of the person's own lock, as a chain's are; else, moved, what this device kept of the
  // state that took it: a moved workspace has no line of prefixes)
  const sub = inner.workspaces.owner(ws);
  const own = !safeMode(inner, ws) && sub !== null;
  if (!own && movedHere(inner, ws)) return keptFor(inner, ws, v);
  const entries: readonly Entry[] = own ? inner.adb.personal().pinnedOf(sub) : (lockHeld(inner, ws)?.entries ?? []);
  let of = took.get(entries);
  if (!of) took.set(entries, (of = new Map()));
  const at = `${v.id}/${v.seq}/${v.sig?.sig}`;
  if (of.has(at)) {
    const cached = of.get(at)!;
    return cached ?? (own ? keptFor(inner, ws, v) : null);
  }
  const extras = own ? personalExtras(inner, ws, sub) : null;
  let was: Checked | null = null;
  for (let n = entries.length - 1; n > 0 && was === null; n--) {
    waitingChecks.count++;
    try {
      const prefix = own
        ? personalChecked(ws, sub, entries.slice(0, n), extras!.memberChains, extras!.memberRoles)
        : checkLock(entries.slice(0, n) as Entry[], nowS(inner));
      if (!(prefix instanceof CoreError) && !prefix.disabled && trusted(prefix, v)) was = prefix;
    } catch {
      // (a prefix that does not check out: an earlier one may)
    }
  }
  of.set(at, was);
  return was ?? (own ? keptFor(inner, ws, v) : null);
}

/// Where a workspace's chain moved, what of the state in force took each vault's version this device found trusted
/// (`keepTook`), by vault, then by epoch: the vault's members in that state with their roles, their app devices as it
/// named them (sign key, own) and the signing keys each had had in it (`signKeys`). That is all `vault_ok_js`,
/// `cert_ok_js` and `item_ok_js` read of a lock for one vault (rules/src/js/js.mbt `lock_view`: its members, devices
/// and signKeys; of those, a version's members, its keys' devices, its signer, its owner's, and an item's signer, a
/// member's device), so the version and its items are taken by it as they were. Kept for the newest version found
/// trusted of the vault's own epoch, and of an earlier epoch while its last version is kept for items left under it
/// (`before`): bounded by the vaults held, each by its members and their devices.
type TookState = { seq: number; sig: string; members: [string, string][]; devices: [string, TookDevice][]; signKeys: [string, string[]][] };
type TookDevice = { id: string; sub: string; kind: "app"; sign_key?: string; own: boolean };
type Took = Record<string, Record<string, TookState>>;
const tookHeld = (inner: Inner, ws: string): Took => {
  const r = inner.data.record("vaultTook", ws);
  return isObject(r) && isObject(r.took) ? (r.took as Took) : {};
};

/// What of `lock` takes vault version `v` (`TookState`).
function sliceOf(lock: Checked, v: Vault): TookState {
  const subs = new Set([v.owner, ...v.members].filter((m) => lock.members.has(m)));
  const devices = [...lock.devices.values()].filter((d) => d.kind === "app" && subs.has(d.sub)).sort((a, b) => (a.id < b.id ? -1 : 1));
  return {
    seq: v.seq, sig: v.sig?.sig ?? "",
    members: [...subs].sort().map((m) => [m, lock.members.get(m)!]),
    devices: devices.map((d) => [d.id, { id: d.id, sub: d.sub, kind: "app", ...(typeof d.sign_key === "string" ? { sign_key: d.sign_key } : {}), own: d.own }]),
    signKeys: devices.flatMap((d) => (lock.signKeys.has(d.id) ? [[d.id, [...lock.signKeys.get(d.id)!]] as [string, string[]]] : [])),
  };
}

/// The lock a kept state is read as: the same object for the same record (`trusted`'s WeakMap rests on it). It names
/// no passkey, settings or stations, and the rules' own object is not kept for it (nothing asks who signs by it).
const keptLocks = new WeakMap<TookState, Checked>();
function keptLock(ws: string, s: TookState): Checked {
  let c = keptLocks.get(s);
  if (c === undefined) {
    c = { ws, head: "", genesis: "", members: new Map(s.members), devices: new Map(s.devices), passkeys: new Map(), signed: new Set(), signKeys: new Map(s.signKeys), origins: [], rp_id: "", disabled: false, cloudKeys: null };
    keptLocks.set(s, c);
  }
  return c;
}

/// Where the chain moved, the state that took vault version `v` as this device kept it: only for that very version
/// (its number and signature), never a later one a station gives, and only where it takes it; else none (a device
/// begun anew since kept none, and holds no key of it either).
function keptFor(inner: Inner, ws: string, v: Vault): Checked | null {
  const s = tookHeld(inner, ws)[v.id]?.[String(v.epoch)];
  if (s === undefined || s.seq !== v.seq || s.sig !== (v.sig?.sig ?? "")) return null;
  const c = keptLock(ws, s);
  return trusted(c, v) ? c : null;
}

/// What of the state in force took each vault version held, kept (`TookState`) where the chain moved: as a version is
/// first found trusted (the vaults held changed: `change`) and as the state changes while it still is (`vaultCome`,
/// which runs as it is made anew, whatever made it so); never as a topic is answered. A version the state takes no
/// more keeps what was kept of it; a state that waits (naming nobody) or is off changes nothing kept.
function keepTook(inner: Inner, ws: string): void {
  if (!movedHere(inner, ws) && safeMode(inner, ws)) return;
  const lock = lockOf(inner, ws);
  const h = held(inner, ws);
  const was = tookHeld(inner, ws);
  const next: Took = {};
  for (const v of Object.values(h.vaults)) {
    if (v.deleted) continue;
    const keep: Record<string, TookState> = {};
    for (const [e, s] of Object.entries(was[v.id] ?? {})) if (e === String(v.epoch) || h.before?.[v.id]?.[e] !== undefined) keep[e] = s;
    if (!(lock instanceof CoreError) && trusted(lock, v)) {
      const s = sliceOf(lock, v);
      const had = keep[String(v.epoch)];
      keep[String(v.epoch)] = had !== undefined && JSON.stringify(had) === JSON.stringify(s) ? had : s;
    }
    if (Object.keys(keep).length > 0) next[v.id] = keep;
  }
  if (JSON.stringify(next) !== JSON.stringify(was)) inner.data.put("vaultTook", ws, { took: next });
}

/// A vault waiting to be keyed anew: the lock as it stood when it last took version `v` (`tookAs`), where the lock as
/// it is takes it no more only for a device or a member taken out since that holds a key of it or is in it, and its
/// owner is a member still; else null. Until its owner's device keys it anew (`rekeyGone`, written on its own
/// station), the devices left read it as that lock took it, and change nothing in it (`vault_waiting`,
/// `waitingError`): the stations take no version of it till then (rules/, a key for a device not in the lock). The
/// owner's decision, 2026-11-10: with the vault's station off (a laptop closed), a device taken out left the vault
/// gone for everyone, its items 「条目不存在」, until that station was back, though the devices left held its key and
/// its items. It gives the device taken out nothing: that device is out of the lock, so reads nothing of any vault
/// here (`Vaults.#ready`, and the views ask for this device in the lock), and reaches no station; what is carried on
/// as the vault is keyed anew is checked against this same lock (`#carryNow`).
export function waitingAs(inner: Inner, ws: string, lock: Checked, v: Vault): Checked | null {
  if (v.deleted || trusted(lock, v)) return null;
  const gone = v.keys.some((k) => !lock.devices.has(k.cert.device)) || v.members.some((m) => !lock.members.has(m));
  const hasManager = v.scope === "workspace"
    ? v.members.some((m) => lock.members.has(m) && isWorkspaceAdmin(lock, m))
    : lock.members.has(v.owner);
  if (!gone || !hasManager) return null;
  return tookAs(inner, ws, v);
}

/// The lock vault `v` is read by on this device: the lock as it is, where it takes it; the lock as it stood, where it
/// waits to be keyed anew (`waitingAs`) and this device, in the lock (`self`), holds one of its keys; else null (not
/// there).
function readAs(inner: Inner, ws: string, lock: Checked, v: Vault, self: { device: string } | null): Checked | null {
  if (v.deleted) return null;
  if (trusted(lock, v)) return lock;
  if (self === null || !v.keys.some((k) => k.cert.device === self.device)) return null;
  return waitingAs(inner, ws, lock, v);
}

/// The name of the station vault `v` waits on to be keyed anew (`waitingAs`), the one it lives on: its id's first
/// characters where the workspace names none.
function waitsOn(inner: Inner, ws: string, v: Vault): string {
  const at = hostOf(inner, ws, v.id);
  return str(stationsOf(inner, ws).find((s) => s.id === at)?.name) || at.slice(0, 8);
}

/// Why a change to vault `v`, waiting to be keyed anew, is refused: the station it waits for (`waitsOn`).
function waitingError(inner: Inner, ws: string, v: Vault): CoreError {
  return new CoreError("vault_waiting", t("core-misc.vault.waiting", { name: v.name, station: waitsOn(inner, ws, v) }));
}

/// Which of what a station says the rules take (a vault's version, an item's, a box certificate): what one says is
/// held over what is held only where they take it, or take what is held no more than it. A version a station made up
/// (signed by someone other than its writer, a later number on it) hides none held before it, nor one it gives after
/// (test/vault.test.ts "a station that lies"). No lock checked here: none taken. A vault waiting to be keyed anew
/// (`waitingAs`) is taken as the lock it waits by took it, and its items checked against that lock: else any later
/// version a station made up of it or of an item, taken by none, would be held over it.
type Fits = { vault(v: Vault): boolean; item(i: Item): boolean; cert(c: BoxCert): boolean };
function fitsWith(inner: Inner, ws: string, lock: Checked): Fits {
  return {
    vault: (v) => trusted(lock, v) || waitingAs(inner, ws, lock, v) !== null,
    item: (i) => {
      const v = held(inner, ws).vaults[i.vault];
      const as = v === undefined ? null : trusted(lock, v) ? lock : waitingAs(inner, ws, lock, v);
      return v !== undefined && as !== null && rules.item_ok_js(as, v, null, i, true, rulesCrypto) === null;
    },
    cert: (c) => rules.cert_ok_js(lock, c, false, rulesCrypto) === null,
  };
}
function fits(inner: Inner, ws: string): Fits {
  const lock = lockOf(inner, ws);
  if (lock instanceof CoreError) return { vault: () => false, item: () => false, cert: () => false };
  return fitsWith(inner, ws, lock);
}

/// Whether what is said is held over what is: the rules take it and not what is held, or it is the later (`later`) and
/// they take it or what is held no more.
const over = (ok: boolean, okHad: () => boolean, later: boolean) => (ok && !okHad()) || (later && (ok || !okHad()));

/// Why this device is no signer of `ws`'s vaults, where that is not its not being trusted there (`core-misc.vault.notSigner`,
/// which said it of both of these before, 2026-11-14): the workspace's chain moved and its state waits for the root's log
/// or its `open` (it names nobody yet, views/lock.ts `inForceOf`); or the state is in force and this device is on its
/// person's own log with its signer not said there (personal-lock.ts `signerUnsaid`), which the state names it by, so a
/// press says it (`confirm`: the call `lock.confirmSigner`). Null otherwise.
function whyNot(inner: Inner, ws: string): { code: string; text: string; confirm: boolean } | null {
  const force = inForceOf(inner, ws);
  // (told by a station that it is left out of the state in force there, it waits on nothing: not a signer, as the
  // `lock` topic's `waits` says, views/lock.ts)
  if (force.said === "waiting" && leftIn(inner, ws) === null) return { code: "vault_lock_waiting", text: t("core-misc.vault.lockWaiting"), confirm: false };
  const sub = inner.workspaces.owner(ws);
  // (only where its person's own lock lets it in here, as the `lock` topic's `confirmSigner`: a device replaced, or on a
  // lock this workspace is not bound to, has nothing to confirm)
  if (force.said === "on" && onBoundPerson(inner, ws) && sub !== null && inner.adb.personal().signerUnsaid(sub)) return { code: "vault_signer_unsaid", text: t("core-misc.vault.signerUnsaid"), confirm: true };
  // (no safe mode: the vault goes by the person's own lock, which names this device by the signer it says there)
  if (!safeMode(inner, ws) && sub !== null && inner.adb.personal().standing(sub) === "member" && inner.adb.personal().signerUnsaid(sub)) return { code: "vault_signer_unsaid", text: t("core-misc.vault.signerUnsaid"), confirm: true };
  return null;
}

/// This device in the lock: the one whose signing key is this app's, where it is its person's own (one an admin put
/// in under their name signs nothing, so keeps no vault).
function me(lock: Checked, signer: string | null | undefined): { device: string; sub: string } | null {
  if (!signer) return null;
  const d = ownSigner(lock, signer);
  return d ? { device: d.id, sub: d.sub } : null;
}

/// The certificates the lock vouches for, latest by device, each with whose it is (`sub`): those of the members' own
/// devices only. `bare`: the certificate alone, as it was signed (what is sealed to, and what a vault's keys carry: a
/// field more breaks its signature).
type Vouched = BoxCert & { sub: string };
function certs(inner: Inner, ws: string, lock: Checked): Vouched[] {
  return Object.values(held(inner, ws).boxes).flatMap((c) => {
    const sub = certOwner(lock, c);
    return sub === null ? [] : [{ ...c, sub }];
  });
}
const bare = ({ sub: _s, ...c }: Vouched): BoxCert => c;

/// The box key's public half this app keeps (BOX_PUB), as `install` reads it at the app's start: given so by a core put
/// together without that start (test/real-size-asked.ts).
export function boxKeyKnown(inner: Inner, pub: string | null): void {
  mem(inner).box = pub;
}

export function install(inner: Inner): void {
  handlers.vault = (core, call, _progress, _at, ctx) => run(core, call as Of, ctx);
  inner.stations.also.push({
    read: (address) => readStation(inner, address),
    resumed: (address) => {
      const ws = ofAddress(address);
      return inner.data.record("vault", ws) !== undefined ? Effect.void : readStation(inner, address);
    },
    event: (address, name, data) => heard(inner, address, name, data),
  });
  inner.router.owners.push(owner(inner));
  // What this app keeps (no person asked): its box key's public half.
  inner.runner.fork(
    Effect.gen(function* () {
      const m = mem(inner);
      const pub = yield* Effect.orElseSucceed(inner.host.storageGet(BOX_PUB), () => null);
      m.box = pub ? new TextDecoder().decode(pub) : null;
      lockSeen(inner).touch("self");
      inner.views?.vaultChanged(null);
      vaultReady(inner);
    }),
  );
}

// ── what the stations hold ──

const ask = (inner: Inner, address: string, method: string, path: string, body: unknown = null, ctx: SpanContext | null = null) =>
  inner.stations.requests.call(StationAddr.parse(address), method, path, body, { quiet: true, ctx });

/// What a station holds of the vault, read again: its vaults (and their items), the box certificates, the requests.
/// One that holds none says why (no lock pinned; a station from before).
export function readStation(inner: Inner, address: string): Effect.Effect<void, CoreError> {
  return Effect.gen(function* () {
    if (!inner.stations.link(address) || !inner.stations.reachable(address)) return;
    const ws = ofAddress(address);
    const station = address.slice(ws.length + 1);
    // The plain library (a station from before keeps none: 404), whether security mode is on or not.
    const plain = yield* Effect.result(ask(inner, address, "GET", "/vault/plain"));
    const plainItems = plain._tag === "Success" ? (arr(get(plain.success, "items")) as PlainRow[]) : null;
    if (plainItems !== null || (plain._tag === "Failure" && plain.failure.status === 404)) {
      change(inner, ws, (h) => {
        for (const [id, row] of Object.entries(h.plain)) if (row.station === station) delete h.plain[id];
        for (const i of plainItems ?? []) if (typeof i?.id === "string") h.plain[i.id] = { ...i, station };
        h.plainOn = h.plainOn.filter((s) => s !== station).concat(plainItems !== null ? [station] : []);
        const lasts = SCOPES.find((s) => s === get(plain._tag === "Success" ? plain.success : null, "lasts"));
        const at = get(plain._tag === "Success" ? plain.success : null, "lastsAt");
        if (lasts && typeof at === "number" && (h.plainLasts === undefined || h.plainLasts.at < at)) h.plainLasts = { lasts, at };
      });
    }
    // The requests are the keeper's (a station without one answers 404: none).
    const requests = yield* Effect.orElseSucceed(Effect.map(ask(inner, address, "GET", "/vault/requests"), (r) => arr(get(r, "requests")) as Request[]), () => [] as Request[]);
    // (what it was held to hold as it was asked: a listing says nothing of a vault written there after it was asked)
    const then = held(inner, ws);
    const vaults = yield* Effect.result(ask(inner, address, "GET", "/vault/vaults"));
    let list: Vault[] | null = null;
    let all: Item[] = [];
    let boxes: BoxCert[] = [];
    const incomingChains: Record<string, Entry[]> = {};
    const incomingRoles: Record<string, string> = {};
    if (vaults._tag === "Failure") {
      const e = vaults.failure;
      if (e.status !== undefined && e.status >= 400 && e.status < 500) change(inner, ws, (h) => {
        h.refused[station] = e.code;
        h.keeps = h.keeps.filter((s) => s !== station);
      });
    } else {
      list = arr(get(vaults.success, "vaults")) as Vault[];
      all = arr(get(yield* ask(inner, address, "GET", "/vault/items"), "items")) as Item[];
      const boxesRes = yield* ask(inner, address, "GET", "/vault/boxes");
      boxes = arr(get(boxesRes, "boxes")) as BoxCert[];
      const ownerSub = inner.workspaces.owner(ws);
      const rawChains = get(boxesRes, "chains");
      if (isObject(rawChains)) {
        for (const [mSub, mChain] of Object.entries(rawChains as Record<string, unknown>)) {
          if (mSub !== ownerSub && Array.isArray(mChain) && mChain.length > 0) incomingChains[mSub] = mChain as Entry[];
        }
      }
      const rawRoles = get(boxesRes, "roles");
      if (isObject(rawRoles)) {
        for (const [mSub, mRole] of Object.entries(rawRoles as Record<string, unknown>)) {
          if (typeof mRole === "string" && mRole !== "") incomingRoles[mSub] = mRole;
        }
      }
    }
    for (const v of [...(plainItems !== null ? [PLAIN] : []), ...(list ?? []).map((v) => v.id)]) yield* readUses(inner, address, v);
    yield* readCrossUses(inner, address);
    // Merge teammates' personal chains and roles before computing `fit`, so their BoxCerts and workspace vaults are
    // verified on the very first station read.
    if (Object.keys(incomingChains).length > 0 || Object.keys(incomingRoles).length > 0) {
      change(inner, ws, (h) => {
        if (Object.keys(incomingChains).length > 0) {
          h.memberChains = { ...(h.memberChains ?? {}), ...incomingChains };
        }
        if (Object.keys(incomingRoles).length > 0) {
          h.memberRoles = { ...(h.memberRoles ?? {}), ...incomingRoles };
        }
      });
    }
    // (what it says checked against the lock as held here; its items against their vaults as held once it is read)
    const fit = fits(inner, ws);
    const missing: string[] = [];
    // (a station read anew, its lock maybe caught up or itself updated: a version it refused is tried once more)
    for (const v of list ?? []) mem(inner).refused.delete(v.id);
    change(inner, ws, (h) => {
      if (list !== null) {
        keeps(h, station);
        const ids = new Set(list.map((v) => v.id));
        // Those it held and holds no more (one held from before copies were kept: where it was): held still here, as
        // its not listing one says nothing of why (a station that lies hides none so); asked for below. Only those it
        // was held to hold as it was asked: a vault made or first copied there meanwhile is not in a listing asked
        // before it (the locks' end to end, 2026-11-15: a vault made on the station as it was being read lost its
        // host here, and the write after it went to station "" and was refused `invalid_params`).
        const heldThen = (id: string) => then.on[id]?.[station] !== undefined || (then.on[id] === undefined && then.at[id] === station);
        for (const id of new Set([...Object.keys(h.on), ...Object.keys(h.at)])) {
          if (!ids.has(id) && heldThen(id) && (h.on[id]?.[station] !== undefined || (h.on[id] === undefined && h.at[id] === station))) {
            unheld(h, id, station);
            if (h.vaults[id] !== undefined) missing.push(id);
          }
        }
        for (const v of list) {
          holds(h, v, station, all.filter((i) => i.vault === v.id), fit);
        }
      }
      for (const c of boxes) if (heldOver(h.boxes[c.device], c, fit)) h.boxes[c.device] = c;
      for (const [id, at] of Object.entries(h.asked)) {
        if (at === station) {
          delete h.requests[id];
          delete h.asked[id];
        }
      }
      for (const r of requests) {
        if (r?.status !== "pending") continue;
        h.requests[r.id] = r;
        h.asked[r.id] = station;
      }
    });
    // Each item as the latest version any station holds (a copy behind its host's says nothing newer).
    for (const v of list ?? []) {
      // (gone where the version held says so: one a station made up deletes nothing)
      if (held(inner, ws).vaults[v.id]?.deleted) inner.data.forgetRecord("vaultItems", `${ws}/${v.id}`);
      else changeItems(inner, ws, v.id, (held) => {
        for (const i of all) if (i.vault === v.id && newer(i, held[i.id], fit)) held[i.id] = i;
      });
      settleBefore(inner, ws, v.id);
    }
    // Those it lists no more: the latest versions it holds of them, as the versions held here show this person was in
    // them; one taking them out (or deleting it), checked, lets it go here.
    if (missing.length > 0) yield* askLatest(inner, address, missing);
    // This device's certificate brought to a station that lacks it (one added to the workspace, or away, since this
    // device was set up, or set up with no station to take it): what its agents ask to keep is sealed to this device
    // too, and the requests waiting there are sealed again (vault/secrets.ts `boxed`). 2026-11-03: a request a station
    // made without it could be approved on no page of this device (「此申请提出时此设备尚未开启密钥库」). Before the
    // vaults are brought (`spreadAll`): a version keyed to this device is checked there against its certificate.
    if (list !== null) {
      const lock = lockOf(inner, ws);
      const self = lock instanceof CoreError ? null : me(lock, signerOf(inner));
      const mine = self === null ? undefined : held(inner, ws).boxes[self.device];
      if (self !== null && mine !== undefined && mine.box === mem(inner).box && certOwner(lock as Checked, mine) !== null && !boxes.some((c) => c.device === self.device && c.at >= mine.at)) {
        yield* Effect.ignore(ask(inner, address, "PUT", "/vault/boxes", mine), { log: "Unhandled", message: "vault box brought" });
      }
    }
    if (list !== null) spreadAll(inner, ws);
    // (members' devices set up meanwhile: given the keys unsealed here)
    if (boxes.length > 0) giveKept(inner, ws);
    // (items left under an earlier key, a keying anew stopped half-way: written again under the vault's where the keys
    // are unsealed here still)
    if (list !== null) carryKept(inner, ws);
    // (this device not set up while the person's vault is on elsewhere: set up by itself)
    autoBox(inner, ws);
  });
}

/// Whether item `i` is kept over `had` (none: it is): the later version, or of one version the one every station keeps
/// (rules/ `item_supersedes_js`).
const newer = (i: Item, had: Item | undefined, fit: Fits) =>
  had === undefined || over(fit.item(i), () => fit.item(had), i.version > had.version || (i.version === had.version && rules.item_supersedes_js(i, had)));

/// Whether box certificate `c` is held over `had` (the later, as `over` says).
const heldOver = (had: BoxCert | undefined, c: BoxCert, fit: Fits) => had === undefined || over(fit.cert(c), () => fit.cert(had), had.at <= c.at);

/// That `at` (a station's holding) holds item `i` at its version.
function holdsItem(at: Holding, i: Item): void {
  at.items[i.id] = i.version;
  if (typeof i.sig?.sig === "string") (at.sigs ??= {})[i.id] = i.sig.sig;
}

/// `station` keeps vaults: one it refused before (no lock pinned, a station from before) has since been updated or
/// caught up, so it is refused no more and brought what it lacks (`spreadAll`). Whether it was not kept before.
function keeps(h: Held, station: string): boolean {
  delete h.refused[station];
  if (h.keeps.includes(station)) return false;
  h.keeps.push(station);
  return true;
}

/// `station` known to keep vaults (it took a write, or told of one): one not kept before brought what it lacks.
function kept(inner: Inner, ws: string, station: string): void {
  let anew = false;
  change(inner, ws, (h) => void (anew = keeps(h, station)));
  if (anew) spreadAll(inner, ws);
}

/// `station` holds vault `v` (and these items, when said): the version kept of those held anywhere is the one shown.
/// (Holding one, it keeps vaults: `keeps`.)
function holds(h: Held, v: Vault, station: string, items: Item[] | null, fit: Fits): void {
  keeps(h, station);
  const on = (h.on[v.id] ??= {});
  const was = on[station];
  on[station] = { seq: v.seq, items: was?.items ?? {}, sig: v.sig?.sig, ...(was?.sigs ? { sigs: was.sigs } : {}) };
  if (items !== null) {
    on[station] = { seq: v.seq, items: {}, sig: v.sig?.sig };
    for (const i of items) holdsItem(on[station]!, i);
  }
  // Its host the first of the stations holding it by id, the same on every device: what each writes there follows on
  // from the same version (one written to another meanwhile is refused, not a second of its seq).
  h.at[v.id] = Object.keys(on).sort()[0]!;
  take(h, v, fit);
}

/// Where vault `id` is written from this device (`at` as it is written to, `hostOf`): the first of `writeHosts`, of the
/// stations holding it that the workspace has now (its list, and the lock's stations where the lock names any) the
/// first by id of those whose link is up, the same on every device that holds the same; `at` where none of them holds
/// it. A station taken out of the workspace stays in `on` (nothing reads it again to say it holds none), and where its
/// id was the first, every write and keying anew of the vault went to it, a station no longer there: the locks' end to
/// end, 2026-11-15, a station enrolled, given the vault's copy, taken out and stopped, then the owner's write refused
/// `vault_waiting` naming it.
function hostOf(inner: Inner, ws: string, id: string): string {
  return writeHosts(inner, ws, id)[0] ?? "";
}

/// The stations vault `id` may be written on, in the order tried (`#putVault`, `#putItem`): those holding it that the
/// workspace has now (as `hostOf` says), the ones whose link is up first, then those not found down, then the rest,
/// each by id within (so every device whose links agree writes on the same one); `at` alone where none of them holds it.
function writeHosts(inner: Inner, ws: string, id: string): string[] {
  const h = held(inner, ws);
  const listed = new Set(stationsOf(inner, ws).map((s) => s.id));
  const named = stateOf(inner, ws).stations;
  const there = Object.keys(h.on[id] ?? {}).filter((s) => listed.has(s) && (named.size === 0 || named.has(s))).sort();
  if (there.length === 0) return h.at[id] ? [h.at[id]!] : [];
  const tier = (s: string) => inner.stations.online(`${ws}/${s}`) ? 0 : inner.stations.reachable(`${ws}/${s}`) ? 1 : 2;
  const tiers = there.map((s) => [tier(s), s] as const);
  return [0, 1, 2].flatMap((t) => tiers.filter(([at]) => at === t).map(([, s]) => s));
}

/// Vault `v` held over the version held where the rules say so (of one seq, written on two stations at once: the one
/// every station and device keeps); a later one the lock does not take yet kept aside (`later`). One under a new key
/// keeps the version it replaces as the last of its key (`before`): its items may be left under it a while.
function take(h: Held, v: Vault, fit: Fits): void {
  const had = h.vaults[v.id];
  const later = had !== undefined && rules.vault_supersedes_js(v, had);
  if (had === undefined || over(fit.vault(v), () => fit.vault(had), later)) {
    h.vaults[v.id] = v;
    // (a vault deleted keeps no items, so nothing under an earlier key either)
    if (v.deleted) delete h.before?.[v.id];
    else if (had !== undefined && v.epoch > had.epoch) {
      const before = (h.before ??= {});
      before[v.id] = { ...before[v.id], [had.epoch]: had };
    }
    if (h.later?.[v.id] !== undefined && !rules.vault_supersedes_js(h.later[v.id], v)) delete h.later[v.id];
  } else if (later && (h.later?.[v.id] === undefined || rules.vault_supersedes_js(v, h.later[v.id]))) (h.later ??= {})[v.id] = v;
}

/// The versions kept of vault `id`'s earlier keys (`before`) let go where no item held of it sits under them any more.
/// As its items are read whole of a station, never as they are carried on here: an item another device wrote under
/// the earlier key as the vault was keyed anew may be told only after this device wrote the ones it held again, and
/// would then have no version to be carried on by.
function settleBefore(inner: Inner, ws: string, id: string): void {
  const of = held(inner, ws).before?.[id];
  if (of === undefined) return;
  const under = new Set(Object.values(items(inner, ws, id)).filter((i) => !i.deleted).map((i) => String(i.epoch)));
  const gone = Object.keys(of).filter((e) => !under.has(e));
  if (gone.length === 0) return;
  change(inner, ws, (h) => {
    const kept = h.before?.[id];
    if (kept === undefined) return;
    for (const e of gone) delete kept[e];
    if (Object.keys(kept).length === 0) delete h.before![id];
  });
}

/// The versions kept aside (`later`) that the lock as it is now takes, held: their items read again of the station
/// holding them (one heard before its vault was taken here was not held either).
function takeLater(inner: Inner, ws: string): void {
  const fit = fits(inner, ws);
  const now = Object.values(held(inner, ws).later ?? {}).filter((v) => fit.vault(v));
  if (now.length === 0) return;
  change(inner, ws, (h) => {
    for (const v of now) {
      delete h.later![v.id];
      take(h, v, fit);
    }
  });
  const h = held(inner, ws);
  for (const v of now) {
    const station = Object.entries(h.on[v.id] ?? {}).find(([, at]) => at.seq === v.seq)?.[0] ?? h.at[v.id];
    if (station !== undefined) inner.scheduler.enqueue(`${ws}/${station}`, `${ws}/${station} vault/${v.id}`, Priority.background, readItems(inner, `${ws}/${station}`, v.id));
  }
}

/// `station` no longer holds vault `id` (the version held kept, whoever holds it): its host another that does.
function unheld(h: Held, id: string, station: string): void {
  const on = h.on[id];
  if (on !== undefined) delete on[station];
  if (on !== undefined && Object.keys(on).length === 0) delete h.on[id];
  if (h.at[id] === station || h.at[id] === undefined) {
    const left = Object.keys(h.on[id] ?? {}).sort();
    if (left.length > 0) h.at[id] = left[0]!;
    else delete h.at[id];
  }
}

/// Whether the version of vault `id` held here takes this person out of it, or deletes it.
function outOf(inner: Inner, ws: string, id: string): boolean {
  const v = held(inner, ws).vaults[id];
  const sub = inner.workspaces.owner(ws);
  return v !== undefined && (v.deleted === true || sub === null || !v.members.includes(sub));
}

/// Vault `id` let go here where the version held says this person is out of it.
function forgetIfOut(inner: Inner, ws: string, id: string, station: string): void {
  if (!outOf(inner, ws, id)) return;
  change(inner, ws, (h) => letGo(h, id, station));
  inner.data.forgetRecord("vaultItems", `${ws}/${id}`);
}

/// The latest versions `address` holds of vaults `ids`, asked by the versions held here (each naming this person, its
/// owner's: station/src/api/routes/vault.ts `vault/vaults/latest`); taken as any it says, checked; those taking this
/// person out let go. A station from before answers 404: nothing taken, nothing let go.
function askLatest(inner: Inner, address: string, ids: string[]): Effect.Effect<void> {
  const ws = ofAddress(address);
  const station = address.slice(ws.length + 1);
  const mine = ids.map((id) => held(inner, ws).vaults[id]).filter((v): v is Vault => v !== undefined);
  return Effect.flatMap(
    Effect.orElseSucceed(Effect.map(ask(inner, address, "POST", "/vault/vaults/latest", { held: mine }), (r) => arr(get(r, "vaults")) as Vault[]), () => [] as Vault[]),
    (latest) => Effect.sync(() => {
      const fit = fits(inner, ws);
      change(inner, ws, (h) => {
        for (const v of latest) if (ids.includes(v.id)) holds(h, v, station, null, fit);
        // (it holds them: the copy of a station that lists one no more for this person; held here no longer as theirs)
        for (const v of latest) unheld(h, v.id, station);
      });
      for (const id of ids) forgetIfOut(inner, ws, id, station);
    }),
  );
}

/// `station` no longer holds vault `id`: gone where no station holds it; its host another that does.
function letGo(h: Held, id: string, station: string): void {
  const on = h.on[id];
  if (on !== undefined) delete on[station];
  if (on === undefined || Object.keys(on).length === 0) {
    delete h.on[id];
    delete h.vaults[id];
    delete h.at[id];
    delete h.before?.[id];
    return;
  }
  if (h.at[id] === station || h.at[id] === undefined) h.at[id] = Object.keys(on).sort()[0]!;
}

/// What `station` lacks of what the vaults' latest versions are: the vaults it holds none or an older version of, and
/// the items it holds none or an older version of (of the vaults it will hold). A vault deleted that it never held
/// (made and deleted here while no station took it) it lacks nothing of.
function lacks(h: Pick<Held, "vaults" | "on">, items: (vault: string) => Record<string, Item>, station: string): { id: string; vault: Vault | null; items: Item[] }[] {
  return Object.values(h.vaults).flatMap((v) => {
    const have = h.on[v.id]?.[station];
    // (or the other one of its seq, or of an item's version: brought the one kept)
    const other = (held: string | undefined, sig: unknown) => held !== undefined && typeof sig === "string" && held !== sig;
    const behind = have === undefined ? !v.deleted : have.seq < v.seq || (have.seq === v.seq && other(have.sig, v.sig?.sig));
    const missing = v.deleted ? [] : Object.values(items(v.id)).filter((i) => {
      const at = have?.items[i.id] ?? -1;
      return at < i.version || (at === i.version && other(have?.sigs?.[i.id], i.sig?.sig));
    });
    return behind || missing.length > 0 ? [{ id: v.id, vault: behind ? v : null, items: missing }] : [];
  });
}

/// Every station that keeps vaults brought what it lacks (each in its own lane, once at a time).
function spreadAll(inner: Inner, ws: string): void {
  if (!inner.scheduler) return;
  for (const station of held(inner, ws).keeps) {
    const address = `${ws}/${station}`;
    inner.scheduler.enqueue(address, `${address} vault-spread`, Priority.background, spread(inner, address));
  }
}

/// A station brought the latest version of each vault and item it lacks, as copies (`?copy=1`: a later version than
/// the one it holds, checked as any is). One that will not take it (a station from before, which takes only the next
/// version) is left as it is: its agents see what it holds.
function spread(inner: Inner, address: string): Effect.Effect<void> {
  const ws = ofAddress(address);
  const station = address.slice(ws.length + 1);
  return Effect.gen(function* () {
    if (!inner.stations.link(address) || !inner.stations.reachable(address)) return;
    for (const want of lacks(held(inner, ws), (vault) => items(inner, ws, vault), station)) {
      if (want.vault !== null) {
        const said = yield* Effect.result(ask(inner, address, "PUT", "/vault/vaults?copy=1", want.vault));
        if (said._tag === "Failure") continue;
        const v = (get(said.success, "vault") as Vault | undefined) ?? want.vault;
        change(inner, ws, (h) => holds(h, v, station, null, fits(inner, ws)));
      }
      for (const i of want.items) {
        const said = yield* Effect.result(ask(inner, address, "PUT", "/vault/items?copy=1", i));
        if (said._tag === "Failure") continue;
        const kept = (get(said.success, "item") as Item | undefined) ?? i;
        change(inner, ws, (h) => {
          const at = h.on[want.id]?.[station];
          if (at !== undefined) holdsItem(at, kept);
        });
      }
    }
  });
}

/// A station's event of the vault: a vault, an item, a box certificate or a request as it is now, a vault gone.
function heard(inner: Inner, address: string, name: string, data: unknown): void {
  const ws = ofAddress(address);
  const station = address.slice(ws.length + 1);
  const d = data as J;
  switch (name) {
    case "vault": {
      if (typeof d?.id !== "string") return;
      const known = held(inner, ws).on[d.id]?.[station] !== undefined;
      change(inner, ws, (h) => holds(h, d as Vault, station, null, fits(inner, ws)));
      if (held(inner, ws).vaults[d.id]?.deleted) inner.data.forgetRecord("vaultItems", `${ws}/${d.id}`);
      // One this person was just put in (or this station was just brought): its items are read.
      else if (!known) inner.scheduler.enqueue(address, `${address} vault/${d.id}`, Priority.background, readItems(inner, address, d.id));
      spreadAll(inner, ws);
      autoBox(inner, ws);
      return;
    }
    case "vault-gone":
      if (typeof d?.id !== "string") return;
      // Gone here only by the version taking this person out, checked (`vault`, as the station tells it); else held
      // still, the station holding it no more.
      change(inner, ws, (h) => {
        if (isObject(d.vault) && d.vault.id === d.id) holds(h, d.vault as Vault, station, null, fits(inner, ws));
        unheld(h, d.id, station);
      });
      forgetIfOut(inner, ws, d.id, station);
      return;
    case "vault-item":
      if (typeof d?.vault === "string" && typeof d?.id === "string") {
        const fit = fits(inner, ws);
        changeItems(inner, ws, d.vault, (all) => { if (newer(d as Item, all[d.id], fit)) all[d.id] = d; });
        change(inner, ws, (h) => {
          keeps(h, station);
          const at = h.on[d.vault]?.[station];
          if (at !== undefined) holdsItem(at, d as Item);
        });
        spreadAll(inner, ws);
      }
      return;
    case "vault-box":
      if (typeof d?.device === "string") {
        change(inner, ws, (h) => {
          if (heldOver(h.boxes[d.device], d as BoxCert, fits(inner, ws))) h.boxes[d.device] = d;
        });
        kept(inner, ws, station);
        // A member's device set up (or asking again): given the keys unsealed here, no one asked.
        giveKept(inner, ws);
        // (another device of this person's set up: this one too, by itself)
        autoBox(inner, ws);
      }
      return;
    case "vault-plain":
      if (typeof d?.id === "string") change(inner, ws, (h) => void (h.plain[d.id] = { ...d, station }));
      return;
    case "vault-request":
      if (typeof d?.id !== "string") return;
      // Decided: a use of its item, read again as its station says it (with its chat's title).
      if ((d.status === "granted" || d.status === "denied") && isObject(d.cross)) {
        inner.scheduler.enqueue(address, `${address} vault-cross-uses`, Priority.background, readCrossUses(inner, address));
      } else if ((d.status === "granted" || d.status === "denied") && typeof d.vault === "string" && d.vault !== "") {
        inner.scheduler.enqueue(address, `${address} vault-uses/${d.vault}`, Priority.background, readUses(inner, address, d.vault));
      }
      change(inner, ws, (h) => {
        if (d.status === "pending") {
          h.requests[d.id] = d;
          h.asked[d.id] = station;
        } else {
          delete h.requests[d.id];
          delete h.asked[d.id];
        }
      });
      return;
  }
}

/// The uses of a vault's items (or the plain library's) a station keeps; one from before keeps none to say.
function readUses(inner: Inner, address: string, vault: string): Effect.Effect<void> {
  const ws = ofAddress(address);
  const station = address.slice(ws.length + 1);
  return Effect.flatMap(
    Effect.orElseSucceed(Effect.map(ask(inner, address, "GET", `/vault/uses?vault=${encodeURIComponent(vault)}`), (r) => arr(get(r, "uses")) as Use[]), () => null),
    (uses) => Effect.sync(() => { if (uses !== null) change(inner, ws, (h) => void (h.uses[`${station}/${vault}`] = uses)); }),
  );
}

/// Cross-workspace personal secret uses recorded on `address`; old stations returning 404 silently yield [].
function readCrossUses(inner: Inner, address: string): Effect.Effect<void> {
  const ws = ofAddress(address);
  const station = address.slice(ws.length + 1);
  return Effect.flatMap(
    Effect.orElseSucceed(
      Effect.map(ask(inner, address, "GET", "/vault/cross-uses"), (r) => arr(get(r, "uses")) as CrossUse[]),
      () => [] as CrossUse[],
    ),
    (uses) => Effect.sync(() => {
      change(inner, ws, (h) => {
        h.crossUses = { ...(h.crossUses ?? {}), [station]: uses };
      });
    }),
  );
}

function readItems(inner: Inner, address: string, vault: string): Effect.Effect<void, CoreError> {
  return Effect.gen(function* () {
    const ws = ofAddress(address);
    const station = address.slice(ws.length + 1);
    const all = arr(get(yield* ask(inner, address, "GET", `/vault/items?vault=${encodeURIComponent(vault)}`), "items")) as Item[];
    const fit = fits(inner, ws);
    changeItems(inner, ws, vault, (held) => {
      for (const i of all) if (newer(i, held[i.id], fit)) held[i.id] = i;
    });
    settleBefore(inner, ws, vault);
    change(inner, ws, (h) => {
      const at = h.on[vault]?.[station];
      if (at !== undefined) {
        at.items = {};
        delete at.sigs;
        for (const i of all) holdsItem(at, i);
      }
    });
    spreadAll(inner, ws);
  });
}

// ── what the pages show ──

function owner(inner: Inner): Owner {
  return {
    owns: (t: Topic) => t.topic === "vaults" || t.topic === "vaultItems" || t.topic === "vaultUses",
    // Shown: the workspace's stations read again, what is held showing meanwhile.
    start: (t: Topic) => {
      const ws = t.workspace as string;
      for (const s of stationsOf(inner, ws)) {
        const address = `${ws}/${s.id}`;
        inner.scheduler.enqueue(address, `${address} vault`, Priority.shown, readStation(inner, address));
      }
    },
    compute: (t: Topic) => {
      const ws = typeof t.workspace === "string" ? t.workspace : "";
      // (what this core holds of them beside the records: its keys, the lock, the vaults unsealed here)
      const seen = lockSeen(inner);
      seen.read("self");
      seen.read(`lock ${ws}`);
      seen.read(`vault ${ws}`);
      if (t.topic === "vaultUses" || t.topic === "vaultItems") {
        for (const [otherWs] of inner.workspaces.owned()) {
          if (otherWs !== ws) seen.read(`vault ${otherWs}`);
        }
      } else if (t.topic === "vaults") {
        const reqs = Object.values(held(inner, ws).requests);
        const hasBrowse = reqs.some((r) => r.status === "pending" && r.browse !== undefined);
        if (hasBrowse) {
          for (const [otherWs] of inner.workspaces.owned()) {
            if (otherWs !== ws) seen.read(`vault ${otherWs}`);
          }
        } else {
          const crossWorkspaces = new Set<string>();
          for (const r of reqs) {
            if (r.status === "pending" && r.cross !== undefined) crossWorkspaces.add(r.cross.workspace);
          }
          for (const otherWs of crossWorkspaces) seen.read(`vault ${otherWs}`);
        }
      }
      return { ok: t.topic === "vaults" ? vaultsView(inner, ws) : t.topic === "vaultUses" ? usesView(inner, ws, String(t.vault), String(t.item)) : itemsView(inner, ws, String(t.vault)) };
    },
  };
}

const keyOf = (v: Vault) => `${v.id}/${v.epoch}`;
const unlocked = (inner: Inner, v: Vault) => (mem(inner).keys.get(keyOf(v))?.until ?? 0) > inner.host.nowMs();

/// Whether this host keeps keys as an app does, in the system's secure storage.
const able = (inner: Inner) => inner.host.appKeys === true && typeof inner.host.secureGet === "function" && typeof inner.host.secureSet === "function";

/// How an agent's request a card names (`card.vault`; `save`: one to keep a secret) is answered on this device, from the
/// vault as this core holds it: what a chat's card shows at its foot with the message itself (views.ts),
/// never asking for more. `elsewhere`: approved only in an app that keeps keys (the plain library's anywhere); `setUp`:
/// a secret to keep while this device's vault is not on (开启密钥库 first); `noKey`: this device does not hold a key to
/// this encrypted vault yet; else `approve`, a use given for `lasts` at the longest (the item's, else its vault's; a
/// request not held yet, as one with none said).
export type AskAnswer = {
  answer: "approve" | "setUp" | "elsewhere" | "notHere" | "noKey" | "empty";
  lasts?: Scope;
  saveTargets?: { id: string; name: string; workspace?: boolean }[];
  browseWorkspaces?: number;
  browseItems?: number;
};

export type BrowseCandidateItem = {
  vault: string;
  vaultName: string;
  item: string;
  name: string;
  about?: string;
  kind: string;
  howText: string;
};

export type BrowseCandidateWorkspace = {
  id: string;
  name: string;
  items: BrowseCandidateItem[];
};

export type BrowseCandidates = {
  workspaces: BrowseCandidateWorkspace[];
  unkeyedWorkspaces: number;
};

/// Whether an item of a cross-workspace personal vault `v` is readable by `selfA` on this device:
/// supports items under `v.epoch` as well as items still under an earlier epoch held in `hA.before`
/// whose historical vault version passes `tookAs` and carries a key for `(selfA.device, myBox)`.
function crossItemReadable(
  inner: Inner,
  otherWs: string,
  lockA: Checked,
  hA: Held,
  v: Vault,
  selfA: { device: string; sub: string },
  myBox: string | null | undefined,
  i: Item,
): { vault: Vault; lock: Checked } | null {
  if (i.deleted || i.listing === undefined || myBox === null || myBox === undefined) return null;
  if (i.epoch === v.epoch) {
    const asA = readAs(inner, otherWs, lockA, v, selfA);
    if (asA === null || !v.keys.some((k) => k.cert.device === selfA.device && k.cert.box === myBox)) return null;
    return { vault: v, lock: asA };
  }
  if (i.epoch < v.epoch) {
    const b = hA.before?.[v.id]?.[String(i.epoch)];
    if (b === undefined) return null;
    const was = tookAs(inner, otherWs, b);
    if (was === null || !b.keys.some((k) => k.cert.device === selfA.device && k.cert.box === myBox)) return null;
    return { vault: b, lock: was };
  }
  return null;
}

/// Pure local SQLite read of eligible personal secrets across other workspaces owned by the same account.
/// Security boundaries (hard-enforced):
/// - only same-account workspaces (`otherWs !== ws`);
/// - verified source lock `lockA` with `selfA.sub === ownerSub`;
/// - only personal vaults (`scope !== "workspace" && owner === ownerSub && !deleted`, trusted or `waitingAs` via `readAs`);
/// - only vaults whose key this device holds;
/// - only non-deleted items with an agent `listing` under `v.epoch` or a readable `before` epoch.
export function browseCandidates(inner: Inner, ws: string): BrowseCandidates {
  const ownerSub = inner.workspaces?.owner(ws) ?? null;
  const signer = signerOf(inner);
  if (ownerSub === null || signer === null || !able(inner)) return { workspaces: [], unkeyedWorkspaces: 0 };
  const myBox = mem(inner).box;
  const workspaces: BrowseCandidateWorkspace[] = [];
  let unkeyedWorkspaces = 0;
  for (const [otherWs, otherOwner] of inner.workspaces.owned()) {
    if (otherWs === ws) continue;
    if (inner.scheduler && !mem(inner).browseRead.has(otherWs)) {
      const ready = stationsOf(inner, otherWs)
        .map((s) => `${otherWs}/${s.id}`)
        .filter((addr) => inner.stations.link(addr) && inner.stations.reachable(addr));
      if (ready.length > 0) {
        mem(inner).browseRead.add(otherWs);
        for (const addr of ready) {
          inner.scheduler.enqueue(addr, `${addr} vault`, Priority.background, readStation(inner, addr));
        }
      }
    }
    const hA = held(inner, otherWs);
    const lockA = lockOf(inner, otherWs);
    const selfA = lockA instanceof CoreError ? null : me(lockA, signer);
    if (lockA instanceof CoreError || selfA === null || selfA.sub !== otherOwner) {
      if (Object.values(hA.vaults).some((v) => !v.deleted && v.scope !== "workspace" && v.owner === otherOwner)) {
        unkeyedWorkspaces++;
      }
      continue;
    }
    const wsItems: BrowseCandidateItem[] = [];
    let hasUnkeyed = false;
    for (const v of Object.values(hA.vaults)) {
      if (v.deleted || v.scope === "workspace" || v.owner !== otherOwner) continue;
      const asA = readAs(inner, otherWs, lockA, v, selfA);
      const keyed = asA !== null && myBox !== null && myBox !== undefined && v.keys.some((k) => k.cert.device === selfA.device && k.cert.box === myBox);
      if (!keyed) {
        hasUnkeyed = true;
        continue;
      }
      for (const i of Object.values(items(inner, otherWs, v.id))) {
        if (crossItemReadable(inner, otherWs, lockA, hA, v, selfA, myBox, i) === null) continue;
        const l = i.listing!;
        wsItems.push({
          vault: v.id,
          vaultName: v.name,
          item: i.id,
          name: l.name,
          ...(l.about ? { about: l.about } : {}),
          kind: l.kind,
          howText: l.modes.map((m) => howText(m, l.hosts)).join("、"),
        });
      }
    }
    if (wsItems.length > 0) {
      wsItems.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : a.item < b.item ? -1 : a.item > b.item ? 1 : 0));
      workspaces.push({ id: otherWs, name: workspaceName(inner, otherWs), items: wsItems });
    } else if (hasUnkeyed) {
      unkeyedWorkspaces++;
    }
  }
  workspaces.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return { workspaces, unkeyedWorkspaces };
}

/// Whether a secret an agent asks to keep was sealed by its station to the person's devices set up then, this one not
/// among them (set up since, or its certificate not on that station then): approved on one of those, or here once
/// the station has this device's certificate and seals it again (readStation brings it). The card says so instead of
/// failing as 存入 is pressed (2026-11-03, 「此申请提出时此设备尚未开启密钥库」).
const notHere = (r: Request | undefined, device: string | null, box: string | null): boolean =>
  r?.save !== undefined && r.save.typed !== true && Array.isArray(r.sealed) && device !== null && !r.sealed.some((x) => x.device === device && (box === null || x.box === box));

/// Whether an encrypted-vault request lacks a key on this device (cannot be approved, saved, renamed or deleted here):
/// - plain requests never need an encrypted vault key;
/// - save requests mirror `#keepSaved` (after `setUp` and `notHere`): when the viewer already owns an active trusted
///   vault, neither `r.vault` nor any active member vault is keyed on this device;
/// - use / describe / remove requests: the target vault exists, is not deleted, and is not keyed on this device
///   (including when `self === null`);
/// - when `r` has not synced yet: falls back to whether the viewer's active member vaults (or own vaults for `save`
///   once `setUp`) exist here with none keyed.
function vaultNoKey(
  lock: Checked,
  h: Held,
  self: { device: string; sub: string } | null,
  mine: BoxCert | undefined,
  box: string | null | undefined,
  r: Request | undefined,
  save: boolean,
  isSetUp: () => boolean,
  activeMemberVaults: () => Vault[],
): boolean {
  const keyed = (v: Vault): boolean =>
    self !== null && mine !== undefined && mine.box === box && v.keys.some((k) => k.cert.device === self.device && k.cert.box === mine.box);
  if (r !== undefined) {
    if (r.vault === PLAIN) return false;
    if (r.save !== undefined) {
      if (!isSetUp()) return false;
      if (notHere(r, self?.device ?? null, box ?? null)) return false;
      const memberVaults = activeMemberVaults();
      const personalVaults = self === null ? [] : memberVaults.filter((v) => v.scope !== "workspace" && v.owner === self.sub);
      if (self === null || personalVaults.length === 0) return false;
      const target = h.vaults[r.vault];
      if (target !== undefined && !target.deleted && target.scope !== "workspace" && trusted(lock, target) && target.members.includes(self.sub) && keyed(target)) return false;
      return !personalVaults.some(keyed);
    }
    const v = h.vaults[r.vault];
    return v !== undefined && !v.deleted && !keyed(v);
  }
  const memberVaults = activeMemberVaults();
  if (!save) return memberVaults.length > 0 && !memberVaults.some(keyed);
  const personalVaults = self === null ? [] : memberVaults.filter((v) => v.scope !== "workspace" && v.owner === self.sub);
  return isSetUp() && personalVaults.length > 0 && !personalVaults.some(keyed);
}

export function askAnswers(inner: Inner, ws: string, asks: { request: string; save: boolean; browse?: boolean; crossWs?: string }[]): AskAnswer[] {
  const lock = lockOf(inner, ws);
  const plain = plainMode(inner, ws);
  if (!able(inner) && !plain) return asks.map(() => ({ answer: "elsewhere" }));
  const h = held(inner, ws);
  const self = lock instanceof CoreError ? null : me(lock, signerOf(inner));
  // (this device's box certificate the lock vouches for, its key the one kept here: as the `vaults` topic's setUp)
  let mineLoaded = false;
  let mineCert: BoxCert | undefined;
  const mineOf = (): BoxCert | undefined => {
    if (mineLoaded) return mineCert;
    mineLoaded = true;
    if (lock instanceof CoreError || self === null) return undefined;
    const cert = h.boxes[self.device];
    return (mineCert = cert !== undefined && certOwner(lock, cert) !== null ? cert : undefined);
  };
  let setUp: boolean | undefined;
  const isSetUp = (): boolean => {
    if (setUp !== undefined) return setUp;
    const mine = mineOf();
    return (setUp = mine !== undefined && mine.box === mem(inner).box);
  };
  let activeVaults: Vault[] | undefined;
  const activeMemberVaults = (): Vault[] => {
    if (activeVaults !== undefined) return activeVaults;
    if (lock instanceof CoreError || self === null) return (activeVaults = []);
    return (activeVaults = Object.values(h.vaults).filter((v) => !v.deleted && trusted(lock, v) && v.members.includes(self.sub)));
  };
  let saveTargetsCache: { id: string; name: string; workspace?: boolean }[] | null | undefined;
  const keyedTargets = (): { id: string; name: string; workspace?: boolean }[] | undefined => {
    if (saveTargetsCache !== undefined) return saveTargetsCache ?? undefined;
    if (plain || lock instanceof CoreError || self === null) return (saveTargetsCache = null), undefined;
    const mine = mineOf();
    const box = mem(inner).box;
    if (mine === undefined || mine.box !== box) return (saveTargetsCache = null), undefined;
    const keyed = activeMemberVaults().filter((v) => v.keys.some((k) => k.cert.device === self.device && k.cert.box === mine.box));
    if (keyed.length <= 1) return (saveTargetsCache = null), undefined;
    const cmp = (a: Vault, b: Vault) => (a.name < b.name ? -1 : a.name > b.name ? 1 : a.id < b.id ? -1 : 1);
    const personal = keyed.filter((v) => v.scope !== "workspace").sort(cmp);
    const workspace = keyed.filter((v) => v.scope === "workspace").sort(cmp);
    saveTargetsCache = [...personal, ...workspace].map((v) => ({ id: v.id, name: v.name, ...(v.scope === "workspace" ? { workspace: true } : {}) }));
    return saveTargetsCache;
  };
  let browseCache: BrowseCandidates | undefined;
  const candidatesOf = (): BrowseCandidates => (browseCache ??= browseCandidates(inner, ws));
  return asks.map(({ request, save, browse, crossWs }): AskAnswer => {
    const r = h.requests[request];
    if (browse || r?.browse !== undefined) {
      if (!able(inner) || lock instanceof CoreError || self === null) return { answer: "elsewhere" };
      const cands = candidatesOf();
      const browseWorkspaces = cands.workspaces.length;
      const browseItems = cands.workspaces.reduce((n, w) => n + w.items.length, 0);
      if (browseItems === 0) {
        return cands.unkeyedWorkspaces > 0
          ? { answer: "noKey", browseWorkspaces: 0, browseItems: 0 }
          : { answer: "empty", browseWorkspaces: 0, browseItems: 0 };
      }
      return { answer: "approve", browseWorkspaces, browseItems };
    }
    const sourceWs = r?.cross?.workspace ?? crossWs;
    if (sourceWs !== undefined) {
      if (!able(inner) || lock instanceof CoreError || self === null) return { answer: "elsewhere" };
      const otherOwner = inner.workspaces.owner(sourceWs);
      const lockA = lockOf(inner, sourceWs);
      const selfA = lockA instanceof CoreError ? null : me(lockA, signerOf(inner));
      const hA = held(inner, sourceWs);
      const myBox = mem(inner).box;
      let sourceNoKey = otherOwner === null || lockA instanceof CoreError || selfA === null || selfA.sub !== otherOwner || myBox === null || myBox === undefined;
      if (!sourceNoKey && !(lockA instanceof CoreError) && r !== undefined) {
        const vA = hA.vaults[r.vault];
        sourceNoKey =
          vA === undefined ||
          vA.deleted ||
          vA.scope === "workspace" ||
          vA.owner !== otherOwner ||
          readAs(inner, sourceWs, lockA, vA, selfA) === null ||
          !vA.keys.some((k) => k.cert.device === selfA!.device && k.cert.box === myBox);
      }
      const lasts: Scope = r === undefined ? "chat" : (items(inner, sourceWs, r.vault)[r.item]?.listing?.lasts ?? hA.vaults[r.vault]?.lasts ?? "chat");
      return { answer: sourceNoKey ? "noKey" : "approve", lasts };
    }
    const noKey = (): boolean =>
      !plain && !(lock instanceof CoreError) && vaultNoKey(lock, h, self, mineOf(), mem(inner).box, r, save, isSetUp, activeMemberVaults);
    if (save) {
      if (r?.describe !== undefined || r?.remove !== undefined) {
        return { answer: noKey() ? "noKey" : !plain && !isSetUp() ? "setUp" : "approve" };
      }
      const answer =
        !plain && !isSetUp()
          ? "setUp"
          : notHere(r, self?.device ?? null, mem(inner).box ?? null)
            ? "notHere"
            : noKey()
              ? "noKey"
              : "approve";
      const saveTargets = answer === "approve" ? keyedTargets() : undefined;
      return saveTargets !== undefined ? { answer, saveTargets } : { answer };
    }
    const lasts =
      r === undefined
        ? "chat"
        : r.vault === PLAIN
          ? (h.plain[r.item]?.listing?.lasts ?? h.plainLasts?.lasts ?? "chat")
          : (items(inner, ws, r.vault)[r.item]?.listing?.lasts ?? h.vaults[r.vault]?.lasts ?? "chat");
    return { answer: noKey() ? "noKey" : "approve", lasts };
  });
}

/// The workspace's lock checked, and this device's certificate in it, as they come (lock.ts, as the lock is read): what
/// a chat's vault cards are answered by is there as the chat opens, not checked then (a chat opens by looking up what
/// it shows: test/chat-open-lookup.test.ts).
export function vaultCome(inner: Inner, ws: string): void {
  // A version told before the lock that takes it came (this device let in again): held now.
  takeLater(inner, ws);
  // (where the chain moved: what of the state took each version, as it is now)
  keepTook(inner, ws);
  timed("vault.come", () => askAnswers(inner, ws, [{ request: "", save: true }]));
  // A device confirmed in the lock whose certificate came first: given the keys unsealed here; the prompts of every
  // workspace follow the lock too.
  giveKept(inner, ws);
  // (a chat's vault cards open already answered as the lock was: answered again as it is now, with no vault changed)
  inner.views?.vaultChanged(ws);
  // A device or member taken out who held a key of a vault of this person's own: the vault keyed anew without them.
  if (able(inner)) inner.runner.fork(Effect.ignore(new Vaults(inner, ws, null).rekeyGone(), { log: "Unhandled", message: "vaults keyed anew" }));
  lockSeen(inner).touch("prompts");
  // This device just let in (approved on another of the person's): set up by itself where their vault is on already;
  // nothing of the vaults held yet, the stations read now for it (once a run), as a page shown would.
  const h = held(inner, ws);
  if (able(inner) && Object.keys(h.vaults).length === 0 && Object.keys(h.boxes).length === 0 && !mem(inner).cameRead.has(ws)) {
    const lock = lockOf(inner, ws);
    if (!(lock instanceof CoreError) && me(lock, signerOf(inner)) !== null) {
      mem(inner).cameRead.add(ws);
      for (const s of stationsOf(inner, ws)) {
        const address = `${ws}/${s.id}`;
        inner.scheduler.enqueue(address, `${address} vault`, Priority.background, readStation(inner, address));
      }
    }
  }
  autoBox(inner, ws);
}

/// Whether this device is set up in `ws` (its certificate the lock vouches for, its box key the one kept here), as the
/// `vaults` topic's `setUp` says.
function setUpHere(inner: Inner, ws: string, lock: Checked, device: string): boolean {
  const mine = held(inner, ws).boxes[device];
  return mine !== undefined && certOwner(lock, mine) !== null && mine.box === mem(inner).box;
}

/// Whether this person's vault is on already on another device of theirs in `ws`: a vault they are in that the lock
/// takes (or one waiting to be keyed anew), or a certificate of another device of theirs (its vault not come yet).
function onElsewhere(inner: Inner, ws: string, lock: Checked, self: { device: string; sub: string }): boolean {
  const h = held(inner, ws);
  return Object.values(h.vaults).some((v) => !v.deleted && v.members.includes(self.sub) && (trusted(lock, v) || waitingAs(inner, ws, lock, v) !== null))
    || certs(inner, ws, lock).some((c) => c.sub === self.sub && c.device !== self.device);
}

/// This device set up by itself (its box key made, its certificate published: `Vaults.certify`) where it is in the lock,
/// not set up, and the person's vault is on already on another device of theirs (`onElsewhere`): approved on that one,
/// they were told 「密钥库未开启」 here and had to press 开启 again (2026-11-20). Writing the box key asks nobody (only
/// reading it does) and the signer is read unasked, so nothing prompts; no recovery words are made and no vault: those
/// of the person's other devices are the ones. Where the vault is on nowhere, 开启 stays the person's own press.
function autoBox(inner: Inner, ws: string): void {
  if (!able(inner) || mem(inner).autoBoxing.has(ws)) return;
  const lock = lockOf(inner, ws);
  if (lock instanceof CoreError) return;
  const self = me(lock, signerOf(inner));
  if (self === null || setUpHere(inner, ws, lock, self.device) || !onElsewhere(inner, ws, lock, self)) return;
  mem(inner).autoBoxing.add(ws);
  inner.runner.fork(Effect.ignore(Effect.ensuring(new Vaults(inner, ws, null).autoSetUp(), Effect.sync(() => void mem(inner).autoBoxing.delete(ws))), { log: "Unhandled", message: "vault set up by itself" }));
}

/// Re-check all owned workspaces once this device's signer or box key finishes loading at cold start: if `readStation`
/// and `vaultCome` ran before `Signer.load()`, `autoBox` returned early and would otherwise never retry.
export function vaultReady(inner: Inner): void {
  if (!able(inner) || signerOf(inner) === null || !inner.scheduler || !inner.runner || !inner.workspaces) return;
  for (const [ws] of inner.workspaces.owned()) {
    const lock = lockOf(inner, ws);
    if (lock instanceof CoreError) continue;
    const self = me(lock, signerOf(inner));
    if (self === null || setUpHere(inner, ws, lock, self.device)) continue;
    const h = held(inner, ws);
    if (Object.keys(h.vaults).length === 0 && Object.keys(h.boxes).length === 0 && !mem(inner).cameRead.has(ws)) {
      mem(inner).cameRead.add(ws);
      for (const s of stationsOf(inner, ws)) {
        const address = `${ws}/${s.id}`;
        inner.scheduler.enqueue(address, `${address} vault`, Priority.background, readStation(inner, address));
      }
    }
    autoBox(inner, ws);
  }
}

/// This app's box key's public half: the one kept, else made now (its private half in the secure storage, written
/// without asking the person) and kept. One at a time in this core (`boxInit`).
export function ensureBoxKey(inner: Inner): Effect.Effect<string, CoreError> {
  // A typed failure, not a defect: `pairBoxCerts` is wrapped in `Effect.orElseSucceed` whenever `appKeys` is true,
  // including on hosts without `secureSet` (a `NodeHost` without a sealer).
  if (!able(inner)) return fail("vault_unavailable", t("core-misc.vault.unavailable"));
  const m = mem(inner);
  return m.boxInit.withPermits(1)(Effect.gen(function* () {
    const had = yield* Effect.orElseSucceed(inner.host.storageGet(BOX_PUB), () => null);
    if (had) return (m.box = new TextDecoder().decode(had));
    const priv = new Uint8Array(32);
    inner.host.randomBytes(priv);
    const pub = boxPublic(priv);
    yield* Effect.mapError(inner.host.secureSet!(BOX_KEY, priv, { user: true }), (e) => CoreError.refused(e, "vault_refused"));
    yield* Effect.mapError(inner.host.storageSet(BOX_PUB, utf8(pub)), asCoreError);
    return (m.box = pub);
  }));
}

/// The box key the system says can no longer be opened (`key_invalidated`: Android, the screen lock taken off since it
/// was kept), as the person read it (`dead`, the public half kept then): made anew, so nothing is sealed to the dead one
/// again (a vault made or given here after would open nowhere, 删库重建仍立刻失败: FB-51). Its public half goes first: where
/// the new one cannot be kept (no screen lock yet), none is kept, and this device is no longer set up anywhere
/// (`setUpHere`) rather than said to hold keys it cannot open. Each workspace's certificate is then published anew by
/// itself (`autoBox`, as for a device just let in: nobody asked), so the vaults show no key here and offer the way back
/// (申请授权, the recovery words), which seals them to the new box key. Made once though several reads fail at once.
function renewBoxKey(inner: Inner, dead: string | null): Effect.Effect<string, CoreError> {
  const m = mem(inner);
  return m.boxInit.withPermits(1)(Effect.gen(function* () {
    const had = yield* Effect.orElseSucceed(inner.host.storageGet(BOX_PUB), () => null);
    const now = had ? new TextDecoder().decode(had) : null;
    if (now !== null && now !== dead) return (m.box = now);
    yield* Effect.ignore(inner.host.storageDelete(BOX_PUB));
    m.box = null;
    // (what the pages say of this device, its setting up and its keys, is read by the box key kept: said again)
    lockSeen(inner).touch("self");
    inner.views?.vaultChanged(null);
    const priv = new Uint8Array(32);
    inner.host.randomBytes(priv);
    const pub = boxPublic(priv);
    yield* Effect.mapError(inner.host.secureSet!(BOX_KEY, priv, { user: true }), (e) => CoreError.refused(e, "vault_refused"));
    priv.fill(0);
    yield* Effect.mapError(inner.host.storageSet(BOX_PUB, utf8(pub)), asCoreError);
    m.box = pub;
    lockSeen(inner).touch("self");
    inner.views?.vaultChanged(null);
    return pub;
  }));
}

export type HandedVault = { ws: string; cert: BoxCert; vault?: Vault };

function handoverWorkspaces(inner: Inner, subs: readonly string[], workspaces: readonly string[]): string[] {
  const out = new Set<string>(workspaces);
  if (subs.length > 0) {
    for (const [ws, sub] of inner.workspaces.owned()) if (subs.includes(sub)) out.add(ws);
  }
  return [...out];
}

/// Signs this device's X25519 box certificate for every workspace involved in a pairing request (`hello.boxCerts`),
/// creating the box key silently if it does not exist yet.
export function pairBoxCerts(inner: Inner, device: string, signer: Signer, subs: readonly string[], workspaces: readonly string[]): Effect.Effect<{ box: string; certs: Record<string, BoxCert> }, CoreError> {
  return Effect.gen(function* () {
    const box = yield* ensureBoxKey(inner);
    const signed: Record<string, BoxCert> = {};
    for (const ws of handoverWorkspaces(inner, subs, workspaces)) {
      const at = Math.max(nowS(inner), (held(inner, ws).boxes[device]?.at ?? -1) + 1);
      signed[ws] = sign({ v: 1 as const, ws, device, box, at }, TAG.box, signer);
    }
    return { box, certs: signed };
  });
}

/// Pure synchronous check for `pair.ts` `approve()`: whether handing over vaults to `device` needs `BOX_KEY` unsealed
/// (i.e. at least one owned vault is missing `device`'s key and its master key is not currently unlocked in RAM).
export function needsBoxForHandover(inner: Inner, device: string, subs: readonly string[], workspaces: readonly string[], boxCerts: Record<string, BoxCert> | null | undefined): boolean {
  if (!boxCerts || !able(inner)) return false;
  const signer = signerOf(inner);
  if (signer === null) return false;
  for (const ws of handoverWorkspaces(inner, subs, workspaces)) {
    const cert = boxCerts[ws];
    if (!cert || cert.ws !== ws || cert.device !== device || typeof cert.box !== "string") continue;
    const lock = lockOf(inner, ws);
    if (lock instanceof CoreError) continue;
    const who = me(lock, signer);
    if (who === null) continue;
    if (subs.length > 0 && !subs.includes(who.sub)) continue;
    for (const v of Object.values(held(inner, ws).vaults)) {
      if (v.deleted || !trusted(lock, v) || !canManage(lock, v, who.sub)) continue;
      if (!v.keys.some((k) => k.cert.device === who.device)) continue;
      if (v.keys.some((k) => k.cert.device === device && k.cert.box === cert.box)) continue;
      if (!unlocked(inner, v)) return true;
    }
  }
  return false;
}

export type PreviewHandoverVault = {
  id: string;
  name: string;
  scope: "personal" | "workspace";
  items: number;
  workspace: string;
  workspaceName: string;
};

/// Pure local read-only preview of every vault (personal + workspace) whose key this device currently holds and would
/// hand over to `device` upon approving its pairing request. Triggers no biometrics or network requests.
export function previewHandoverVaults(
  inner: Inner,
  opts: { device: string; subs: readonly string[]; workspaces: readonly string[]; boxCerts: Record<string, BoxCert> | null | undefined },
): PreviewHandoverVault[] {
  if (!opts.boxCerts || !able(inner)) return [];
  const signer = signerOf(inner);
  if (signer === null) return [];
  const out: PreviewHandoverVault[] = [];
  for (const ws of handoverWorkspaces(inner, opts.subs, opts.workspaces)) {
    const cert = opts.boxCerts[ws];
    if (!cert || cert.ws !== ws || cert.device !== opts.device || typeof cert.box !== "string") continue;
    const lock = lockOf(inner, ws);
    if (lock instanceof CoreError) continue;
    const who = me(lock, signer);
    if (who === null) continue;
    if (opts.subs.length > 0 && !opts.subs.includes(who.sub)) continue;
    const wsName = workspaceName(inner, ws);
    for (const v of Object.values(held(inner, ws).vaults)) {
      if (v.deleted || !trusted(lock, v) || !canManage(lock, v, who.sub)) continue;
      if (!v.keys.some((k) => k.cert.device === who.device)) continue;
      if (v.keys.some((k) => k.cert.device === opts.device && k.cert.box === cert.box)) continue;
      const count = Object.values(items(inner, ws, v.id)).filter((i) => !i.deleted).length;
      out.push({
        id: v.id,
        name: v.name,
        scope: v.scope === "workspace" ? "workspace" : "personal",
        items: count,
        workspace: ws,
        workspaceName: wsName,
      });
    }
  }
  out.sort((a, b) => (a.workspace < b.workspace ? -1 : a.workspace > b.workspace ? 1 : a.name < b.name ? -1 : a.name > b.name ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return out;
}

/// After approving `device` into the personal or workspace lock, seals all manageable vaults (personal and workspace)
/// to `device`'s verified `BoxCert` using either RAM-cached keys or the already-unsealed `boxPriv` (zero extra prompts).
export function handoverForApproved(
  inner: Inner,
  opts: { device: string; signKey: string | null; subs: readonly string[]; workspaces: readonly string[]; boxCerts: Record<string, BoxCert> | null | undefined; boxPriv: Uint8Array | null; chains?: Record<string, Entry[]> },
): Effect.Effect<HandedVault[]> {
  const boxCerts = opts.boxCerts;
  const signKey = opts.signKey;
  if (!boxCerts || !signKey || !able(inner)) return Effect.succeed([]);
  return Effect.gen(function* () {
    const signer = yield* Effect.orElseSucceed(Signer.load(inner.host), () => null);
    if (signer === null) return [];
    const handed: HandedVault[] = [];
    for (const ws of handoverWorkspaces(inner, opts.subs, opts.workspaces)) {
      const cert = boxCerts[ws];
      if (!cert || cert.ws !== ws || cert.device !== opts.device || cert.sig?.key !== signKey) continue;
      const ownerSub = inner.workspaces.owner(ws);
      const chain = !safeMode(inner, ws) && ownerSub !== null ? opts.chains?.[ownerSub] : undefined;
      const lock = chain && chain.length > 0
        ? (() => {
            const { memberChains, memberRoles } = personalExtras(inner, ws, ownerSub!);
            return personalChecked(ws, ownerSub!, chain, memberChains, memberRoles);
          })()
        : lockOf(inner, ws);
      if (lock instanceof CoreError) continue;
      const who = me(lock, signer.id);
      if (who === null) continue;
      if (certOwner(lock, cert) !== who.sub) continue;
      const fit = fitsWith(inner, ws, lock);
      change(inner, ws, (h) => {
        if (heldOver(h.boxes[cert.device], cert, fit)) h.boxes[cert.device] = cert;
      });
      for (const s of stationsOf(inner, ws)) {
        inner.runner.fork(Effect.ignore(ask(inner, `${ws}/${s.id}`, "PUT", "/vault/boxes", cert), { log: "Unhandled", message: "vault handover box put" }));
      }
      const vaults = new Vaults(inner, ws, null);
      const wsHanded = yield* Effect.orElseSucceed(vaults.handover(cert, opts.boxPriv, lock, signer), () => [] as HandedVault[]);
      if (wsHanded.length > 0) handed.push(...wsHanded);
      else handed.push({ ws, cert });
    }
    return handed;
  });
}

/// On the newly approved device: verifies and stores the handed-over `BoxCert` and `Vault` records immediately so the
/// vault is ready with zero extra clicks, then enqueues `readStation` to fetch encrypted items and `spreadAll` to push
/// `seq + 1` once stations catch up on the lock.
export function takeHanded(inner: Inner, raw: unknown): void {
  const list = arr(raw);
  if (list.length === 0) return;
  const touched = new Set<string>();
  for (const item of list) {
    const ws = str(get(item, "ws"));
    const cert = get(item, "cert") as BoxCert | undefined;
    if (ws === null || !isObject(cert) || typeof cert.device !== "string") continue;
    const vault = get(item, "vault") as Vault | undefined;
    const fit = fits(inner, ws);
    change(inner, ws, (h) => {
      if (heldOver(h.boxes[cert.device], cert, fit)) h.boxes[cert.device] = cert;
      if (isObject(vault) && typeof vault.id === "string") take(h, vault, fit);
    });
    touched.add(ws);
  }
  if (!inner.scheduler) return;
  for (const ws of touched) {
    spreadAll(inner, ws);
    for (const s of stationsOf(inner, ws)) {
      const address = `${ws}/${s.id}`;
      inner.scheduler.enqueue(address, `${address} vault`, Priority.shown, readStation(inner, address));
    }
  }
}

/// A device (its id) or a member (their sub) this device takes out of workspace `ws`'s lock as a person asked it to, here
/// and now (views/lock.ts `Lock.append`, a call's): keying anew the vaults that held a key for them is part of what they
/// did, so the box key may be read for it once, the person asked (`rekeyGone`). Nothing else keys a vault anew by asking.
export function tookOut(inner: Inner, ws: string, id: string): void {
  const out = mem(inner).out;
  let at = out.get(ws);
  if (at === undefined) out.set(ws, (at = new Set()));
  at.add(id);
}

/// A device this one took off its person's own log at their asking where `ws`'s chain moved (views/lock.ts
/// `takeOffBound`): as `tookOut`, and the vaults that held a key for it keyed anew now (`rekeyGone`), the state in force
/// having no workspace entry whose taking would run it.
export function tookOutMoved(inner: Inner, ws: string, id: string): void {
  tookOut(inner, ws, id);
  if (able(inner)) inner.runner.fork(Effect.ignore(new Vaults(inner, ws, null).rekeyGone(), { log: "Unhandled", message: "vaults keyed anew" }));
}

/// How long a removal waits for the stations holding vaults of this person's to be read before it is signed (a deadline
/// on what a call waits for, as the lock's `ASKED_MS`).
const LEVEL_MS = 3_000;

/// The vaults held of workspace `ws` brought level with the stations that hold them (each read again, as a link that
/// opens reads it), before this device takes a device or a member out at the person's asking: a version the one to be
/// taken out wrote while it was in is taken and checked now, while it is (2026-11-14, the locks' end to end: a device
/// let in again took the one that keyed the vault meanwhile off a fraction of a second after, before it had read that
/// version; after, it could never check it, kept the one before it, and every keying anew it wrote the station refused,
/// `vault_conflict`). At most LEVEL_MS, asking nothing: a station not read holds the removal back no longer
/// (`#rekey` writes past what it holds then).
export function levelVaults(inner: Inner, ws: string, out?: string): Effect.Effect<void> {
  return Effect.suspend(() => {
    if (!able(inner)) return Effect.void;
    const h = held(inner, ws);
    const at = new Set<string>();
    for (const id of Object.keys(h.vaults)) {
      for (const s of Object.keys(h.on[id] ?? {})) at.add(s);
      const host = hostOf(inner, ws, id);
      if (host !== "") at.add(host);
    }
    const reads = Effect.all([...at].map((s) => Effect.ignore(readStation(inner, `${ws}/${s}`), { log: "Unhandled", message: "vault station read" })), { concurrency: "unbounded" });
    const read = at.size === 0 ? Effect.void : Effect.asVoid(Effect.timeoutOption(reads, LEVEL_MS)); // timer: a deadline on what a call waits for
    return Effect.andThen(read, Effect.sync(() => {
      if (out !== undefined && (movedHere(inner, ws) || !safeMode(inner, ws))) keepBefore(inner, ws, out);
    }));
  });
}

/// `levelVaults` of every workspace of person `sub`'s here, as one of their devices (`out`) is taken off their own lock.
export function levelVaultsOf(inner: Inner, sub: string, out?: string): Effect.Effect<void> {
  return Effect.suspend(() => Effect.asVoid(Effect.all([...inner.workspaces.owned()].filter(([, owner]) => owner === sub).map(([ws]) => levelVaults(inner, ws, out)), { concurrency: "unbounded" })));
}

/// Where the chain moved, the state in force just before a removal this device makes (of a device's id or a member's
/// sub), kept for this run by workspace with whom it takes out: a version of a vault that one wrote, which the stations
/// hold and this device had not read before the removal, is checked against it (`#rekey`), so it is taken as on a chain
/// not moved, where the chain as it stood checks it (`waitingAs`'s prefix): the same acceptance, no wider. A signature
/// carries no time; it is this device's own knowledge that the signer was in until the removal it made (the lead,
/// 2026-11-14: a moved workspace does for people what an unmoved one does, 迁过之后和之前一样). Never let go for the rest
/// of the run, on purpose: a chain not moved accepts by any prefix for good, so this side stays as open as that one;
/// tightening one side alone would make the two differ again (the lead, 2026-11-14).
const beforeOut = new WeakMap<Inner, Map<string, { lock: Checked; out: Set<string> }>>();
function keepBefore(inner: Inner, ws: string, out: string): void {
  const lock = lockOf(inner, ws);
  if (lock instanceof CoreError) return;
  let m = beforeOut.get(inner);
  if (m === undefined) beforeOut.set(inner, (m = new Map()));
  const was = m.get(ws);
  m.set(ws, { lock, out: new Set([...(was?.out ?? []), out]) });
}

/// Vault `id` as a station holds it past this device's (`later`), signed by one this device took out (`beforeOut`) and
/// taken by the state just before that removal: taken here, what of that state took it kept (`vaultTook`), so it is
/// read and keyed anew as one waiting to be (`waitingAs`). Whether it was.
function takeBefore(inner: Inner, ws: string, id: string): boolean {
  const theirs = held(inner, ws).later?.[id];
  const kept = beforeOut.get(inner)?.get(ws);
  if (theirs === undefined || kept === undefined || !trusted(kept.lock, theirs)) return false;
  const key = theirs.sig?.key ?? "";
  const signer = [...kept.lock.devices.values()].find((d) => d.sign_key === key || (kept.lock.signKeys.get(d.id) ?? []).includes(key));
  if (signer === undefined || !(kept.out.has(signer.id) || kept.out.has(signer.sub))) return false;
  change(inner, ws, (h) => {
    h.vaults[id] = theirs;
    if (h.later !== undefined) delete h.later[id];
  });
  const took = tookHeld(inner, ws);
  inner.data.put("vaultTook", ws, { took: { ...took, [id]: { ...(took[id] ?? {}), [String(theirs.epoch)]: sliceOf(kept.lock, theirs) } } });
  return true;
}

/// The keys unsealed here given to the members' devices set up that have none (the vaults of this person's own):
/// forked, nothing asked of the person (`Vaults.giveKept`).
function giveKept(inner: Inner, ws: string): void {
  if (!able(inner)) return;
  inner.runner.fork(Effect.ignore(new Vaults(inner, ws, null).giveKept(), { log: "Unhandled", message: "vault keys given" }));
}

/// The items left under an earlier key of each vault that has any written again under its key with the keys
/// unsealed here: forked, nothing asked of the person (`Vaults.carryOn`). As a station is read again (its connection
/// opened), not as each vault or item is told: that would race the device keying a vault anew, item by item.
function carryKept(inner: Inner, ws: string): void {
  if (!able(inner)) return;
  const h = held(inner, ws);
  const ids = Object.values(h.vaults).filter((v) => !v.deleted && h.before?.[v.id] !== undefined && underEarlier(inner, ws, v).length > 0).map((v) => v.id);
  if (ids.length === 0) return;
  const vaults = new Vaults(inner, ws, null);
  inner.runner.fork(Effect.forEach(ids, (id) => Effect.ignore(vaults.carryOn(id, null), { log: "Unhandled", message: "vault items carried on" }), { discard: true }));
}

/// The items of vault `v` held here still under an earlier key than its own (not deleted).
const underEarlier = (inner: Inner, ws: string, v: Vault): Item[] => Object.values(items(inner, ws, v.id)).filter((i) => !i.deleted && i.epoch < v.epoch);

/// Resolves a device's kind and human-readable label across safe-mode workspace lock, this person's own chain, and
/// station-cached teammate personal chains (`held.memberChains`). Never throws.
function deviceLabelOf(inner: Inner, ws: string, deviceId: string, sub: string): { kind: string; label: string } {
  const d = stateOf(inner, ws).devices.get(deviceId);
  if (d !== undefined) return { kind: str(d.kind) ?? "app", label: str(d.label) ?? "" };
  try {
    const personal = inner.adb.personal();
    if (typeof personal.signKeys === "function") {
      const own = personal.signKeys(sub).get(deviceId);
      if (own !== undefined) return { kind: "app", label: own.label };
    }
    if (typeof personal.chain === "function") {
      const ownChain = personal.chain(sub);
      if (ownChain !== null) {
        for (const dev of ownChain.devices.values()) {
          if (dev.id === deviceId) return { kind: "app", label: dev.label };
        }
      }
    }
  } catch {
    // ignore if personal lock is unavailable
  }
  const chainEntries = held(inner, ws).memberChains?.[sub];
  if (Array.isArray(chainEntries) && chainEntries.length > 0) {
    try {
      const chain = checkChain(chainEntries, sub);
      if (chain !== null) {
        for (const dev of chain.devices.values()) {
          if (dev.id === deviceId) return { kind: "app", label: dev.label };
        }
      }
    } catch {
      // ignore malformed teammate chain
    }
  }
  return { kind: "app", label: "" };
}

/// Resolves member display name and email from the workspace view, falling back to the workspace lock's member map.
function memberInfoOf(inner: Inner, ws: string): (sub: string) => { ownerName: string; ownerEmail: string | undefined } {
  const people = new Map<string, J>(arr(get(workspaceView(inner, ws), "members")).map((p) => [p.sub, p]));
  const lockMembers = stateOf(inner, ws).members;
  return (sub: string) => {
    const p = people.get(sub);
    const lm = lockMembers.get(sub);
    const email = str(get(p, "email")) || str(get(lm, "email")) || "";
    const name = str(get(p, "name")) || email || sub;
    return { ownerName: name, ownerEmail: email || undefined };
  };
}

/// The `lockPrompts` topic's `asks` (views/lock.ts promptsView: the topic every page has open, and every recorded
/// run of the app asks; a topic of its own would be asked by none of them): in every workspace of the person's, the
/// members' devices set up (their certificates the lock vouches for) that hold no key to a vault of this person's own
/// that this device holds the key to (so can give it: `vault.addDevice {vault, device}`), the latest asking first; not
/// those put away (`vault.hidePrompt`), until they ask again (`vault.ask`: a certificate published anew). None where
/// this app keeps no keys.
export function vaultAsks(inner: Inner): J[] {
  const asks: J[] = [];
  if (!able(inner)) return asks;
  const now = clockOf(inner);
  for (const ws of workspaceIds(inner.views?.ok({ topic: "workspaces" }))) {
    const lock = lockOf(inner, ws);
    if (lock instanceof CoreError) continue;
    const self = me(lock, signerOf(inner));
    if (self === null) continue;
    const h = held(inner, ws);
    const vouched = certs(inner, ws, lock);
    const mine = vouched.find((c) => c.device === self.device);
    if (mine === undefined) continue;
    const safe = safeMode(inner, ws);
    const memberOf = memberInfoOf(inner, ws);
    for (const v of Object.values(h.vaults)) {
      if (v.deleted || !trusted(lock, v) || !canManage(lock, v, self.sub)) continue;
      const keyed = new Map(v.keys.map((k) => [k.cert.device, k.cert.box]));
      if (keyed.get(self.device) !== mine.box) continue;
      const vaultScope = v.scope === "workspace" ? "workspace" : "personal";
      const vaultItems = Object.values(items(inner, ws, v.id)).filter((i) => !i.deleted).length;
      for (const c of vouched) {
        if (!v.members.includes(c.sub) || keyed.get(c.device) === c.box || (h.hidden[c.device] ?? -1) >= c.at) continue;
        const dev = deviceLabelOf(inner, ws, c.device, c.sub);
        const info = memberOf(c.sub);
        const code = deviceVerifyCode(c.device);
        asks.push({
          workspace: ws, workspaceName: workspaceName(inner, ws), vault: v.id, vaultName: v.name, device: c.device,
          deviceText: deviceText(dev),
          ...(code ? { deviceCode: code } : {}),
          ownerName: info.ownerName,
          ...(info.ownerEmail ? { ownerEmail: info.ownerEmail } : {}),
          isOwnDevice: c.sub === self.sub,
          vaultScope,
          vaultItems,
          safeMode: safe,
          at: c.at, atText: str(stamp(c.at * 1000, now).ago) ?? "",
        });
      }
    }
  }
  asks.sort((a, b) => b.at - a.at || (a.device < b.device ? -1 : 1));
  return asks;
}

/// The `vaults` topic.
export function vaultsView(inner: Inner, ws: string): J {
  const h = held(inner, ws);
  const lock = lockOf(inner, ws);
  const m = mem(inner);
  const sub = inner.workspaces.owner(ws);
  const memberOf = memberInfoOf(inner, ws);
  const nameOf = (s: string) => memberOf(s).ownerName;
  const stationName = new Map(stationsOf(inner, ws).map((s) => [s.id, s.name]));
  const safe = safeMode(inner, ws);
  const clock = clockOf(inner);
  const thisDeviceText = deviceText({ kind: inner.host.appKeys ? "app" : "web", label: prefs.deviceName(inner.data) ?? "" });
  const baseDeviceId = inner.meshNow()?.deviceId() ?? baseOf(inner);
  const baseCode = baseDeviceId ? deviceVerifyCode(baseDeviceId) : "";
  // (no safe mode, a station that keeps no vault for want of it is one from before: every station now keeps a vault by
  // its members' own locks, station/src/cloud/vault-lock.ts; said as old, never as safe mode wanting)
  // (only of stations the workspace has now: one taken out stays in `refused`, nothing reading it again to say otherwise)
  const refusedRows = Object.entries(h.refused).filter(([id]) => stationName.has(id)).map(([id, code]) => ({ station: id, name: stationName.get(id) ?? "", code: !safe && code === "vault_needs_lock" ? "station_old" : code }));
  // (`locked`: whether the workspace is in safe mode, as the `lock` topic says it; the vault is encrypted either way)
  const base = {
    available: able(inner), locked: safe && !(lock instanceof CoreError), canSign: false, setUp: false, vaults: [] as J[], requests: [] as J[], refused: refusedRows,
    ...(baseCode ? { thisDeviceCode: baseCode } : {}),
    thisDeviceText,
  };
  const plainItems = Object.values(h.plain).filter((i) => !i.deleted);
  const requestRow = (r: Request, itemName: string | null, vaultName: string, lasts: Scope) => ({
    id: r.id, vault: r.vault, vaultName, item: r.item, itemName, lasts,
    session: r.session, chat: r.chat, station: h.asked[r.id] ?? null, mode: r.mode, reason: r.reason, command: r.command ?? null, hosts: r.hosts ?? [], at: r.at, ...(r.timeout ? { timeoutKind: r.timeout.kind, timeoutSeconds: r.timeout.seconds } : {}),
    howText: r.browse !== undefined ? "" : r.describe ? describeText(itemName ?? r.describe.was.name, { name: r.describe.name, about: r.describe.about, wasAbout: r.describe.was.about }) : r.save?.about ? aboutText(r.save.about) : howText(r.mode, r.hosts ?? []),
    // A secret an agent asks to keep: what kind, the account it is for, whether the person types it in.
    ...(r.save ? { save: { kind: r.save.kind, ...(r.save.username ? { username: r.save.username } : {}), ...(r.save.filename ? { filename: r.save.filename } : {}), ...(r.save.typed ? { typed: true } : {}), ...(r.save.oauth ? { oauth: r.save.oauth } : {}), ...(r.save.vaultName ? { vaultName: r.save.vaultName } : {}), ...(r.save.shared ? { shared: true } : {}) } } : {}),
    // An item to rename or say what it is: its name and about as they would be (and its about as it was).
    ...(r.describe ? { describe: { name: r.describe.name, about: r.describe.about, wasAbout: r.describe.was.about } } : {}),
    // An item to delete.
    ...(r.remove ? { remove: true } : {}),
    ...(r.browse !== undefined ? { browse: r.browse } : {}),
    ...(r.cross !== undefined ? { cross: r.cross } : {}),
  });
  const personal = t("core-misc.vault.personal");
  // Security mode on and its lock not checking out here: no plain library and nothing signed (a lock that does not
  // check out is never taken for one turned off). No words of its own: the page's not-signer card, whose press leads
  // to 安全 where the lock's state is said (its message is the core's own English, never a person's words).
  if (lock instanceof CoreError && safe) return { ...base, locked: true, ...statusWords([], []) };
  // No safe mode and this device not on its person's own lock (another device of theirs approves it) or that lock
  // replaced: nothing signed here; the page offers being approved (or going on as the one that replaced it).
  if (lock instanceof CoreError) return { ...base, ...statusWords([], []) };
  const self = me(lock, signerOf(inner));
  const vouched = certs(inner, ws, lock);
  const mine = self ? vouched.find((c) => c.device === self.device) : undefined;
  const myDeviceId = self?.device ?? baseDeviceId;
  const thisDeviceCode = myDeviceId ? deviceVerifyCode(myDeviceId) : "";
  const deviceRow = (device: string, devSub: string, at: number) => {
    const info = memberOf(devSub);
    const dev = deviceLabelOf(inner, ws, device, devSub);
    return {
      device,
      deviceText: deviceText(dev),
      deviceCode: deviceVerifyCode(device),
      ownerName: info.ownerName,
      ...(info.ownerEmail ? { ownerEmail: info.ownerEmail } : {}),
      current: self !== null && device === self.device,
      at,
      atText: str(stamp(at * 1000, clock).ago) ?? "",
    };
  };
  const vaults = Object.values(h.vaults)
    // (one waiting to be keyed anew too, where this device holds a key of it: readAs)
    .filter((v) => sub !== null && v.members.includes(sub) && readAs(inner, ws, lock, v, self) !== null)
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : a.id < b.id ? -1 : 1))
    .map((v) => {
      const readLock = readAs(inner, ws, lock, v, self);
      const keyed = new Map(v.keys.map((k) => [k.cert.device, k.cert.box]));
      const all = Object.values(items(inner, ws, v.id)).filter((i) => !i.deleted);
      const authorizedDevices = v.keys
        .map((k) => {
          const devSub = lock.devices.get(k.cert.device)?.sub ?? readLock?.devices.get(k.cert.device)?.sub ?? stateOf(inner, ws).devices.get(k.cert.device)?.sub ?? "";
          return deviceRow(k.cert.device, devSub, k.cert.at);
        })
        .sort((a, b) => Number(b.current) - Number(a.current) || b.at - a.at || (a.device < b.device ? -1 : a.device > b.device ? 1 : 0));
      const pendingDevices = vouched
        .filter((c) => v.members.includes(c.sub) && keyed.get(c.device) !== c.box)
        .map((c) => deviceRow(c.device, c.sub, c.at))
        .sort((a, b) => b.at - a.at || (a.device < b.device ? -1 : a.device > b.device ? 1 : 0));
      return {
        id: v.id, name: v.name, owner: v.owner, ownerName: nameOf(v.owner), mine: v.owner === sub,
        scope: v.scope === "workspace" ? "workspace" : "personal",
        manages: sub !== null && canManage(lock, v, sub),
        members: v.members.map((s) => ({ sub: s, name: nameOf(s) })),
        station: hostOf(inner, ws, v.id), stationName: stationName.get(hostOf(inner, ws, v.id)) ?? "",
        items: all.length, devices: v.keys.length, open: unlocked(inner, v),
        // Whether this device has a key to it; members' devices set up since that have none yet (its owner's device gives
        // them the key as it next has it in hand, or as asked: addDevice).
        // (by the box key kept here too: a certificate naming one made anew since is not this device's key, FB-51)
        keyed: self !== null && mine !== undefined && mine.box === m.box && keyed.get(self.device) === mine.box,
        missing: pendingDevices.length,
        recoverable: v.recovery !== undefined, lasts: v.lasts ?? "chat",
        authorizedDevices,
        pendingDevices,
        // (said only while it waits to be keyed anew: a row that does not wait is as it was)
        ...(waitingAs(inner, ws, lock, v) !== null ? { waits: waitsOn(inner, ws, v) } : {}),
      };
    });
  // (a secret to keep is told only to whom it is for: it may be meant for no vault yet; none of the plain library's, which
  // safe mode on has none of)
  const setUp = mine !== undefined && mine.box === m.box;
  const plain = plainMode(inner, ws);
  let activeVaults: Vault[] | undefined;
  const activeMemberVaults = (): Vault[] =>
    (activeVaults ??= self === null ? [] : Object.values(h.vaults).filter((v) => !v.deleted && trusted(lock, v) && v.members.includes(self.sub)));
  let browseCache: BrowseCandidates | undefined;
  const browseCounts = (): { browseWorkspaces: number; browseItems: number; noKey?: true } => {
    const cands = (browseCache ??= browseCandidates(inner, ws));
    const browseItems = cands.workspaces.reduce((n, w) => n + w.items.length, 0);
    return {
      browseWorkspaces: cands.workspaces.length,
      browseItems,
      ...(browseItems === 0 && cands.unkeyedWorkspaces > 0 ? { noKey: true as const } : {}),
    };
  };
  const requests = Object.values(h.requests)
    .filter((r) => r.status === "pending" && r.vault !== PLAIN && (r.save !== undefined || r.browse !== undefined || r.cross !== undefined || (h.vaults[r.vault] !== undefined && !h.vaults[r.vault]!.deleted && sub !== null && h.vaults[r.vault]!.members.includes(sub))))
    .sort((a, b) => a.at - b.at)
    .map((r) => {
      if (r.browse !== undefined) {
        return { ...requestRow(r, null, personal, "chat"), ...browseCounts() };
      }
      if (r.cross !== undefined) {
        const srcWs = r.cross.workspace;
        const otherOwner = inner.workspaces.owner(srcWs);
        const hA = held(inner, srcWs);
        const listingA = items(inner, srcWs, r.vault)[r.item]?.listing;
        const lockA = lockOf(inner, srcWs);
        const selfA = lockA instanceof CoreError ? null : me(lockA, signerOf(inner));
        const vA = hA.vaults[r.vault];
        const crossNoKey =
          otherOwner === null ||
          lockA instanceof CoreError ||
          self === null ||
          selfA === null ||
          selfA.sub !== otherOwner ||
          m.box === null ||
          m.box === undefined ||
          vA === undefined ||
          vA.deleted ||
          vA.scope === "workspace" ||
          vA.owner !== otherOwner ||
          readAs(inner, srcWs, lockA, vA, selfA) === null ||
          !vA.keys.some((k) => k.cert.device === selfA.device && k.cert.box === m.box);
        return {
          ...requestRow(r, listingA?.name ?? null, r.cross.vaultName, listingA?.lasts ?? vA?.lasts ?? "chat"),
          ...(crossNoKey ? { noKey: true } : {}),
        };
      }
      const listing = items(inner, ws, r.vault)[r.item]?.listing;
      const isSave = r.save !== undefined || r.describe !== undefined || r.remove !== undefined;
      const noKey = !plain && vaultNoKey(lock, h, self, mine, m.box, r, isSave, () => setUp, activeMemberVaults);
      return {
        ...requestRow(r, r.save?.name ?? r.describe?.was.name ?? r.remove?.name ?? listing?.name ?? null, h.vaults[r.vault]?.name ?? personal, listing?.lasts ?? h.vaults[r.vault]?.lasts ?? "chat"),
        ...(notHere(r, self?.device ?? null, m.box ?? null) ? { notHere: true } : {}),
        ...(noKey ? { noKey: true } : {}),
      };
    });
  // What is left of the plain library from before security mode, to be moved into the person's vault.
  // (no signer here for a reason of its own: its words, and the press that ends it where one does)
  const why = self === null ? whyNot(inner, ws) : null;
  // (no safe mode, their own lock begun nowhere yet: 开启 begins it with this device on it, `Vaults.setup`)
  const begins = self === null && why === null && able(inner) && personalNone(inner, ws);
  const hasWorkspaceVault = Object.values(h.vaults).some((v) => !v.deleted && v.scope === "workspace" && (trusted(lock, v) || waitingAs(inner, ws, lock, v) !== null));
  const canCreateWorkspace = setUp && self !== null && isWorkspaceAdmin(lock, self.sub) && !hasWorkspaceVault;
  return {
    ...base,
    ...(thisDeviceCode ? { thisDeviceCode } : {}),
    canSign: self !== null || begins, ...(why !== null ? { stateText: why.text, ...(why.confirm ? { confirmText: t("core-misc.vault.confirm") } : {}) } : {}), setUp, canCreateWorkspace, vaults, requests, ...statusWords(vaults, requests), ...(plainItems.length > 0 ? { plainLeft: plainItems.length } : {}),
  };
}

const clockOf = (inner: Inner) => {
  const now = inner.host.nowMs();
  return { now, offsetMin: inner.host.utcOffsetMin(now) };
};

/// A vault's uses (any station's, for the plain library), the latest first, as the pages show them.
/// For a personal vault, also merges cross-workspace uses from other same-account workspaces.
function usesOf(inner: Inner, ws: string, vault: string): J[] {
  const h = held(inner, ws);
  const clock = clockOf(inner);
  const combined: (Use & { station: string; workspace?: string; workspaceName?: string })[] = Object.entries(h.uses)
    .filter(([k]) => k.slice(k.indexOf("/") + 1) === vault)
    .flatMap(([k, list]) => list.map((u) => ({ ...u, station: k.slice(0, k.indexOf("/")) })));
  const v = h.vaults[vault];
  const ownerSub = inner.workspaces?.owner(ws) ?? null;
  if (v !== undefined && v.scope !== "workspace" && ownerSub !== null && v.owner === ownerSub) {
    for (const [otherWs] of inner.workspaces.owned()) {
      if (otherWs === ws) continue;
      const crossUses = held(inner, otherWs).crossUses;
      if (!isObject(crossUses)) continue;
      const otherName = workspaceName(inner, otherWs);
      for (const [st, list] of Object.entries(crossUses)) {
        for (const u of list ?? []) {
          if (u.sourceWorkspace === ws && u.sourceVault === vault) {
            combined.push({
              item: u.item,
              at: u.at,
              session: u.session,
              station: st,
              chatTitle: u.chatTitle ?? null,
              mode: u.mode,
              command: u.command ?? null,
              hosts: u.hosts ?? [],
              denied: u.denied === true,
              workspace: otherWs,
              workspaceName: otherName,
            });
          }
        }
      }
    }
  }
  return combined
    .sort((a, b) => b.at - a.at)
    .map((u) => ({
      item: u.item, at: stamp(u.at * 1000, clock), session: u.session, station: u.station, chatTitle: u.chatTitle, mode: u.mode, command: u.command, hosts: u.hosts,
      // how, in a line: the command it ran (and its way), else how it was given
      howText: typeof u.command === "string" && u.command !== "" ? `${u.command} · ${modeText(u.mode)}` : howText(u.mode, u.hosts ?? []),
      ...(u.denied ? { denied: true } : {}),
      ...(u.workspace !== undefined ? { workspace: u.workspace, workspaceName: u.workspaceName } : {}),
    }));
}

/// The `vaultUses` topic.
export function usesView(inner: Inner, ws: string, vault: string, item: string): J {
  return { item, uses: usesOf(inner, ws, vault).filter((u) => u.item === item).map(({ item: _, ...u }) => u) };
}

/// The last use of each item of a vault (granted ones only: a refusal is no use).
function lastUses(inner: Inner, ws: string, vault: string): Map<string, J> {
  const last = new Map<string, J>();
  for (const u of usesOf(inner, ws, vault)) if (!u.denied && !last.has(u.item)) last.set(u.item, (({ item: _, ...rest }) => rest)(u));
  return last;
}

/// The plain library's items, as a vault's (their fields only when opened).
function plainItemsView(inner: Inner, ws: string): J {
  const last = lastUses(inner, ws, PLAIN);
  const list = Object.values(held(inner, ws).plain)
    .filter((i) => !i.deleted)
    .map((i) => ({
      id: i.id, version: i.version, at: i.at, name: i.name, kind: i.kind, ...(i.notes ? { about: i.notes } : {}),
      listed: i.listing !== undefined, modes: i.listing?.modes ?? [], hosts: i.listing?.hosts ?? [], env: i.listing?.env ?? null, lasts: i.listing?.lasts ?? null,
      ...(last.has(i.id) ? { lastUse: last.get(i.id) } : {}),
    }))
    .map((r) => ({ ...r, ...itemWords(r, held(inner, ws).plainLasts?.lasts) }))
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : a.id < b.id ? -1 : 1));
  return { vault: PLAIN, name: t("core-misc.vault.personal"), open: true, items: list };
}

/// The `vaultItems` topic: a vault's items, their names once it is unlocked here (else the listing's, if any).
export function itemsView(inner: Inner, ws: string, id: string): J {
  if (id === PLAIN) return plainMode(inner, ws) ? plainItemsView(inner, ws) : { vault: PLAIN, name: "", open: false, items: [] };
  const last = lastUses(inner, ws, id);
  const v = held(inner, ws).vaults[id];
  const lock = lockOf(inner, ws);
  // (one waiting to be keyed anew too, where this device holds a key of it: readAs)
  if (!v || lock instanceof CoreError || readAs(inner, ws, lock, v, me(lock, signerOf(inner))) === null) return { vault: id, name: "", open: false, items: [] };
  const key = unlocked(inner, v) ? mem(inner).keys.get(keyOf(v))!.key : null;
  const list = Object.values(items(inner, ws, id))
    .filter((i) => !i.deleted)
    .map((i) => {
      let plain: Plain | null = null;
      if (key && i.epoch === v.epoch) {
        try {
          plain = JSON.parse(new TextDecoder().decode(decrypt(key, i.ct, itemContext(ws, id, i.id, i.version, i.epoch)))) as Plain;
        } catch {
          plain = null;
        }
      }
      return {
        id: i.id, version: i.version, at: i.at,
        name: str(plain?.name) ?? i.listing?.name ?? null, kind: str(plain?.kind) ?? i.listing?.kind ?? null,
        ...((str(plain?.notes) || i.listing?.about) ? { about: str(plain?.notes) || i.listing?.about } : {}),
        listed: i.listing !== undefined, modes: i.listing?.modes ?? [], hosts: i.listing?.hosts ?? [], env: i.listing?.env ?? null, lasts: i.listing?.lasts ?? null,
        ...(last.has(i.id) ? { lastUse: last.get(i.id) } : {}),
      };
    })
    .map((r) => ({ ...r, ...itemWords(r, v.lasts) }))
    .sort((a, b) => ((a.name ?? "") < (b.name ?? "") ? -1 : (a.name ?? "") > (b.name ?? "") ? 1 : a.id < b.id ? -1 : 1));
  return { vault: id, name: v.name, open: key !== null, items: list };
}

// ── what a person does ──

function run(inner: Inner, c: Of, ctx: SpanContext | null): Effect.Effect<unknown, CoreError> {
  const v = new Vaults(inner, c.workspace, ctx);
  const p = (k: string) => str(c.params[k]) ?? "";
  switch (c.name) {
    case "state":
      return Effect.succeed(vaultsView(inner, c.workspace));
    case "lock":
      return Effect.sync(() => {
        mem(inner).keys.clear();
        changed(inner, c.workspace);
        return null;
      });
    case "setup":
      return v.setup();
    case "create": {
      const scopeRaw = str(c.params.scope);
      if (scopeRaw !== null && scopeRaw !== "personal" && scopeRaw !== "workspace") {
        return Effect.fail(CoreError.invalid("scope: personal or workspace"));
      }
      const members = Array.isArray(c.params.members) ? c.params.members.filter((x): x is string => typeof x === "string") : undefined;
      return v.create(p("name"), str(c.params.station), {
        ...(scopeRaw ? { scope: scopeRaw } : {}),
        ...(members !== undefined ? { members } : {}),
      });
    }
    case "delete":
      return v.delete(p("vault"));
    case "addDevice":
      return v.addDevice(p("vault"), str(c.params.device));
    case "setMembers":
      return v.setMembers(p("vault"), arr(c.params.members).filter((x): x is string => typeof x === "string"));
    case "ask":
      return v.ask();
    case "hidePrompt":
      return v.hidePrompt(p("device"), typeof c.params.at === "number" ? c.params.at : null);
    case "prompts":
      return Effect.succeed({ asks: vaultAsks(inner) });
    case "putItem":
      return p("vault") === PLAIN ? v.putPlain(str(c.params.id), c.params.plain, c.params.listing) : v.putItem(p("vault"), str(c.params.id), c.params.plain, c.params.listing);
    case "deleteItem":
      return p("vault") === PLAIN ? v.deletePlain(p("item")) : v.deleteItem(p("vault"), p("item"));
    case "oauthBegin":
      return oauth.begin(inner, c.workspace, p("vault"), p("provider"), p("back"), p("request"));
    case "oauthComplete":
      return oauth.complete(
        inner,
        c.workspace,
        p("query"),
        (vault, plain, listing) => (vault === PLAIN ? v.putPlain(null, plain, listing) : v.putItem(vault, null, plain, listing)),
        (request, token) => v.approve(request, "once", { secret: token }),
      );
    case "open":
      // (with its fields as its page shows them, and its kind in a word)
      return (held(inner, c.workspace).plain[p("item")] ? v.openPlain(p("item")) : v.open(p("item"))).pipe(
        Effect.map((o) => ({ ...(o as J), shown: shownFields(get(o, "plain")), kindText: kindText(get(get(o, "plain"), "kind")) })),
      );
    case "migrate":
      return v.migrate();
    case "recover":
      return v.recover(p("words"));
    case "browseCandidates":
      return Effect.succeed(browseCandidates(inner, c.workspace));
    case "approve": {
      const selected = Array.isArray(c.params.items)
        ? (c.params.items as unknown[]).filter(
            (x): x is { workspace: string; vault: string; item: string } =>
              isObject(x) && typeof x.workspace === "string" && typeof x.vault === "string" && typeof x.item === "string",
          )
        : undefined;
      return v.approve(p("request"), (str(c.params.scope) ?? "once") as Scope, c.params.typed, c.params.timeout, str(c.params.vault) ?? undefined, selected);
    }
    case "deny":
      return v.deny(p("request"));
    case "setLasts":
      return v.setLasts(p("vault"), p("lasts"));
    default:
      return Effect.fail(CoreError.invalid(`no vault call ${c.name}`));
  }
}

const KINDS = ["token", "ssh_key", "login", "file", "browser"];
/// The most an item's about may be, its characters (the station's ABOUT_MOST).
const ABOUT_MOST = 2000;
const MODES = ["proxy", "ssh", "env", "file", "browser"];
/// The most a file kept may be, its bytes (the station's FILE_MOST): one credential's file, not a store of files.
const FILE_MOST = 64 * 1024;

/// Why a file's fields are not one (its content its bytes in base64, FILE_MOST of them at most; its name a name), or
/// null.
function fileProblem(fields: Record<string, string>): CoreError | null {
  const bytes = fileBytes(fields.content ?? "");
  if (bytes === null || bytes.length === 0) return CoreError.invalid("a file's content is its bytes in base64");
  if (bytes.length > FILE_MOST) return new CoreError("vault_file_too_big", t("core-misc.vault.fileTooBig", { most: "64 KB" }));
  const name = fields.filename;
  if (name !== undefined && (name.length > 200 || /[/\\\0]/.test(name) || name === "." || name === "..")) return CoreError.invalid("a file's name is a name, not a path");
  return null;
}

/// An item's plaintext as a call gives it: its kind and name, its fields as words.
function plainOf(v: unknown): Plain {
  if (!isObject(v) || !KINDS.includes(v.kind as string) || typeof v.name !== "string") throw CoreError.invalid("plain: {kind: token|ssh_key|login|file|browser, name, fields, domains, notes}");
  const fields: Record<string, string> = {};
  for (const [k, x] of Object.entries(isObject(v.fields) ? v.fields : {})) if (typeof x === "string") fields[k] = x;
  const bad = v.kind === "file" ? fileProblem(fields) : null;
  if (bad !== null) throw bad;
  return { kind: v.kind as Plain["kind"], name: v.name, fields, domains: arr(v.domains).filter((d) => typeof d === "string"), notes: typeof v.notes === "string" ? v.notes : "" };
}

function listingOf(v: unknown): Listing | undefined {
  if (v === undefined || v === null) return undefined;
  if (!isObject(v) || typeof v.name !== "string" || !KINDS.includes(v.kind as string)) throw CoreError.invalid("listing: {name, kind, modes, hosts, env?}");
  const modes = arr(v.modes).filter((m) => MODES.includes(m));
  const lasts = SCOPES.find((s) => s === v.lasts);
  const about = typeof v.about === "string" ? v.about.trim() : "";
  if (about.length > ABOUT_MOST) throw new CoreError("vault_about_long", t("core-misc.vault.aboutTooLong", { most: String(ABOUT_MOST) }));
  return { name: v.name, kind: v.kind as Listing["kind"], modes, hosts: arr(v.hosts).filter((x) => typeof x === "string"), ...(typeof v.env === "string" ? { env: v.env } : {}), ...(lasts ? { lasts } : {}), ...(about ? { about } : {}) };
}

/// What the person typed in for a secret an agent asked to keep (`typed: {secret, username?}`; a file picked, `{secret:
/// its bytes in base64, filename}`), as the item's fields: as the vault's editor writes them (a token's trimmed, a
/// private key's ending in its line, a password as typed; a login's account the agent's, else the one typed; a file's
/// name the one the agent gave, else its own); undefined when there is no secret in it, why not where a file is not one.
function typedFields(s: Save, typed: unknown): Record<string, string> | CoreError | undefined {
  const secret = isObject(typed) && typeof typed.secret === "string" ? typed.secret : "";
  if (secret.trim() === "") return undefined;
  if (s.kind === "file") {
    const filename = s.filename ?? (isObject(typed) && typeof typed.filename === "string" ? typed.filename.trim() : "");
    const fields = { content: secret, ...(filename ? { filename } : {}) };
    return fileProblem(fields) ?? fields;
  }
  if (s.kind === "token") return { value: secret.trim() };
  if (s.kind === "ssh_key") return { private_key: secret.trim() + "\n", ...(s.public_key ? { public_key: s.public_key } : {}) };
  const username = s.username ?? (isObject(typed) && typeof typed.username === "string" ? typed.username.trim() : "");
  return { ...(username ? { username } : {}), password: secret };
}

class Vaults {
  readonly #inner: Inner;
  readonly ws: string;
  readonly #ctx: SpanContext | null;

  constructor(inner: Inner, ws: string, ctx: SpanContext | null) {
    this.#inner = inner;
    this.ws = ws;
    this.#ctx = ctx;
  }

  #station(station: string, method: string, path: string, body: unknown) {
    return this.#inner.stations.requests.call(new StationAddr(this.ws, station), method, path, body, { ctx: this.#ctx });
  }

  /// What every vault call needs: an app keeping keys, the workspace's lock (checked), this app's signing key in it.
  #ready(): Effect.Effect<{ lock: Checked; signer: Signer; self: { device: string; sub: string } }, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      if (!able(inner)) return yield* fail("vault_unavailable", t("core-misc.vault.unavailable"));
      const lock = lockOf(inner, self.ws);
      if (lock instanceof CoreError) return yield* Effect.fail(lock);
      const signer = yield* Signer.load(inner.host);
      const who = signer ? me(lock, signer.id) : null;
      // (in the lock, signing with this app's key, but put in under this person's name by someone else)
      if (signer && !who && [...lock.devices.values()].some((d) => d.kind === "app" && d.sign_key === signer.id)) return yield* fail("vault_not_own", t("core-misc.vault.notOwn"));
      if (!signer || !who) {
        const why = whyNot(inner, self.ws);
        return yield* (why !== null ? fail(why.code, why.text) : fail("vault_not_signer", t("core-misc.vault.notSigner")));
      }
      return { lock, signer, self: who };
    });
  }

  /// Vault `id` to be changed: one waiting to be keyed anew (`waitingAs`) is refused, saying the station it waits for.
  #vault(lock: Checked, id: string): Effect.Effect<Vault, CoreError> {
    const v = held(this.#inner, this.ws).vaults[id];
    if (!v || v.deleted) return fail("vault_unknown", t("core-misc.vault.unknown"));
    if (trusted(lock, v)) return Effect.succeed(v);
    if (waitingAs(this.#inner, this.ws, lock, v) !== null) return Effect.fail(waitingError(this.#inner, this.ws, v));
    return fail("vault_unknown", t("core-misc.vault.unknown"));
  }

  /// Vault `id` to have an item written in it by this device (`who`): `#vault`, but one waiting to be keyed anew whose
  /// owner this device's person is, its key in hand here, is keyed anew first (`#rekey`, awaited: the key in hand only,
  /// never the box key read for it) and then written in. The lead's decision, 2026-11-14 (the locks' end to end on real
  /// stations: an item opened, so its vault's key in hand and the keying anew set going, then written at once, was
  /// refused `vault_waiting`, telling the owner to wait for their own device). Any other device, or none in hand: as
  /// `#vault` says.
  #writable(lock: Checked, id: string, who: { sub: string; device: string }): Effect.Effect<Vault, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const v = held(inner, self.ws).vaults[id];
      const inHand = v !== undefined && (mem(inner).keys.get(keyOf(v))?.until ?? 0) > inner.host.nowMs();
      if (v !== undefined && !v.deleted && !trusted(lock, v) && canManage(lock, v, who.sub) && inHand && v.keys.some((k) => k.cert.device === who.device) && waitingAs(inner, self.ws, lock, v) !== null) {
        // (a station that takes no write keys nothing anew: waited for a while, then refused as before, naming it)
        yield* Effect.timeoutOption(self.#rekey(v.id, v.seq), REKEY_WAIT_MS); // timer: a deadline
      }
      return yield* self.#vault(lock, id);
    });
  }

  /// Vault `id` to be read, and the lock it is read by (`readAs`: one waiting to be keyed anew, as the lock took it).
  #readable(lock: Checked, id: string, self: { device: string }): Effect.Effect<{ v: Vault; as: Checked }, CoreError> {
    const v = held(this.#inner, this.ws).vaults[id];
    const as = v === undefined ? null : readAs(this.#inner, this.ws, lock, v, self);
    if (!v || as === null) return fail("vault_unknown", t("core-misc.vault.unknown"));
    return Effect.succeed({ v, as });
  }

  /// This device's box key, read from the secure storage (the person asked, saying `reason`).
  /// One the system can no longer open (`key_invalidated`) is made anew (`renewBoxKey`), and the person told the way back.
  #boxKey(reason: string): Effect.Effect<Uint8Array, CoreError> {
    const inner = this.#inner;
    return Effect.gen(function* () {
      const kept = yield* Effect.orElseSucceed(inner.host.storageGet(BOX_PUB), () => null);
      const got = yield* Effect.result(inner.host.secureGet!(BOX_KEY, { user: true, reason }));
      if (got._tag === "Failure") {
        if (got.failure.message !== "key_invalidated") return yield* Effect.fail(CoreError.refused(got.failure, "vault_refused"));
        yield* renewBoxKey(inner, kept ? new TextDecoder().decode(kept) : null);
        if (inner.workspaces) for (const [ws] of inner.workspaces.owned()) autoBox(inner, ws);
        return yield* fail("key_invalidated", t("core-misc.vault.keyRenewed"));
      }
      const priv = got.success;
      if (priv === null || priv.length !== 32) return yield* fail("vault_not_set_up", t("core-misc.vault.notSetUp"));
      return priv;
    });
  }

  /// This device's certificate, its box key the one kept here: published anew where the one held names another (the
  /// box key made anew since, `renewBoxKey`, its certificate not published yet), so nothing is sealed to a key this
  /// device no longer has. None where it is not set up.
  #current(lock: Checked, signer: Signer, who: { device: string; sub: string }): Effect.Effect<Vouched | undefined, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const here = certs(inner, self.ws, lock).find((c) => c.device === who.device);
      if (here === undefined) return undefined;
      const pub = yield* ensureBoxKey(inner);
      if (here.box === pub) return here;
      yield* self.#certify(lock, signer, who);
      return certs(inner, self.ws, lock).find((c) => c.device === who.device && c.box === pub);
    });
  }

  /// A vault's key: kept unsealed a while, else unsealed with this device's box key (the person asked); `fresh`: asked
  /// even when it is kept (an agent's grant). In hand, it is given on to the members' devices set up since that have
  /// none (`#give`: its owner's device only), unless the call is that giving itself (`give` false).
  #key(v: Vault, self: { device: string }, fresh: boolean, reason: string, give = true, unsealed?: (priv: Uint8Array) => void): Effect.Effect<Uint8Array, CoreError> {
    const inner = this.#inner;
    const ws = this.ws;
    const self_ = this;
    return Effect.tap(
      Effect.gen(function* () {
        const kept = mem(inner).keys.get(keyOf(v));
        if (!fresh && kept && kept.until > inner.host.nowMs()) return kept.key;
        const mine = v.keys.find((k) => k.cert.device === self.device);
        if (!mine) return yield* fail("vault_no_key", t("core-misc.vault.noKey"));
        const priv = yield* self_.#boxKey(reason);
        if (boxPublic(priv) !== mine.cert.box) return yield* fail("vault_no_key", t("core-misc.vault.noKey"));
        const key = yield* Effect.try({ try: () => openSeal(priv, mine.wrapped, keyContext(ws, v.id, v.epoch)), catch: asCoreError });
        unsealed?.(priv);
        self_.#keep(v, key);
        // (in hand for what the person does: a vault of theirs waiting to be keyed anew is keyed anew with it now)
        inner.runner.fork(Effect.ignore(self_.rekeyGone(), { log: "Unhandled", message: "vaults keyed anew" }));
        return key;
      }),
      (key) => Effect.sync(() => void (give && inner.runner.fork(Effect.ignore(self_.#give(v.id, v.epoch, key, null), { log: "Unhandled", message: "vault key given" })))),
    );
  }

  /// What runs on vault `id` one at a time, each after the one before: a giving of its key, a keying anew, its items
  /// carried on to its key.
  #giving(id: string) {
    const giving = mem(this.#inner).giving;
    let one = giving.get(id);
    if (one === undefined) giving.set(id, (one = Semaphore.makeUnsafe(1)));
    return one.withPermits(1);
  }

  /// The members' devices set up (their box certificates the lock vouches for) that vault `v` has no key for (or
  /// `device` alone).
  #missing(lock: Checked, v: Vault, device: string | null): Vouched[] {
    const keyed = new Map(v.keys.map((k) => [k.cert.device, k.cert.box]));
    return certs(this.#inner, this.ws, lock).filter((c) => v.members.includes(c.sub) && keyed.get(c.device) !== c.box && (device === null || c.device === device));
  }

  /// Vault `id`'s key (of `epoch`, unsealed here) sealed for the members' devices set up since it was keyed (or
  /// `device` alone): its next version, which its owner signs (another member's device gives none). How many it gave.
  #give(id: string, epoch: number, key: Uint8Array, device: string | null): Effect.Effect<number, CoreError> {
    const self = this;
    // One giving of a vault at a time (two would write the same seq, the second refused), each after the one before,
    // reading the vault and the certificates anew: a certificate heard while a version is written is given to next,
    // not dropped (review of #3624).
    return this.#giving(id)(
      Effect.gen(function* () {
        const inner = self.#inner;
        const { lock, signer, self: who } = yield* self.#ready();
        // (one waiting to be keyed anew is given to no one till it is: a key unsealed to read it gives nothing; asked
        // for by the person, addDevice says why)
        const was = held(inner, self.ws).vaults[id];
        if (was !== undefined && waitingAs(inner, self.ws, lock, was) !== null) return 0;
        const v = yield* self.#vault(lock, id);
        if (!canManage(lock, v, who.sub) || v.epoch !== epoch) return 0;
        const add = self.#missing(lock, v, device);
        const { keys: kept, freshened } = self.#freshened(lock, v);
        if (add.length === 0 && !freshened) return 0;
        const devices = new Set(add.map((c) => c.device));
        const context = keyContext(self.ws, v.id, v.epoch);
        const keys = [
          ...kept.filter((k) => !devices.has(k.cert.device)),
          ...add.map((c) => {
            const cert = bare(c);
            const eph = new Uint8Array(32);
            inner.host.randomBytes(eph);
            return { cert, wrapped: sealWith(cert.box, key, context, eph) };
          }),
        ];
        const { sig: _, ...rest } = v;
        // (refused as not a vault, by a station from before this device's checks: not tried again for this version,
        // as the next certificate or read comes, but as the vault moves on)
        yield* Effect.tapError(self.#putVault(sign({ ...rest, seq: v.seq + 1, keys, at: nowS(inner) }, TAG.vault, signer), hostOf(inner, self.ws, v.id)), (e) =>
          Effect.sync(() => void (e.code === "vault_invalid" && mem(inner).refused.set(v.id, v.seq))));
        return add.length;
      }),
    );
  }

  /// Seals all owned vaults in this workspace to `cert` during pairing handover, using RAM-cached keys or `boxPriv`
  /// without prompting again. Each `seq + 1` is held here at once and handed to the new device over the pairing link;
  /// the stations are brought it afterwards (`spreadAll`, each in its own lane), so a slow or stuck station never holds
  /// the pairing up, and one whose lock has not taken the new device yet is brought it again as it is next read.
  handover(cert: BoxCert, boxPriv: Uint8Array | null, effectiveLock?: Checked, givenSigner?: Signer): Effect.Effect<HandedVault[], CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      let lock: Checked;
      let signer: Signer;
      let who: { device: string; sub: string };
      if (effectiveLock !== undefined && givenSigner !== undefined) {
        const w = me(effectiveLock, givenSigner.id);
        if (w === null) return [];
        lock = effectiveLock;
        signer = givenSigner;
        who = w;
      } else {
        const ready = yield* self.#ready();
        lock = effectiveLock ?? ready.lock;
        signer = givenSigner ?? ready.signer;
        who = me(lock, signer.id) ?? ready.self;
      }
      const cleanCert = bare({ ...cert, sub: who.sub });
      const out: HandedVault[] = [];
      const privPub = boxPriv !== null && boxPriv.length === 32 ? boxPublic(boxPriv) : null;
      for (const cur of Object.values(held(inner, self.ws).vaults)) {
        if (cur.deleted || !trusted(lock, cur) || !canManage(lock, cur, who.sub) || !cur.keys.some((k) => k.cert.device === who.device)) continue;
        if (cur.keys.some((k) => k.cert.device === cleanCert.device && k.cert.box === cleanCert.box)) {
          out.push({ ws: self.ws, vault: cur, cert: cleanCert });
          continue;
        }
        const entry = yield* self.#giving(cur.id)(
          Effect.gen(function* () {
            const v = held(inner, self.ws).vaults[cur.id];
            if (!v || v.deleted || !trusted(lock, v) || !canManage(lock, v, who.sub)) return null;
            if (v.keys.some((k) => k.cert.device === cleanCert.device && k.cert.box === cleanCert.box)) return { ws: self.ws, vault: v, cert: cleanCert };
            const kept = mem(inner).keys.get(keyOf(v));
            let key: Uint8Array | null = kept && kept.until > inner.host.nowMs() ? kept.key : null;
            if (key === null && boxPriv !== null && privPub !== null) {
              const mine = v.keys.find((k) => k.cert.device === who.device);
              if (mine && privPub === mine.cert.box) {
                try {
                  key = openSeal(boxPriv, mine.wrapped, keyContext(self.ws, v.id, v.epoch));
                } catch {
                  key = null;
                }
              }
            }
            if (key === null) return null;
            const eph = new Uint8Array(32);
            inner.host.randomBytes(eph);
            const wrapped = sealWith(cleanCert.box, key, keyContext(self.ws, v.id, v.epoch), eph);
            const { keys: keptKeys } = self.#freshened(lock, v);
            const keys = [...keptKeys.filter((k) => k.cert.device !== cleanCert.device), { cert: cleanCert, wrapped }];
            const { sig: _, ...rest } = v;
            const next = sign({ ...rest, seq: v.seq + 1, keys, at: nowS(inner) }, TAG.vault, signer);
            const fit = fitsWith(inner, self.ws, lock);
            change(inner, self.ws, (h) => take(h, next, fit));
            spreadAll(inner, self.ws);
            return { ws: self.ws, vault: next, cert: cleanCert };
          }),
        );
        if (entry !== null) out.push(entry);
      }
      return out;
    });
  }

  /// The vault's keys with each device's certificate the latest the lock vouches for of the same box key, where it
  /// is signed by another key (the device back in the lock under a new signing key: its old certificate no longer
  /// checks out against the lock, and a station checks every certificate of a version it is given); whether any was
  /// replaced. One published anew under the same key (`vault.ask`) changes nothing. The key wrapped stays: it is
  /// sealed to the box key, which is the same.
  #freshened(lock: Checked, v: Vault): { keys: Vault["keys"]; freshened: boolean } {
    const latest = new Map(certs(this.#inner, this.ws, lock).map((c) => [c.device, bare(c)]));
    let freshened = false;
    const keys = v.keys.map((k) => {
      const c = latest.get(k.cert.device);
      if (c === undefined || c.box !== k.cert.box || c.sig.key === k.cert.sig.key) return k;
      freshened = true;
      return { cert: c, wrapped: k.wrapped };
    });
    return { keys, freshened };
  }

  /// The keys unsealed here (UNLOCK_MS from their last use) given to the members' devices set up that have none, in
  /// the vaults of this person's own: as a device's certificate comes, or the lock names it, nothing asked of the
  /// person (a key in hand is given on, as it is whenever it is unsealed).
  giveKept(): Effect.Effect<void, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const lock = lockOf(inner, self.ws);
      if (lock instanceof CoreError) return;
      const who = me(lock, signerOf(inner));
      if (who === null) return;
      for (const v of Object.values(held(inner, self.ws).vaults)) {
        if (v.deleted || !trusted(lock, v) || !canManage(lock, v, who.sub) || mem(inner).refused.get(v.id) === v.seq) continue;
        const kept = mem(inner).keys.get(keyOf(v));
        if (!kept || kept.until <= inner.host.nowMs()) continue;
        if (self.#missing(lock, v, null).length === 0 && !self.#freshened(lock, v).freshened) continue;
        yield* Effect.ignore(self.#give(v.id, v.epoch, kept.key, null), { log: "Unhandled", message: "vault key given" });
      }
    });
  }

  /// The vaults of this person's own that a device or member taken out of the lock since holds a key of (so the
  /// stations take no version of them more, rules/src/vault/vault.mbt, a key for a device not in the lock; this core
  /// reads them meanwhile and changes nothing in them: `waitingAs`) written anew: a new key under the next epoch,
  /// sealed to the members' devices the lock still vouches for, and each item written again under it, the one taken
  /// out holding no key to any of it. Only a version the lock took before (a prefix of the chain vouching for it,
  /// `waitingAs`) is so carried on, and only its items that held then. The key unsealed here, or read with this
  /// device's box key, the person asked, only where this device took out who it waits for at their asking (`tookOut`,
  /// once for that: what is done by itself asks no one). Otherwise it waits for the key unsealed here for something the
  /// person does (`#key`, which runs this then). As the lock comes; nothing done when nothing was taken out. (The locks'
  /// end to end, round 7b, the side run of 2026-11-13: a device started anew, doing nothing, read the box key each time
  /// the lock came, the vault's station not taking the write: its person asked seven times.)
  rekeyGone(): Effect.Effect<void, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const lock = lockOf(inner, self.ws);
      if (lock instanceof CoreError) return;
      const who = me(lock, signerOf(inner));
      if (who === null) return;
      // (waiting to be keyed anew: a version the lock took before, a prefix of the chain vouching for it)
      const waiting = Object.values(held(inner, self.ws).vaults).filter((v) => !v.deleted && canManage(lock, v, who.sub) && !trusted(lock, v) && v.keys.some((k) => k.cert.device === who.device) && waitingAs(inner, self.ws, lock, v) !== null);
      // Those waiting for one this device took out at the person's asking, their keys not in hand: the box key read
      // once for all of them (the person asked once), each one's key unsealed with it and kept, and what they wait
      // for asked for no more (taken from `out` before the prompt, so a second keying anew as the lock comes again
      // does not ask too).
      const out = mem(inner).out.get(self.ws);
      const goneOf = (v: Vault) => [...v.keys.map((k) => k.cert.device).filter((d) => !lock.devices.has(d)), ...v.members.filter((m) => !lock.members.has(m))];
      const inHand = (v: Vault) => (mem(inner).keys.get(keyOf(v))?.until ?? 0) > inner.host.nowMs();
      const asked = out === undefined ? [] : waiting.filter((v) => !inHand(v) && goneOf(v).some((x) => out.has(x)));
      if (asked.length > 0) {
        for (const v of asked) for (const x of goneOf(v)) out!.delete(x);
        const priv = yield* self.#boxKey(t("core-misc.vault.reason.rekey", { name: asked[0]!.name }));
        for (const v of asked) {
          const mine = v.keys.find((k) => k.cert.device === who.device)!;
          const key = yield* Effect.result(Effect.try({ try: () => openSeal(priv, mine.wrapped, keyContext(self.ws, v.id, v.epoch)), catch: asCoreError }));
          if (key._tag === "Success") self.#keep(v, key.success);
        }
      }
      for (const v of waiting) yield* Effect.ignore(self.#rekey(v.id, v.seq), { log: "Unhandled", message: "vault keyed anew" });
    });
  }

  #rekey(id: string, seq: number): Effect.Effect<void, CoreError> {
    const self = this;
    return this.#giving(id)(
      Effect.gen(function* () {
        const inner = self.#inner;
        const { lock, signer, self: who } = yield* self.#ready();
        const v = held(inner, self.ws).vaults[id];
        // (written anew meanwhile, by another of the person's devices: nothing left to do here)
        if (!v || v.seq !== seq || trusted(lock, v) || !canManage(lock, v, who.sub)) return;
        // (the key unsealed here only: `rekeyGone` says when the box key is read for it)
        const kept = mem(inner).keys.get(keyOf(v));
        if (!kept || kept.until <= inner.host.nowMs()) return;
        const old = kept.key;
        const members = v.members.filter((m) => lock.members.has(m));
        const to = certs(inner, self.ws, lock).filter((c) => members.includes(c.sub));
        const key = new Uint8Array(32);
        inner.host.randomBytes(key);
        const isWs = v.scope === "workspace";
        const recovery = isWs ? undefined : to.find((c) => c.sub === v.owner && c.recovery)?.recovery;
        const nextOwner = isWs && !members.includes(v.owner) ? who.sub : v.owner;
        const { sig: _, recovery: _r, ...rest } = v;
        /// The version keyed anew, following `seq` under `epoch`.
        const made = (seq: number, epoch: number) => {
          const context = keyContext(self.ws, v.id, epoch);
          const seal = (pub: string) => {
            const eph = new Uint8Array(32);
            inner.host.randomBytes(eph);
            return sealWith(pub, key, context, eph);
          };
          return sign({ ...rest, owner: nextOwner, seq: seq + 1, members, epoch, keys: to.map((c) => ({ cert: bare(c), wrapped: seal(c.box) })), ...(recovery ? { recovery: seal(recovery) } : {}), at: nowS(inner) }, TAG.vault, signer);
        };
        const host = hostOf(inner, self.ws, v.id);
        const first = yield* Effect.result(self.#putVault(made(v.seq, v.epoch + 1), host));
        let nv: Vault;
        if (first._tag === "Success") nv = first.success;
        else {
          if (first.failure.code !== "vault_conflict") return yield* Effect.fail(first.failure);
          // Another version there: read again, one that checks is taken (on a chain, by the chain as it stood); where the
          // chain moved, one the device this one just took out wrote, checked by the state just before that removal
          // (`takeBefore`), as a chain's prefix checks it. Either is keyed anew from as the lock comes. One that checks
          // against neither is not taken, and the vault waits, as on a chain not moved.
          yield* Effect.ignore(readStation(inner, `${self.ws}/${host}`), { log: "Unhandled", message: "vault station read" });
          const now = held(inner, self.ws).vaults[id];
          if ((now !== undefined && now.seq !== v.seq) || takeBefore(inner, self.ws, id)) {
            inner.runner.fork(Effect.ignore(self.rekeyGone(), { log: "Unhandled", message: "vaults keyed anew" }));
            return;
          }
          return yield* Effect.fail(first.failure);
        }
        // The key before kept a while too, not forgotten: an item not written again yet (this device stopped, a write
        // that failed) is carried on with it, nobody asked. The device taken out holds that key anyway: keeping it
        // here a while gives nothing away. (The version it was sealed in is kept as the last of its epoch, `before`.)
        self.#keep(v, old);
        self.#keep(nv, key);
        // Its items, as they held when the lock took the version before, written again under the new key.
        yield* Effect.ignore(self.#carryNow(id, null, new Map([[keyOf(v), old], [keyOf(nv), key]])), { log: "Unhandled", message: "vault items keyed anew" });
        // A device that came back meanwhile (put in the lock again as it was keyed anew) was looked at against the
        // version before, its key given for the epoch going: given the new one now (after this, as it waits its turn).
        inner.runner.fork(Effect.ignore(self.giveKept(), { log: "Unhandled", message: "vault keys given" }));
      }),
    );
  }

  /// Vault `id`'s items left under an earlier key (a keying anew stopped half-way: the device keying it closed, killed
  /// or cut off, a write that failed) written again under its key, as `#rekey` writes them; otherwise nothing would,
  /// and none of them could be opened. Only those that held when the lock took the last version of that key held here
  /// (`before`) are carried on: a version or an item a station made up is not. Any member's device with a key to the
  /// vault does it, as the rules let any member's device write an item's next version: an owner whose only device
  /// stopped half-way leaves a team's vault unreadable to no one. The keys from `known`, else unsealed here still, else
  /// unsealed with this device's box key, read at most once: the person asked, saying `ask` (`how.asked` told when they
  /// are), or read already (`how.priv`); `ask` null and none read, those of a key not to be had are left as they are.
  /// How many it wrote. Within the vault's giving (`carryOn` takes its turn; `#rekey` holds it already).
  #carryNow(id: string, ask: string | null, known?: Map<string, Uint8Array>, how: { asked?: () => void; priv?: Uint8Array } = {}): Effect.Effect<number, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const ws = self.ws;
      const { lock, signer, self: who } = yield* self.#ready();
      const v = held(inner, ws).vaults[id];
      if (!v || v.deleted || !trusted(lock, v) || !v.members.includes(who.sub) || !v.keys.some((k) => k.cert.device === who.device)) return 0;
      const left = underEarlier(inner, ws, v);
      if (left.length === 0) return 0;
      // What may be carried on, by earlier key: the items the lock took then under the last version held of it.
      const before: Record<string, Vault> = held(inner, ws).before?.[id] ?? {};
      const plan: { b: Vault; items: Item[] }[] = [];
      for (const epoch of new Set(left.map((i) => i.epoch))) {
        const b = before[epoch];
        const was = b === undefined ? null : tookAs(inner, ws, b);
        if (b === undefined || was === null) continue;
        const these = left.filter((i) => i.epoch === b.epoch && rules.item_ok_js(was, b, null, i, true, rulesCrypto) === null);
        if (these.length > 0) plan.push({ b, items: these });
      }
      // This device's box key, read once, where the person may be asked (or it was read already).
      let priv: Uint8Array | null = how.priv ?? null;
      const boxKey: Effect.Effect<Uint8Array | null, CoreError> = Effect.suspend((): Effect.Effect<Uint8Array | null, CoreError> => {
        if (priv !== null || ask === null) return Effect.succeed(priv);
        return Effect.map(self.#boxKey(ask), (p) => {
          priv = p;
          how.asked?.();
          return p;
        });
      });
      // A version's key: given, unsealed here still, else unsealed with the box key (then kept, as `#key` keeps it);
      // none where it is not to be had.
      const keyFor = (of: Vault): Effect.Effect<Uint8Array | null, CoreError> =>
        Effect.gen(function* () {
          const given = known?.get(keyOf(of));
          if (given !== undefined) return given;
          const kept = mem(inner).keys.get(keyOf(of));
          if (kept && kept.until > inner.host.nowMs()) return kept.key;
          const sealed = of.keys.find((k) => k.cert.device === who.device);
          if (sealed === undefined) return null;
          const p = yield* boxKey;
          if (p === null || boxPublic(p) !== sealed.cert.box) return null;
          let key: Uint8Array;
          try {
            key = openSeal(p, sealed.wrapped, keyContext(ws, of.id, of.epoch));
          } catch {
            return null;
          }
          self.#keep(of, key);
          return key;
        });
      const key = plan.length === 0 ? null : yield* keyFor(v);
      let wrote = 0;
      for (const { b, items: these } of key === null ? [] : plan) {
        const old = yield* keyFor(b);
        if (old === null) continue;
        for (const i of these) {
          // (one that fails stops none of the rest; one another device wrote meanwhile is read again by `#putItem`)
          yield* Effect.ignore(
            Effect.gen(function* () {
              const plain = yield* Effect.try({ try: () => decrypt(old, i.ct, itemContext(ws, id, i.id, i.version, i.epoch)), catch: asCoreError });
              const nonce = new Uint8Array(12);
              inner.host.randomBytes(nonce);
              const version = i.version + 1;
              const ct = encryptWith(key!, plain, itemContext(ws, id, i.id, version, v.epoch), nonce);
              const item = sign({ v: 1 as const, ws, vault: id, id: i.id, version, epoch: v.epoch, ct, ...(i.listing ? { listing: i.listing } : {}), at: nowS(inner) }, TAG.item, signer);
              yield* self.#putItem(item, v);
              wrote++;
            }),
            { log: "Unhandled", message: "vault item keyed anew" },
          );
        }
      }
      // (the versions kept of the earlier keys are let go as the vault's items are next read of a station, not here:
      // `settleBefore`)
      changed(inner, ws);
      return wrote;
    });
  }

  /// Vault `id`'s items left under an earlier key carried on (`#carryNow`), in its turn after a giving or a keying anew
  /// under way: a read that carries waits for it, not racing it item by item.
  carryOn(id: string, ask: string | null, known?: Map<string, Uint8Array>, how: { asked?: () => void; priv?: Uint8Array } = {}): Effect.Effect<number, CoreError> {
    return this.#giving(id)(this.#carryNow(id, ask, known, how));
  }

  /// A vault's key kept unsealed UNLOCK_MS from now, then forgotten (and the pages told).
  #keep(v: Vault, key: Uint8Array): void {
    const inner = this.#inner;
    const until = inner.host.nowMs() + UNLOCK_MS;
    mem(inner).keys.set(keyOf(v), { key, until });
    changed(inner, this.ws);
    inner.runner.fork(
      Effect.andThen(
        Effect.sleep(UNLOCK_MS),
        Effect.sync(() => {
          const k = mem(inner).keys.get(keyOf(v));
          if (k && k.until <= inner.host.nowMs()) mem(inner).keys.delete(keyOf(v));
          changed(inner, this.ws);
        }),
      ),
    );
  }

  /// A vault's version taken by its station, held here as it is; where no station can take it now (`station` none, or
  /// `localFallback`), held here alone, no station said to hold it, so each is brought it as it can be (`spreadAll`,
  /// another online at once). A station's refusal by the rules fails it.
  /// Where another station holds the vault too, each is waited on `WRITE_TRY_MS` before the next is tried
  /// (`writeHosts` order); only a station that cannot take it now passes it on, never one refusing it by the rules.
  #putVault(next: Vault, station: string): Effect.Effect<Vault, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const targets = station === "" ? [] : [station, ...writeHosts(inner, self.ws, next.id).filter((s) => s !== station)];
      for (const s of targets) {
        const put = self.#station(s, "PUT", "/vault/vaults", next);
        const res = targets.length > 1
          ? yield* Effect.timeoutOption(Effect.result(put), WRITE_TRY_MS) // timer: a deadline
          : Option.some(yield* Effect.result(put));
        if (Option.isNone(res)) continue;
        if (res.value._tag === "Success") {
          const v = (get(res.value.success, "vault") as Vault | undefined) ?? next;
          change(inner, self.ws, (h) => holds(h, v, s, null, fits(inner, self.ws)));
          spreadAll(inner, self.ws);
          return v;
        }
        if (!localFallback(res.value.failure)) return yield* Effect.fail(res.value.failure);
      }
      change(inner, self.ws, (h) => take(h, next, fits(inner, self.ws)));
      spreadAll(inner, self.ws);
      return next;
    });
  }

  /// This device set up for the vault in this workspace: its box key (made once, in the secure storage), its
  /// certificate signed and published to the workspace's stations. The person's recovery words the first time: one of
  /// their devices that published a recovery key already gives it (none are made then). Their own vault made (`made`)
  /// only when they have none, as the stations hold them now: a device set up after the first is given that one's
  /// key by a device that has it (`#give`), never a second vault.
  setup(): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      // No safe mode and their own lock begun nowhere (`personalNone`): begun here first, this device on it with its
      // signer (made now where it has none, `begin`), the person asked once. Where reading it found it begun on another
      // device after all, nothing is begun: the page then offers to be approved there.
      if (able(inner) && personalNone(inner, self.ws)) {
        const sub = inner.workspaces.owner(self.ws)!;
        const signer = yield* Signer.make(inner.host);
        signerKnown(inner, signer.id);
        yield* inner.adb.personal().open(sub, t("core-misc.vault.reason.turnOn"));
        if (inner.adb.personal().standing(sub) !== "member") return yield* fail("vault_personal_outside", t("core-misc.vault.notTrusted"));
      }
      const { lock, signer, self: who } = yield* self.#ready();
      // The box key made once (its public half kept beside, read without asking the person).
      const pub = yield* ensureBoxKey(inner);
      const theirs = certs(inner, self.ws, lock).filter((c) => c.sub === who.sub && typeof c.recovery === "string").sort((a, b) => b.at - a.at)[0];
      let words: string | null = null;
      let recovery = theirs?.recovery ?? null;
      if (recovery === null) {
        const entropy = new Uint8Array(32);
        inner.host.randomBytes(entropy);
        words = toWords(entropy);
        recovery = recoveryPair(entropy).pub;
      }
      const stations = yield* self.#publish(sign({ v: 1 as const, ws: self.ws, device: who.device, box: pub, recovery, at: nowS(inner) }, TAG.box, signer));
      for (const s of stations) yield* Effect.ignore(readStation(inner, `${self.ws}/${s}`), { log: "Unhandled", message: "vault station read" });
      // (not made, it is offered on the page as when there is none; one waiting to be keyed anew is one; workspace vaults do not count as a personal vault)
      const own = Object.values(held(inner, self.ws).vaults).some((v) => !v.deleted && v.scope !== "workspace" && (trusted(lock, v) || waitingAs(inner, self.ws, lock, v) !== null) && v.owner === who.sub);
      const made = own ? null : yield* Effect.orElseSucceed(Effect.map(self.create(t("core-misc.vault.personal"), null), (m) => (m as { id: string }).id), () => null);
      // What a station still keeps unencrypted from before moved into the vault just made, its key in hand (nobody
      // asked again); what is left, or comes later, the page offers to move (`plainLeft`, `migrate`).
      if (made !== null && Object.values(held(inner, self.ws).plain).some((r) => !r.deleted)) yield* Effect.ignore(self.migrate(), { log: "Unhandled", message: "plain secrets moved into the vault" });
      return { words, device: who.device, stations, made };
    });
  }

  /// This device's certificate kept here, then published to the workspace's stations (each told: the members' devices
  /// hear of it); the stations that took it. None did (none online, none in the workspace): it is brought to each as it
  /// is next read (`readStation`).
  #publish(cert: BoxCert): Effect.Effect<string[], CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      change(inner, self.ws, (h) => {
        if (heldOver(h.boxes[cert.device], cert, fits(inner, self.ws))) h.boxes[cert.device] = cert;
      });
      const stations = stationsOf(inner, self.ws);
      if (stations.length === 0) return [];
      // (done once one took it: a station gone silent is not waited on, the others still told it; lock.ts answersOf. Each
      // that takes it keeps vaults, a later one than the first too: one refused before, since updated, is no more.)
      const published = yield* answersOf(inner, stations.map((s) => self.#station(s.id, "PUT", "/vault/boxes", cert).pipe(
        Effect.tap(() => Effect.sync(() => kept(inner, self.ws, s.id))),
        Effect.as(s.id),
      )), tookOrRefused);
      return published.flatMap((r) => (r._tag === "Success" ? [r.success] : []));
    });
  }

  /// This device asking for the keys it lacks (set up already): its certificate published anew, dated now, so that
  /// the owner's devices hearing of it give it the keys they hold unsealed, or prompt for it again where it was put
  /// away (`lockPrompts` `asks`: what is shown is by the certificate's date). How many stations were told.
  ask(): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const { lock, signer, self: who } = yield* self.#ready();
      const here = certs(inner, self.ws, lock).find((c) => c.device === who.device);
      const had = yield* Effect.orElseSucceed(inner.host.storageGet(BOX_PUB), () => null);
      const pub = had ? new TextDecoder().decode(had) : null;
      if (!here || pub === null || here.box !== pub) {
        // (not set up yet, the vault on on another device of the person's, its `autoBox` not done as the person
        // pressed: set up now, as it would be, and so asking; on nowhere, 开启 is theirs to press, the words said then)
        if (!onElsewhere(inner, self.ws, lock, who)) return yield* fail("vault_not_set_up", t("core-misc.vault.notSetUp"));
        return { asked: (yield* self.#certify(lock, signer, who)).length };
      }
      const { sig: _s, ...rest } = bare(here);
      const stations = yield* self.#publish(sign({ ...rest, at: Math.max(nowS(inner), here.at + 1) }, TAG.box, signer));
      return { asked: stations.length };
    });
  }

  /// This device's box key (made once, `ensureBoxKey`) certified and published, with the recovery key the person's
  /// other devices' certificates carry (none made: their recovery words are said once, on the device that turned the
  /// vault on); the stations that took it.
  #certify(lock: Checked, signer: Signer, who: { device: string; sub: string }): Effect.Effect<string[], CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const pub = yield* ensureBoxKey(inner);
      const recovery = certs(inner, self.ws, lock).filter((c) => c.sub === who.sub && typeof c.recovery === "string").sort((a, b) => b.at - a.at)[0]?.recovery ?? null;
      const at = Math.max(nowS(inner), (held(inner, self.ws).boxes[who.device]?.at ?? -1) + 1);
      return yield* self.#publish(sign({ v: 1 as const, ws: self.ws, device: who.device, box: pub, ...(recovery !== null ? { recovery } : {}), at }, TAG.box, signer));
    });
  }

  /// `autoBox`'s work: as it was asked, checked again now (the lock, this device in it, not set up, the vault on on
  /// another device of the person's), this device certified (`#certify`). The signer read as it is kept, never made.
  autoSetUp(): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const lock = lockOf(inner, self.ws);
      if (lock instanceof CoreError) return;
      const signer = yield* Signer.load(inner.host);
      const who = signer ? me(lock, signer.id) : null;
      if (signer === null || who === null || !onElsewhere(inner, self.ws, lock, who)) return;
      // (the box key kept already, read now: `install` may not have read it yet)
      yield* ensureBoxKey(inner);
      if (setUpHere(inner, self.ws, lock, who.device)) return;
      yield* self.#certify(lock, signer, who);
    });
  }

  /// A device's prompt for a key put away on this device, until it asks again (a certificate dated later than the
  /// one shown, `at`: not one that came while the prompt was up).
  hidePrompt(device: string, at: number | null): Effect.Effect<unknown, CoreError> {
    const inner = this.#inner;
    const now = held(inner, this.ws).boxes[device]?.at;
    if (now === undefined) return Effect.fail(CoreError.invalid("device"));
    const hid = at !== null && at < now ? at : now;
    change(inner, this.ws, (h) => void (h.hidden[device] = hid));
    return Effect.succeed(null);
  }

  /// A personal or shared workspace vault, on `station` (the first of the workspace's that holds vaults, when not said;
  /// none: kept here, brought to the stations as they can take it). A personal vault seals its key to each of one's own
  /// set-up devices and recovery key; a workspace vault (`scope: "workspace"`) requires workspace owner/admin, allows
  /// at most one active workspace vault per workspace, seals its key to all selected members' set-up devices, and has
  /// no single-person recovery key.
  create(name: string, station: string | null, opts?: { scope?: "personal" | "workspace"; members?: string[] }): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      if (name.trim() === "") return yield* Effect.fail(CoreError.invalid("name"));
      const { lock, signer, self: who } = yield* self.#ready();
      const here = yield* self.#current(lock, signer, who);
      if (!here || here.sub !== who.sub) return yield* fail("vault_not_set_up", t("core-misc.vault.notSetUp"));
      const allCerts = certs(inner, self.ws, lock);
      const h = held(inner, self.ws);
      const isWs = opts?.scope === "workspace";
      let memberSubs: string[];
      let to: Vouched[];
      if (isWs) {
        if (!isWorkspaceAdmin(lock, who.sub)) return yield* fail("vault_not_admin", t("core-misc.vault.notOwner"));
        const hasWorkspace = Object.values(h.vaults).some(
          (v) => !v.deleted && v.scope === "workspace" && (trusted(lock, v) || waitingAs(inner, self.ws, lock, v) !== null),
        );
        if (hasWorkspace) return yield* fail("vault_exists", "a workspace vault already exists");
        if (opts?.members !== undefined) {
          const seen = new Set<string>();
          memberSubs = [];
          for (const m of opts.members) {
            if (seen.has(m)) continue;
            if (!lock.members.has(m)) return yield* Effect.fail(CoreError.invalid(`member ${m} is not in workspace`));
            seen.add(m);
            memberSubs.push(m);
          }
          if (!seen.has(who.sub)) memberSubs.unshift(who.sub);
        } else {
          memberSubs = [...lock.members.keys()].filter((m) => m !== "");
          if (!memberSubs.includes(who.sub)) memberSubs.unshift(who.sub);
        }
        to = allCerts.filter((c) => memberSubs.includes(c.sub));
      } else {
        memberSubs = [who.sub];
        to = allCerts.filter((c) => c.sub === who.sub);
      }
      const on = station ?? stationsOf(inner, self.ws).find((s) => h.refused[s.id] === undefined)?.id ?? "";
      const id = `v_${ulid(inner.host)}`;
      const key = new Uint8Array(32);
      inner.host.randomBytes(key);
      const context = keyContext(self.ws, id, 0);
      const seal = (pub: string) => {
        const eph = new Uint8Array(32);
        inner.host.randomBytes(eph);
        return sealWith(pub, key, context, eph);
      };
      const recovery = isWs ? undefined : (here.recovery ?? to.find((c) => c.recovery)?.recovery);
      const next = sign(
        {
          v: 1 as const, ws: self.ws, id, seq: 0, owner: who.sub, name: name.trim(), members: memberSubs, epoch: 0,
          ...(isWs ? { scope: "workspace" as const } : {}),
          keys: to.map((c) => ({ cert: bare(c), wrapped: seal(c.box) })),
          ...(recovery ? { recovery: seal(recovery) } : {}),
          at: nowS(inner),
        },
        TAG.vault,
        signer,
      );
      const v = yield* self.#putVault(next, on);
      self.#keep(v, key);
      return { id, station: on };
    });
  }

  /// Updates the member list of a shared workspace vault (workspace owners/admins who are members only). Adding
  /// members keeps the current epoch and seals the current master key to their set-up devices; removing any member
  /// rotates to `epoch + 1` with a fresh master key (taking over `owner` if the original creator is removed) and
  /// immediately re-encrypts all items under the new epoch.
  setMembers(id: string, members: string[]): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const { lock, signer, self: who } = yield* self.#ready();
      const v0 = yield* self.#vault(lock, id);
      if (v0.scope !== "workspace") return yield* fail("vault_not_workspace", "only workspace vaults support managing members");
      if (!canManage(lock, v0, who.sub)) return yield* fail("vault_not_admin", t("core-misc.vault.notOwner"));
      const seen = new Set<string>();
      const nextMembers: string[] = [];
      for (const m of members) {
        if (seen.has(m)) continue;
        if (!lock.members.has(m)) return yield* Effect.fail(CoreError.invalid(`member ${m} is not in workspace`));
        seen.add(m);
        nextMembers.push(m);
      }
      if (!seen.has(who.sub)) return yield* Effect.fail(CoreError.invalid("cannot remove yourself from workspace vault"));
      const added0 = nextMembers.filter((m) => !v0.members.includes(m));
      const removed0 = v0.members.filter((m) => !seen.has(m));
      if (added0.length === 0 && removed0.length === 0) return { id: v0.id, members: v0.members, rekeyed: false };
      return yield* self.#giving(v0.id)(
        Effect.gen(function* () {
          const { lock, signer, self: who } = yield* self.#ready();
          const v = yield* self.#vault(lock, id);
          if (v.scope !== "workspace") return yield* fail("vault_not_workspace", "only workspace vaults support managing members");
          if (!canManage(lock, v, who.sub)) return yield* fail("vault_not_admin", t("core-misc.vault.notOwner"));
          for (const m of nextMembers) {
            if (!lock.members.has(m)) return yield* Effect.fail(CoreError.invalid(`member ${m} is not in workspace`));
          }
          if (!nextMembers.includes(who.sub)) return yield* Effect.fail(CoreError.invalid("cannot remove yourself from workspace vault"));
          const added = nextMembers.filter((m) => !v.members.includes(m));
          const removed = v.members.filter((m) => !seen.has(m));
          if (added.length === 0 && removed.length === 0) return { id: v.id, members: v.members, rekeyed: false };
          const oldKey = yield* self.#key(v, who, false, t("core-misc.vault.reason.unlock", { name: v.name }), false);
          if (removed.length === 0) {
            const { keys: kept } = self.#freshened(lock, v);
            const keyed = new Map(kept.map((k) => [k.cert.device, k.cert.box]));
            const addCerts = certs(inner, self.ws, lock).filter((c) => nextMembers.includes(c.sub) && keyed.get(c.device) !== c.box);
            const addDevices = new Set(addCerts.map((c) => c.device));
            const context = keyContext(self.ws, v.id, v.epoch);
            const keys = [
              ...kept.filter((k) => !addDevices.has(k.cert.device)),
              ...addCerts.map((c) => {
                const cert = bare(c);
                const eph = new Uint8Array(32);
                inner.host.randomBytes(eph);
                return { cert, wrapped: sealWith(cert.box, oldKey, context, eph) };
              }),
            ];
            const { sig: _, ...rest } = v;
            const next = sign({ ...rest, seq: v.seq + 1, members: nextMembers, keys, at: nowS(inner) }, TAG.vault, signer);
            yield* self.#putVault(next, hostOf(inner, self.ws, v.id));
            return { id: v.id, members: nextMembers, rekeyed: false };
          }
          const newKey = new Uint8Array(32);
          inner.host.randomBytes(newKey);
          const nextEpoch = v.epoch + 1;
          const context = keyContext(self.ws, v.id, nextEpoch);
          const to = certs(inner, self.ws, lock).filter((c) => nextMembers.includes(c.sub));
          const nextOwner = nextMembers.includes(v.owner) ? v.owner : who.sub;
          const { sig: _, recovery: _r, ...rest } = v;
          const next = sign(
            {
              ...rest, owner: nextOwner, seq: v.seq + 1, members: nextMembers, epoch: nextEpoch,
              keys: to.map((c) => {
                const cert = bare(c);
                const eph = new Uint8Array(32);
                inner.host.randomBytes(eph);
                return { cert, wrapped: sealWith(cert.box, newKey, context, eph) };
              }),
              at: nowS(inner),
            },
            TAG.vault,
            signer,
          );
          const nv = yield* self.#putVault(next, hostOf(inner, self.ws, v.id));
          self.#keep(v, oldKey);
          self.#keep(nv, newKey);
          yield* Effect.ignore(self.#carryNow(v.id, null, new Map([[keyOf(v), oldKey], [keyOf(nv), newKey]])), { log: "Unhandled", message: "vault items keyed anew" });
          return { id: v.id, members: nextMembers, rekeyed: true, epoch: nextEpoch };
        }),
      );
    });
  }

  /// A vault of one's own deleted: its last version, which its owner signs, sealed to no one under a new epoch (the
  /// stations let its items go, and bring it to those holding an older one); the person asked first when it holds any
  /// item, which goes with it.
  delete(id: string): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const { lock, signer, self: who } = yield* self.#ready();
      const v = yield* self.#vault(lock, id);
      if (!canManage(lock, v, who.sub)) return yield* fail("vault_not_owner", t("core-misc.vault.notOwnerDelete"));
      const n = Object.values(items(inner, self.ws, v.id)).filter((i) => !i.deleted).length;
      if (n > 0) yield* askPerson(inner, t("core-misc.vault.reason.delete", { name: v.name }), "vault_refused");
      const { sig: _, recovery: _r, ...rest } = v;
      yield* self.#putVault(sign({ ...rest, seq: v.seq + 1, epoch: v.epoch + 1, keys: [], deleted: true as const, at: nowS(inner) }, TAG.vault, signer), hostOf(inner, self.ws, v.id));
      mem(inner).keys.delete(keyOf(v));
      inner.data.forgetRecord("vaultItems", `${self.ws}/${v.id}`);
      changed(inner, self.ws);
      return { deleted: v.id };
    });
  }

  /// The longest grant of a vault's items that say none: a new version its owner signs; the plain library's told to
  /// each station keeping it (the latest word kept on each).
  setLasts(id: string, lasts: string): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const scope = SCOPES.find((s) => s === lasts);
      if (!scope) return yield* Effect.fail(CoreError.invalid("lasts: once, hour or chat"));
      if (id === PLAIN) {
        if (!plainMode(inner, self.ws)) return yield* fail("vault_locked", t("core-misc.vault.plainLocked"));
        const at = nowS(inner);
        const told = yield* answersOf(inner, held(inner, self.ws).plainOn.map((s) => self.#station(s, "PUT", "/vault/plain/lasts", { lasts: scope, at })), tookOrRefused);
        if (!told.some((r) => r._tag === "Success")) return yield* fail("vault_no_station", t("core-misc.vault.noStation"));
        change(inner, self.ws, (h) => void (h.plainLasts = { lasts: scope, at }));
        return { lasts: scope };
      }
      const { lock, signer, self: who } = yield* self.#ready();
      const v = yield* self.#vault(lock, id);
      if (!canManage(lock, v, who.sub)) return yield* fail("vault_not_owner", t("core-misc.vault.notOwnerLasts"));
      const { sig: _, ...rest } = v;
      yield* self.#putVault(sign({ ...rest, seq: v.seq + 1, lasts: scope, at: nowS(inner) }, TAG.vault, signer), hostOf(inner, self.ws, v.id));
      return { lasts: scope };
    });
  }

  /// The vault's key sealed for members' devices set up since it was keyed (or `device` alone): its owner signs. (Done
  /// by itself whenever the owner's device unseals the key: this for when it has not been since.)
  addDevice(id: string, device: string | null): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const { lock, self: who } = yield* self.#ready();
      const v = yield* self.#vault(lock, id);
      if (!canManage(lock, v, who.sub)) return yield* fail("vault_not_owner", t("core-misc.vault.notOwner"));
      if (self.#missing(lock, v, device).length === 0) return { added: 0 };
      const key = yield* self.#key(v, who, false, t("core-misc.vault.reason.unlock", { name: v.name }), false);
      return { added: yield* self.#give(v.id, v.epoch, key, device) };
    });
  }

  /// An item written: encrypted under the vault's key, the version after the one held (a new one's 0), signed.
  putItem(vault: string, id: string | null, plain: unknown, listing: unknown): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const body = yield* Effect.try({ try: () => ({ plain: plainOf(plain), listing: listingOf(listing) }), catch: asCoreError });
      const { lock, signer, self: who } = yield* self.#ready();
      const v = yield* self.#writable(lock, vault, who);
      if (!v.members.includes(who.sub)) return yield* fail("vault_unknown", t("core-misc.vault.unknown"));
      const key = yield* self.#key(v, who, false, t("core-misc.vault.reason.unlock", { name: v.name }));
      const item = id ?? `i_${ulid(inner.host)}`;
      const prev = items(inner, self.ws, vault)[item];
      const version = prev ? prev.version + 1 : 0;
      const nonce = new Uint8Array(12);
      inner.host.randomBytes(nonce);
      const ct = encryptWith(key, utf8(JSON.stringify(body.plain)), itemContext(self.ws, vault, item, version, v.epoch), nonce);
      const next = sign({ v: 1 as const, ws: self.ws, vault, id: item, version, epoch: v.epoch, ct, ...(body.listing ? { listing: body.listing } : {}), at: nowS(inner) }, TAG.item, signer);
      return yield* self.#putItem(next, v);
    });
  }

  deleteItem(vault: string, id: string): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const { lock, signer, self: who } = yield* self.#ready();
      const v = yield* self.#writable(lock, vault, who);
      const prev = items(self.#inner, self.ws, vault)[id];
      if (!prev || prev.deleted) return yield* fail("vault_unknown", t("core-misc.vault.unknownItem"));
      const next = sign({ v: 1 as const, ws: self.ws, vault, id, version: prev.version + 1, epoch: v.epoch, deleted: true as const, ct: "", at: nowS(self.#inner) }, TAG.item, signer);
      return yield* self.#putItem(next, v);
    });
  }

  /// An item's version taken by its station; one that was not the next (another device wrote meanwhile) has the vault's
  /// items read again before it fails. Where no station can take it now (the vault on none, or `localFallback`), held
  /// here alone, no station said to hold it, so each is brought it as it can be (`spreadAll`).
  /// Where another station holds the vault too, each is waited on `WRITE_TRY_MS` before the next is tried, as
  /// `#putVault`.
  #putItem(next: Item, v: Vault): Effect.Effect<unknown, CoreError> {
    const self = this;
    const targets = writeHosts(this.#inner, this.ws, v.id);
    return Effect.gen(function* () {
      const inner = self.#inner;
      let item = next;
      let on = "";
      for (const s of targets) {
        const put = self.#station(s, "PUT", "/vault/items", next);
        const res = targets.length > 1
          ? yield* Effect.timeoutOption(Effect.result(put), WRITE_TRY_MS) // timer: a deadline
          : Option.some(yield* Effect.result(put));
        if (Option.isNone(res)) continue;
        if (res.value._tag === "Success") {
          item = (get(res.value.success, "item") as Item | undefined) ?? next;
          on = s;
          break;
        }
        if (res.value.failure.code === "vault_conflict") {
          yield* Effect.ignore(readItems(inner, `${self.ws}/${s}`, v.id), { log: "Unhandled", message: "vault items read" });
          return yield* Effect.fail(res.value.failure);
        }
        if (!localFallback(res.value.failure)) return yield* Effect.fail(res.value.failure);
      }
      const fit = fits(inner, self.ws);
      changeItems(inner, self.ws, v.id, (all) => { if (newer(item, all[item.id], fit)) all[item.id] = item; });
      if (on !== "") change(inner, self.ws, (h) => {
        const at = h.on[v.id]?.[on];
        if (at !== undefined) holdsItem(at, item);
      });
      spreadAll(inner, self.ws);
      return { id: item.id, version: item.version };
    });
  }

  /// The item, found in its vault, that vault, and the lock it is read by (`readAs`: one waiting to be keyed anew, as
  /// the lock took it).
  #find(lock: Checked, self: { device: string }, id: string): Effect.Effect<{ v: Vault; item: Item; as: Checked }, CoreError> {
    const h = held(this.#inner, this.ws);
    for (const v of Object.values(h.vaults)) {
      const item = items(this.#inner, this.ws, v.id)[id];
      const as = item && !item.deleted ? readAs(this.#inner, this.ws, lock, v, self) : null;
      if (item && as !== null) return Effect.succeed({ v, item, as });
    }
    return fail("vault_unknown", t("core-misc.vault.unknownItem"));
  }

  /// What an item holds: written by a member's own device in the lock, opened with its vault's key.
  #plain(lock: Checked, v: Vault, item: Item, key: Uint8Array): Effect.Effect<Uint8Array, CoreError> {
    // (as the stations take it, rules/ `itemOk`, and written under the key it is opened with)
    if (rules.item_ok_js(lock, v, null, item, true, rulesCrypto) !== null || item.epoch !== v.epoch) return fail("vault_untrusted", t("core-misc.vault.untrusted"));
    return Effect.try({ try: () => decrypt(key, item.ct, itemContext(this.ws, v.id, item.id, item.version, item.epoch)), catch: asCoreError });
  }

  open(id: string): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      // (a device taken out of the lock opens nothing, of a vault waiting to be keyed anew either: #ready refuses it)
      const { lock, self: who } = yield* self.#ready();
      let { v, item, as } = yield* self.#find(lock, who, id);
      // Written before its vault was keyed anew (`rekeyGone`), as held here: its station read again for the one
      // written since under the new key.
      if (item.epoch < v.epoch) {
        const host = hostOf(self.#inner, self.ws, v.id);
        if (host !== "") yield* Effect.ignore(readItems(self.#inner, `${self.ws}/${host}`, v.id), { log: "Unhandled", message: "vault items read" });
        ({ v, item, as } = yield* self.#find(lock, who, id));
      }
      const name = item.listing?.name ?? v.name;
      const reason = t("core-misc.vault.reason.open", { name });
      // Still under the earlier key (its keying anew stopped half-way): carried on to the vault's key here, the person
      // asked for this device's box key where the keys are not unsealed (as opening it would); one not to be carried on
      // stays refused below (nor one of a vault waiting to be keyed anew: nothing is written into it). What fails it is
      // reading the box key, which opening it would fail on the same way: the answer, not asked again.
      if (item.epoch < v.epoch) {
        yield* self.carryOn(v.id, reason);
        ({ v, item, as } = yield* self.#find(lock, who, id));
      }
      const key = yield* self.#key(v, who, false, reason);
      // (an item of a vault waiting to be keyed anew checked against the lock as it took the vault, as what is carried
      // on is)
      const bytes = yield* self.#plain(as, v, item, key);
      return { vault: v.id, id: item.id, version: item.version, plain: JSON.parse(new TextDecoder().decode(bytes)) };
    });
  }

  /// This device keyed into the vaults the recovery words open (its person's own: their owner signs).
  recover(words: string): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const entropy = yield* Effect.try({ try: () => fromWords(words), catch: asCoreError });
      const { lock, signer, self: who } = yield* self.#ready();
      const here = yield* self.#current(lock, signer, who);
      if (!here) return yield* fail("vault_not_set_up", t("core-misc.vault.notSetUp"));
      const { priv } = recoveryPair(entropy);
      let recovered = 0;
      let others = 0;
      // (one waiting to be keyed anew that this device would be keyed into: a version written, refused, said once the
      // others are done)
      let waited: Vault | null = null;
      for (const v of Object.values(held(inner, self.ws).vaults)) {
        const waits = waitingAs(inner, self.ws, lock, v) !== null;
        if ((!waits && !trusted(lock, v)) || v.scope === "workspace" || !v.recovery || !v.members.includes(who.sub)) continue;
        let key: Uint8Array;
        try {
          key = openSeal(priv, v.recovery, keyContext(self.ws, v.id, v.epoch));
        } catch {
          continue;
        }
        if (v.owner !== who.sub) {
          others++;
          continue;
        }
        self.#keep(v, key);
        if (v.keys.some((k) => k.cert.device === who.device && k.cert.box === here.box)) {
          recovered++;
          continue;
        }
        if (waits) {
          waited ??= v;
          continue;
        }
        const eph = new Uint8Array(32);
        inner.host.randomBytes(eph);
        const cert = bare(here);
        const keys = [...v.keys.filter((k) => k.cert.device !== who.device), { cert, wrapped: sealWith(cert.box, key, keyContext(self.ws, v.id, v.epoch), eph) }];
        const { sig: _s, ...rest } = v;
        yield* self.#putVault(sign({ ...rest, seq: v.seq + 1, keys, at: nowS(inner) }, TAG.vault, signer), hostOf(inner, self.ws, v.id));
        recovered++;
      }
      if (waited !== null) return yield* Effect.fail(waitingError(inner, self.ws, waited));
      return { recovered, others };
    });
  }

  /// The request as held, or read again from the stations when it is not.
  #request(id: string): Effect.Effect<{ r: Request; station: string }, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      if (!held(inner, self.ws).requests[id]) {
        yield* answersOf(inner, stationsOf(inner, self.ws).map((s) => readStation(inner, `${self.ws}/${s.id}`)), () => (held(inner, self.ws).requests[id] !== undefined ? 0 : OTHERS_MS));
      }
      const h = held(inner, self.ws);
      const r = h.requests[id];
      if (!r || r.status !== "pending") return yield* fail("vault_no_request", t("core-misc.vault.noRequest"));
      return { r, station: h.asked[id] ?? "" };
    });
  }

  /// An agent's request granted: the item's plaintext sealed to the keeper's key for this request, signed by this
  /// device (the person asked each time, whether the vault is unlocked or not). One to keep a secret: kept, with what
  /// the person `typed` where it is theirs to type in.
  approve(id: string, scope: Scope, typed?: unknown, timeoutValue?: unknown, targetVault?: string, selectedItems?: { workspace: string; vault: string; item: string }[]): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const asked = yield* self.#request(id);
      if (asked.r.browse !== undefined) return yield* self.#approveBrowse(asked.r, asked.station, selectedItems);
      if (!["once", "hour", "chat"].includes(scope)) return yield* Effect.fail(CoreError.invalid("scope: once, hour or chat"));
      const timeout = timeoutValue as { kind?: unknown; seconds?: unknown } | undefined;
      if (timeout !== undefined && (timeout === null || typeof timeout !== "object" || (timeout.kind !== "idle" && timeout.kind !== "fixed") || !Number.isSafeInteger(timeout.seconds) || (timeout.seconds as number) < 1 || (timeout.seconds as number) > 30 * 86400 || scope === "once" || (timeout.seconds as number) > GRANT_SECS[scope])) return yield* Effect.fail(CoreError.invalid("invalid timeout"));
      // The plain library's: its owner says so, nothing to open or sign (the station holds the value).
      if (asked.r.save) return yield* self.#keepSaved(asked.r, asked.station, typed, targetVault);
      if (asked.r.describe) return yield* self.#describe(asked.r, asked.station);
      if (asked.r.remove) return yield* self.#remove(asked.r, asked.station);
      if (asked.r.timeout && scope !== "once" && !timeout) return yield* Effect.fail(CoreError.invalid("this request needs an approval with its timeout; update the app"));
      if (asked.r.cross !== undefined) return yield* self.#approveCross(asked.r, asked.station, scope, timeout as { kind: "idle" | "fixed"; seconds: number } | undefined);
      if (asked.r.vault === PLAIN) {
        if (!plainMode(inner, self.ws)) return yield* fail("vault_locked", t("core-misc.vault.plainLocked"));
        const { r, station } = asked;
        const h = held(inner, self.ws);
        if (!allows(h.plain[r.item]?.listing?.lasts ?? h.plainLasts?.lasts, scope)) return yield* fail("vault_scope", t("core-misc.vault.scopeTooLong"));
        yield* self.#station(station, "POST", "/vault/plain/grants", { request: r.id, scope, ...(timeout ? { timeout } : {}) });
        self.#settled(r.id, { status: "granted", scope, ...(timeout ? { timeout: timeout as { kind: "idle" | "fixed"; seconds: number } } : {}) });
        return { request: r.id, scope };
      }
      const { lock, signer, self: who } = yield* self.#ready();
      const { r, station } = yield* self.#request(id);
      // (a use of an item, read: one of a vault waiting to be keyed anew is given as it is opened, checked against the
      // lock that took the vault; the sign-in's newer cookies are not written into it meanwhile, below)
      const { v, as } = yield* self.#readable(lock, r.vault, who);
      if (!v.members.includes(who.sub)) return yield* fail("vault_unknown", t("core-misc.vault.unknown"));
      const found = items(inner, self.ws, v.id)[r.item];
      if (!found || found.deleted) return yield* fail("vault_unknown", t("core-misc.vault.unknownItem"));
      let item: Item = found;
      if (!allows(item.listing?.lasts ?? v.lasts, scope)) return yield* fail("vault_scope", t("core-misc.vault.scopeTooLong"));
      // (this device's box key, as it was unsealed for it: a sign-in's newer cookies the request carries are opened with it)
      const unsealed: { priv?: Uint8Array } = {};
      const key = yield* self.#key(v, who, true, t("core-misc.vault.reason.approve", { name: item.listing?.name ?? v.name }), true, (p) => (unsealed.priv = p));
      // Still under the earlier key (its keying anew stopped half-way): carried on to the vault's key first, with the
      // box key just read (the person asked once); one not to be carried on stays refused below.
      if (item.epoch < v.epoch) {
        yield* Effect.ignore(self.carryOn(v.id, null, new Map([[keyOf(v), key]]), unsealed.priv ? { priv: unsealed.priv } : {}), { log: "Unhandled", message: "vault items carried on" });
        item = items(inner, self.ws, v.id)[r.item] ?? item;
      }
      let bytes = yield* self.#plain(as, v, item, key);
      // A sign-in's newer cookies ( 登录态 写回): written as its next version, and granted (not into a vault waiting
      // to be keyed anew: the cookies it holds granted).
      const renewal = r.mode === "browser" && as === lock ? r.renewal?.sealed.find((x) => x.device === who.device) : undefined;
      const priv = unsealed.priv;
      if (renewal !== undefined && priv !== undefined) {
        const renewed = yield* Effect.result(Effect.try({
          try: () => {
            const was = JSON.parse(new TextDecoder().decode(bytes)) as Plain;
            const fields = JSON.parse(new TextDecoder().decode(openSeal(priv, renewal.secret, saveContext(self.ws, r.renewal!.id)))) as Record<string, unknown>;
            if (was.kind !== "browser" || typeof fields.cookies !== "string" || fields.cookies === "") throw new Error("no sign-in's cookies");
            return plainOf({ ...was, fields: { ...was.fields, cookies: fields.cookies } });
          },
          catch: asCoreError,
        }));
        if (renewed._tag === "Success") {
          const plain = renewed.success;
          const version = item.version + 1;
          const nonce = new Uint8Array(12);
          inner.host.randomBytes(nonce);
          const ct = encryptWith(key, utf8(JSON.stringify(plain)), itemContext(self.ws, v.id, item.id, version, v.epoch), nonce);
          const next = sign({ v: 1 as const, ws: self.ws, vault: v.id, id: item.id, version, epoch: v.epoch, ct, ...(item.listing ? { listing: item.listing } : {}), at: nowS(inner) }, TAG.item, signer);
          const put = yield* Effect.result(self.#putItem(next, v));
          if (put._tag === "Success") bytes = utf8(JSON.stringify(plain));
        }
      }
      const mode = r.mode === "browse" ? "proxy" : r.mode;
      const grantTo = (box: string): Grant => {
        const eph = new Uint8Array(32);
        inner.host.randomBytes(eph);
        const now = nowS(inner);
        return sign(
          { v: 1 as const, ws: self.ws, request: r.id, vault: v.id, item: item.id, mode, hosts: r.hosts ?? item.listing?.hosts ?? [], scope, exp: now + (timeout ? timeout.seconds as number : GRANT_SECS[scope]), ...(timeout ? { timeout: timeout as { kind: "idle" | "fixed"; seconds: number } } : {}), secret: sealWith(box, bytes, grantContext(self.ws, r.id), eph), at: now },
          TAG.grant,
          signer,
        );
      };
      let grant = grantTo(r.box);
      // The station restarted since this request was read: it waits on with a new box (told, maybe not heard yet), so
      // it is read again and sealed to that one.
      const sent = yield* Effect.result(self.#station(station, "POST", "/vault/grants", grant));
      if (sent._tag === "Failure") {
        if (sent.failure.code !== "vault_refused") return yield* Effect.fail(sent.failure);
        yield* Effect.ignore(readStation(inner, `${self.ws}/${station}`), { log: "Unhandled", message: "vault station read" });
        const again = held(inner, self.ws).requests[r.id];
        if (again?.status !== "pending" || !again.box || again.box === r.box) return yield* Effect.fail(sent.failure);
        grant = grantTo(again.box);
        yield* self.#station(station, "POST", "/vault/grants", grant);
      }
      self.#settled(r.id, { status: "granted", scope, ...(timeout ? { timeout: timeout as { kind: "idle" | "fixed"; seconds: number } } : {}) });
      return { request: r.id, scope, exp: grant.exp };
    });
  }

  /// Approve a cross-workspace browse request (`secret_list` other_workspaces): re-verifies every candidate against
  /// strict personal-vault security rules, signs `BrowseAnswer` with `TAG.browse`, and posts to `/vault/browses`.
  #approveBrowse(r: Request, station: string, selected?: { workspace: string; vault: string; item: string }[]): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const { signer } = yield* self.#ready();
      const myBox = mem(inner).box;
      const wanted = selected !== undefined
        ? selected
        : browseCandidates(inner, self.ws).workspaces.flatMap((w) => w.items.map((it) => ({ workspace: w.id, vault: it.vault, item: it.item })));
      if (wanted.length === 0) return yield* fail("vault_browse_empty", t("core-misc.vault.browseEmpty"));
      const listings: CrossListing[] = [];
      const seen = new Set<string>();
      const sourceWorkspaces = new Set<string>();
      for (const pick of wanted) {
        const key = `${pick.workspace}/${pick.vault}/${pick.item}`;
        if (seen.has(key)) continue;
        seen.add(key);
        if (pick.workspace === self.ws) return yield* fail("vault_invalid", t("core-misc.vault.unknown"));
        const otherOwner = inner.workspaces.owner(pick.workspace);
        if (otherOwner === null) return yield* fail("vault_not_owner", t("core-misc.vault.notOwner"));
        const lockA = lockOf(inner, pick.workspace);
        if (lockA instanceof CoreError) return yield* Effect.fail(lockA);
        const selfA = me(lockA, signer.id);
        if (selfA === null || selfA.sub !== otherOwner) return yield* fail("vault_not_signer", t("core-misc.vault.notSigner"));
        const hA = held(inner, pick.workspace);
        const vA = hA.vaults[pick.vault];
        if (!vA || vA.deleted || vA.scope === "workspace" || vA.owner !== otherOwner) {
          return yield* fail("vault_unknown", t("core-misc.vault.unknown"));
        }
        const asA = readAs(inner, pick.workspace, lockA, vA, selfA);
        if (asA === null) {
          return yield* fail("vault_unknown", t("core-misc.vault.unknown"));
        }
        if (myBox === null || myBox === undefined || !vA.keys.some((k) => k.cert.device === selfA.device && k.cert.box === myBox)) {
          return yield* fail("vault_no_key", t("core-misc.vault.noKey"));
        }
        const itemA = items(inner, pick.workspace, vA.id)[pick.item];
        if (!itemA || !itemA.listing || crossItemReadable(inner, pick.workspace, lockA, hA, vA, selfA, myBox, itemA) === null) {
          return yield* fail("vault_unknown", t("core-misc.vault.unknownItem"));
        }
        sourceWorkspaces.add(pick.workspace);
        listings.push({
          sourceWs: pick.workspace,
          sourceWsName: workspaceName(inner, pick.workspace),
          vault: vA.id,
          vaultName: vA.name,
          ...(vA.lasts ? { vaultLasts: vA.lasts } : {}),
          item: itemA.id,
          listing: itemA.listing,
        });
      }
      if (listings.length === 0 || listings.length > 500) return yield* fail("vault_browse_empty", t("core-misc.vault.browseEmpty"));
      const answer: BrowseAnswer = sign(
        { v: 1 as const, ws: self.ws, request: r.id, items: listings, at: nowS(inner) },
        TAG.browse,
        signer,
      );
      yield* self.#station(station, "POST", "/vault/browses", answer);
      self.#settled(r.id, { status: "granted", browse: { workspaces: sourceWorkspaces.size, items: listings.length } });
      return { request: r.id, workspaces: sourceWorkspaces.size, items: listings.length };
    });
  }

  /// Approve a cross-workspace personal secret use (`r.cross`): dual-lock verified (`lockB` + `lockA`), decrypts
  /// from local SQLite cache under `wsA`, re-seals under `grantContext(wsB, r.id)` to `r.box`, and posts `Grant`
  /// with `sourceWs: wsA`.
  #approveCross(r: Request, station: string, scope: Scope, timeout?: { kind: "idle" | "fixed"; seconds: number }): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const wsA = r.cross!.workspace;
      if (wsA === self.ws) return yield* fail("vault_invalid", t("core-misc.vault.unknown"));
      const { signer } = yield* self.#ready();
      const otherOwner = inner.workspaces.owner(wsA);
      if (otherOwner === null) return yield* fail("vault_not_owner", t("core-misc.vault.notOwner"));
      const lockA = lockOf(inner, wsA);
      if (lockA instanceof CoreError) return yield* Effect.fail(lockA);
      const whoA = me(lockA, signer.id);
      if (whoA === null || whoA.sub !== otherOwner) return yield* fail("vault_not_signer", t("core-misc.vault.notSigner"));
      const hA = held(inner, wsA);
      const vA = hA.vaults[r.vault];
      if (!vA || vA.deleted || vA.scope === "workspace" || vA.owner !== otherOwner) return yield* fail("vault_unknown", t("core-misc.vault.unknown"));
      const asA = readAs(inner, wsA, lockA, vA, whoA);
      if (asA === null) return yield* fail("vault_unknown", t("core-misc.vault.unknown"));
      const itemA = items(inner, wsA, vA.id)[r.item];
      if (!itemA || itemA.deleted || itemA.listing === undefined) {
        return yield* fail("vault_unknown", t("core-misc.vault.unknownItem"));
      }
      let keyVault = vA;
      let itemLock = asA;
      if (itemA.epoch < vA.epoch) {
        const b = hA.before?.[vA.id]?.[String(itemA.epoch)];
        const was = b === undefined ? null : tookAs(inner, wsA, b);
        if (b === undefined || was === null) {
          return yield* fail("vault_unknown", t("core-misc.vault.unknownItem"));
        }
        keyVault = b;
        itemLock = was;
      } else if (itemA.epoch !== vA.epoch) {
        return yield* fail("vault_unknown", t("core-misc.vault.unknownItem"));
      }
      if (rules.item_ok_js(itemLock, keyVault, null, itemA, true, rulesCrypto) !== null) {
        return yield* fail("vault_untrusted", t("core-misc.vault.untrusted"));
      }
      if (!allows(itemA.listing.lasts ?? vA.lasts, scope)) return yield* fail("vault_scope", t("core-misc.vault.scopeTooLong"));
      const mineA = keyVault.keys.find((k) => k.cert.device === whoA.device);
      if (!mineA) return yield* fail("vault_no_key", t("core-misc.vault.noKey"));
      const priv = yield* self.#boxKey(t("core-misc.vault.reason.approve", { name: itemA.listing.name }));
      if (boxPublic(priv) !== mineA.cert.box) return yield* fail("vault_no_key", t("core-misc.vault.noKey"));
      const vaultKey = yield* Effect.try({ try: () => openSeal(priv, mineA.wrapped, keyContext(wsA, vA.id, keyVault.epoch)), catch: asCoreError });
      const bytes = yield* Effect.try({ try: () => decrypt(vaultKey, itemA.ct, itemContext(wsA, vA.id, itemA.id, itemA.version, itemA.epoch)), catch: asCoreError });
      const grantTo = (box: string): Grant => {
        const eph = new Uint8Array(32);
        inner.host.randomBytes(eph);
        const now = nowS(inner);
        return sign(
          {
            v: 1 as const, ws: self.ws, request: r.id, vault: vA.id, item: itemA.id, mode: r.mode as Grant["mode"],
            hosts: r.hosts ?? itemA.listing!.hosts ?? [], scope, exp: now + (timeout ? timeout.seconds : GRANT_SECS[scope]),
            ...(timeout ? { timeout } : {}), sourceWs: wsA,
            secret: sealWith(box, bytes, grantContext(self.ws, r.id), eph), at: now,
          },
          TAG.grant,
          signer,
        );
      };
      let grant = grantTo(r.box);
      const sent = yield* Effect.result(self.#station(station, "POST", "/vault/grants", grant));
      if (sent._tag === "Failure") {
        if (sent.failure.code !== "vault_refused") return yield* Effect.fail(sent.failure);
        yield* Effect.ignore(readStation(inner, `${self.ws}/${station}`), { log: "Unhandled", message: "vault station read" });
        const again = held(inner, self.ws).requests[r.id];
        if (again?.status !== "pending" || !again.box || again.box === r.box) return yield* Effect.fail(sent.failure);
        grant = grantTo(again.box);
        yield* self.#station(station, "POST", "/vault/grants", grant);
      }
      self.#settled(r.id, { status: "granted", scope, ...(timeout ? { timeout } : {}) });
      return { request: r.id, scope, exp: grant.exp };
    });
  }

  /// A secret an agent asked to keep, approved. The plain library's is written by the station that asked (with what the
  /// person typed in, where it was theirs to). A vault's is opened with this device's box key (that station sealed it to
  /// the person's devices set up), or is what they typed in, written under the request's item id into one of their
  /// vaults this device holds a key to (the one asked for first, their own next; a new one only when they have none of
  /// their own: one this device has no key to yet, refused), its copy brought to that station, which is then told where
  /// it went, with the grant that lets the asking chat use it. Either way the chat that asked may use it at once.
  #keepSaved(r: Request, station: string, typed: unknown, targetVault?: string): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const s = r.save!;
      const given = s.typed ? typedFields(s, typed) : null;
      if (given === undefined) return yield* fail("vault_typed_empty", t("core-misc.vault.typedEmpty"));
      if (given instanceof CoreError) return yield* Effect.fail(given);
      if (r.vault === PLAIN) {
        if (!plainMode(self.#inner, self.ws)) return yield* fail("vault_locked", t("core-misc.vault.plainLocked"));
        yield* self.#station(station, "POST", "/vault/plain/saves", { request: r.id, ...(given ? { fields: given } : {}) });
        self.#settled(r.id, { status: "granted" });
        return { request: r.id, item: r.item };
      }
      const { lock, signer, self: who } = yield* self.#ready();
      // The box key it is kept with: the one the station sealed it to here, or (typed in) this device's the lock vouches.
      const sealed = (r.sealed ?? []).find((x) => x.device === who.device);
      const box = given ? certs(inner, self.ws, lock).find((c) => c.device === who.device)?.box : sealed?.box;
      if (box === undefined) return yield* (given ? fail("vault_not_set_up", t("core-misc.vault.notSetUp")) : fail("vault_no_key", t("core-misc.vault.notSealedHere")));
      const keyedHere = (v: Vault) => trusted(lock, v) && v.members.includes(who.sub) && v.keys.some((k) => k.cert.device === who.device && k.cert.box === box);
      const h = held(inner, self.ws);
      // (a secret is written into no vault waiting to be keyed anew: the one asked for, or their own when it is the one
      // it would go to, refused saying the station it waits for, not put elsewhere nor a second one made)
      const waitsHere = (v: Vault) => v.members.includes(who.sub) && waitingAs(inner, self.ws, lock, v) !== null;
      let chosen: Vault | undefined;
      if (targetVault !== undefined && targetVault !== "") {
        const explicit = h.vaults[targetVault];
        if (explicit === undefined || explicit.deleted) return yield* fail("vault_unknown", t("core-misc.vault.unknown"));
        if (waitsHere(explicit)) return yield* Effect.fail(waitingError(inner, self.ws, explicit));
        if (!keyedHere(explicit)) return yield* fail("vault_no_key", t("core-misc.vault.noKey"));
        chosen = explicit;
      } else {
        const reqPersonal = h.vaults[r.vault] !== undefined && h.vaults[r.vault]!.scope !== "workspace" ? h.vaults[r.vault] : undefined;
        if (reqPersonal !== undefined && waitsHere(reqPersonal)) return yield* Effect.fail(waitingError(inner, self.ws, reqPersonal));
        const theirs = Object.values(h.vaults).filter(keyedHere).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : a.id < b.id ? -1 : 1));
        chosen = (reqPersonal && keyedHere(reqPersonal) ? reqPersonal : undefined) ?? theirs.find((x) => x.scope !== "workspace" && x.owner === who.sub);
        const ownWaiting = chosen ? undefined : Object.values(h.vaults).find((v) => v.scope !== "workspace" && v.owner === who.sub && waitsHere(v));
        if (ownWaiting !== undefined) return yield* Effect.fail(waitingError(inner, self.ws, ownWaiting));
        // Their own personal vault this device has no key to yet: given it by a device that has (not a second one made here).
        if (!chosen && Object.values(h.vaults).some((v) => !v.deleted && v.scope !== "workspace" && trusted(lock, v) && v.owner === who.sub)) return yield* fail("vault_no_key", t("core-misc.vault.noKey"));
      }
      const priv = yield* self.#boxKey(t("core-misc.vault.reason.save", { name: s.name }));
      if (boxPublic(priv) !== box) return yield* fail("vault_no_key", t(given ? "core-misc.vault.noKey" : "core-misc.vault.notSealedHere"));
      const body = yield* Effect.try({
        try: () => {
          const fields = given ?? JSON.parse(new TextDecoder().decode(openSeal(priv, sealed!.secret, saveContext(self.ws, r.id))));
          return {
            plain: plainOf({ kind: s.kind, name: s.name, fields, domains: [], notes: s.about ?? "" }),
            listing: listingOf({ name: s.name, kind: s.kind, modes: s.modes, hosts: s.hosts, ...(s.env ? { env: s.env } : {}), ...(s.about ? { about: s.about } : {}) }),
          };
        },
        catch: asCoreError,
      });
      let v = chosen;
      if (!v) {
        const made = (yield* self.create(t("core-misc.vault.personal"), null)) as { id: string };
        v = held(inner, self.ws).vaults[made.id];
        if (!v) return yield* fail("vault_unknown", t("core-misc.vault.unknown"));
      }
      const vault = v;
      // Its key: kept unsealed a while, else opened with the box key just read (the person is asked once).
      const kept = mem(inner).keys.get(keyOf(vault));
      const wrapped = vault.keys.find((k) => k.cert.device === who.device)!.wrapped;
      const key = kept && kept.until > inner.host.nowMs() ? kept.key : yield* Effect.try({ try: () => openSeal(priv, wrapped, keyContext(self.ws, vault.id, vault.epoch)), catch: asCoreError });
      self.#keep(vault, key);
      inner.runner.fork(Effect.ignore(self.#give(vault.id, vault.epoch, key, null), { log: "Unhandled", message: "vault key given" }));
      // Written once: an approval tried again after the station was not told finds it there.
      const had = items(inner, self.ws, vault.id)[r.item];
      if (had?.deleted) return yield* fail("vault_unknown", t("core-misc.vault.unknownItem"));
      if (had === undefined) {
        const nonce = new Uint8Array(12);
        inner.host.randomBytes(nonce);
        const ct = encryptWith(key, utf8(JSON.stringify(body.plain)), itemContext(self.ws, vault.id, r.item, 0, vault.epoch), nonce);
        const next = sign({ v: 1 as const, ws: self.ws, vault: vault.id, id: r.item, version: 0, epoch: vault.epoch, ct, ...(body.listing ? { listing: body.listing } : {}), at: nowS(inner) }, TAG.item, signer);
        yield* self.#putItem(next, vault);
      }
      // Keeping it lets the chat that asked use it, for as long as the vault's items are given: its grant sealed to the
      // request's box (a station from before boxes none: no grant then).
      const scope: Scope = allows(body.listing?.lasts ?? vault.lasts, "hour") ? "hour" : "once";
      const now = nowS(inner);
      const eph = new Uint8Array(32);
      inner.host.randomBytes(eph);
      const saveMode = r.mode === "browse" ? "proxy" : r.mode;
      const grant: Grant | null = r.box
        ? sign(
            { v: 1 as const, ws: self.ws, request: r.id, vault: vault.id, item: r.item, mode: saveMode, hosts: saveMode === "proxy" || saveMode === "browser" ? (r.hosts ?? s.hosts) : [], scope, exp: now + GRANT_SECS[scope], ...(scope === "hour" ? { timeout: { kind: "idle" as const, seconds: 3600 } } : {}), secret: sealWith(r.box, utf8(JSON.stringify(body.plain)), grantContext(self.ws, r.id), eph), at: now },
            TAG.grant,
            signer,
          )
        : null;
      // The station that asked holds its copy before it is told.
      yield* spread(inner, `${self.ws}/${station}`);
      yield* self.#station(station, "POST", "/vault/saves", { request: r.id, vault: vault.id, ...(grant ? { grant } : {}) });
      self.#settled(r.id, { status: "granted", ...(grant ? { scope } : {}) });
      return { request: r.id, vault: vault.id, item: r.item, ...(grant ? { scope } : {}) };
    });
  }

  /// An agent's request to rename an item or change its about, approved: the plain library's written by its station; a
  /// vault's item opened here and written as its next version saying so (its listing too, what agents read), its copy
  /// brought to the station that asked, which is then told. It grants nothing.
  #describe(r: Request, station: string): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const d = r.describe!;
      if (typeof d.name !== "string" || d.name.trim() === "" || typeof d.about !== "string") return yield* Effect.fail(CoreError.invalid("describe: {name, about}"));
      if (r.vault === PLAIN) {
        if (!plainMode(inner, self.ws)) return yield* fail("vault_locked", t("core-misc.vault.plainLocked"));
        yield* self.#station(station, "POST", "/vault/plain/described", { request: r.id });
        self.#settled(r.id, { status: "granted" });
        return { request: r.id, item: r.item };
      }
      const opened = (yield* self.open(r.item)) as { vault: string; plain: Plain };
      const item = items(inner, self.ws, opened.vault)[r.item];
      if (!item || item.deleted) return yield* fail("vault_unknown", t("core-misc.vault.unknownItem"));
      const { about: _, ...listing } = item.listing ?? { name: d.name, kind: opened.plain.kind, modes: [], hosts: [] };
      // (one agents may not ask for keeps no listing: its name and notes alone change)
      yield* self.putItem(opened.vault, r.item, { ...opened.plain, name: d.name, notes: d.about }, item.listing ? { ...listing, name: d.name, ...(d.about ? { about: d.about } : {}) } : null);
      // The station that asked holds its copy before it is told.
      yield* spread(inner, `${self.ws}/${station}`);
      yield* self.#station(station, "POST", "/vault/described", { request: r.id });
      self.#settled(r.id, { status: "granted" });
      return { request: r.id, item: r.item };
    });
  }

  /// An agent's request to delete an item, approved: the plain library's deleted by its station; a vault's item deleted
  /// here (its deleted version signed by this device), its copy brought to the station that asked, which is then told.
  /// It grants nothing.
  #remove(r: Request, station: string): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      if (r.vault === PLAIN) {
        if (!plainMode(inner, self.ws)) return yield* fail("vault_locked", t("core-misc.vault.plainLocked"));
        yield* self.#station(station, "POST", "/vault/plain/removed", { request: r.id });
        self.#settled(r.id, { status: "granted" });
        return { request: r.id, item: r.item };
      }
      const item = items(inner, self.ws, r.vault)[r.item];
      // (gone already, by another device or from its page: what is left is to say so)
      if (item && !item.deleted) yield* self.deleteItem(r.vault, r.item);
      // The station that asked holds its copy before it is told.
      yield* spread(inner, `${self.ws}/${station}`);
      yield* self.#station(station, "POST", "/vault/removed", { request: r.id });
      self.#settled(r.id, { status: "granted" });
      return { request: r.id, item: r.item };
    });
  }

  deny(id: string): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const asked = yield* self.#request(id);
      if (asked.r.vault === PLAIN) {
        if (!plainMode(self.#inner, self.ws)) return yield* fail("vault_locked", t("core-misc.vault.plainLocked"));
        const { r, station } = asked;
        yield* self.#station(station, "POST", "/vault/plain/denials", { request: r.id });
        self.#settled(r.id, { status: "denied" });
        return { request: r.id };
      }
      // (a secret to keep, no safe mode, their own lock begun nowhere yet: turned down with this app's signer, which the
      // station takes from whoever it is kept for, station/src/vault/secrets.ts `deny`; no vault turned on for it)
      const signer = (asked.r.save !== undefined || asked.r.browse !== undefined || asked.r.cross !== undefined) && able(self.#inner) && personalNone(self.#inner, self.ws) ? yield* Signer.make(self.#inner.host) : (yield* self.#ready()).signer;
      const { r, station } = yield* self.#request(id);
      const deny: Deny = sign({ v: 1 as const, ws: self.ws, request: r.id, at: nowS(self.#inner) }, TAG.deny, signer);
      yield* self.#station(station, "POST", "/vault/denials", deny);
      self.#settled(r.id, { status: "denied" });
      return { request: r.id };
    });
  }

  // ── the plain library ( 不加锁的库) ──

  /// An item of the plain library written on its station (a new one on the station keeping the library), the version
  /// after the one held.
  putPlain(id: string | null, plain: unknown, listing: unknown): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const body = yield* Effect.try({ try: () => ({ plain: plainOf(plain), listing: listingOf(listing) }), catch: asCoreError });
      if (!plainMode(inner, self.ws)) return yield* fail("vault_locked", t("core-misc.vault.plainLocked"));
      const h = held(inner, self.ws);
      const prev = id ? h.plain[id] : undefined;
      if (id && (!prev || prev.deleted)) return yield* fail("vault_unknown", t("core-misc.vault.unknownItem"));
      const station = prev?.station ?? vaultsView(inner, self.ws).vaults[0]?.station;
      if (!station) return yield* fail("vault_no_station", t("core-misc.vault.noPlainStation"));
      const next = {
        id: id ?? `i_${ulid(inner.host)}`, version: prev ? prev.version + 1 : 0, kind: body.plain.kind, name: body.plain.name, fields: body.plain.fields, notes: body.plain.notes,
        ...(body.listing ? { listing: body.listing } : {}), at: nowS(inner),
      };
      return yield* self.#putPlainRow(station, next);
    });
  }

  deletePlain(id: string): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const prev = held(self.#inner, self.ws).plain[id];
      if (!prev || prev.deleted) return yield* fail("vault_unknown", t("core-misc.vault.unknownItem"));
      return yield* self.#putPlainRow(prev.station, { id, version: prev.version + 1, kind: prev.kind, name: "", fields: {}, notes: "", at: nowS(self.#inner), deleted: true });
    });
  }

  /// A plain item's version taken by its station, held here as it said it; not the next (written elsewhere meanwhile):
  /// the library read again before it fails.
  #putPlainRow(station: string, next: J): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const said = yield* Effect.tapError(self.#station(station, "PUT", "/vault/plain", next), (e) =>
        e.code === "vault_conflict" ? Effect.ignore(readStation(self.#inner, `${self.ws}/${station}`), { log: "Unhandled", message: "vault station read" }) : Effect.void,
      );
      const item = (get(said, "item") as PlainRow | undefined) ?? (({ fields: _, ...rest }) => rest)(next);
      change(self.#inner, self.ws, (h) => void (h.plain[item.id] = { ...item, station }));
      return { id: item.id, version: item.version };
    });
  }

  /// What a plain item holds, as its station keeps it (nobody asked: nothing is sealed).
  openPlain(id: string): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const row = held(self.#inner, self.ws).plain[id];
      if (!row || row.deleted) return yield* fail("vault_unknown", t("core-misc.vault.unknownItem"));
      const i = get(yield* self.#station(row.station, "GET", `/vault/plain/item?id=${encodeURIComponent(id)}`, null), "item") as J;
      const fields: Record<string, string> = {};
      for (const [k, x] of Object.entries(isObject(i?.fields) ? (i.fields as Record<string, unknown>) : {})) if (typeof x === "string") fields[k] = x;
      return { vault: PLAIN, id, version: Number(get(i, "version") ?? row.version), plain: { kind: get(i, "kind") ?? row.kind, name: get(i, "name") ?? row.name, fields, domains: [], notes: str(get(i, "notes")) ?? "" } };
    });
  }

  /// The person's own vaults' items opened (their plaintext and listing), for security mode turned off.
  unsealOwn(reason?: string, asked?: () => void): Effect.Effect<{ plain: Plain; listing: Listing | null }[], CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      if (!able(inner) || lockOf(inner, self.ws) instanceof CoreError) return [];
      const ready = yield* Effect.result(self.#ready());
      if (ready._tag === "Failure") return [];
      const { lock, self: who } = ready.success;
      const out: { plain: Plain; listing: Listing | null }[] = [];
      for (const v of Object.values(held(inner, self.ws).vaults)) {
        // (read: one waiting to be keyed anew too, its items checked against the lock that took it; personal vaults only)
        const as = readAs(inner, self.ws, lock, v, who);
        if (as === null || v.scope === "workspace" || v.owner !== who.sub || !v.keys.some((k) => k.cert.device === who.device)) continue;
        const why = reason ?? t("core-misc.vault.reason.unlock", { name: v.name });
        // (those left under an earlier key carried on first: none of them is lost as the lock goes)
        if (underEarlier(inner, self.ws, v).length > 0) yield* self.carryOn(v.id, why, undefined, { asked: () => asked?.() });
        const all = Object.values(items(inner, self.ws, v.id)).filter((i) => !i.deleted && i.epoch === v.epoch);
        if (all.length === 0) continue;
        const key = yield* self.#key(v, who, false, why, true, () => asked?.());
        for (const item of all) {
          const bytes = yield* Effect.result(self.#plain(as, v, item, key));
          if (bytes._tag === "Success") out.push({ plain: plainOf(JSON.parse(new TextDecoder().decode(bytes.success))), listing: item.listing ?? null });
        }
      }
      return out;
    });
  }

  /// Security mode on: each item left in the plain library written into the person's own vault (encrypted, its listing
  /// kept), then deleted where it was; one the vault holds already (written back when security mode was off, and on
  /// again) only deleted. One that fails stays, said in the count.
  migrate(): Effect.Effect<unknown, CoreError> {
    const self = this;
    return Effect.gen(function* () {
      const inner = self.#inner;
      const { lock, self: who } = yield* self.#ready();
      // (one this device holds a key to first; personal vaults only, never migrate plain secrets into a shared workspace vault)
      const owns = Object.values(held(inner, self.ws).vaults).filter((v) => !v.deleted && v.scope !== "workspace" && trusted(lock, v) && v.owner === who.sub);
      const own = owns.find((v) => v.keys.some((k) => k.cert.device === who.device)) ?? owns[0];
      // (their own waiting to be keyed anew: nothing moved into it till it is)
      const waiting = own ? undefined : Object.values(held(inner, self.ws).vaults).find((v) => v.scope !== "workspace" && v.owner === who.sub && waitingAs(inner, self.ws, lock, v) !== null);
      if (waiting !== undefined) return yield* Effect.fail(waitingError(inner, self.ws, waiting));
      if (!own) return yield* fail("vault_not_set_up", t("core-misc.vault.notSetUp"));
      const same = (p: Plain) => JSON.stringify([p.kind, p.name, p.fields]);
      const had = new Set((yield* self.unsealOwn()).map((s) => same(s.plain)));
      let moved = 0;
      let left = 0;
      for (const row of Object.values(held(inner, self.ws).plain)) {
        if (row.deleted) continue;
        const done = yield* Effect.result(Effect.gen(function* () {
          const opened = (yield* self.openPlain(row.id)) as { plain: Plain };
          if (!had.has(same(plainOf(opened.plain)))) yield* self.putItem(own.id, null, opened.plain, row.listing ?? null);
          yield* self.deletePlain(row.id);
        }));
        if (done._tag === "Success") moved++;
        else left++;
      }
      return { moved, left };
    });
  }

  /// A request answered here (how: `outcome`): no longer waiting (the station says so too, as it tells it), with how it
  /// went shown on its card in the chat at once.
  #settled(id: string, outcome: VaultOutcome): void {
    this.#inner.views?.local.vaultDecided(id, outcome);
    change(this.#inner, this.ws, (h) => {
      delete h.requests[id];
      delete h.asked[id];
    });
  }
}
