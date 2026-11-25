// A station's own page made once as nodes of the window's tree, laid out by the width its frame
// gives it (page_node): its head of its own (its mark and name, which its managers change where they are, how it is and
// what it is, what is wrong with it, trying it again while away, 启动 where it is this machine's and stopped, its ⋯),
// then its parts one at a time as its choice says: how it is and what runs on it, its 进程, what it is let do and set
// to, its software and the machine. Everything said is the core's, each part bound to what it says now: the machine's
// figures (station_cards.mbt), its 进程 (resources_node.mbt), a login's card under way (login_card.mbt's node); what it
// works out apart from its nodes, station_page.mbt. Every frame makes it so, and a chat's side panel as a station's tab
// (sfdesk panel_node.mbt side_station_node).

///|
/// Station `address`'s page (StationSettings, StationScreen) made once in node `v`, as wide as `width` gives it, in the
/// frame it is given: while the stations are read, or where it is gone, a made-up one's in its bones;
/// made again as the viewer comes to manage it or not. `stint`: the page's time on top (what a picture put up for its
/// mark is asked for on). Its parts' choice pressed, what the part pressed reads as it is first drawn is asked of `src`
/// (station_part_asks) and the page stays as it is, the choice showing what was pressed; the part is switched to whole in
/// the frame that is answered, in the press's where it is already (sfbase's switch_answered): never a part's rows come one
/// by one as the core answers them. What it reads by (@settings.station_parts: the part shown) changes only then; another
/// part pressed, or the page left, gives the wait up, the choice back on what is shown.
pub fn station_node(
  v : @view.View,
  core : Core,
  src : Source,
  here : () -> Here,
  address : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
  stint? : () -> Int = fn() { 0 },
) -> Unit {
  // (that station alone, whole: none while the stations are not known, null where the workspace has no such station)
  let listed = fn() {
    match @settings.station_read(core, here(), address).value {
      Some(Object(_)) => Some(true)
      Some(_) => Some(false)
      None => None
    }
  }
  let manager = fn() {
    let r = role_of(core, here())
    r == "owner" || r == "admin"
  }
  // (what is said of what the pointer rests on: the frame's, else drawn over the page in the page's own node, each tip
  // its holder over all of it there: history_node's)
  let tips = match tips {
    Some(t) => t
    None => @sf.TipLayer::new(fn() { Some(v) })
  }
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  // (one that only runs tasks is no station this device is linked to: its own page, station_rig.mbt)
  let rig = fn() { @settings.rig_at(core, here(), address) }
  v.pick(fn() { (if rig() is Some(_) { None } else { listed() }, listed() == Some(true) && manager(), rig() is Some(_)) }, fn(p, k) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    if k.2 {
      rig_station_node(p, core, here, address, rig, on_back, frame, said, width, tips)
      return
    }
    match k.0 {
      Some(true) =>
        station_view_node(p, core, src, here, fn() { @settings.station_of(core, here(), address) }, k.1, None, on_back, frame, said, width, tips, stint)
      // (while they are read: a made-up one's in its bones, waiting on them; removed, or a link from before, the same,
      // waiting on nothing)
      found => {
        let wait = if found is None { @sf.t("common.readingStations") } else { "" }
        let sample = station_sample()
        station_view_node(p, core.quiet(), src, here, fn() { Some(sample) }, false, Some(wait), on_back, frame, said, width, tips, stint)
      }
    }
  })
}

///|
/// A station's page while the workspace's stations are read, none picked yet (the stations' place in the wide frame):
/// a made-up one's in its bones, waiting on them, as station_node's.
pub fn stations_reading_node(
  v : @view.View,
  core : Core,
  src : Source,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let tips = match tips {
    Some(t) => t
    None => @sf.TipLayer::new(fn() { Some(v) })
  }
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  let sample = station_sample()
  station_view_node(v, core.quiet(), src, here, fn() { Some(sample) }, false, Some(@sf.t("common.readingStations")), on_back, frame, said, width, tips, fn() {
    0
  })
}

///|
/// Station `s`'s page: its head, then its parts one at a time. `bones`: all of it in its bones,
/// waiting on what it says (its title the frame's).
fn station_view_node(
  p : @view.View,
  core : Core,
  src : Source,
  here : () -> Here,
  s : () -> Json?,
  manager : Bool,
  bones : String?,
  on_back : () -> Unit,
  frame : () -> PageFrame,
  said : ((@sf.PageSaid) -> Unit)?,
  width : (() -> Double)?,
  tips : @sf.TipLayer,
  stint : () -> Int,
) -> Unit {
  let address = text(@signals.untracked(s), "station")
  // (its 进程 as its blocks read it, a row of its table a block: read only as one is made)
  let rs = rs_table_of(core, here, address)
  // (what the host says of the station here, as it said it last: a signal of that input, read again every few seconds
  // from when it is made, while this page is this machine's station's: it starts, stops and updates on its own time)
  let host : @signals.Signal[String] = @signals.signal(
    if address == this_machine() { @hostapi.app_said("local_station") } else { "" },
    same=fn(a, b) { a == b },
  )
  if bones is None && address == this_machine() {
    fn again(at : Double) -> Unit {
      p.at_moment(at + @settings.local_read_ms, later=true, fn() {
        let said = @hostapi.app_said("local_station")
        host.set(said)
        @settings.local_station_heard(said)
        again(at + @settings.local_read_ms)
      })
      |> ignore
    }
    again(p.logic_at())
  }
  // (the part shown, by station: the settings' own, which a login's card also moves to 设置)
  let part = fn() {
    match @settings.station_parts.get(address) {
      Some(p) if station_part_names.contains(p) => p
      _ => "overview"
    }
  }
  // (a part pressed and what waits for what it reads: one at a time. Pressed, the choice shows it; what is shown is
  // `part`'s till what it reads is answered, then switched to it whole: station_node's)
  let pressed : @signals.Signal[String?] = @signals.signal(None)
  let waiting : Ref[@sfbase.PressWait?] = Ref(None)
  let press = fn(to : String) {
    @signals.untracked(fn() {
      guard pressed.get() != Some(to) else { return }
      // (the one pressed before: waited for no more, the choice back on what is shown)
      match waiting.val {
        Some(w) => {
          waiting.val = None
          w.give_up()
        }
        None => ()
      }
      if to == part() {
        pressed.set(None)
        return
      }
      pressed.set(Some(to))
      // (in its bones nothing is read: switched at once)
      let asks = if bones is None { station_part_asks(core, here(), address, s(), manager, to) } else { [] }
      let w = @sfbase.switch_answered(
        src,
        asks,
        station_shown_at(address),
        then=station_part_then(address, @signals.untracked(s), to),
        fn() {
          @settings.station_parts[address] = to
          pressed.set(None)
        },
        let_go=fn() {
          if pressed.untracked() == Some(to) {
            pressed.set(None)
          }
        },
      )
      if w.waiting() {
        waiting.val = Some(w)
      }
    })
  }
  let chosen = fn() {
    match pressed.get() {
      Some(p) => p
      None => part()
    }
  }
  // (what its blocks are worked out of: the station as their keys read it, so a change of what no key reads runs none
  // of what reads them; and the blocks worked out once, told only as one comes, goes or moves)
  // (and the `beta` features it runs: its terminals' rows are keys of its overview's parts)
  let keyed = station_narrowed(s, ["copies", "drive", "permissions", "agentEnv", "search", "diagnostics", "elevation", "screenService", "autoChats", "features"])
  let blocks_now = @signals.computed(fn(_) {
    let s = keyed
    // (being retired, or taking a retired one's chats in: 迁移 first, over its parts, whichever is shown; or something
    // of it moved to another station, moving, stopped or failed: station_move_node.mbt's; whether or not the station
    // offers moving now, a stable one that never moved having none)
    let out = if station_moving_shown(s()) {
      ["moving", "parts"]
    } else if flag(s(), "online") && (core.move_on)() && @settings.move_shown(core, address) {
      ["move", "parts"]
    } else {
      ["parts"]
    }
    out.append(
      match part() {
        // (its head, each row of its table, how it is read: a block each; in its bones its head alone)
        "processes" =>
          if bones is None {
            ["processes"] + rs_block_keys(rs, flag(s(), "online") || (rs.state)() == 0)
          } else {
            ["processes"]
          }
        "settings" => station_settings_keys(s(), manager, (core.workspaces_on)())
        _ => station_overview_keys(core, here, s())
      },
    )
    out
  })
  let blocks = fn() { blocks_now.get() }
  // (what most parts read of it: all it says of itself, of its overview only the `beta` features it runs (its terminals),
  // whether it has a machine)
  let top = station_narrowed(s, ["features"])
  let block = fn(b : @view.View, key : String) {
    match key {
      "parts" => station_parts_node(b, chosen, press)
      "diag" => station_diag_node(b, core, address, fn() { local_stopped_in(address, host.get()) })
      "resources" =>
        station_resources_node(b, core, src, here, station_narrowed(s, ["processes", "processesText"], host=true), fn() {
          press("processes")
        })
      k if k == "allScreens" || k.has_prefix("allScreens/") => all_screens_block(b, core, here, top, k)
      "userPages" => station_user_pages_node(b, core, here, top)
      "agentPages" => station_agent_pages_node(b, core, here, top)
      "screens" => station_screens_node(b, core, here, top)
      "profiles" => station_profiles_node(b, core, here, top)
      "connects" => station_connects_node(b, core, station_narrowed(s, ["connects"]))
      "drive" => station_drive_node(b, station_narrowed(s, ["drive"]))
      // its devices, and adding one: any member but one who only reads (a whole station's are every chat's); read-only while offline
      "devices" => {
        let id = text(@signals.untracked(s), "id")
        @settings.station_devices_node(b, core, here, id, false, fn() {
          let role = text(workspace_view(core, here()).value, "role")
          flag(top(), "online") && role != "" && role != "viewer"
        })
      }
      "more" => station_more_node(b, core, address)
      "processes" => station_processes_node(b, core, here, station_narrowed(s, ["processesText"]), if bones is None { Some(rs) } else { None })
      k if k.has_prefix("processes/") => rs_block_node(b, core, address, rs, k)
      "offline" =>
        b.box(fn(n) {
          @sf.style_node(n, fn() { st_offline_note })
          @sf.page_note_node(n, fn() { @sf.t("web-pages.stations.settingsOffline") })
        })
        |> ignore
      "system" =>
        station_system_node(b, core, address, station_narrowed(s, ["agentEnv", "search", "diagnostics", "elevation", "screenService", "autoChats"]), manager, fn() {
          flag(top(), "online")
        })
      "logins" => station_logins_node(b, core, address, fn() { flag(top(), "online") })
      "permissions" =>
        station_permissions_node(b, core, address, station_overview_of(s, "permissions"), fn() { flag(top(), "online") })
      "env" => station_env_node(b, core, address, station_overview_of(s, "agentEnv"), manager)
      "search" => station_search_node(b, core, address, station_overview_of(s, "search"), manager)
      "context" => station_context_node(b, core, address, station_overview_of(s, "context"), manager)
      "diagnostics" => station_diagnostics_node(b, core, address, station_overview_of(s, "diagnostics"), manager)
      "elevation" => station_elevation_node(b, core, address, station_overview_of(s, "elevation"))
      "workspaces" => station_workspaces_node(b, core, address)
      "network" => station_network_node(b, core, address, station_overview_of(s, "network"), manager)
      "copies" => station_copies_node(b, core, address, station_overview_of(s, "copies"))
      "moving" => station_moving_node(b, core, here, station_narrowed(s, ["copies"]), manager)
      "move" => station_move_section(b, core, address)
      "software" =>
        station_software_node(b, core, station_narrowed(s, ["updates"]), manager, fn() { flag(top(), "online") }, tips)
      _ => ()
    }
  }
  @sf.page_node(
    p,
    // (its head says its name: what it says of itself to a bar that names it, what it is of)
    fn() { @sf.t("android-misc.bar.place.stations") },
    blocks,
    fn(b, key) {
      match bones {
        // (in its bones, breathing: the first waiting on what it says, to a screen reader)
        Some(wait) =>
          @sf.waiting_node(b, fn(w) { block(w, key) }, note=fn() { { reading: true, text: if key == "parts" { wait } else { "" }, failing: [] } })
        None => block(b, key)
      }
    },
    on_back~,
    frame~,
    said?,
    width?,
    tips~,
    // its head says its name: no title over it (StationSettings: Head, then Body). (It reads all the station says of
    // itself, none of its overview or its machine: what the machine is worked out of it whole on its own, its ⋯ the
    // station whole as it is pressed)
    head=fn(h) { station_head_node(h, core, here, top, s, host, manager, bones is Some(_), stint, tips) },
    // (what its head does, on back's line over it where the page puts it there: own_head's back_line)
    actions=fn(a) {
      if bones is None {
        station_actions_node(a, core, here, top, s, fn() { local_stopped_in(address, host.get()) }, manager, tips)
      }
    },
  )
}

///|
/// Station `s` (whole) as a part of its page reads it: all it says of itself but its `overview` and its machine (its
/// name, mark, how it is, what is wrong with it: a few words, which change as it does), of its overview only `overview`'s
/// fields, and its machine (`host`) whole where `host` says so, else only whether it has one (a `{}` in its place).
/// Worked out once of it whole, told only as that comes out otherwise (a computed, Json's equality): a change of what
/// the part does not read (a profile's quota, its 归档's line, the machine's meters) runs none of what shows it.
fn station_narrowed(s : () -> Json?, overview : Array[String], host? : Bool = false) -> () -> Json? {
  let now = @signals.computed(fn(_) {
    match s() {
      Some(Object(m)) => {
        let out : Map[String, Json] = Map([])
        for k, v in m {
          if k == "overview" {
            let o : Map[String, Json] = Map([])
            for f in overview {
              match field(Some(v), f) {
                Some(x) => o[f] = x
                None => ()
              }
            }
            out[k] = Json::object(o)
          } else if k == "host" {
            out[k] = match v {
              Object(_) if !host => Json::object(Map([]))
              _ => v
            }
          } else {
            out[k] = v
          }
        }
        Some(Json::object(out))
      }
      other => other
    }
  })
  fn() { now.get() }
}

