// Made-up settings in the core's shapes (WorkspaceView, StationView, LockView, VaultsView, ProfilesView, ConnectsView,
// UsageView, ArchiveView, StationMemory…) for the app with no core (src/sffix): screenshots that are the same on every
// run (scripts/shots.sh settings, web-settings). Every word here is made up. The workspace is the fixture's own ws1
// (星火工作室, lin@example.com), its stations ws1/st1 (Willow) and ws1/st2 (Maple, offline).

///|
/// What the made-up settings changed since they started (a station renamed, a chat restored), and how often.
priv struct SettingsFixture {
  names : Map[String, String]
  restored : Map[String, Bool]
  mut version : Int
  /// the stations' marks set (by id)
  marks : Map[String, String]
  /// the station's updating by itself
  mut auto : Bool
  /// the station's congestion control
  mut congestion : String
  /// the station going on afresh by itself once a session's cache is over, and its cost threshold
  mut afresh : Bool
  mut afresh_above : Double
  /// the station sending its log to still.fail
  mut logs : Bool
  /// whether this station accepts automatically assigned new chats and presets
  mut accept_auto_chats : Bool
  /// whether 公司 Claude's share follows the workspace's whitelist (`profile.share` `allowAuto` said so)
  mut cc_follows : Bool
  /// a Windows station's running as administrator, as the core shows it (its overview's `elevation`), as a test sets
  /// it; none: not a Windows station
  mut elevation : Json?
  /// a Windows station's optional LocalSystem screen service, as the core shows it (its overview's `screenService`),
  /// as a test sets it; none: not a Windows station
  mut screen_service : Json?
  /// the copies of its chats as the core shows them (its overview's `copies`), as a mode sets them; none: a station
  /// from before them
  mut copies : Json?
  /// The station with two GPUs, for the resource overview's fixture.
  mut gpus : Bool
  /// Four GPUs, to exercise another row of resource dials.
  mut more_gpus : Bool
  /// Willow's CPU, memory and disk all running low (settings-stations-low): its card's line of three chips.
  mut low_meters : Bool
  /// Its stations given no mark (settings-stations-unmarked: 1), and so shown by their systems' icons as the core
  /// gives them (settings-stations-os: 2, client-core station-os.ts); 0 the marks they are given
  mut os_icons : Int
  /// the mode's page has no station (settings-first-station)
  mut none : Bool
  /// the subscription's sign-in: "" none, "needs_code" under way (settings-profile-login), "failed"
  /// (settings-profile-login-failed)
  mut login : String
  /// the sign-in's page can be opened in the station's own browser (settings-profile-login-station,
  /// settings-new-profile-login-station)
  mut login_station : Bool
  /// a new profile's page at an Anthropic plan's sign-in, waiting for the code (settings-new-profile-login…)
  mut new_login : Bool
  /// a new profile's draft at a key's form with a region and a protocol to choose (settings-new-profile-key)
  mut new_key : Bool
  /// Claude 主账号's trouble: "" none, "quota" its allowance unreadable (settings-profile-quota-failed), "verify" its
  /// provider refusing the account until it is verified at a link (settings-profile-verify), "blocked"
  /// its provider refusing it for its allowance used up (settings-profile-blocked), "login" to be signed in to again (settings-profile-signin)
  mut trouble : String
  /// the vault not set up on this device (settings-vault-off: on nowhere, no vault of theirs; settings-vault-elsewhere:
  /// on another device of theirs, their vault there with no key here yet)
  mut vault_off : Bool
  /// lin's vault on on another device of theirs, this one not set up yet (settings-vault-elsewhere): its row not keyed here
  mut vault_elsewhere : Bool
  /// secrets of lin's still in plain text from before security mode (settings-vault-plain), until encrypted
  mut plain_left : Int
  /// lin's own vault waiting to be keyed anew on Willow, a device holding its key taken out of the lock
  /// (settings-vault-waits): its row's `waits`
  mut vault_waits : Bool
  /// the workspace in no safe mode, the vault its person's own (settings-vault-own-…): "" in safe mode; "off" not turned on
  /// yet (开启 begins their own lock); "on" turned on here; "outside" this device to be approved by another of theirs
  mut vault_own : String
  /// shared workspace vault fixture mode: "" none, "create" admin can create one, "has" workspace vault exists
  mut vault_workspace : String
  /// members of the workspace vault in the fixture
  vault_workspace_members : Array[String]
  /// the skills shared (true) or no longer (false) since the run started (`skill.share`), by name
  skills_shared : Map[String, Bool]
  /// the quota's resets used on ChatGPT 团队 (`profile.resetQuota`)
  mut resets_used : Int
  /// Two reset credits with distinct expiry times (settings-profile-quota-expiry).
  mut reset_expiry : Bool
  /// Claude 主账号's resets of two kinds: a 5-hour one usable only at a limit, a Fable one usable now, used by
  /// `profile.resetQuota` with its kind (settings-profile-quota-kinds).
  mut reset_kinds : Bool
  /// the Fable reset used (`profile.resetQuota` with `reset: model`)
  mut fable_used : Bool
  /// the models named by hand on ChatGPT 团队 (`profile.addModel`)
  models_added : Array[String]
  /// Whether the example API key is enabled.
  mut key_enabled : Bool
  /// Claude 主账号's configured maxConcurrentSessions (null = unlimited) and new-account protection flag.
  mut cc_max_sessions : Json
  mut cc_protection : Bool
  /// A copy of Maple's Claude subscription among Willow's profiles (settings-profile-copy), and whether Willow uses it.
  mut copy_shown : Bool
  mut copy_enabled : Bool
  /// a new device of lin's asking to be let in with this one's code (settings-lock-prompt), until turned away or its
  /// prompt closed
  mut pairing : Bool
  mut pairing_personal : Bool
  /// asked into one more workspace meanwhile (开源, its mark an emoji): fixture_prompts_now
  mut pairing_more : Bool
  /// pairing prompt with deviceCode, build, willSign, and handoverVaults (settings-pair-prompt)
  mut pairing_clarity : Bool
  /// Maple is being added to security mode (settings-security-protecting).
  mut protecting : Bool
  /// the lock's changes made here that no station took yet, by id (settings-security-pending: `fx_pending_rows`),
  /// a failed one dropped by `lock.pendingDismiss`
  pending : Array[String]
  /// what the upgrade of safe mode waits for, as the core's `upgrade` says it on the owner's device that is to finish it
  /// (settings-security-upgrade-…: `fx_upgrade`), "" none
  mut upgrade : String
  /// how an upgraded workspace's safe mode stands for this device and person (security.mbt, vault.mbt, lock_prompts.mbt):
  /// "confirm" this device to verify once on its person's own lock (not signing meanwhile: not a signer, not trusted,
  /// removing none of its person's other devices), "syncing" not signing for what comes by itself,
  /// "root" on and "root-off" off by another person alone, "again" off by this person, "role" the new device's prompt
  /// saying the role approving lets them in as; "" none
  mut lock_case : String
  /// what a press made of a device waiting on its person's own lock (lock-restart, lock-replaced): "rebound" made its
  /// person's only trusted device (`lock.restartOwn`), "asked" the lock begun anew elsewhere confirmed theirs
  /// (`lock.forgetOwn`); "" as its mode says
  mut own_after : String
  /// safe mode's change of this device at work (`lock.confirmSigner`, `lock.open`) and the workspace it is of, "" none
  mut lock_doing : String
  mut lock_doing_ws : String
  /// how its prompt went: "deny" (turned away), "hide" (closed, the code still good), "" while it is up
  mut pair_ended : String
  /// a code typed on the page that waits (fixture_pair_typed): how far it got, "" none typed; how many were typed
  mut pair_flow : String
  mut pair_typed : Int
  /// a device of lin's (Pixel 9) set up without the key to 林的库, waiting on this one for it (settings-vault-prompt),
  /// until given it or put away
  mut key_ask : Bool
  /// how that went: "give" (授权), "hide" (稍后, or closed), "" while it is up
  mut key_ask_ended : String
  /// the key being given it (the core's `doing`: vault.addDevice under way): fixture_prompts_now
  mut key_giving : Bool
  /// whether the workspace in key_ask is in safe mode (false tests the non-safe-mode prompt wording)
  mut key_ask_safe_mode : Bool
  /// this device's verification code shown on vault no-key card (settings-vault-no-key-code)
  mut this_device_code : String
  /// whether pending device d-new on v-ws has been authorized in the current fixture run
  mut vault_ws_pending_done : Bool
  /// Maple online too (settings-profiles-pick: Profile's ＋ asks which station)
  mut mba_online : Bool
  /// how many other stations are online to take Willow's chats as it is retired (settings-station-retire…): 1 Maple,
  /// 2 Cedar besides; 0 neither (Maple as it is)
  mut retire_others : Int
  /// the workspace Willow is retired from is its home (its accounts go along); false: one it joined (they stay)
  mut retire_home : Bool
  // (settings-station-away: Willow away, what it last said of itself kept)
  mut willow_away : Bool
  // (settings-stations-incompatible: Willow up, saying what this core cannot read)
  mut willow_incompatible : Bool
  // (settings-stations-tasks-theirs: Willow added by another member, seen by a plain member: its mode not theirs to change)
  mut willow_theirs : Bool
  /// the subscriptions' allowances a month's window too, three in all (settings-profiles-monthly: OpenCode Go's)
  mut monthly : Bool
  /// the Claude subscription's allowance its models' own weeks too, under the account's: how many of Fable's, Opus's
  /// (nearly spent) and Sonnet's (settings-profiles-fable, settings-profile-fable: one; …-own3: all three, five windows)
  mut own : Int
  /// that subscription with no 5 小时 window (…-week-fable: the account's week and Fable's alone, as an account says
  /// them whose short window has not begun)
  mut no_hours : Bool
  /// five Claude subscription accounts, by their e-mails, each its own windows as a report showed them
  /// (settings-profiles-several: one row's figures a point wider than the others')
  mut several : Bool
  /// Willow's own Codex login, not a profile yet, with its allowance as the core sends an offered login's
  /// (settings-profiles-offer: what is left of its week shown where it is listed, as a profile's is)
  mut offer_quota : Bool
  /// The same subscription independently signed in and borrowed on several stations.
  mut profile_hosts : Bool
  /// ChatGPT 团队 of a kind of login that cannot be shared (the station's `shareable` false:
  /// settings-profile-unshareable): its page says so in place of the switch.
  mut profile_unshareable : Bool
  /// Only one station is signed in; another borrows it.
  mut profile_one_owner : Bool
  /// A borrowing station cannot reach its source, and another station is offline.
  mut profile_away : Bool
  /// A station may use the account, but its copy has not arrived yet.
  mut profile_pending : Bool
  /// That station is cut off from still.fail cloud, so the copy does not come.
  mut profile_cut_off : Bool
  /// how far the made-up workspace has changed on its own (settings-workspace-motion, settings-stations-motion): 1 a
  /// person and a station come, 2 one of each goes (fixture_motion)
  mut motion : Int
  /// the bytes of the drives' files kept (`cache.usage`'s `drive`), until let go (`drive.kept.clear`)
  mut drive_kept : Double
  /// the chats' files kept let go (`cache.file.clear`), by name
  kept_cleared : Array[String]
  /// the workspace's own relays added since the run started (`workspace.setRelays`)
  relays : Array[String]
  /// whether still.fail's relays were turned off (`workspace.setWay` with `way: "ours"`)
  mut ours_off : Bool
  /// whether the profiles' overview uses the multi-pool summary fixture (`settings-profiles-sum-a`)
  mut summary : Bool
}

///|
let fx : SettingsFixture = {
  names: {},
  restored: {},
  version: 0,
  marks: {},
  auto: false,
  congestion: "cubic",
  afresh: false,
  afresh_above: 1.0,
  logs: true,
  accept_auto_chats: false,
  cc_follows: false,
  elevation: None,
  screen_service: None,
  copies: None,
  gpus: false,
  more_gpus: false,
  low_meters: false,
  os_icons: 0,
  none: false,
  login: "",
  login_station: false,
  new_login: false,
  new_key: false,
  trouble: "",
  vault_off: false,
  vault_elsewhere: false,
  plain_left: 0,
  vault_waits: false,
  vault_own: "",
  vault_workspace: "",
  vault_workspace_members: ["u1", "u2", "u3"],
  skills_shared: {},
  resets_used: 0,
  reset_expiry: false,
  reset_kinds: false,
  fable_used: false,
  models_added: [],
  key_enabled: true,
  cc_max_sessions: Json::number(8.0),
  cc_protection: true,
  copy_shown: false,
  copy_enabled: true,
  pairing: false,
  pairing_personal: false,
  pairing_more: false,
  pairing_clarity: false,
  protecting: false,
  pending: [],
  upgrade: "",
  lock_case: "",
  own_after: "",
  lock_doing: "",
  lock_doing_ws: "",
  pair_ended: "",
  pair_flow: "",
  pair_typed: 0,
  key_ask: false,
  key_ask_ended: "",
  key_giving: false,
  key_ask_safe_mode: true,
  this_device_code: "",
  vault_ws_pending_done: false,
  mba_online: false,
  retire_others: 0,
  retire_home: true,
  willow_away: false,
  willow_incompatible: false,
  willow_theirs: false,
  monthly: false,
  own: 0,
  no_hours: false,
  several: false,
  offer_quota: false,
  profile_hosts: false,
  profile_unshareable: false,
  profile_one_owner: false,
  profile_away: false,
  profile_pending: false,
  profile_cut_off: false,
  motion: 0,
  drive_kept: fx_drive_kept,
  kept_cleared: [],
  relays: [],
  ours_off: false,
  summary: false,
}

///|
/// A chat's file kept (`cache.usage`'s `files`, `loose`): its session, its name, its size, the bytes kept of it, when
/// it was last opened (the fixture's clock stands at 0), unless let go.
fn fx_kept_file(key : String, name : String, size : Double, bytes : Double, opened : Double, station? : String) -> Json? {
  if fx.kept_cleared.contains(name) {
    return None
  }
  let o : Map[String, Json] = {
    "key": str(key),
    "name": str(name),
    "size": Json::number(size),
    "bytes": Json::number(bytes),
    "opened": Json::number(opened),
  }
  match station {
    Some(s) => o["station"] = str(s)
    None => ()
  }
  Some(Json::object(o))
}

///|
/// lin's own vault, 林的库 on Willow, as the core's `vaults` lists it: waiting to be keyed anew there (`waits`) in
/// settings-vault-waits only, as the core says it only while it does.
fn fx_vault_row() -> Json {
  let row : Array[(String, Json)] = [
    ("id", str("v1")),
    ("name", str("林的库")),
    ("owner", str("u1")),
    ("ownerName", str("林")),
    ("mine", Json::boolean(true)),
    ("members", []),
    ("station", str("st1")),
    ("stationName", str("Willow")),
    ("items", Json::number(3.0)),
    ("devices", Json::number(2.0)),
    ("open", Json::boolean(false)),
    ("keyed", Json::boolean(!fx.vault_elsewhere)),
    ("missing", Json::number(0.0)),
    ("recoverable", Json::boolean(true)),
    (
      "authorizedDevices",
      Json::array([
        obj([
          ("device", str("d-mac")),
          ("deviceText", str("林的 MacBook Pro · still.fail")),
          ("deviceCode", str("A3B-9CD")),
          ("ownerName", str("林")),
          ("ownerEmail", str("lin@example.com")),
          ("current", Json::boolean(true)),
          ("at", Json::number(0.0)),
          ("atText", str("1 小时前")),
        ]),
        obj([
          ("device", str("d-ios")),
          ("deviceText", str("林的 iPhone · still.fail")),
          ("deviceCode", str("M4N-8PQ")),
          ("ownerName", str("林")),
          ("ownerEmail", str("lin@example.com")),
          ("current", Json::boolean(false)),
          ("at", Json::number(0.0)),
          ("atText", str("昨天")),
        ]),
      ]),
    ),
    ("pendingDevices", []),
  ]
  if fx.vault_waits {
    row.push(("waits", str("Willow")))
  }
  obj(row)
}

///|
/// The shared workspace vault in the fixture (`settings-vault-workspace*`).
fn fx_workspace_vault_row() -> Json {
  let pending_dev = obj([
    ("device", str("d-new")),
    ("deviceText", str("Pixel 9 · still.fail Android")),
    ("deviceCode", str("K7M-4PX")),
    ("ownerName", str("林")),
    ("ownerEmail", str("lin@example.com")),
    ("current", Json::boolean(false)),
    ("at", Json::number(0.0)),
    ("atText", str("3 分钟前")),
  ])
  let authorized : Array[Json] = [
    obj([
      ("device", str("d-mac")),
      ("deviceText", str("林的 MacBook Pro · still.fail")),
      ("deviceCode", str("A3B-9CD")),
      ("ownerName", str("林")),
      ("ownerEmail", str("lin@example.com")),
      ("current", Json::boolean(true)),
      ("at", Json::number(0.0)),
      ("atText", str("1 小时前")),
    ]),
    obj([
      ("device", str("d-ana")),
      ("deviceText", str("Ana 的 MacBook Air · still.fail")),
      ("deviceCode", str("E5F-2GH")),
      ("ownerName", str("Ana")),
      ("ownerEmail", str("ana@example.com")),
      ("current", Json::boolean(false)),
      ("at", Json::number(0.0)),
      ("atText", str("昨天")),
    ]),
  ]
  let pending : Array[Json] = if fx.vault_ws_pending_done {
    authorized.push(pending_dev)
    []
  } else {
    [pending_dev]
  }
  obj([
    ("id", str("v-ws")),
    ("name", str("Workspace 密钥库")),
    ("scope", str("workspace")),
    ("owner", str("u1")),
    ("ownerName", str("林")),
    ("mine", Json::boolean(false)),
    ("manages", Json::boolean(true)),
    (
      "members",
      Json::array(
        fx.vault_workspace_members.map(fn(s) {
          let name = match s {
            "u1" => "林"
            "u2" => "Ana"
            "u3" => "周"
            _ => s
          }
          obj([("sub", str(s)), ("name", str(name))])
        }),
      ),
    ),
    ("station", str("st1")),
    ("stationName", str("Willow")),
    ("items", Json::number(2.0)),
    ("devices", Json::number(authorized.length().to_double())),
    ("open", Json::boolean(false)),
    ("keyed", Json::boolean(true)),
    ("missing", Json::number(pending.length().to_double())),
    ("recoverable", Json::boolean(false)),
    ("lasts", str("chat")),
    ("authorizedDevices", Json::array(authorized)),
    ("pendingDevices", Json::array(pending)),
  ])
}

///|
/// What the drives' files kept come to as a run starts: 38.5 MB.
let fx_drive_kept : Double = 40370176.0

///|
/// A sheet a fixture's mode puts up over its page once it is drawn (mark, add, add-existing, add-command, env).
priv struct FixtureOpen {
  mut sheet : String
  /// a dialog of the desktop's pages to put up (src/sfdesk: fixture_desk), "" none
  mut desk : String
}

///|
let fixture_open : FixtureOpen = { sheet: "", desk: "" }

///|
/// The new connect's step its fixture shows (MBUI_FIXTURE=settings-new-connect: team; -platform, -scan: Feishu's).
let fx_connect_step : Ref[String] = Ref("team")

///|
/// What is typed on a new group connect's server step (its fields by name), as the page sends it; and whether one was
/// added (k1 is it then).
// kept across runs: the fixture's state, reset with the rest of it (fixture_reset)
let fx_group_typed : Map[String, String] = Map([])

///|
// kept across runs: the fixture's state, reset with the rest of it (fixture_reset)
let fx_group_made : Ref[Bool] = Ref(false)

///|
/// Where a new profile's draft for Google is (settings-new-profile-google…): "" none; "pick" (the providers, Google
/// among them), "method" (its ways), or the way chosen ("plan", "enterprise", "key"); moved on as the page edits it.
// kept across runs: the fixture's state, reset with the rest of it (fixture_reset)
let fx_google : Ref[String] = Ref("")

///|
/// Its sign-in's state ("" none started; "needs_code", "needs_project", "verifying"), moved on as the page sends it.
// kept across runs: the fixture's state, reset with the rest of it (fixture_reset)
let fx_google_login : Ref[String] = Ref("")

///|
/// An Anthropic plan's sign-in for a new profile (settings-new-profile-login…) given its whole code: signed in, its
/// profile made (cc); before, waiting on the code.
// kept across runs: the fixture's state, reset with the rest of it (fixture_reset)
let fx_new_login_done : Ref[Bool] = Ref(false)

///|
/// Whether Google accounts are among the profiles (settings-profiles-google): a company's and a person's.
// kept across runs: the fixture's state, reset with the rest of it (fixture_reset)
let fx_google_profiles : Ref[Bool] = Ref(false)

///|
/// Whether the person's Google account asks Google's API for its quota beside its CLI (`directQuota`; off in
/// settings-profile-google-off).
// kept across runs: the fixture's state, reset with the rest of it (fixture_reset)
let fx_google_direct : Ref[Bool] = Ref(true)

///|
/// Whether a Google Colab compute service account is among the profiles (settings-profiles-colab, settings-profile-colab).
// kept across runs: the fixture's state, reset with the rest of it (fixture_reset)
let fx_colab_profiles : Ref[Bool] = Ref(false)

///|
/// Whether a new Google Colab service sign-in is under way (settings-new-profile-colab-login).
// kept across runs: the fixture's state, reset with the rest of it (fixture_reset)
let fx_colab_login : Ref[Bool] = Ref(false)

///|
/// Claude 主账号 named by an email as long as an account's (settings-profiles-long-name): its plan leaves its row's line
/// in the sidebar before its name is cut short.
// kept across runs: the fixture's state, reset with the rest of it (fixture_reset)
let fx_long_name : Ref[Bool] = Ref(false)

///|
/// 连接 (MBUI_FIXTURE=settings-connects): a Slack app made and not connected yet over the connects, one connect with its
/// own picture and one with its platform's mark.
let fx_connects_waiting : Ref[Bool] = Ref(false)

///|
/// A station with enough accounts in one kind to search its profiles.
let fx_station_many_profiles : Ref[Bool] = Ref(false)

///|
/// A station whose update failed because its state could not be read.
let fx_station_update_failed : Ref[Bool] = Ref(false)

///|
/// A station just updated, what the update said kept on its row (the core's `done`): a sentence beside the name, which
/// a phone with bigger words drew over it (#5117; words_large_wbtest.mbt).
let fx_station_updated : Ref[Bool] = Ref(false)

///|
/// A station whose channel's feed names earlier releases to go back to (the core's `earlier`), updating itself
/// (`settings-station-back`), or gone back to one, updating by itself held till a newer one than it left (`autoAfter`:
/// `settings-station-back-held`).
let fx_station_back : Ref[String] = Ref("")

///|
/// A station running a local replacement (`stillfail replace`, `settings-station-override`) with conditional auto-update.
let fx_station_override : Ref[Bool] = Ref(false)

///|
/// The workspace in safe mode with its stations not named by it: Willow, online, which the viewer could protect here
/// (the core's `protect`), and Maple, offline, which it could not.
let fx_unprotected : Ref[Bool] = Ref(false)

///|
let fx_connect_stations : Map[String, Array[String]] = Map([])

///|
let fx_connect_auto : Map[String, Bool] = Map([])

///|
/// The made-up settings as a run starts (reset): none changed, no sheet or scroll to put up.
fn fixture_reset() -> Unit {
  fx.names.clear()
  fx_connect_stations.clear()
  fx_connect_auto.clear()
  rigs_fixture_reset()
  move_fixture_reset()
  devices_fixture_reset()
  fx_many_kept.val = false
  fx_station_many_profiles.val = false
  fx_station_update_failed.val = false
  fx_station_updated.val = false
  fx_station_back.val = ""
  fx_station_override.val = false
  fx_unprotected.val = false
  fx.restored.clear()
  fx.skills_shared.clear()
  fx.drive_kept = fx_drive_kept
  fx.kept_cleared.clear()
  fx.relays.clear()
  fx.ours_off = false
  fx.resets_used = 0
  fx.reset_expiry = false
  fx.reset_kinds = false
  fx.fable_used = false
  fx.models_added.clear()
  fx.key_enabled = true
  fx.cc_max_sessions = Json::number(8.0)
  fx.cc_protection = true
  fx.copy_shown = false
  fx.copy_enabled = true
  fx.version = 0
  fx.marks.clear()
  fx.auto = false
  fx.afresh = false
  fx.afresh_above = 1.0
  fx.logs = true
  fx.accept_auto_chats = false
  fx.cc_follows = false
  fx.elevation = None
  fx.screen_service = None
  fx.copies = None
  fixture_retire_asked.clear()
  fx_remote_made.clear()
  fx.gpus = false
  fx.more_gpus = false
  fx.low_meters = false
  fx.os_icons = 0
  fx.congestion = "cubic"
  fx.none = false
  fx_adb.val = ""
  fx.login = ""
  fx.login_station = false
  fx.new_login = false
  fx.new_key = false
  fx.trouble = ""
  fx.vault_off = false
  fx.vault_elsewhere = false
  fx.plain_left = 0
  fx.vault_waits = false
  fx.vault_own = ""
  fx.vault_workspace = ""
  fx.vault_workspace_members.clear()
  fx.vault_workspace_members.append(["u1", "u2", "u3"])
  fx.pairing = false
  fx.pairing_personal = false
  fx.pairing_more = false
  fx.pairing_clarity = false
  fx.protecting = false
  fx.pending.clear()
  fx.upgrade = ""
  fx.lock_case = ""
  fx.own_after = ""
  fx.lock_doing = ""
  fx.lock_doing_ws = ""
  fx.pair_ended = ""
  fx.pair_flow = ""
  fx.pair_typed = 0
  fx.key_ask = false
  fx.key_ask_ended = ""
  fx.key_giving = false
  fx.key_ask_safe_mode = true
  fx.this_device_code = ""
  fx.vault_ws_pending_done = false
  fx.mba_online = false
  fx.retire_others = 0
  fx.retire_home = true
  fx.willow_away = false
  fx.willow_incompatible = false
  fx.willow_theirs = false
  fx.monthly = false
  fx.own = 0
  fx.no_hours = false
  fx.several = false
  fx.offer_quota = false
  fx.summary = false
  profiles_narrow_overview.set(false)
  fx.profile_hosts = false
  fx.profile_unshareable = false
  fx.profile_one_owner = false
  fx.profile_away = false
  fx.profile_pending = false
  fx.profile_cut_off = false
  fx.motion = 0
  fixture_open.sheet = ""
  fixture_open.desk = ""
  fx_connect_step.val = "team"
  fx_group_typed.clear()
  fx_group_made.val = false
  fx_google.val = ""
  fx_google_login.val = ""
  fx_new_login_done.val = false
  fx_google_profiles.val = false
  fx_google_direct.val = true
  fx_colab_profiles.val = false
  fx_colab_login.val = false
  fx_long_name.val = false
  fx_connects_waiting.val = false
}

///|
/// The made-up workspace's people (settings-workspace-motion: 林 comes, then 周 goes).
fn fx_members(me : Json) -> Json {
  let all = [
    me,
    obj([("sub", str("u2")), ("email", str("ana@example.com")), ("name", str("Ana")), ("role", str("admin"))]),
    obj([("sub", str("u3")), ("email", str("zhou@example.com")), ("name", str("周")), ("role", str("member"))]),
  ]
  if fx.motion >= 1 {
    all.push(obj([("sub", str("u5")), ("email", str("lin2@example.com")), ("name", str("林")), ("role", str("member"))]))
  }
  if fx.motion >= 2 {
    all.remove(2) |> ignore
  }
  Json::array(all)
}

///|
/// `v`'s items as the made-up workspace has changed on its own (fx's `motion`): `add` come at 1, the one `gone` names
/// gone at 2 (settings-*-motion).
fn fx_moved(v : Json, add : Json, gone : (Json) -> Bool) -> Json {
  match v {
    Object(m) =>
      match m.get("items") {
        Some(Array(a)) => {
          let b = a.copy()
          if fx.motion >= 1 {
            b.push(add)
          }
          m["items"] = Json::array(if fx.motion >= 2 { b.filter(fn(x) { !gone(x) }) } else { b })
        }
        _ => ()
      }
    _ => ()
  }
  v
}

///|
/// The made-up workspace changed on its own as far as `step` (fx's `motion`), for the recordings of its pages' lists'
/// motion: told to what follows the made-up core's topics.
pub fn fixture_motion(step : Int) -> Unit {
  fx.motion = step
  fx_changed()
}

///|
/// How often the made-up settings changed: added to the fixture's own version.
pub fn fixture_version() -> Int {
  fx.version
}

///|
/// The made-up settings changed: their version on by one, told to what follows the made-up core's topics.
fn fx_changed() -> Unit {
  fx.version += 1
  fixture_changed()
}

///|
/// The made-up core's changes (the app's fixture's and its settings'), told to what follows its topics as they happen,
/// as the core client tells a subscription's (src/core Sub.changes): fixture_changed with each, fixture_followed as a
/// topic of it is read.
// kept across runs: a count of changes; a run anew reads its topics anew
let fixture_changes : @signals.Signal[Int] = @signals.signal(0)

///|
/// The made-up core changed (the app's fixture, its settings, its browsing): what read its topics in a computed is
/// worked out again.
pub fn fixture_changed() -> Unit {
  fixture_changes.set(fixture_changes.untracked() + 1)
}

///|
/// A topic of the made-up core read: what reads it in a computed follows its changes (fixture_changed).
pub fn fixture_followed() -> Unit {
  fixture_changes.get() |> ignore
}

///|
/// A draft's words told the made-up core (`composer.text`): its topic alone changed, told to what reads that topic
/// (fixture_draft_followed), nothing else of the made-up core's, as the core changes the draft's alone.
// kept across runs: a count of changes; a run anew reads its topics anew
let fixture_draft_changes : @signals.Signal[Int] = @signals.signal(0)

///|
/// A draft's words changed in the made-up core (fixture_draft_changes).
pub fn fixture_draft_changed() -> Unit {
  fixture_draft_changes.set(fixture_draft_changes.untracked() + 1)
}

///|
/// A draft's topic of the made-up core read: followed as its words change (fixture_draft_changed).
pub fn fixture_draft_followed() -> Unit {
  fixture_draft_changes.get() |> ignore
}

///|
/// How the new device's prompt went (`lockPrompt.deny` "deny", `lockPrompt.hide` "hide"; "" while it is up).
pub fn fixture_pair_ended() -> String {
  fx.pair_ended
}

///|
/// How the prompt for a vault's key went (`vault.addDevice` "give", `vault.hidePrompt` "hide"; "" while it is up).
pub fn fixture_key_ask_ended() -> String {
  fx.key_ask_ended
}

///|
/// What the made-up core's `lockPrompts` holds now, as another device changed it (lock_prompts.mbt, vault_prompts.mbt):
/// the new device asking (`pairing`; into one more workspace meanwhile, `more`), the device waiting for the vault's key
/// (`key_ask`; the key being given it, `giving`), told to what follows its topics.
pub fn fixture_prompts_now(
  pairing~ : Bool,
  more? : Bool = false,
  key_ask~ : Bool,
  giving? : Bool = false,
  safe_mode? : Bool = true,
) -> Unit {
  fx.pairing = pairing
  fx.pairing_more = more
  fx.key_ask = key_ask
  fx.key_giving = giving
  fx.key_ask_safe_mode = safe_mode
  fx_changed()
}

///|
/// Safe mode's change of this device asked (`lock.confirmSigner` verifying it once, `lock.open` turning it on again as it
/// was), where the mode's `lock_case` is the one it ends: at work from now (the core's `doing`), told to what follows its
/// topics; false where it ends none, the call the settings' own (fixture_call).
pub fn fixture_lock_doing(name : String, params : Json) -> Bool {
  let ends = match (name, fx.lock_case) {
    ("lock.confirmSigner", "confirm") | ("lock.open", "again") => true
    _ => false
  }
  if ends {
    fx.lock_doing = name
    fx.lock_doing_ws = text(Some(params), "workspace")
    fx_changed()
  }
  ends
}

///|
/// What fixture_lock_doing set going done: this device verified, or safe mode on again, told to what follows its topics.
pub fn fixture_lock_done() -> Unit {
  fx.lock_doing = ""
  fx.lock_doing_ws = ""
  fx.lock_case = ""
  fx_changed()
}

///|
/// A code typed on the page that waits (`lock.pairCode`), as a trusted device that asks its person takes it: checked
/// (`checking`), then that device asking them there (fixture_pair_asking), whose person is not through its prompt the
/// first time (the app not in front there: the same code to type again) and is the next (fixture_pair_answer). True
/// for that call: the made-up core takes it so (src/sffixture fixture.mbt).
pub fn fixture_pair_typed(name : String) -> Bool {
  if name != "lock.pairCode" {
    return false
  }
  fx.pair_typed += 1
  fx.pair_flow = "checking"
  fx_changed()
  true
}

///|
/// The trusted device asks its person for the code typed (fixture_pair_typed).
pub fn fixture_pair_asking() -> Unit {
  fx.pair_flow = "confirming"
  fx_changed()
}

///|
/// What came of the code typed (fixture_pair_typed): the first time not through, the next let in.
pub fn fixture_pair_answer() -> Result[Json, Json] {
  if fx.pair_typed < 2 {
    fx.pair_flow = "retry"
    fx_changed()
    Err(obj([("code", str("pair_wrong")), ("message", str(fixture_pair_retry))]))
  } else {
    fx.pair_flow = "done"
    fx_changed()
    Ok(obj([]))
  }
}

///|
/// The core's words for a code right whose trusted device's person was not through its prompt (core-misc.lock.pairRetryAway).
let fixture_pair_retry : String = "显示安全码的设备上 still.fail 不在前台，没能验证身份：在那台设备上打开 still.fail，再在这里输入一次同一个安全码"

///|
/// The bot being made by scanning (MBUI_FIXTURE=settings-new-connect-scan) made: the wizard done on its own, the
/// connect added (`k1`), told to what follows its topics.
pub fn fixture_scanned() -> Unit {
  fx_connect_step.val = "feishuScanned"
  fx_changed()
}

///|
/// Willow a Windows station, running as administrator as `v` says (the core's `StationElevation`), or not.
pub fn fixture_elevation(v : Json?) -> Unit {
  fx.elevation = v
}

///|
/// Willow a Windows station, with the optional LocalSystem screen service as `v` says (the core's `StationScreenService`), or not.
pub fn fixture_screen_service(v : Json?) -> Unit {
  fx.screen_service = v
}

///|
/// 远程's place-remote modes: Maple online beside Willow, each under its heading with its ＋ (Willow's screens and
/// terminals, Maple's display and a terminal).
pub fn fixture_place_remote() -> Unit {
  fx.mba_online = true
}

///|
/// What 远程's ＋ made this run (place-remote modes), by station: its terminals (`terminal.view` of `new`) and its
/// browser's tabs (`screen.openBrowser`), as the station would list them after (fixture_remote_made_said).
// kept across runs: emptied by fixture_reset
let fx_remote_made : Map[String, Array[String]] = Map([])

///|
/// 远程's ＋ made `id` (a terminal's, or a tab's screen `browser:<id>`) on station `station`: listed from now on, told
/// to what follows the made-up core's topics.
pub fn fixture_remote_made_said(station : String, id : String) -> Unit {
  let made = match fx_remote_made.get(station) {
    Some(a) => a
    None => {
      let a : Array[String] = []
      fx_remote_made[station] = a
      a
    }
  }
  if !made.contains(id) {
    made.push(id)
    fx_changed()
  }
}

///|
/// What 远程's ＋ made this run on station `station` (fixture_remote_made_said), in the order made.
pub fn fixture_remote_made(station : String) -> Array[String] {
  fx_remote_made.get(station).unwrap_or([])
}

///|
/// Station `station`'s `screens` as listed (`listed`), then the tabs 远程's ＋ made on it: a new tab each, blank.
fn fx_remote_listed(listed : Json, station : String) -> Json {
  match listed {
    Array(a) => Json::array(a + fx_remote_tabs(station))
    _ => listed
  }
}

///|
/// The tabs 远程's ＋ made on station `station`, as its `screens` lists them: a new tab each, blank.
fn fx_remote_tabs(station : String) -> Array[Json] {
  fixture_remote_made(station).filter(fn(id) { id.has_prefix("browser:") }).map(fn(id) {
    obj([("id", str(id)), ("kind", str("browser")), ("userTab", Json::boolean(true)), ("closable", Json::boolean(true)), ("openUrl", Json::boolean(true)), ("site", str("")), ("title", str("新标签页")), ("width", Json::number(1280.0)), ("height", Json::number(800.0)), ("line", str("空白标签页")), ("link", str(""))])
  })
}

