// What the settings' pages (src/sfapp/settings) read and call, and how they move (@settings.Core): the core's topics
// and calls, the stack, toasts, the system's pickers and browser, notifications, updates, this Mac's station, the
// faces, the bars; one for every frame (settings_core), what the shell does asked of the shell.

///|
/// What the settings' pages read and call, and how they move: the core as the app has it (Source), the app's stack,
/// the shell's way home (what is over the pages put down too)
/// and the pages' card to share of the workspace's agents at work (`share_card_of`). One for every frame.
pub fn settings_core(src : Source, w : Workspace) -> @settings.Core {
  settings_core_of(
    src,
    w,
    home=fn() { (shell.val.home)() },
    share_card=fn() { (share_card_of.val)(src, w) },
  )
}

///|
/// A sign-in to a service as the person, its token kept in their vault (@settings.Core's vault_oauth: sfcore's
/// vault_oauth): by workspace, vault, provider and request. Given as the app starts; with none given it says it failed.
// kept across runs: what the app says once as it starts
pub let vault_oauth_of : Ref[(String, String, String, String, (Result[String, String]) -> Unit) -> Unit] = Ref(fn(
  _,
  _,
  _,
  _,
  done,
) {
  done(Err(""))
})

///|
/// The card to share of the workspace's agents at work, as the pages open it (sfpages' share_card_open), given as the
/// app starts.
// kept across runs: what the app says once as it starts
pub let share_card_of : Ref[(Source, Workspace) -> Unit] = Ref(fn(_, _) {  })

///|
/// settings_core's, its way home (`home`) and the card to share
/// (`share_card`) given.
fn settings_core_of(
  src : Source,
  w : Workspace,
  home~ : () -> Unit,
  share_card~ : () -> Unit,
) -> @settings.Core {
  // (a station's terminal from its page: the page it is)
  @settings.open_terminal_of.val = fn(station, terminal, cwd) {
    open_page(Terminal({ station, terminal, watch: false, cwd }))
  }
  // (概览 switched to from the accounts' list once what it shows is answered, the list meanwhile, and what was asked
  // handed to it as the list's pages hand theirs: the shells' shown_read of "profiles-list")
  @settings.overview_switch.val = fn(ws, go, on_cancel) {
    let scope = { "scope": Json::string(ws) }
    let wait = switch_answered(
      src,
      [station_rows_ask(ws), ("profiles", scope), ("profilesOverview", scope)],
      "profiles-list\u{1}" + ws,
      go,
      let_go=on_cancel,
    )
    fn() { wait.give_up() }
  }
  {
    topic: fn(name, params) {
      let topic = src.topic(name, params)
      let read = fn() -> @settings.Read {
        let t = topic.get()
        { value: t.value, error: t.error, version: t.version }
      }
      @signals.computed_scoped(fn(_) { read() }, untracked_read=Some(fn() {
        if held_building.val { Some(read()) } else { None }
      }))
    },
    call: fn(name, params, done) { (src.call)(name, params, done) },
    push: fn(r) {
      match r {
        @settings.Route::Home => open_page(Settings)
        // (an account's page once what it shows is answered, the screen as it was meanwhile: account_open.mbt)
        _ => {
          let open = fn() { open_page(Setting(r)) }
          // (an account's page timed for the host from the press: open_timing)
          let open = if route_asks(w.id, r).is_empty() { open } else { timed_open("account", open) }
          // (a station's and a connect's too where what opens waits for what it shows: route_open_asks)
          open_answered(src, route_open_asks(src, w, r), open, then?=route_open_then(src, w, r), most?=route_open_most(src, w, r))
          |> ignore
        }
      }
    },
    pop: fn() { go_back() |> ignore },
    in_place: fn(r) { open_in_place(Setting(r)) },
    home,
    open_chat: fn(station, session, title) {
      // its station's name, as the chats' rows have it
      let stations = station_rows(src, w.id)
      let mut name = ""
      match stations.value {
        Some(Array(a)) =>
          for x in a {
            if text(Some(x), "station") == station {
              name = text(Some(x), "name")
            }
          }
        _ => ()
      }
      open_page(Chat({ station, session, title, station_name: name }))
    },
    open_drive: fn(station) { open_page(Drive({ station, root: None, path: "" })) },
    open_folder: fn(station, root) { open_page(Drive({ station, root: Some(root), path: "" })) },
    sign_in: fn() { (src.sign_in)() },
    say: fn(words) {
      toast_later(words)
    },
    picture: fn(url, frame) { (src.picture)(url, frame) },
    now: src.now,
    notify_ask: fn() { ask_from_switch() },
    push_sync: fn(wanted) { if !src.read_only { push_sync(src, wanted) } },
    under: fn() {
      match app.nav.under() {
        Some(Home) => "chats"
        Some(Settings | Setting(@settings.Route::Home)) => "settings"
        _ => ""
      }
    },
    version_now: fn() { update_stands() },
    version_tap: fn() { update_row_tapped(src) },
    version_check: fn() { update_dialog(src) },
    update_auto_on,
    local_install: fn(join) { if join { local_station_install(src, w.id) } else { local_station_update() } },
    // the system's browser (LocalUriHandler.openUri); nothing took it, said so (android-misc.link.cantOpen)
    open_link: fn(url) {
      if !@ui.open_url(url) {
        toast_later(@sf.t("android-misc.link.cantOpen"))
      }
    },
    vault_oauth: fn(ws, vault, provider, request, done) { (vault_oauth_of.val)(ws, vault, provider, request, done) },
    open_screen: fn(station, screen) { open_page(Screen({ station, screen, title: "", until_gone: true })) },
    pick_picture: fn(done) {
      @ui.pick(@hostapi.PickKind::Photos, on_got=fn(files) { done(files.get(0).map(fn(f) { f.bytes })) }) is Some(_)
    },
    bars: fn() { bars_in(src, w.id) },
    set_bars: fn(sets, cur) { set_bars(src, w.id, sets, cur) },
    reporting: fn() { reporting_on(src) },
    set_reporting: fn(on) {
      match reporting_host.get() {
        Some(h) => {
          (h.set)(on)
          reporting_said.set(Some(on))
        }
        // (where the core sends what people use and the host keeps no switch: the prefs' `reports`)
        None =>
          @settings.set_pref_with(
            fn(name, params, done) { (src.call)(name, params, done) },
            fn(said) { toast_later(said) },
            "reports",
            if on {
              ""
            } else {
              "off"
            },
          )
      }
    },
    share_card,
    face_preview: fn(id, index, variable) { face_preview(src, id, index, variable) },
    face_here: face_here,
    face_failed: face_failed,
    own_code_face: own_code_preview,
    read_only: if src.read_only { read_only_words } else { "" },
    devices_on: src.asks_devices,
    move_on: fn() { (src.asks_station_move)() },
    workspaces_on: fn() { (src.asks_station_workspaces)() },
    terminals_on: fn() { (src.asks_terminals)() },
  }
}