///|
/// Field `key` of station `s`'s overview, worked out once of it whole, told only as it comes out otherwise (a computed):
/// what a part of the page that shows that field alone reads.
fn station_overview_of(s : () -> Json?, key : String) -> () -> Json? {
  let now = @signals.computed(fn(_) { field(field(s(), "overview"), key) })
  fn() { now.get() }
}

///|
/// The keys of its overview's parts (station_overview's), those it has now: connection diagnostics while offline or
/// silent, what is left of the machine (live or last known snapshot), its screens, profiles, connects, folders and
/// devices.
fn station_overview_keys(core : Core, here : () -> Here, s : Json?) -> Array[String] {
  let address = text(s, "station")
  let id = text(s, "id")
  let has_devices = if flag(s, "online") {
    true
  } else {
    @settings.devices_listed(core, here())
    .iter()
    .any(fn(d) { text(Some(d), "station") == id && text(Some(d), "via") != "phone" })
  }
  station_overview_keys_by(
    s,
    station_part_read(core, address, station_screens_ask(address)).value,
    terminals=terminals_to_show(core, address, s),
    has_devices~,
  )
}

///|
/// The keys of its overview's parts (station_overview_keys'), its screens as `screens` says them (None: not answered).
fn station_overview_keys_by(s : Json?, screens : Json?, terminals? : Bool = false, has_devices? : Bool = false) -> Array[String] {
  let o = field(s, "overview")
  let out = []
  let online = flag(s, "online")
  let silent = items(s, "problems").iter().any(fn(p) { text(Some(p), "key") == "silent" })
  if !online || silent {
    out.push("diag")
  }
  if field(s, "host") is Some(Object(_)) {
    out.push("resources")
  }
  match screens {
    Some(Object(_)) as v => {
      let all = items(v, "screens")
      let can_open = flag(v, "browser") && flag(v, "control")
      // (its terminals there too, while it is up: 打开终端 at least)
      if !all.is_empty() || can_open || text(v, "note") != "" || (terminals && online) {
        // (its heading, then a block a row: all_screens_block)
        out.push("allScreens")
        for row in all_screens_rows_by(s, v, terminals) {
          out.push("allScreens/" + row)
        }
      }
    }
    _ => ()
  }
  if field(o, "drive") is Some(Object(_)) {
    out.push("drive")
  }
  // its devices while it is up (one is added there), or cached devices read-only while offline
  if online || has_devices {
    out.push("devices")
  }
  out
}

///|
/// The keys of its 设置's parts (station_settings'), those it has now. Away, a banner saying it is a read-only snapshot
/// followed by cached software, permissions and runtime settings (no restore offers or active logins).
fn station_settings_keys(s : Json?, manager : Bool, workspaces_on : Bool) -> Array[String] {
  let o = field(s, "overview")
  let online = flag(s, "online")
  let out = if online { ["software"] } else { ["offline", "software"] }
  if field(o, "permissions") is Some(Object(_)) {
    out.push("permissions")
  }
  let env = items(o, "agentEnv")
  let has_env = field(o, "agentEnv") is Some(Array(_)) && ((online && manager) || env.length() > 0)
  let search = field(o, "search")
  let has_search = search is Some(Object(_)) && text(search, "files") == "spotlight"
  if has_env || has_search || field(o, "diagnostics") is Some(Object(_)) || field(o, "elevation") is Some(Object(_)) || field(o, "screenService") is Some(Object(_)) || field(o, "autoChats") is Some(Object(_)) {
    out.push("system")
  }
  if manager && workspaces_on {
    out.push("workspaces")
  }
  if online && items(field(o, "copies"), "offers").length() > 0 {
    out.push("copies")
  }
  out
}

///|
/// What a part of station `address`'s page reads by (each read's ask, said where the read is: a topic and its params),
/// as it reads it: saying so where a part pressed handed it what it asked (sfbase's switch_answered, shown_read).
fn station_part_read(core : Core, address : String, ask : (String, Map[String, Json])) -> @settings.Read {
  let r = (core.topic)(ask.0, ask.1).get()
  @sfbase.shown_read(station_shown_at(address))
  r
}

///|
/// What station `address`'s page's readers say they have read anew by, what a part pressed asked handed to them
/// (sfbase's switch_answered, shown_read).
pub fn station_shown_at(address : String) -> String {
  "station\u{1}" + address
}

///|
/// Its screens (the core's `screens` of station `address`): what its overview's keys and its screens' parts read.
fn station_screens_ask(address : String) -> (String, Map[String, Json]) {
  ("screens", { "station": str(address) })
}

///|
/// How this device reaches station `address` (the core's `stationNet`): its resources' line.
fn station_net_ask(address : String) -> (String, Map[String, Json]) {
  ("stationNet", { "station": str(address) })
}

///|
/// Local connection diagnostics of station `address` (the core's `stationDiag`): subscribed only while offline or silent.
fn station_diag_ask(address : String) -> (String, Map[String, Json]) {
  ("stationDiag", { "station": str(address) })
}

///|
/// The workspaces station `address` is in (the core's `memberships`): its 设置's, for its managers.
fn station_memberships_ask(address : String) -> (String, Map[String, Json]) {
  ("memberships", { "station": str(address) })
}

///|
/// The draft `form` of station `address`'s agents' variables (the core's `agentEnvForm`): its 设置's editor's.
fn station_env_form_ask(address : String, form : String) -> (String, Map[String, Json]) {
  ("agentEnvForm", { "station": str(address), "form": str(form) })
}

///|
/// What block `key` of station `address`'s page (`s` whole, as it is now) reads as it is first drawn, each by the ask its
/// read is made by: what comes of an answer is station_part_then's. Its variables' editor's draft opened as the editor's
/// first build opens it, once (station_env_form).
fn station_block_asks(core : Core, here : Here, address : String, s : Json?, manager : Bool, key : String) -> Array[(String, Map[String, Json])] {
  match key {
    "diag" => [station_diag_ask(address)]
    "resources" => if flag(s, "online") { [station_net_ask(address), resources_ask(here, address)] } else { [resources_ask(here, address)] }
    "allScreens" => [station_screens_ask(address), ..if terminals_offered(core, s) { [terminals_ask(address)] } else { [] }]
    "userPages" | "agentPages" | "screens" => [station_screens_ask(address)]
    "devices" => if (core.devices_on)() { [@settings.devices_ask(here)] } else { [] }
    "processes" => [resources_ask(here, address)]
    "system" =>
      if flag(s, "online") && manager && station_env_open.get(address).unwrap_or(false) {
        [station_env_form_ask(address, station_env_form(core, address))]
      } else {
        []
      }
    "logins" => [logins_ask(address)]
    "env" => if manager { [station_env_form_ask(address, station_env_form(core, address))] } else { [] }
    // (up, it is the part's last, under its variables' editor: made only as it is scrolled to, which asks it then; away,
    // the part is three short blocks, all of it drawn as it comes)
    "workspaces" => if flag(s, "online") { [] } else { [station_memberships_ask(address)] }
    _ => []
  }
}

///|
/// What part `part` of station `address`'s page (`s` whole, as it is now) reads as it is first drawn (station_node's
/// press asks it): each of its blocks' (station_block_asks), its overview's screens first, which say which blocks it has.
fn station_part_asks(core : Core, here : Here, address : String, s : Json?, manager : Bool, part : String) -> Array[(String, Map[String, Json])] {
  let keys = match part {
    "processes" => ["processes"]
    "settings" => station_settings_keys(s, manager, (core.workspaces_on)())
    _ => ["screens", ..station_overview_keys_by(s, None, terminals=terminals_offered(core, s), has_devices=true)]
  }
  let out : Array[(String, Map[String, Json])] = []
  let said : Map[String, Bool] = Map([])
  for key in keys {
    for ask in station_block_asks(core, here, address, s, manager, key) {
      let k = ask.0 + Json::object(ask.1).stringify()
      if !said.contains(k) {
        said[k] = true
        out.push(ask)
      }
    }
  }
  out
}

///|
fn station_logins_shown(view : Json?, online : Bool) -> Array[String] {
  if !online || !flag(view, "supported") {
    return []
  }
  items(view, "logins").filter(fn(l) { flag(Some(l), "active") }).map(fn(l) { text(Some(l), "id") })
}

///|
/// What part `part` of station `address`'s page (`s` whole, as it is now) reads as it is first drawn once what the press
/// asked is answered (switch_answered's `then`).
fn station_part_then(_address : String, _s : Json?, _part : String) -> (((String, Map[String, Json])) -> Json?) -> Array[(String, Map[String, Json])] {
  fn(_read) { [] }
}

///|
/// Its head (Head, station_head's): its mark (picked by its managers), its name (renamed by them), how it is (its dot
/// before it), what the machine is, its version, where it is from; what is wrong with it under them; at its end trying
/// it again while away or silent, 启动 where it is this machine's and stopped here, its ⋯. This machine's as the host
/// says it, asked again every few seconds from when it is made (it starts, stops and updates on its own time: a
/// moment said each time). `bones`: all of it in its bones while what it says is read the first time. `s`: the station
/// as its head reads it (station_narrowed's: none of its overview or its machine), `whole` all of it.
fn station_head_node(
  h : @view.View,
  core : Core,
  here : () -> Here,
  s : () -> Json?,
  whole : () -> Json?,
  host : @signals.Signal[String],
  manager : Bool,
  bones : Bool,
  stint : () -> Int,
  tips : @sf.TipLayer,
) -> Unit {
  if bones {
    @sf.waiting_node(h, fn(w) { station_head_node(w, core, here, s, whole, host, manager, false, stint, tips) })
    return
  }
  let address = text(@signals.untracked(s), "station")
  let stopped = fn() { local_stopped_in(address, host.get()) }
  let online = fn() { flag(s(), "online") }
  let dot = fn() { if online() { "online" } else { "offline" } }
  let state = fn() {
    match stopped() {
      Some(_) as st => (local_stopped_words(st), text(st, "doing") != "")
      None => (text(s(), "stateText"), flag(s(), "stateBusy"))
    }
  }
  let name = fn() { text(s(), "name") }
  // (what the machine is, its version, where it is from: worked out once of the station whole, told only as it reads
  // otherwise, so its machine's figures changing run nothing of the head)
  let facts_now = @signals.computed(fn(_) { station_head_facts(whole()) })
  let facts = fn() { facts_now.get() }
  @sf.own_head_node(
    h,
    fn(m, side) {
      let glyph = if side <= 32.0 { st_mark_wide_glyph } else { st_mark_glyph }
      m.pick(fn() { @sf.has_station_mark(text(s(), "emoji"), text(s(), "icon")) }, fn(k, has) {
        if has {
          @sf.station_mark_node(k, fn() { text(s(), "emoji") }, fn() { text(s(), "icon") }, glyph, fn() {
            @sf.theme().p.text
          }, stint)
        } else {
          @sf.words_node(k, fn() {
            match name().iter().next() {
              Some(ch) => ch.to_string().to_upper()
              None => "?"
            }
          }, fn() { st_mark_letter })
          |> ignore
        }
      })
    },
    // its mark: its managers pick it, by what it is called (图标)
    mark_press?=if manager {
      Some(
        (
          fn() { @sf.t("android-settings.station.emoji") },
          fn() {
            let now = @signals.untracked(s)
            let workspace = @signals.untracked(here)
            guard flag(now, "online") else { @settings.mark_offline(core, text(now, "name")) }
            // (its system's icon, shown where it has none, is none to the picker)
            let icon = if flag(now, "osIcon") { "" } else { text(now, "icon") }
            open_mark_pick(core, text(now, "name"), text(now, "emoji"), icon, @sf.t("android-settings.station.emojiWhat"), fn(
              emoji,
              icon,
              done,
            ) {
              (core.call)(
                "workspace.renameStation",
                obj([("workspace", str(workspace.workspace)), ("station", str(text(now, "id"))), ("emoji", str(emoji)), ("icon", str(icon)), ("account", str(workspace.sub))]),
                done,
              )
            })
          },
        ),
      )
    } else {
      None
    },
    name,
    rename?=if manager { Some(fn() { station_rename(core, @signals.untracked(here), @signals.untracked(s)) }) } else { None },
    rename_label=fn() { @sf.t("web-pages.settings.stations.rename") },
    // (what the machine is, none for one never reached: no line, and no dot before nothing)
    lines=fn() {
      match facts() {
        "" => []
        facts => [facts]
      }
    },
    // its dot before what it says of how it is (reconnecting …; this machine's, how it stands here: 已停止, 正在更新),
    // else before what the machine is
    dot=fn() { if state().0 == "" && facts() != "" { dot() } else { "" } },
    state=fn(k) {
      @sf.state_dot_node(k, fn() { if state().1 && stopped() is Some(_) { "busy" } else { dot() } })
      @sf.words_node(k, fn() { state().0 }, fn() { if state().1 { st_fact_busy } else { st_fact } }) |> ignore
    },
    state_shown=fn() { state().0 != "" },
    warnings=fn() {
      let out = items(s(), "problems").map(fn(p) { (text(Some(p), "text"), text(Some(p), "level") == "red") })
      match local_failed_words(stopped()) {
        "" => ()
        words => out.push((words, true))
      }
      out
    },
    actions=fn(a) { station_actions_node(a, core, here, s, whole, stopped, manager, tips) },
  )
}