///|
/// The page a fixture's mode opens (MBUI_FIXTURE=settings-<page>[-dark]), by the name route_of takes.
pub fn fixture_page(mode : String) -> String {
  let m = if mode.has_suffix("-dark") {
    mode.unsafe_substring(start=0, end=mode.length() - 5)
  } else {
    mode
  }
  // (the stable channel's: the same page, of Willow updated on the stable channel, which runs no `beta` feature of a
  // station's: sffixture's fixture_stable_mode)
  fx_station_beta.val = !m.has_suffix("-stable")
  let m = if m.has_suffix("-stable") { m.unsafe_substring(start=0, end=m.length() - 7) } else { m }
  // a sheet up over the page (fixture_open)
  let up = fn(sheet : String, _list : String, _block : Int) {
    fixture_open.sheet = sheet
  }
  // 共享调试 as it stands with the phone (fx_adb_share), its host's word on the phone said already (settings-adb-desk: a
  // computer's host, no adb of its own)
  fx_adb.val = ""
  if m.has_prefix("settings-adb-") {
    fx_adb.val = m.unsafe_substring(start=13, end=m.length())
    adb_host.phone.set(Some(
      if fx_adb.val == "desk" {
        obj([("supported", Json::boolean(false)), ("none", Json::boolean(true))])
      } else {
        obj([
          ("supported", Json::boolean(true)),
          ("developer", Json::boolean(true)),
          ("wireless", Json::boolean(fx_adb.val != "off" && fx_adb.val != "chats-off")),
          ("wifi", Json::boolean(true)),
          ("canSwitch", Json::boolean(false)),
        ])
      },
    ))
  }
  match m {
    // The grants list with long reasons is itself in view for the spacing and corner sweeps.
    "settings-adb-chats-long" => up("", "settings/adb/", 4)
    "settings-station-mark" => up("mark", "", 0)
    "settings-station-many-profiles" => fx_station_many_profiles.val = true
    "settings-station-gpu" => fx.gpus = true
    "settings-stations-low" => fx.low_meters = true
    // (Willow on Linux, its GPUs', Maple a Mac, Cedar on Windows: their systems apart)
    "settings-stations-unmarked" => {
      fx.gpus = true
      fx.os_icons = 1
    }
    "settings-stations-os" => {
      fx.gpus = true
      fx.os_icons = 2
    }
    "settings-station-gpu-many" => {
      fx.gpus = true
      fx.more_gpus = true
    }
    // the page's 设置 (its variables' sheet up over it), its 软件与设备
    "settings-station-env" => station_parts["ws1/st1"] = "settings"
    // its 设置 while it is away: only what can be changed then
    "settings-stations-incompatible" => fx.willow_incompatible = true
    "settings-stations-tasks-theirs" => fx.willow_theirs = true
    "settings-stations-tasks-doing" => fx_rigs.mode_doing = true
    "settings-station-away" => {
      fx.willow_away = true
      station_parts["ws1/st1"] = "settings"
    }
    // its 设置 with 高级网络设置 opened: its congestion control, a section of the page after it
    "settings-station-network" => {
      station_parts["ws1/st1"] = "settings"
      station_network_open["ws1/st1"] = true
      up("", "settings/station/ws1/st1", -1)
    }
    // its 设置 scrolled to 备份: its row (Cedar and Aspen up to date; -alone: the only station of its workspace;
    // -config: expanded backup settings with manual peer selection and Cloudflare R2; -s3-form: R2/S3 add dialog)
    "settings-station-copies" | "settings-station-copies-alone" => {
      fx.copies = Some(fixture_copies_row(alone=m == "settings-station-copies-alone"))
      station_parts["ws1/st1"] = "settings"
      up("", "settings/station/ws1/st1", -1)
    }
    "settings-backup" => {
      fx.copies = Some(fixture_copies_config())
      fx.mba_online = true
    }
    "settings-backup-station" | "settings-backup-s3-form" => {
      fx.copies = Some(fixture_copies_config())
      if m == "settings-backup-s3-form" {
        fixture_open.desk = "copies-s3-form"
      }
    }
    "settings-backup-restore-s3" => fx.copies = Some(fixture_copies_restore_s3())
    "settings-station-copies-config" | "settings-station-copies-s3-form" => {
      fx.copies = Some(fixture_copies_config())
      station_parts["ws1/st1"] = "settings"
      up("", "settings/station/ws1/st1", -1)
      if m == "settings-station-copies-s3-form" {
        fixture_open.desk = "copies-s3-form"
      }
    }
    "settings-station-restore-s3" => {
      fx.copies = Some(fixture_copies_restore_s3())
      station_parts["ws1/st1"] = "settings"
      up("", "settings/station/ws1/st1", -1)
    }
    // a new station's 设置 scrolled to 备份: a backup of a station no longer there it can restore (-offer: 恢复到这台
    // live; -confirm: asked first), one being restored; -restored: what came of it, after the restart
    "settings-station-restore" => {
      fx.copies = Some(fixture_copies_restore(under_way=true, name="Old Mac"))
      station_parts["ws1/st1"] = "settings"
      up("", "settings/station/ws1/st1", -1)
    }
    // (-long: a station named in 24 characters, its confirm's title kept to one line)
    "settings-station-restore-offer" | "settings-station-restore-confirm" | "settings-station-restore-confirm-long" => {
      fx.copies = Some(fixture_copies_restore(under_way=false, name=if m == "settings-station-restore-confirm-long" { "Lin's MacBook Pro (2021)" } else { "Old Mac" }))
      station_parts["ws1/st1"] = "settings"
      up("", "settings/station/ws1/st1", -1)
      if m != "settings-station-restore-offer" {
        fixture_open.desk = "copies-confirm"
      }
    }
    "settings-station-restored" => {
      fx.copies = Some(fixture_copies_restored())
      station_parts["ws1/st1"] = "settings"
      up("", "settings/station/ws1/st1", -1)
    }
    // Willow retired from the workspace, its chats moved to another station (station_retire_node.mbt): its ⋯'s
    // 迁走聊天并移出工作区 there (-retire: Maple the one other station up); its panel opened over its page, what goes and
    // what stays as Willow counts them (-panel: Maple chosen; -panel-pick: Maple and Cedar up, none chosen; -panel-none:
    // none up; -panel-joined: a workspace Willow only joined, its accounts staying; -panel-long: the one up named long);
    // then 迁移 at the top of its page, its steps as it goes: sending (取消), its chats paused (取消), failed as Maple
    // took them (重试, 取消), its accounts moving, done (移出 workspace), done with two accounts left behind; -taking:
    // a station as old stations' chats come to it
    "settings-station-retire" | "settings-station-retire-panel" | "settings-station-retire-panel-pick" | "settings-station-retire-panel-none" | "settings-station-retire-panel-joined" | "settings-station-retire-panel-long" => {
      fx.copies = Some(fixture_copies_retire(""))
      fx.retire_others = match m {
        "settings-station-retire-panel-pick" => 2
        "settings-station-retire-panel-none" => 0
        _ => 1
      }
      fx.retire_home = m != "settings-station-retire-panel-joined"
      if m == "settings-station-retire-panel-long" {
        fx.names["st2"] = "Lin's MacBook Pro (2021)"
      }
      if m != "settings-station-retire" {
        fixture_open.desk = "retire-panel"
      }
      station_parts["ws1/st1"] = "overview"
    }
    "settings-station-retire-sending" | "settings-station-retire-sent" | "settings-station-retire-sent-failed" | "settings-station-retire-quiet" | "settings-station-retire-failed" | "settings-station-retire-accounts" | "settings-station-retire-done" | "settings-station-retire-done-left" | "settings-station-taking" => {
      fx.copies = Some(fixture_copies_retire(if m == "settings-station-taking" { "taking" } else { m.unsafe_substring(start=24, end=m.length()) }))
      fx.retire_others = 1
      station_parts["ws1/st1"] = "overview"
    }
    // its 进程: what still.fail uses of the machine
    "settings-station-processes" => station_parts["ws1/st1"] = "processes"
    "settings-station-lower" => {
      station_parts["ws1/st1"] = "settings"
      up("", "settings/station/ws1/st1", 0)
    }
    "settings-station-versions" | "settings-station-update-failed" | "settings-station-updated" | "settings-station-back" | "settings-station-back-held" | "settings-station-override" => {
      station_parts["ws1/st1"] = "settings"
      fx_station_update_failed.val = m == "settings-station-update-failed"
      fx_station_updated.val = m == "settings-station-updated"
      fx_station_back.val = if m.has_prefix("settings-station-back") { m } else { "" }
      fx_station_override.val = m == "settings-station-override"
      up("", "settings/station/ws1/st1", 0)
    }
    "settings-stations-add" => up("add", "", 0)
    // a station its workspace's safe mode does not name, which the viewer could protect: 保护 on its page and its card
    "settings-station-unprotected" | "settings-stations-unprotected" => fx_unprotected.val = true
    // Profile's ＋ with more than one station online: which to add it on (pressed by the film's step)
    "settings-profiles-pick" => fx.mba_online = true
    // an account's page with the station it is on and its move to another, Maple up to take it: ChatGPT 团队, a
    // subscription not shared; 备用 key, a key not shared
    "settings-profile-move" | "settings-profile-move-key" => fx.mba_online = true
    "settings-profiles-monthly" => fx.monthly = true
    "settings-profiles-fable" | "settings-profile-fable" => fx.own = 1
    // (settings-station-own3: the station's page, for its accounts' panel pictured with them)
    "settings-profiles-own3" | "settings-profile-own3" | "settings-station-own3" => fx.own = 3
    "settings-profiles-week-fable" | "settings-profile-week-fable" => {
      fx.own = 1
      fx.no_hours = true
    }
    "settings-profiles-several" => fx.several = true
    "settings-profiles-offer" => fx.offer_quota = true
    // (an account on several stations' own page: its members those of a profile's hosts)
    "settings-profile-account" => fx.profile_hosts = true
    "settings-profiles-sum-a" => {
      fx.summary = true
      profiles_narrow_overview.set(true)
    }
    "settings-stations-existing" => up("add-existing", "", 0)
    "settings-stations-command" => up("add-command", "", 0)
    "settings-first-station" => fx.none = true
    "settings-profile-lower" => up("", "settings/profile/ws1/st1/cc", 2)
    // The sharing section of the made-up subscription, for reviewing its on-screen layout.
    "settings-profile-share" => up("", "settings/profile/ws1/st1/cc", 6)
    "settings-profile-unshareable" => {
      fx.profile_unshareable = true
      up("", "settings/profile/ws1/st1/cx", 0)
    }
    "settings-profile-hosts" | "settings-profile-hosts-one" | "settings-profile-hosts-away" | "settings-profile-hosts-pending" | "settings-profile-hosts-cutoff" => {
      fx.profile_hosts = true
      fx.profile_one_owner = m == "settings-profile-hosts-one"
      fx.profile_away = m == "settings-profile-hosts-away"
      fx.profile_pending = m == "settings-profile-hosts-pending" || m == "settings-profile-hosts-cutoff"
      fx.profile_cut_off = m == "settings-profile-hosts-cutoff"
      up("", "settings/profile/ws1/st1/cc", 3)
    }
    "settings-profile-login" => {
      fx.login = "needs_code"
      up("", "settings/profile/ws1/st1/cc", 0)
    }
    // A copy of another station's subscription: its page, where this station pauses it (its ⋯'s 停用)
    "settings-profile-copy" => {
      fx.copy_shown = true
      up("", "settings/profile/ws1/st1/bx", 0)
    }
    "settings-profile-login-station" => {
      fx.login = "needs_code"
      fx.login_station = true
      up("", "settings/profile/ws1/st1/cc", 0)
    }
    "settings-new-profile-login" => fx.new_login = true
    // Google's: from the providers on (pressed through), at its ways, at a company account's code and its project
    "settings-new-profile-google" => fx_google.val = "pick"
    "settings-new-profile-google-ways" => fx_google.val = "method"
    "settings-new-profile-google-code" => {
      fx_google.val = "enterprise"
      fx_google_login.val = "needs_code"
    }
    "settings-new-profile-google-plan" => {
      fx_google.val = "plan"
      fx_google_login.val = "needs_code"
    }
    "settings-new-profile-google-project" => {
      fx_google.val = "enterprise"
      fx_google_login.val = "needs_project"
    }
    "settings-profiles-google" | "settings-profile-google" => fx_google_profiles.val = true
    "settings-profile-google-off" => {
      fx_google_profiles.val = true
      fx_google_direct.val = false
    }
    "settings-profiles-colab" | "settings-profile-colab" => fx_colab_profiles.val = true
    "settings-new-profile-colab-login" => fx_colab_login.val = true
    // a key's form for a provider with a choice of region and of protocol (Kimi's: 中国 / 国际, OpenAI / Anthropic
    // 兼容)
    "settings-new-profile-key" => fx.new_key = true
    // three stations online to add it on (Willow, Maple, Cedar): the add page's choice of them
    // (desk_profile_wbtest.mbt's station pressed)
    "settings-new-profile-stations" => {
      fx.mba_online = true
      fx.motion = 1
      fx.names["st3"] = "Cedar"
    }
    "settings-new-profile-login-station" => {
      fx.new_login = true
      fx.login_station = true
    }
    "settings-profile-login-failed" => {
      fx.login = "failed"
      up("", "settings/profile/ws1/st1/cc", 0)
    }
    "settings-profile-quota-failed" => fx.trouble = "quota"
    "settings-profile-verify" => fx.trouble = "verify"
    "settings-profile-quota-login" => fx.trouble = "quota-login"
    "settings-profile-quota-expiry" => fx.reset_expiry = true
    "settings-profiles-long-name" => fx_long_name.val = true
    "settings-profile-quota-kinds" => fx.reset_kinds = true
    "settings-profile-blocked" => fx.trouble = "blocked"
    "settings-profile-signin" => fx.trouble = "login"
    // a connect's page; its way of making sessions asked (src/sfpages connect.mbt's dialog)
    "settings-connect-menu" => ()
    "settings-connect-mode" => fixture_open.desk = "connect-mode"
    "settings-vault-off" => fx.vault_off = true
    "settings-vault-elsewhere" => {
      fx.vault_off = true
      fx.vault_elsewhere = true
    }
    "settings-vault-plain" => fx.plain_left = 2
    "settings-vault-waits" => fx.vault_waits = true
    // 密钥 with no safe mode: the vault its person's own (not turned on yet, turned on with secrets from before still in
    // plain text, this device to be approved by another trusted device of theirs: its code typed, or their devices set
    // up again elsewhere)
    "settings-vault-own-off" => {
      fx.vault_own = "off"
      fx.vault_off = true
      fx.plain_left = 2
    }
    "settings-vault-own-on" => {
      fx.vault_own = "on"
      fx.plain_left = 2
    }
    "settings-vault-own-outside" => {
      fx.vault_own = "outside"
      fx_adb.val = "lock-outside"
    }
    "settings-vault-own-code" => {
      fx.vault_own = "outside"
      fx_adb.val = "gate-code"
    }
    "settings-vault-own-replaced" => {
      fx.vault_own = "outside"
      fx_adb.val = "lock-replaced"
    }
    "settings-lock-prompt" => fx.pairing = true
    "settings-pair-prompt" => {
      fx.pairing = true
      fx.pairing_clarity = true
    }
    // (one asking into the person's own lock: no workspace named)
    "settings-lock-prompt-personal" => {
      fx.pairing = true
      fx.pairing_personal = true
    }
    // (someone's first device in an upgraded workspace: the role approving lets them in as)
    "settings-lock-prompt-role" => {
      fx.pairing = true
      fx.lock_case = "role"
    }
    // 密钥 before the library, this device not signing: verified once by a press, or what it waits for
    "settings-vault-confirm" => fx.lock_case = "confirm"
    "settings-vault-syncing" => fx.lock_case = "syncing"
    // 密钥 on a device not confirmed in an upgraded workspace's safe mode, its security page as the core says it: left
    // out by its station and waiting to be approved, or its person's lock begun anew elsewhere (`replaced`); each as the
    // core says it since (not confirmed, the way to 安全) and as it said before (`-was`: held on 正在同步…, or offered
    // 验证, which its person's lock refuses: `personal_outside`)
    "settings-vault-waiting" => fx.lock_case = "waiting"
    "settings-vault-waiting-was" => fx.lock_case = "waiting-was"
    "settings-vault-replaced" => fx.lock_case = "replaced"
    "settings-vault-replaced-was" => fx.lock_case = "replaced-was"
    "settings-vault-prompt" => fx.key_ask = true
    "settings-vault-words" => recovery_words["ws1"] = fx_words()
    "settings-vault-add" => fixture_open.desk = "vault-add"
    "settings-vault-editor" => fixture_open.desk = "vault-editor"
    "settings-vault-workspace-create" => fx.vault_workspace = "create"
    "settings-vault-workspace" => fx.vault_workspace = "has"
    "settings-vault-workspace-save-picked" => {
      fx.vault_workspace = "has"
      vault_target_picked["r-ws-save"] = ("v-ws", "Workspace 密钥库", true)
    }
    "settings-vault-workspace-members" => {
      fx.vault_workspace = "has"
      fixture_open.desk = "vault-workspace-members"
    }
    "settings-vault-workspace-editor" => {
      fx.vault_workspace = "has"
      fixture_open.desk = "vault-workspace-editor"
    }
    "settings-vault-devices-dialog" => {
      fx.vault_workspace = "has"
      fixture_open.desk = "vault-devices-dialog"
    }
    "settings-vault-no-key-code" => {
      fx.vault_off = true
      fx.vault_elsewhere = true
      fx.this_device_code = "K7M-4PX"
    }
    "settings-vault-recover" => fixture_open.desk = "vault-recover"
    "settings-add-people" => up("add-people", "", 0)
    "settings-workspace-mark" => up("workspace-mark", "", 0)
    // 外观's 本机字体 open (src/sfpages font_setting.mbt local_tile: the families the host lists)
    "settings-local-fonts" => fixture_open.desk = "local-fonts"
    // the archive policy with a dialog up (src/sfpages automatic_decisions.mbt): its words, an option of the
    // station's; its 安全 with one (security.mbt): Maple to take in, turning it off
    "settings-policy-text" => fixture_open.desk = "policy-text"
    "settings-policy-option" => fixture_open.desk = "policy-option"
    "settings-security-join" => fixture_open.desk = "lock-join"
    "settings-security-off" => fixture_open.desk = "lock-off"
    "settings-security-protecting" => fx.protecting = true
    "settings-security-pending" => fx.pending.append(["p1", "p2", "p3"])
    // an upgraded workspace's: this device to verify once on its person's own lock; on, or off, by another person
    // alone; off by this person, to turn on again as it was
    "settings-security-confirm" => fx.lock_case = "confirm"
    "settings-security-root" => fx.lock_case = "root"
    "settings-security-root-off" => fx.lock_case = "root-off"
    "settings-security-again" => fx.lock_case = "again"
    // trusted here by the workspace's lock, its person's own lock begun on another device not naming it: 完成此设备的批准
    // offered on its security page, nothing waiting in front of the app (views/lock.ts `confirmedOffOwn`, FB-45)
    "settings-security-own-outside" => fx.lock_case = "own-outside"
    // what the upgrade of safe mode waits for (security.mbt upgrade_keys): a station this person may update, one they
    // may not, a member, a device, more than six, a station of another workspace, a station updating
    m if m.has_prefix("settings-security-upgrade-") => fx.upgrade = m.unsafe_substring(start=26, end=m.length())
    // 本机缓存 with many chats kept (a card of 200 rows)
    "settings-kept-many" => fx_many_kept.val = true
    // the fonts page at code's faces
    "settings-fonts-code" => fonts_at.set(2)
    "settings-new-connect-platform" => fx_connect_step.val = "platform"
    "settings-new-connect-scan" => fx_connect_step.val = "feishuScan"
    // a new Comma connect's model, its first step after the platform
    "settings-new-connect-comma" => fx_connect_step.val = "commaBind"
    // a station with the group connect: Group offered and picked; a new group connect's server, filled in
    "settings-new-connect-platform-group" => fx_connect_step.val = "platformGroup"
    "settings-new-connect-group" => fx_connect_step.val = "groupForm"
    // a new Slack app's step: its name, its look
    "settings-new-connect-app" => fx_connect_step.val = "app"
    "settings-connects" => fx_connects_waiting.val = true
    _ => fx_connect_step.val = "team"
  }
  // a new connect's dialog over 连接 (src/sfpages new_connect.mbt), at the step said above
  if m.has_prefix("settings-new-connect") {
    fixture_open.desk = "new-connect"
  }
  let moves = move_fixture_mode(m)
  match m {
    "settings" => "home"
    _ if moves && (m == "settings-station-move-section" || m == "settings-station-move-offered") => "station:ws1/st1"
    _ if moves => "move:ws1/st1"
    "settings-backup" => "backup"
    "settings-backup-station" | "settings-backup-s3-form" | "settings-backup-restore-s3" => "backup:ws1/st1"
    "settings-station-mark" | "settings-station-gpu" | "settings-station-gpu-many" | "settings-station-env" | "settings-station-processes" | "settings-station-lower" | "settings-station-versions" | "settings-station-update-failed" | "settings-station-updated" | "settings-station-back" | "settings-station-back-held" | "settings-station-override" | "settings-station-network" | "settings-station-away" | "settings-station-copies" | "settings-station-copies-alone" | "settings-station-copies-config" | "settings-station-copies-s3-form" | "settings-station-restore" | "settings-station-restore-offer" | "settings-station-restore-confirm" | "settings-station-restore-confirm-long" | "settings-station-restore-s3" | "settings-station-restored" | "settings-station-retire" | "settings-station-retire-panel" | "settings-station-retire-panel-pick" | "settings-station-retire-panel-none" | "settings-station-retire-panel-joined" | "settings-station-retire-panel-long" | "settings-station-retire-sending" | "settings-station-retire-sent" | "settings-station-retire-sent-failed" | "settings-station-retire-quiet" | "settings-station-retire-failed" | "settings-station-retire-accounts" | "settings-station-retire-done" | "settings-station-retire-done-left" | "settings-station-taking" | "settings-station-terminals" =>
      "station:ws1/st1"
    "settings-stations-add" | "settings-stations-existing" | "settings-stations-command" | "settings-first-station" =>
      "stations"
    "settings-adb" | "settings-adb-off" | "settings-adb-unpaired" | "settings-adb-pairing" | "settings-adb-connected" | "settings-adb-failed" =>
      "adb:ws1/st1"
    "settings-adb-chats" | "settings-adb-chats-off" | "settings-adb-chats-long" | "settings-adb-desk" | "settings-adb-unsigned" | "settings-adb-gate-none" | "settings-adb-gate-code" | "settings-adb-gate-checking" | "settings-adb-idle" | "settings-adb-lock-member" | "settings-adb-lock-two" | "settings-adb-lock-outside" | "settings-adb-lock-multi" | "settings-adb-lock-multi-replaced" | "settings-adb-lock-multi-member" =>
      "adb:"
    // the second station a phone is lent to, its first paired already
    "settings-adb-second" => "adb:ws1/st2"
    "settings-profile-menu" | "settings-profile-lower" | "settings-profile-share" | "settings-profile-login" | "settings-profile-login-station" =>
      "profile:ws1/st1#cc"
    "settings-new-profile" | "settings-new-profile-hermes" | "settings-new-profile-colab" | "settings-new-profile-google-colab-ways" | "settings-new-profile-google-vertex-ways" | "settings-new-profile-google-vertex-key" | "settings-new-profile-colab-login" | "settings-new-profile-stations" | "settings-new-profile-login" | "settings-new-profile-login-station" | "settings-new-profile-key" | "settings-new-profile-google" | "settings-new-profile-google-ways"
    | "settings-new-profile-google-code" | "settings-new-profile-google-plan" | "settings-new-profile-google-project" => "new-profile:ws1/st1"
    "settings-connect-menu" | "settings-connect-mode" => "connect:ws1/st1#k1"
    "settings-connect-run" | "settings-connect-switch" | "settings-slack-app" => "connect:ws1/st1#k1"
    // the page of a connect of another kind, none of its sessions yet
    "settings-connect-comma" | "settings-connect-feishu" | "settings-connect-group" => "connect:ws1/st1#k1"
    "settings-new-connect" | "settings-new-connect-platform" | "settings-new-connect-scan" | "settings-new-connect-app" | "settings-new-connect-comma"
    | "settings-new-connect-platform-group" | "settings-new-connect-group" => "connects"
    "settings-vault-off" | "settings-vault-elsewhere" | "settings-vault-no-key-code" | "settings-vault-words" | "settings-vault-recover" | "settings-vault-plain" | "settings-vault-waits"
    | "settings-vault-workspace-create" | "settings-vault-workspace" | "settings-vault-workspace-save-picked" | "settings-vault-workspace-members" | "settings-vault-devices-dialog"
    | "settings-vault-own-off" | "settings-vault-own-on" | "settings-vault-own-outside" | "settings-vault-own-code" | "settings-vault-own-replaced"
    | "settings-vault-confirm" | "settings-vault-syncing" | "settings-vault-waiting" | "settings-vault-waiting-was" | "settings-vault-replaced"
    | "settings-vault-replaced-was" => "vault"
    "settings-vault-items" | "settings-vault-add" | "settings-vault-editor" | "settings-vault-workspace-editor" => "vault-items"
    "settings-vault-item" | "settings-vault-item-cross" => "vault-item:v1#it1"
    "settings-decisions" => "decisions-settings"
    "settings-completion" => "completion"
    "settings-policy" | "settings-policy-text" | "settings-policy-option" => "policy:ws1/st1"
    "settings-bars" => "bars"
    "settings-kept" | "settings-kept-many" | "settings-kept-fill" => "kept"
    "settings-changelog" => "changelog"
    "settings-about-flow" | "settings-about-traced" => "about"
    "settings-fonts-coming" | "settings-fonts-code" => "fonts"
    "settings-prices" => "prices:7"
    "settings-add-people" | "settings-workspace-mark" | "settings-workspace-motion" => "workspace"
    "settings-stations-motion" | "settings-stations-incompatible" | "settings-stations-low" | "settings-stations-unmarked" | "settings-stations-os" =>
      "stations"
    "settings-connects-motion" => "connects"
    "settings-vault-motion" => "vault-items"
    "settings-local-fonts" => "fonts"
    "settings-security-join" | "settings-security-off" | "settings-security-protecting" | "settings-security-pending"
    | "settings-security-confirm" | "settings-security-root" | "settings-security-root-off" | "settings-security-again"
    | "settings-security-own-outside" => "security"
    m if m.has_prefix("settings-security-upgrade-") => "security"
    "settings-stations-tasks" | "settings-stations-tasks-outside" | "settings-stations-tasks-theirs" | "settings-stations-tasks-doing" | "settings-stations-devices" => "stations"
    "settings-station-devices" => "station:ws1/st1"
    "settings-station-tasks" | "settings-station-tasks-locked" => "station:ws1/aa11"
    "settings-station-tasks-other" => "station:ws1/bb22"
    "settings-notify-off" | "settings-lock-prompt" | "settings-lock-prompt-personal" | "settings-lock-prompt-role" | "settings-pair-prompt" | "settings-vault-prompt" =>
      "home"
    // (the notifications' page; the system having refused them: its banner's way to allow them)
    "settings-notify" | "settings-notify-denied" => "notifications"
    "settings-station" | "settings-station-pages" | "settings-station-many-profiles" | "settings-station-own3" | "settings-station-unprotected" => "station:ws1/st1"
    "settings-stations-unprotected" => "stations"
    "settings-station-offline" => "station:ws1/st2"
    "settings-memory" => "memory:ws1/st1"
    "settings-memory-doc" => "memory-doc:ws1/st1#发布流程"
    "settings-profile" | "settings-profile-hosts" | "settings-profile-hosts-one" | "settings-profile-hosts-away" | "settings-profile-hosts-pending" | "settings-profile-hosts-cutoff" | "settings-profile-quota-failed" | "settings-profile-verify" | "settings-profile-blocked" | "settings-profile-signin" | "settings-profile-fable" | "settings-profile-own3" | "settings-profile-week-fable" =>
      "profile:ws1/st1#cc"
    "settings-profile-key" | "settings-profile-move-key" => "profile:ws1/st1#k2"
    "settings-profile-colab" => "profile:ws1/st1#colab"
    "settings-profile-google" | "settings-profile-google-off" => "profile:ws1/st1#gp"
    "settings-profile-move" => "profile:ws1/st1#cx"
    "settings-profile-copy" => "profile:ws1/st1#bx"
    "settings-profile-quota" | "settings-profile-quota-login" | "settings-profile-quota-expiry" | "settings-profile-unshareable" => "profile:ws1/st1#cx"
    "settings-profile-quota-kinds" => "profile:ws1/st1#cc"
    // (an account on several stations by its key, and one station's profiles from its page)
    "settings-profile-account" => "profile-account:ws1/st1/cc"
    "settings-profiles-station" => "profiles:ws1/st1"
    "settings-me-reading" => "me"
    "settings-usage-details-pending" | "settings-usage-real" => "usage"
    // (its prices of the same workspace's: usage_real's)
    "settings-usage-real-prices" => "prices"
    "settings-profiles-pick" | "settings-profiles-monthly" | "settings-profiles-fable" | "settings-profiles-own3" | "settings-profiles-week-fable" | "settings-profiles-several" | "settings-profiles-offer"
    | "settings-profiles-google" | "settings-profiles-colab" | "settings-profiles-sum-a" | "settings-profiles-long-name" => "profiles"
    "settings-connect" | "settings-connect-borrow" => "connect:ws1/st1#k1"
    _ =>
      if m.has_prefix("settings-") {
        m.unsafe_substring(start=9, end=m.length())
      } else {
        ""
      }
  }
}

///|
fn stamp_of(ago : String, until? : String = "") -> Json {
  obj([
    ("at", Json::number(0.0)),
    ("ago", str(ago)),
    ("full", str("")),
    ("until", str(until)),
    ("past", Json::boolean(true)),
  ])
}

///|
fn meter(short : String, left : Int, level : String, remaining : String, big : String, unit : String, title : String, total : String, title_short? : String = "", total_short? : String = "") -> Json {
  obj([
    ("titleShort", str(title_short)),
    ("totalShort", str(total_short)),
    ("label", str(short)),
    ("short", str(short)),
    ("percent", Json::number((100 - left).to_double())),
    ("left", Json::number(left.to_double())),
    ("level", str(level)),
    ("value", str("")),
    ("remaining", str(remaining)),
    ("big", str(big)),
    ("unit", str(unit)),
    ("title", str(title)),
    ("total", str(total)),
  ])
}

///|
fn fx_profile(id : String, name : String, kind : String, tone : String, check : String, group : String, title : String, more : Array[(String, Json)]) -> Json {
  let rt = if group == "chatgpt" { "codex" } else if group == "agy" { "agy" } else { "claude" }
  let p : Map[String, Json] = {
    "id": str(id),
    "name": str(name),
    "runtime": str(rt),
    "runtimes": [str(rt)],
    "access": obj([("kind", str(kind)), ("key", str(if kind == "subscription" { "" } else { "sk-…a41f" }))]),
    "home": "",
    "homeExists": true,
    "models": ["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-5"],
    "named": [],
    "env": [],
    "usedBy": ["k1"],
    "loginCommand": "",
    "checkText": str(check),
    "checkTone": str(tone),
    "planText": str(if id == "cc" { "Ultra" } else if id == "cx" { "Pro 200" } else { "" }),
    // (the core's words of it: present.ts profile)
    "signInProvider": str(if group == "chatgpt" { "ChatGPT" } else { "Claude" }),
    "group": str(group),
    "groupTitle": str(title),
    "makers": obj([]),
    "names": obj([("claude-opus-5-5", str("Opus 5.5")), ("claude-sonnet-5", str("Sonnet 5")), ("claude-haiku-5", str("Haiku 5"))]),
    "series": [
      obj([("name", str("Opus")), ("models", ["claude-opus-5-5"])]),
      obj([("name", str("Sonnet")), ("models", ["claude-sonnet-5"])]),
      obj([("name", str("Haiku")), ("models", ["claude-haiku-5"])]),
    ],
    "modelsText": "3 个模型",
    "available": ["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-5"],
    "usesText": "Claude Code",
    "check": obj([("state", str("ok")), ("detail", str("可用，订阅有效")), ("checkedAt", Json::number(0.0)), ("time", obj([("checkedAt", stamp_of("5 分钟前"))]))]),
    "quota": obj([
      ("state", str("ok")),
      (
        "windows",
        Json::array(
        (if fx.no_hours {
          []
        } else {
          [obj([("label", str("5 小时")), ("usedPercent", Json::number(38.0)), ("mark", str("5H")), ("left", Json::number(62.0)), ("level", str("ok")), ("refills", str(if fx.own > 0 { "3 小时 5 分钟后刷新" } else { "2 小时后恢复" }))])]
        }).iter().concat(
          // (with its models' own: named and refilling in the words the core says, their real length)
          [obj([("label", str(if fx.own > 0 { "每周" } else { "本周" })), ("usedPercent", Json::number(81.0)), ("mark", str("W")), ("left", Json::number(19.0)), ("level", str("amber")), ("refills", str(if fx.own > 0 { "2 天 4 小时后刷新" } else { "星期一恢复" }))])].iter(),
        ).concat(
          (if fx.monthly {
            [obj([("label", str("每月")), ("usedPercent", Json::number(3.0)), ("mark", str("M")), ("left", Json::number(97.0)), ("level", str("ok")), ("refills", str("11 月 1 日恢复"))])]
          } else {
            []
          }).iter(),
        ).concat(
          [("Fable", 46, "ok"), ("Opus", 8, "red"), ("Sonnet", 100, "ok")].iter().take(fx.own).map(fn(m) {
            obj([("label", str("每周 · " + m.0)), ("usedPercent", Json::number((100 - m.1).to_double())), ("scope", str(m.0)), ("mark", str(m.0)), ("left", Json::number(m.1.to_double())), ("level", str(m.2)), ("refills", str("2 天 4 小时后刷新"))])
          }),
        ).collect()),
      ),
      ..(if id == "cc" { fx_cc_resets() } else { [] }),
      ("checkedAt", Json::number(0.0)),
      ("time", obj([("checkedAt", stamp_of("3 分钟前"))])),
    ]),
  }
  for kv in more {
    p[kv.0] = kv.1
  }
  // (the core's words of it: present.ts profile, as it is after `more`)
  let pv = Some(Json::object(p))
  if !p.contains("kindText") {
    p["kindText"] = str(
      if flag(pv, "machine") {
        "终端里的登录"
      } else if text(pv, "providerName") != "" {
        text(pv, "providerName")
      } else {
        match kind {
          "subscription" => "订阅账号"
          "anthropic-api" => "Anthropic API"
          "opencode-go" => "OpenCode Go"
          "api-provider" => "API 服务商"
          "env" => "自定义环境变量"
          _ => ""
        }
      },
    )
  }
  p["checkLine"] = str(
    if has(pv, "enabled") && !flag(pv, "enabled") { "" } else { match field(pv, "check") {
      Some(Object(_)) => text(field(pv, "check"), "detail").replace(old="可用，", new="")
      _ => "尚未检查"
    } },
  )
  Json::object(p)
}

///|
/// The made-up station's profiles (Willow's), for the chats' fixture's overview of it too: one made-up world.
pub fn fixture_profiles() -> Array[Json] {
  fx_profiles()
}

///|
/// Claude 主账号's name: an email as long as an account's where fx.long_name says (settings-profiles-long-name).
fn fx_cc_name() -> String {
  if fx_long_name.val {
    "someone.with.a.long.name@company.example"
  } else {
    "Claude 主账号"
  }
}

///|
fn fx_profiles() -> Array[Json] {
  let profiles = [
    fx_profile("cc", fx_cc_name(), "subscription", fx_cc_tone(), "可用", "claude", "Claude 订阅", fx_cc_with([
      ("share", obj([("id", str("sh1")), ("role", str("host")), ("host", str("st1")), ("users", ["st2"]), ..fx_cc_follows()])),
      ("fast", Json::boolean(false)),
      ("backgroundOnMessage", Json::boolean(true)),
      ("maxConcurrentSessions", fx.cc_max_sessions),
      ("newAccountProtection", Json::boolean(fx.cc_protection)),
      ("workspaces", ["ws2"]),
      ("loginCommand", str("claude setup-token")),
      (
        "login",
        match fx.login {
          "" => Json::null()
          "failed" =>
            obj([
              ("profile", str("cc")),
              ("runtime", str("claude")),
              ("state", str("failed")),
              ("error", str("授权码已过期")),
              ("startedAt", Json::number(0.0)),
              ("expiresAt", Json::number(0.0)),
            ])
          state => fx_login_job("cc", state)
        },
      ),
    ])),
    fx_profile("cx", "ChatGPT 团队", "subscription", "green", "可用", "chatgpt", "ChatGPT 订阅", fx_cx_more()),
    fx_profile("k2", "备用 key", "anthropic-api", if fx.key_enabled { "red" } else { "neutral" }, if fx.key_enabled { "没能使用" } else { "已停用" }, "key", "API key", [
      ("enabled", Json::boolean(fx.key_enabled)),
      // (as the core says it: present.ts issue, trouble.key_next, trouble.key_label)
      ("trouble", if fx.key_enabled { obj([("title", str("key 已失效")), ("detail", str("服务商拒绝了这个 key")), ("next", str("核对服务商的 key 是否有效、余额和权限是否足够；可以更换 key，保存后会自动检查")), ("action", str("key")), ("label", str("更换 key"))]) } else { Json::null() }),
      ("quota", obj([("state", str("unsupported")), ("windows", []), ("checkedAt", Json::number(0.0))])),
      ("usedBy", []),
    ]),
  ]
  if fx_google_profiles.val {
    // Google accounts signed in to (settings-profiles-google): a company's on Gemini Enterprise, a person's on Ultra 5x,
    // their plans as the station's check says them
    for g in [("gw", "lin@company.example", "Enterprise Ultra"), ("gp", "lin@gmail.example", "Ultra 5x")] {
      profiles.push(
        fx_profile(g.0, g.1, "subscription", "green", "可用", "google", "Google 订阅", [
          ("runtime", str("agy")),
          ("runtimes", [str("agy")]),
          ("email", str(g.1)),
          ("planText", str(g.2)),
          ("signInProvider", str("Google")),
          ("usesText", str("Antigravity CLI")),
          ("usedBy", []),
          ("directQuota", Json::boolean(g.0 != "gp" || fx_google_direct.val)),
          ("quota", obj([
            ("state", str("ok")),
            ("windows", [
              fx_window("5 小时 · Gemini", "Gemini 5H", 99, "1 小时后恢复", "Gemini"),
              fx_window("每周 · Gemini", "Gemini W", 76, "3 天后恢复", "Gemini"),
              fx_window("5 小时 · Claude / GPT", "Claude / GPT 5H", 100, "3 小时后恢复", "Claude / GPT"),
              fx_window("每周 · Claude / GPT", "Claude / GPT W", 49, "3 天后恢复", "Claude / GPT"),
            ]),
          ])),
        ]),
      )
    }
  }
  if fx_colab_profiles.val {
    profiles.push(
      fx_profile("gp-colab", "lin@gmail.example", "subscription", "green", "可用", "agy", "Google", [
        ("runtime", str("agy")),
        ("runtimes", [str("agy")]),
        ("email", str("lin@gmail.example")),
        ("planText", str("Ultra 5x")),
        ("signInProvider", str("Google")),
        ("usesText", str("Antigravity CLI")),
        ("usedBy", []),
        ("quota", obj([
          ("state", str("ok")),
          ("windows", [
            fx_window("5 小时 · Gemini", "Gemini 5H", 99, "1 小时后恢复", "Gemini"),
            fx_window("每周 · Gemini", "Gemini W", 76, "3 天后恢复", "Gemini"),
          ]),
        ])),
      ]),
    )
    profiles.push(
      fx_profile("colab", "lin@colab.example", "service", "green", "可用", "agy", "Google", [
        ("runtime", Json::null()),
        ("service", str("colab")),
        ("runtimes", []),
        ("email", str("lin@colab.example")),
        ("access", obj([("kind", str("service")), ("key", str("")), ("service", str("colab")), ("login", Json::boolean(true))])),
        ("providerName", str("Google Colab")),
        ("providerMark", str("colab")),
        ("signInProvider", str("Google Colab")),
        ("kindText", str("Google Colab")),
        ("usesText", str("Google Colab GPU 算力")),
        ("planText", str("")),
        ("models", []),
        ("available", []),
        ("added", []),
        ("series", []),
        ("modelsText", str("")),
        ("canAddModel", Json::boolean(false)),
        ("decisionOnly", Json::boolean(false)),
        ("decisionModels", []),
        ("usedBy", []),
        ("share", Json::null()),
        ("shareable", Json::boolean(false)),
        ("shareRefusal", str("Google Colab 算力账号仅保存在所属 station 上，不支持跨 station 分享")),
        ("check", obj([("state", str("ok")), ("detail", str("已登录，lin@colab.example")), ("models", Json::null()), ("time", obj([("checkedAt", obj([("ago", str("刚刚"))]))]))])),
        ("quota", obj([
          ("state", str("ok")),
          ("windows", []),
          ("credits", obj([("hasCredits", Json::boolean(true)), ("unlimited", Json::boolean(false)), ("balance", str("2500.00 CU"))])),
          ("creditsText", str("2,500 CU")),
          ("detail", str("1 台运行中 · 10.05 CU/h")),
          ("time", obj([("checkedAt", obj([("ago", str("刚刚"))]))])),
        ])),
      ]),
    )
  }
  if fx.copy_shown {
    // Maple's Claude subscription borrowed here (share role user): its station pauses it (`enabled`), edits nothing else.
    profiles.push(
      fx_profile("bx", "maple@example.com", "subscription", if fx.copy_enabled { "green" } else { "neutral" }, if fx.copy_enabled { "可用" } else { "已停用" }, "claude", "Claude 订阅", [
        ("email", str("maple@example.com")),
        ("share", obj([("id", str("sh2")), ("role", str("user")), ("host", str("st2")), ("allow", Json::null()), ("reachable", Json::boolean(true)), ("pausable", Json::boolean(true))])),
        ("enabled", Json::boolean(fx.copy_enabled)),
        ("usedBy", []),
      ]),
    )
  }
  if fx.several {
    fx_several(profiles)
  }
  if fx.summary {
    return fx_summary_profiles()
  }
  profiles
}

