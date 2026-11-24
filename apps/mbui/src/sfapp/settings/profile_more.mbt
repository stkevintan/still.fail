// A profile's page past its check, allowance and models: its "…" (renaming, checking,
// deleting or stopping it), signing its subscription in (SignIn, LoginSteps), its sharing with the workspace's other
// stations (ShareSection) and the workspaces it serves (WorkspacesSection), how it runs (default Fast, commands put
// to the background), its key or its variables changed, what to do when it is in trouble (ProfileRecovery); which of the
// machines' own logins are offered as profiles (profiles_offers); and where something is added, a station picked.

///|
/// A machine login's runtime by name (RUNTIME_LABEL).
pub fn runtime_label(rt : String) -> String {
  match rt {
    "claude" => "Claude Code"
    "codex" => "Codex"
    "dsh" => "DeepSeek Harness"
    "grok" => "Grok Build"
    "cursor" => "Cursor"
    "devin" => "Devin"
    "hermes" => "Hermes Agent"
    "agy" => "Antigravity CLI"
    "pi" => "Pi"
    "copilot" => "GitHub Copilot"
    _ => rt
  }
}

///|
/// A runtime's short label in capsules and compact pills (RUNTIME_SHORT).
pub fn runtime_short(rt : String) -> String {
  match rt {
    "claude" => "CC"
    "codex" => "Codex"
    "dsh" => "DSH"
    "grok" => "GROK"
    "cursor" => "Cursor"
    "devin" => "Devin"
    "hermes" => "Hermes"
    "agy" => "AGY"
    "pi" => "Pi"
    "copilot" => "Copilot"
    _ => rt
  }
}

///|
/// The online stations of the workspace, as `stations` has them.
fn online_stations(core : Core, here : Here, only? : String = "") -> Array[Json] {
  match stations_of(core, here).value {
    Some(Array(a)) =>
      a.filter(fn(s) { flag(Some(s), "online") && (only == "" || text(Some(s), "station") == only) })
    _ => []
  }
}

///|
/// The machine logins offered on the workspace's stations, as its `profiles` says them (`machineLogins`: each station
/// up whose overview is read and offers one, in the stations' order, with its name and those logins), the list the
/// Profile place opens on: nothing asked of each station for them.
pub fn profiles_offers(profiles : Json?) -> Array[(Json, Array[Json])] {
  items(profiles, "machineLogins").map(fn(e) {
    let e = Some(e)
    (obj([("station", str(text(e, "station"))), ("name", str(text(e, "stationName")))]), items(e, "logins"))
  })
}

///|
/// The machine logins station `station` offers, as the workspace's `profiles` says them (profiles_offers).
pub fn profiles_offers_of(profiles : Json?, station : String) -> Array[Json] {
  match profiles_offers(profiles).iter().find_first(fn(o) { text(Some(o.0), "station") == station }) {
    Some(o) => o.1
    None => []
  }
}

///|
/// Where something is added: one of the stations online picked (openPickStation), the library's pick opened `from`
/// what was pressed (a sheet on Small, else beside it), what it is for its title.
fn open_pick_station(stations : Array[Json], go : (String) -> Unit, from~ : @sf.Beside) -> Unit {
  // (each by its mark, as the sidebar and a chat's bar have it)
  let choices = stations.map(fn(s) {
    let sv = Some(s)
    @sf.choice(text(sv, "station"), text(sv, "name"), mark=OfStation(text(sv, "emoji"), text(sv, "icon"), false, fn() { @sf.theme().p.text }))
  })
  @sf.pick(tr("android-settings.pickStation"), choices, "", go, from~)
}

///|
/// What a sign-in's sheet keeps while it is up: the code typed (by the sign-in's id), whether its link was copied, the
/// command to run by hand shown.
priv struct LoginState {
  copied : Map[String, Bool]
  manual : Map[String, Bool]
  error : Map[String, String]
  /// the sign-in's state last seen (a toast as it comes to done)
  seen : Map[String, String]
}

///|
let login_state : LoginState = { copied: {}, manual: {}, error: {}, seen: {} }