///|
/// What its head does at its end (station_head's): trying it again while away or silent, 启动 where it is this
/// machine's and stopped here (`stopped`), how its renaming goes and its ⋯ for its managers. `s`: the station as they
/// read it (station_narrowed's), `whole` all of it, which its ⋯ reads as it is pressed.
fn station_actions_node(
  a : @view.View,
  core : Core,
  here : () -> Here,
  s : () -> Json?,
  whole : () -> Json?,
  stopped : () -> Json?,
  manager : Bool,
  tips : @sf.TipLayer,
) -> Unit {
  let online = fn() { flag(s(), "online") }
  let id = fn() { text(s(), "id") }
  let silent = fn() { items(s(), "problems").iter().any(fn(p) { text(Some(p), "key") == "silent" }) }
  a.pick(fn() { if stopped() is Some(_) { 1 } else if !online() || silent() { 2 } else { 0 } }, fn(e, end) {
    match end {
      // this machine's, not running here: started from here, no try at reaching it again (station_start's)
      1 => {
        let working = fn() { text(stopped(), "doing") != "" }
        @sf.button_node(e, fn() { @sf.t("web-pages.localStation.start") }, fn() { local_start(core, @signals.untracked(stopped)) }, tone=Ghost, busy=working, disabled=working)
        |> ignore
      }
      // tried again now (station_retry's: the core's `client.wake`, every station at once)
      2 => {
        let trying = fn() { flag(field(s(), "link"), "retrying") || is_doing(core, ["client.wake"], []) }
        @sf.button_node(e, fn() { @sf.t("common.retry") }, fn() {
          @settings.act(
            core,
            @sf.t("common.retry"),
            "client.wake",
            obj([("away", Json::number(0.0)), ("network", Json::boolean(true)), ("retry", Json::boolean(true))]),
          )
        }, tone=Ghost, busy=trying, disabled=trying)
        |> ignore
      }
      _ => ()
    }
  })
  // its 加入安全模式 (station_protect's), where its workspace's safe mode does not name it and the viewer could protect it here
  a.show(fn() { flag(s(), "protect") }, fn(e) {
    let joining = fn() { is_doing(core, ["lock.joinStation"], [("workspace", here().workspace), ("station", id())]) }
    @sf.button_node(e, fn() { @sf.t("web-pages.security.joinShort") }, fn() {
      let now = @signals.untracked(s)
      join_dialog(core, @signals.untracked(here).workspace, text(now, "id"), text(now, "name"))
    }, tone=Ghost, busy=joining, disabled=joining)
    |> ignore
  })
  if manager {
    let on = fn() { [("station", id())] }
    // (its mode changing too: asked of the station, then the cloud, a while in all)
    doing_mark_node(a, fn() { is_doing(core, ["workspace.renameStation", "workspace.removeStation", "rig.setMode"], on()) }, fn() {
      failed_of(core, ["workspace.renameStation", "workspace.removeStation", "rig.setMode"], on())
    }, tips~)
    // its ⋯ (station_menu's), beside it
    @sf.icon_action_opens_node(a, "more", fn() { @sf.t("common.more") }, fn(m) {
      @sf.menu(station_menu_items(core, @signals.untracked(here), @signals.untracked(whole)), from=Node(m), along=End)
    })
    |> ignore
  }
}

///|
/// The parts to pick from (Body's Segmented, station_parts_choice's): the one `chosen` says (pressed, from the press),
/// one picked `press`ed.
fn station_parts_node(b : @view.View, chosen : () -> String, press : (String) -> Unit) -> Unit {
  @sf.page_choice_node(
    b,
    fn() { station_part_names.map(fn(p) { @sf.t("web-pages.stations.page.part." + p) }) },
    fn() { station_part_names.search(chosen()).unwrap_or(0) },
    fn(i) { press(station_part_names[i]) },
  )
}

///|
/// A section of the page (st_section's), titled `title`, `count` beside its title where it is one or more (wide),
/// `note` what it holds said by it, `ends` what it does at its title's end.
fn st_section_node(
  b : @view.View,
  title : () -> String,
  body : (@view.View) -> Unit,
  count? : () -> Int = fn() { 0 },
  note? : () -> String = fn() { "" },
  ends? : (() -> Bool, (@view.View) -> Unit),
) -> Unit {
  let ends = match ends {
    Some((shown, make)) => Some(fn(e : @view.View) { e.show(shown, make) })
    None => None
  }
  @sf.section_node(b, title, body, note~, ends?, title_after=fn(l) {
    l.show(fn() { count() > 0 }, fn(n) { @sf.words_node(n, fn() { count().to_string() }, fn() { st_count }) |> ignore })
  })
}

///|
/// A row that says how something stands, going nowhere (said_row's: its title, `note` under it).
fn said_row_node(g : @view.View, title : () -> String, note? : () -> String = fn() { "" }, lead? : @sf.RowLead = NoLead) -> Unit {
  @sf.link_row_node(g, title, fn() {  }, note~, goes=false, lead~)
}

///|
/// A row's mark (a screen's, a folder's, a grant's: st_row_mark's): its icon in the muted ink.
fn st_mark_node(l : @view.View, icon : () -> String) -> Unit {
  @sf.icon_node(l, @signals.untracked(icon), st_row_glyph, By(fn() { @sf.theme().p.muted }), name_now=icon) |> ignore
}

// ── Overview ────────────────────────────────────────────────────────────

///|
/// Local connection diagnostics shown at the top of an offline or silent station's overview: summary, last error,
/// backoff status, key metadata, per-route dial attempts, and a local log shortcut when this machine's station stopped.
fn station_diag_node(b : @view.View, core : Core, address : String, stopped : () -> Json?) -> Unit {
  let diag = fn() { station_part_read(core, address, station_diag_ask(address)).value }
  let is_local_stopped = fn() { address == this_machine() && stopped() is Some(_) }
  b.show(fn() { diag() is Some(Object(_)) || is_local_stopped() }, fn(p) {
    st_section_node(
      p,
      fn() { @sf.t("web-pages.stations.diag.title") },
      ends=(fn() { text(diag(), "copyText") != "" }, fn(e) {
        @sf.action_node(
          e,
          fn() { @sf.t("web-pages.stations.diag.copy") },
          fn() {
            let copied = text(@signals.untracked(diag), "copyText")
            if copied != "" {
              @ui.clipboard_set(copied)
              @sfbase.toast_later(@sf.t("web-pages.stations.diag.copied"))
            }
          },
          icon="copy",
        )
      }),
      fn(sec) {
        @sf.group_node(sec, fn(g) {
          g.show(fn() { diag() is Some(Object(_)) }, fn(s) {
            @sf.block_node(s, fn(k) {
              k.show(fn() { text(diag(), "detail") != "" || text(diag(), "retryText") != "" }, fn(h) {
                @sf.style_node(h, fn() { st_diag_head })
                h.show(fn() { text(diag(), "detail") != "" }, fn(w) {
                  @sf.words_node(w, fn() { text(diag(), "detail") }, fn() { st_diag_summary }) |> ignore
                })
                h.show(fn() { text(diag(), "retryText") != "" }, fn(w) {
                  @sf.words_node(w, fn() { text(diag(), "retryText") }, fn() { st_problem }) |> ignore
                })
              })
              let meta_rows = fn() {
                let out : Array[(String, String)] = []
                let cloud = text(diag(), "cloudStatus")
                if cloud != "" {
                  out.push((@sf.t("web-pages.stations.diag.cloud"), cloud))
                }
                let last_net = text(diag(), "lastNetText")
                if last_net != "" {
                  out.push((@sf.t("web-pages.stations.diag.lastNet"), last_net))
                }
                let addrs = strings(diag(), "addresses")
                if addrs.length() > 0 {
                  out.push((@sf.t("web-pages.stations.diag.addresses"), join(addrs, ", ")))
                }
                out
              }
              k.show(fn() { meta_rows().length() > 0 }, fn(m) { diag_meta_node(m, meta_rows) })
              k.show(fn() { items(diag(), "ways").length() > 0 }, fn(w) {
                diag_ways_node(w, fn() { items(diag(), "ways") })
              })
            })
          })
          g.show(is_local_stopped, fn(r) {
            @sf.link_row_node(
              r,
              fn() { @sf.t("web-pages.stations.diag.localLog") },
              fn() { @hostapi.app_tell("local_station_act", "log") },
              lead=LeadLine(fn(l) { st_mark_node(l, fn() { "file-text" }) }),
            )
          })
        })
      },
    )
  })
}

///|
/// What is left of the machine (and what its agents take of it), this device's connection to it, what still.fail uses
/// of it opening its 进程 (station_overview's 资源: `processes`, its choice's press).
fn station_resources_node(b : @view.View, core : Core, src : Source, here : () -> Here, s : () -> Json?, processes : () -> Unit) -> Unit {
  st_section_node(
    b,
    fn() { @sf.t("web-pages.stations.page.resources") },
    note=fn() {
      if flag(s(), "online") { "" } else { @sf.t("web-pages.stations.resourcesSnapshot") }
    },
    fn(sec) {
    @sf.group_node(sec, fn(g) {
      @sf.block_node(g, fn(k) {
        k.box(fn(r) {
          @sf.style_node(r, fn() { st_resources_in })
          let address = @signals.untracked(fn() { text(s(), "station") })
          let net = fn() { station_part_read(core, address, station_net_ask(address)).value }
          let uses = fn() { items(station_part_read(core, address, resources_ask(here(), address)).value, "stations").get(0) }
          // what the machine is, over its figures (the core's `madeOf`: its chip and cores, architecture, system and
          // hostname, none of which its dials say)
          let made_of = @signals.computed(fn(_) { text(field(s(), "host"), "madeOf") })
          r.show(fn() { made_of.get() != "" }, fn(x) {
            @sf.words_node(x, fn() { made_of.get() }, fn() { st_made_of }) |> ignore
          })
          station_dials_node(r, src, fn() { field(s(), "host") })
          r.show(fn() { flag(s(), "online") && net() is Some(Object(_)) }, fn(x) { 
            @sfbase.station_net_line_node(x, net, look=Page, egress=fn() { text(field(s(), "host"), "egressText") })
          })
          // (what still.fail itself uses of the machine, opening its 进程: read while shown)
          r.show(fn() { uses() is Some(_) }, fn(x) { station_uses_node(x, uses, processes) })
          r.show(fn() { uses() is None && items(field(s(), "overview"), "processes").length() > 0 }, fn(x) {
            @sf.words_node(x, fn() { text(field(s(), "overview"), "processesText") }, fn() { st_memory }) |> ignore
          })
        })
        |> ignore
      })
    })
    },
  )
}

///|
fn is_user_screen(sv : Json?) -> Bool {
  flag(sv, "userTab") || text(sv, "id").has_prefix("browser:u_")
}

///|
fn is_browser_screen(sv : Json?) -> Bool {
  text(sv, "kind") == "browser" || text(sv, "id").has_prefix("browser:")
}

///|
fn is_agent_screen(sv : Json?) -> Bool {
  is_browser_screen(sv) && !is_user_screen(sv)
}

///|
fn screen_row_icon(sv : Json?) -> String {
  if is_browser_screen(sv) {
    "web"
  } else if text(sv, "kind") == "simulator" {
    "phone"
  } else {
    "monitor"
  }
}

///|
/// Unified "屏幕与浏览器" section: physical/simulator screens, agent-opened browser tabs, and station browser entry, all
/// of it in one node (a test's: the page has it a block a row, all_screens_keys).
// (held by its tests, not used by the app yet)
#warnings("-unused_value")
fn station_all_screens_node(b : @view.View, core : Core, here : () -> Here, s : () -> Json?) -> Unit {
  let address = text(@signals.untracked(s), "station")
  st_section_node(b, fn() { all_screens_title(core, s()) }, count=fn() { all_screens_count(core, address, s) }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      g.each(fn() { all_screens_rows(core, address, s()) }, fn(k) { k }, fn(row, k) {
        all_screens_row_node(row, core, here, s, k.untracked())
      })
    })
  })
}

///|
/// Its heading: 屏幕、浏览器与终端 where its terminals are offered (a `beta` feature of the station's: terminals_offered),
/// else 屏幕与浏览器.
fn all_screens_title(core : Core, s : Json?) -> String {
  if terminals_offered(core, s) {
    @sf.t("web-pages.stations.screensAndTerminals")
  } else {
    @sf.t("web-pages.stations.screensTitle")
  }
}

///|
/// Its screens' topic (`screens`).
fn all_screens_v(core : Core, address : String) -> Json? {
  (core.topic)("screens", { "station": str(address) }).get().value
}

///|
/// How many 屏幕、浏览器与终端 counts: its screens, the agents' tabs and its terminals.
fn all_screens_count(core : Core, address : String, s : () -> Json?) -> Int {
  let v = all_screens_v(core, address)
  let screens = items(v, "screens").filter(fn(sc) { !is_browser_screen(Some(sc)) }).length()
  let tabs = items(v, "screens").filter(fn(sc) { is_agent_screen(Some(sc)) }).length()
  let terminals = if terminals_offered(core, s()) && flag(s(), "online") {
    let tv = (core.topic)("terminals", { "station": str(address) }).get().value
    if terminals_shown(s(), tv) { items(tv, "terminals").length() } else { 0 }
  } else {
    0
  }
  screens + tabs + terminals
}

///|
/// The rows of 屏幕、浏览器与终端 by their keys, in order (as `screens`, `v`, and station `s` say them, `terminals`:
/// terminals_to_show's): each screen ("screen/<id>"), each agent's tab ("tab/<id>"), opening its browser ("browser"),
/// its terminals and 打开终端 ("terminals"), what it says where it has none ("note").
fn all_screens_rows_by(s : Json?, v : Json?, terminals : Bool) -> Array[String] {
  let all = items(v, "screens")
  let out : Array[String] = []
  for sc in all {
    if !is_browser_screen(Some(sc)) {
      out.push("screen/" + text(Some(sc), "id"))
    }
  }
  for sc in all {
    if is_agent_screen(Some(sc)) {
      out.push("tab/" + text(Some(sc), "id"))
    }
  }
  if all.iter().any(fn(sc) { is_user_screen(Some(sc)) }) || (flag(v, "browser") && flag(v, "control")) {
    out.push("browser")
  }
  if terminals && flag(s, "online") {
    out.push("terminals")
  }
  if all.is_empty() && text(v, "note") != "" {
    out.push("note")
  }
  out
}

///|
/// The rows of 屏幕、浏览器与终端 of station `address` (`s` whole) as they are now (all_screens_rows_by's).
fn all_screens_rows(core : Core, address : String, s : Json?) -> Array[String] {
  all_screens_rows_by(s, all_screens_v(core, address), terminals_to_show(core, address, s))
}