///|
/// The Profile overview the made-up core says (`profilesOverview`): the core's own of the accounts it lists, as
/// fixture_overview.mbt keeps them (fx_summary_profiles' or fx_profiles' two subscriptions); none with no station.
pub fn fixture_overview() -> Json {
  if fx.none {
    return obj([("pools", [])])
  }
  @json.parse(if fx.summary { fx_overview_summary } else { fx_overview_plain }) catch {
    _ => obj([("pools", [])])
  }
}

///|
fn fx_window(label : String, mark : String, left : Int, refills : String, scope : String, short? : String) -> Json {
  let level = if left <= 10 { "red" } else if left <= 25 { "amber" } else { "ok" }
  let fields : Array[(String, Json)] = [
    ("label", str(label)),
    ("usedPercent", Json::number((100 - left).to_double())),
    ("mark", str(mark)),
    ("left", Json::number(left.to_double())),
    ("level", str(level)),
    ("refills", str(refills)),
  ]
  if short is Some(s) {
    fields.push(("refillShort", str(s)))
  }
  if scope != "" {
    fields.push(("scope", str(scope)))
  }
  obj(fields)
}

///|
/// Realistic multi-account pool across four provider groups for the profiles overview designs.
fn fx_summary_profiles() -> Array[Json] {
  let ok_q = fn(ws : Array[Json]) -> Json {
    obj([("state", str("ok")), ("windows", Json::array(ws)), ("checkedAt", Json::number(0.0)), ("time", obj([("checkedAt", stamp_of("2 分钟前"))]))])
  }
  let ok_q_reset = fn(ws : Array[Json], count : Int, text : String) -> Json {
    obj([
      ("state", str("ok")),
      ("windows", Json::array(ws)),
      ("resetCount", Json::number(count.to_double())),
      ("resetText", str(text)),
      ("checkedAt", Json::number(0.0)),
      ("time", obj([("checkedAt", stamp_of("2 分钟前"))])),
    ])
  }
  [
    // Claude 订阅 (5): weighted tight weekly pace (4 days left to reset, heavy usage + 1 weekly dead + 1 expired login)
    fx_profile("cc", "Claude 主账号", "subscription", "green", "可用", "claude", "Claude 订阅", [
      ("planText", str("Max 20x")),
      (
        "quota",
        ok_q_reset(
          [fx_window("5 小时", "5H", 48, "2 小时后恢复", ""), fx_window("每周", "W", 28, "5 天后恢复", ""), fx_window("每周 · Fable", "Fable", 52, "5 天后恢复", "Fable")],
          1,
          "剩余 1 次重置 · 28 小时后过期",
        ),
      ),
    ]),
    fx_profile("cc2", "afkdev1@proton.me", "subscription", "green", "可用", "claude", "Claude 订阅", [
      ("email", str("afkdev1@proton.me")),
      ("planText", str("Max 20x")),
      ("quota", ok_q([fx_window("5 小时", "5H", 36, "3 小时后恢复", ""), fx_window("每周", "W", 22, "5 天后恢复", ""), fx_window("每周 · Fable", "Fable", 45, "5 天后恢复", "Fable")])),
    ]),
    fx_profile("cc3", "afkdev2@proton.me", "subscription", "green", "可用", "claude", "Claude 订阅", [
      ("email", str("afkdev2@proton.me")),
      ("planText", str("Max 5x")),
      ("quota", ok_q([fx_window("5 小时", "5H", 0, "42 分钟后恢复", "", short="42m"), fx_window("每周", "W", 40, "4 天后恢复", ""), fx_window("每周 · Fable", "Fable", 80, "4 天后恢复", "Fable")])),
    ]),
    fx_profile("cc4", "cuesurf4@proton.me", "subscription", "green", "可用", "claude", "Claude 订阅", [
      ("email", str("cuesurf4@proton.me")),
      ("planText", str("Max 20x")),
      ("quota", ok_q([fx_window("每周", "W", 0, "2 天后恢复", "", short="2d"), fx_window("每周 · Fable", "Fable", 100, "2 天后恢复", "Fable")])),
    ]),
    fx_profile("cc5", "cuesurf2@proton.me", "subscription", "red", "需要登录", "claude", "Claude 订阅", [
      ("email", str("cuesurf2@proton.me")),
      ("planText", str("Max 20x")),
      ("trouble", obj([("title", str("需要重新登录")), ("detail", str("登录凭证已过期")), ("next", str("重新登录这个账号后恢复使用")), ("action", str("login")), ("label", str("重新登录"))])),
      ("quota", obj([("state", str("unavailable")), ("windows", []), ("checkedAt", Json::number(0.0))])),
    ]),
    // ChatGPT 订阅 (3): comfortable pace, and jiachen@cue.surf resets in 14h with 84% weekly quota untouched
    fx_profile("cx", "ChatGPT 团队", "subscription", "green", "可用", "chatgpt", "ChatGPT 订阅", [
      ("planText", str("Pro 200")),
      ("quota", ok_q([fx_window("5 小时", "5H", 82, "3 小时后恢复", ""), fx_window("每周", "W", 68, "3 天后恢复", "")])),
    ]),
    fx_profile("cx2", "jiachen@cue.surf", "subscription", "green", "可用", "chatgpt", "ChatGPT 订阅", [
      ("email", str("jiachen@cue.surf")),
      ("planText", str("Pro 200")),
      ("quota", ok_q([fx_window("5 小时", "5H", 92, "4 小时后恢复", ""), fx_window("每周", "W", 84, "14 小时后恢复", "")])),
    ]),
    fx_profile("cx3", "yangjinfei@cue.surf", "subscription", "green", "可用", "chatgpt", "ChatGPT 订阅", [
      ("email", str("yangjinfei@cue.surf")),
      ("planText", str("Plus")),
      ("quota", ok_q([fx_window("5 小时", "5H", 100, "5 小时后恢复", ""), fx_window("每周", "W", 0, "2 天后恢复", "", short="2d")])),
    ]),
    // Google 订阅 (2): provides both Gemini and Claude / GPT independent pools, marked as the core marks them
    fx_profile("ag1", "zover.v@gmail.com", "subscription", "green", "可用", "agy", "Google 订阅", [
      ("email", str("zover.v@gmail.com")),
      ("planText", str("AI Ultra")),
      ("signInProvider", str("Google")),
      (
        "quota",
        ok_q([
          fx_window("5 小时 · Gemini", "Gemini 5H", 76, "3 小时后恢复", "Gemini"),
          fx_window("每周 · Gemini", "Gemini W", 68, "3 天后恢复", "Gemini"),
          fx_window("5 小时 · Claude / GPT", "Claude / GPT 5H", 0, "4 小时 21 分钟后恢复", "Claude / GPT", short="4h21m"),
          fx_window("每周 · Claude / GPT", "Claude / GPT W", 49, "3 天后恢复", "Claude / GPT"),
        ]),
      ),
    ]),
    fx_profile("ag2", "zzj3720@gmail.com", "subscription", "green", "可用", "agy", "Google 订阅", [
      ("email", str("zzj3720@gmail.com")),
      ("planText", str("AI Ultra")),
      ("signInProvider", str("Google")),
      (
        "quota",
        ok_q([
          fx_window("5 小时 · Gemini", "Gemini 5H", 64, "1 小时后恢复", "Gemini"),
          fx_window("每周 · Gemini", "Gemini W", 62, "4 天后恢复", "Gemini"),
          fx_window("5 小时 · Claude / GPT", "Claude / GPT 5H", 100, "5 小时后恢复", "Claude / GPT"),
          fx_window("每周 · Claude / GPT", "Claude / GPT W", 68, "4 天后恢复", "Claude / GPT"),
        ]),
      ),
    ]),
    // API key (2): 1 ready with balance, 1 invalid key
    fx_profile("k1", "OpenRouter", "api-provider", "green", "可用", "key", "API key", [
      ("providerName", str("OpenRouter")),
      ("providerMark", str("openrouter")),
      ("access", obj([("kind", str("api-provider")), ("provider", str("openrouter")), ("key", str("sk-or-…9c2a"))])),
      ("quota", obj([("state", str("ok")), ("windows", []), ("creditsText", str("余额 $42.80")), ("checkedAt", Json::number(0.0))])),
      ("usedBy", ["k1"]),
    ]),
    fx_profile("k2", "备用 key", "anthropic-api", "red", "key 已失效", "key", "API key", [
      ("trouble", obj([("title", str("key 已失效")), ("detail", str("服务商拒绝了这个 key")), ("next", str("更换有效 key")), ("action", str("key")), ("label", str("更换 key"))])),
      ("quota", obj([("state", str("unsupported")), ("windows", []), ("checkedAt", Json::number(0.0))])),
      ("usedBy", []),
    ]),
  ]
}

///|
/// The offered login's allowance (settings-profiles-offer): the figures of the fixture's own Claude subscription,
/// as the Mac's text has them.
fn fx_offer_quota() -> Json {
  obj([
    ("state", str("ok")),
    ("windows", [
      obj([("label", str("5 小时")), ("usedPercent", Json::number(38.0)), ("mark", str("5H")), ("left", Json::number(62.0)), ("level", str("ok")), ("refills", str("4 小时后恢复"))]),
      obj([("label", str("本周")), ("usedPercent", Json::number(81.0)), ("mark", str("W")), ("left", Json::number(19.0)), ("level", str("ok")), ("refills", str("星期一恢复"))]),
    ]),
    ("checkedAt", Json::number(0.0)),
  ])
}

///|
/// The Claude subscription five accounts (settings-profiles-several): the first of them its own (cc), the rest copies,
/// each by its e-mail with what is left of its windows by mark (Fable's a model's own week).
fn fx_several(profiles : Array[Json]) -> Unit {
  let accounts : Array[Array[(String, Int)]] = [
    [("5H", 26), ("W", 17), ("Fable", 52)],
    [("5H", 0), ("W", 13), ("Fable", 74)],
    [("W", 0), ("Fable", 100)],
    [("W", 48), ("Fable", 26)],
    [("5H", 0), ("W", 5), ("Fable", 70)],
  ]
  guard profiles[0] is Object(cc) else { return }
  for i, windows in accounts {
    let p = cc.copy()
    if i > 0 {
      p["id"] = str("claude-" + (i + 1).to_string())
    }
    p["name"] = str("claude" + (i + 1).to_string() + "@example.com")
    p["quota"] = obj([
      ("state", str("ok")),
      (
        "windows",
        Json::array(
          windows.map(fn(w) {
            let (mark, left) = w
            let level = if left <= 10 { "red" } else if left <= 20 { "amber" } else { "ok" }
            let (label, refills) = match mark {
              "5H" => ("5 小时", "3 小时 5 分钟后刷新")
              "W" => ("每周", "2 天 4 小时后刷新")
              _ => ("每周 · " + mark, "2 天 4 小时后刷新")
            }
            let fields = [
              ("label", str(label)),
              ("usedPercent", Json::number((100 - left).to_double())),
              ("mark", str(mark)),
              ("left", Json::number(left.to_double())),
              ("level", str(level)),
              ("refills", str(refills)),
            ]
            if mark == "Fable" {
              fields.push(("scope", str(mark)))
            }
            obj(fields)
          }),
        ),
      ),
      ("checkedAt", Json::number(0.0)),
      ("time", obj([("checkedAt", stamp_of("3 分钟前"))])),
    ])
    if i == 0 {
      profiles[0] = Json::object(p)
    } else {
      profiles.insert(i, Json::object(p))
    }
  }
}

///|
/// The station overview's accounts: the long case has nine Claude and three ChatGPT accounts.
fn fx_station_profiles() -> Array[Json] {
  let profiles = fx_profiles()
  if fx_station_many_profiles.val {
    for i in 1..<9 {
      match profiles[0] {
        Object(p) => {
          let copy = p.copy()
          copy["id"] = str("claude-" + i.to_string())
          copy["name"] = str("claude" + i.to_string() + "@example.com")
          let hours = 90 - i * 7
          let week = 92 - i * 10
          copy["quota"] = obj([
            ("state", str("ok")),
            ("windows", [
              obj([("label", str("5 小时")), ("usedPercent", Json::number((100 - hours).to_double())), ("mark", str("5H")), ("left", Json::number(hours.to_double())), ("level", str(if hours <= 20 { "amber" } else { "ok" })), ("refills", str("2 小时后恢复"))]),
              obj([("label", str("本周")), ("usedPercent", Json::number((100 - week).to_double())), ("mark", str("W")), ("left", Json::number(week.to_double())), ("level", str(if week <= 20 { "amber" } else { "ok" })), ("refills", str("星期一恢复"))]),
            ]),
            ("checkedAt", Json::number(0.0)),
          ])
          profiles.push(Json::object(copy))
        }
        _ => ()
      }
    }
    for i in 1..<3 {
      match profiles[1] {
        Object(p) => {
          let copy = p.copy()
          copy["id"] = str("chatgpt-" + i.to_string())
          copy["name"] = str("chatgpt" + i.to_string() + "@example.com")
          profiles.push(Json::object(copy))
        }
        _ => ()
      }
    }
  }
  profiles
}

///|
/// Its account kinds and states, in the same shapes as the core's station view.
fn fx_station_profile_groups(profiles : Array[Json]) -> Array[Json] {
  let groups : Array[(String, String, Array[String], Array[String])] = []
  for p in profiles {
    let pv = Some(p)
    let kind = text(pv, "group")
    let at = match groups.search_by(fn(g) { g.0 == kind }) {
      Some(i) => i
      None => {
        groups.push((kind, text(pv, "groupTitle"), [], []))
        groups.length() - 1
      }
    }
    if field(pv, "trouble") is Some(Object(_)) {
      groups[at].2.push(text(pv, "id"))
    } else {
      groups[at].3.push(text(pv, "id"))
    }
  }
  groups.map(fn(g) {
    obj([
      ("group", str(g.0)), ("title", str(g.1)),
      ("profiles", Json::array(g.2.iter().concat(g.3.iter()).map(fn(id) { str(id) }).collect())),
      ("attention", Json::number(g.2.length().to_double())),
    ])
  })
}

///|
fn fx_station_profile_states(profiles : Array[Json]) -> Json {
  let states : Map[String, Json] = Map([])
  for p in profiles {
    let pv = Some(p)
    let trouble = field(pv, "trouble")
    let green = text(pv, "checkTone") == "green"
    if trouble is Some(Object(_)) && green {
      states[text(pv, "id")] = obj([("text", str(text(trouble, "title"))), ("tone", str("amber"))])
    } else if !green && text(pv, "checkText") != "" {
      states[text(pv, "id")] = obj([("text", str(text(pv, "checkText"))), ("tone", str(text(pv, "checkTone")))])
    }
  }
  Json::object(states)
}

///|
/// The profiles of one account: independently signed in on three stations and also borrowed on three.
fn fx_profile_hosts() -> Array[Json] {
  let profile_host = fn(station : String, name : String, id : String, role : String, title : String, about : String) -> Json {
    obj([
      ("station", str("ws1/" + station)), ("stationId", str(station)), ("stationName", str(name)),
      ("profileId", str(id)), ("profileName", str(id)), ("role", str(role)), ("title", str(title)),
      ("about", str(about)), ("online", Json::boolean(true)), ("usable", Json::boolean(true)),
      ("checkText", str("可用")), ("checkTone", str("green")), ("usedBy", Json::number(0.0)),
    ])
  }
  let members = [
    profile_host("st1", "Willow", "cc", "host", "Willow", "在此 station 登录，借给 Maple、Cedar、Birch"),
    profile_host("st2", "Maple", "sh1", "user", "Maple", "向 Willow 借用"),
    profile_host("st3", "Cedar", "local", "own", "Cedar", "在此 station 单独登录"),
    profile_host("st3", "Cedar", "sh1", "user", "Cedar", "向 Willow 借用"),
    profile_host("st4", "Birch", "local", "own", "Birch", "在此 station 单独登录"),
    profile_host("st4", "Birch", "sh1", "user", "Birch", "向 Willow 借用"),
  ]
  if fx.profile_one_owner {
    return [members[0], members[1]]
  }
  members
}

///|
/// The same account by station, as the core's places says it.
fn fx_profile_places() -> Array[Json] {
  let members = fx_profile_hosts()
  let chosen = if fx.profile_one_owner { members } else { [members[0], members[1], members[2], members[4]] }
  chosen.map(fn(m) {
    let v = Some(m)
    let offline = fx.profile_away && text(v, "stationId") == "st4"
    let unavailable = fx.profile_away && text(v, "stationId") == "st2"
    let pending = fx.profile_pending && text(v, "stationId") == "st2"
    obj([
      ("station", str(text(v, "station"))), ("stationId", str(text(v, "stationId"))),
      ("stationName", str(text(v, "stationName"))), ("profileId", str(if pending { "" } else { text(v, "profileId") })),
      ("online", Json::boolean(!offline)), ("usable", Json::boolean(!offline && !unavailable && !pending)),
      ("sourceName", str(if unavailable || pending { "Willow" } else { "" })),
      ("state", if pending && fx.profile_cut_off {
        obj([("text", str("无法连接 still.fail cloud")), ("tone", str("amber"))])
      } else if pending {
        obj([("text", str("等待同步")), ("tone", str("neutral"))])
      } else {
        Json::null()
      }),
    ])
  })
}

///|
/// Claude 主账号's dot as its trouble has it (fx.trouble).
fn fx_cc_tone() -> String {
  match fx.trouble {
    "login" | "blocked" | "verify" => "red"
    _ => "green"
  }
}

///|
/// What the station says where Google asks an Antigravity CLI account to be verified first (agy-quota.ts `agyVerify`,
/// station.quota.agyVerifyAt): the account refused, the link whole on its own line last.
let fx_verify_detail : String = "Google 要求先验证这个账号才能用 Antigravity。用登录了这个 Google 账号的浏览器打开下面的链接完成验证，然后重新查询额度\nhttps://accounts.google.com/v3/signin/continue?plt=AKgnsbvgpMGWUxHL-LdY6TaKwyqigcx13EZGzlKmZcGrDxrNDt57SPhlkbXKa1uIKydtd8wIqmUCw2x25ooo2v5G_JN2S8spn6C0rCAJWTFB47we5La_Ckx-UMLZpie3MBHPZkmLQIIq&continue=https://developers.google.com/gemini-code-assist/auth/auth_success_gemini&sarp=1&scc=1&flowName=GlifWebSignIn&authuser"

///|
/// Claude 主账号's own (`more`) and its trouble (fx.trouble) as the core says it (present.ts profileTrouble), with what
/// its check and its allowance say then.
fn fx_cc_with(more : Array[(String, Json)]) -> Array[(String, Json)] {
  let issue = fn(title : String, detail : String, next : String, action : String, label : String) {
    ("trouble", obj([("title", str(title)), ("detail", str(detail)), ("next", str(next)), ("action", str(action)), ("label", str(label))]))
  }
  more..append(match fx.trouble {
    "quota" =>
      [
        issue("额度查询失败", "请求超时，已中止", "查不到额度不代表账号不能用。先重新查询；还是失败，再按返回的原因检查登录或网络。", "quota", "重新查询额度"),
        ("quota", obj([("state", str("unavailable")), ("detail", str("请求超时，已中止")), ("windows", []), ("checkedAt", Json::number(0.0))])),
      ]
    "verify" =>
      [
        issue("服务商拒绝了这个账号", fx_verify_detail, "按上面的原因到服务商处理（解除停用、完成验证等），处理后重新查询额度", "quota", "重新查询额度"),
        ("quota", obj([("state", str("blocked")), ("detail", str(fx_verify_detail)), ("windows", []), ("checkedAt", Json::number(0.0))])),
        ("checkText", str("账号被拒")),
      ]
    "blocked" =>
      [
        issue("额度已用完", "本周额度已用完", "等额度恢复，或换一个账号。", "quota", "重新查询额度"),
        ("quota", obj([("state", str("blocked")), ("detail", str("本周额度已用完")), ("windows", []), ("checkedAt", Json::number(0.0))])),
      ]
    "login" =>
      [
        issue("需要重新登录", "登录已过期", "", "login", "登录"),
        ("check", obj([("state", str("login")), ("detail", str("登录已过期")), ("checkedAt", Json::number(0.0)), ("time", obj([("checkedAt", stamp_of("5 分钟前"))]))])),
        ("checkText", str("需要登录")),
      ]
    _ => []
  })
}

///|
/// ChatGPT 团队's resets left, in the core's words.
fn fx_cx_reset_text(left : Int) -> String {
  if fx.reset_expiry {
    if left == 2 { "剩余 2 次 · 6 小时 35 分钟后、3 天 19 小时后到期" } else if left == 1 { "剩余 1 次 · 3 天 19 小时后到期" } else { "剩余 0 次" }
  } else {
    "还可重置 \{left} 次"
  }
}

///|
/// Claude 主账号's resets of two kinds, as the core offers them (settings-profile-quota-kinds).
fn fx_cc_resets() -> Array[(String, Json)] {
  if !fx.reset_kinds {
    return []
  }
  let kinds = [
    obj([
      ("id", str("session")),
      ("kind", str("session")),
      ("left", Json::number(1.0)),
      ("usable", Json::boolean(false)),
      ("title", str("5 小时重置")),
      ("leftText", str("剩 1 次")),
      ("text", str("到达它能恢复的上限后才能用")),
      ("refills", str("立即恢复 5 小时额度")),
    ]),
  ]
  if !fx.fable_used {
    kinds.push(
      obj([
        ("id", str("model")),
        ("kind", str("model")),
        ("left", Json::number(1.0)),
        ("usable", Json::boolean(true)),
        ("title", str("Fable 重置")),
        ("leftText", str("剩 1 次")),
        ("text", str("118 天后到期")),
        ("refills", str("把本周 Fable 用掉的额度还回每周额度")),
      ]),
    )
  }
  [("resetCount", Json::number(kinds.length().to_double())), ("resets", Json::array(kinds))]
}

///|
/// ChatGPT 团队's own: more models than its page shows at first (one named by hand once added, which can be taken off
/// again), a reset of its quota left.
fn fx_cx_more() -> Array[(String, Json)] {
  let ids = [
    "gpt-6", "gpt-6-mini", "gpt-6-nano", "gpt-6-codex", "gpt-6-codex-mini", "gpt-5.5", "gpt-5.5-mini", "gpt-5.5-codex", "gpt-5",
    "gpt-5-mini", "o9", "o9-mini",
  ]..append(fx.models_added)
  let names : Map[String, Json] = Map([])
  for m in ids {
    names[m] = str(m.to_upper())
  }
  let left = 2 - fx.resets_used
  [
    ("shareable", Json::boolean(!fx.profile_unshareable)),
    ("maxConcurrentSessions", Json::null()),
    ("modelsText", str("\{ids.length()} 个模型")),
    ("models", Json::array(ids.map(str))),
    ("named", Json::array(fx.models_added.map(str))),
    ("added", Json::array(fx.models_added.map(str))),
    ("available", Json::array(ids.map(str))),
    ("names", Json::object(names)),
    ("series", fx_cx_series(ids)),
    ("canAddModel", Json::boolean(true)),
    (
      "quota",
      obj([
        ("state", str("ok")),
        (
          "windows",
          [
            obj([("label", str("5 小时")), ("usedPercent", Json::number(38.0)), ("mark", str("5H")), ("left", Json::number(62.0)), ("level", str("ok")), ("refills", str("2 小时后恢复"))]),
            obj([("label", str("本周")), ("usedPercent", Json::number(81.0)), ("mark", str("W")), ("left", Json::number(19.0)), ("level", str("amber")), ("refills", str("星期一恢复"))]),
          ],
        ),
        ("resetCount", Json::number(left.to_double())),
        ("resetText", str(fx_cx_reset_text(left))),
        // (one kind, which says nothing of what it gives back: as the core offers it, with no kind to ask for)
        ("resets", if left > 0 {
          [
            obj([
              ("kind", str("credit")),
              ("left", Json::number(left.to_double())),
              ("usable", Json::boolean(true)),
              ("title", str("额度重置")),
              ("leftText", str("剩 \{left} 次")),
              ("text", str(if fx.reset_expiry { if left == 2 { "6 小时 35 分钟后、3 天 19 小时后到期" } else { "3 天 19 小时后到期" } } else { "" })),
            ]),
          ]
        } else {
          []
        }),
        ("checkedAt", Json::number(0.0)),
        ("time", obj([("checkedAt", stamp_of("3 分钟前"))])),
      ]),
    ),
  ]..append(if fx.trouble == "quota-login" {
    [
      ("trouble", obj([("title", str("需要登录")), ("detail", str("ChatGPT 登录已失效，请重新登录")), ("next", str("重新登录此账号")), ("action", str("login")), ("label", str("重新登录"))])),
      ("quota", obj([("state", str("unavailable")), ("detail", str("ChatGPT 登录已失效，请重新登录")), ("windows", []), ("checkedAt", Json::number(0.0))])),
      ("check", obj([("state", str("login")), ("detail", str("ChatGPT 登录已失效，请重新登录")), ("checkedAt", Json::number(0.0)), ("time", obj([("checkedAt", stamp_of("3 分钟前"))]))])),
      ("checkText", str("需要登录")),
      ("checkTone", str("amber")),
      ("login", if fx.login == "" { Json::null() } else { fx_login_job("cx", fx.login) }),
    ]
  } else {
    []
  })
}

///|
/// Its models by series, as the core gives them (newest first, one named by hand under 其他).
fn fx_cx_series(ids : Array[String]) -> Json {
  let series = [
    ("GPT-6", ["gpt-6", "gpt-6-mini", "gpt-6-nano", "gpt-6-codex", "gpt-6-codex-mini"]),
    ("GPT-5.5", ["gpt-5.5", "gpt-5.5-mini", "gpt-5.5-codex"]),
    ("GPT-5", ["gpt-5", "gpt-5-mini"]),
    ("o9", ["o9", "o9-mini"]),
  ]
  let rest = ids.filter(fn(m) { !series.iter().any(fn(s) { s.1.contains(m) }) })
  let all = series.map(fn(s) { obj([("name", str(s.0)), ("models", Json::array(s.1.map(str)))]) })
  if rest.length() > 0 {
    all.push(obj([("name", str("其他")), ("models", Json::array(rest.map(str)))]))
  }
  Json::array(all)
}

///|
fn fx_connect(id : String, name : String, presence : String, status : String, mode : String) -> Json {
  obj([
    ("id", str(id)),
    ("name", str(name)),
    ("team", str("星火")),
    ..(if fx_connects_waiting.val && id == "k1" {
      [("botImage", str("https://app.still.fail/avatars/backend.webp"))]
    } else {
      []
    }),
    ("enabled", Json::boolean(true)),
    ("kind", str("slack")),
    ("mode", str(mode)),
    ("requireMention", Json::boolean(true)),
    ("bind", obj([("runtime", str("claude")), ("model", str("claude-opus-5-5")), ("effort", str("high"))])),
    ("slack", obj([("appToken", str("")), ("botToken", str(""))])),
    ("connection", obj([("state", str(if presence == "error" { "error" } else { "connected" })), ("error", str("Slack 拒绝了 token"))])),
    ("createdBy", obj([("id", str("lin@example.com")), ("name", str("林")), ("shown", obj([("name", str("林")), ("display", str("你")), ("mine", Json::boolean(true))]))])),
    ("sessions", Json::number(4.0)),
    // (a station that runs its new conversations elsewhere and moves it: connects/workspace.ts)
    (
      "startsOn",
      if fx_connect_auto.get(id) == Some(true) {
        Json::null()
      } else {
        match fx_connect_stations.get(id) {
          Some([first, ..]) => str(first)
          _ => Json::null()
        }
      },
    ),
    (
      "startsOnStations",
      if fx_connect_auto.get(id) == Some(true) {
        Json::null()
      } else {
        match fx_connect_stations.get(id) {
          Some(list) if list.length() > 0 => Json::array(list.map(str))
          _ => Json::null()
        }
      },
    ),
    ("startsOnAuto", Json::boolean(fx_connect_auto.get(id) == Some(true))),
    ("moves", Json::boolean(true)),
    ("statusText", str(status)),
    ("presence", str(presence)),
    ("modeText", str(if mode == "multi-session" { "每个 thread 一个会话" } else { "所有 thread 共用一个会话" })),
    ("modeShort", str("")),
    ("runtimeText", str("Claude Code")),
    ("runText", str("")),
    ("modelName", str("Opus 5.5")),
    // (the core's words of it: present.ts connect)
    ("placeText", str("星火")),
    ("modeLabel", str(if mode == "multi-session" { "每个 thread 一个会话" } else { "所有 thread 共用一个会话" })),
    (
      "modeSentence",
      str(
        if mode == "multi-session" {
          "在 thread 中 @ 它即开启一个新会话，该 thread 的后续消息都进入此会话"
        } else {
          "它看到的所有 thread 都进入同一个会话，适合长期值守的助手仅在被 @ 时唤醒。"
        },
      ),
    ),
    ("modeWords", fx_mode_words(false)),
  ])
}

///|
/// Connect k1 as one of another kind (MBUI_FIXTURE=settings-connect-comma, -feishu, -group): Comma's, reached in Comma
/// and running a session a Task; Feishu's, its app on 飞书; Group's, a member of an IM server. No Slack workspace
/// either, so no team.
fn fx_connect_as(kind : String) -> Json {
  let feishu = kind == "feishu"
  let group = kind == "group"
  // (a Feishu one's words as the core says them in the language shown: its English picture all English)
  let feishu_name = if @sf.language() == "en" { "Feishu Assistant" } else { "飞书助手" }
  match fx_connect("k1", if feishu { feishu_name } else if group { "Claude" } else { "Comma 助手" }, "online", "在线", "multi-session") {
    Object(o) => {
      o["kind"] = str(kind)
      o.remove("team")
      o.remove("slack")
      o["sessions"] = Json::number(0.0)
      o["placeText"] = str(if feishu { tr("web-pages.connect.feishu.name") } else if group { "Group" } else { "Comma" })
      if group {
        o["group"] = obj([
          ("server", str("3f9a1c0e7b2d4a6f8e1c3b5d7a9f0e2c4b6d8a0f1e3c5b7d9a2f4e6c8b0d1a3f")),
          ("relays", [str("https://relay-tokyo.group.example")]),
          ("botName", str("Claude")),
          ("memberId", str("5c1e9a7b3d2f")),
          ("device", str("b7e2c94f0a1d3e5c7b9a2f4e6d8c0b1a3f5e7d9c2b4a6f8e0d1c3b5a7f9e2d4c")),
          ("joining", Json::boolean(false)),
        ])
        o["modeWords"] = fx_mode_words_group()
        o["modeText"] = str("每个对话一个会话")
        o["modeLabel"] = str("每个对话一个会话")
        o["modeSentence"] = str("私聊它，或在群里 @ 它开始；之后这个私聊或群里的消息都交给这个会话")
      }
      if feishu {
        o["feishu"] = obj([
          ("appId", str("cli_a7f3e9b2c41d500e")),
          ("appSecret", str("…9c2b")),
          ("domain", str("feishu")),
          ("directThreads", Json::boolean(false)),
          ("console", str("https://open.feishu.cn/app/cli_a7f3e9b2c41d500e")),
        ])
        o["statusText"] = str(tr("core-logic.format.connection.connected"))
        o["modeWords"] = fx_mode_words(true)
        o["modeText"] = str(tr("web-main.mode.feishu.multi.label"))
        o["modeLabel"] = str(tr("web-main.mode.feishu.multi.label"))
        o["modeSentence"] = str(tr("web-main.mode.feishu.multi.description"))
      }
      Json::object(o)
    }
    v => v
  }
}

///|
/// A new connect on Comma's path at its model (MBUI_FIXTURE=settings-new-connect-comma): step 2 of 3, a model picked.
fn fx_comma_flow() -> Json {
  obj([
    ("step", str("commaBind")),
    ("title", str("绑定模型")),
    ("back", str("platform")),
    ("number", Json::number(2.0)),
    ("total", Json::number(3.0)),
    ("mobile", Json::boolean(true)),
    ("platforms", [str("slack"), str("feishu"), str("comma")]),
    ("platform", str("comma")),
    ("comma", obj([("line", str("")), ("ready", Json::boolean(false)), ("error", Json::null())])),
    ("mode", str("multi-session")),
    ("requireMention", Json::boolean(true)),
    ("threads", Json::boolean(false)),
    ("modeWords", fx_mode_words(false)),
    ("noProfile", Json::boolean(false)),
    ("canCreate", Json::boolean(true)),
    ("pick", fx_session_pick()),
  ])
}

///|
/// A new group connect (MBUI_FIXTURE=settings-new-connect-platform-group, settings-new-connect-group): Group picked
/// among the platforms; its model and way; its server, step 3 of 3, as typed (settings-new-connect-group: filled in as
/// someone pasted it); added.
fn fx_group_flow(step : String, mode : String) -> Json {
  let filled = mode == "settings-new-connect-group"
  let typed = fn(name : String, sample : String) { if filled { sample } else { fx_group_typed.get(name).unwrap_or("") } }
  let server = typed("server", "3f9a1c0e7b2d4a6f8e1c3b5d7a9f0e2c4b6d8a0f1e3c5b7d9a2f4e6c8b0d1a3f")
  let relays = typed("relays", "https://relay-tokyo.group.example")
  let code = typed("code", "7K2M-QX9P-H4TW-3NRB")
  let ready = server.length() == 64 && relays.has_prefix("https://") && code.length() >= 16
  let form = step == "groupForm" || step == "groupDone"
  let step = if step == "groupDone" { "done" } else { step }
  obj([
    ("step", str(step)),
    ("title", str(if form { "加入 Group 服务器" } else if step == "groupBind" { "绑定模型" } else { "选择平台" })),
    ("back", str(if form { "groupBind" } else if step == "groupBind" { "platform" } else { "close" })),
    ("number", Json::number(if form { 3.0 } else if step == "groupBind" { 2.0 } else { 1.0 })),
    ("total", Json::number(3.0)),
    ("mobile", Json::boolean(true)),
    ("platforms", [str("slack"), str("feishu"), str("comma"), str("group")]),
    ("platform", str("group")),
    (
      "group",
      obj([
        ("server", str(server)),
        ("relays", str(relays)),
        ("code", str(code)),
        ("botName", str(typed("botName", "Claude"))),
        ("serverError", Json::null()),
        ("relaysError", Json::null()),
        ("codeError", Json::null()),
        ("ready", Json::boolean(ready)),
        ("error", Json::null()),
      ]),
    ),
    ("mode", str("multi-session")),
    ("requireMention", Json::boolean(true)),
    ("threads", Json::boolean(false)),
    ("modeWords", fx_mode_words_group()),
    ("noProfile", Json::boolean(false)),
    ("canCreate", Json::boolean(true)),
    ("pick", fx_session_pick()),
  ])
}

///|
/// How a group connect's ways are said (present.ts modeWords "group"): in its conversations' words.
fn fx_mode_words_group() -> Json {
  obj([
    ("multi", obj([("label", str("每个对话一个会话")), ("description", str("私聊它，或在群里 @ 它开始；之后这个私聊或群里的消息都交给这个会话"))])),
    ("single", obj([("label", str("所有对话共用一个会话")), ("description", str("它所在的群和私聊都进入同一个会话，适合长期值守的助手"))])),
    ("mentionOn", str("被 @ 后，同一个群里的后续消息无需再 @；私聊的每条消息都会进入会话。")),
    ("mentionOff", str("它所在的群和私聊里的每条消息都会进入会话。")),
  ])
}

///|
/// How a connect's ways are said, as the core says them (present.ts modeWords): a Feishu one's in its groups' words.
fn fx_mode_words(feishu : Bool) -> Json {
  if feishu {
    obj([
      ("multi", obj([("label", str(tr("web-main.mode.feishu.multi.label"))), ("description", str(tr("web-main.mode.feishu.multi.description")))])),
      ("threads", obj([("label", str(tr("web-main.mode.feishu.threads.label"))), ("description", str(tr("web-main.mode.feishu.threads.description")))])),
      ("single", obj([("label", str(tr("web-main.mode.feishu.single.label"))), ("description", str(tr("web-main.mode.feishu.single.description")))])),
      ("mentionOn", str(tr("web-pages.connect.mentionOn.feishu"))),
      ("mentionOff", str(tr("web-pages.connect.mentionOff.feishu"))),
    ])
  } else {
    obj([
      ("multi", obj([("label", str("每个 thread 一个会话")), ("description", str("在 thread 中 @ 它即开启一个新会话，该 thread 的后续消息都进入此会话"))])),
      ("single", obj([("label", str("所有 thread 共用一个会话")), ("description", str("它看到的所有 thread 都进入同一个会话，适合长期值守的助手"))])),
      ("mentionOn", str("被 @ 的 thread 中，后续回复无需再 @。")),
      ("mentionOff", str("频道中它可见的每条消息都会进入会话。")),
    ])
  }
}

///|
/// A Slack app's permissions as the core says them (present.ts slackSections).
fn fx_sections() -> Json {
  [
    obj([
      ("title", str("消息")),
      (
        "groups",
        [
          fx_group("base", "读取和回复消息", "", fixed=true),
          fx_group("public", "在未加入的公开频道发言", ""),
          fx_group("dm", "主动发私信", ""),
          fx_group("customize", "使用自定义名称和头像发消息", ""),
          fx_group("reactions", "表情回应、置顶和书签", ""),
        ],
      ),
    ]),
    obj([
      ("title", str("频道和群")),
      (
        "groups",
        [
          fx_group("channels", "创建和管理频道", ""),
          fx_group("topics", "修改频道话题和邀请成员", ""),
          fx_group("connect", "Slack Connect 跨组织频道", "接受邀请需要由能批准 Slack Connect 的人（默认为管理员）安装 app；发送邀请也受工作区设置限制，且仅限付费版"),
        ],
      ),
    ]),
    obj([
      ("title", str("文件和文档")),
      (
        "groups",
        [
          fx_group("files", "读写文件", ""),
          fx_group("canvases", "读写 canvas", ""),
          fx_group("lists", "读写列表", ""),
        ],
      ),
    ]),
    obj([
      ("title", str("成员和搜索")),
      (
        "groups",
        [
          fx_group("people", "查看成员资料", ""),
          fx_group("usergroups", "管理用户组和发起通话", "创建用户组、修改成员需要工作区设置允许，很多工作区仅限管理员；用户组仅限付费版"),
          fx_group("search", "搜索消息、文件和成员", ""),
        ],
      ),
    ]),
    obj([
      ("title", str("其他")),
      (
        "groups",
        [
          fx_group("extras", "链接预览、提醒和状态", ""),
          fx_group("more", "状态、元数据和斜杠命令", ""),
        ],
      ),
    ]),
  ]
}