///|
/// Whether usage statistics and error reports go out from this device, as the host keeps it (src/stillfail
/// reports.mbt: Android's Crashes.reporting, the app's prefs); None where nothing is sent anyway: no settings row then.
pub(all) struct ReportingHost {
  get : () -> Bool
  set : (Bool) -> Unit
}

///|
/// The host's, set once as the app starts (src/stillfail main); None under a Tester (reset), unless its test sets one.
// (by the one host: functions, no value to compare)
pub let reporting_host : @signals.Signal[ReportingHost?] = @signals.signal_ref(None)

///|
/// Whether this device's core sends what people use (the prefs' `counted`, client/core-ts/src/use-counts.ts: a build
/// given still.fail's PostHog project, on still.fail's own cloud); not so under a Tester or a replay, whose core says
/// nothing of it, so the app tells it nothing of it there either.
pub fn core_counts(src : Source) -> Bool {
  match src.topic("prefs", {}).get().value {
    Some(Object(m)) => m.get("counted") is Some(True)
    _ => false
  }
}

///|
/// Whether this device's core sends its traces (the prefs' `traced`, client/core-ts/src/trace.ts), on any cloud: one on
/// monoid's sends them as one on still.fail's does, so the switch is shown and told there too. Not so under a Tester or
/// a replay, whose core says nothing of it (a recorded trace's calls stay as recorded).
pub fn core_traces(src : Source) -> Bool {
  match src.topic("prefs", {}).get().value {
    Some(Object(m)) => m.get("traced") is Some(True)
    _ => false
  }
}

///|
/// Whether usage statistics and error reports go out from this device: as the host's switch is, where it keeps one;
/// else, where the core sends what people use or its traces, as the prefs' `reports` say (on unless `off`); None where
/// nothing is sent (no settings row then).
pub fn reporting_on(src : Source) -> Bool? {
  reporting_said.get() |> ignore
  match reporting_host.get() {
    Some(h) => Some((h.get)())
    None =>
      if core_counts(src) || core_traces(src) {
        Some(@settings.pref_from(src.topic("prefs", {}).get().value, "reports") != "off")
      } else {
        None
      }
  }
}

///|
/// What the app tells a core that counts what people use or sends its traces (core_counts, core_traces): whether to,
/// as the settings say (reporting_on), and, while it counts, what it shows by its kind alone ("" where it does not
/// count, or is not to); None while nothing is to be told.
pub fn reports_told(src : Source, shown : String) -> (Bool, String)? {
  let counts = core_counts(src)
  if !counts && !core_traces(src) {
    return None
  }
  let on = reporting_on(src).unwrap_or(true)
  Some((on, if on && counts { shown } else { "" }))
}

///|
/// What this device was last set here to send them or not (None: not set here; what reads it reads the host again as
/// it is set otherwise).
// kept across runs: put back with the host (pages_reset)
let reporting_said : @signals.Signal[Bool?] = @signals.signal(None, same=fn(a, b) { a == b })