///|
/// Row `key` of 屏幕、浏览器与终端 (all_screens_rows_by's) in `row`: a screen's with who is on it, an agent's tab's, opening
/// the browser, the terminals, its note. One whose screen is gone draws it as it was last, while it goes.
fn all_screens_row_node(row : @view.View, core : Core, here : () -> Here, s : () -> Json?, key : String) -> Unit {
  let address = text(@signals.untracked(s), "station")
  let v = fn() { all_screens_v(core, address) }
  // (the screen `id` as `screens` has it now, else as it was last)
  let screen_of = fn(id : String) -> () -> Json? {
    let last : Ref[Json?] = Ref(None)
    fn() {
      match items(v(), "screens").iter().find_first(fn(sc) { text(Some(sc), "id") == id }) {
        Some(sc) => {
          last.val = Some(sc)
          Some(sc)
        }
        None => last.val
      }
    }
  }
  match key {
    k if k.has_prefix("screen/") => {
      let id = k.exact_view(start=7).to_owned()
      let sv = screen_of(id)
      let lacks = fn() {
        let access = field(sv(), "access")
        access is Some(Object(_)) && (!flag(access, "capture") || !flag(access, "control"))
      }
      // (its row made again as it comes to be this machine's own or lacks what it may, who is on it under it made
      // once, whatever of that changes)
      @sf.group_rows_node(row, fn(r) {
        r.pick(fn() { (own_screen(address, id), lacks()) }, fn(p, k) {
          let (own, lacks) = k
          @sf.link_row_node(
            p,
            fn() { text(sv(), "title") },
            fn() {
              if !own {
                @sfbase.open_page(Screen({ station: address, screen: id, title: text(@signals.untracked(sv), "title"), until_gone: false }))
              }
            },
            note=fn() { if own { @sf.t("android-misc.screen.here") } else { text(sv(), "line") } },
            lacks=!own && lacks,
            goes=!own,
            lead=LeadLine(fn(l) { st_mark_node(l, fn() { screen_row_icon(sv()) }) }),
          )
        })
        screen_views_node(r, core, here, address, sv)
      })
    }
    k if k.has_prefix("tab/") => station_browser_row_node(row, core, here, address, screen_of(k.exact_view(start=4).to_owned()))
    "browser" => {
      let user_tabs = fn() { items(v(), "screens").filter(fn(sc) { is_user_screen(Some(sc)) }) }
      @sf.link_row_node(
        row,
        fn() { @sf.t("web-pages.screen.openBrowserRow") },
        fn() { @settings.open_station_browser(core, address) },
        note=fn() { browser_tabs_note(user_tabs().length()) },
        lead=LeadLine(fn(l) { st_mark_node(l, fn() { "web" }) }),
      )
    }
    // its terminals, then 打开终端 (station_terminals_node.mbt)
    "terminals" => @sf.group_rows_node(row, fn(r) { station_terminal_rows_node(r, core, address, s) })
    "note" => said_row_node(row, fn() { text(v(), "note") }, lead=LeadLine(fn(l) { st_mark_node(l, fn() { "monitor" }) }))
    _ => ()
  }
}

///|
/// 屏幕、浏览器与终端 as blocks of the page's list (a block is a row): its heading ("allScreens"), then each of its rows
/// ("allScreens/<row>", all_screens_rows'), a piece of its card each.
fn all_screens_block(b : @view.View, core : Core, here : () -> Here, s : () -> Json?, key : String) -> Unit {
  let address = text(@signals.untracked(s), "station")
  if key == "allScreens" {
    @sf.section_heading_node(b, fn() { all_screens_title(core, s()) }, title_after=fn(l) {
      l.show(fn() { all_screens_count(core, address, s) > 0 }, fn(n) {
        @sf.words_node(n, fn() { all_screens_count(core, address, s).to_string() }, fn() { st_count }) |> ignore
      })
    })
    return
  }
  let row = key.exact_view(start=11).to_owned()
  // (as tall as its block, its piece of the card in it as tall: card_piece_node)
  b.grow(Is(1.0)) |> ignore
  let last : Ref[@sf.CardPiece] = Ref(@sf.CardPiece::CardWhole)
  let piece = fn() {
    let rows = all_screens_rows(core, address, s())
    match rows.search(row) {
      Some(i) => last.val = @sf.card_piece_of(i, rows.length())
      None => ()
    }
    last.val
  }
  @sf.card_piece_node(b, piece, wide_group=true, fn(card) { all_screens_row_node(card, core, here, s, row) })
}

///|
/// A person's own pages on this station's browser (`station_overview`'s 浏览器): one row, opening it at once on the tab
/// looked at last, else a new one (@settings.open_station_browser), how many it has in its note.
fn station_user_pages_node(b : @view.View, core : Core, here : () -> Here, s : () -> Json?) -> Unit {
  ignore(here)
  let address = text(@signals.untracked(s), "station")
  let v = fn() { (core.topic)("screens", { "station": str(address) }).get().value }
  let tabs = fn() { items(v(), "screens").filter(fn(sc) { is_user_screen(Some(sc)) }) }
  st_section_node(b, fn() { @sf.t("web-pages.screen.browser") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      @sf.link_row_node(
        g,
        fn() { @sf.t("web-pages.screen.openBrowserRow") },
        fn() { @settings.open_station_browser(core, address) },
        note=fn() { browser_tabs_note(tabs().length()) },
        lead=LeadLine(fn(l) { st_mark_node(l, fn() { "web" }) }),
      )
    })
  })
}

///|
/// Agent-opened and login browser pages on this station (`station_overview`'s Agent 页面), kept apart from user pages.
fn station_agent_pages_node(b : @view.View, core : Core, here : () -> Here, s : () -> Json?) -> Unit {
  let address = text(@signals.untracked(s), "station")
  let v = fn() { (core.topic)("screens", { "station": str(address) }).get().value }
  let tabs = fn() { items(v(), "screens").filter(fn(sc) { is_agent_screen(Some(sc)) }) }
  st_section_node(b, fn() { @sf.t("web-pages.screen.agentPages") }, count=fn() { tabs().length() }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      g.each(tabs, fn(sc) { text(Some(sc), "id") }, fn(row, sc) {
        station_browser_row_node(row, core, here, address, fn() { Some(sc.get()) })
      })
    })
  })
}

///|
/// One of the agents' tabs (`station_browser_row`'s node counterpart): opens the tab, 关闭 at its end where it may be,
/// and any active viewer rows under it.
fn station_browser_row_node(row : @view.View, core : Core, here : () -> Here, address : String, sv : () -> Json?) -> Unit {
  let id = text(@signals.untracked(sv), "id")
  // (its row made again as it comes to be closable or not, who is on it under it made once)
  @sf.group_rows_node(row, fn(r) {
    r.pick(fn() { flag(sv(), "closable") }, fn(p, close_on) {
      @sf.link_row_node(
        p,
        fn() { text(sv(), "title") },
        fn() {
          @sfbase.open_page(Screen({ station: address, screen: id, title: text(@signals.untracked(sv), "title"), until_gone: true }))
        },
        note=fn() { text(sv(), "line") },
        lead=LeadLine(fn(l) { st_mark_node(l, fn() { screen_row_icon(sv()) }) }),
        control?=if close_on {
          Some(fn(e) {
            let on = [("station", address), ("screen", id)]
            let what = @sf.t("web-pages.screen.closeTabWhat")
            @sf.row_end_button_node(
              e,
              fn() { @sf.t("web-pages.screen.closeTab") },
              fn() { @settings.act(core, what, "screen.close", obj([("station", str(address)), ("screen", str(id))])) },
              busy=fn() { is_doing(core, ["screen.close"], on) },
            )
            |> ignore
          })
        } else {
          None
        },
      )
    })
    screen_views_node(r, core, here, address, sv)
  })
}

///|
/// Its screens (station_overview's): a row each opening it (this machine's own display said so, not opened), what it
/// lacks in amber, who is on it under it; one from before them says so quietly.
fn station_screens_node(b : @view.View, core : Core, here : () -> Here, s : () -> Json?) -> Unit {
  let address = text(@signals.untracked(s), "station")
  let v = fn() { (core.topic)("screens", { "station": str(address) }).get().value }
  let screens = fn() { items(v(), "screens").filter(fn(sc) { !is_browser_screen(Some(sc)) }) }
  st_section_node(b, fn() { @sf.t("web-pages.screen.section") }, count=fn() { screens().length() }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      g.each(screens, fn(sc) { text(Some(sc), "id") }, fn(row, sc) {
        let sv = fn() { Some(sc.get()) }
        let id = text(@signals.untracked(sv), "id")
        // this machine's own display: said so, not opened (own_screen); what it lacks, its row made again so (the
        // core's: what cannot be done now)
        let lacks = fn() {
          let access = field(sv(), "access")
          access is Some(Object(_)) && (!flag(access, "capture") || !flag(access, "control"))
        }
        @sf.group_rows_node(row, fn(r) {
          r.pick(fn() { (own_screen(address, id), lacks()) }, fn(p, k) {
          let (own, lacks) = k
          @sf.link_row_node(
            p,
            fn() { text(sv(), "title") },
            fn() {
              if !own {
                @sfbase.open_page(Screen({ station: address, screen: id, title: text(@signals.untracked(sv), "title"), until_gone: false }))
              }
            },
            // what it lacks says so in its line
            note=fn() { if own { @sf.t("android-misc.screen.here") } else { text(sv(), "line") } },
            lacks=!own && lacks,
            goes=!own,
            // (its mark the page's own row mark, st_row_mark's 16 in the muted ink, by its first line, as the old page's)
            lead=LeadLine(fn(l) { st_mark_node(l, fn() { screen_row_icon(sv()) }) }),
          )
          })
          screen_views_node(r, core, here, address, sv)
        })
      })
      g.show(fn() { screens().length() == 0 && items(v(), "screens").is_empty() && text(v(), "note") != "" }, fn(n) {
        said_row_node(n, fn() { text(v(), "note") }, lead=LeadLine(fn(l) { st_mark_node(l, fn() { "monitor" }) }))
      })
    })
  })
}

///|
/// Who is on one of its screens now (screen_views'): a row a view, whose and on which device, whether it drives it and
/// since when; 转为只看 and 断开 at its end for one the viewer may let go of, and 全部断开 once there is more than one.
fn screen_views_node(g : @view.View, core : Core, here : () -> Here, address : String, screen : () -> Json?) -> Unit {
  let id = text(@signals.untracked(screen), "id")
  let asked = fn(name : String, what : String, params : Array[(String, Json)]) {
    @settings.act(core, what, name, obj([("station", str(address)), ("screen", str(id)), ("account", str(@signals.untracked(here).sub)), ..params]))
  }
  g.each(fn() { items(screen(), "views") }, fn(v) { text(Some(v), "id") }, fn(row, vs) {
    let vv = fn() { Some(vs.get()) }
    let view = text(@signals.untracked(vv), "id")
    let on = [("view", view)]
    // (made once: 转为只看 and 断开 come and go at its end as the view says it may be let go of and drives it, the row
    // itself not made again for either)
    @sf.link_row_node(
        row,
        fn() { text(vv(), "name") },
        fn() {  },
        // (the device is what tells one's own views apart: in the note, which wraps where 转为只看 and 断开 leave little room)
        note=fn() {
          let device = if flag(vv(), "here") { @sf.t("web-pages.screen.viewHere") } else { text(vv(), "device") }
          let mode = @sf.t(if flag(vv(), "control") { "web-pages.screen.viewControl" } else { "web-pages.screen.viewWatch" })
          if device == "" { mode + " · " + text(vv(), "ago") } else { device + " · " + mode + " · " + text(vv(), "ago") }
        },
        goes=false,
        tail=fn(e) {
          @sf.line_end_node(e, fn(l) {
            l.show(fn() { flag(vv(), "control") }, fn(w) {
              let what = @sf.t("web-pages.screen.viewWatchOnly")
              @sf.button_node(w, fn() { what }, fn() { asked("screen.watchOnly", what, [("view", str(view))]) }, tone=Ghost, busy=fn() {
                is_doing(core, ["screen.watchOnly"], on)
              })
              |> ignore
            })
            let what = @sf.t("web-pages.screen.viewEnd")
            @sf.button_node(l, fn() { what }, fn() { asked("screen.endView", what, [("view", str(view))]) }, tone=Ghost, busy=fn() {
              is_doing(core, ["screen.endView"], on)
            })
            |> ignore
          })
        },
        tail_shown=fn() { flag(vv(), "may") },
      )
  })
  g.show(fn() { items(screen(), "views").filter(fn(v) { flag(Some(v), "may") }).length() > 1 }, fn(r) {
    let what = @sf.t("web-pages.screen.viewsEndAll")
    @sf.link_row_node(r, fn() { "" }, fn() {  }, goes=false, tail=fn(e) {
      @sf.line_end_node(e, fn(l) {
        @sf.button_node(l, fn() { what }, fn() { asked("screen.endViews", what, []) }, tone=Ghost, busy=fn() {
          is_doing(core, ["screen.endViews"], [("screen", id)])
        })
        |> ignore
      })
    })
  })
}

///|
/// Its profiles by account kind (station_overview's): a row a kind, how many and how many need a look, pressed open to
/// its accounts beside it (station_profiles_panel), from the row (link_row_opens_node).
fn station_profiles_node(b : @view.View, core : Core, here : () -> Here, s : () -> Json?) -> Unit {
  let address = text(@signals.untracked(s), "station")
  st_section_node(b, fn() { @sf.t("android-misc.bar.place.profiles") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      g.each(fn() { items(s(), "profileGroups") }, fn(gr) { text(Some(gr), "group") }, fn(row, gr) {
        let gv = fn() { Some(gr.get()) }
        let kind = text(@signals.untracked(gv), "group")
        let ids = fn() { strings(gv(), "profiles") }
        let attention = fn() {
          match field(gv(), "attention") {
            Some(Number(n, ..)) => n.to_int()
            _ => 0
          }
        }
        row.box(fn(holder) {
          // (opened from the row itself: beside it, following it, the focus back on it as it closes)
          @sf.link_row_opens_node(
            holder,
            fn() { text(gv(), "title") },
            fn(at) {
              let many = @signals.untracked(ids).length() >= @sf.pick_search_from
              station_profiles_panel(core, @signals.untracked(here), address, kind, text(@signals.untracked(gv), "title"), Node(at), many)
            },
            value=fn() { @sf.t("web-mobile.settings.profilesCount", args=[("n", ids().length().to_string())]) },
            trouble=fn() {
              if attention() > 0 {
                @sf.t("web-mobile.settings.profilesShort", args=[("n", attention().to_string())])
              } else {
                ""
              }
            },
            lead=LeadLine(fn(l) { vt_group_mark_node(l, kind) }),
          )
        })
        |> ignore
      })
    })
  })
}