///|
/// A group of a Slack app's permissions, as the core says it (`admin`: what only Slack's admins allow, "" none).
fn fx_group(id : String, label : String, admin : String, fixed? : Bool = false) -> Json {
  obj([
    ("id", str(id)),
    ("label", str(label)),
    ("description", str(label)),
    ("admin", if admin == "" { Json::null() } else { str(admin) }),
    ("tip", str(if admin == "" { label } else { label + " " + admin })),
    ("fixed", Json::boolean(fixed)),
  ])
}

///|
/// The ways a multi-session connect could be switched to, as the core says them (present.ts modeChanges).
fn fx_mode_changes() -> Json {
  let change = fn(mode : String, mention : Bool, changed : Bool, effects : Array[String], action : String) {
    obj([
      ("mode", str(mode)),
      ("requireMention", Json::boolean(mention)),
      ("changed", Json::boolean(changed)),
      ("effects", Json::array(effects.map(str))),
      ("action", str(action)),
    ])
  }
  let single = "此后它收到的消息都将进入同一个会话；现有各 thread 的会话不再接收新消息，包括这些 thread 中的回复。记录会保留。"
  let fresh = "下一条消息将开始新的单会话；也可在切换后选择已有会话。"
  Json::array([
    change("multi-session", true, false, [], "确认更改"),
    change("single-session", true, true, [single, fresh], "改为单会话"),
    change("single-session", false, true, [single, fresh, "无需 @：它可见的所有频道和私信中的每条消息都会发送给 agent，用量会明显增加。"], "改为单会话"),
  ])
}

///|
/// Station `id`'s icon as the core gives it: the one it was given, else `given` (none, or its system `os`'s, as
/// fx.os_icons says).
fn fx_mark(id : String, given : String, os : String) -> String {
  match (fx.marks.get(id), fx.os_icons) {
    (Some(m), _) => m
    (None, 0) => given
    (None, 1) => ""
    (None, _) => "glyph:" + os
  }
}

///|
/// Whether station `id`'s icon is its system's (fx_mark): the core's `osIcon`.
fn fx_os_icon(id : String) -> Bool {
  fx.os_icons == 2 && fx.marks.get(id) is None
}

///|
fn fx_station(address : String) -> Json {
  let id = station_name(address)
  let renamed = fx.names.get(id)
  if address == "ws1/st1" {
    let profiles = fx_station_profiles()
    obj([
      ("station", str(address)),
      ("id", str(id)),
      ("name", str(renamed.unwrap_or("Willow"))),
      ("icon", str(fx_mark(id, "glyph:desktop", "linux"))),
      ("osIcon", Json::boolean(fx_os_icon(id))),
      ("summary", str(if fx.willow_incompatible { "版本不兼容，需要更新" } else if fx.gpus { "AMD EPYC · 2 个 agent 在工作" } else { "Apple M1 Pro · 2 个 agent 在工作" })),
      ("face", str("working")),
      ("line", str(if fx.willow_incompatible { "版本不兼容，需要更新" } else if fx.gpus { "AMD EPYC · 32 GB · Linux" } else { "Apple M1 Pro · 32 GB · macOS 26" })),
      ("online", Json::boolean(!fx.willow_away)),
      // its mode the viewer's to change (the core's `mine`: they added it, or they own or administer the workspace)
      ("mine", Json::boolean(!fx.willow_theirs)),
      ("profileGroups", Json::array(fx_station_profile_groups(profiles))),
      ("profileStates", fx_station_profile_states(profiles)),
      ("link", obj([
        ("state", str(if fx.willow_away { "offline" } else { "online" })),
        ..if fx.willow_away {
          [("cause", str("unreached")), ("message", str("连接超时，未收到 station 响应"))]
        } else {
          []
        },
      ])),
      ("stateText", str(if fx.willow_away { "5 分钟前在线" } else { "" })),
      ("acceptAutoChats", Json::boolean(fx.accept_auto_chats)),
      (
        "problems",
        if fx.willow_incompatible {
          [obj([("key", str("incompatible")), ("level", str("amber")), ("text", str("版本不兼容：这台 station 和这个 still.fail 的版本不匹配，部分信息无法显示。请更新 still.fail 和这台 station。"))])]
        } else if fx.willow_away {
          [obj([("key", str("away")), ("level", str("red")), ("text", str("无法连接：可能已离线，或受中继、防火墙影响"))])]
        } else {
          []
        },
      ),
      (
        "diag",
        if fx.willow_away {
          obj([
            ("cause", str("unreached")),
            ("summary", str("本机已连上 still.fail cloud，但所有路径均无法连上这台 station")),
            ("detail", str("连接超时，未收到 station 响应")),
            ("lastOnlineText", str("5 分钟前（15:42）")),
            ("cloudStatus", str("正常")),
            ("retryText", str("已连续失败 5 次 · 下次重试 15:52:10（每 10 分钟）")),
            ("lastNetText", str("东京中继 · 42 ms")),
            ("addresses", [str("192.168.1.24:41901"), str("100.64.0.12:41901")]),
            (
              "ways",
              [
                obj([("name", str("局域网直连")), ("status", str("timeout")), ("resultText", str("无响应（握手 · 10 秒）"))]),
                obj([("name", str("Tailscale")), ("status", str("error")), ("resultText", str("失败（握手 · 320ms） · connection refused"))]),
                obj([("name", str("东京中继")), ("status", str("timeout")), ("resultText", str("无响应（等待认证 · 10 秒）"))]),
                obj([("name", str("新加坡中继")), ("status", str("down")), ("resultText", str("中继未连接"))]),
              ],
            ),
            ("copyText", str("Station: Willow (st1) v0.1.1288\nCause: unreached — 本机已连上 still.fail cloud，但所有路径均无法连上这台 station\nCloud: 正常\nLast online: 5 分钟前（15:42）\nLast route: 东京中继 · 42 ms\nAddresses: 192.168.1.24:41901, 100.64.0.12:41901\nRetry: 已连续失败 5 次 · 下次重试 15:52:10（每 10 分钟）\nDetail: 连接超时，未收到 station 响应\nRoutes:\n  - [timeout] 局域网直连: 无响应（握手 · 10 秒）\n  - [error] Tailscale: 失败（握手 · 320ms） · connection refused\n  - [timeout] 东京中继: 无响应（等待认证 · 10 秒）\n  - [down] 新加坡中继: 中继未连接")),
          ])
        } else {
          Json::null()
        },
      ),
      ("protect", Json::boolean(fx_unprotected.val && !fx.willow_away)),
      // the runtimes it runs, each with its models (its page's: the connect page asks whether one runs on its runtime)
      ("runtimes", [obj([("runtime", str("claude")), ("models", [str("claude-opus-5-5"), str("claude-sonnet-5")])])]),
      // what its profiles have turned on (Claude 主账号's: Opus 5.5 and Sonnet 5, on claude)
      (
        "models",
        [
          obj([("model", str("claude-opus-5-5")), ("name", str("Opus 5.5")), ("family", str("Opus")), ("maker", obj([("id", str("anthropic"))])), ("runtimes", ["claude"])]),
          obj([("model", str("claude-sonnet-5")), ("name", str("Sonnet 5")), ("family", str("Sonnet")), ("maker", obj([("id", str("anthropic"))])), ("runtimes", ["claude"])]),
        ],
      ),
      (
        "host",
        if fx.willow_incompatible {
          Json::null()
        } else {
        obj([
          ("identity", str(if fx.gpus { "AMD EPYC · 32 GB · Linux" } else { "Apple M1 Pro · 32 GB · macOS 26" })),
          ("gpus", if fx.gpus {
            let cards : Array[Json] = [
              obj([("big", str("63")), ("unit", str("%")), ("left", Json::number(63.0)), ("level", str("ok")), ("title", str("GPU 1 空闲率")), ("total", str("显存剩 20/24G")), ("model", str("NVIDIA GeForce RTX 4090"))]),
              obj([("big", str("100")), ("unit", str("%")), ("left", Json::number(100.0)), ("level", str("ok")), ("title", str("GPU 2 空闲率")), ("total", str("显存剩 23/24G")), ("model", str("NVIDIA GeForce RTX 4090"))]),
            ]
            if fx.more_gpus {
              cards.push(obj([("big", str("50")), ("unit", str("%")), ("left", Json::number(50.0)), ("level", str("ok")), ("title", str("GPU 3 空闲率")), ("total", str("显存剩 12/24G")), ("model", str("NVIDIA GeForce RTX 4090"))]))
              cards.push(obj([("big", str("20")), ("unit", str("%")), ("left", Json::number(20.0)), ("level", str("amber")), ("title", str("GPU 4 空闲率")), ("total", str("显存剩 5/24G")), ("model", str("NVIDIA GeForce RTX 4090"))]))
            }
            Json::array(cards)
          } else { [] }),
          (
            "meters",
            [
              meter("CPU", if fx.low_meters { 8 } else { 72 }, if fx.low_meters { "red" } else { "ok" }, if fx.low_meters { "空闲 8%" } else { "空闲 72%" }, if fx.low_meters { "8" } else { "72" }, "%", "CPU 空闲率", "负载 1.4", title_short="CPU 空闲"),
              if fx.willow_away {
                meter("内存", 6, "red", "剩 1.9 G", "1.9", "GB", "可用内存", "总内存 32 GB", total_short="总 32 GB")
              } else {
                meter("内存", 18, "amber", "剩 5.8 G", "5.8", "GB", "可用内存", "总内存 32 GB", total_short="总 32 GB")
              },
              if fx.low_meters || fx.willow_away {
                meter("磁盘", 9, "amber", "剩 19.4 G", "19.4", "GB", "可用磁盘", "总磁盘 1 TB", total_short="总 1 TB")
              } else {
                meter("磁盘", 42, "ok", "剩 420 G", "420", "GB", "可用磁盘", "总磁盘 1 TB", total_short="总 1 TB")
              },
            ],
          ),
          ("uptimeText", str("已运行 6 天 4 小时")),
          ("madeOf", str(if fx.gpus {
            "AMD EPYC 7543 · 64 核 · x86_64 · Linux 6.8.0-45-generic · willow"
          } else {
            "Apple M1 Pro · 10 核 · arm64 · macOS 26.2 · willow"
          })),
          // where its traffic leaves for the internet (Host's egressText)
          ("egressText", str("出口 美国")),
        ])
        },
      ),
      (
        "net",
        if fx.willow_away {
          obj([
            ("path", str("东京中继")),
            ("via", str("relay")),
            ("rtt", obj([("text", str("42 ms")), ("level", str("ok"))])),
            ("rttHistory", []),
            ("down", str("0 B/s")),
            ("up", str("0 B/s")),
            ("total", str("")),
            ("downTotal", str("212 MB")),
            ("upTotal", str("9.6 MB")),
          ])
        } else {
          obj([
            ("path", str("直连")),
            ("via", str("direct")),
            ("rtt", obj([("text", str("38 ms")), ("level", str("ok"))])),
            ("rttHistory", []),
            ("down", str("1.4 MB/s")),
            ("up", str("96 KB/s")),
            ("total", str("")),
            ("downTotal", str("212 MB")),
            ("upTotal", str("9.6 MB")),
          ])
        },
      ),
      (
        "overview",
        obj([
          ("connects", [fx_connect("k1", "星火助手", "online", "在线", "multi-session")]),
          ("profiles", Json::array(profiles)),
          // a new profile's sign-in under way (settings-new-profile-login…)
          (
            "logins",
            if fx_colab_login.val {
              [
                obj([
                  ("id", str("login-new")),
                  ("runtime", Json::null()),
                  ("service", str("colab")),
                  (
                    "job",
                    obj([
                      ("profile", str("login-new")),
                      ("runtime", Json::null()),
                      ("service", str("colab")),
                      ("state", str("needs_code")),
                      ("url", str("https://accounts.google.com/o/oauth2/v2/auth?client_id=1014160490159&scope=colaboratory")),
                      ("startedAt", Json::number(0.0)),
                      ("expiresAt", Json::number(0.0)),
                      ("browser", Json::boolean(true)),
                    ]),
                  ),
                ]),
              ]
            } else if fx_google_login.val != "" {
              [
                obj([
                  ("id", str("login-new")), ("runtime", str("agy")), ("job", fx_google_job(fx_google_login.val)),
                  ("created", if fx_google_login.val == "done" { str("gw") } else { Json::null() }),
                ]),
              ]
            } else if fx.new_login && fx_new_login_done.val {
              [obj([("id", str("login-new")), ("runtime", str("claude")), ("job", fx_login_job("login-new", "done")), ("created", str("cc"))])]
            } else if fx.new_login {
              [obj([("id", str("login-new")), ("runtime", str("claude")), ("job", fx_login_job("login-new", "needs_code"))])]
            } else {
              []
            },
          ),
          ("processesText", str("2 个 agent 进程 · claude 1.2 GB")),
          (
            "slackApps",
            if fx_connects_waiting.val {
              [
                obj([
                  ("appId", str("A07GEMINI01")),
                  ("name", str("Gemini-Monoid")),
                  ("teamId", str("T04ACME0001")),
                  ("team", str("星火")),
                  ("installed", Json::boolean(false)),
                  ("install", str("https://slack.com/oauth/v2/authorize?client_id=1")),
                ]),
              ]
            } else {
              []
            },
          ),
          ("drive", obj([("roots", [{ "path": "~/项目", "name": "项目", "state": "ok" }, { "path": "~/文档", "name": "文档", "state": "ok" }]), ("all", Json::boolean(false))])),
          (
            "updates",
            [
              obj([
                ("id", str("station")),
                ("name", str("Station")),
                ("installed", Json::boolean(true)),
                ("version", str(if fx_station_updated.val { "0.1.1300" } else { "0.1.1288" })),
                ("latest", str("0.1.1300")),
                ("newer", Json::boolean(!fx_station_updated.val)),
                ("channel", str("stable")),
                ("auto", Json::boolean(if fx_station_override.val { false } else if fx_station_back.val == "" { fx.auto } else { fx_station_back.val == "settings-station-back" })),
                ("updatable", Json::boolean(true)),
                ("state", str(if fx_station_update_failed.val || fx.willow_away { "failed" } else { "idle" })),
                ("failedText", str("更新失败")),
                ("message", str(if fx_station_update_failed.val { "无法读取 C:\\Users\\Willow\\.stillfail\\mesh\\cloud.json：文件可能已加密或损坏。请在文件加密软件中允许程序 C:\\Users\\Willow\\.stillfail\\app\\node\\node.exe 读取，或从备份恢复文件。" } else if fx.willow_away { "下载更新包超时，请检查网络连接后重试" } else { "" })),
                ("checkedAt", Json::number(if fx.willow_away { 1795189320000.0 } else { 1.0 })),
                ("done", str(if fx_station_updated.val { "已更新到 0.1.1300，agent 未中断" } else { "" })),
                // (the core's words of it: present.ts software)
                ("shownText", str(if fx_station_override.val { "本地替换版（基于 0.1.1288）" } else if fx_station_updated.val { "0.1.1300" } else { "0.1.1288" })),
                ("tipText", str("")),
              ] +
                (if fx_station_override.val {
                  [
                    ("overridden", Json::boolean(true)),
                    ("overrideBase", str("0.1.1288")),
                    ("overrideKind", str("overlay")),
                    ("overrideNote", str("mm2 overview 扇出热修复")),
                    ("autoWhen", Json::array([str("#8270"), str("FB-123")])),
                  ]
                } else {
                  []
                }) +
                (if fx_station_back.val == "" {
                  []
                } else {
                  [("earlier", Json::array([str("0.1.1280"), str("0.1.1276"), str("0.1.1262")]))] +
                  (if fx_station_back.val == "settings-station-back-held" { [("autoAfter", str("0.1.1300"))] } else { [] })
                })),
              obj([
                ("id", str("claude")),
                ("name", str("Claude Code")),
                ("installed", Json::boolean(true)),
                ("version", str("2.1.4")),
                ("latest", str("2.1.4")),
                ("newer", Json::boolean(false)),
                ("updatable", Json::boolean(true)),
                ("state", str("idle")),
                ("checkedAt", Json::number(if fx.willow_away { 1795189320000.0 } else { 1.0 })),
                ("shownText", str("2.1.4")),
                ("tipText", str("已是最新")),
              ]),
              obj([
                ("id", str("codex")),
                ("name", str("Codex")),
                ("installed", Json::boolean(false)),
                ("newer", Json::boolean(false)),
                ("updatable", Json::boolean(true)),
                ("state", str("idle")),
                ("checkedAt", Json::number(if fx.willow_away { 1795189320000.0 } else { 1.0 })),
                ("shownText", str("未安装")),
                ("tipText", str("")),
              ]),
            ],
          ),
          (
            "permissions",
            obj([
              (
                "grants",
                [
                  obj([("id", str("capture")), ("name", str("屏幕录制")), ("line", str("查看这台 Mac 的屏幕")), ("granted", Json::boolean(true)), ("asking", Json::boolean(false))]),
                  obj([("id", str("control")), ("name", str("辅助功能")), ("line", str("操作这台 Mac 的鼠标和键盘")), ("granted", Json::boolean(false)), ("asking", Json::boolean(false))]),
                  obj([("id", str("documents")), ("name", str("文稿")), ("line", str("读写「文稿」中的文件")), ("granted", Json::boolean(false)), ("asking", Json::boolean(true))]),
                ],
              ),
              ("note", str("未允许辅助功能：agent 只能查看屏幕，不能操作")),
              ("canRequest", Json::boolean(true)),
            ]),
          ),
          (
            "agentEnv",
            [
              obj([("key", str("HTTPS_PROXY")), ("secret", Json::boolean(false)), ("value", str("http://127.0.0.1:7890"))]),
              obj([("key", str("NO_PROXY")), ("secret", Json::boolean(false)), ("value", str("localhost,.internal"))]),
            ],
          ),
          ("search", obj([("files", str("spotlight")), ("personal", Json::boolean(false))])),
          ("context", obj([("afreshWhenCold", Json::boolean(fx.afresh)), ("afreshAbove", Json::number(fx.afresh_above))])),
          ("diagnostics", obj([("logs", Json::boolean(fx.logs))])),
          ("autoChats", obj([("enabled", Json::boolean(fx.accept_auto_chats)), ("canEdit", Json::boolean(true))])),
          ("network", obj([("congestion", str(fx.congestion))])),
          ("elevation", fx.elevation.unwrap_or(Json::null())),
          ("screenService", fx.screen_service.unwrap_or(Json::null())),
          ("copies", fx.copies.unwrap_or(Json::null())),
          ("move", fx_move_offer()),
          ("features", fx_station_features()),
          ("sharing", Json::boolean(true)),
          ("shareAllowAuto", Json::boolean(true)),
          (
            "machineLogins",
            [
              obj([("runtime", str("codex")), ("installed", Json::boolean(true)), ("loggedIn", Json::boolean(true)), ("email", str("lin@example.com")), ("plan", str("plus")), ("planText", str("Plus")), ("usable", Json::boolean(true)), ("text", str("")), ("offered", Json::boolean(true)),
                // (null where the fixture says none: a field left as it is, as field_made has it)
                ("quota", if fx.offer_quota { fx_offer_quota() } else { Json::null() }),
              ]),
            ],
          ),
          (
            "archiving",
            // (the core's words and choices)
            obj([
              ("days", Json::number(1.0)),
              ("slackDays", Json::number(3.0)),
              ("reviewed", Json::boolean(false)),
              ("canEdit", Json::boolean(true)),
              ("mode", str("idle")),
              ("summaryText", str("空闲就归档 · 1 天 · Slack：3 天")),
              ("daysOffered", [Json::number(1.0), Json::number(3.0), Json::number(7.0), Json::number(30.0)]),
              ("slackDaysOffered", [Json::number(0.0), Json::number(3.0), Json::number(7.0), Json::number(30.0)]),
              ("daysOfferedText", [str("1 天"), str("3 天"), str("7 天"), str("30 天")]),
              ("slackDaysOfferedText", [str("不归档"), str("3 天"), str("7 天"), str("30 天")]),
              ("reviewOn", Json::boolean(true)),
              ("reviewText", str("已开启 · GPT-6 mini")),
              ("stalled", Json::boolean(false)),
              ("lineText", str("空闲就归档 · 1 天 · Slack：3 天")),
              (
                "modes",
                [
                  obj([("mode", str("off")), ("label", str("不自动归档")), ("days", Json::number(0.0)), ("reviewed", Json::boolean(false)), ("allowed", Json::boolean(true))]),
                  obj([("mode", str("idle")), ("label", str("空闲就归档")), ("days", Json::number(1.0)), ("reviewed", Json::boolean(false)), ("allowed", Json::boolean(true))]),
                  obj([("mode", str("reviewed")), ("label", str("按模型判断")), ("days", Json::number(1.0)), ("reviewed", Json::boolean(true)), ("allowed", Json::boolean(true))]),
                ],
              ),
              ("modeNote", str("空闲超过下面的天数就归档。只看状态，不读内容：chat 里提到但没做完的事，它看不出来。")),
            ]),
          ),
          (
            "automaticDecisions",
            obj([
              ("canEdit", Json::boolean(true)),
              ("canReview", Json::boolean(true)),
              ("settings", obj([("completion", obj([("enabled", Json::boolean(true))]))])),
              ("models", [obj([("id", str("gpt-6-mini")), ("name", str("GPT-6 mini")), ("profiles", ["cx"])])]),
              ("recent", []),
              (
                "policy",
                obj([
                  ("text", str("做完、没有待办的对话归档；还在等人回复或有后续计划的留下。")),
                  (
                    "options",
                    [
                      obj([("id", str("o1")), ("name", str("已完成")), ("rubric", str("任务做完，没有后续")), ("archive", Json::boolean(true)), ("count", Json::number(12.0)), ("chats", [obj([("session", str("s-c3")), ("title", str("夜里的构建又失败了"))])])]),
                      obj([("id", str("o2")), ("name", str("被放弃")), ("rubric", str("明确不再继续")), ("archive", Json::boolean(true)), ("count", Json::number(3.0)), ("chats", [])]),
                      obj([("id", str("o3")), ("name", str("等回复")), ("rubric", str("在等某人的答复")), ("archive", Json::boolean(false)), ("count", Json::number(5.0)), ("chats", [])]),
                    ],
                  ),
                  ("days", Json::number(7.0)),
                  ("checked", Json::number(20.0)),
                  ("failed", Json::number(0.0)),
                  ("edited", Json::boolean(false)),
                  ("summaryText", str("近 7 天检查了 20 个对话")),
                  ("changeText", str("上次修改 3 天前")),
                ]),
              ),
            ]),
          ),
        ]),
      ),
      ("betaOffered", Json::boolean(true)),
    ])
  } else {
    // (Maple online for Profile's ＋; it, and Cedar besides, to take Willow's chats as it is retired)
    let up = fx.mba_online || fx.retire_others >= 2 || (fx.retire_others == 1 && id == "st2")
    obj([
      ("station", str(address)),
      ("id", str(id)),
      ("name", str(renamed.unwrap_or(if id == "st3" && (fx.retire_others >= 2 || fx.os_icons > 0) { "Cedar" } else { "Maple" }))),
      ("icon", str(fx_mark(id, "glyph:laptop:teal", if id == "st3" { "windows" } else { "macos" }))),
      ("osIcon", Json::boolean(fx_os_icon(id))),
      ("summary", str(if up { "Apple M3 · 空闲" } else { "离线 · 2 天前" })),
      ("face", str(if up { "idle" } else { "offline" })),
      ("online", Json::boolean(up)),
      ("acceptAutoChats", Json::boolean(true)),
      ("link", obj([("state", str(if up { "online" } else { "offline" }))])),
      // (away, as Willow away says it)
      ("stateText", str(if up { "" } else { "2 天前在线" })),
      ("problems", if up { [] } else { [obj([("key", str("away")), ("level", str("red")), ("text", str("离线：在该机器上打开 still.fail 即可重新连接"))])] }),
      ("runtimes", []),
      ("models", []),
      (
        "overview",
        if up && fx.copies is Some(_) {
          obj([("copies", fixture_copies_maple())])
        } else {
          Json::null()
        },
      ),
    ])
  }
}

///|
fn fx_archive(q? : String = "") -> Json {
  let all = [
    ("a1", "整理上个月的发票", "已经把 23 张发票按月份归好", "14:05", "今天", true),
    ("a2", "试一下新的图标尺寸", "三种尺寸的对比图放在共享文件夹里", "11:30", "今天", true),
    ("a3", "周会纪要", "下周一前补上第三项的负责人", "18:20", "昨天", false),
    ("a4", "清理旧的构建缓存", "删掉了 41 GB 的旧缓存", "09:12", "星期三", true),
  ]
  let days : Array[(String, Array[Json])] = []
  for a in all {
    if fx.restored.contains("s-" + a.0) {
      continue
    }
    // (looked for: those whose title or last line has the words, as the core's archive search has them)
    if q != "" && !a.1.contains(q) && !a.2.contains(q) {
      continue
    }
    let row = obj([
      ("station", str("ws1/st1")),
      ("id", str(a.0)),
      ("session", str("s-" + a.0)),
      ("thread", Json::number(a.0.length().to_double())),
      ("title", str(a.1)),
      ("last", str(a.2)),
      ("at", Json::number(0.0)),
      ("clock", str(a.3)),
      ("how", str("手动归档")),
      ("deletable", Json::boolean(a.5)),
    ])
    match days.iter().find_first(fn(d) { d.0 == a.4 }) {
      Some(d) => d.1.push(row)
      None => days.push((a.4, [row]))
    }
  }
  obj([
    ("days", Json::array(days.map(fn(d) { obj([("label", str(d.0)), ("items", Json::array(d.1))]) }))),
    ("errors", []),
    ("wait", obj([("reading", Json::boolean(false)), ("failing", []), ("empty", Json::boolean(days.length() == 0))])),
    ("total", Json::number(days.length().to_double())),
    ("more", Json::boolean(false)),
  ])
}

///|
/// The list `only` (a key) is of ("" none).
fn only_shown_list(lists : Array[(String, String, Array[(String, String, String, String, Double)])], only : String) -> String {
  for l in lists {
    if l.2.search_by(fn(it) { it.0 == only }) is Some(_) {
      return l.0
    }
  }
  ""
}

///|
/// 用量's summary as the core says it (views/usage-summary.ts), its year from 2025-10-05: a workspace counted since March, most days busy
/// and weekends quieter, today Friday 10/2 (a Saturday after it).
fn fx_usage_summary() -> Json {
  let cells : Array[Json] = []
  let levels : Array[Int] = []
  for i in 0..<(52 * 7) {
    let week = i / 7
    let wd = i % 7
    let level = if i == 51 * 7 + 6 {
      -1
    } else if week < 22 {
      0
    } else {
      // (a made-up mix: weekdays busier, a quiet day now and then)
      let h = (i * 7919 + week * 104729 + wd * 31) % 997
      if wd == 0 || wd == 6 {
        h % 3
      } else {
        h % 5
      }
    }
    cells.push(Json::number(level.to_double()))
    levels.push(level)
  }
  // each day's date from 2025-10-05 (2026 no leap year), as the core says it under the pointer
  let lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  let date = fn(n : Int) {
    let mut m = 9
    let mut d = 5 + n
    while d > lengths[m] {
      d = d - lengths[m]
      m = (m + 1) % 12
    }
    "\{m + 1}月\{d}日"
  }
  let tips : Array[Json] = []
  let week_tips : Array[Json] = []
  let running_tips : Array[Json] = []
  for i, level in levels {
    tips.push(
      str(
        if level < 0 {
          ""
        } else if level == 0 {
          date(i) + " · 没有用 token"
        } else {
          date(i) + " · \{level * 1200} 万 token"
        },
      ),
    )
  }
  for w in 0..<52 {
    week_tips.push(str(date(w * 7) + "起一周 · " + (if w < 22 { "没有用 token" } else { "\{(w * 5 % 4) + 3} 千万 token" })))
    running_tips.push(str("截至" + date(@cmp.minimum(w * 7 + 6, 51 * 7 + 5)) + " · 共 \{w} 亿 token"))
  }
  let weekly : Array[Json] = []
  let cumulative : Array[Json] = []
  for w in 0..<52 {
    weekly.push(Json::number((if w < 22 { 0 } else { (w * 5 % 4) + 3 }).to_double()))
    cumulative.push(Json::number((if w < 22 { 0 } else { (w - 21) * 7 / 30 + 1 }).to_double()))
  }
  let months = [(4, "11月"), (9, "12月"), (13, "1月"), (17, "2月"), (21, "3月"), (26, "4月"), (30, "5月"), (35, "6月"), (39, "7月"), (43, "8月"), (48, "9月")]
  let named = fn(title : String, key : String, rows : Array[(String, String)]) {
    obj([("title", str(title)), ("items", Json::array(rows.map(fn(r) { obj([(key, str(r.0)), ("value", str(r.1))]) })))])
  }
  obj([
    ("title", str("")),
    (
      "figures",
      Json::array([("累计 token", "18.3 亿"), ("归档的对话", "1,358"), ("跨设备任务", "312")].map(fn(f) {
        obj([("label", str(f.0)), ("value", str(f.1))])
      })),
    ),
    (
      "activity",
      obj([
        ("title", str("Token 活跃度")),
        ("sub", str("近 12 个月")),
        ("views", [str("按天"), str("按周")]),
        ("weekdays", Json::array(["日", "一", "二", "三", "四", "五", "六"].map(str))),
        ("months", Json::array(months.map(fn(m) { obj([("week", Json::number(m.0.to_double())), ("label", str(m.1))]) }))),
        ("cells", Json::array(cells)),
        ("weekly", Json::array(weekly)),
        ("cumulative", Json::array(cumulative)),
        ("tips", Json::array(tips)),
        ("weekTips", Json::array(week_tips)),
        ("runningTips", Json::array(running_tips)),
        ("less", str("少")),
        ("more", str("多")),
        ("captions", [str(""), str("每列一周 · 最高 1.1 亿")]),
      ]),
    ),
    ("stations", named("各设备的工作量", "name", [("Willow", "12.6 亿 token · 69%"), ("Maple", "4.1 亿 token · 22%"), ("Birch", "1.6 亿 token · 9%")])),
    ("places", named("对话来自", "name", [("still.fail", "1,212 个对话"), ("Slack", "184 个对话"), ("飞书", "34 个对话")])),
    ("asOf", str("")),
  ])
}

///|
/// What the core's `usage` view says (views/usage.ts) of a made-up workspace: its days split by the list `split`
/// asks for, of the one person, account or model `only` names (its key) alone; as it is sent (client/core-ts
/// schema.ts UsageView: not its accounts' allowances, its scale's lines, a day's calls and parts, an item's calls).
fn fx_usage(days : Int, split? : String = "people", only? : String = "", day? : String = "", details_pending? : Bool = false) -> Json {
  // (the one alone: a part of everything)
  let part = if only == "" { 1.0 } else { 0.42 }
  let daily : Array[Json] = []
  for i in 0..<days {
    let cost = (((i * 37 + 11) % 23).to_double() + 4.0) * part
    daily.push(
      obj([
        ("day", str("2026-10-" + (if i + 1 < 10 { "0" } else { "" }) + (i + 1).to_string())),
        ("label", str("10/" + (i + 1).to_string())),
        ("cost", Json::number(cost)),
        ("costText", str("$" + cost.to_int().to_string())),
        // (what the core says of it: views/usage.ts)
        ("name", str(if i == days - 1 { "今天" } else { "10/" + (i + 1).to_string() })),
        ("tick", str(if i == days - 1 { "今天" } else if days <= 10 || (days - 1 - i) % 7 == 0 { "10/" + (i + 1).to_string() } else { "" })),
        ("shares", [Json::number(0.6), Json::number(0.3), Json::number(0.1)]),
      ]),
    )
  }
  let item = fn(key : String, title : String, sub : String, cost : String, share : Double, shareText : String) {
    obj([
      ("key", str(key)),
      ("title", str(title)),
      ("sub", str(sub)),
      ("costText", str(cost)),
      ("share", Json::number(share)),
      ("shareText", str(shareText)),
      ("tokensText", str("")),
    ])
  }
  let series = match split {
    "models" => [("claude-opus-5-5", "Opus 5.5", "$84"), ("gpt-6", "GPT-6", "$28"), ("", "其他", "$6.10")]
    "profiles" => [("Willow/cc", "公司 Claude", "$84"), ("Willow/codex", "Codex 团队", "$34")]
    "chats" => [("Willow/1", "整理发布清单", "$31"), ("Willow/4", "给设置页加一个深色模式开关", "$22"), ("", "其他", "$65")]
    _ => [("lin@example.com", "林", "$80"), ("ana@example.com", "Ana", "$31"), ("", "其他", "$7.20")]
  }
  // The core ranks the filtered rows too: the selected split then contains only the chosen part.
  let series = if only != "" && series.iter().any(fn(s) { s.0 == only }) { series.filter(fn(s) { s.0 == only }) } else { series }
  let lists = [
    (
      "people",
      "按人",
      [
        ("lin@example.com", "林", "18 个对话 · 812 次调用 · 最多 Opus 5.5", "$80", 0.68),
        ("ana@example.com", "Ana", "9 个对话 · 410 次调用 · 最多 GPT-6", "$31", 0.26),
        ("wu@example.com", "吴", "4 个对话 · 118 次调用 · 最多 Sonnet 5", "$4.50", 0.04),
        ("chen@example.com", "陈", "2 个对话 · 52 次调用 · 最多 Haiku 5", "$1.80", 0.015),
        ("zhao@example.com", "赵", "1 个对话 · 24 次调用 · 最多 Haiku 5", "$0.90", 0.008),
      ],
    ),
    (
      "chats",
      "按对话",
      [
        ("Willow/1", "整理发布清单", "林 · Opus 5.5 · Willow", "$31", 0.26),
        ("Willow/4", "给设置页加一个深色模式开关", "Ana · GPT-6 · Willow", "$22", 0.19),
        ("Maple/3", "夜里的构建又失败了", "林 · Opus 5.5 · Maple", "$15", 0.13),
        ("Willow/8", "排查列表滚动卡顿", "林 · Opus 5.5 · Willow", "$12", 0.10),
        ("Maple/6", "补充支付回调单元测试", "Ana · Sonnet 5 · Maple", "$9.40", 0.08),
        ("deleted/all", "已删除的对话（14 个）", "共 312 次调用 · Opus 5.5、GPT-6", "$28.60", 0.24),
      ],
    ),
    (
      "profiles",
      "按账号",
      [
        ("Willow/cc", "公司 Claude", "Willow · 订阅 (Max) · 最多 Opus 5.5", "$84", 0.71),
        ("Willow/codex", "Codex 团队", "Willow · 订阅 (Pro) · 最多 GPT-6", "$34", 0.29),
      ],
    ),
    (
      "models",
      "按模型",
      [
        ("claude-opus-5-5", "Opus 5.5", "1,620 万 token · 842 次调用", "$84", 0.71),
        ("gpt-6", "GPT-6", "510 万 token · 390 次调用", "$28", 0.24),
        ("claude-haiku-5", "Haiku 5", "223 万 token · 184 次调用", "$6.10", 0.05),
      ],
    ),
  ]
  // (the day's name as the core says it: 10/5 for 2026-10-05)
  let dd = if day.length() >= 10 { day[8:].to_owned() } else { "" }
  // (its cost, as its bar says it)
  let day_cost = match daily.search_by(fn(d) { day != "" && text(Some(d), "day") == day }) {
    Some(i) => text(Some(daily[i]), "costText")
    None => ""
  }
  let day_name = if day == "" { "" } else { "10/" + (if dd.has_prefix("0") { dd[1:].to_owned() } else { dd }) }
  let only_shown = match lists.search_by(fn(l) { l.2.search_by(fn(it) { it.0 == only }) is Some(_) }) {
    Some(k) if only != "" => {
      let (_, _, its) = lists[k]
      let it = its[its.search_by(fn(it) { it.0 == only }).unwrap()]
      obj([("title", str(it.1))])
    }
    _ => Json::null()
  }
  obj([
    ("split", str(split)),
    ("only", only_shown),
    ("wait", obj([("reading", Json::boolean(details_pending)), ("failing", []), ("empty", Json::boolean(false))])),
    ("empty", Json::boolean(details_pending)),
    ("detailsPreparing", Json::boolean(details_pending)),
    (
      "tiles",
      [
        obj([
          ("label", str("折合费用")),
          ("value", str(if details_pending { "$0" } else if day_cost != "" { day_cost } else if only != "" { "$50" } else if days == 7 { "$118" } else { "$486" })),
          // (a day picked: against nothing)
          ("change", if details_pending || day != "" { Json::null() } else { str(if days == 7 { "↑18%" } else { "↓6.4%" }) }),
        ]),
        obj([
          ("label", str("模型调用")),
          ("value", str(if only != "" { "595 次" } else if days == 7 { "1,416 次" } else { "5,830 次" })),
          ("change", str(if days == 7 { "↑9.2%" } else { "↓3.1%" })),
        ]),
        obj([
          ("label", str("输入 token")),
          ("value", str(if only != "" { "970 万" } else if days == 7 { "2,310 万" } else { "9,870 万" })),
          ("sub", str("缓存命中 84%")),
          ("change", str(if days == 7 { "↑21%" } else { "↑2.5%" })),
        ]),
        obj([
          ("label", str("输出 token")),
          ("value", str(if only != "" { "18 万" } else if days == 7 { "43 万" } else { "1.8 亿" })),
          ("change", str(if days == 7 { "↓4.0%" } else { "持平" })),
        ]),
      ],
    ),
    ("versus", str("比前 " + days.to_string() + " 天")),
    ("period", str(if day != "" { day_name } else { "近 " + days.to_string() + " 天" })),
    ("summary", fx_usage_summary()),
    ("series", Json::array(series.map(fn(x) { obj([("key", str(x.0)), ("name", str(x.1)), ("costText", str(x.2))]) }))),
    ("daily", Json::array(daily)),
    ("many", Json::boolean(days > 10)),
    // (the scale the core works out for it: views/usage.ts scale)
    ("top", Json::number(30.0)),
    ("ticks", [obj([("value", Json::number(15.0)), ("label", str("$15"))]), obj([("value", Json::number(30.0)), ("label", str("$30"))])]),
    (
      "lists",
      Json::array(
        lists.map(fn(l) {
          let (key, title, its) = l
          let shown = if only == "" { its } else { its.filter(fn(it) { it.0 == only || key != only_shown_list(lists, only) }) }
          let listed = shown.map(fn(it) { item(it.0, it.1, it.2, it.3, it.4, (it.4 * 100.0).to_int().to_string() + "%") })
          obj([
            ("key", str(key)),
            ("title", str(title)),
            ("items", Json::array(listed)),
            // (its first three and the rest: as many here, each its key)
            ("parts", Json::array(shown.map(fn(it) { obj([("key", str(it.0))]) }))),
          ])
        }),
      ),
    ),
    ("notes", if details_pending { [str("正在读取历史记录，数据可能变化")] } else { [] }),
    ("basis", str("按各服务商公开的 API 价格折算，不是实际账单。")),
    (
      "prices",
      [
        obj([
          ("station", str("Willow")),
          ("note", str("每百万 token 的美元价格，取自服务商公开价格")),
          (
            "rows",
            [
              obj([("model", str("Opus 5.5")), ("rates", [obj([("label", str("输入")), ("value", str("$5"))]), obj([("label", str("输出")), ("value", str("$25"))]), obj([("label", str("缓存读")), ("value", str("$0.5"))])])]),
              obj([("model", str("GPT-6")), ("rates", [obj([("label", str("输入")), ("value", str("$2.5"))]), obj([("label", str("输出")), ("value", str("$10"))]), obj([("label", str("缓存读")), ("value", str("$0.25"))])])]),
              obj([("model", str("Sonnet 5")), ("rates", [obj([("label", str("输入")), ("value", str("$3"))]), obj([("label", str("输出")), ("value", str("$15"))]), obj([("label", str("缓存读")), ("value", str("$0.3"))])])]),
              obj([("model", str("Haiku 5")), ("rates", [obj([("label", str("输入")), ("value", str("$1"))]), obj([("label", str("输出")), ("value", str("$5"))]), obj([("label", str("缓存读")), ("value", str("$0.1"))])])]),
            ],
          ),
        ]),
        obj([("station", str("Maple")), ("note", str("station 离线，读不到它的价格表")), ("rows", [])]),
      ],
    ),
  ])
}