///|
/// Its connects (station_overview's): a row each, its team and how it runs, how it is where it is not online, opening
/// its page.
fn station_connects_node(b : @view.View, core : Core, s : () -> Json?) -> Unit {
  let address = text(@signals.untracked(s), "station")
  let connects = fn() { items(field(s(), "overview"), "connects") }
  st_section_node(b, fn() { @sf.t("web-pages.settings.nav.connects") }, count=fn() { connects().length() }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      g.each(connects, fn(cn) { text(Some(cn), "id") }, fn(row, cn) {
        let cv = fn() { Some(cn.get()) }
        @sf.link_row_node(
          row,
          fn() { text(cv(), "name") },
          fn() { (core.push)(Connect(address, text(@signals.untracked(cv), "id"))) },
          note=fn() { join([text(cv(), "team"), text(cv(), "runText")], " · ") },
          value=fn() { if text(cv(), "presence") != "online" { text(cv(), "statusText") } else { "" } },
          lead=LeadLine(fn(l) { @sf.state_dot_node(l, fn() { text(cv(), "presence") }) }),
        )
      })
    })
  })
}

///|
/// Its drive (station_overview's): a station that offers its home opens there; older ones still show their configured
/// folders, 打开文件 at its title's end.
fn station_drive_node(b : @view.View, s : () -> Json?) -> Unit {
  let address = text(@signals.untracked(s), "station")
  let drive = fn() { field(field(s(), "overview"), "drive") }
  let roots = fn() { items(drive(), "roots") }
  let open = fn(root : String?) { @sfbase.open_page(Drive({ station: address, root, path: "" })) }
  b.pick(fn() { flag(drive(), "anywhere") }, fn(p, anywhere) {
    if anywhere {
      st_section_node(p, fn() { @sf.t("web-pages.drive.title") }, fn(sec) {
        @sf.group_node(sec, fn(g) {
          @sf.link_row_node(g, fn() { @sf.t("web-pages.stations.page.openFiles") }, fn() { open(None) }, lead=LeadLine(fn(l) { st_mark_node(l, fn() { "folder" }) }))
        })
      })
    } else {
      st_section_node(
        p,
        fn() { @sf.t("web-pages.drive.title") },
        count=fn() { roots().length() },
        ends=(fn() { true }, fn(e) {
          @sf.action_node(e, fn() { @sf.t("web-pages.stations.page.openFiles") }, fn() { open(None) }, icon="folder")
        }),
        fn(sec) {
          @sf.group_node(sec, fn(g) {
            g.show(fn() { roots().length() == 0 }, fn(n) { said_row_node(n, fn() { @sf.t("web-pages.drive.noneYet") }) })
            g.each(roots, fn(r) { text(Some(r), "path") }, fn(row, r) {
              let rv = fn() { Some(r.get()) }
              @sf.link_row_node(
                row,
                fn() { text(rv(), "name") },
                fn() { open(Some(text(@signals.untracked(rv), "path"))) },
                note=fn() { text(rv(), "path") },
                lead=LeadLine(fn(l) { st_mark_node(l, fn() { "folder" }) }),
              )
            })
          })
        },
      )
    }
  })
}

///|
/// What else of it has a page of its own (station_overview's 更多): its memory.
fn station_more_node(b : @view.View, core : Core, address : String) -> Unit {
  st_section_node(b, fn() { @sf.t("web-pages.stations.page.more") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      @sf.link_row_node(g, fn() { @sf.t("android-settings.memory") }, fn() { (core.push)(Memory(address)) })
      // (共享调试 is no station's: a chat's agent asks for the phone, and settings' 共享调试 is where it stands)
    })
  })
}

///|
/// Its 进程 (station_processes'): what still.fail uses of the machine; offline, renders cached snapshot if available,
/// otherwise a line saying it cannot be seen.
/// `table`: its page's, its table's rows and how it is read blocks of their own (rs_block_node).
fn station_processes_node(b : @view.View, core : Core, here : () -> Here, s : () -> Json?, table : RsTable?) -> Unit {
  let address = text(@signals.untracked(s), "station")
  let cached_rs = fn() {
    match table {
      Some(t) => (t.state)() == 0
      None => {
        let v = station_part_read(core, address, resources_ask(here(), address)).value
        v is Some(Object(_)) && !flag(v, "empty")
      }
    }
  }
  b.pick(fn() { (flag(s(), "online"), cached_rs()) }, fn(p, state) {
    let (online, has_rs) = state
    if online {
      resources_node(p, core, here, address, table?)
    } else if has_rs {
      p.box(fn(k) {
        @sf.style_node(k, fn() { rs_processes })
        @sf.words_node(k, fn() { @sf.t("web-pages.stations.processesSnapshot") }, fn() { st_memory }) |> ignore
        let v = fn() { station_part_read(core, address, resources_ask(here(), address)).value }
        resources_body_node(k, core, address, v, table?)
      })
      |> ignore
    } else {
      let proc_text = fn() { text(field(s(), "overview"), "processesText") }
      p.pick(fn() { proc_text() != "" }, fn(q, has_text) {
        if has_text {
          q.box(fn(k) {
            @sf.style_node(k, fn() { st_diag_head })
            @sf.words_node(k, fn() { @sf.t("web-pages.stations.processesSnapshot") }, fn() { st_memory }) |> ignore
            @sf.words_node(k, proc_text, fn() { st_diag_summary }) |> ignore
          })
          |> ignore
        } else {
          @sf.words_node(q, fn() { @sf.t("web-pages.stations.processesOffline") }, fn() { st_memory }) |> ignore
        }
      })
    }
  })
}

// ── Settings ────────────────────────────────────────────────────────────

///|
/// Unified "运行设置" section: collapsible Agent 环境变量, Spotlight personal search switch, Windows admin elevation switch, Windows screen service switch, and diagnostic logs switch.
fn station_system_node(b : @view.View, core : Core, address : String, s : () -> Json?, manager : Bool, online : () -> Bool) -> Unit {
  let env_list = fn() { items(field(s(), "overview"), "agentEnv") }
  let has_env = fn() { field(field(s(), "overview"), "agentEnv") is Some(Array(_)) && ((online() && manager) || env_list().length() > 0) }
  let env_open = @signals.signal(station_env_open.get(address).unwrap_or(false))
  let search = fn() { field(field(s(), "overview"), "search") }
  let diagnostics = fn() { field(field(s(), "overview"), "diagnostics") }
  let elevation = fn() { field(field(s(), "overview"), "elevation") }
  let screen_service = fn() { field(field(s(), "overview"), "screenService") }
  let auto_chats = fn() { field(field(s(), "overview"), "autoChats") }
  let has_search = fn() { search() is Some(Object(_)) && text(search(), "files") == "spotlight" }
  st_section_node(b, fn() { "运行设置" }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      g.show(fn() { auto_chats() is Some(Object(_)) }, fn(ac) {
        st_switch_node(
          ac,
          core,
          address,
          fn() { @sf.t("web-pages.stations.autoChats.label") },
          fn() { flag(auto_chats(), "enabled") },
          fn() { @sf.t("web-pages.stations.autoChats.line") },
          "autoChats.save",
          "enabled",
          fn() { @sf.t("web-pages.stations.autoChats.what") },
          fn() { online() && flag(auto_chats(), "canEdit") && manager },
        )
      })
      g.show(has_env, fn(ev) {
        @sf.group_rows_node(ev, fn(gr) {
          @sf.link_row_node(
            gr,
            fn() { @sf.t("web-pages.stations.agentEnv") },
            fn() {
              let now = !env_open.untracked()
              station_env_open[address] = now
              env_open.set(now)
            },
            note=fn() { station_env_summary(env_list()) },
            folds=fn() { env_open.get() },
          )
          gr.show(fn() { env_open.get() }, fn(ed) {
            ed.pick(fn() { manager && online() }, fn(p, editable) {
              if editable {
                station_env_editor_node(p, core, address, @ui.Field::new())
              } else {
                p.each(fn() { env_list().mapi(fn(i, e) { (i, e) }) }, fn(x) { x.0 }, fn(row, x) {
                  said_row_node(row, fn() { text(Some(x.get().1), "key") }, note=fn() { text(Some(x.get().1), "value") })
                })
              }
            })
          })
        })
      })
      g.show(has_search, fn(sr) {
        st_switch_node(
          sr,
          core,
          address,
          fn() { @sf.t("web-pages.stations.search.personal") },
          fn() { flag(search(), "personal") },
          fn() { @sf.t("web-pages.stations.search.personalLine") },
          "search.setPersonal",
          "personal",
          fn() { @sf.t("web-pages.stations.search.what") },
          fn() { online() && manager },
        )
      })
      g.show(fn() { elevation() is Some(Object(_)) }, fn(el) {
        st_switch_node(
          el,
          core,
          address,
          fn() { @sf.t("web-pages.stations.elevation.admin") },
          fn() { flag(elevation(), "on") },
          fn() { text(elevation(), "line") },
          "elevation.set",
          "on",
          fn() { @sf.t("web-pages.stations.elevation.what") },
          fn() { online() && flag(elevation(), "canChange") },
          busy=fn() { flag(elevation(), "busy") },
        )
      })
      g.show(fn() { screen_service() is Some(Object(_)) }, fn(ss) {
        st_switch_node(
          ss,
          core,
          address,
          fn() { @sf.t("web-pages.stations.screenService.title") },
          fn() { flag(screen_service(), "on") },
          fn() { text(screen_service(), "line") },
          "screenService.set",
          "on",
          fn() { @sf.t("web-pages.stations.screenService.what") },
          fn() { online() && flag(screen_service(), "canChange") },
          busy=fn() { flag(screen_service(), "busy") },
        )
      })
      g.show(fn() { diagnostics() is Some(Object(_)) }, fn(dg) {
        st_switch_node(
          dg,
          core,
          address,
          fn() { @sf.t("web-pages.stations.diagnostics.logs") },
          fn() { flag(diagnostics(), "logs") },
          fn() { @sf.t("web-pages.stations.diagnostics.logsLine") },
          "diagnostics.setLogs",
          "logs",
          fn() { @sf.t("web-pages.stations.diagnostics.what") },
          fn() { online() && manager },
        )
      })
    })
    sec.show(fn() { text(elevation(), "failed") != "" }, fn(f) {
      @sf.words_node(f, fn() { text(elevation(), "failed") }, fn() { st_problem_bad }) |> ignore
    })
    sec.show(fn() { text(screen_service(), "failed") != "" }, fn(f) {
      @sf.words_node(f, fn() { text(screen_service(), "failed") }, fn() { st_problem_bad }) |> ignore
    })
  })
}

///|
/// Its 登录 (station_logins'): only the logins done there through still.fail; one under way its card (as in its chat), those ended a row per program naming it, who last logged in to it, from
/// which chat, and how many tries, pressed open to them. Nothing when there are none. Away (`online` false), no card of
/// one under way: it can be neither done nor cancelled until it is back.
fn station_logins_node(b : @view.View, core : Core, station : String, online : () -> Bool) -> Unit {
  let view = fn() { station_part_read(core, station, logins_ask(station)).value }
  let active = fn() { station_logins_shown(view(), online()) }
  let tools = fn() { items(view(), "tools") }
  b.show(fn() { flag(view(), "supported") && active().length() + tools().length() > 0 }, fn(p) {
    st_section_node(p, fn() { @sf.t("web-main.logins.title") }, note=fn() { @sf.t("web-main.logins.lead") }, fn(sec) {
      sec.show(fn() { active().length() > 0 }, fn(cards) {
        @sf.style_node(cards, fn() { lg_cards })
        cards.each(active, fn(id) { id }, fn(c, id) {
          login_card_node(c, core, station, id.untracked(), place="station")
        })
      })
      sec.show(fn() { tools().length() > 0 }, fn(gp) {
        @sf.group_node(gp, fn(g) {
          // (a row a program, and under one open a row a try: each a row of the card's)
          let rows = fn() {
            let out : Array[(String, Int)] = []
            for tool in tools() {
              let name = text(Some(tool), "name")
              out.push((name, -1))
              if st_logins_open.get(station) == Some(name) {
                for i, _ in items(Some(tool), "tries") {
                  out.push((name, i))
                }
              }
            }
            out
          }
          let tool_of = fn(name : String) { tools().iter().find_first(fn(t) { text(Some(t), "name") == name }) }
          g.each(rows, fn(r) { r }, fn(row, r) {
            let (name, at) = r.untracked()
            if at < 0 {
              login_tool_row_node(row, station, name, fn() { tool_of(name) })
            } else {
              login_try_row_node(row, fn() { items(tool_of(name), "tries").get(at) })
            }
          })
        })
      })
    })
  })
}

///|
/// A program's row (station_logins'): its maker's mark, bare; its name; who last logged in to it, from which chat (in
/// red where none went through and the latest failed); how many tries at its end; pressed, its tries open or shut.
fn login_tool_row_node(row : @view.View, station : String, name : String, tool : () -> Json?) -> Unit {
  let said = fn() {
    let chat = match text(tool(), "chatTitle") {
      "" => ""
      title => "「" + title + "」"
    }
    join([text(tool(), "summaryText"), chat].filter(fn(w) { w != "" }), " · ")
  }
  let open = fn() { st_logins_open.get(station) == Some(name) }
  @sf.link_row_node(
    row,
    fn() { name },
    fn() { st_logins_open[station] = if @signals.untracked(open) { "" } else { name } },
    note=fn() { if flag(tool(), "failed") { "" } else { said() } },
    trouble=fn() { if flag(tool(), "failed") { said() } else { "" } },
    folds=open,
    // (its maker's mark, bare, in its colours; else a terminal's: one key for all told them apart by nothing)
    lead=LeadMade(fn(l) {
      l.box(fn(m) {
        @sf.style_node(m, fn() { lg_mark })
        @sf.tool_mark_node(m, text(@signals.untracked(tool), "mark"), lg_mark_glyph)
      })
      |> ignore
    }),
    // (how many tries at its end, not as what it says: its name, a station's words, keeps the line)
    tail=fn(t) { @sf.words_node(t, fn() { text(tool(), "countText") }, fn() { lg_count }) |> ignore },
  )
}