///|
fn fx_memory() -> Json {
  obj([
    (
      "global",
      obj([
        ("path", str("~/.stillfail/agent/MEMORY.md")),
        ("text", str("")),
        ("size", str("4 KB")),
        ("whenChanged", str("15 分钟前 · Willow")),
        (
          "sections",
          [
            obj([("title", str("开头")), ("text", str("这台机器上的 agent 共用的记忆。")), ("note", str("1 KB"))]),
            obj([
              ("title", str("习惯")),
              ("text", str("- 提交前先跑测试\n- 说明写成完整的句子")),
              ("note", str("2 条")),
              ("whenChanged", str("15 分钟前 · Willow")),
              (
                "diff",
                [
                  [str("-"), str("- UI 改动先本地出图发用户确认再提 PR")],
                  [str("+"), str("- 复杂的活和 UI 设计先让用户确认方案和预览效果再动手；干活中有新变化先确认方案")],
                ],
              ),
            ]),
          ],
        ),
      ]),
    ),
    (
      "skills",
      [
        obj([
          ("name", str("发布流程")),
          ("description", str("项目记忆：发布新版本时")),
          ("project", Json::boolean(true)),
          ("builtin", Json::boolean(false)),
          ("text", str("")),
          ("body", str("## 步骤\n\n1. 改版本号\n2. 写更新说明\n3. 打包并上传")),
          ("about", str("发布新版本时")),
          ("size", str("3 KB")),
          ("whenChanged", str(if fx.skills_shared.get("发布流程").unwrap_or(true) { "25 分钟前 · Willow" } else { "" })),
          (
            "diff",
            [
              [str("-"), str("2. 手工整理更新说明")],
              [str("+"), str("2. 写更新说明")],
            ],
          ),
          ("files", [obj([("name", str("checklist.md")), ("text", str("- 签名\n- 截图")), ("label", str("checklist")), ("size", str("1 KB"))])]),
          // (the core's words of it: looks.ts)
          ("group", str("project")), ("kindText", str("项目记忆")), ("whenText", str("发布新版本时")), ("line", str("发布新版本时")), ("pages", [obj([("key", str("")), ("label", str("总览")), ("text", str("## 步骤\n\n1. 改版本号\n2. 写更新说明\n3. 打包并上传"))]), obj([("key", str("checklist.md")), ("label", str("checklist")), ("size", str("1 KB")), ("text", str("- 签名\n- 截图"))])]),
          (
            "share",
            if fx.skills_shared.get("发布流程").unwrap_or(true) {
              obj([("id", str("sh1")), ("role", str("host")), ("host", str("st1")), ("conflicts", ["SKILL.md"]), ("users", ["st2"]), ("missing", [])])
            } else {
              obj([])
            }
          ),
        ]),
        obj([
          ("name", str("周报")),
          ("description", str("写周报时用的格式")),
          ("project", Json::boolean(false)),
          ("builtin", Json::boolean(false)),
          ("text", str("每周五下午写。")),
          ("size", str("1 KB")),
          ("whenChanged", str("40 分钟前 · Maple")),
          ("group", str("skill")), ("kindText", str("Skill")), ("whenText", str("写周报时用的格式")), ("line", str("写周报时用的格式")), ("pages", [obj([("key", str("")), ("label", str("总览")), ("text", str("每周五下午写。"))])]),
        ]),
        obj([("name", str("pdf")), ("size", str("2 KB")), ("description", str("读写 PDF")), ("project", Json::boolean(false)), ("builtin", Json::boolean(true)), ("text", str("")), ("group", str("builtin")), ("kindText", str("station 内置")), ("whenText", str("读写 PDF")), ("line", str("读写 PDF")), ("pages", [obj([("key", str("")), ("label", str("总览")), ("text", str("（空）"))])])]),
        obj([("name", str("xlsx")), ("size", str("2 KB")), ("description", str("读写表格")), ("project", Json::boolean(false)), ("builtin", Json::boolean(true)), ("text", str("")), ("group", str("builtin")), ("kindText", str("station 内置")), ("whenText", str("读写表格")), ("line", str("读写表格")), ("pages", [obj([("key", str("")), ("label", str("总览")), ("text", str("（空）"))])])]),
      ],
    ),
  ])
}

///|
/// The workspaces the new device asks into (settings-lock-prompt): 星火工作室 and 个人, and 开源 once it asked there
/// too (fx's `pairing_more`).
fn pairing_places() -> Array[Json] {
  let places = [obj([("id", str("ws1")), ("name", str("星火工作室"))]), obj([("id", str("ws2")), ("name", str("个人"))])]
  if fx.pairing_more {
    places.push(obj([("id", str("ws3")), ("name", str("开源")), ("emoji", str("🌲"))]))
  }
  places
}

///|
/// A made-up settings topic, None for one these do not make.
pub fn fixture_topic(mode : String, name : String, params : Map[String, Json]) -> Json? {
  if name == "lock" && mode.has_prefix("lock-") {
    return Some(waiting_lock(mode))
  }
  // (settings-vault-waiting, -replaced: the security page of a device not confirmed, as lock-waiting's, lock-replaced's)
  match fx.lock_case {
    "waiting" | "waiting-was" if name == "lock" => return Some(waiting_lock("lock-waiting"))
    "replaced" | "replaced-was" if name == "lock" => return Some(waiting_lock("lock-replaced"))
    _ => ()
  }
  let me : Json = obj([("sub", str("u1")), ("email", str("lin@example.com")), ("name", str("林")), ("role", str("owner"))])
  match name {
    // Willow's logins (station_logins.mbt): codex's under way, gh's done yesterday
    // (the settings' own pages only: a chat's login cards are the chats' fixture's)
    "machineLogins" if mode.has_prefix("settings") && text(Some(Json::object(params)), "station") == "ws1/st1" => {
      let gh_login = obj([
        ("id", str("login-0")),
        ("active", Json::boolean(false)),
        ("name", str("gh")),
        ("command", str("env GH_HOST=github.com /opt/homebrew/bin/gh auth login")),
        ("chat", str("s-c1")),
        ("chatTitle", str("整理发布清单")),
        ("whenText", str("昨天")),
        ("statusText", str("已登录")),
        ("doneByText", str("林 完成")),
        ("state", str("done")),
      ])
      Some(
        obj([
          ("supported", Json::boolean(true)),
          ("canLogin", Json::boolean(true)),
          ("canRelay", Json::boolean(true)),
          (
            "logins",
            [
              obj([("id", str("login-2")), ("active", Json::boolean(true)), ("command", str("codex login"))]),
              gh_login,
            ],
          ),
          (
            "tools",
            [
              obj([
                ("name", str("gh")),
                ("summaryText", str("林 登录 · 昨天")),
                ("failed", Json::boolean(false)),
                ("chat", str("s-c1")),
                ("chatTitle", str("整理发布清单")),
                ("countText", str("1 次")),
                ("tries", [gh_login]),
              ]),
            ],
          ),
        ]),
      )
    }
    "machineLogin" if mode.has_prefix("settings") && text(Some(Json::object(params)), "id") == "login-2" =>
      Some(
        obj([
          ("id", str("login-2")),
          ("title", str("在 Willow 上登录 codex")),
          ("state", str("browser")),
          ("step", str("open")),
          ("url", str("https://auth.openai.com/log-in")),
          ("domain", str("auth.openai.com")),
          ("active", Json::boolean(true)),
          ("statusText", str("等你在浏览器里登录")),
        ]),
      )
    "workspace" =>
      Some(
        obj([
          ("id", str("ws1")),
          ("name", str("星火工作室")),
          ("role", str("owner")),
          (
            "members",
            fx_members(me),
          ),
          (
            "stations",
            if rigs_fixture_made() {
              [obj([("id", str("st2")), ("name", str("Maple"))])]
            } else {
              [obj([("id", str("st1")), ("name", str("Willow"))]), obj([("id", str("st2")), ("name", str("Maple"))])]
            },
          ),
          ("rigs", rigs_fixture_listed(mode)),
          ("invitations", [obj([("id", str("i1")), ("role", str("member")), ("email", str("qin@example.com")), ("time", obj([("expires_at", stamp_of("", until="6 天后"))]))])]),
          ("added", [obj([("email", str("he@example.com")), ("role", str("member"))])]),
          (
            "relays",
            Json::array(
              fx.relays.map(fn(u) {
                let h = if u.has_prefix("https://") { u.unsafe_substring(start=8, end=u.length()) } else { u }
                let host = if h.has_suffix("/") { h.unsafe_substring(start=0, end=h.length() - 1) } else { h }
                obj([("url", str(u)), ("host", str(host)), ("by", str("林"))])
              }),
            ),
          ),
        ]),
      )
    // the workspace's stations that only run tasks (rigs_fixture.mbt)
    "rigs" if rigs_fixture_mode(mode) => Some(rigs_fixture_topic(mode))
    // the workspace's devices (devices_fixture.mbt)
    "devices" if devices_fixture_mode(mode) => Some(devices_fixture_topic())
    // every way its devices reach its stations (the core's views/ways.ts), the punched path turned off
    "workspaceWays" => {
      let own = fx.relays.map(fn(u) {
        let h = if u.has_prefix("https://") { u.unsafe_substring(start=8, end=u.length()) } else { u }
        let host = if h.has_suffix("/") { h.unsafe_substring(start=0, end=h.length() - 1) } else { h }
        obj([("id", str(u)), ("kind", str("relay")), ("name", str(host)), ("own", Json::boolean(true)), ("by", str("林")), ("on", Json::boolean(true))])
      })
      let ways = [
        obj([("id", str("https://app.still.fail/")), ("kind", str("relay")), ("name", str("Cloudflare")), ("own", Json::boolean(false)), ("on", Json::boolean(!fx.ours_off))]),
        obj([("id", str("https://39.105.157.122/")), ("kind", str("relay")), ("name", str("北京")), ("own", Json::boolean(false)), ("on", Json::boolean(!fx.ours_off))]),
      ] +
      own + [
        obj([("id", str("lan")), ("kind", str("lan")), ("name", str("")), ("own", Json::boolean(false)), ("on", Json::boolean(true))]),
        obj([("id", str("tailnet")), ("kind", str("tailnet")), ("name", str("")), ("own", Json::boolean(false)), ("on", Json::boolean(true))]),
        obj([("id", str("direct")), ("kind", str("direct")), ("name", str("")), ("own", Json::boolean(false)), ("on", Json::boolean(false))]),
      ]
      let off = if fx.ours_off { 3 } else { 1 }
      Some(
        obj([
          ("ways", Json::array(ways)),
          ("off", Json::number(off.to_double())),
          ("offLabel", str("已关闭 \{off} 项")),
        ]),
      )
    }
    "stations" =>
      if fx.none {
        Some([])
      } else {
        // (settings-stations-motion: 3 comes, then Maple goes)
        let all = if rigs_fixture_made() { [fx_station("ws1/st2")] } else { [fx_station("ws1/st1"), fx_station("ws1/st2")] }
        // (settings-stations-os: Cedar, a Windows machine, beside them)
        if fx.motion >= 1 || fx.retire_others >= 2 || fx.os_icons > 0 {
          all.push(fx_station("ws1/st3"))
        }
        if fx.motion >= 2 {
          all.remove(1) |> ignore
        }
        Some(Json::array(all))
      }
    // a new device asking with this one's code (lock_prompts.mbt)
    "lockPrompts" =>
      Some(
        obj([
          (
            "pairing",
            if fx.pairing {
              [
                obj([
                  ("device", str("d-new")),
                  ("name", str("林")),
                  ("email", str("lin@example.com")),
                  ("kind", str("android")),
                  ("label", str("Pixel 9")),
                  ("code", str("482915")),
                  ("deviceText", str("Pixel 9")),
                  ("created_at", Json::number(0.0)),
                  ("untilText", str("14:05 前有效")),
                  ("workspaces", if fx.pairing_personal { [] } else { Json::array(pairing_places()) }),
                ] +
                (if fx.lock_case == "role" { [("roleText", str("「星火工作室」：批准后以管理员身份加入"))] } else { [] }) +
                (if fx.pairing_clarity {
                  [
                    ("deviceCode", str("K7M-4PX")),
                    ("build", str("0.1.10587")),
                    ("willSign", Json::boolean(true)),
                    (
                      "handoverVaults",
                      Json::array([
                        obj([
                          ("id", str("v1")),
                          ("name", str("林的库")),
                          ("scope", str("personal")),
                          ("items", Json::number(5.0)),
                          ("workspace", str("ws1")),
                          ("workspaceName", str("星火工作室")),
                        ]),
                        obj([
                          ("id", str("v-ws")),
                          ("name", str("Workspace 密钥库")),
                          ("scope", str("workspace")),
                          ("items", Json::number(3.0)),
                          ("workspace", str("ws1")),
                          ("workspaceName", str("星火工作室")),
                        ]),
                      ]),
                    ),
                  ]
                } else {
                  []
                })),
              ]
            } else {
              []
            },
          ),
          // a device of lin's waiting on this one for the key to 林的库 (vault_prompts.mbt)
          (
            "asks",
            if fx.key_ask {
              [
                obj([
                  ("workspace", str("ws1")),
                  ("workspaceName", str("星火工作室")),
                  ("vault", str("v1")),
                  ("vaultName", str("林的库")),
                  ("device", str("d-new")),
                  ("deviceText", str("Pixel 9")),
                  ("deviceCode", str("K7M-4PX")),
                  ("ownerName", str("林")),
                  ("ownerEmail", str("lin@example.com")),
                  ("isOwnDevice", Json::boolean(true)),
                  ("vaultScope", str("personal")),
                  ("vaultItems", Json::number(3.0)),
                  ("safeMode", Json::boolean(fx.key_ask_safe_mode)),
                  ("at", Json::number(0.0)),
                  ("atText", str("3 分钟前")),
                ]),
              ]
            } else {
              []
            },
          ),
        ]),
      )
    // (远程's Maple, online beside Willow: its display, its browser to make a tab of)
    "screens" if text(Some(Json::object(params)), "station") == "ws1/st2" && mode.has_prefix("place-remote") =>
      Some(
        obj([
          (
            "screens",
            [
              obj([("id", str("desktop")), ("kind", str("desktop")), ("title", str("Maple 的屏幕")), ("width", Json::number(2560.0)), ("height", Json::number(1440.0)), ("line", str("2560 × 1440 · 无人在看")), ("link", str(""))]),
            ] |> fx_remote_listed("ws1/st2"),
          ),
          ("browser", Json::boolean(true)),
          ("outdated", Json::boolean(false)),
          ("control", Json::boolean(true)),
          ("known", Json::boolean(true)),
        ]),
      )
    // (Willow's: Maple is away, none of its own known)
    "screens" if text(Some(Json::object(params)), "station") == "ws1/st2" =>
      Some(obj([("screens", Json::array([])), ("outdated", Json::boolean(false)), ("control", Json::boolean(false)), ("known", Json::boolean(true))]))
    "screens" => {
      let m = if mode.has_suffix("-dark") { mode.unsafe_substring(start=0, end=mode.length() - 5) } else { mode }
      if m == "settings-station-pages" || m == "screen-pages" || m == "screen-user-pages" || m == "screen-user-tabs" {
        Some(
          obj([
            (
              "screens",
              [
                obj([("id", str("desktop")), ("kind", str("desktop")), ("title", str("Willow 的屏幕")), ("width", Json::number(3024.0)), ("height", Json::number(1964.0)), ("line", str("3024 × 1964 · 无人在看")), ("link", str(""))]),
                obj([("id", str("browser:u_mail")), ("kind", str("browser")), ("userTab", Json::boolean(true)), ("closable", Json::boolean(true)), ("openUrl", Json::boolean(true)), ("site", str("mail.proton.me")), ("title", str("收件箱 - Proton Mail")), ("width", Json::number(1280.0)), ("height", Json::number(800.0)), ("line", str("mail.proton.me")), ("link", str(""))]),
                obj([("id", str("browser:u_gh")), ("kind", str("browser")), ("userTab", Json::boolean(true)), ("sleeping", Json::boolean(true)), ("closable", Json::boolean(true)), ("openUrl", Json::boolean(true)), ("site", str("github.com")), ("title", str("GitHub")), ("width", Json::number(0.0)), ("height", Json::number(0.0)), ("line", str("github.com")), ("link", str(""))]),
                obj([("id", str("browser:tab-1")), ("kind", str("browser")), ("closable", Json::boolean(true)), ("openUrl", Json::boolean(true)), ("title", str("Sign in · Anthropic")), ("width", Json::number(1280.0)), ("height", Json::number(720.0)), ("line", str("浏览器标签页 · 1280 × 720")), ("link", str(""))]),
              ],
            ),
            ("browser", Json::boolean(true)),
            ("outdated", Json::boolean(false)),
            ("control", Json::boolean(true)),
            ("known", Json::boolean(true)),
          ]),
        )
      } else if m.has_prefix("place-remote") {
        // (远程: Willow's display, an iOS simulator, a tab an agent drives and one of its own)
        Some(
          obj([
            (
              "screens",
              [
                obj([("id", str("desktop")), ("kind", str("desktop")), ("title", str("Willow 的屏幕")), ("width", Json::number(3024.0)), ("height", Json::number(1964.0)), ("line", str("3024 × 1964 · 无人在看")), ("link", str(""))]),
                obj([("id", str("sim:iphone")), ("kind", str("simulator")), ("title", str("iPhone 17 Pro")), ("width", Json::number(1206.0)), ("height", Json::number(2622.0)), ("line", str("iOS 26 · 1206 × 2622")), ("link", str(""))]),
                obj([("id", str("browser:T1")), ("kind", str("browser")), ("agent", Json::boolean(true)), ("closable", Json::boolean(true)), ("site", str("localhost:5173")), ("title", str("发布清单 - localhost:5173")), ("width", Json::number(1280.0)), ("height", Json::number(800.0)), ("line", str("浏览器标签页 · 1280 × 800")), ("link", str(""))]),
                obj([("id", str("browser:u_mail")), ("kind", str("browser")), ("userTab", Json::boolean(true)), ("closable", Json::boolean(true)), ("openUrl", Json::boolean(true)), ("site", str("mail.proton.me")), ("title", str("收件箱 - Proton Mail")), ("width", Json::number(1280.0)), ("height", Json::number(800.0)), ("line", str("mail.proton.me")), ("link", str(""))]),
              ] |> fx_remote_listed("ws1/st1"),
            ),
            ("browser", Json::boolean(true)),
            ("outdated", Json::boolean(false)),
            ("control", Json::boolean(true)),
            ("known", Json::boolean(true)),
          ]),
        )
      } else {
        Some(
          obj([
            (
              "screens",
              [
                obj([("id", str("desktop")), ("kind", str("desktop")), ("title", str("Willow 的屏幕")), ("width", Json::number(3024.0)), ("height", Json::number(1964.0)), ("line", str("3024 × 1964 · 无人在看")), ("link", str(""))]),
                obj([("id", str("browser:t1")), ("kind", str("browser")), ("title", str("发布清单 - 文档")), ("width", Json::number(1280.0)), ("height", Json::number(800.0)), ("line", str("浏览器标签页 · 1280 × 800")), ("link", str(""))]),
              ],
            ),
            ("outdated", Json::boolean(false)),
            ("control", Json::boolean(true)),
            ("known", Json::boolean(true)),
          ]),
        )
      }
    }
    // what still.fail uses of Willow's machine (the `resources` view): a chat's agent and the station
    "resources" => Some(fx_resources())
    "adbShare" => Some(fx_adb_share())
    "joinable" =>
      Some(
        obj([
          ("offered", Json::boolean(true)),
          ("loading", Json::boolean(false)),
          (
            "items",
            [
              obj([("station", str("ws2/st9")), ("id", str("st9")), ("name", str("家里的 mini")), ("icon", str("glyph:mini:green")), ("workspace", str("ws2")), ("workspaceName", str("个人")), ("online", Json::boolean(true)), ("rig", Json::boolean(false)), ("canFull", Json::boolean(true)), ("line", str("个人 · 在线"))]),
              obj([("station", str("ws2/r1")), ("id", str("r1")), ("name", str("build-box")), ("workspace", str("ws2")), ("workspaceName", str("个人")), ("online", Json::boolean(true)), ("rig", Json::boolean(true)), ("canFull", Json::boolean(false)), ("line", str("个人 · 只执行任务 · 在线"))]),
              obj([("station", str("ws3/st7")), ("id", str("st7")), ("name", str("实验机")), ("workspace", str("ws3")), ("workspaceName", str("实验室")), ("online", Json::boolean(false)), ("rig", Json::boolean(false)), ("canFull", Json::boolean(true)), ("line", str("所属 workspace「实验室」已开启安全模式，请先在当前 workspace 开启安全模式后再添加")), ("needsLock", Json::boolean(true))]),
            ],
          ),
        ]),
      )
    "memberships" =>
      Some(
        obj([
          ("manages", Json::boolean(true)),
          ("loading", Json::boolean(false)),
          ("canJoin", Json::boolean(true)),
          (
            "workspaces",
            [
              obj([("id", str("ws1")), ("workspace", str("ws1")), ("home", Json::boolean(true)), ("name", str("星火工作室")), ("mode", str("full")), ("line", str("主 workspace"))]),
              obj([("id", str("ws2")), ("workspace", str("ws2")), ("home", Json::boolean(false)), ("name", str("个人")), ("mode", str("tasks")), ("line", str("加入的 workspace · 只执行任务"))]),
            ],
          ),
        ]),
      )
    "profileFlow" if fx_colab_login.val => Some(fx_profile_flow_colab_login())
    "profileFlow" if mode == "settings-new-profile-google-colab-ways" => Some(fx_profile_flow_google_colab_ways())
    "profileFlow" if mode == "settings-new-profile-google-vertex-ways" => Some(fx_profile_flow_google_vertex_ways())
    "profileFlow" if mode == "settings-new-profile-google-vertex-key" => Some(fx_profile_flow_google_vertex_key())
    "profileFlow" if fx_google.val != "" => Some(fx_profile_flow_google(fx_google.val))
    "profileFlow" if fx.new_login => Some(fx_profile_flow_plan())
    "profileFlow" if fx.new_key => Some(fx_profile_flow_key())
    "profileFlow" => Some(fx_profile_flow(hermes=mode == "settings-new-profile-hermes", colab=mode == "settings-new-profile-colab"))
    "pick" if text(Some(Json::object(params)), "of").has_prefix("session:") => Some(fx_session_pick())
    "connectFlow" if fx_connect_step.val == "commaBind" => Some(fx_comma_flow())
    "connectFlow" if fx_connect_step.val == "platformGroup" => Some(fx_group_flow("platform", mode))
    "connectFlow" if fx_connect_step.val == "groupBind" || fx_connect_step.val == "groupForm" || fx_connect_step.val == "groupDone" =>
      Some(fx_group_flow(fx_connect_step.val, mode))
    "connectFlow" if fx_connect_step.val != "team" && fx_connect_step.val != "app" =>
      Some(fx_feishu_flow(fx_connect_step.val))
    "connectFlow" =>
      Some(
        obj([
          ("step", str(fx_connect_step.val)),
          ("title", str(if fx_connect_step.val == "app" { "Slack 应用" } else { "Slack 工作区" })),
          ("back", str(if fx_connect_step.val == "app" { "team" } else { "close" })),
          ("number", Json::number(if fx_connect_step.val == "app" { 2.0 } else { 1.0 })),
          ("total", Json::number(4.0)),
          ("mobile", Json::boolean(true)),
          ("adding", Json::boolean(false)),
          (
            "settings",
            obj([
              ("name", str("still.fail")),
              ("description", str("Coding agent in your threads (still.fail)")),
              ("backgroundColor", str("#F3E3D3")),
            ]),
          ),
          ("config", str("")),
          ("configReady", Json::boolean(false)),
          ("mode", str("multi-session")),
          ("requireMention", Json::boolean(true)),
          ("gettingToken", Json::boolean(false)),
          ("noProfile", Json::boolean(false)),
          ("canMake", Json::boolean(false)),
          ("canCreate", Json::boolean(false)),
          (
            "teams",
            [
              obj([("teamId", str("T1")), ("name", str("星火")), ("owner", obj([("user", str("林")), ("teamDomain", str("xinghuo"))]))]),
              obj([("teamId", str("T2")), ("name", str("实验室")), ("owner", obj([("user", str("林"))]))]),
            ],
          ),
          ("chosen", obj([("teamId", str("T1")), ("name", str("星火"))])),
          ("modeWords", fx_mode_words(fx_connect_step.val.has_prefix("feishu"))),
          ("sections", fx_sections()),
        ]),
      )
    "slackApp" =>
      Some(
        obj([
          ("state", str("ok")),
          ("appId", str("A1")),
          ("links", obj([("settings", str("https://api.slack.com/apps/A1")), ("install", str("")), ("appToken", str("")), ("oauth", str(""))])),
          (
            "settings",
            obj([
              ("name", str("星火助手")),
              ("displayName", str("星火助手")),
              ("description", str("帮团队整理发布和构建")),
              ("longDescription", str("")),
              ("backgroundColor", str("#F3E3D3")),
              ("groups", obj([("base", Json::boolean(true)), ("public", Json::boolean(true)), ("dm", Json::boolean(true)), ("files", Json::boolean(true))])),
            ]),
          ),
          // its permissions as the core says them (present.ts slackSections)
          ("sections", fx_sections()),
        ]),
      )
    "vaultUses" =>
      Some(
        obj([
          (
            "uses",
            if mode == "settings-vault-item-cross" {
              [
                obj([("at", stamp_of("10 分钟前")), ("session", str("s-c2")), ("station", str("st2")), ("workspace", str("ws-team")), ("workspaceName", str("产品研发组")), ("chatTitle", str("排查生产环境发布失败")), ("mode", str("proxy")), ("hosts", ["api.github.com"]), ("command", str("gh run view 9412")), ("howText", str("gh run view 9412 · 代理"))]),
                obj([("at", stamp_of("昨天")), ("session", str("s-c1")), ("station", str("st1")), ("chatTitle", str("整理发布清单")), ("mode", str("proxy")), ("hosts", ["api.github.com"]), ("command", str("git push origin main")), ("howText", str("git push origin main · 代理"))]),
                obj([("at", stamp_of("3 天前")), ("session", str("s-cross-2")), ("station", str("st3")), ("workspace", str("ws-ops")), ("workspaceName", str("运维值班")), ("chatTitle", str("轮换线上证书")), ("mode", str("proxy")), ("hosts", []), ("denied", Json::boolean(true)), ("howText", str("代理"))]),
              ]
            } else {
              [
                obj([("at", stamp_of("昨天")), ("session", str("s-c1")), ("station", str("st1")), ("chatTitle", str("整理发布清单")), ("mode", str("proxy")), ("hosts", ["api.github.com"]), ("command", str("git push origin main")), ("howText", str("git push origin main · 代理"))]),
                obj([("at", stamp_of("3 天前")), ("session", str("s-c4")), ("station", str("st1")), ("chatTitle", str("给设置页加一个深色模式开关")), ("mode", str("proxy")), ("hosts", []), ("denied", Json::boolean(true)), ("howText", str("代理"))]),
              ]
            },
          ),
        ]),
      )
    "decisionForm" =>
      Some(obj([("enabled", Json::boolean(true)), ("model", str("gpt-6-mini")), ("dirty", Json::boolean(false)), ("pending", Json::boolean(false))]))
    "policyForm" =>
      Some(
        obj([
          ("policy", str("做完、没有待办的对话归档；还在等人回复或有后续计划的留下。")),
          // the station's options, each its draft's key its id
          (
            "options",
            [
              obj([("key", str("o1")), ("id", str("o1")), ("name", str("已完成")), ("rubric", str("任务做完，没有后续")), ("archive", Json::boolean(true))]),
              obj([("key", str("o2")), ("id", str("o2")), ("name", str("被放弃")), ("rubric", str("明确不再继续")), ("archive", Json::boolean(true))]),
              obj([("key", str("o3")), ("id", str("o3")), ("name", str("等回复")), ("rubric", str("在等某人的答复")), ("archive", Json::boolean(false))]),
            ],
          ),
          ("dirty", Json::boolean(false)),
          ("pending", Json::boolean(false)),
        ]),
      )
    // what the settings say of the workspace (the core's views/settings.ts): Willow's completion rule on
    "settings" =>
      Some(
        obj([
          ("decisionsOn", Json::number(1.0)),
          ("decisionsText", str("1 台 station 已启用")),
          // (Willow reviews, Maple is offline: nothing to say of the hint)
          ("hintNoReview", Json::boolean(false)),
          ("hintReviewText", str("")),
        ]),
      )
    // (as the core answers it: every tab, the one asked (`part`, the first where none or another is said) with its
    // days, its first `limit` of them; two changes, none more)
    "changelog" => {
      let asked = match params.get("part") {
        Some(String("station")) => "station"
        _ => "app"
      }
      let days : Array[Json] = [
        obj([
          ("day", Json::number(20380.0)),
          ("label", str("10 月 19 日")),
          (
            "entries",
            [
              obj([("version", Json::number(2.0)), ("versionName", str("0.1.1300")), ("lines", [obj([("kind", str("new")), ("label", str("新增")), ("text", str("设置里可以添加 station 和 Profile"))])]), ("has", Json::boolean(false)), ("note", str("更新后可用"))]),
              obj([("version", Json::number(1.0)), ("versionName", str("0.1.1288")), ("lines", [obj([("kind", str("fix")), ("label", str("修复")), ("text", str("对话列表偶尔把同一行显示两次，滑到底再滑回来也不会消失"))])]), ("has", Json::boolean(true)), ("note", str(""))]),
            ],
          ),
        ]),
      ]
      Some(
        obj([
          ("build", Json::number(1300.0)),
          (
            "tabs",
            [
              obj([("part", str("app")), ("label", str("此 app")), ("days", if asked == "app" { Json::array(days) } else { [] })]),
              obj([("part", str("station")), ("label", str("Station")), ("days", [])]),
            ],
          ),
        ]),
      )
    }
    "agentEnvForm" =>
      Some(
        obj([
          ("text", str("HTTPS_PROXY=http://127.0.0.1:7890\nNO_PROXY=localhost,.internal\nBAD LINE")),
          (
            "lines",
            [
              obj([("parts", []), ("error", Json::boolean(false))]),
              obj([("parts", []), ("error", Json::boolean(false))]),
              obj([("parts", []), ("error", Json::boolean(true)), ("problem", str("缺少「=」"))]),
            ],
          ),
          ("errors", Json::number(1.0)),
          ("dirty", Json::boolean(true)),
          ("pending", Json::boolean(false)),
        ]),
      )
    "connects" =>
      Some(
        fx_moved(obj([
          ("me", obj([("email", str("lin@example.com"))])),
          (
            "items",
            [
              obj([
                ("station", str("ws1/st1")),
                ("stationName", str("Willow")),
                (
                  "connect",
                  match mode {
                    "settings-connect-comma" => fx_connect_as("comma")
                    "settings-connect-feishu" => fx_connect_as("feishu")
                    "settings-connect-group" => fx_connect_as("group")
                    _ if fx_group_made.val => fx_connect_as("group")
                    _ => fx_connect("k1", "星火助手", "online", "在线", "multi-session")
                  },
                ),
                ("runtimeChanges", Json::boolean(mode == "settings-connect-switch")),
                (
                  "sessions",
                  if mode == "settings-connect-comma" || mode == "settings-connect-feishu" || mode == "settings-connect-group" || fx_group_made.val {
                    []
                  } else {
                    [
                      obj([("key", str("s-c7")), ("titleText", str("Slack 里问的报销流程")), ("statusText", str("昨天"))]),
                      obj([("key", str("s-c2")), ("titleText", str("首页的列表改成按天分组")), ("statusText", str("8 分钟前"))]),
                    ]
                  },
                ),
                ("candidates", []),
                ("running", Json::number(0.0)),
                ("changes", fx_mode_changes()),
              ]),
              obj([
                ("station", str("ws1/st1")),
                ("stationName", str("Willow")),
                ("connect", fx_connect("k2", "值班机器人", "error", "连接失败", "single-session")),
                ("sessions", []),
                ("candidates", []),
                ("running", Json::number(0.0)),
                ("changes", Json::array([])),
              ]),
            ],
          ),
          ("wait", obj([("reading", Json::boolean(false)), ("failing", []), ("empty", Json::boolean(false))])),
        ]), obj([
          ("station", str("ws1/st1")),
          ("stationName", str("Willow")),
          ("connect", fx_connect("k9", "发布助手", "online", "在线", "multi-session")),
          ("sessions", []),
          ("candidates", []),
          ("running", Json::number(0.0)),
          ("changes", Json::array([])),
        ]), fn(x) { text(field(Some(x), "connect"), "id") == "k2" }),
      )
    "lock" =>
      Some(
        obj([
          ("available", Json::boolean(true)),
          // (a vault kept by its person's own devices alone is a workspace not in security mode)
          ("locked", Json::boolean(fx.vault_own == "" && fx.lock_case != "root-off" && fx.lock_case != "again")),
          ("notice", Json::boolean(false)),
          ("role", str("owner")),
          ("manages", Json::boolean(true)),
          ("owner", Json::boolean(true)),
          ("canSign", Json::boolean(true)),
          ("signs", Json::boolean(fx.lock_case != "confirm")),
          ("signers", Json::number(if fx.lock_case == "confirm" { 4.0 } else { 5.0 })),
          ("protected", Json::number(1.0)),
          ("attention", Json::number(0.0)),
          (
            "members",
            [
              obj([
                ("sub", str("u1")),
                ("email", str("lin@example.com")),
                ("name", str("林")),
                ("role", str("owner")),
                ("you", Json::boolean(true)),
                ("nameText", str("林")),
                ("roleText", str("Owner")),
                ("devicesText", str(if fx.lock_case == "confirm" { "3 台受信任设备 · 1 台设备 · 1 个网页版" } else { "4 台受信任设备 · 1 个网页版" })),
                (
                  "groups",
                  [
                    obj([
                      ("appText", str("still.fail Android")),
                      ("devices", [
                        obj([("id", str("d1")), ("kind", str("app")), ("label", str("still.fail Android · Pixel 9")), ("signs", Json::boolean(fx.lock_case != "confirm")), ("older", Json::boolean(false)), ("mine", Json::boolean(true)), ("renewSoon", Json::boolean(false)), ("recent", Json::boolean(false)), ("lastSeen", Json::number(1760000000.0)), ("removable", Json::boolean(false)), ("nameText", str("Pixel 9")), ("fullText", str("Pixel 9 · still.fail Android")), ("metaText", str(if fx.lock_case == "confirm" { "此设备" } else { "此设备 · 受信任" })), ("machine", str("phone")), ("appText", str("still.fail Android")), ("noteText", str(if fx.lock_case == "confirm" { "still.fail Android" } else { "still.fail Android · 受信任" }))]),
                      ]),
                    ]),
                    obj([
                      ("appText", str("still.fail 桌面版")),
                      ("devices", [
                        obj([("id", str("d4")), ("kind", str("app")), ("label", str("still.fail 桌面版 · 林的 MacBook Pro")), ("signs", Json::boolean(true)), ("older", Json::boolean(false)), ("mine", Json::boolean(false)), ("renewSoon", Json::boolean(false)), ("recent", Json::boolean(false)), ("lastSeen", Json::number(1759990000.0)), ("removable", Json::boolean(fx.lock_case != "confirm")), ("nameText", str("林的 MacBook Pro")), ("fullText", str("林的 MacBook Pro · still.fail 桌面版")), ("metaText", str("一天内使用过 · 受信任")), ("machine", str("computer")), ("appText", str("still.fail 桌面版")), ("noteText", str("still.fail 桌面版 · 一天内使用过 · 受信任"))]),
                        obj([("id", str("d6")), ("kind", str("app")), ("label", str("still.fail 桌面版 · 示例工作站")), ("signs", Json::boolean(true)), ("older", Json::boolean(false)), ("mine", Json::boolean(false)), ("renewSoon", Json::boolean(false)), ("recent", Json::boolean(false)), ("lastSeen", Json::number(1759700000.0)), ("removable", Json::boolean(fx.lock_case != "confirm")), ("nameText", str("示例工作站")), ("fullText", str("示例工作站 · still.fail 桌面版")), ("metaText", str("3 天前使用过 · 受信任")), ("machine", str("computer")), ("appText", str("still.fail 桌面版")), ("noteText", str("still.fail 桌面版 · 3 天前使用过 · 受信任"))]),
                      ]),
                    ]),
                    obj([
                      ("appText", str("still.fail 网页版")),
                      ("devices", [
                        obj([("id", str("d2")), ("kind", str("web")), ("label", str("still.fail 网页版 · Chrome · macOS")), ("signs", Json::boolean(false)), ("older", Json::boolean(false)), ("mine", Json::boolean(false)), ("daysLeft", Json::number(4.0)), ("renewSoon", Json::boolean(true)), ("recent", Json::boolean(false)), ("lastSeen", Json::number(1759800000.0)), ("removable", Json::boolean(fx.lock_case != "confirm")), ("nameText", str("Chrome · macOS")), ("fullText", str("Chrome · macOS · still.fail 网页版")), ("metaText", str("2 天前使用过 · 剩余 4 天")), ("appText", str("still.fail 网页版")), ("noteText", str("still.fail 网页版 · 2 天前使用过")), ("leftText", str("剩余 4 天"))]),
                      ]),
                    ]),
                    obj([
                      ("appText", str("其他")),
                      ("devices", [
                        obj([("id", str("d5")), ("kind", str("app")), ("label", str("")), ("signs", Json::boolean(true)), ("older", Json::boolean(false)), ("mine", Json::boolean(false)), ("renewSoon", Json::boolean(false)), ("recent", Json::boolean(false)), ("removable", Json::boolean(fx.lock_case != "confirm")), ("nameText", str("客户端")), ("fullText", str("客户端")), ("metaText", str("超过一个月未使用 · 受信任")), ("machine", str("computer")), ("noteText", str("超过一个月未使用 · 受信任"))]),
                      ]),
                    ]),
                  ],
                ),
              ]),
              obj([
                ("sub", str("u2")),
                ("email", str("ana@example.com")),
                ("name", str("Ana")),
                ("role", str("admin")),
                ("you", Json::boolean(false)),
                ("nameText", str("Ana")),
                ("roleText", str("管理员")),
                ("devicesText", str("1 台受信任设备")),
                (
                  "groups",
                  [
                    obj([
                      ("appText", str("still.fail 桌面版")),
                      ("devices", [
                        obj([("id", str("d3")), ("kind", str("app")), ("label", str("still.fail 桌面版 · Ana 的 MacBook Air")), ("signs", Json::boolean(true)), ("older", Json::boolean(false)), ("mine", Json::boolean(false)), ("renewSoon", Json::boolean(false)), ("recent", Json::boolean(false)), ("lastSeen", Json::number(1759570000.0)), ("removable", Json::boolean(false)), ("nameText", str("Ana 的 MacBook Air")), ("fullText", str("Ana 的 MacBook Air · still.fail 桌面版")), ("metaText", str("5 天前使用过 · 受信任")), ("machine", str("computer")), ("appText", str("still.fail 桌面版")), ("noteText", str("still.fail 桌面版 · 5 天前使用过 · 受信任"))]),
                      ]),
                    ]),
                  ],
                ),
              ]),
            ],
          ),
          (
            "stations",
            [
              obj([("id", str("st1")), ("name", str("Willow")), ("online", Json::boolean(true)), ("protected", Json::boolean(true)), ("icon", str("glyph:desktop"))]),
              obj([("id", str("st2")), ("name", str("Maple")), ("online", Json::boolean(false)), ("protected", Json::boolean(false))]),
            ],
          ),
          ("renew", []),
        ] +
        fx_pending_fields() +
        fx_upgrade_fields() +
        fx_lock_case_fields()),
      )
    "vaults" =>
      Some(
        obj([
          ("available", Json::boolean(true)),
          // (no safe mode: the vault its person's own all the same, `locked` saying only safe mode's off)
          ("locked", Json::boolean(fx.vault_own == "")),
          (
            "canSign",
            Json::boolean(fx.vault_own != "outside" && !["confirm", "syncing", "waiting", "waiting-was", "replaced", "replaced-was"].contains(fx.lock_case)),
          ),
          ("setUp", Json::boolean(!fx.vault_off)),
          ("canCreateWorkspace", Json::boolean(fx.vault_workspace == "create")),
          ("plainLeft", Json::number(fx.plain_left.to_double())),
          (
            "vaults",
            // (none where it is on nowhere: settings-vault-off in safe mode too)
            if fx.vault_own == "off" || fx.vault_own == "outside" || (fx.vault_off && !fx.vault_elsewhere) {
              []
            } else if fx.vault_workspace == "has" {
              [fx_vault_row(), fx_workspace_vault_row()]
            } else {
              [fx_vault_row()]
            },
          ),
          (
            "requests",
            if fx.vault_own == "off" || fx.vault_own == "outside" {
              []
            } else {
              let reqs = [
                obj([
                  ("id", str("r1")),
                  ("vault", str("v1")),
                  ("vaultName", str("林的库")),
                  ("item", str("it1")),
                  ("itemName", str("GitHub token")),
                  ("session", str("s-c1")),
                  ("station", str("st1")),
                  ("chat", str("c1")),
                  ("mode", str("proxy")),
                  ("reason", str("要把发布清单推到仓库")),
                  ("command", str("git push origin main")),
                  ("hosts", ["api.github.com"]),
                  ("howText", str("代理 · 限 api.github.com")),
                  ("at", Json::number(0.0)),
                ]),
              ]
              if fx.vault_workspace == "has" {
                reqs.push(
                  obj([
                    ("id", str("r-ws-save")),
                    ("vault", str("v1")),
                    ("vaultName", str("林的库")),
                    ("item", str("")),
                    ("itemName", str("Sentry DSN")),
                    ("session", str("s-c1")),
                    ("station", str("st1")),
                    ("chat", str("c1")),
                    ("mode", str("env")),
                    ("reason", str("存入错误上报配置")),
                    ("howText", str("环境变量 · SENTRY_DSN")),
                    ("save", obj([("kind", str("token"))])),
                    ("at", Json::number(0.0)),
                  ]),
                )
              }
              Json::array(reqs)
            },
          ),
          ("refused", []),
          // (the core's words of it: its requests wait; none where no vault of theirs is kept)
          ("statusText", str(if fx.vault_own == "off" || fx.vault_own == "outside" { "" } else if fx.vault_workspace == "has" { "2 个待批准" } else { "1 个待批准" })),
          ("statusBad", Json::boolean(!(fx.vault_own == "off" || fx.vault_own == "outside"))),
        ] +
        (if fx.this_device_code != "" { [("thisDeviceCode", str(fx.this_device_code))] } else { [] }) +
        (match fx.lock_case {
          // (not signing for a reason of its own: the core's words, and 验证 where a press ends it)
          "confirm" | "replaced-was" => [("stateText", str("此设备需完成一次验证后才能使用密钥库")), ("confirmText", str("验证"))]
          "syncing" | "waiting-was" => [("stateText", str("正在同步安全模式的成员名单，同步完成后即可使用"))]
          _ => []
        })),
      )
    "vaultItems" =>
      Some(
        fx_moved(obj([
          ("vault", str("v1")),
          ("name", str("林的库")),
          ("open", Json::boolean(false)),
          (
            "items",
            [
              obj([("id", str("it1")), ("version", Json::number(1.0)), ("at", Json::number(0.0)), ("name", str("GitHub token")), ("kind", str("token")), ("listed", Json::boolean(true)), ("modes", ["proxy"]), ("hosts", ["api.github.com"]), ("lastUse", obj([("at", stamp_of("昨天")), ("session", str("s-c1")), ("chatTitle", str("修 CI")), ("mode", str("proxy")), ("hosts", [])])), ("kindText", str("Token")), ("shut", [obj([("key", str("value")), ("label", str("值")), ("value", str("••••••••••••••••••••")), ("secret", Json::boolean(true)), ("mono", Json::boolean(true))])]), ("agentText", str("允许 agent 申请 · 代理 · api.github.com")), ("lineText", str("代理 · api.github.com · 昨天在「修 CI」用过")), ("howText", str("代理 · 限 api.github.com")), ("lastsText", str("跟随默认 · 直到对话归档"))]),
              obj([("id", str("it2")), ("version", Json::number(1.0)), ("at", Json::number(0.0)), ("name", str("部署机")), ("kind", str("ssh_key")), ("listed", Json::boolean(true)), ("modes", ["ssh"]), ("hosts", []), ("kindText", str("SSH 密钥")), ("shut", [obj([("key", str("private_key")), ("label", str("私钥")), ("value", str("••••••••••••••••••••")), ("secret", Json::boolean(true)), ("mono", Json::boolean(true))])]), ("agentText", str("允许 agent 申请 · ssh-agent")), ("lineText", str("ssh-agent")), ("howText", str("ssh-agent")), ("lastsText", str("跟随默认 · 直到对话归档"))]),
              obj([("id", str("it3")), ("version", Json::number(1.0)), ("at", Json::number(0.0)), ("kind", str("login")), ("listed", Json::boolean(false)), ("modes", []), ("hosts", []), ("kindText", str("登录")), ("shut", [obj([("key", str("username")), ("label", str("用户名")), ("value", str("••••••••••")), ("secret", Json::boolean(false)), ("mono", Json::boolean(false))]), obj([("key", str("password")), ("label", str("密码")), ("value", str("••••••••••••")), ("secret", Json::boolean(true)), ("mono", Json::boolean(true))])]), ("agentText", str("仅自己可见")), ("lineText", str("仅自己可见")), ("howText", str("")), ("lastsText", str("跟随默认 · 直到对话归档"))]),
            ],
          ),
        ]), obj([("id", str("it4")), ("version", Json::number(1.0)), ("at", Json::number(0.0)), ("name", str("OpenAI key")), ("kind", str("token")), ("listed", Json::boolean(true)), ("modes", ["proxy"]), ("hosts", ["api.openai.com"]), ("kindText", str("Token")), ("shut", []), ("agentText", str("允许 agent 申请 · 代理 · api.openai.com")), ("lineText", str("代理 · api.openai.com")), ("howText", str("代理 · 限 api.openai.com")), ("lastsText", str("跟随默认 · 直到对话归档"))]), fn(x) { text(Some(x), "id") == "it1" }),
      )
    "profiles" => {
      let list = fx_profiles().map(fn(p) {
        // how it is, as the core says it (views/profiles.ts stateOf): its trouble, in its check's words where the check
        // did not pass
        let pv = Some(p)
        let look = field(pv, "trouble") is Some(Object(_))
        let green = text(pv, "checkTone") == "green"
        let state = if look && green {
          obj([("text", str(text(field(pv, "trouble"), "title"))), ("tone", str("amber"))])
        } else if green {
          Json::null()
        } else {
          obj([("text", str(text(pv, "checkText"))), ("tone", str(text(pv, "checkTone")))])
        }
        obj([
          ("key", str("ws1/st1/" + text(Some(p), "id"))),
          ("group", str(text(Some(p), "group"))),
          ("groupTitle", str(text(Some(p), "groupTitle"))),
          ("station", str("ws1/st1")),
          // (as the list is sent it: client/core-ts schema.ts WorkspaceProfile, ListedProfile)
          ("profile", listed_profile_said(p)),
          ("title", str(if text(Some(p), "email") == "" { text(Some(p), "name") } else { text(Some(p), "email") })),
          ("usable", Json::boolean(if has(pv, "usable") { flag(pv, "usable") } else { true })),
          ("state", state),
          ("look", Json::boolean(look)),
          ("where", str(if fx.trouble == "quota-login" && text(pv, "id") == "cx" { "Willow" } else { "Willow 可用" })),
          // (what the list's 多选 reads of it, as views/profiles.ts says it: Willow's own, up, sharing)
          ("shared", Json::boolean(field(pv, "share") is Some(Object(_)))),
          ("shareAuto", Json::boolean(flag(field(pv, "share"), "allowAuto"))),
          ("canBatchShare", Json::boolean(fx_batch_why(pv) == "")),
          ("batchShareAllowAuto", Json::boolean(true)),
          ..if fx_batch_why(pv) == "" { [] } else { [("batchShareWhy", str(fx_batch_why(pv)))] },
          (
            "stations",
            [
              obj([("id", str("st1")), ("name", str("Willow")), ("online", Json::boolean(true)), ("acceptAutoChats", Json::boolean(fx.accept_auto_chats))]),
              obj([("id", str("st2")), ("name", str("Maple")), ("online", Json::boolean(fx.mba_online)), ("acceptAutoChats", Json::boolean(true))]),
            ],
          ),
          (
            "members",
            if fx.profile_hosts && text(pv, "id") == "cc" {
              Json::array(
                fx_profile_hosts()
                .filter(fn(m) { !fx.profile_pending || text(Some(m), "stationId") != "st2" })
                .map(fn(m) { fields_dropped(m, ["stationName", "profileName", "checkText", "usedBy"]) }),
              )
            } else { [
              obj([("station", str("ws1/st1")), ("stationId", str("st1")), ("online", Json::boolean(true)), ("profileId", str(text(Some(p), "id"))), ("role", str("host")), ("about", str("")), ("usable", Json::boolean(true)), ("checkTone", str("green"))]),
            ] },
          ),
          (
            "places",
            if fx.profile_hosts && text(pv, "id") == "cc" {
              Json::array(fx_profile_places().map(fn(pl) { fields_dropped(pl, ["stationId"]) }))
            } else {
              [obj([("station", str("ws1/st1")), ("stationName", str("Willow")), ("profileId", str(text(pv, "id"))), ("online", Json::boolean(true)), ("usable", Json::boolean(true)), ("sourceName", str("")), ("state", Json::null())])]
            },
          ),
        ])
      })
      let attention = list.filter(fn(e) { flag(Some(e), "look") }).length()
      Some(
        obj([
          ("items", Json::array(list)),
          ("attention", Json::number(attention.to_double())),
          ("wait", obj([("reading", Json::boolean(false)), ("failing", []), ("empty", Json::boolean(false))])),
          // (the workspace's owner's: its `workspace` says so)
          ("manages", Json::boolean(true)),
        ]),
      )
    }
    // (what the core makes of a workspace spread over three stations as real ones are: usage_real.mbt; split as asked,
    // the core's choice where none is, all of it where a part or a day is picked)
    "usage" if mode.has_prefix("settings-usage-real") =>
      usage_real(
        match params.get("days") {
          Some(Number(n, ..)) => n.to_int()
          _ => 7
        },
        match params.get("split") {
          Some(String(l)) => l
          _ => ""
        },
      )
    "usage" =>
      Some(
        fx_usage(
          match params.get("days") {
            Some(Number(n, ..)) => n.to_int()
            _ => 7
          },
          split=match params.get("split") {
            Some(String(l)) => l
            _ => "people"
          },
          only=match params.get("only") {
            Some(Object(o)) =>
              match o.get("key") {
                Some(String(k)) => k
                _ => ""
              }
            _ => ""
          },
          day=match params.get("day") {
            Some(String(d)) => d
            _ => ""
          },
          details_pending=mode == "settings-usage-details-pending",
        ),
      )
    "archive" =>
      Some(
        fx_archive(
          q=match params.get("q") {
            Some(String(q)) => q
            _ => ""
          },
        ),
      )
    "memory" => Some(fx_memory())
    // (settings-me-reading: where the account is signed in not read yet, its wait line shown)
    "loginSessions" if mode.has_prefix("settings-me-reading") => None
    "loginSessions" =>
      Some([
        obj([("id", str("l1")), ("name", str("Pixel 9 · still.fail")), ("current", Json::boolean(true)), ("time", obj([("created_at", stamp_of("3 天前")), ("expires_at", stamp_of("", until="27 天后"))]))]),
        obj([("id", str("l2")), ("name", str("Chrome · macOS")), ("current", Json::boolean(false)), ("time", obj([("created_at", stamp_of("2 周前")), ("expires_at", stamp_of("", until="16 天后"))]))]),
      ])
    "notify" => {
      // notifications off (slice 10's settings-notify-off)
      let on = !mode.has_prefix("settings-notify-off")
      Some(
        obj([
          ("on", Json::boolean(on)),
          ("asked", Json::boolean(true)),
          ("push", Json::boolean(false)),
          ("show", []),
          ("kinds", obj([("wait", Json::boolean(true)), ("failed", Json::boolean(true)), ("done", str("away")), ("message", Json::boolean(false)), ("billed", Json::boolean(false))])),
          ("preview", Json::boolean(true)),
          ("permission", str(if mode.has_prefix("settings-notify-denied") { "denied" } else { "granted" })),
          // (the account's two workspaces, 个人 turned off)
          ("muted", [str("ws2")]),
          (
            "workspaces",
            [
              obj([("id", str("ws1")), ("name", str("星火工作室")), ("on", Json::boolean(true))]),
              obj([("id", str("ws2")), ("name", str("个人")), ("on", Json::boolean(false))]),
            ],
          ),
        ]),
      )
    }
    "stationMove" => Some(fx_move_view(params))
    "doing" if fx_move.refused is Some(_) => Some(obj([("doing", Json::array(fx_move_doing()))]))
    "doing" if fx.lock_doing != "" =>
      Some(
        obj([
          (
            "doing",
            [
              obj([
                ("call", str(fx.lock_doing)),
                ("stage", str("running")),
                ("params", obj([("workspace", str(fx.lock_doing_ws))])),
              ]),
            ],
          ),
        ]),
      )
    "doing" if rigs_fixture_doing(mode) is Some(d) => Some(d)
    "doing" => Some(obj([("doing", if fx.protecting {
      [obj([("call", str("lock.joinStation")), ("stage", str("running")), ("params", obj([("workspace", str("ws1")), ("station", str("st2"))]))])]
    } else if fx.key_giving {
      [obj([("call", str("vault.addDevice")), ("stage", str("running")), ("params", obj([("workspace", str("ws1")), ("vault", str("v1")), ("device", str("d-new"))]))])]
    } else {
      []
    })]))
    "lockDraft" =>
      Some(
        obj([
          ("available", Json::boolean(true)),
          ("loading", Json::boolean(false)),
          ("canSign", Json::boolean(true)),
          ("owner", Json::boolean(true)),
          ("ready", Json::boolean(true)),
          (
            "members",
            [
              obj([("sub", str("u1")), ("email", str("lin@example.com")), ("name", str("林")), ("role", str("owner")), ("nameText", str("林")), ("roleText", str("Owner"))]),
              obj([("sub", str("u2")), ("email", str("ana@example.com")), ("name", str("Ana")), ("role", str("admin")), ("nameText", str("Ana")), ("roleText", str("管理员"))]),
            ],
          ),
          (
            "devices",
            [
              obj([("id", str("d1")), ("person", str("林")), ("kind", str("app")), ("label", str("这台手机")), ("older", Json::boolean(false)), ("current", Json::boolean(true)), ("on", Json::boolean(true)), ("fixed", Json::boolean(true)), ("nameText", str("林 · 此设备")), ("howText", str("客户端 · 受信任"))]),
              obj([("id", str("d3")), ("person", str("Ana")), ("kind", str("app")), ("label", str("MacBook")), ("older", Json::boolean(false)), ("current", Json::boolean(false)), ("on", Json::boolean(true)), ("fixed", Json::boolean(false)), ("nameText", str("Ana · MacBook")), ("howText", str("客户端"))]),
            ],
          ),
          (
            "stations",
            [
              obj([("id", str("st1")), ("name", str("Willow")), ("version", str("0.1.4600")), ("state", str("ok")), ("on", Json::boolean(true)), ("fixed", Json::boolean(false))]),
              obj([("id", str("st2")), ("name", str("Maple")), ("state", str("offline")), ("on", Json::boolean(false)), ("fixed", Json::boolean(true)), ("stateText", str("离线 · 上线后可在此保护"))]),
            ],
          ),
        ]),
      )
    _ => None
  }
}

///|
/// A made-up settings call (a station renamed, a chat restored, a station's memory read), None for one these do not
/// take.
pub fn fixture_call(name : String, params : Json) -> Result[Json, Json]? {
  let p = Some(params)
  // (a device waiting on its person's own lock: made their only trusted device, or the lock begun anew elsewhere said
  // theirs, as the core then says it: waiting_lock)
  if name == "lock.restartOwn" || name == "lock.forgetOwn" {
    fx.own_after = if name == "lock.restartOwn" { "rebound" } else { "asked" }
    fx_changed()
    return Some(Ok(Json::null()))
  }
  // (验证 on a device whose person's lock was begun anew elsewhere: refused, as the core did before it offered none)
  if name == "lock.confirmSigner" && fx.lock_case == "replaced-was" {
    return Some(Err(obj([("code", str("personal_outside")), ("message", str("此设备尚未获批：先在这台设备上发送批准请求，输入你的受信任设备上显示的安全码"))])))
  }
  match rigs_fixture_call(name, p) {
    Some(r) => return Some(r)
    None => ()
  }
  match devices_fixture_call(name, p) {
    Some(r) => return Some(r)
    None => ()
  }
  // (an account moved to Maple: asked with what the station needs, the one it is on, which, and where to)
  if name == "profile.move" {
    return Some(
      if text(p, "station") == "ws1/st1" && text(p, "id") != "" && text(p, "to") == "st2" && fx.mba_online {
        Ok(obj([]))
      } else {
        Err(obj([("code", str("invalid")), ("message", str("missing station, id or to"))]))
      },
    )
  }
  match retire_fixture_call(name, p) {
    Some(r) => return Some(r)
    None => ()
  }
  if name == "copies.history" {
    return Some(Ok(fixture_copies_history()))
  }
  match move_fixture_call(name, p) {
    Some(r) => return Some(r)
    None => ()
  }
  match name {
    "workspace.renameStation" => {
      // a name, or (the mark picker's) a mark
      match field(p, "icon") {
        Some(_) => fx.marks[text(p, "station")] = text(p, "icon")
        None => fx.names[text(p, "station")] = text(p, "name")
      }
      fx_changed()
      Some(Ok(obj([])))
    }
    "chat.archive" if field(p, "archived") is Some(False) => {
      fx.restored[text(p, "session")] = true
      fx_changed()
      Some(Ok(obj([])))
    }
    // still.fail's buddies a Slack app can wear (the core's own list, web/public/avatars/index.json: three of it)
    "buddies" =>
      Some(
        Ok(
          Json::array([
            obj([("id", str("backend")), ("label", str("后端接口")), ("bg", str("#B582EB"))]),
            obj([("id", str("mobile")), ("label", str("移动应用")), ("bg", str("#B9D84A"))]),
            obj([("id", str("documentation")), ("label", str("写文档")), ("bg", str("#F3CA43"))]),
          ]),
        ),
      )
    // 开启 with no safe mode (settings-vault-own-off): lin's own lock begun with this device on it, the vault made, the
    // recovery words to write down, what was plain from before moved in (views/vault.ts `setup`)
    "vault.setup" if fx.vault_own == "off" => {
      fx.vault_own = "on"
      fx.vault_off = false
      fx.plain_left = 0
      fx_changed()
      Some(Ok(obj([("words", str(fx_words().join(" "))), ("device", str("d1")), ("stations", ["st1"]), ("made", str("v1"))])))
    }
    // this device asking to be approved by another trusted device of lin's (settings-vault-own-outside): the code it
    // shows typed in here next; typed, approved, on lin's own lock (the vault 开启 here next)
    "adb.personalJoin" if fx.vault_own == "outside" => {
      fx_adb.val = "gate-code"
      fx_changed()
      Some(Ok(obj([])))
    }
    "adb.personalCode" if fx.vault_own == "outside" => {
      fx_adb.val = "lock-member"
      fx.vault_own = "off"
      fx.vault_off = true
      fx.plain_left = 0
      fx_changed()
      Some(Ok(Json::null()))
    }
    // lin's secrets from before security mode encrypted into their vault
    "vault.migrate" => {
      fx.plain_left = 0
      fx_changed()
      Some(Ok(obj([])))
    }
    // the device waiting for a key given it (the vault's key unsealed here), or its prompt put away: no longer shown
    "vault.addDevice" | "vault.hidePrompt" => {
      if name == "vault.addDevice" && text(p, "vault") == "v-ws" && text(p, "device") == "d-new" {
        fx.vault_ws_pending_done = true
      }
      fx.key_ask = false
      fx.key_ask_ended = if name == "vault.addDevice" { "give" } else { "hide" }
      fx_changed()
      Some(Ok(obj([("added", Json::number(1.0))])))
    }
    // this device asking for the keys it lacks: its other devices told
    "vault.ask" => Some(Ok(obj([("asked", Json::number(1.0))])))
    "vault.create" => {
      if text(p, "scope") == "workspace" {
        fx.vault_workspace = "has"
        fx_changed()
      }
      Some(Ok(obj([("id", str(if text(p, "scope") == "workspace" { "v-ws" } else { "v1" }))])))
    }
    "vault.setMembers" => {
      fx.vault_workspace_members.clear()
      fx.vault_workspace_members.append(strings(p, "members"))
      fx_changed()
      Some(Ok(obj([])))
    }
    "vault.putItem" => Some(Ok(obj([("id", str("it-new"))])))
    // the new device turned away, or its prompt closed: no longer shown
    "lockPrompt.deny" | "lockPrompt.hide" => {
      fx.pairing = false
      fx.pair_ended = if name == "lockPrompt.deny" { "deny" } else { "hide" }
      fx_changed()
      Some(Ok(obj([])))
    }
    // a skill shared with the workspace's other stations, or no longer
    "skill.share" => {
      fx.skills_shared[text(p, "name")] = flag(p, "on")
      fx_changed()
      Some(Ok(obj([])))
    }
    "cache.usage" =>
      Some(
        Ok(
          obj([
            (
              "chats",
              Json::array(([
                // a PDF opened, 5 minutes ago; a video, 12 of its 48 MB come
                obj([
                  ("station", str("ws1/st1")),
                  ("thread", Json::number(1.0)),
                  ("title", str("整理发布清单")),
                  ("sessions", ["s-c1"]),
                  ("bytes", Json::number(2400000.0)),
                  (
                    "files",
                    Json::array(
                      [
                        fx_kept_file("s-c1", "季度报告.pdf", 3355443.0, 3355443.0, -300000.0),
                        fx_kept_file("s-c1", "演示录屏.mp4", 50331648.0, 12582912.0, -7200000.0),
                      ].filter_map(fn(f) { f }),
                    ),
                  ),
                ]),
                obj([("station", str("ws1/st1")), ("thread", Json::number(4.0)), ("title", str("给设置页加一个深色模式开关")), ("sessions", ["s-c4"]), ("bytes", Json::number(860000.0))]),
                obj([("station", str("ws1/st2")), ("thread", Json::number(3.0)), ("title", str("夜里的构建又失败了")), ("sessions", ["s-c3"]), ("bytes", Json::number(41000.0))]),
                ] +
                fx_kept_many())
                |> fx_kept_most_first,
              ),
            ),
            ("drive", Json::number(fx.drive_kept)),
            // one of a chat no longer kept here, 3 days ago
            ("loose", Json::array([fx_kept_file("s-old", "旧日志.zip", 921600.0, 921600.0, -3.0 * 86400000.0, station="ws1/st2")].filter_map(fn(f) { f }))),
          ]),
        ),
      )
    // a failed pending change read, dropped (a waiting one stays)
    "lock.pendingDismiss" => {
      let id = text(p, "id")
      if fx_pending_rows().iter().any(fn(r) { text(Some(r), "id") == id && text(Some(r), "state") == "failed" }) {
        fx.pending.retain(fn(x) { x != id })
        fx_changed()
      }
      Some(Ok(Json::null()))
    }
    "drive.kept.clear" => {
      fx.drive_kept = 0.0
      fx_changed()
      Some(Ok(Json::null()))
    }
    "cache.file.clear" => {
      fx.kept_cleared.push(text(p, "name"))
      fx_changed()
      Some(Ok(Json::null()))
    }
    "machineSessions.list" => Some(Ok(obj([("sessions", [])])))
    "workspace.enroll" =>
      Some(
        Ok(
          obj([
            ("token", str("made-up")),
            ("install", str("curl -fsSL https://still.fail/install.sh | sh -s -- 4f7c2a9e1b")),
            ("installWindows", str("& ([scriptblock]::Create((irm https://still.fail/install.ps1))) 4f7c2a9e1b")),
            ("installDocker", str("docker run -d --restart unless-stopped -v stillfail:/home/stillfail -e STILLFAIL_ORIGIN=https://still.fail ghcr.io/afk-surf/stillfail-station 4f7c2a9e1b")),
            ("command", str("stillfail station enroll https://still.fail 4f7c2a9e1b")),
          ]),
        ),
      )
    "software.auto" => {
      fx.auto = flag(p, "on")
      fx_changed()
      Some(Ok(obj([])))
    }
    "network.setCongestion" => {
      fx.congestion = text(p, "congestion")
      Some(Ok(obj([])))
    }
    "station.restart" => Some(Ok(obj([("restarting", Json::boolean(true))])))
    "elevation.set" => {
      match fx.elevation {
        Some(Object(e)) => {
          let shown = e.copy()
          shown["on"] = Json::boolean(flag(p, "on"))
          shown["busy"] = Json::boolean(true)
          shown["canChange"] = Json::boolean(false)
          fx.elevation = Some(Json::object(shown))
          fx_changed()
        }
        _ => ()
      }
      Some(Ok(obj([])))
    }
    "screenService.set" => {
      match fx.screen_service {
        Some(Object(e)) => {
          let shown = e.copy()
          shown["on"] = Json::boolean(flag(p, "on"))
          shown["busy"] = Json::boolean(true)
          shown["canChange"] = Json::boolean(false)
          fx.screen_service = Some(Json::object(shown))
          fx_changed()
        }
        _ => ()
      }
      Some(Ok(obj([])))
    }
    "context.setAfresh" => {
      match field(p, "afreshWhenCold") {
        Some(True) => fx.afresh = true
        Some(False) => fx.afresh = false
        _ => ()
      }
      match field(p, "afreshAbove") {
        Some(Number(above, ..)) => fx.afresh_above = above
        _ => ()
      }
      fx_changed()
      Some(Ok(obj([])))
    }
    "diagnostics.setLogs" => {
      fx.logs = flag(p, "logs")
      fx_changed()
      Some(Ok(obj([])))
    }
    "autoChats.save" => {
      fx.accept_auto_chats = flag(p, "enabled")
      fx_changed()
      Some(Ok(obj([])))
    }
    "software.check" | "software.update" | "software.channel" | "search.setPersonal" | "permissions.request" =>
      Some(Ok(obj([])))
    "agentEnv.form.open" | "agentEnv.form.edit" | "agentEnv.form.drop" | "agentEnv.form.save" => Some(Ok(obj([])))
    // ChatGPT 团队's models named by hand, one taken off
    "profile.put" if text(p, "id") == "cx" && field(field(p, "input"), "models") is Some(Array(_)) => {
      let named = items(field(p, "input"), "models").filter_map(fn(m) { if m is String(m) { Some(m) } else { None } })
      fx.models_added.retain(fn(m) { named.contains(m) })
      fx_changed()
      Some(Ok(obj([])))
    }
    "profile.put" if text(p, "id") == "cc" &&
      (field(field(p, "input"), "maxConcurrentSessions") is Some(_) || field(field(p, "input"), "newAccountProtection") is Some(_)) => {
      match field(field(p, "input"), "maxConcurrentSessions") {
        Some(v) => fx.cc_max_sessions = v
        None => ()
      }
      fx.cc_protection = false
      fx_changed()
      Some(Ok(obj([])))
    }
    "profile.put" if text(p, "id") == "k2" && has(field(p, "input"), "enabled") => {
      fx.key_enabled = flag(field(p, "input"), "enabled")
      fx_changed()
      Some(Ok(obj([])))
    }
    "profile.put" if text(p, "id") == "bx" && has(field(p, "input"), "enabled") => {
      fx.copy_enabled = flag(field(p, "input"), "enabled")
      fx_changed()
      Some(Ok(obj([])))
    }
    // (公司 Claude set to follow the whitelist or not, as the station keeps it: its share's `allowAuto`)
    "profile.share" if text(p, "id") == "cc" && flag(p, "on") => {
      fx.cc_follows = flag(p, "allowAuto")
      fx_changed()
      Some(Ok(obj([])))
    }
    "profile.quota" | "profile.check" | "profile.put" | "profile.share" => Some(Ok(obj([])))
    // the subscription's sign-in begun: as settings-profile-login has it, waiting on the code
    "profile.login" => {
      fx.login = "needs_code"
      fx_changed()
      Some(Ok(obj([])))
    }
    "profile.resetQuota" if text(p, "reset") == "model" => {
      fx.fable_used = true
      fx_changed()
      Some(Ok(obj([])))
    }
    "profile.resetQuota" => {
      fx.resets_used += 1
      fx_changed()
      Some(Ok(obj([])))
    }
    "profile.addModel" => {
      if text(p, "id") == "cx" {
        fx.models_added.push(text(p, "model"))
      }
      fx_changed()
      Some(Ok(obj([])))
    }
    // a new connect's wizard gone on or back (its back as the core's: the app's step back to the workspace's, the first
    // closing it)
    "connect.flow.go" => {
      let to = text(field(p, "input"), "to")
      let target = match (to, fx_connect_step.val) {
        ("back", "app") => "team"
        ("back", "feishuScan") => "feishuWay"
        ("back", "groupForm") => "groupBind"
        ("back", "groupBind") => "platformGroup"
        ("back", _) => "close"
        (step, _) => step
      }
      if target == "close" {
        Some(Ok(obj([("close", Json::boolean(true))])))
      } else {
        fx_connect_step.val = target
        fx_changed()
        Some(Ok(obj([])))
      }
    }
    // the drafts' forms (a new profile's, a new connect's, the decisions' and the archive policy's), opened and edited
    // an Anthropic plan's sign-in for a new profile, begun (settings-new-profile-login…)
    "login.new" if fx_colab_login.val =>
      Some(
        Ok(
          obj([
            ("id", str("login-new")),
            (
              "job",
              obj([
                ("profile", str("login-new")),
                ("runtime", Json::null()),
                ("service", str("colab")),
                ("state", str("needs_code")),
                ("url", str("https://accounts.google.com/o/oauth2/v2/auth?client_id=1014160490159&scope=colaboratory")),
                ("startedAt", Json::number(0.0)),
                ("expiresAt", Json::number(0.0)),
                ("browser", Json::boolean(true)),
              ]),
            ),
          ]),
        ),
      )
    "login.new" if fx.new_login => Some(Ok(obj([("id", str("login-new")), ("job", fx_login_job("login-new", "needs_code"))])))
    // a code pasted back for Claude's sign-in, as the station takes it (station/src/accounts/login.ts claudeCodeOf):
    // refused without its `#` and what follows it, the sign-in still waiting; whole, signed in
    "login.code" if fx.new_login =>
      Some(
        match fx_claude_code(text(p, "code")) {
          Some(e) => Err(e)
          None => {
            fx_new_login_done.val = true
            fx_changed()
            Ok(obj([("job", fx_login_job("login-new", "done"))]))
          }
        },
      )
    "profile.loginCode" if fx.login == "needs_code" =>
      Some(
        match fx_claude_code(text(p, "code")) {
          Some(e) => Err(e)
          None => {
            fx.login = "done"
            fx_changed()
            Ok(obj([]))
          }
        },
      )
    // Google's sign-in, begun; its code taken (a company's then asks for its project), its project taken
    "login.new" if fx_google.val != "" => {
      // (one under way already, as a mode put it: as it is)
      if fx_google_login.val == "" {
        fx_google_login.val = "needs_code"
      }
      fx_changed()
      Some(Ok(obj([("id", str("login-new")), ("job", fx_google_job(fx_google_login.val))])))
    }
    "login.code" if fx_google_login.val != "" => {
      // (a company's code: then its project; its project, or a person's code: signed in, its profile made, as gw)
      fx_google_login.val = if fx_google_login.val == "needs_code" && fx_google.val == "enterprise" { "needs_project" } else { "done" }
      if fx_google_login.val == "done" {
        fx_google_profiles.val = true
      }
      fx_changed()
      Some(Ok(obj([("job", fx_google_job(fx_google_login.val))])))
    }
    "login.drop" if fx_google_login.val != "" => {
      fx_google_login.val = ""
      fx_changed()
      Some(Ok(obj([])))
    }
    // Google's draft moved on as the core moves it (forms.ts): its provider picked, a way chosen, back
    "profile.flow.edit" if fx_google.val != "" => {
      let patch = field(p, "input")
      let was = fx_google.val
      fx_google.val = if text(patch, "provider") == "google" {
        "method"
      } else if has(patch, "provider") && text(patch, "provider") == "" {
        "pick"
      } else if text(patch, "method") != "" {
        text(patch, "method")
      } else if flag(patch, "back") {
        if was == "method" || was == "pick" { "pick" } else { "method" }
      } else {
        was
      }
      if fx_google.val != was {
        fx_google_login.val = ""
        fx_changed()
      }
      Some(Ok(obj([])))
    }
    // a new group connect's server as typed, and added (k1 is it from then on)
    "connect.flow.edit" if has(field(p, "input"), "group") => {
      let g = field(field(p, "input"), "group")
      for name in ["server", "relays", "code", "botName"] {
        if has(g, name) {
          fx_group_typed[name] = text(g, name)
        }
      }
      fx_changed()
      Some(Ok(obj([])))
    }
    "connect.flow.create" if fx_connect_step.val == "groupForm" => {
      fx_group_made.val = true
      fx_connect_step.val = "groupDone"
      fx_changed()
      Some(Ok(obj([("id", str("k1"))])))
    }
    "connect.put" if has(field(p, "input"), "autoStation") || has(field(p, "input"), "stations") => {
      let id = text(p, "id")
      let inp = field(p, "input")
      if flag(inp, "autoStation") {
        fx_connect_auto[id] = true
        fx_connect_stations.remove(id)
      } else if has(inp, "stations") {
        fx_connect_auto.remove(id)
        let next : Array[String] = []
        for s in strings(inp, "stations") {
          let trimmed = s.trim(chars=" \t\n").to_owned()
          let bare = match trimmed.rev_find("/") {
            Some(i) => trimmed.clamped_view(start=i + 1, end=trimmed.length()).to_owned()
            None => trimmed
          }
          if bare != "" && !next.contains(bare) {
            next.push(bare)
          }
        }
        if next.length() > 0 {
          fx_connect_stations[id] = next
        } else {
          fx_connect_stations.remove(id)
        }
      } else {
        fx_connect_auto.remove(id)
      }
      fx_changed()
      Some(Ok(obj([])))
    }
    "profile.flow.open" | "profile.flow.edit" | "profile.flow.drop" | "connect.flow.open" | "connect.flow.edit"
    | "connect.flow.drop" | "automaticDecisions.form.open" | "automaticDecisions.form.edit"
    | "automaticDecisions.form.drop" | "automaticDecisions.policy.open" | "automaticDecisions.policy.drop" =>
      Some(Ok(obj([])))
    // people added: each as one who has not signed in yet
    "workspace.addMembers" =>
      Some(Ok(obj([("joined", []), ("added", field(p, "emails").unwrap_or(Json::array([]))), ("already", [])])))
    "workspace.setRelays" => {
      fx.relays.clear()
      for u in items(p, "relays") {
        if u is String(s) {
          fx.relays.push(s)
        }
      }
      if fx.relays.is_empty() {
        fx.ours_off = false
      }
      fx_changed()
      Some(Ok(obj([])))
    }
    "workspace.setWay" => {
      if text(p, "way") == "ours" {
        fx.ours_off = !flag(p, "on")
      }
      fx_changed()
      Some(Ok(obj([])))
    }
    _ => None
  }
}

///|
/// The trusted devices a waiting device dials (the lock's `me.pair.approvers`): a phone and a laptop, the phone
/// showing the code where `code`.
fn waiting_approvers(code : Bool) -> Json {
  [
    obj([
      ("id", str("d-phone")),
      ("showing", Json::boolean(code)),
      ("kind", str("phone")),
      ("nameText", str("Pixel 9")),
    ]),
    obj([
      ("id", str("d-laptop")),
      ("showing", Json::boolean(false)),
      ("kind", str("computer")),
      ("nameText", str("林的 MacBook Pro")),
    ]),
  ]
}