///|
/// A try under its program's row (station_logins'): when, how it ended (who ended it says so: 张三 取消; else the status:
/// 已取消), in red where it failed, from which chat; its words where the program's name is.
fn login_try_row_node(row : @view.View, l : () -> Json?) -> Unit {
  @sf.link_row_node(
    row,
    fn() { text(l(), "whenText") },
    fn() {  },
    value=fn() {
      match text(l(), "doneByText") {
        "" => text(l(), "statusText")
        by => by
      }
    },
    value_bad=fn() { text(l(), "state") == "failed" },
    note=fn() {
      match text(l(), "chatTitle") {
        "" => ""
        title => "「" + title + "」"
      }
    },
    goes=false,
    lead=LeadMade(fn(m) { @sf.style_node(m, fn() { lg_no_mark }) }),
  )
}

///|
/// What macOS lets its still.fail Helper do (station_permissions'): a row each, what it is for, given or not; one not
/// given asked for from here (`permissions.request`), its screen opened where it can be driven.
fn station_permissions_node(b : @view.View, core : Core, address : String, p : () -> Json?, online : () -> Bool) -> Unit {
  st_section_node(b, fn() { @sf.t("web-pages.stations.permissions.section") }, note=fn() { text(p(), "note") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      g.each(fn() { items(p(), "grants") }, fn(gr) { text(Some(gr), "id") }, fn(row, gr) {
        let gv = fn() { Some(gr.get()) }
        let gid = text(@signals.untracked(gv), "id")
        let end = fn() {
          if flag(gv(), "granted") {
            "granted"
          } else if !online() {
            "missing"
          } else if flag(gv(), "asking") {
            if text(p(), "screen") != "" { "open" } else { "waiting" }
          } else if flag(p(), "canRequest") {
            "request"
          } else {
            "missing"
          }
        }
        row.pick(end, fn(r, now) {
          let button = now == "open" || now == "request"
          @sf.link_row_node(
            r,
            fn() { text(gv(), "name") },
            fn() {  },
            note=fn() { text(gv(), "line") },
            value=fn() {
              match now {
                "granted" => @sf.t("web-pages.stations.permissions.granted")
                "waiting" => @sf.t("web-pages.stations.permissions.waiting")
                "missing" => @sf.t("web-pages.stations.permissions.missing")
                _ => ""
              }
            },
            goes=false,
            // (a button at its end makes its first line as tall as the button: its mark across that line's middle, by
            // its title, not the body line's above it)
            lead=LeadLine(fn(l) {
              if button {
                l.box(fn(m) {
                  m.height(By(fn() { Some(@sf.button_height()) })).lies_along(Is(Middle)) |> ignore
                  st_mark_node(m, fn() { grant_icon(gid) })
                })
                |> ignore
              } else {
                st_mark_node(l, fn() { grant_icon(gid) })
              }
            }),
            tail?=match now {
              "open" =>
                Some(fn(t) {
                  @sf.button_node(t, fn() { @sf.t("web-pages.stations.permissions.openScreen") }, fn() {
                    open_screen_link(core, text(@signals.untracked(p), "screen"))
                  })
                  |> ignore
                })
              "request" =>
                Some(fn(t) {
                  let busy = fn() { is_doing(core, ["permissions.request"], [("station", address), ("grant", gid)]) }
                  @sf.button_node(t, fn() { @sf.t("web-pages.stations.permissions.request") }, fn() {
                    let screen = text(@signals.untracked(p), "screen")
                    @settings.act(
                      core,
                      @sf.t("web-pages.stations.permissions.requestWhat", args=[("name", text(@signals.untracked(gv), "name"))]),
                      "permissions.request",
                      obj([("station", str(address)), ("grant", str(gid))]),
                      then=fn(answer) {
                        if text(Some(answer), "window") == "up" && flag(Some(answer), "screen") && screen != "" {
                          open_screen_link(core, screen)
                        }
                      },
                    )
                  }, tone=Primary, busy~, disabled=busy)
                  |> ignore
                })
              _ => None
            },
          )
        })
      })
    })
  })
}

///|
/// Its agents' variables (station_env's): its managers edit them as a .env file's lines in the core's draft
/// (`agentEnvForm`) on a card, saved with 保存; the others see them, a secret's value masked.
fn station_env_node(b : @view.View, core : Core, address : String, env : () -> Json?, manager : Bool) -> Unit {
  if manager {
    st_section_node(b, fn() { @sf.t("web-pages.stations.agentEnv") }, note=fn() { @sf.t("web-pages.stations.agentEnvLead") }, fn(sec) {
      @sf.page_card_node(sec, footed=true, fn(k) { station_env_editor_node(k, core, address, @ui.Field::new()) })
    })
    return
  }
  let list = fn() {
    match env() {
      Some(Array(a)) => a
      _ => []
    }
  }
  b.show(fn() { list().length() > 0 }, fn(p) {
    st_section_node(p, fn() { @sf.t("web-pages.stations.agentEnv") }, fn(sec) {
      @sf.group_node(sec, fn(g) {
        g.each(fn() { list().mapi(fn(i, e) { (i, e) }) }, fn(x) { x.0 }, fn(row, x) {
          said_row_node(row, fn() { text(Some(x.get().1), "key") }, note=fn() { text(Some(x.get().1), "value") })
        })
      })
    })
  })
}

///|
/// The draft of station `address`'s variables its editor follows (station_env_editor's): the one opened for it here,
/// else one opened now (the core's `agentEnv.form.open`, by an id of this device's), once: as the editor is first built,
/// or as its 设置 is pressed (station_block_asks), whichever is first.
fn station_env_form(core : Core, address : String) -> String {
  match env_forms.get(address) {
    Some(f) => f
    None => {
      env_forms_made.val += 1
      let f = "mbui-env-" + env_forms_made.val.to_string()
      env_forms[address] = f
      @settings.act(core, @sf.t("web-pages.stations.agentEnvRead"), "agentEnv.form.open", obj([("station", str(address)), ("form", str(f))]))
      f
    }
  }
}

///|
/// The draft of a station's variables (station_env_editor's) in node `k`, typed in `field_`: the field (following the
/// draft every page of it shares, the latest edit kept while the core catches up), what is wrong under it (a line the
/// core cannot take), 取消 while changed, 保存. What is typed told the core as it is typed; one typed while it saves,
/// once it is done.
fn station_env_editor_node(k : @view.View, core : Core, address : String, field_ : @ui.Field) -> Unit {
  let form = station_env_form(core, address)
  let d = fn() { station_part_read(core, address, station_env_form_ask(address, form)).value }
  let draft = match env_drafts.get(address) {
    Some(draft) => draft
    None => {
      let draft : EnvDraft = { pending: @signals.signal(None, same=fn(a, b) { a == b }), reset: @signals.signal(0), source: None, sent: None }
      env_drafts[address] = draft
      draft
    }
  }
  // (the core's words as it says them, while it is not saving)
  let said = fn() {
    match d() {
      Some(Object(_)) as v if !flag(v, "pending") => Some(text(v, "text"))
      _ => None
    }
  }
  // (what the core says becomes what the draft holds, and clears what was pending where it is that: an older answer for
  // an older edit leaves a newer edit be)
  let known : @signals.Signal[String?] = @signals.signal(draft.source, same=fn(a, b) { a == b })
  k.reacts(said, fn(now) {
    match now {
      Some(words) => {
        draft.source = now
        known.set(now)
        if draft.pending.untracked() == Some(words) {
          draft.pending.set(None)
          draft.sent = None
        }
      }
      None => ()
    }
  })
  let source = fn() {
    match draft.pending.get() {
      Some(_) as p => p
      None => known.get()
    }
  }
  // Keep the latest edit visible on every page while the core catches up: the field follows what the draft holds.
  k.reacts(fn() { (source(), draft.reset.get()) }, fn(now) {
    match now.0 {
      Some(words) => field_.follow(words, generation=now.1)
      None => ()
    }
  })
  // The core cannot edit a form while it saves: an edit typed then is shared at once, and sent once saving finishes;
  // an older acknowledgement never clears or resends a newer value.
  k.reacts(fn() { (draft.pending.get(), d()) }, fn(now) {
    match now {
      (Some(words), Some(Object(_)) as v) if !flag(v, "pending") && text(v, "text") != words && draft.sent != Some(words) => {
        draft.sent = Some(words)
        station_env_edit(core, address, form, words)
      }
      _ => ()
    }
  })
  // what the person types here, as they type it (the field's edit, never what it is given to follow): the draft's,
  // told the core once it can take it. Typed before the core has said the form's words (just opened, it has not
  // answered yet) or while it saves, it is pending and sent as the core says them (the reaction above).
  let typed = fn(typed : String) {
    let known = @signals.untracked(source)
    if known != Some(typed) {
      draft.pending.set(Some(typed))
      if known is None || flag(@signals.untracked(d), "pending") {
        draft.sent = None
      } else {
        draft.sent = Some(typed)
        station_env_edit(core, address, form, typed)
      }
    }
  }
  let saving = fn() { is_doing(core, ["agentEnv.form.save"], [("station", address), ("form", form)]) }
  let read = fn() { d() is Some(Object(_)) && text(d(), "text") == field_.text() }
  k.box(fn(e) {
    @sf.style_node(e, fn() { st_editor })
    // (first in its card, a block in its corners: `corner_inset` in, a row's corner, its words on the card's line:
    // @sf.card_block_out)
    e.box(fn(f) {
      @sf.style_node(f, fn() { @sf.card_block_out(top=true) })
      @sf.textarea_node(f, field_, rows=6, placeholder=env_placeholder, corner=@sf.row_corner, edited=typed) |> ignore
    })
    |> ignore
    // what is wrong, a line each
    let problems = fn() {
      if !read() {
        return []
      }
      let out : Array[(Int, String, Bool)] = []
      for i, l in items(d(), "lines") {
        let lv = Some(l)
        if text(lv, "problem") != "" {
          out.push((i + 1, text(lv, "problem"), flag(lv, "error")))
        }
      }
      out
    }
    e.show(fn() { problems().length() > 0 }, fn(ps) {
      @sf.style_node(ps, fn() { st_env_problems })
      ps.each(problems, fn(x) { x.0 }, fn(l, x) {
        @sf.words_node(l, fn() {
          @sf.t("web-pages.stations.agentEnvLine", args=[("line", x.get().0.to_string()), ("problem", x.get().1)])
        }, fn() { if x.get().2 { st_problem_bad } else { st_problem } })
        |> ignore
      })
    })
    // (its buttons at its foot's end, reaching its foot corners: card_foot's at_end)
    e.box(fn(a) {
      @sf.style_node(a, fn() { st_env_foot.then(@sf.foot_across(@sf.button_height())) })
      a.show(fn() { flag(d(), "dirty") }, fn(c) {
        @sf.button_node(c, fn() { @sf.t("common.cancel") }, fn() {
          @signals.start_batch()
          draft.pending.set(None)
          draft.sent = None
          draft.reset.set(draft.reset.untracked() + 1)
          @signals.end_batch()
          @settings.act(
            core,
            @sf.t("web-pages.stations.agentEnvEdit"),
            "agentEnv.form.edit",
            obj([("station", str(address)), ("form", str(form)), ("input", obj([("reset", Json::boolean(true))]))]),
          )
        }, tone=Ghost)
        |> ignore
      })
      let can = fn() {
        let v = d()
        v is Some(Object(_)) && flag(v, "dirty") && !flag(v, "pending") && !saving() && read() && count(v, "errors") == 0
      }
      @sf.button_node(a, fn() { @sf.t("common.save") }, fn() {
        @settings.act(
          core,
          @sf.t("web-pages.stations.agentEnvSave"),
          "agentEnv.form.save",
          obj([("station", str(address)), ("form", str(form))]),
          done=@sf.t("web-pages.profiles.saved"),
        )
      }, tone=Primary, busy=saving, disabled=fn() { !can() })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A switch of its 设置 (search's, diagnostics', context's, elevation's): `title`, on as `on` says, `note` under it,
/// turned (the core's `call` with `key` set to what it is to be, said `what`) by its managers only; waiting on what was
/// set meanwhile.
fn st_switch_node(
  g : @view.View,
  core : Core,
  address : String,
  title : () -> String,
  on : () -> Bool,
  note : () -> String,
  call : String,
  key : String,
  what : () -> String,
  can : () -> Bool,
  busy? : () -> Bool = fn() { false },
) -> Unit {
  let busy = fn() { is_doing(core, [call], [("station", address)]) || busy() }
  @sf.switch_row_node(
    g,
    title,
    on,
    fn(now) { @settings.act(core, what(), call, obj([("station", str(address)), (key, Json::boolean(now))])) },
    note~,
    disabled=fn() { !can() },
    busy~,
  )
}

///|
/// What its search finds of the machine (station_search's): whether the person's own mail and the like are found too.
fn station_search_node(b : @view.View, core : Core, address : String, search : () -> Json?, manager : Bool) -> Unit {
  st_section_node(b, fn() { @sf.t("web-pages.stations.search.section") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      st_switch_node(
        g,
        core,
        address,
        fn() { @sf.t("web-pages.stations.search.personal") },
        fn() { flag(search(), "personal") },
        fn() { @sf.t("web-pages.stations.search.personalLine") },
        "search.setPersonal",
        "personal",
        fn() { @sf.t("web-pages.stations.search.what") },
        fn() { manager },
      )
    })
  })
}

///|
/// What it sends still.fail to find its problems by (station_diagnostics'): whether its log goes, scrubbed.
fn station_diagnostics_node(b : @view.View, core : Core, address : String, diagnostics : () -> Json?, manager : Bool) -> Unit {
  st_section_node(b, fn() { @sf.t("web-pages.stations.diagnostics.section") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      st_switch_node(
        g,
        core,
        address,
        fn() { @sf.t("web-pages.stations.diagnostics.logs") },
        fn() { flag(diagnostics(), "logs") },
        fn() { @sf.t("web-pages.stations.diagnostics.logsLine") },
        "diagnostics.setLogs",
        "logs",
        fn() { @sf.t("web-pages.stations.diagnostics.what") },
        fn() { manager },
      )
    })
  })
}

///|
/// How it goes on with a session whose prompt cache is over (station_context's): the station default, and once it is
/// on, its estimated cost threshold changed from the section's title (its managers').
fn station_context_node(b : @view.View, core : Core, address : String, context : () -> Json?, manager : Bool) -> Unit {
  let cost = fn() {
    match field(context(), "afreshAbove") {
      Some(Number(value, ..)) => Some(value)
      _ => None
    }
  }
  let on = fn() { flag(context(), "afreshWhenCold") }
  let busy = fn() { is_doing(core, ["context.setAfresh"], [("station", address)]) }
  st_section_node(
    b,
    fn() { @sf.t("web-pages.stations.context.section") },
    ends=(fn() { cost() is Some(_) && on() && manager }, fn(e) {
      @sf.action_node(e, fn() { @sf.t("web-pages.stations.context.customAmount") }, fn() {
        match @signals.untracked(cost) {
          Some(value) => station_cold_custom(core, address, value)
          None => ()
        }
      }, disabled=busy)
    }),
    fn(sec) {
      @sf.group_node(sec, fn(g) {
        @sf.switch_row_node(
          g,
          fn() { @sf.t("web-pages.stations.context.afresh") },
          on,
          fn(now) {
            @settings.act(
              core,
              @sf.t("web-pages.stations.context.what"),
              "context.setAfresh",
              obj([("station", str(address)), ("afreshWhenCold", Json::boolean(now))]),
            )
          },
          note=fn() {
            match cost() {
              Some(value) if value == 0.0 => @sf.t("web-pages.stations.context.afreshZeroLine")
              Some(value) => @sf.t("web-pages.stations.context.afreshCostLine", args=[("amount", "$" + value.to_string())])
              None => @sf.t("web-pages.stations.context.afreshLineLegacy")
            }
          },
          disabled=fn() { !manager },
          busy~,
        )
      })
    },
  )
}

///|
/// Whether a Windows station runs as the machine's administrator (station_elevation's): switched by the workspace's
/// managers, Windows asking on the machine and the station restarting; how the last change failed under it.
fn station_elevation_node(b : @view.View, core : Core, address : String, elevation : () -> Json?) -> Unit {
  st_section_node(b, fn() { @sf.t("web-pages.stations.elevation.section") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      st_switch_node(
        g,
        core,
        address,
        fn() { @sf.t("web-pages.stations.elevation.admin") },
        fn() { flag(elevation(), "on") },
        fn() { text(elevation(), "line") },
        "elevation.set",
        "on",
        fn() { @sf.t("web-pages.stations.elevation.what") },
        fn() { flag(elevation(), "canChange") },
        busy=fn() { flag(elevation(), "busy") },
      )
    })
    sec.show(fn() { text(elevation(), "failed") != "" }, fn(f) {
      @sf.words_node(f, fn() { text(elevation(), "failed") }, fn() { st_problem_bad }) |> ignore
    })
  })
}