///|
/// The lock as a device not confirmed in it has it (MBUI_FIXTURE=lock-waiting, lock-finding, lock-code, lock-wrong,
/// lock-wrong-gone, lock-checking, lock-confirming, lock-none, lock-failed, lock-nocode, lock-security, each also -dark: its waiting page
/// asking, finding, the code being typed, typed wrong (or the device showing it gone), being checked (the device showing
/// it asking its person there), no device found,
/// the pairing failed (lock-elsewhere: approved in another workspace, not this one), this device without
/// its code yet; its security page): this device waiting, not a signer. lock-upgrade: in the lock but not signing (its key lost), the code being typed on its
/// security page. lock-needs-app, lock-needs-app-security: a web page left out of an upgraded workspace that nobody can
/// approve there (its person has no app in it): the core's `needsAppText` in place of the ask, on its waiting page and
/// on its security page. lock-out, lock-out-security: its person taken out of an upgraded workspace, by whom, when and
/// whom to ask (the core's `outText`), the ask there for once they are added back. lock-restart, lock-restart-security:
/// its person's own lock to join, none of their devices answering, 我的其它设备都不在了 offered (`restartText`); lock-rebound,
/// lock-rebound-security: made their only trusted device, the workspace binding the lock of before, whom to ask
/// (`reboundText`), nothing to press; lock-replaced, lock-replaced-security: their own lock begun anew on another device,
/// what happened and 是我做的，继续 (`forgetText`). What a press makes of them: `fx.own_after`.
fn waiting_lock(mode : String) -> Json {
  let mode = if mode.has_suffix("-dark") { mode.unsafe_substring(start=0, end=mode.length() - 5) } else { mode }
  let own = if fx.own_after != "" {
    fx.own_after
  } else if mode.has_prefix("lock-restart") {
    "restart"
  } else if mode.has_prefix("lock-rebound") {
    "rebound"
  } else if mode.has_prefix("lock-replaced") {
    "replaced"
  } else {
    ""
  }
  let pair = match mode {
    // (a code typed here, as the made-up core takes it: fixture_pair_typed)
    _ if fx.pair_flow == "checking" => obj([("state", str("checking")), ("left", Json::number(3.0))])
    _ if fx.pair_flow == "confirming" =>
      obj([("state", str("checking")), ("left", Json::number(3.0)), ("checkingText", str("请在显示安全码的设备上完成身份验证"))])
    _ if fx.pair_flow == "retry" =>
      obj([("state", str("wrong")), ("left", Json::number(3.0)), ("error", str(fixture_pair_retry)), ("untilText", str("14:05 前有效"))])
    _ if fx.pair_flow == "done" => obj([("state", str("done"))])
    _ if own == "restart" => obj([("state", str("none")), ("approvers", waiting_approvers(false))])
    _ if own != "" => Json::null()
    // (the devices it dials, the core's rows; one showing the code, once it does)
    "lock-finding" => obj([("state", str("finding")), ("approvers", waiting_approvers(false))])
    "lock-code" | "lock-upgrade" =>
      obj([("state", str("code")), ("left", Json::number(3.0)), ("untilText", str("14:05 前有效")), ("approvers", waiting_approvers(true))])
    "lock-wrong" => obj([("state", str("wrong")), ("left", Json::number(2.0)), ("untilText", str("14:05 前有效"))])
    "lock-wrong-gone" =>
      obj([("state", str("wrong")), ("left", Json::number(2.0)), ("error", str("安全码不对，或显示它的设备已断开，还可以试 2 次")), ("untilText", str("14:05 前有效"))])
    "lock-checking" => obj([("state", str("checking")), ("left", Json::number(3.0))])
    // (the trusted device took the code and asks its person there: where to look, the core's words)
    "lock-confirming" =>
      obj([("state", str("checking")), ("left", Json::number(3.0)), ("checkingText", str("请在显示安全码的设备上完成身份验证"))])
    "lock-none" => obj([("state", str("none")), ("approvers", waiting_approvers(false))])
    "lock-failed" => obj([("state", str("failed")), ("error", str("配对超时"))])
    "lock-elsewhere" =>
      obj([("state", str("failed")), ("devices", Json::number(0.0)), ("error", str("此设备已在「日常」获批，在这里还需要此 workspace 的管理员或你在这里的受信任设备批准"))])
    _ => Json::null()
  }
  // in the lock, its key since lost (a phone moved to a new one): made one that signs on its security page
  let upgrade = mode == "lock-upgrade"
  let code = if mode == "lock-nocode" { "" } else { "Q4K-7PM" }
  // a web page nobody can approve here: not waiting (nothing to ask), the core's words (core-misc.lock.needsApp)
  let needs_app = mode.has_prefix("lock-needs-app")
  let me : Array[(String, Json)] = [
    ("device", str("d-me")),
    ("code", str(code)),
    ("kind", str(if needs_app { "web" } else { "app" })),
    ("confirmed", Json::boolean(upgrade || fx.pair_flow == "done")),
    ("waiting", Json::boolean(!upgrade && !needs_app && fx.pair_flow != "done")),
    ("unsigned", Json::boolean(upgrade)),
    ("pair", pair),
  ]
  if mode.has_prefix("lock-out") {
    me.push(("outText", str("Ana 于 11月15日 14:05 将你移出了此 workspace 的安全模式。需要继续使用的话，请联系 Ana 或其他管理员重新添加")))
  }
  if needs_app {
    me.push(("needsAppText", str("此 workspace 的安全模式要求每位成员至少有一台客户端。请安装桌面或手机客户端并登录，由管理员批准后，再用客户端批准此网页版")))
  }
  // (the core's words, core-misc.lock.* and android-misc.personal.*)
  match own {
    "restart" | "asked" => me.push(("ownLock", Json::boolean(true)))
    _ => ()
  }
  match own {
    "restart" => {
      me.push(("restartText", str("我的其它设备都不在了")))
      me.push(("restartNoteText", str("选「我的其它设备都不在了」后，这台设备会成为你唯一的受信任设备；已开启安全模式的 workspace 需先将你移出再重新添加，你的其它设备也需重新获批。")))
    }
    "rebound" =>
      me.push(("reboundText", str("已将这台设备设为你唯一的受信任设备。请此 workspace 的另一位 owner 先将你移出再重新添加；若只有你一位 owner，请在各台 station 所在的机器上运行 stillfail lock reset 后重新开启安全模式。")))
    "replaced" => {
      me.push(("replacedTitleText", str("你的受信任设备被重新设置过")))
      me.push(("replacedNoteText", str("只有你自己在另一台设备上选过「我的其它设备都不在了」才会这样。如果不是你做的，不要继续，你的账号可能已经被盗。")))
      me.push(("forgetText", str("是我做的，继续")))
    }
    _ => ()
  }
  obj([
    ("available", Json::boolean(true)),
    ("locked", Json::boolean(true)),
    ("notice", Json::boolean(false)),
    ("role", str("owner")),
    ("manages", Json::boolean(true)),
    ("owner", Json::boolean(true)),
    ("canSign", Json::boolean(!needs_app)),
    ("signs", Json::boolean(false)),
    ("signers", Json::number(5.0)),
    ("protected", Json::number(4.0)),
    ("attention", Json::number(0.0)),
    ("me", obj(me)),
    (
      "members",
      [
        obj([
          ("sub", str("u1")),
          ("email", str("lin@example.com")),
          ("name", str("林")),
          ("role", str("owner")),
          ("you", Json::boolean(true)),
          ("nameText", str("林")),
          ("roleText", str("Owner")),
          (
            "groups",
            [
              obj([
                ("appText", str("still.fail Android")),
                ("devices", [
                  obj([("id", str("d1")), ("kind", str("app")), ("label", str("still.fail Android · OPPO PLP110")), ("signs", Json::boolean(true)), ("older", Json::boolean(false)), ("mine", Json::boolean(false)), ("renewSoon", Json::boolean(false)), ("recent", Json::boolean(false)), ("lastSeen", Json::number(1760000000.0)), ("removable", Json::boolean(false)), ("nameText", str("OPPO PLP110")), ("fullText", str("OPPO PLP110 · still.fail Android")), ("metaText", str("一天内使用过 · 受信任"))]),
                ]),
              ]),
            ],
          ),
        ]),
      ],
    ),
    ("stations", []),
    ("renew", []),
  ])
}

///|
/// The dialog of the desktop's pages a fixture's mode puts up ("" none), taken once: the desktop's page puts it up
/// once it is drawn with what it needs.
pub fn fixture_copies() -> Json? {
  fx.copies
}

///|
/// What a fixture's mode puts up over the settings (MBUI_FIXTURE=settings-…), said once.
pub fn fixture_desk() -> String {
  let d = fixture_open.desk
  fixture_open.desk = ""
  d
}

///|
/// The sheet a fixture's mode puts up, once its page is drawn with what it needs (`page`).
fn fixture_sheet(core : Core, here : Here) -> Unit {
  let what = fixture_open.sheet
  if what == "" {
    return
  }
  fixture_open.sheet = ""
  match what {
    "mark" => {
      let s = Some(fx_station("ws1/st1"))
      open_mark_pick(core, text(s, "name"), text(s, "emoji"), text(s, "icon"), "", fn(_, _, _) {  })
    }
    "add-people" => open_add_people(core, here, workspace_view(core, here).value)
    "workspace-mark" => open_mark_pick(core, "星火工作室", "", "glyph:rocket:orange", "", fn(_, _, _) {  })
    "add" | "add-existing" | "add-command" => {
      open_add_station(core, here, ["st1", "st2"], existing=what == "add-existing")
      if what == "add-command" {
        adding.made.set(Some(
          (
            "curl -fsSL https://still.fail/install.sh | sh -s -- 4f7c2a9e1b",
            "& ([scriptblock]::Create((irm https://still.fail/install.ps1))) 4f7c2a9e1b",
            "docker run -d --restart unless-stopped -v stillfail:/home/stillfail -e STILLFAIL_ORIGIN=https://still.fail ghcr.io/afk-surf/stillfail-station 4f7c2a9e1b",
          ),
        ))
      }
    }
    _ => ()
  }
}

///|
/// Made-up recovery words for the words' screenshot (no one's: the words of a fixture are not a key to anything).
fn fx_words() -> Array[String] {
  [
    "amber", "basin", "cedar", "delta", "ember", "fable", "grove", "harbor", "island", "jasper", "kettle", "lantern", "meadow",
    "nectar", "orbit", "pebble", "quarry", "river", "saddle", "timber", "umbra", "velvet", "willow", "zephyr",
  ]
}

///|
/// Why the station would refuse `code` pasted back for Claude's sign-in (no `#`, or nothing on a side of it), as its
/// refusal comes to the app; None where it takes it.
fn fx_claude_code(code : String) -> Json? {
  let parts = code.split("#").to_array()
  if parts.length() == 2 && parts[0].trim(chars=" ").length() > 0 && parts[1].trim(chars=" ").length() > 0 {
    None
  } else {
    Some(obj([("code", str("http")), ("message", str("授权码不完整，请复制授权页面上的完整授权码（含 # 及后面的部分）"))]))
  }
}

///|
/// A subscription's sign-in under way in `state` (a profile's, or a new one's by its login's id): its page, and that
/// the station's own browser can open it where the fixture says so.
fn fx_login_job(profile : String, state : String) -> Json {
  let o = [
    ("profile", str(profile)),
    ("runtime", str(if profile == "cx" { "codex" } else { "claude" })),
    ("state", str(state)),
    ("url", str("https://claude.example/oauth/authorize")),
    ("startedAt", Json::number(0.0)),
    ("expiresAt", Json::number(0.0)),
  ]
  if fx.login_station {
    o.push(("browser", Json::boolean(true)))
  }
  obj(o)
}

///|
/// A new profile's draft at an Anthropic plan's sign-in (`profileFlow`, settings-new-profile-login…): 连接 Anthropic.
fn fx_profile_flow_plan() -> Json {
  obj([
    ("step", str("connect")),
    ("station", str("ws1/st1")),
    ("title", str("连接 Anthropic")),
    ("hint", str("")),
    ("method", str("plan")),
    ("tile", obj([("id", str("anthropic")), ("name", str("Anthropic")), ("kind", str("subscription")), ("runtime", str("claude")), ("mark", str("anthropic"))])),
    ("signIn", obj([("runtime", str("claude")), ("provider", str("Claude")), ("access", str(""))])),
    ("groups", []),
    ("choices", []),
    ("showEndpoint", Json::boolean(false)),
    ("endpoint", str("")),
    ("protocols", []),
    ("showKey", Json::boolean(false)),
    ("key", str("")),
    ("keyLabel", str("")),
    ("canSubmit", Json::boolean(false)),
    ("pending", Json::boolean(false)),
    ("submitLabel", str("")),
    ("usesLine", str("")),
  ])
}

///|
/// Google's sign-in under way in `state` (settings-new-profile-google…): its page at accounts.google.com.
fn fx_google_job(state : String) -> Json {
  obj([
    ("profile", str("login-new")),
    ("runtime", str("agy")),
    ("state", str(state)),
    ("url", str("https://accounts.google.com/o/oauth2/auth")),
    ("startedAt", Json::number(0.0)),
    ("expiresAt", Json::number(0.0)),
  ])
}

///|
/// A new profile's draft for Google at `at` (fx_google): the providers with Google among them, its ways (a person's
/// plan, a company's, a key) as the core says them, or the way chosen: a plan's sign-in, or the key's form.
fn fx_profile_flow_google(at : String) -> Json {
  if at == "pick" {
    guard fx_profile_flow() is Object(m) else { return fx_profile_flow() }
    let google = obj([
      ("id", str("google")), ("name", str("Google Gemini")), ("group", str("labs")), ("kind", str("api-provider")),
      ("runtime", str("agy")), ("mark", str("gemini")), ("hasKey", Json::boolean(true)), ("hasPlan", Json::boolean(true)),
    ])
    let groups = match m.get("groups") {
      Some(Array(gs)) =>
        gs.mapi(fn(i, g) {
          match g {
            Object(o) if i == 0 =>
              match o.get("providers") {
                Some(Array(ps)) => {
                  let o2 = o.copy()
                  o2["providers"] = Json::array([..ps, google])
                  Json::object(o2)
                }
                _ => g
              }
            _ => g
          }
        })
      _ => []
    }
    let m2 = m.copy()
    m2["groups"] = Json::array(groups)
    return Json::object(m2)
  }
  let choice = fn(id : String, title : String, hint : String) { obj([("id", str(id)), ("title", str(title)), ("hint", str(hint))]) }
  let way = if at == "method" { "" } else { at }
  let fields : Array[(String, Json)] = [
    ("step", str(if at == "method" { "method" } else { "connect" })),
    ("station", str("ws1/st1")),
    ("title", str("连接 Google Gemini")),
    ("hint", str("")),
    ("method", str(way)),
    (
      "tile",
      obj([
        ("id", str("google")), ("name", str("Google Gemini")), ("kind", str("api-provider")), ("runtime", str("agy")),
        ("mark", str("gemini")), ("hasKey", Json::boolean(true)), ("hasPlan", Json::boolean(true)),
      ]),
    ),
    ("groups", []),
    (
      "choices",
      if at == "method" {
        [
          choice("plan", "订阅 · Google AI", "Google AI Pro / Ultra 或免费账号，运行 Antigravity CLI（第三方工具使用有封号风险）"),
          choice("enterprise", "企业版 · Gemini Enterprise", "Google Workspace / Cloud 公司账号，运行 Antigravity CLI（第三方工具使用有封号风险）"),
          choice("key", "API key", "使用 Google Gemini 的 API key，按量计费"),
        ]
      } else {
        []
      },
    ),
    ("showEndpoint", Json::boolean(false)),
    ("endpoint", str("")),
    ("protocols", []),
    ("showKey", Json::boolean(at == "key")),
    ("key", str("")),
    ("keyLabel", str(if at == "key" { "API key" } else { "" })),
    ("canSubmit", Json::boolean(false)),
    ("pending", Json::boolean(false)),
    ("submitLabel", str(if at == "key" { "验证并添加" } else { "" })),
    ("usesLine", str(if at == "method" { "" } else { "添加后可用于：Antigravity CLI" })),
  ]
  if at == "plan" || at == "enterprise" {
    fields.push((
      "signIn",
      obj([("runtime", str("agy")), ("provider", str("Google")), ("access", str(if at == "enterprise" { "agy-enterprise" } else { "" }))]),
    ))
  }
  obj(fields)
}

///|
/// A new profile's draft at a key's form (`profileFlow`, settings-new-profile-key): Kimi's, a region and a protocol to
/// choose, the key not typed yet.
fn fx_profile_flow_key() -> Json {
  let pair = fn(id : String, label : String) { obj([("id", str(id)), ("label", str(label))]) }
  obj([
    ("step", str("connect")),
    ("station", str("ws1/st1")),
    ("title", str("连接 Kimi")),
    ("hint", str("")),
    ("method", str("key")),
    ("tile", obj([("id", str("kimi")), ("name", str("Kimi")), ("kind", str("api-provider")), ("runtime", str("")), ("mark", str("kimi"))])),
    ("groups", []),
    ("choices", []),
    ("showEndpoint", Json::boolean(false)),
    ("endpoint", str("")),
    ("regions", [pair("cn", "中国"), pair("global", "国际")]),
    ("region", str("cn")),
    ("protocols", [pair("openai", "OpenAI 兼容"), pair("anthropic", "Anthropic 兼容")]),
    ("protocol", str("openai")),
    ("showKey", Json::boolean(true)),
    ("key", str("")),
    ("keyLabel", str("API key")),
    ("canSubmit", Json::boolean(false)),
    ("pending", Json::boolean(false)),
    ("submitLabel", str("验证并添加")),
    ("usesLine", str("")),
  ])
}

///|
/// A new profile's draft at Google's 4-way method picker (`profileFlow`, settings-new-profile-google-colab-ways).
fn fx_profile_flow_google_colab_ways() -> Json {
  let choice = fn(id : String, title : String, hint : String) { obj([("id", str(id)), ("title", str(title)), ("hint", str(hint))]) }
  obj([
    ("step", str("method")),
    ("station", str("ws1/st1")),
    ("title", str("连接 Google")),
    ("hint", str("")),
    ("method", str("")),
    (
      "tile",
      obj([
        ("id", str("google")), ("name", str("Google")), ("kind", str("api-provider")), ("runtime", str("agy")),
        ("service", str("colab")), ("mark", str("gemini")), ("hasKey", Json::boolean(true)), ("hasPlan", Json::boolean(true)),
      ]),
    ),
    ("groups", []),
    (
      "choices",
      [
        choice("plan", "订阅 · Google AI", "Google AI Pro / Ultra 或免费账号，运行 Antigravity CLI（第三方工具使用有封号风险）"),
        choice("enterprise", "企业版 · Gemini Enterprise", "Google Workspace / Cloud 公司账号，运行 Antigravity CLI（第三方工具使用有封号风险）"),
        choice("colab", "Google Colab", "Google Colab / AI Ultra 账号，用于 GPU 算力任务"),
        choice("key", "API key", "使用 Google Gemini 的 API key，按量计费"),
      ],
    ),
    ("showEndpoint", Json::boolean(false)),
    ("endpoint", str("")),
    ("protocols", []),
    ("showKey", Json::boolean(false)),
    ("key", str("")),
    ("keyLabel", str("")),
    ("canSubmit", Json::boolean(false)),
    ("pending", Json::boolean(false)),
    ("submitLabel", str("")),
    ("usesLine", str("")),
  ])
}

///|
/// A new profile's draft at Google's 5-way method picker with Vertex AI (`profileFlow`, settings-new-profile-google-vertex-ways).
fn fx_profile_flow_google_vertex_ways() -> Json {
  let choice = fn(id : String, title : String, hint : String) { obj([("id", str(id)), ("title", str(title)), ("hint", str(hint))]) }
  obj([
    ("step", str("method")),
    ("station", str("ws1/st1")),
    ("title", str("连接 Google")),
    ("hint", str("")),
    ("method", str("")),
    (
      "tile",
      obj([
        ("id", str("google")), ("name", str("Google")), ("kind", str("api-provider")), ("runtime", str("agy")),
        ("service", str("colab")), ("mark", str("gemini")), ("hasKey", Json::boolean(true)), ("hasPlan", Json::boolean(true)),
        ("hasVertex", Json::boolean(true)),
      ]),
    ),
    ("groups", []),
    (
      "choices",
      [
        choice("plan", "订阅 · Google AI", "Google AI Pro / Ultra 或免费账号，运行 Antigravity CLI（第三方工具使用有封号风险）"),
        choice("enterprise", "企业版 · Gemini Enterprise", "Google Workspace / Cloud 公司账号，运行 Antigravity CLI（第三方工具使用有封号风险）"),
        choice("vertex", "Vertex AI", "Google Cloud 项目的服务账号密钥，运行 Antigravity CLI，按量计费"),
        choice("colab", "Google Colab", "Google Colab / AI Ultra 账号，用于 GPU 算力任务"),
        choice("key", "API key", "使用 Google Gemini 的 API key，按量计费"),
      ],
    ),
    ("showEndpoint", Json::boolean(false)),
    ("endpoint", str("")),
    ("protocols", []),
    ("showKey", Json::boolean(false)),
    ("key", str("")),
    ("keyLabel", str("")),
    ("canSubmit", Json::boolean(false)),
    ("pending", Json::boolean(false)),
    ("submitLabel", str("")),
    ("usesLine", str("")),
  ])
}

///|
/// A new profile's draft at Google Vertex AI's key form with an error under it (`profileFlow`, settings-new-profile-google-vertex-key).
fn fx_profile_flow_google_vertex_key() -> Json {
  obj([
    ("step", str("connect")),
    ("station", str("ws1/st1")),
    ("title", str("连接 Google")),
    ("hint", str("")),
    ("method", str("vertex")),
    (
      "tile",
      obj([
        ("id", str("google")), ("name", str("Google")), ("kind", str("api-provider")), ("runtime", str("agy")),
        ("mark", str("gemini")), ("hasKey", Json::boolean(true)), ("hasPlan", Json::boolean(true)),
        ("hasVertex", Json::boolean(true)),
      ]),
    ),
    ("groups", []),
    ("choices", []),
    ("showEndpoint", Json::boolean(false)),
    ("endpoint", str("")),
    ("protocols", []),
    ("showKey", Json::boolean(true)),
    ("key", str("")),
    ("keyLabel", str("服务账号密钥（JSON）")),
    ("keyHint", str("粘贴服务账号 JSON 密钥的全部内容，仅保存在此 station 上")),
    ("error", str("验证没通过：请粘贴有效的 Google Cloud 服务账号 JSON 密钥（需包含 type、project_id、client_email 和 private_key）")),
    ("canSubmit", Json::boolean(true)),
    ("pending", Json::boolean(false)),
    ("submitLabel", str("添加")),
    ("usesLine", str("添加后可用于：Antigravity CLI")),
  ])
}

///|
/// A new profile's draft at a Google Colab OAuth sign-in (`profileFlow`, settings-new-profile-colab-login).
fn fx_profile_flow_colab_login() -> Json {
  obj([
    ("step", str("connect")),
    ("station", str("ws1/st1")),
    ("title", str("连接 Google Colab")),
    ("hint", str("")),
    ("method", str("colab")),
    ("tile", obj([("id", str("google")), ("name", str("Google")), ("kind", str("api-provider")), ("runtime", str("agy")), ("service", str("colab")), ("mark", str("gemini"))])),
    ("signIn", obj([("service", str("colab")), ("provider", str("Google Colab"))])),
    ("groups", []),
    ("choices", []),
    ("showEndpoint", Json::boolean(false)),
    ("endpoint", str("")),
    ("protocols", []),
    ("showKey", Json::boolean(false)),
    ("key", str("")),
    ("keyLabel", str("")),
    ("canSubmit", Json::boolean(false)),
    ("pending", Json::boolean(false)),
    ("submitLabel", str("")),
    ("usesLine", str("添加后可用于 Google Colab GPU 算力任务")),
  ])
}

///|
/// A new profile's draft at its first step (`profileFlow`): the providers by group.
fn fx_profile_flow(hermes? : Bool = false, colab? : Bool = false) -> Json {
  let provider = fn(id : String, name : String, group : String, runtime : String, mark : String) {
    obj([("id", str(id)), ("name", str(name)), ("group", str(group)), ("kind", str("api-provider")), ("runtime", str(runtime)), ("mark", str(mark))])
  }
  let labs_providers : Array[Json] = [
    provider("openai", "OpenAI", "labs", "codex", "openai"),
    provider("anthropic", "Anthropic", "labs", "claude", "anthropic"),
    provider("deepseek", "DeepSeek", "labs", "", "deepseek"),
    provider("kimi", "Kimi", "labs", "", "kimi"),
  ]
  if colab {
    labs_providers.push(
      obj([
        ("id", str("google")),
        ("name", str("Google")),
        ("group", str("labs")),
        ("kind", str("api-provider")),
        ("runtime", str("agy")),
        ("service", str("colab")),
        ("mark", str("gemini")),
        ("hasKey", Json::boolean(true)),
        ("hasPlan", Json::boolean(true)),
      ]),
    )
  }
  let groups : Array[Json] = [
    obj([("id", str("labs")), ("title", str("模型厂商")), ("providers", Json::array(labs_providers))]),
    obj([("id", str("gateways")), ("title", str("中转站")), (
      "providers",
      [
        provider("openrouter", "OpenRouter", "gateways", "", "openrouter"),
        provider("command-code", "Command Code", "gateways", "", "command-code"),
        provider("open-design", "Open Design", "gateways", "", "open-design"),
      ],
    )]),
  ]
  if hermes {
    groups.push(obj([
      ("id", str("local")), ("title", str("自定义变量")),
      ("providers", [obj([
        ("id", str("env-hermes")), ("name", str("Hermes Agent")), ("group", str("local")),
        ("kind", str("env")), ("runtime", str("hermes")),
      ])]),
    ]))
  }
  obj([
    ("step", str("pick")),
    ("station", str("ws1/st1")),
    ("title", str("选择服务商")),
    ("hint", str("订阅和 API key 都在这里添加，选择服务商开始")),
    ("groups", Json::array(groups)),
    ("choices", []),
    ("showEndpoint", Json::boolean(false)),
    ("endpoint", str("")),
    ("protocols", []),
    ("showKey", Json::boolean(false)),
    ("key", str("")),
    ("keyLabel", str("")),
    ("canSubmit", Json::boolean(false)),
    ("pending", Json::boolean(false)),
    ("submitLabel", str("")),
    ("usesLine", str("")),
  ])
}

///|
/// Whether many chats are kept (MBUI_FIXTURE=settings-kept-many): 200 more after the three, each with a few KB.
let fx_many_kept : Ref[Bool] = Ref(false)

///|
/// The chats kept after the three when many are (fx_many_kept): 测试会话 1 to 200.
fn fx_kept_many() -> Array[Json] {
  if !fx_many_kept.val {
    return []
  }
  Array::makei(200, fn(i) -> Json {
    obj([
      ("station", str("ws1/st2")),
      ("thread", Json::number((100 + i).to_double())),
      ("title", str("测试会话 \{i + 1}")),
      ("sessions", Json::array([str("s-m\{i}")])),
      ("bytes", Json::number((4096 * (i + 1)).to_double())),
    ])
  })
}

///|
/// The chats kept, the one keeping most (its messages and its files) first, as the core gives them.
fn fx_kept_most_first(chats : Array[Json]) -> Array[Json] {
  let all = fn(x : Json) {
    items(Some(x), "files").fold(init=number(Some(x), "bytes"), fn(s, f) { s + number(Some(f), "bytes") })
  }
  let out = chats.copy()
  out.sort_by(fn(a, b) { all(b).compare(all(a)) })
  out
}

///|
/// A chat's agent as it runs and as it is to run (`pick` of `session:<key>`, the comma and group flows): its effort
/// raised to high, the rest as it was.
fn fx_session_pick() -> Json {
  let model = obj([("model", str("claude-opus-5-5")), ("name", str("Opus 5.5")), ("maker", obj([("id", str("anthropic"))]))])
  let options : Json = [model]
  obj([
    ("value", obj([("model", str("claude-opus-5-5")), ("runtime", str("claude"))])),
    ("draft", obj([("model", str("claude-opus-5-5")), ("runtime", str("claude")), ("effort", str("high"))])),
    ("option", str("claude-opus-5-5")),
    ("options", options),
    ("maker", obj([("id", str("anthropic"))])),
    ("modelText", str("Opus 5.5")),
    ("efforts", ["low", "medium", "high"]),
    ("was", ["Opus 5.5", "默认深度", "自动 · Claude 主账号"]),
    ("becomes", ["Opus 5.5", "high", "自动 · Claude 主账号"]),
    ("accountText", str(tr("core-logic.choose.account.auto"))),
    ("accountNote", str("Claude 主账号 · 5 小时窗口已用 62%")),
    ("repick", str("重新分配")),
    // (PickProfile: its kind, its runtime, its allowance as its chips draw it)
    (
      "accounts",
      [
        obj([
          ("id", str("p1")),
          ("name", str("Claude 主账号")),
          ("kind", str("subscription")),
          ("runtime", str("claude")),
          (
            "quota",
            obj([
              ("state", str("ok")),
              ("windows", [obj([("mark", str("5H")), ("left", Json::number(38.0)), ("level", str("ok"))]), obj([("mark", str("W")), ("left", Json::number(70.0)), ("level", str("ok"))])]),
            ]),
          ),
        ]),
      ],
    ),
    ("changed", Json::boolean(true)),
    ("saveText", str("改成 Opus 5.5 · high · 自动分配")),
  ])
}

///|
/// A new connect on Feishu's path (MBUI_FIXTURE=settings-new-connect-platform, -scan): the platform picked (飞书), or
/// the bot being made by scanning, its QR code waiting.
fn fx_feishu_flow(step : String) -> Json {
  let scanned = step == "feishuScanned"
  let scan = step == "feishuScan" || scanned
  let step = if scanned { "done" } else { step }
  let feishu : Array[(String, Json)] = [
    ("way", str("scan")),
    ("appId", str("")),
    ("appSecret", str("")),
    ("lark", Json::boolean(false)),
    ("canVerify", Json::boolean(false)),
    ("verified", Json::boolean(false)),
    ("errors", []),
    ("failed", Json::boolean(false)),
    ("creating", Json::boolean(false)),
    ("error", Json::null()),
    ("connect", if scanned { str("k1") } else { Json::null() }),
  ]
  if scan {
    feishu.push(("registration", obj([("state", str(if scanned { "done" } else { "waiting" })), ("url", str("https://open.feishu.cn/page/launcher?code=made-up"))])))
    feishu.push(("stateText", str("使用飞书扫描二维码，按提示创建机器人")))
    feishu.push(("qr", fx_qr(25)))
  }
  obj([
    ("step", str(step)),
    ("title", str(if scan { "扫码创建" } else { "选择平台" })),
    ("back", str(if scan { "feishuWay" } else { "close" })),
    ("number", Json::number(if scan { 4.0 } else { 1.0 })),
    ("total", Json::number(4.0)),
    ("mobile", Json::boolean(true)),
    ("platforms", [str("slack"), str("feishu")]),
    ("platform", str("feishu")),
    ("feishu", obj(feishu)),
    ("mode", str("multi-session")),
    ("requireMention", Json::boolean(true)),
    ("noProfile", Json::boolean(false)),
    ("canCreate", Json::boolean(true)),
  ])
}

///|
/// A made-up QR code's modules, `n` a side (the three finder squares, the rest a fixed scatter): only drawn, never
/// read.
fn fx_qr(n : Int) -> Json {
  let rows : Array[Json] = []
  for y in 0..<n {
    let row = StringBuilder()
    for x in 0..<n {
      let finder = fn(ox : Int, oy : Int) {
        let dx = x - ox
        let dy = y - oy
        if dx < 0 || dy < 0 || dx > 6 || dy > 6 {
          None
        } else {
          let ring = if dx < dy { dx } else { dy }
          let far = if 6 - dx < 6 - dy { 6 - dx } else { 6 - dy }
          let d = if ring < far { ring } else { far }
          Some(d != 1)
        }
      }
      let dark = match finder(0, 0) {
        Some(b) => b
        None =>
          match finder(n - 7, 0) {
            Some(b) => b
            None =>
              match finder(0, n - 7) {
                Some(b) => b
                None => (x * 7 + y * 13 + x * y * 3) % 5 < 2
              }
          }
      }
      row.write_char(if dark { '1' } else { '0' })
    }
    rows.push(str(row.to_string()))
  }
  obj([("size", Json::number(n.to_double())), ("rows", Json::array(rows))])
}

///|
/// A use, its figures and each said (ResourceUse): CPU, memory, the network's and the disk's rates.
fn fx_use(cpu : Double, memory : Double, net : Double, disk : Double, texts : (String, String, String, String)) -> Json {
  let (cpu_text, memory_text, net_text, disk_text) = texts
  obj([
    ("cpu", Json::number(cpu)),
    ("memory", Json::number(memory)),
    ("netIn", Json::number(net / 2.0)),
    ("netOut", Json::number(net / 2.0)),
    ("net", Json::number(net)),
    ("diskRead", Json::number(disk)),
    ("diskWrite", Json::number(0.0)),
    ("disk", Json::number(disk)),
    ("cpuText", str(cpu_text)),
    ("memoryText", str(memory_text)),
    ("netText", str(net_text)),
    ("diskText", str(disk_text)),
  ])
}

///|
/// What still.fail uses of Willow's machine now (ResourcesView), as a busy Mac says it: its four totals with what is
/// under each (the network and the disk both read), two chats' agents (one titled at length) and the station, each with
/// its processes.
fn fx_resources() -> Json {
  let process = fn(key : String, pid : Double, name : String, endable : Bool, u : Json) {
    obj([("key", str(key)), ("pid", Json::number(pid)), ("name", str(name)), ("endable", Json::boolean(endable)), ("use", u)])
  }
  let tile = fn(key : String, label : String, value : String, sub : String, points : Array[Double]) {
    obj([("key", str(key)), ("label", str(label)), ("value", str(value)), ("sub", str(sub)), ("points", Json::array(points.map(x => Json::number(x))))])
  }
  let chat = fx_use(25.9, 59.0e6, 0.0, 2.9e6, ("25.9%", "59 MB", "0 B/s", "2.9 MB/s"))
  let notes = fx_use(14.1, 980.0e6, 0.0, 13.0e3, ("14.1%", "980 MB", "0 B/s", "13 KB/s"))
  let station = fx_use(2.8, 363.0e6, 56.0e3, 0.0, ("2.8%", "363 MB", "56 KB/s", "0 B/s"))
  obj([
    ("wait", obj([("reading", Json::boolean(false)), ("text", str("")), ("failing", [])])),
    ("empty", Json::boolean(false)),
    ("net", Json::boolean(true)),
    ("disk", Json::boolean(true)),
    ("everyMs", Json::number(5000.0)),
    (
      "tiles",
      [
        tile("cpu", "CPU", "20.5%", "占 10 核的 2%", [12.0, 18.0, 15.0, 22.0, 20.5]),
        tile("memory", "内存", "508 MB", "占 32 GB 的 2%", [480.0, 495.0, 500.0, 504.0, 508.0]),
        tile("disk", "磁盘", "↓ 2.9 MB/s", "↑ 13 KB/s", [9.0, 1.0, 1.2, 0.9, 2.9]),
        tile("net", "网络", "↓ 1.6 KB/s", "↑ 410 B/s", [0.8, 2.4, 1.1, 1.9, 1.6]),
      ],
    ),
    ("kinds", [obj([("key", str("chat")), ("label", str("对话"))]), obj([("key", str("station")), ("label", str("Station"))])]),
    (
      "groups",
      [
        obj([
          ("key", str("chat:c1")),
          ("kind", str("chat")),
          ("title", str("修一下登录")),
          ("kindText", str("对话")),
          ("chat", obj([("station", str("ws1/st1")), ("session", str("s1"))])),
          ("station", str("ws1/st1")),
          ("session", str("s1")),
          ("use", chat),
          (
            "processes",
            [
              process("p1", 4211.0, "claude", false, fx_use(12.0, 41.0e6, 0.0, 1.9e6, ("12.0%", "41 MB", "0 B/s", "1.9 MB/s"))),
              process("p2", 4290.0, "node", true, fx_use(13.9, 18.0e6, 0.0, 1.0e6, ("13.9%", "18 MB", "0 B/s", "1.0 MB/s"))),
            ],
          ),
        ]),
        obj([
          ("key", str("chat:c2")),
          ("kind", str("chat")),
          ("title", str("把发版日志按平台分开写清楚，再给每一条补上改前改后的截图")),
          ("kindText", str("对话")),
          ("chat", obj([("station", str("ws1/st1")), ("session", str("s2"))])),
          ("station", str("ws1/st1")),
          ("session", str("s2")),
          ("use", notes),
          ("processes", [process("p4", 5120.0, "claude", false, notes)]),
        ]),
        obj([
          ("key", str("station")),
          ("kind", str("station")),
          ("title", str("Station")),
          ("kindText", str("")),
          ("station", str("ws1/st1")),
          ("use", station),
          ("processes", [process("p3", 812.0, "stillfail", false, station)]),
        ]),
      ],
    ),
    (
      "stations",
      [
        obj([
          ("station", str("ws1/st1")),
          ("net", Json::boolean(true)),
          ("use", fx_use(20.5, 508.0e6, 1.6e3, 2.9e6, ("20.5%", "508 MB", "1.6 KB/s", "2.9 MB/s"))),
        ]),
      ],
    ),
    ("notes", []),
    ("basis", str("按 Activity Monitor 的口径：CPU 100% 是一个核")),
  ])
}

///|
/// 共享调试 as a fixture's mode has it (MBUI_FIXTURE=settings-adb-<off|unpaired|pairing|connected|failed|chats|idle|desk>;
/// "" not lent).
let fx_adb : Ref[String] = Ref("")

///|
/// The core's `adbShare` for fx_adb: lent to Willow (ws1/st1) and how its adb holds the phone, the ports the app found.
fn fx_adb_share() -> Json {
  let lent = fn(adb : String, fields : Array[(String, Json)]) {
    obj(
      [
        ("sharing", Json::boolean(true)),
        ("station", str("ws1/st1")),
        ("phase", str("offered")),
        ("serial", str("127.0.0.1:37762")),
        ("adb", str(adb)),
        ("tunnels", Json::number(0.0)),
        ("connectPort", Json::number(41239.0)),
      ]..append(fields),
    )
  }
  // lent for a chat's grant (the station's adb as `adb` holds the phone), as a core of grants says it: the first lending
  // at its top, each in `lends`
  let granted = fn(adb : String, fields : Array[(String, Json)]) {
    lent(adb, [
      ("on", Json::boolean(true)),
      ("lends", Json::array([obj([("station", str("ws1/st1")), ("phase", str("offered")), ("adb", str(adb)), ("serial", str("127.0.0.1:37762")), ("tunnels", Json::number(0.0))])])),
      ("grants", Json::array([obj([("station", str("ws1/st1")), ("id", str("p-1")), ("session", str("s-c1")), ("chatTitle", str("通知权限检查")), ("reason", str("装上刚编好的测试包，看首屏在折叠屏展开时排得对不对")), ("status", str("granted")), ("scope", str("chat"))])])),
      ..fields,
    ])
  }
  // a device on the person's own lock
  let device = fn(key : String, label : String, me : Bool) { obj([("key", str(key)), ("label", str(label)), ("me", Json::boolean(me))]) }
  match fx_adb.val {
    // the person's own lock on 共享调试: this device on it (its devices listed, two), or to be approved by one
    "lock-member" =>
      lent("connected", [
        ("personal", Json::array([obj([("sub", str("s")), ("email", str("lin@example.com")), ("standing", str("member")), ("devices", Json::array([
          device("ed25519:aa", "OPPO PLP110", true),
          device("ed25519:bb", "MacBook Pro", false),
        ]))])])),
        ("toConfirm", Json::number(2.0)),
      ])
    // on the locks of two accounts (a phone signed in to both), the second's email long; a chat's grant held
    "lock-two" =>
      granted("connected", [
        ("personal", Json::array([
          obj([("sub", str("s-zuo")), ("email", str("zuozijian1994@gmail.com")), ("standing", str("member")), ("devices", Json::array([
            device("ed25519:z1", "youdid.wtf 桌面版 · 左子健的 MacBook Air", false),
            device("ed25519:z2", "youdid.wtf Android · OPPO Find N6", true),
            device("ed25519:z3", "still.fail Android · OPPO Find N6", false),
          ]))]),
          obj([("sub", str("s-work")), ("email", str("zijian.zuo.engineering@example-company.com")), ("standing", str("member")), ("devices", Json::array([
            device("ed25519:w1", "youdid.wtf Android · OPPO Find N6", true),
            device("ed25519:w2", "still.fail 桌面版 · Mac Studio", false),
          ]))]),
        ])),
      ])
    // 共享调试 with no lock of the person's own yet (the page as it is: allowing a request begins it), or this device
    // typing the code a trusted device of theirs shows (the page is that step alone)
    "gate-none" => lent("connected", [("personal", Json::array([obj([("sub", str("s")), ("email", str("lin@example.com")), ("standing", str("none")), ("devices", Json::array([]))])]))])
    "gate-code" =>
      lent("connected", [
        ("personal", Json::array([obj([("sub", str("s")), ("email", str("lin@example.com")), ("standing", str("outside")), ("devices", Json::array([])), ("pair", obj([("state", str("code")), ("devices", Json::number(1.0)), ("untilText", str("14:05 前有效")), ("showing", Json::array([str("MacBook Pro")]))]))])])),
      ])
    // (the code typed being checked, the device showing it asking its person there)
    "gate-checking" =>
      lent("connected", [
        ("personal", Json::array([obj([("sub", str("s")), ("email", str("lin@example.com")), ("standing", str("outside")), ("devices", Json::array([])), ("pair", obj([("state", str("checking")), ("devices", Json::number(1.0)), ("untilText", str("14:05 前有效")), ("checkingText", str("请在显示安全码的设备上完成身份验证")), ("showing", Json::array([str("MacBook Pro")]))]))])])),
      ])
    "lock-outside" => lent("connected", [("personal", Json::array([obj([("sub", str("s")), ("email", str("lin@example.com")), ("standing", str("outside")), ("devices", Json::array([]))])]))])
    "lock-replaced" => lent("connected", [("personal", Json::array([obj([("sub", str("s")), ("email", str("lin@example.com")), ("standing", str("replaced")), ("devices", Json::array([]))])]))])
    // two accounts signed in here: another's lock has this device on it, the workspace's account (u1) is to be approved
    // on its own (`multi`), or set it up again elsewhere (`multi-replaced`); or the other way round (`multi-member`)
    "lock-multi" | "lock-multi-replaced" | "lock-multi-member" => {
      let (mine, other) = match fx_adb.val {
        "lock-multi" => ("outside", "member")
        "lock-multi-replaced" => ("replaced", "member")
        _ => ("member", "outside")
      }
      let own = if mine == "member" { Json::array([device("ed25519:u1", "OPPO PLP110", true)]) } else { Json::array([]) }
      let others = if other == "member" { Json::array([device("ed25519:w1", "OPPO PLP110", true)]) } else { Json::array([]) }
      granted("connected", [
        ("personal", Json::array([
          obj([("sub", str("s-work")), ("email", str("lin@work.example")), ("standing", str(other)), ("devices", others)]),
          obj([("sub", str("u1")), ("email", str("lin@example.com")), ("standing", str(mine)), ("devices", own)]),
        ])),
      ])
    }
    // lent for a chat's grant to Willow: its adb waiting to be paired (the pairing dialog not open yet, then open),
    // holding the phone, failing
    "unpaired" => granted("unpaired", [])
    "pairing" => granted("unpaired", [("pairPort", Json::number(37115.0))])
    "connected" => granted("connected", [("tunnels", Json::number(1.0))])
    "failed" =>
      granted("failed", [
        // (the phone's own words, as a station says them: station/src/adb/link.ts Refused)
        ("message", str("无法连接手机上的 adb：Connection refused (os error 111)")),
        ("refusedPort", Json::number(41239.0)),
      ])
    // settings' 共享调试, its switch off: nothing granted
    "idle" => obj([("sharing", Json::boolean(false)), ("phase", str("off")), ("on", Json::boolean(false)), ("tunnels", Json::number(0.0))])
    // lent for chats' grants to two stations: Willow's adb holds the phone, the other's waits to be paired with it (as
    // a core from before it said the one it names at its top: the first)
    "second" =>
      lent("connected", [
        ("on", Json::boolean(true)),
        ("pairPort", Json::number(37115.0)),
        (
          "lends",
          Json::array([
            obj([("station", str("ws1/st1")), ("phase", str("offered")), ("adb", str("connected")), ("serial", str("127.0.0.1:37762")), ("tunnels", Json::number(1.0))]),
            obj([("station", str("ws1/st2")), ("phase", str("offered")), ("adb", str("unpaired")), ("serial", str("127.0.0.1:37715")), ("tunnels", Json::number(0.0))]),
          ]),
        ),
        (
          "grants",
          Json::array([
            obj([("station", str("ws1/st1")), ("id", str("p-1")), ("reason", str("装上刚编好的测试包，看首屏在折叠屏展开时排得对不对")), ("status", str("granted")), ("scope", str("chat"))]),
            obj([("station", str("ws1/st2")), ("id", str("p-2")), ("reason", str("录一段登录流程的视频")), ("status", str("granted")), ("scope", str("hour"))]),
          ]),
        ),
      ])
    // The length and mix of reasons people see in the grants list, including one from before use times were recorded
    // (desk: the same seen on a computer, which lends no adb of its own)
    "chats-long" | "desk" =>
      obj([
        ("sharing", Json::boolean(true)),
        ("station", str("ws1/st1")),
        ("phase", str("offered")),
        ("adb", str("connected")),
        ("on", Json::boolean(true)),
        ("tunnels", Json::number(0.0)),
        ("lends", [obj([("station", str("ws1/st1")), ("phase", str("offered")), ("adb", str("connected")), ("tunnels", Json::number(1.0))])]),
        ("grants", [
          obj([("station", str("ws1/st1")), ("id", str("p-long-1")), ("session", str("s-c1")), ("chatTitle", str("键盘升起卡顿排查")), ("reason", str("在开发版里打开对话，让键盘升起再收起，记录每一帧的时间和显示时刻，量完就停")), ("status", str("granted")), ("scope", str("chat")), ("time", obj([("lastUsedAt", stamp_of("3 分钟前"))]))]),
          obj([("station", str("ws1/st1")), ("id", str("p-long-2")), ("session", str("s-c2")), ("chatTitle", str("客户端卡顿排查")), ("reason", str("量整页重搭那一帧实际跑多久，CPU 跑在什么频率，并比较改动前后的差别")), ("status", str("granted")), ("scope", str("chat")), ("time", obj([("lastUsedAt", stamp_of("2 小时前"))]))]),
          obj([("station", str("ws1/st1")), ("id", str("p-long-3")), ("session", str("s-c3")), ("chatTitle", str("检查登录页面")), ("reason", str("检查登录页面")), ("status", str("granted")), ("scope", str("hour"))]),
        ]),
      ])
    // a grant from before the person's own lock: signed by no device on it, so the phone
    // lends nothing on it; no reason given, and its station not lent yet
    "unsigned" =>
      obj([
        ("sharing", Json::boolean(false)),
        ("phase", str("idle")),
        ("on", Json::boolean(true)),
        ("tunnels", Json::number(0.0)),
        ("toConfirm", Json::number(1.0)),
        ("grants", [
          obj([("station", str("ws1/st1")), ("id", str("p-u-1")), ("session", str("s-c1")), ("chatTitle", str("定时 · 每 15 分钟审 mbui 三条线")), ("status", str("granted")), ("scope", str("chat")), ("held", Json::boolean(false))]),
        ]),
      ])
    // settings' 共享调试, its switch on: two chats granted it, one asking; lent to both their stations, Willow's adb
    // holding the phone and the other's waiting to be paired
    "chats" | "chats-off" =>
      obj([
        ("sharing", Json::boolean(true)),
        ("station", str("ws1/st2")),
        ("phase", str("offered")),
        ("adb", str(if fx.motion == 0 { "unpaired" } else { "connected" })),
        ("on", Json::boolean(true)),
        ("tunnels", Json::number(0.0)),
        (
          "lends",
          Json::array([
            obj([("station", str("ws1/st1")), ("phase", str("offered")), ("adb", str("connected")), ("tunnels", Json::number(1.0))]),
            obj([("station", str("ws1/st2")), ("phase", str("offered")), ("adb", str(if fx.motion == 0 { "unpaired" } else { "connected" })), ("tunnels", Json::number(0.0))]),
          ]),
        ),
        (
          "grants",
          Json::array([
            obj([("station", str("ws1/st1")), ("id", str("p-1")), ("reason", str("装上刚编好的测试包，看首屏在折叠屏展开时排得对不对")), ("status", str("granted")), ("scope", str("chat"))]),
            obj([("station", str("ws1/st2")), ("id", str("p-2")), ("reason", str("录一段登录流程的视频")), ("status", str("granted")), ("scope", str("hour"))]),
            obj([("station", str("ws1/st1")), ("id", str("p-3")), ("session", str("s-c1")), ("chatTitle", str("通知权限检查")), ("reason", str("看通知权限弹窗的文案")), ("status", str("pending"))]),
          ]),
        ),
      ])
    _ => obj([("sharing", Json::boolean(false)), ("phase", str("idle")), ("tunnels", Json::number(0.0))])
  }
}

///|
/// MBUI_FIXTURE=newchat-machine: the sessions Willow's machine kept (as the core gives them: the parts of each line
/// apart too), their list open over the new chat: two runtimes, a few folders, still.fail's own among them, one of them
/// already going on in a chat.
pub fn fixture_machine_sessions(core : Core) -> Unit {
  let s = fn(id : String, runtime : String, title : String, where_ : String, day : String, when : String, session : String) {
    let label = if runtime == "claude" { "Claude Code" } else { "Codex" }
    let parts = where_.split("/").to_array()
    obj([
      ("id", str(id)),
      ("runtime", str(runtime)),
      ("title", str(title)),
      ("first", str(title)),
      ("where", str(where_)),
      ("folder", str(parts[parts.length() - 1].to_owned())),
      ("day", str(day)),
      ("when", str(when)),
      ("own", Json::boolean(where_.has_prefix("~/.stillfail/"))),
      ("meta", str(label + " · " + where_)),
      ("session", if session == "" { Json::null() } else { str(session) }),
    ])
  }
  let own = "~/.stillfail/sessions/chat/c-41f2/workspace"
  machine_sessions_asked["ws1/st1"] = true
  machine_sessions["ws1/st1"] = [
    s("m1", "codex", "检查线程并操作应用内浏览器", "~/Documents/GitHub/still.fail", "今天", "3 分钟前", ""),
    s("m2", "codex", "Use your image generation tool to make the app icon", own, "今天", "20 分钟前", ""),
    s("m3", "codex", "[财务] 建立全自动记账系统", "~/Documents/Codex/ledger", "今天", "1 小时前", "s-c2"),
    s("m4", "claude", "整理构建脚本，把 Windows 的打包也接进 CI", "~/Documents/GitHub/still.fail", "今天", "3 小时前", ""),
    s("m5", "codex", "Create PR for airbuild integration with the release workflow", "~/Documents/GitHub/still.fail", "昨天", "22:41", ""),
    s("m6", "claude", "确认沉星之序大地图解密知识锁", "~/Documents/Codex/game", "昨天", "15:02", ""),
    s("m7", "codex", "Use your image generation tool to draw the empty state", own, "昨天", "11:20", ""),
    s("m8", "claude", "Review the onboarding copy", "~/Documents/GitHub/still.fail", "星期二", "18:09", ""),
    s("m9", "codex", "把发票 PDF 按月份归档", "~/Documents/Codex/ledger", "10月20日", "09:31", ""),
  ]
  open_machine_sessions(core, "ws1/st1", "Willow")
}

///|
/// Willow's 备份 row as the core shows it (StationCopies): Cedar and Aspen up to date; `alone`: the only station of its
/// workspace.
fn fixture_copies_row(alone~ : Bool) -> Json {
  let fields : Array[(String, Json)] = [
    ("line", str(if alone { "再加一台 station 就会自动备份" } else { "已备份到 Cedar 和 Aspen · 2 分钟前" })),
    ("level", str(if alone { "amber" } else { "ok" })),
    ("offers", []),
    ("canRestore", Json::boolean(true)),
    ("formerly", []),
  ]
  if !alone {
    fields.push(
      (
        "backup",
        obj([
          ("mode", str("auto")),
          ("stations", []),
          ("acceptOthers", Json::boolean(true)),
          (
            "peers",
            Json::array([
              obj([("station", str("st2")), ("name", str("Cedar")), ("acceptOthers", Json::boolean(true)), ("online", Json::boolean(true))]),
              obj([("station", str("st3")), ("name", str("Aspen")), ("acceptOthers", Json::boolean(true)), ("online", Json::boolean(true))]),
            ]),
          ),
          ("s3", []),
        ]),
      ),
    )
  }
  obj(fields)
}

///|
/// Willow's expanded backup configuration: manual station selection (Cedar selected, Aspen declining, Birch offline)
/// plus a configured Cloudflare R2 target.
fn fixture_copies_config() -> Json {
  obj([
    ("line", str("已备份到 Cedar 和 Cloudflare R2 · 2 分钟前")),
    ("level", str("ok")),
    // (Cedar up to date; Elm with the chats, its first copy of the transcripts still going)
    (
      "keepers",
      Json::array([
        obj([("station", str("st2")), ("name", str("Cedar")), ("line", str("2 分钟前已备份到最新")), ("level", str("ok"))]),
        obj([
          ("station", str("st5")),
          ("name", str("Elm")),
          ("line", str("聊天已备份到最新（1 分钟前），会话记录还差 33012 个文件")),
          ("level", str("ok")),
        ]),
      ]),
    ),
    ("offers", []),
    ("canRestore", Json::boolean(true)),
    ("formerly", []),
    (
      "backup",
      obj([
        ("mode", str("manual")),
        ("stations", Json::array([str("st2")])),
        ("acceptOthers", Json::boolean(true)),
        ("settingsSummary", str("手动互备：Cedar · Cloudflare R2 · 接收互备")),
        (
          "peers",
          Json::array([
            obj([("station", str("st2")), ("name", str("Cedar")), ("acceptOthers", Json::boolean(true)), ("online", Json::boolean(true))]),
            obj([("station", str("st3")), ("name", str("Aspen")), ("acceptOthers", Json::boolean(false)), ("online", Json::boolean(true))]),
            obj([("station", str("st4")), ("name", str("Birch")), ("acceptOthers", Json::boolean(true)), ("online", Json::boolean(false))]),
          ]),
        ),
        (
          "s3",
          Json::array([
            obj([
              ("id", str("r2-1")),
              ("name", str("Cloudflare R2")),
              ("endpoint", str("https://acct.r2.cloudflarestorage.com")),
              ("region", str("auto")),
              ("bucket", str("stillfail-backups")),
              ("prefix", str("stillfail-backup")),
              ("forcePathStyle", Json::boolean(true)),
              ("accessKeyMask", str("AKIA****1234")),
              ("keyFingerprint", str("ab12cd34")),
              ("includeTranscripts", Json::boolean(true)),
              ("to", Json::number(7.0)),
              ("at", Json::number(480000.0)),
              ("error", Json::null()),
              ("reason", Json::null()),
              ("statusLine", str("已同步 · 2 分钟前")),
              ("level", str("ok")),
            ]),
          ]),
        ),
      ]),
    ),
  ])
}

///|
/// Maple's backup configuration in `settings-backup`: automatic 2-station backup, accepting others, no S3.
fn fixture_copies_maple() -> Json {
  obj([
    ("line", str("已备份到 Willow · 5 分钟前")),
    ("level", str("ok")),
    ("offers", []),
    ("canRestore", Json::boolean(true)),
    ("formerly", []),
    (
      "backup",
      obj([
        ("mode", str("auto")),
        ("stations", Json::array([])),
        ("acceptOthers", Json::boolean(true)),
        ("settingsSummary", str("自动互备（2 台） · 接收互备")),
        (
          "peers",
          Json::array([
            obj([("station", str("st1")), ("name", str("Willow")), ("acceptOthers", Json::boolean(true)), ("online", Json::boolean(true))]),
          ]),
        ),
        ("s3", Json::array([])),
      ]),
    ),
  ])
}

///|
/// Typical `copies.history` response for fixture previews and tests: a run of syncs to Cedar that went well, 2 more
/// (R2 + peer) and 1 failed S3 sync.
fn fixture_copies_history() -> Json {
  obj([
    (
      "records",
      Json::array([
        // (Cedar brought level at every pass: a run of syncs that went well, a station from before saying each)
        obj([
          ("id", str("rec-c0")),
          ("at", Json::number(1795358400000.0)),
          ("kind", str("sync")),
          ("targetKind", str("station")),
          ("target", str("st2")),
          ("targetName", str("Cedar")),
          ("status", str("ok")),
          ("chats", Json::number(42.0)),
          ("messages", Json::number(1280.0)),
          ("batches", Json::number(2.0)),
          ("bytes", Json::number(18400000.0)),
          ("reason", Json::null()),
          ("error", Json::null()),
        ]),
        obj([
          ("id", str("rec-c1")),
          ("at", Json::number(1795358387000.0)),
          ("kind", str("sync")),
          ("targetKind", str("station")),
          ("target", str("st2")),
          ("targetName", str("Cedar")),
          ("status", str("ok")),
          ("chats", Json::number(42.0)),
          ("messages", Json::number(1280.0)),
          ("batches", Json::number(3.0)),
          ("bytes", Json::number(18400000.0)),
          ("reason", Json::null()),
          ("error", Json::null()),
        ]),
        obj([
          ("id", str("rec-c2")),
          ("at", Json::number(1795358374000.0)),
          ("kind", str("sync")),
          ("targetKind", str("station")),
          ("target", str("st2")),
          ("targetName", str("Cedar")),
          ("status", str("ok")),
          ("chats", Json::number(42.0)),
          ("messages", Json::number(1280.0)),
          ("batches", Json::number(2.0)),
          ("bytes", Json::number(18400000.0)),
          ("reason", Json::null()),
          ("error", Json::null()),
        ]),
        obj([
          ("id", str("rec-c3")),
          ("at", Json::number(1795358361000.0)),
          ("kind", str("sync")),
          ("targetKind", str("station")),
          ("target", str("st2")),
          ("targetName", str("Cedar")),
          ("status", str("ok")),
          ("chats", Json::number(42.0)),
          ("messages", Json::number(1280.0)),
          ("batches", Json::number(3.0)),
          ("bytes", Json::number(18400000.0)),
          ("reason", Json::null()),
          ("error", Json::null()),
        ]),
        obj([
          ("id", str("rec-c4")),
          ("at", Json::number(1795358348000.0)),
          ("kind", str("sync")),
          ("targetKind", str("station")),
          ("target", str("st2")),
          ("targetName", str("Cedar")),
          ("status", str("ok")),
          ("chats", Json::number(42.0)),
          ("messages", Json::number(1280.0)),
          ("batches", Json::number(2.0)),
          ("bytes", Json::number(18400000.0)),
          ("reason", Json::null()),
          ("error", Json::null()),
        ]),
        obj([
          ("id", str("rec-1")),
          ("at", Json::number(1795357800000.0)),
          ("kind", str("sync")),
          ("targetKind", str("s3")),
          ("target", str("r2-1")),
          ("targetName", str("Cloudflare R2")),
          ("status", str("ok")),
          ("chats", Json::number(42.0)),
          ("messages", Json::number(1280.0)),
          ("batches", Json::number(3.0)),
          ("bytes", Json::number(18400000.0)),
          ("reason", Json::null()),
          ("error", Json::null()),
        ]),
        obj([
          ("id", str("rec-2")),
          ("at", Json::number(1795357200000.0)),
          ("kind", str("sync")),
          ("targetKind", str("station")),
          ("target", str("st2")),
          ("targetName", str("Cedar")),
          ("status", str("ok")),
          ("chats", Json::number(42.0)),
          ("messages", Json::number(1280.0)),
          ("batches", Json::number(2.0)),
          ("bytes", Json::number(18400000.0)),
          ("reason", Json::null()),
          ("error", Json::null()),
        ]),
        obj([
          ("id", str("rec-3")),
          ("at", Json::number(1795353600000.0)),
          ("kind", str("sync")),
          ("targetKind", str("s3")),
          ("target", str("s3-2")),
          ("targetName", str("AWS S3")),
          ("status", str("error")),
          ("chats", Json::number(0.0)),
          ("messages", Json::number(0.0)),
          ("batches", Json::number(0.0)),
          ("bytes", Json::number(0.0)),
          ("reason", str("offline")),
          ("error", str("ECONNREFUSED")),
        ]),
      ]),
    ),
  ])
}

///|
/// A new empty station discovering a restorable backup stored in Cloudflare R2.
fn fixture_copies_restore_s3() -> Json {
  obj([
    ("line", str("未配置备份目标")),
    ("level", str("amber")),
    (
      "offers",
      [
        obj([
          ("station", str("st9")),
          ("gen", str("1-abcdef01")),
          ("name", str("Old Mac")),
          ("line", str("Old Mac 的 128 个聊天 · 来自 Cloudflare R2")),
          ("fromStation", Json::null()),
          ("fromS3", str("r2-1")),
          ("fromName", str("Cloudflare R2")),
          ("busy", Json::boolean(false)),
        ]),
      ],
    ),
    ("canRestore", Json::boolean(true)),
    ("formerly", []),
  ])
}

///|
/// A new station's 备份 (StationCopies): no chat of its own yet, Old Mac's backup (at Cedar) to restore; `under_way`:
/// it being restored, how in its row (恢复到这台 waits), else 恢复到这台 live.
fn fixture_copies_restore(under_way~ : Bool, name~ : String) -> Json {
  obj([
    ("line", str("还没备份好 · Cedar 连不上")),
    ("level", str("amber")),
    (
      "offers",
      [
        obj([
          ("station", str("st9")),
          ("gen", str("1-abcdef01")),
          ("name", str(name)),
          ("line", str(if under_way { "正在恢复：37 / 412 个文件" } else { name + " 的 128 个聊天" })),
          ("fromStation", str("st2")),
          ("busy", Json::boolean(under_way)),
        ]),
      ],
    ),
    ("canRestore", Json::boolean(!under_way)),
    ("formerly", []),
  ])
}

///|
/// The station after the restart that took Old Mac's chats in: what came of it, in its 备份 row until a station is up to
/// date with it.
fn fixture_copies_restored() -> Json {
  obj([
    ("line", str("已恢复 Old Mac 的 128 个聊天 · 2 分钟前")),
    ("level", str("amber")),
    ("offers", []),
    ("canRestore", Json::boolean(true)),
    ("formerly", [str("st9")]),
  ])
}

///|
/// Willow's copies (StationCopies) as it is retired, by `step` (the fixture mode's end), in the core's words: "" none
/// under way, it may be retired; "sending" its files going to Maple, "quiet" its chats paused, both let go of;
/// "failed" Maple out of reach as it took them, tried again or let go of; "accounts" its accounts moving; "done" all
/// on Maple, "done-left" with two accounts left behind; "taking": a station that takes two retired ones' chats in, Old
/// Mac's working directories made again and Birch's failed.
fn fixture_copies_retire(step : String) -> Json {
  let to = "Maple"
  let keys = ["sending", "quiet", "handing", "accounts", "connects"]
  // (`sent`: all of it there, the chats still working, 暂停聊天 not yet, waiting for the hand-over's confirmation;
  // `sent-failed`: back there after a hand-over failed, that row saying why and that the chats work again: as the
  // core's copies.ts says)
  let sent = step == "sent" || step == "sent-failed"
  let at = match step {
    "sending" => 0
    "quiet" | "sent" | "sent-failed" => 1
    "failed" => 2
    "accounts" => 3
    _ => 5
  }
  let steps = keys.mapi(fn(i, key) {
    let state = if i < at {
      "done"
    } else if i == at {
      if step == "failed" || step == "sent-failed" { "failed" } else if step == "sent" { "todo" } else { "now" }
    } else {
      "todo"
    }
    let note = match (state, key) {
      ("todo", _) if step == "sent" && i == at => tr("core-views.copies.retire.waiting")
      ("now", "sending") => fill("core-views.copies.retire.sent", [("done", "1.5 GB"), ("total", "3.2 GB")])
      ("failed", _) if step == "sent-failed" =>
        fill("core-views.copies.retire.resumed", [("why", fill("core-views.copies.retire.why.failed", [("name", to)]))])
      ("failed", _) => fill("core-views.copies.retire.why.offline", [("name", to)])
      _ => ""
    }
    obj([
      ("key", str(key)),
      ("label", str(fill("core-views.copies.retire.step." + key, [("name", to)]))),
      ("state", str(state)),
      ("note", str(note)),
    ])
  })
  let left = if step == "done-left" {
    obj([
      ("label", str(fill("core-views.copies.retire.left", [("n", "2")]))),
      (
        "note",
        str(fill("core-views.copies.retire.leftNote", [("names", "cuesurf5@proton.me" + tr("core-views.copies.andLast") + "Kimi Code key"), ("name", to)])),
      ),
    ])
  } else {
    Json::null()
  }
  let r = if step == "" || step == "taking" {
    Json::null()
  } else {
    obj([
      ("steps", Json::array(steps)),
      ("left", left),
      ("done", Json::boolean(at == 5)),
      ("stopped", Json::boolean(at > 0 && at < 5 && !sent)),
      ("to", str("st2")),
      ("toName", str(to)),
      ("cancellable", Json::boolean(at <= 2)),
      ("retriable", Json::boolean(step == "failed" || step == "sent-failed")),
    ])
  }
  let taking = fn(origin : String, name : String, line : String, level : String) {
    obj([("origin", str(origin)), ("name", str(name)), ("line", str(line)), ("level", str(level))])
  }
  obj([
    ("line", str("已备份到 Cedar 和 Aspen · 2 分钟前")),
    ("level", str("ok")),
    ("offers", []),
    ("canRestore", Json::boolean(true)),
    ("formerly", []),
    ("canRetire", Json::boolean(step == "" || step == "taking")),
    ("retire", r),
    (
      "taking",
      if step == "taking" {
        [
          taking("st9", "Old Mac", tr("core-views.copies.taking.gits"), "ok"),
          taking("st8", "Birch", fill("core-views.copies.taking.failed", [("why", tr("core-views.copies.why.error"))]), "amber"),
        ]
      } else {
        []
      },
    ),
  ])
}

///|
/// What retiring Willow would take along and leave (RetirePreview, `copies.retirePreview`), as a station of real use
/// says it: 594 chats, 525 of them archived; five connects; nine accounts, its home's, else staying; six tasks and
/// services running; three chats whose folders are not on it.
pub fn fixture_retire_preview() -> Json {
  let things = fn(names : Array[String]) {
    Json::array(names.mapi(fn(i, n) { obj([("id", str("t" + i.to_string())), ("name", str(n))]) }))
  }
  let accounts = [
    "cuesurf5@proton.me", "lin@example.com", "studio-ci@cue.surf", "Kimi Code key", "OpenRouter (team)", "jev-decisions",
    "zhou.design@example.com", "Anthropic API · nightly", "Cursor (Lin)",
  ]
  obj([
    ("home", Json::boolean(fx.retire_home)),
    ("chats", Json::number(594.0)),
    ("archived", Json::number(525.0)),
    ("connects", things(["发布助手 · Slack", "飞书助手", "Comma 助手", "值班机器人 · Slack", "Release notes · Slack"])),
    ("accounts", if fx.retire_home { things(accounts) } else { [] }),
    ("accountsStay", if fx.retire_home { [] } else { things(accounts) }),
    (
      "jobs",
      Json::array(
        ["pnpm dev", "station tests", "preview :5173", "storybook", "ollama serve", "nightly build"].map(fn(n) {
          obj([("name", str(n)), ("session", str("s-c1"))])
        }),
      ),
    ),
    ("outside", Json::number(3.0)),
  ])
}

///|
/// The calls of Willow's retirement the made-up core was asked, as it was asked them (name and params), each answered
/// only where what it was given is what the core needs (the station's address; for `copies.retire` a station of the
/// workspace up and not Willow): a test reads what a page asked.
// kept across runs: emptied by fixture_reset
pub let fixture_retire_asked : Array[(String, Json)] = []

///|
/// A `copies.retire*` call answered as the core would, Willow's copies moved on as its station would say them next;
/// one given what the core would refuse refused in its words. None: not one of them.
fn retire_fixture_call(name : String, p : Json?) -> Result[Json, Json]? {
  if name == "copies.retirePreview" {
    fixture_retire_asked.push((name, p.unwrap_or(Json::null())))
    return Some(if text(p, "station") == "ws1/st1" { Ok(fixture_retire_preview()) } else { Err(obj([("code", str("invalid")), ("message", str("missing station"))])) })
  }
  guard name == "copies.retire" || name == "copies.retireCancel" || name == "copies.retireAgain" else { return None }
  fixture_retire_asked.push((name, p.unwrap_or(Json::null())))
  let refused = fn(why : String) { Some(Err(obj([("code", str("invalid")), ("message", str(why))]))) }
  guard text(p, "station") == "ws1/st1" else { return refused("missing station") }
  match name {
    "copies.retire" => {
      let to = text(p, "to")
      let up = (to == "st2" && fx.retire_others >= 1) || (to == "st3" && fx.retire_others >= 2)
      guard up else { return refused("no such station up: " + to) }
      fx.copies = Some(fixture_copies_retire("sending"))
    }
    "copies.retireCancel" => fx.copies = Some(fixture_copies_retire(""))
    _ => fx.copies = Some(fixture_copies_retire("quiet"))
  }
  fx_changed()
  Some(Ok(obj([])))
}

///|
/// The lock's changes made here that no station took yet, as the core's `lock` topic has them (lock-pending.ts
/// `pendingRow`), oldest first: a device of a long name taken out, waiting for Willow and Maple; Ana's role, changed
/// meanwhile on another device; a web page's renewal refused, in the station's words.
fn fx_pending_rows() -> Array[Json] {
  let all = [
    obj([
      ("id", str("p1")),
      ("text", str("移除设备 林的 MacBook Pro（2024 款 · 公司配的那台 · 放在办公室）：已记下，等 Willow、Maple 上线后生效")),
      ("state", str("waiting")),
      ("stations", [str("Willow"), str("Maple")]),
    ]),
    obj([
      ("id", str("p2")),
      ("text", str("把 Ana 改为成员：没有生效。「Ana」在这之后又被改过，请查看现在的状态，仍然需要的话再操作一次")),
      ("state", str("failed")),
      ("stations", []),
      ("dismissText", str("知道了")),
    ]),
    obj([
      ("id", str("p3")),
      ("text", str("续期 Chrome · macOS：没有生效。请查看现在的状态，仍然需要的话再操作一次")),
      ("state", str("failed")),
      ("stations", []),
      ("why", str("这台设备已不在安全模式中")),
      ("dismissText", str("知道了")),
    ]),
  ]
  all.filter(fn(r) { fx.pending.contains(text(Some(r), "id")) })
}

///|
/// What the upgrade of safe mode waits for in the state `fx.upgrade` names, as the core's `upgrade` says it (views/lock.ts
/// `upgradeOf`): its title, its lines (a sentence each, what it is of, a station's address and whether this person may
/// update it from here, or how its update goes), or its button where only the person's ask is lacking.
fn fx_upgrade() -> Json? {
  let station = fn(name : String, at : String, can : Bool) -> Json {
    obj(
      [
        ("text", str("等待 station \{name}：请将它更新到最新版本并保持在线；已不再使用的话，请在它的页面上选择「从 workspace 移除」")),
        ("of", str("station")),
        ("station", str(at)),
      ] +
      (if can { [("canUpdate", Json::boolean(true))] } else { [] }),
    )
  }
  let person = fn(name : String) -> Json {
    obj([("text", str("等待 \{name}：请其在自己的受信任设备上将 still.fail 更新到最新版本并打开一次")), ("of", str("member"))])
  }
  let device = fn(name : String, device : String) -> Json {
    obj([
      ("text", str("等待 \{name} 的设备「\{device}」：请其在另一台受信任设备上打开「设置 › 安全」并完成一次验证；该设备已不再使用的话，请其将它移除")),
      ("of", str("device")),
    ])
  }
  let lines : Array[Json] = match fx.upgrade {
    "station" => [station("Maple", "ws1/st2", true)]
    "station-not" => [station("Maple", "ws1/st2", false)]
    "member" => [person("Ana")]
    "device" => [device("Ana", "Pixel 8 · still.fail Android")]
    "many" =>
      [
        station("Maple", "ws1/st2", true),
        person("Ana"),
        person("ben@example.com"),
        device("Ana", "Pixel 8 · still.fail Android"),
        device("周宁", "周宁的 MacBook Air · still.fail 桌面版"),
        station("Cedar", "ws1/st3", false),
        obj([("text", str("以及另外 3 项")), ("of", str("more"))]),
      ]
    "other" =>
      [
        obj([
          ("text", str("等待「个人」的 station 家里的 mini：请将它更新到最新版本并保持在线；已不再使用的话，请在它的页面上选择「从 workspace 移除」")),
          ("of", str("station")),
          ("station", str("ws2/st9")),
          ("canUpdate", Json::boolean(true)),
        ]),
      ]
    "updating" =>
      [
        obj([
          ("text", str("等待 station Maple：请将它更新到最新版本并保持在线；已不再使用的话，请在它的页面上选择「从 workspace 移除」")),
          ("of", str("station")),
          ("station", str("ws1/st2")),
          ("updating", Json::boolean(true)),
          ("percent", Json::number(40.0)),
        ]),
      ]
    _ => return None
  }
  Some(
    obj([("titleText", str("安全模式有一项升级尚未完成")), ("lines", Json::array(lines))]),
  )
}

///|
/// The `lock` topic's field of the upgrade, while there is one.
fn fx_upgrade_fields() -> Array[(String, Json)] {
  match fx_upgrade() {
    Some(u) => [("upgrade", u)]
    None => []
  }
}

///|
/// The `lock` topic's fields of how an upgraded workspace stands (`fx.lock_case`): this device to verify once (`me`'s
/// `stateText`, `confirmText`), on or off by another person alone (`rootText`), off by this person (`onAgainText`).
fn fx_lock_case_fields() -> Array[(String, Json)] {
  let root = "安全模式由 Ana 开启，只有其本人可以关闭或重新开启。其本人无法操作时，可在 station 所在的电脑上运行 stillfail lock reset"
  match fx.lock_case {
    "confirm" => [("me", obj([("stateText", str("此设备需完成一次验证后才能成为受信任设备")), ("confirmText", str("验证"))]))]
    "root" | "root-off" => [("rootText", str(root))]
    "again" => [("onAgainText", str("重新开启安全模式"))]
    // (confirmed and signing here; its own lock to join, the ask as the page that waits has it, a code typed as the
    // made-up core takes it: fixture_pair_typed)
    "own-outside" => {
      let pair = match fx.pair_flow {
        "checking" => obj([("state", str("checking")), ("left", Json::number(3.0))])
        "confirming" => obj([("state", str("checking")), ("left", Json::number(3.0)), ("checkingText", str("请在显示安全码的设备上完成身份验证"))])
        "retry" => obj([("state", str("wrong")), ("left", Json::number(3.0)), ("error", str(fixture_pair_retry)), ("untilText", str("14:05 前有效"))])
        "done" => obj([("state", str("done"))])
        _ => Json::null()
      }
      let me : Array[(String, Json)] = [
        ("device", str("d1")),
        ("code", str("Q4K-7PM")),
        ("kind", str("app")),
        ("confirmed", Json::boolean(true)),
        ("waiting", Json::boolean(false)),
        ("unsigned", Json::boolean(false)),
        ("pair", pair),
      ]
      if fx.pair_flow != "done" {
        me.push(("ownLock", Json::boolean(true)))
        me.push(("restartText", str("我的其它设备都不在了")))
        me.push(("restartNoteText", str("选「我的其它设备都不在了」后，这台设备会成为你唯一的受信任设备；已开启安全模式的 workspace 需先将你移出再重新添加，你的其它设备也需重新获批。")))
      }
      [("me", obj(me))]
    }
    _ => []
  }
}

///|
/// The `lock` topic's fields of what is pending: the rows, and their heading while there are any.
fn fx_pending_fields() -> Array[(String, Json)] {
  let rows = fx_pending_rows()
  if rows.is_empty() {
    [("pending", Json::array(rows))]
  } else {
    [("pending", Json::array(rows)), ("pendingText", str("以下改动还没有生效"))]
  }
}

///|
/// What is pending made `ids` (of settings-security-pending's), as the core says it changed: a station took one, or one
/// was dropped.
pub fn fixture_pending_set(ids : Array[String]) -> Unit {
  fx.pending.clear()
  fx.pending.append(ids)
  fx_changed()
}

///|
/// Why the list's 多选 cannot take the made-up account `pv` (views/profiles.ts `batchWhy`): another station's copy, or
/// its kind of login that cannot be lent yet; "" where it can.
fn fx_batch_why(pv : Json?) -> String {
  if text(field(pv, "share"), "role") == "user" {
    "borrowed"
  } else if !(field(pv, "share") is Some(Object(_))) && field(pv, "shareable") is Some(False) {
    "unshareable"
  } else {
    ""
  }
}

///|
/// What 公司 Claude's share says of following the workspace's whitelist (the station's profileView): its rule, and the
/// stations it makes now (Willow and Maple, on it).
fn fx_cc_follows() -> Array[(String, Json)] {
  if fx.cc_follows {
    [("allowAuto", Json::boolean(true)), ("allow", ["st1", "st2"])]
  } else {
    []
  }
}