///|
/// Its advanced network controls (station_network's), folded until asked for: opened, a row of its card under the row
/// that folds them, the congestion controller chosen for the next station start.
fn station_network_node(b : @view.View, core : Core, address : String, network : () -> Json?, manager : Bool) -> Unit {
  // (open as the settings keep it, by station: turned here, told there as well)
  let open = @signals.signal(@settings.station_network_open.get(address).unwrap_or(false))
  @sf.group_node(b, fn(g) {
    @sf.link_row_node(g, fn() { @sf.t("web-pages.stations.network.advanced") }, fn() {
      let now = !open.untracked()
      @settings.station_network_open[address] = now
      open.set(now)
    }, folds=fn() { open.get() })
    g.show(fn() { open.get() }, fn(o) {
      @sf.setting_node(o, fn() { @sf.t("web-pages.stations.network.algorithm") }, note=fn() { @sf.t("web-pages.stations.network.note") }, in_card=true, fn(c) {
        let busy = fn() { is_doing(core, ["network.setCongestion"], [("station", address)]) }
        @sf.select_node(
          c,
          fn() { text(network(), "congestion") },
          fn() { ["cubic", "bbr"].map(fn(algorithm) { (algorithm, @sf.t("web-pages.stations.network." + algorithm)) }) },
          fn(algorithm) {
            @settings.act(
              core,
              @sf.t("web-pages.stations.network.what"),
              "network.setCongestion",
              obj([("station", str(address)), ("congestion", str(algorithm))]),
              done=@sf.t("web-pages.stations.network.saved"),
            )
          },
          label=fn() { @sf.t("web-pages.stations.network.algorithm") },
          disabled=fn() { !manager || busy() },
          whole=true,
        )
      })
    })
  })
}

///|
/// The workspaces it is in (station_workspaces'), for its home's owners and admins once it is in more than one: its
/// home first, what each has of the machine.
fn station_workspaces_node(b : @view.View, core : Core, address : String) -> Unit {
  let m = fn() { station_part_read(core, address, station_memberships_ask(address)).value }
  let ws = fn() { items(m(), "workspaces") }
  b.show(fn() { flag(m(), "manages") && ws().length() >= 2 }, fn(p) {
    let has_tasks = fn() { ws().iter().any(fn(w) { text(Some(w), "mode") == "tasks" }) }
    st_section_node(p, fn() { "Workspace" }, count=fn() { ws().length() }, note=fn() {
      @sf.t(if has_tasks() { "web-pages.stations.workspacesLeadMixed" } else { "web-pages.stations.workspacesLead" })
    }, fn(sec) {
      @sf.group_node(sec, fn(g) {
        g.each(fn() { ws().mapi(fn(i, w) { (i, w) }) }, fn(x) { x.0 }, fn(row, x) {
          let wv = fn() { Some(x.get().1) }
          row.pick(fn() { @sf.has_station_mark(text(wv(), "emoji"), text(wv(), "icon")) }, fn(r, marked) {
            said_row_node(r, fn() { text(wv(), "name") }, note=fn() { text(wv(), "line") }, lead=if marked {
              LeadLine(fn(l) { @sf.station_mark_node(l, fn() { text(wv(), "emoji") }, fn() { text(wv(), "icon") }, st_ws_mark, fn() { @sf.theme().p.text }, fn() { 0 }) })
            } else {
              NoLead
            })
          })
        })
      })
    })
  })
}

// ── Machine ─────────────────────────────────────────────────────────────

///|
/// Its software (station_machine's 软件与更新): its versions (updated by its home's managers), away a line saying they
/// cannot be seen; its own version where it lists none.
fn station_software_node(b : @view.View, core : Core, s : () -> Json?, manager : Bool, online : () -> Bool, tips : @sf.TipLayer) -> Unit {
  let station = text(@signals.untracked(s), "station")
  let updates = fn() { items(field(s(), "overview"), "updates") }
  st_section_node(b, fn() { @sf.t("web-pages.stations.software") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      // (its rows the card's own; offline shows cached software versions read-only, falling back to a note only when none are cached)
      software_list_node(g, core, station, updates, manager, fn() { flag(s(), "betaOffered") }, online, tips)
      g.show(fn() { !online() && updates().length() == 0 }, fn(r) { said_row_node(r, fn() { @sf.t("web-pages.stations.softwareOffline") }) })
      g.show(fn() { updates().length() == 0 && text(s(), "version") != "" }, fn(r) {
        said_row_node(r, fn() { "Station " + text(s(), "version") })
      })
    })
  })
}

///|
/// A station's software (software_list's): a row each, then when it was last checked, with checking again.
fn software_list_node(
  g : @view.View,
  core : Core,
  station : String,
  updates : () -> Array[Json],
  manager : Bool,
  beta : () -> Bool,
  online : () -> Bool,
  tips : @sf.TipLayer,
) -> Unit {
  let batch = fn() { is_doing(core, ["software.updateAll"], [("station", station)]) }
  g.each(updates, fn(u) { text(Some(u), "id") }, fn(row, u) {
    let id = text(Some(u.untracked()), "id")
    software_row_node(row, core, station, fn() { Some(u.get()) }, manager, fn() {
      batch() || is_doing(core, ["software.update"], [("station", station), ("id", id)])
    }, beta, online, tips)
  })
  // (in lines: checking again after when it was last checked, under it where the line has not the room; why it failed a
  // line of its own)
  g.show(fn() { updates().length() > 0 }, fn(f) {
    let checked = fn() {
      match field(updates().get(0), "checkedAt") {
        Some(Number(n, ..)) => Some(n)
        _ => None
      }
    }
    f.box(fn(foot) {
      @sf.style_node(foot, fn() { sw_foot })
      foot.wraps(Is(Some(sw_foot_lines))) |> ignore
      @sf.words_node(foot, fn() {
        match checked() {
          None => @sf.t("web-main.versions.checkingVersions")
          Some(n) => @sf.t("web-main.versions.lastChecked", args=[("time", @settings.short_date_time(n))])
        }
      }, fn() { sw_foot_words })
      |> ignore
      foot.show(fn() { software_failed.get(station) is Some(_) }, fn(w) {
        @sf.words_node(w, fn() { software_failed.get(station).unwrap_or("") }, fn() { sw_failed_line }) |> ignore
      })
      foot.show(fn() { online() && checked() is Some(_) }, fn(w) {
        let checking = fn() { is_doing(core, ["software.check"], [("station", station)]) }
        @sf.action_box_node(w, fn() { @sf.t("web-main.versions.check") }, disabled=checking, fn(_) {
          software_call(core, station, "software.check", [])
        }, fn(k) {
          @sf.style_node(k, fn() { sw_check })
          @sf.words_node(k, fn() {
            if checking() {
              @sf.t("web-main.versions.checking")
            } else {
              @sf.t("web-main.versions.check")
            }
          }, fn() { if @sf.lit_node(k) && !checking() { sw_check_lit } else { sw_check_words } })
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
}

///|
/// One piece of software (software_row's): its mark; its name and what is newer with updating it on its first line;
/// its version (what more there is of it beside it, under the hand), what an update under way or done says, why it
/// cannot be updated and the station's own
/// switches (its channel, updating by itself, for its managers) under them, as wide as its words.
fn software_row_node(
  row : @view.View,
  core : Core,
  station : String,
  v : () -> Json?,
  manager : Bool,
  busy : () -> Bool,
  beta : () -> Bool,
  online : () -> Bool,
  tips : @sf.TipLayer,
) -> Unit {
  let id = text(@signals.untracked(v), "id")
  let own = id == "station"
  let switches = fn() {
    online() &&
    own &&
    manager &&
    ((beta() && has(v(), "channel")) || (has(v(), "auto") && !flag(v(), "overridden")) || software_earlier(v()).length() > 0)
  }
  let call = fn(name : String, params : Array[(String, Json)]) { software_call(core, station, name, params) }
  @sf.item_row_node(row, fn(r) {
    // (its mark on its first line, never centred on the lines under it (its version, what an update says, its switches):
    // the row's parts from its top, and its first line at least as tall as the mark, across whose middle the name and
    // what stands at its end are)
    r.lines_up(Is(Some(Start))) |> ignore
    r.box(fn(m) {
      @sf.style_node(m, fn() { sw_mark }, in_row=true)
      if own {
        m.pick(fn() { @sf.theme().dark }, fn(k, dark) {
          @sf.drawable_node(k, if dark { "stillfail_mark_dark" } else { "stillfail_mark" }, sw_glyph) |> ignore
        })
      } else {
        @sf.maker_mark_node(m, "", id, sw_glyph) |> ignore
      }
    })
    |> ignore
    @sf.row_lines_node(r, spaced=true, fn(h) {
      h.min_height(Is(Some(sw_mark_d))).wraps(Is(Some(6.0))).lies_along(Is(Between)) |> ignore
      h.box(fn(n) {
        @sf.style_node(n, fn() { sw_name_line }, in_row=true)
        n.shrink(Is(0.0)) |> ignore
        @sf.words_node(n, fn() { text(v(), "name") }, fn() { sw_name }) |> ignore
        n.show(fn() { text(v(), "channel") == "beta" && !switches() }, fn(tag) {
          @sf.style_node(tag, fn() { sw_beta })
          @sf.words_node(tag, fn() { @sf.t("web-main.versions.beta") }, fn() { sw_beta_words }) |> ignore
        })
      })
      |> ignore
      h.pick(fn() { (software_end(v()), online()) }, fn(e, state) {
        let (end, is_online) = state
        @sf.style_node(e, fn() { sw_rest })
        software_end_node(e, end, v, manager && is_online, busy, call)
      })
    }, fn(u) {
      u.box(fn(vb) {
        @sf.style_node(vb, fn() { sw_version_box })
        vb.points(Is(true)) |> ignore
        @sf.words_node(vb, fn() { text(v(), "shownText") }, fn() { sw_version }) |> ignore
        if text(@signals.untracked(v), "tipText") != "" {
          @sf.tip_node(tips, vb, fn() { text(v(), "tipText") }) |> ignore
        }
      })
      |> ignore
      // what it says of an update under way or done: a sentence, on a line of its own under its version, never beside
      // its name, which it would squeeze there on a narrow page
      u.show(fn() { software_said(v()) != "" }, fn(w) {
        @sf.words_node(w, fn() { software_said(v()) }, fn() { sw_note }) |> ignore
      })
      u.show(fn() { text(v(), "note") != "" }, fn(w) { @sf.words_node(w, fn() { text(v(), "note") }, fn() { sw_note }) |> ignore })
      // station-only update notes: held after rollback, local override note, and fix-gated/paused auto-update status
      if own {
        u.show(fn() { text(v(), "autoAfter") != "" }, fn(w) {
          @sf.words_node(w, fn() { @sf.t("web-main.versions.autoAfter", args=[("version", text(v(), "autoAfter"))]) }, fn() { sw_note })
          |> ignore
        })
        u.show(fn() { text(v(), "overrideNote") != "" }, fn(w) {
          @sf.words_node(w, fn() { text(v(), "overrideNote") }, fn() { sw_note }) |> ignore
        })
        u.show(fn() { software_override_auto_note(v()) != "" }, fn(w) {
          @sf.words_node(w, fn() { software_override_auto_note(v()) }, fn() { sw_note }) |> ignore
        })
      }
      u.show(fn() { text(v(), "state") == "failed" && text(v(), "message") != "" }, fn(w) {
        @sf.words_node(w, fn() { text(v(), "message") }, fn() { sw_note }) |> ignore
      })
      // the station's own: which releases it takes, and whether it takes them by itself
      u.show(switches, fn(sw) {
        @sf.style_node(sw, fn() { sw_switches })
        sw.show(fn() { beta() && has(v(), "channel") }, fn(l) {
          software_switch_node(
            l,
            tips,
            fn() { @sf.t("web-main.versions.beta") },
            fn() { @sf.t("web-main.versions.betaStation") },
            fn() { text(v(), "channel") == "beta" },
            fn(now) { call("software.channel", [("channel", str(if now { "beta" } else { "stable" }))]) },
            fn() { is_doing(core, ["software.channel"], [("station", station)]) },
            busy,
            fn() { @sf.t("web-main.versions.betaNote") },
          )
        })
        sw.show(fn() { has(v(), "auto") && !flag(v(), "overridden") }, fn(l) {
          software_switch_node(
            l,
            tips,
            fn() { @sf.t("web-main.versions.auto") },
            fn() { @sf.t("web-main.versions.auto") },
            fn() { flag(v(), "auto") },
            fn(now) { call("software.auto", [("on", Json::boolean(now))]) },
            fn() { is_doing(core, ["software.auto"], [("station", station)]) },
            busy,
            fn() { @sf.t(if flag(v(), "idleOnly") { "web-main.versions.autoIdleTip" } else { "web-main.versions.autoTip" }) },
          )
        })
        // back to a release before (the ones its channel's feed names): which one picked in a menu, then asked
        sw.show(fn() { software_earlier(v()).length() > 0 }, fn(l) {
          // (its chevron in the words' own ink: the link's default, the theme's blue, is not the Link words' colour here)
          @sf.link_opens_node(l, fn() { @sf.t("web-main.versions.back") }, chevron=true, ink=fn() { @ui.style_ink(@sf.link) }, on=fn() { !busy() }, fn(b) {
            let now = @signals.untracked(v)
            @sf.menu(
              software_earlier(now).map(fn(version) {
                Some(@sf.menu_item_of(version, further=true, fn() { software_back_ask(now, version, call) }))
              }),
              from=Node(b),
              title=@sf.t("web-main.versions.backTo"),
            )
          })
          |> ignore
        })
      })
    })
  })
}

///|
/// What a piece of software has at its first line's end, by how it stands (software_row's): updating (how far, what it
/// says under its version), failed (why, trying again), to repair, to install, newer (updating to it), a way back to the
/// stable release; nothing.
fn software_end(v : Json?) -> String {
  let state = text(v, "state")
  if state == "updating" {
    "updating"
  } else if state == "failed" {
    "failed"
  } else if flag(v, "overridden") {
    "restore"
  } else if flag(v, "repairable") {
    "repair"
  } else if !flag(v, "installed") {
    "install"
  } else if flag(v, "newer") && text(v, "latest") != "" {
    "newer"
  } else if flag(v, "downgrade") && text(v, "latest") != "" {
    "downgrade"
  } else {
    ""
  }
}

///|
/// Formatted fix conditions (`autoWhen`) that trigger automatic restore/update once released.
fn software_auto_when(v : Json?) -> Array[String] {
  items(v, "autoWhen").filter_map(fn(e) {
    match e {
      String(s) if s != "" => Some(s)
      _ => None
    }
  })
}

///|
/// Status note for an overridden station's conditional or paused auto-update.
fn software_override_auto_note(v : Json?) -> String {
  let when = software_auto_when(v)
  if when.length() > 0 {
    let sep = if @sf.language() == "en" { ", " } else { "、" }
    @sf.t("web-main.versions.autoWhen", args=[("conditions", when.join(sep))])
  } else if flag(v, "autoHeld") {
    @sf.t("web-main.versions.overrideHeld")
  } else {
    ""
  }
}

///|
/// Asks before restoring an overridden station `v` back to the official signed release on its channel.
fn software_restore_ask(v : Json?, call : (String, Array[(String, Json)]) -> Unit) -> Unit {
  let latest = text(v, "latest")
  let note = if latest != "" {
    @sf.t("web-main.versions.restoreNote", args=[("latest", latest)])
  } else {
    @sf.t("web-main.versions.restoreNoteNoLatest")
  }
  confirm(
    @sf.t("web-main.versions.restoreAsk"),
    note,
    @sf.t("web-main.versions.restoreDo"),
    fn() { call("software.update", [("id", str("station"))]) },
  )
}

///|
/// The releases the station can go back to (its `earlier`), newest first.
fn software_earlier(v : Json?) -> Array[String] {
  items(v, "earlier").filter_map(fn(e) {
    match e {
      String(s) => Some(s)
      _ => None
    }
  })
}

///|
/// Asks before the station `v` goes back to `version` (software_row's 退回旧版本): what it does, and what becomes of its
/// updating by itself; said, `call` puts it back.
fn software_back_ask(v : Json?, version : String, call : (String, Array[(String, Json)]) -> Unit) -> Unit {
  confirm(
    @sf.t("web-main.versions.backAsk", args=[("version", version)]),
    @sf.t(if flag(v, "auto") { "web-main.versions.backNoteAuto" } else { "web-main.versions.backNote" }, args=[
      ("version", version),
      ("current", text(v, "shownText")),
    ]),
    @sf.t("web-main.versions.backDo"),
    fn() { call("software.update", [("id", str("station")), ("to", str(version))]) },
  )
}

///|
/// What a piece of software says of its update under its version (software_row's): how one under way goes, or, with
/// nothing else at its first line's end, that one is done.
fn software_said(v : Json?) -> String {
  match software_end(v) {
    "updating" => text(v, "updatingText")
    "" => text(v, "done")
    _ => ""
  }
}

///|
/// What software_end says is at its first line's end, made in `e`: its words, and the button that does it (where its
/// managers may: updating it, or repairing it where that is what it needs; not again while that is under way).
fn software_end_node(
  e : @view.View,
  end : String,
  v : () -> Json?,
  manager : Bool,
  busy : () -> Bool,
  call : (String, Array[(String, Json)]) -> Unit,
) -> Unit {
  let id = text(@signals.untracked(v), "id")
  let button = fn(label : () -> String, primary : Bool) {
    if manager && flag(@signals.untracked(v), "updatable") {
      @sf.button_node(e, label, fn() { call("software.update", [("id", str(id))]) }, tone=if primary { Primary } else { Plain }, disabled=busy)
      |> ignore
    }
  }
  let repair = fn(label : () -> String) {
    if manager && flag(@signals.untracked(v), "repairable") {
      @sf.button_node(e, label, fn() { call("software.update", [("id", str(id)), ("repair", Json::boolean(true))]) }, tone=Primary, disabled=busy)
      |> ignore
    }
  }
  let words = fn(said : () -> String, look : @ui.TextStyle) { @sf.words_node(e, said, fn() { look }) |> ignore }
  match end {
    "updating" => {
      e.show(fn() { field(v(), "percent") is Some(Number(_, ..)) }, fn(bar) {
        bar.width(Is(Some(sw_progress_w))) |> ignore
        @sf.progress_node(bar, fn() { Some(number(v(), "percent") / 100.0) }, fn() { @ui.tree_theme().line }, fn() {
          @sf.theme().p.accent
        })
        |> ignore
      })
    }
    "failed" => {
      words(fn() { text(v(), "failedText") }, sw_failed)
      if flag(@signals.untracked(v), "repairable") {
        repair(fn() { @sf.t("common.retry") })
      } else {
        button(fn() { @sf.t("common.retry") }, false)
      }
    }
    "restore" =>
      if manager && flag(@signals.untracked(v), "updatable") {
        @sf.button_node(e, fn() { @sf.t("web-main.versions.restoreOfficial") }, fn() {
          software_restore_ask(@signals.untracked(v), call)
        }, tone=Primary, disabled=busy)
        |> ignore
      }
    "repair" => repair(fn() { @sf.t("web-main.versions.repairNpm") })
    "install" => button(fn() { @sf.t("web-main.versions.install") }, false)
    "newer" => {
      words(fn() { text(v(), "latest") }, sw_newer)
      button(fn() { @sf.t("web-main.versions.update") }, true)
    }
    "downgrade" => {
      words(fn() { text(v(), "latest") }, sw_newer)
      button(fn() { @sf.t("web-main.versions.backToStable") }, false)
    }
    _ => ()
  }
}

///|
/// One of the station's own switches under its version (software_row's): its `word`, a small switch (read out
/// `label`), on as `on` says, `turn` told what it is to be; a ring before it while what it set is on its way (`doing`),
/// not turned while the station's software is (`busy`); what it means (`tip`) beside it under the hand.
fn software_switch_node(
  l : @view.View,
  tips : @sf.TipLayer,
  word : () -> String,
  label : () -> String,
  on : () -> Bool,
  turn : (Bool) -> Unit,
  doing : () -> Bool,
  busy : () -> Bool,
  tip : () -> String,
) -> Unit {
  l.box(fn(line) {
    @sf.style_node(line, fn() { sw_switch_line })
    line.points(Is(true)) |> ignore
    @sf.words_node(line, word, fn() { sw_switch_word }) |> ignore
    line.show(doing, fn(s) { @sf.spinner_node(s, size=@sf.spinner_inline) |> ignore })
    @sf.switch_node(line, on, turn, label, small=true, disabled=fn() { busy() || doing() })
    @sf.tip_node(tips, line, tip) |> ignore
  })
  |> ignore
}

///|
/// Diagnostic key-value rows with a vertically aligned value column that wraps cleanly on narrow screens and large
/// font scales while keeping first-line baseline alignment between label and value.
fn diag_meta_node(k : @view.View, rows : () -> Array[(String, String)]) -> Unit {
  let numbered = fn() { rows().mapi(fn(i, r) { (i, r) }) }
  k.box(fn(list) {
    @sf.style_node(list, fn() { st_diag_meta })
    list.each(numbered, fn(x) { x.0 }, fn(row, x) {
      @sf.style_node(row, fn() { st_diag_meta_row })
      row.box(fn(lbl) {
        lbl.min_width(Is(Some(st_diag_label_w))) |> ignore
        @sf.words_node(lbl, fn() { x.get().1.0 }, fn() { hd_label }) |> ignore
      })
      |> ignore
      row.box(fn(val) {
        @sf.style_node(val, fn() { st_diag_meta_val_box }, in_row=true)
        val.min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(val, fn() { x.get().1.1 }, fn() { st_diag_meta_val }) |> ignore
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// Compact per-route dial attempt rows: first-line aligned status dot, aligned route name column, and wrapping result.
fn diag_ways_node(k : @view.View, ways : () -> Array[Json]) -> Unit {
  let numbered = fn() { ways().mapi(fn(i, w) { (i, w) }) }
  k.box(fn(list) {
    @sf.style_node(list, fn() { st_diag_ways })
    list.each(numbered, fn(x) { x.0 }, fn(row, x) {
      let wv = fn() { Some(x.get().1) }
      @sf.style_node(row, fn() { st_diag_way_row })
      row.box(fn(dot) {
        @sf.style_node(dot, fn() { st_diag_way_dot }, in_row=true)
        @sf.state_dot_node(dot, fn() {
          match text(wv(), "status") {
            "ok" => "online"
            "timeout" => "busy"
            "refused" | "error" => "error"
            _ => "offline"
          }
        })
      })
      |> ignore
      row.box(fn(name) {
        name.min_width(Is(Some(st_diag_label_w))) |> ignore
        @sf.words_node(name, fn() { text(wv(), "name") }, fn() { st_diag_way_name }) |> ignore
      })
      |> ignore
      row.box(fn(res) {
        @sf.style_node(res, fn() { st_diag_meta_val_box }, in_row=true)
        res.min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(res, fn() { text(wv(), "resultText") }, fn() { st_diag_meta_val }) |> ignore
      })
      |> ignore
    })
  })
  |> ignore
}

// ── styles ──────────

///|
/// The machine's figures in its block (station_overview's: @sf.block's 12 apart).
// kept across runs: a value (no field of it changes)
let st_resources_in : @ui.Style = @ui.css("w=Full gap=S3")

///|
/// A program's mark's side in its row (station_logins' 20).
let lg_mark_glyph : Double = 20.0

///|
/// A footed card's buttons at its end (card_foot's at_end: pg_card_foot_end).
// kept across runs: a value (no field of it changes)
let st_env_foot : @ui.Style = @ui.css("row w=Full gap=S2 justify=JEnd align=ACenter")

///|
/// The software's foot's lines apart where checking again goes under (software_list's line_gap).
let sw_foot_lines : Double = 4.0

///|
/// A station's page opened by a press, where what opens waits for what it shows (sfbase's route_open_then): once the
/// station is answered, what the part shown reads as it is first drawn, as a press on that part asks it
/// (station_part_asks), so the page opens with every block of it whole. Read once, as it is (nothing followed: what
/// it read of the workspace's is held by the app).
fn init {
  @sfbase.station_open_more.val = fn(src, w, address, s) {
    @signals.untracked(fn() {
      let core = @sfbase.settings_core(src, w)
      let here = @settings.here_of(core, w.id, w.name)
      let part = match @settings.station_parts.get(address) {
        Some(p) if station_part_names.contains(p) => p
        _ => "overview"
      }
      // (whether it is managed matters to its 设置 alone)
      let manager = part == "settings" && {
        let r = role_of(core, here)
        r == "owner" || r == "admin"
      }
      station_part_asks(core, here, address, Some(s), manager, part)
    })
  }
}
