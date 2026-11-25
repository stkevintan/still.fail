// The page's pane's stack held by the window's tree (@ui.nav_flat_view: the pane beside the block on Large, the tape's
// page panel on Medium): each page of the stack made once as nodes (pane_made): what waits to be confirmed
// in the workspace's safe mode in its place, else the page moved aside as the folded sidebar is shown a while, its
// words picked by the pointer (a finger picks them as on a phone).

///|
/// The stack in the pane off the tape (Large) as a node of `v`'s: each page made once (pane_made); a page put in
/// place shown as pane_page_wait says, at its causes; nothing pushed over slides here (shown in place as any other).
/// While the workspace waits to be confirmed in its safe mode, what waits in its place instead, the stack none of it
/// (nothing of it pressed, nothing of it back), as the frame had it before.
fn pane_pages(v : @view.View, src : Source, tips : @sf.TipLayer) -> Unit {
  let gated = fn() {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) => fold_target(src, w, v.window_w()).0.gated
      None => false
    }
  }
  // (the page on top switched, as the stack is told it, before any page of it is built; none while what waits in the
  // safe mode is in the pages' place. An old page works out its bars from the block's move as it is built (pane_page_one).
  page_switch_said(v, fn() { @sfbase.workspace_in_view(src).0 is Some(_) && !gated() })
  // (what waits in its place giving back the focus as it goes, to what had it as it came: the page under it kept, laid
  // out nowhere meanwhile (none of it built, pressed or read out), the focus in it let go of then, after it is kept)
  v.show(gated, at_once=true, fn(g) {
    g.grow(Is(1.0)).focus_returns() |> ignore
    pane_gate_node(g, src)
  })
  v.box(fn(s) {
    s.grow(Is(1.0)).laid_nowhere(By(gated)) |> ignore
    pane_stack(s, src, tips)
  })
  |> ignore
}

///|
/// What waits to be confirmed in the workspace's safe mode in the pane off the tape, in node `g` (all of the pane), made
/// once for the workspace in view: on the page's ground, sfpages' page (lock_wait_node); over its top the window's
/// title bar where its buttons are in the app's top row (pane_made_host's), and the workspace's button where the
/// system's tabs are the rail (gate_heading_node).
fn pane_gate_node(g : @view.View, src : Source) -> Unit {
  g.ground(By(fn() { @sf.theme().p.bg })) |> ignore
  g.switch_by(fn() { @sfbase.workspace_in_view(src).0.map(fn(w) { w.id }) }, fn(p, _id) {
    // (all of the pane, as the page it is in the place of; what waits clear of the column of the system's bars down
    // the window's trailing edge, an iPhone Duo's on its side (@sf.native_clear), the page's ground on under it)
    p.over(Is(true)).padding(By(fn() { (0.0, 0.0, @sf.native_clear(), 0.0) })) |> ignore
    guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
    let core = settings_core(src, w)
    @sfpages.lock_wait_node(p, core, @settings.here_of(core, w.id, w.name)).grow(Is(1.0)) |> ignore
    p.show(fn() { @ui.window_inset() }, fn(t) {
      t
      .over(Is(true))
      .height(By(fn() { Some(@sf.wide_bar_h + @sf.window_keys_bar_over_now()) }))
      .presses(Is(true))
      .moves_window(Is(true))
      |> ignore
    })
    p.show(@sf.native_on, fn(h) {
      h.over(Is(true)) |> ignore
      gate_heading_node(h, src, w)
    })
  })
}

///|
/// The workspace's button (its icon and name in the system's glass: chats.mbt workspace_heading, the bars'
/// workspace-switch) over the top of the page that waits, in node `h` (over all of the pane), where the sidebar's head
/// would have it: the sidebar is not shown while the device waits, and where the rail's places are the system's tabs
/// those hold no workspaces, so with nothing to switch with a person was held in the workspace until a trusted device
/// approved this one (the user, 2026-11-03; the web's SecurityWaiting keeps its WorkspaceSwitcher over the page,
/// cloud/workspace.tsx Bare). The rail has the workspaces where it is the app's own, the narrow frame's Home bar its
/// switch (sfapp lock_gate). Its place handed to the system's glass as it is read out (native_sidebar_items, by its
/// node's id), let go with it.
fn gate_heading_node(h : @view.View, src : Source, w : Workspace) -> Unit {
  let inset = fn() {
    let list = @sf.theme().chat_list
    list.band_in + list.heading_in
  }
  @sf.host_button_anchor_node(h, fn() { w.name }, fn(b) {
    b
    .width(By(fn() {
      Some(dmin(dmax(side_min, wide.side_w.get()), pane_w_at(src, b) - @sf.native_clear() - 2.0 * inset()))
    }))
    .height(By(fn() { Some(@sf.band_row_h()) }))
    .offset(By(fn() { (inset(), side_top_web + band_new_top) }))
    |> ignore
    let id = @ui.tree_read_out_id(b)
    native_workspace_hooked()
    b.reacts(fn() { native_workspace_item(src, w) }, fn(item) {
      native_sidebar_items[id] = item
      native_workspace_anchor.val = Node(b)
      native_floating_schedule()
    })
    b.owns(fn() {
      native_sidebar_items.remove(id)
      match native_workspace_anchor.val {
        Node(n) if n.id() == b.id() => native_workspace_anchor.val = Unanchored
        _ => ()
      }
      native_floating_schedule()
    })
    |> ignore
  })
  |> ignore
}

///|
/// Whether the pane's page of entry `k` shows (Nav::shows), for what it holds put to rest while another covers it in
/// the pane; as it last was while what is on top is over the whole window (a drive's text read, a film played, a
/// station's screen: the pane under it as it was, back to it as it was left), and once its entry has left the stack,
/// let go as it is, never put to rest on the way.
fn pane_shows(k : Int) -> () -> Bool {
  let last = Ref(true)
  fn() {
    match app.nav.page_of(k) {
      Some((p, _)) if app.nav.shelved(p) != Some(k) &&
        !(app.nav.top() is (Screen(_) | Terminal(_) | DriveRead(_) | DrivePlay(_))) =>
        last.val = app.nav.shows(k)
      _ => ()
    }
    last.val
  }
}

///|
/// Pause remote screens when `Place("remote")` is parked on the nav shelf (`keeps_holds=false` pauses
/// `remote_workbench_node`'s own `v.reacts` while shelved) and resume the active screen when returning to it.
fn remote_shelf_pause_node(v : @view.View, src : Source) -> Unit {
  let was_shelved = Ref(false)
  v.reacts(
    fn() {
      let _ = app.nav.pages()
      let shelved = app.nav.shelved(Place("remote")) is Some(_)
      let ws = @sfbase.workspace_in_view(src).0.map(fn(w) { w.id })
      (shelved, ws)
    },
    fn(cur) {
      let (shelved, ws) = cur
      if shelved == was_shelved.val {
        return
      }
      was_shelved.val = shelved
      guard ws is Some(wid) else { return }
      let (tabs, active) = @signals.untracked(fn() { @sfbase.remote_tabs_of(src, wid) })
      if shelved {
        let top = @signals.untracked(fn() { app.nav.top() })
        for tab in tabs {
          match tab.1 {
            @sfbase.RemoteTab::Screen(at) => {
              let shown_aside = @signals.untracked(fn() { side_screen_shown(src, at.station, at.screen) })
              let shown_full = top is Screen(t) && t.station == at.station && t.screen == at.screen
              if !shown_aside && !shown_full {
                @sfpages.screen_covered(src, at.station, at.screen, true)
              }
            }
            _ => ()
          }
        }
      } else if @signals.untracked(fn() { app.nav.top() }) == Place("remote") {
        for tab in tabs {
          if tab.0 == active {
            if tab.1 is @sfbase.RemoteTab::Screen(at) {
              @sfpages.screen_covered(src, at.station, at.screen, false)
            }
            break
          }
        }
      }
    },
  )
}

///|
fn pane_stack(v : @view.View, src : Source, tips : @sf.TipLayer) -> Unit {
  remote_shelf_pause_node(v, src)
  @ui.nav_flat_view(
    v,
    app.nav,
    fn(_c, _p) {  },
    fn(p) { (fold_goes.ready)(p) },
    fold_goes.most,
    bg=fn() { @sf.theme().p.bg },
    stacks=fn() { false },
    made=fn(p) { pane_made(src, p, tips) },
    // (which show, as the stack stands whole: the page made once that shows, by its entry)
    shown=fn(ks) { fold_goes.shown = ks },
    // (a chat's page made as nodes left kept, taken back as it is opened again: sfbase's chat_page_left_key)
    keeps_left=@sfbase.chat_page_left_key,
    keeps_made=true,
  )
  |> ignore
}

///|
/// The pages of the library's made once as nodes in the pane off the tape (Large), in the place of their old view
/// (nav_flat_view's `made`): 关于, 记忆, 更新日志, 一台 station 的记忆; 归档, a station's own archiving, 自动决策; 用量,
/// 价目表; a chat (and the new chat that becomes it), its old view in it as yet (chat_page_made). Laid out by the width the frame gives the pane (the window's less the block's column where its move goes:
/// fold_target's, never what the page last laid out), narrow or wide (page_node), each made again only as that
/// arrangement changes. What the old view's island did for the page done by its node (pane_made_host).
fn pane_made(
  src : Source,
  page : Page,
  tips : @sf.TipLayer,
) -> (String, (@view.View, () -> Page, Page?, () -> Int, Int) -> Unit)? {
  // (made in the workspace in view, its settings' core, under what it was opened from, as wide as the frame gives it)
  let made_k = fn(
    kind : String,
    f : (@view.View, @settings.Core, () -> @settings.Here, () -> Int, () -> @sf.PageFrame, () -> Double, Int) -> Unit,
  ) {
    Some(
      (
        kind,
        fn(v : @view.View, page : () -> Page, under : Page?, stint : () -> Int, k : Int) {
          v.switch_by(fn() { @sfbase.workspace_in_view(src).0.map(fn(w) { w.id }) }, fn(p, _id) {
            guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
            let core = settings_core(src, w)
            let here = fn() { @settings.here_of(core, w.id, w.name) }
            @settings.frame(core, @signals.untracked(here))
            // (a dialog a fixture's mode puts up over its page, before the page is made: setting_page's)
            settings_fixture(src, core)
            pane_made_host(p, src, k)
            // (back over it only under another settings page or a place of the rail's: setting_page's; a place of the
            // rail's itself, none, whatever is under it: place_page's; its words read as they are said, in the
            // language now)
            let frame = fn() -> @sf.PageFrame {
              {
                back: match (page(), under) {
                  (Place(_), _) => None
                  (_, Some(u)) if u is (Setting(_) | Place(_)) => Some(@sfbase.back_label(u))
                  _ => None
                },
                top: 0.0,
                foot: 0.0,
                named: false,
              }
            }
            let width = fn() {
              let ww = p.window_w()
              match @sfbase.workspace_in_view(src).0 {
                Some(w) => ww - fold_target(src, w, ww).1.col
                None => ww
              }
            }
            p.box(fn(a) {
              a.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
              f(a, core, here, stint, frame, width, k)
            })
            |> ignore
          })
        },
      ),
    )
  }
  let made = fn(
    kind : String,
    f : (@view.View, @settings.Core, () -> @settings.Here, () -> Int, () -> @sf.PageFrame, () -> Double) -> Unit,
  ) {
    made_k(kind, fn(a, core, here, stint, frame, width, _k) { f(a, core, here, stint, frame, width) })
  }
  match page {
    // (Home: the board while it is chosen, else its ground: board.mbt)
    Home => Some(board_home_made(src, tips))
    // (the settings come to beside their list: its first row's page, made once as that page is)
    Settings | Setting(Home) => pane_made(src, Setting(settings_landing), tips).map(fn(m) { ("settings/" + m.0, m.1) })
    Setting(About) =>
      made("about", fn(a, core, _here, _stint, frame, width) {
        @sfpages.about_node(a, core, on_back=core.pop, frame~, width~)
      })
    Setting(Memories) =>
      made("memories", fn(a, core, here, _stint, frame, width) {
        @sfpages.memories_node(a, core, here, on_back=core.pop, frame~, width~)
      })
    Setting(Changelog) =>
      made("changelog", fn(a, core, _here, _stint, frame, width) {
        @sfpages.changelog_node(a, core, on_back=core.pop, frame~, width~)
      })
    // (the profiles' place: the profile picked in its list, made once as its page is; none to pick yet, the first to add)
    Place("profiles") =>
      made("place/profiles", fn(a, core, here, stint, frame, width) {
        profiles_place_node(a, src, core, here, stint, frame, width, tips~)
      })
    // (the stations' place: the station picked in its list made once as its page is, none the first to add)
    Place("stations") =>
      made("place/stations", fn(a, core, here, stint, frame, width) {
        stations_place_node(a, src, core, here, stint, frame, width, tips~)
      })
    Place("remote") =>
      Some(
        (
          "place/remote",
          fn(v, _page, _under, _stint, k) {
            v.switch_by(fn() { @sfbase.workspace_in_view(src).0.map(fn(w) { w.id }) }, fn(p, ws_id) {
              guard ws_id is Some(wid) else { return }
              pane_made_host(p, src, k)
              let ends = pane_chat_bar_ends(src, p)
              let width = fn() { pane_w_at(src, p) }
              @sfpages.remote_workbench_node(
                p,
                src,
                fn() { @sfbase.workspace_in_view(src).0.map_or(wid, fn(w) { w.id }) },
                tips,
                start_pad=fn() { dmax(12.0, (ends.start)(true)) },
                end_pad=fn() { (ends.end)(false, false) },
                width~,
                shown=pane_shows(k),
                keep_screen=fn(st, sc) {
                  side_screen_shown(src, st, sc) ||
                  (app.nav.top() is Screen(top) && top.station == st && top.screen == sc)
                },
              )
            })
          },
        ),
      )
    // (a place of the rail's whose page is one of those: that page, at the stack's root (no back over it, place_page's),
    // made under its own kind)
    Place(name) =>
      match @settings.route_of(name) {
        // (those whose old view is gone: every frame makes them once, as a page or a place)
        Some(r) if @settings.made_once(r) =>
          pane_made(src, Setting(r), tips).map(fn(m) { ("place/" + m.0, m.1) })
        _ => None
      }
    // (by its station: another station's another page, not this one become it)
    Setting(Memory(address)) =>
      made("memory/" + address, fn(a, core, here, _stint, frame, width) {
        @sfpages.memory_node(a, core, here, address, on_back=core.pop, frame~, width~, tips~)
      })
    // 文件 and a station's drive (sfpages' files_page_node.mbt): one kind for all of them, the files' page's tabs kept
    // as the folder in front changes (its address, the page as it is now)
    Files =>
      made_k("files-home", fn(a, _core, _here, _stint, frame, width, k) {
        guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
        // (at rest while a page covers it in the pane: shown=)
        @sfpages.files_home_node(a, src, w.id, frame~, width~, on_back=fn() { @sfbase.go_back() |> ignore }, tips~, shown=pane_shows(k), arrives=fn() { app.nav.top() is Files })
      })
    Drive(_) =>
      made_k("files", fn(a, _core, _here, _stint, frame, width, k) {
        guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
        // (its own entry's folder, as it is now (what it became in place): kept shown while the page in its place
        // waits, it shows what it showed, never that one's)
        let own = fn() {
          match app.nav.page_of(k) {
            Some((Drive(d), _)) => Some(d)
            _ => None
          }
        }
        let last = Ref(@signals.untracked(own).unwrap_or({ station: "", root: None, path: "" }))
        let at = fn() {
          match own() {
            Some(d) => last.val = d
            None => ()
          }
          last.val
        }
        @sfpages.drive_page_node(a, src, w.id, at, frame~, width~, on_back=fn() { @sfbase.go_back() |> ignore }, go=files_go, tips~, shown=pane_shows(k), arrives=fn() { app.nav.top() is Drive(_) })
      })
    // (a web service whose chat the station has not said, or that it does not find: service_beside_node)
    Service(station, job) =>
      made("service/" + station + "/" + job, fn(a, _core, _here, _stint, _frame, _width) {
        service_beside_node(a, src, station, job)
      })
    // (已归档, none of its chats beside the sidebar's list of them: what it is)
    Archived => made("archived", fn(a, _core, _here, _stint, _frame, _width) { archive_main_node(a) })
    Setting(Archive) =>
      made("archive", fn(a, core, here, _stint, frame, width) {
        @sfpages.archive_node(a, core, here, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(Archiving) =>
      // (its pictures asked for again each time it is come back to, not each frame it stays: nav_flat_view's stint)
      made("archiving", fn(a, core, here, stint, frame, width) {
        @sfpages.archiving_node(a, core, here, on_back=core.pop, frame~, stint~, width~)
      })
    Setting(AutoDecisions) =>
      made("auto-decisions", fn(a, core, here, _stint, frame, width) {
        @sfpages.decisions_node(a, core, here, on_back=core.pop, frame~, width~, tips~)
      })
    // (by its station: another station's another page, not this one become it)
    Setting(StationArchiving(st)) =>
      made("station-archiving/" + st, fn(a, core, here, _stint, frame, width) {
        @sfpages.station_archiving_node(a, core, here, st, on_back=core.pop, frame~, width~)
      })
    Setting(Backup) =>
      made("backup", fn(a, core, here, stint, frame, width) {
        @sfpages.backup_node(a, core, here, on_back=core.pop, frame~, stint~, width~)
      })
    Setting(StationBackup(st)) =>
      made("station-backup/" + st, fn(a, core, here, _stint, frame, width) {
        @sfpages.station_backup_node(a, core, here, st, on_back=core.pop, frame~, width~)
      })
    Setting(StationMove(st)) =>
      made("station-move/" + st, fn(a, core, here, _stint, frame, width) {
        @sfpages.station_move_node(a, core, here, st, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(Shortcuts) =>
      // (recording while it is the one on top of the stack: its stay there, stint's)
      made("shortcuts", fn(a, core, _here, stint, frame, width) {
        @sfpages.shortcuts_node(a, core, on_back=core.pop, frame~, active=fn() { app.nav.top_stay().1 == stint() }, width~)
      })
    Setting(Notifications) =>
      // (a workspace's picture asked for again each time it is come back to: nav_flat_view's stint)
      made("notifications", fn(a, core, here, stint, frame, width) {
        @sfpages.notify_node(a, core, here, on_back=core.pop, frame~, stint~, width~)
      })
    // (by its station, skill and the part first shown: another's another page)
    Setting(MemoryDoc(address, skill, at)) =>
      made("memory-doc/" + address + "/" + skill + "/" + at.to_string(), fn(a, core, here, _stint, frame, width) {
        @sfpages.memory_doc_node(a, core, here, address, skill, at, on_back=core.pop, frame~, width~)
      })
    Setting(AutoPolicy(st)) =>
      made("auto-policy/" + st, fn(a, core, here, _stint, frame, width) {
        @sfpages.policy_node(a, core, here, st, on_back=core.pop, frame~, width~)
      })
    Setting(Appearance) =>
      made("appearance", fn(a, core, _here, _stint, frame, width) { @sfpages.appearance_node(a, core, on_back=core.pop, frame~, width~) })
    Setting(Experimental) =>
      made("experimental", fn(a, core, _here, _stint, frame, width) { @sfpages.experimental_node(a, core, on_back=core.pop, frame~, width~) })
    // the stations' list, the profiles' (by station: another station's another page) and an account's on several
    // stations (sfpages' stations_list.mbt, profiles_list.mbt)
    Setting(Stations) =>
      made("stations", fn(a, core, here, _stint, frame, width) {
        @sfpages.stations_list_node(a, core, here, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(Profiles("")) =>
      made("profiles/", fn(a, core, here, _stint, frame, width) {
        @sfpages.profiles_page_node(a, src, core, here, @settings.profiles_narrow_overview, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(Profiles(only)) =>
      made("profiles/" + only, fn(a, core, here, _stint, frame, width) {
        @sfpages.profiles_list_node(a, core, here, only, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(ProfileAccount(key)) =>
      made("profile-account/" + key, fn(a, core, here, _stint, frame, width) {
        @sfpages.profile_account_node(a, core, here, key, on_back=core.pop, frame~, width~, tips~)
      })
    // (by its station and id: another's another page)
    Setting(Profile(address, id)) =>
      made("profile/" + address + "/" + id, fn(a, core, here, stint, frame, width) {
        @sfpages.profile_node(a, core, here, address, id, on_back=core.pop, frame~, width~, tips~, stint~)
      })
    Setting(NewProfile(address)) =>
      made("new-profile/" + address, fn(a, core, here, _stint, frame, width) {
        @sfpages.new_profile_node(a, core, src, here, address, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(LocalStation) =>
      made("local-station", fn(a, core, _here, _stint, frame, width) {
        @sfpages.local_station_node(a, core, on_back=core.pop, frame~, width~)
      })
    // (by its station: another station's another page, not this one become it)
    Setting(Station(address)) =>
      made("station/" + address, fn(a, core, here, stint, frame, width) {
        @sfpages.station_node(a, core, src, here, address, on_back=core.pop, frame~, width~, stint~)
      })
    Setting(Permissions) =>
      made("permissions", fn(a, core, _here, _stint, frame, width) {
        @sfpages.permissions_node(a, core, on_back=core.pop, frame~, width~)
      })
    Setting(Me) =>
      made("me", fn(a, core, here, stint, frame, width) {
        @sfpages.me_node(a, core, here, on_back=core.pop, frame~, stint~, width~)
      })
    Setting(Fonts) =>
      made("fonts", fn(a, core, _here, _stint, frame, width) { @sfpages.fonts_node(a, core, on_back=core.pop, frame~, width~) })
    Setting(BarSettings) =>
      made("bars", fn(a, core, _here, _stint, frame, width) { @sfpages.bars_node(a, core, on_back=core.pop, frame~, width~) })
    Setting(Security) =>
      made("security", fn(a, core, here, stint, frame, width) {
        @sfpages.security_node(a, core, here, on_back=core.pop, frame~, stint~, width~)
      })
    Setting(SecurityOpen) =>
      made("security-open", fn(a, core, here, _stint, frame, width) {
        @sfpages.security_open_node(a, core, here, on_back=core.pop, frame~, width~)
      })
    Setting(Workspace) =>
      made("workspace", fn(a, core, here, stint, frame, width) {
        @sfpages.workspace_node(a, core, here, on_back=core.pop, frame~, stint~, width~, tips~)
      })
    Setting(VaultItems) =>
      made("vault-items", fn(a, core, here, _stint, frame, width) {
        @sfpages.vault_items_node(a, core, here, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(KeptFiles) =>
      made("kept", fn(a, core, _here, _stint, frame, width) { @settings.kept_node(a, core, on_back=core.pop, frame~, width~, tips~) })
    // (by its station and thread: another chat's another page)
    Setting(KeptChat(station, thread)) =>
      made("kept/" + station + "/" + thread.to_string(), fn(a, core, _here, _stint, frame, width) {
        @settings.kept_chat_node(a, core, station, thread, on_back=core.pop, frame~, width~, tips~)
      })
    // (by the station whose step is said first: another station's another page)
    Setting(AdbShare(focus)) =>
      made("adb/" + focus, fn(a, core, here, _stint, frame, width) {
        @settings.adb_node(a, core, focus, on_back=core.pop, frame~, width~, tips~, sub=fn() { here().sub })
      })
    Setting(Vault) =>
      made("vault", fn(a, core, here, _stint, frame, width) { @sfpages.vault_node(a, core, here, on_back=core.pop, frame~, width~, tips~) })
    // (by its vault and item: another's another page)
    Setting(VaultItem(vault, item)) =>
      made("vault-item/" + vault + "/" + item, fn(a, core, here, _stint, frame, width) {
        @sfpages.vault_item_node(a, core, here, vault, item, on_back=core.pop, frame~, width~, tips~)
      })
    // (by its station and id: another's another page)
    Setting(Connects(only)) =>
      made("connects/" + only, fn(a, core, here, stint, frame, width) {
        @sfpages.connects_node(a, src, core, here, only, on_back=core.pop, frame~, stint~, width~, tips~)
      })
    Setting(Connect(station, id)) =>
      made("connect/" + station + "/" + id, fn(a, core, here, stint, frame, width) {
        @sfpages.connect_node(a, src, core, here, station, id, on_back=core.pop, frame~, stint~, width~, tips~)
      })
    Setting(AutoCompletion) =>
      made("auto-completion", fn(a, core, here, _stint, frame, width) {
        @sfpages.completion_node(a, core, here, on_back=core.pop, frame~, width~, tips~)
      })
    Setting(Usage) =>
      made("usage", fn(a, core, here, _stint, frame, width) {
        @sfpages.usage_node(a, core, src, here, on_back=core.pop, frame~, width~, tips~)
      })
    // (by its days: another's of other days another page)
    Setting(UsagePrices(days)) =>
      made("usage-prices/" + days.to_string(), fn(a, core, here, _stint, frame, width) {
        @sfpages.usage_prices_node(a, core, here, days, on_back=core.pop, frame~, width~)
      })
    // (a chat, and the new chat that becomes one in place: the same page, a node of the tree's)
    page if @sfbase.chat_page_is(page) =>
      Some(
        (
          @sfbase.chat_page_kind(),
          fn(v, _page, _under, stint, k) {
            // (beside it its side panel, the tree's, reading by the page's source, let go with it: side_panel_node)
            v.row(Is(true)).grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
            let page_src : Ref[Source] = Ref(src)
            v.box(fn(p) {
              p.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))) |> ignore
              // (its bar the tree's, over the page: chat_bar_wide_node, keeping clear of the window's corner)
              page_src.val = @sfbase.chat_page_made(
                p,
                src,
                k,
                drawn=fn(serial) { pane_page_wait.draws(serial) },
                over=fn(o, src, page, stint) {
                  chat_bar_wide_node(o, src, page, pane_chat_bar_ends(src, o, page~), tips, stint)
                },
                // (its messages nodes, its composer made as nodes in their list's foot)
                body=fn(col, s, r, composer, shows, on_stack) {
                  pane_made_chat(col, k)
                  context_node(col)
                  chat_body_nodes(col, s, r, tips, stint, composer, shows, visible=fn() { pane_page_wait.is_shown(k) }, on_stack~)
                },
                // (its composer made as nodes in the list's foot: sfpages' chat_composer_node)
                foot_node=fn(n, s, r, shows, laid) {
                  @sfpages.chat_composer_node(
                    n,
                    s,
                    r,
                    shows~,
                    laid~,
                    tips~,
                    apart=fn() { wide.tape.get() },
                    over_it=fn(o) { wide_composer_bar_node(o, s, r, tips, stint) },
                    over_tall=fn() { 36.0 },
                  )
                },
                // (its column on the page's way as the side panel or left sidebar slides beside it: laid out as at its target end)
                narrower=fn(s, n) { pane_chat_narrower(s, n, k) },
                // (moved aside with the folded block over it, in the same offset as the way across: chat_page_made's)
                aside=fn(n) { if app.nav.page_of(k) is Some((Chat(_), _)) { pane_aside_at(src, n) } else { 0.0 } },
                // (the new chat it is till it becomes one, made as nodes: sfpages' new_chat_node)
                new_node=fn(n, s) {
                  match @signals.untracked(fn() { @sfbase.workspace_in_view(s).0 }) {
                    // (as wide as the frame gives the pane (made_k's), less its 文件 beside it at rest where that is open:
                    // new_side_node's, laid out narrow or wide by where it comes to, not on its way)
                    Some(w) =>
                      @sfpages.new_chat_node(n, s, w, new_frame_node(s, w, fn() {
                        let ww = n.window_w()
                        let pane = ww - fold_target(s, w, ww).1.col
                        let beside = pane >= side_both_least &&
                          new_files_open(s, w.id) &&
                          new_drive_station(s, w) is Some(_)
                        pane - (if beside { side_whole(s, n) } else { 0.0 })
                      }, apart=fn() { wide.tape.get() },
                      // (the window's top row it drags by, as pane_made_host puts over a page of its own: a new chat is
                      // made under none, hidden with its bar as it becomes its chat)
                      bar=fn(b) {
                        b.show(fn() { @ui.window_inset() }, fn(t) {
                          t
                          .over(Is(true))
                          .height(By(fn() { Some(@sf.wide_bar_h + @sf.window_keys_bar_over_now()) }))
                          .presses(Is(true))
                          .moves_window(Is(true))
                          |> ignore
                        })
                      }), tips)
                    None => ()
                  }
                },
              )
            })
            |> ignore
            side_panel_node(v, page_src.val, k, tips)
          },
        ),
      )
    _ => None
  }
}

///|
/// Where a chat's bar in the pane off the tape keeps clear at its ends (chat_bar_wide_node's, node `n` its page's): as a
/// page's bar there (page_bar_room), where the block's move has it as the bar is drawn (fold_along's, as
/// pane_aside_at's): its start past the rail and the window's buttons as the block is closed, its margins while it is
/// shown a while; its end at the window's corner while no panel is open beside it (window_end_in: its buttons'
/// corner the window's, followed), clear of a corner too square for ⌘F's field (a capsule: window_corner_past), the
/// bar's own padding beside a panel.
fn pane_chat_bar_ends(
  src : Source,
  n : @view.View,
  page? : () -> Page? = fn() { None },
) -> ChatBarEnds {
  let look = fn() {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) => {
        let (_, now) = fold_target(src, w, n.window_w())
        Some(fold_along(fold_drawn_at(n), now))
      }
      None => None
    }
  }
  {
    over: fn() { @sf.window_keys_bar_over_now() },
    // (as the old view's were, drawn in the page moved aside: page_one's `aside`, which the bar over it is not)
    margins: fn() {
      match look() {
        Some(f) => (f.bar_ml + f.aside, f.bar_mr - f.aside)
        None => (0.0, 0.0)
      }
    },
    start: fn(_) {
      match look() {
        Some(f) => f.bar_pl
        None => 0.0
      }
    },
    end: fn(beside, finding) {
      let side_key = match page() {
        Some(Chat(r)) => Some(chat_key(r))
        Some(NewChat) => @sfbase.workspace_in_view(src).0.map(fn(w) { "new:" + w.id })
        _ => None
      }
      let roots = @ui.tree_corner_roots_now()
      let closed_end = if finding {
        if @ui.window_keys_own() {
          @sf.window_keys_room(roots~) + bar_in
        } else {
          @sf.window_corner_past(bar_in, roots~)
        }
      } else {
        @sf.window_end_in(bar_in, roots~)
      }
      match side_key {
        Some(key) => {
          let side_by_side = pane_w_at(src, n) >= side_both_least
          let col_w = if side_by_side {
            let _ = side_way(key)
            side_col(src, n, key, beside)
          } else {
            0.0
          }
          if @ui.window_keys_own() {
            if !side_by_side || col_w <= 0.0 {
              closed_end
            } else {
              let whole = side_whole(src, n)
              let frac = if whole > 0.5 { dmax(0.0, dmin(1.0, col_w / whole)) } else { 1.0 }
              let smooth = bar_in + (closed_end - bar_in) * (1.0 - frac)
              dmax(bar_in, dmax(closed_end - col_w, smooth))
            }
          } else if col_w > 0.5 {
            dmax(bar_in, @sf.window_corner_past(4.0, roots~) - col_w)
          } else {
            closed_end
          }
        }
        None => if beside { bar_in } else { closed_end }
      }
    },
    // (the page's column from where the bar starts: the page's margin before the bar's taken back)
    content_offset: fn() {
      match look() {
        Some(f) => -f.bar_ml
        None => 0.0
      }
    },
    linked: fn() { if @ui.window_keys_own() { None } else { Some(@sf.window_corner_key()) } },
    ground: fn(_) { @sf.theme().p.bg },
  }
}

///|
/// What the old view's island did for the page, done for entry `k`'s page made once in node `p`: moved
/// aside as the folded sidebar is shown a while, where the block's move has got (page_aside's); over it the window's
/// title bar where its buttons are in the app's top row (title_row's); a right click in it copying what is picked
/// (context_node); what it shows across read of it as the sidebar comes to be shown a while, and nothing handed the
/// system's bars, while its entry shows (fold_goes' `made` by its entry, `shown`). Nothing in it moves of its own for
/// what moves the page (a keyboard, the block): no motion of the old view's is in it to be scoped to its foot
/// (@motion.scope's), its own (the update's bar's room) bound to its cause.
fn pane_made_host(p : @view.View, src : Source, k : Int) -> Unit {
  p
  .grow(Is(1.0))
  .min_height(Is(Some(0.0)))
  .offset(By(fn() { (pane_aside_at(src, p), 0.0) }))
  |> ignore
  context_node(p)
  fold_goes.made[k] = p
  p.owns(fn() {
    match fold_goes.made.get(k) {
      Some(v) if v.id() == p.id() => fold_goes.made.remove(k)
      _ => ()
    }
  })
  |> ignore
  p.show(fn() { @ui.window_inset() }, fn(t) {
    t
    .over(Is(true))
    .height(By(fn() { Some(@sf.wide_bar_h + @sf.window_keys_bar_over_now()) }))
    .presses(Is(true))
    .moves_window(Is(true))
    |> ignore
  })
}

///|
/// What page_one did for a chat's page in its island, done for entry `k`'s chat made as nodes, its messages' column
/// `col` (chat_body_nodes', the composer in it): what it shows across read of it as the folded sidebar is shown a while,
/// while its entry shows (fold_goes' `made`), the one kept while the one on top waits too. Moved aside as that block
/// moves (pane_aside_at) by chat_page_made's `aside`, in the one offset its column has with its way across as the side
/// panel slides: an offset bound here too let go of that one (a node's one binding of a property), and the chat's rows
/// stood still while the panel slid, then stepped to their place at its end.
fn pane_made_chat(col : @view.View, k : Int) -> Unit {
  fold_goes.made[k] = col
  col.owns(fn() {
    match fold_goes.made.get(k) {
      Some(v) if v.id() == col.id() => fold_goes.made.remove(k)
      _ => ()
    }
  })
  |> ignore
}

///|
/// How far the page in the pane off the tape is moved aside as node `n` is drawn (the folded block shown a while over
/// it), where the block's move has it then.
fn pane_aside_at(src : Source, n : @view.View) -> Double {
  match @sfbase.workspace_in_view(src).0 {
    Some(w) => {
      let (_, now) = fold_target(src, w, n.window_w())
      fold_along(fold_drawn_at(n), now).aside
    }
    None => 0.0
  }
}

///|
/// How chat page `serial`'s node column in the pane off the tape is laid out as node `n` is drawn (chat_page_made's
/// `narrower`): while its right side panel slides, follows side_narrower; otherwise while the left sidebar block moves
/// on a Chat page (never NewChat), holds the column at the move's target width via pane_fold_held; at rest, as wide as
/// the pane less its open side panel.
fn pane_chat_narrower(src : Source, n : @view.View, serial : Int) -> @sfbase.ColumnLaid {
  let pane = pane_w_at(src, n)
  let side_active = match app.nav.page_of(serial) {
    Some((Chat(r), _)) if pane >= side_both_least => {
      let key = chat_key(r)
      let way = side_way(key)
      way.said()
      let t = n.drawn_while(fn(at) { way.goes_at(at) })
      (t != @double.infinity && way.goes_at(t)) || side_setting_off(key, side_drawn_open(src, r, key))
    }
    Some((NewChat, _)) => true
    _ => false
  }
  if side_active {
    return side_narrower(src, n, serial, pane)
  }
  if app.nav.page_of(serial) is Some((Chat(_), _)) && fold_going(fold_drawn_at(n)) {
    return pane_fold_held(src, n, serial)
  }
  side_narrower(src, n, serial, pane)
}

///|
/// How chat page `serial`'s old view in the pane off the tape is laid out as node `n` is drawn (chat_page_made's `held`):
/// while the block's move goes, at the width the page has where the move ends all the way, moved across as far as its
/// rows' words stood further in at the width it set off from, less as much as the move has come (laid_toward, as the
/// side panel's way has it), so the old view is built as the move sets off and not again at each frame of it, its words
/// going with the page; at rest, and while a new chat (laid out anew as the move goes, its words not a chat's rows), as
/// wide as it is.
fn pane_fold_held(src : Source, n : @view.View, serial : Int) -> @sfbase.ColumnLaid {
  let ww = n.window_w()
  guard @sfbase.workspace_in_view(src).0 is Some(w) else { return { by: 0.0, across: 0.0, laid: ww, toward: ww, toward_by: 0.0 } }
  let (_, now) = fold_target(src, w, ww)
  let t = fold_drawn_at(n)
  let pane = ww - fold_along(t, now).col
  guard app.nav.page_of(serial) is Some((Chat(_), _)) else { return { by: 0.0, across: 0.0, laid: pane, toward: pane, toward_by: 0.0 } }
  // (what of the pane the chat's page does not have: its side panel's column beside it, as it is at that moment)
  let beside = pane - pane_page_w(src, n, serial, pane)
  match (fold_goes.from, fold_goes.to) {
    (Some(a), Some(b)) if fold_going(t) =>
      laid_toward(pane - beside, ww - a.col - beside, ww - b.col - beside)
    _ => { by: 0.0, across: 0.0, laid: pane - beside, toward: pane - beside, toward_by: 0.0 }
  }
}

///|
/// How wide chat page `serial` is in a pane `pane` wide, node `n` its page's (its side panel's column beside it, none where
/// the panel is over the page: side_panel_node's).
fn pane_page_w(src : Source, n : @view.View, serial : Int, pane : Double) -> Double {
  match app.nav.page_of(serial) {
    Some((Chat(r), _)) if pane >= side_both_least =>
      pane - side_col(src, n, chat_key(r), side_now(src, r).0.length() > 0)
    _ => pane
  }
}

///|
/// How wide the pane off the tape is as node `n` is drawn: the window's less the block's column, where the block's move
/// has it then.
fn pane_w_at(src : Source, n : @view.View) -> Double {
  let ww = n.window_w()
  match @sfbase.workspace_in_view(src).0 {
    Some(w) => {
      let (_, now) = fold_target(src, w, ww)
      ww - fold_along(fold_drawn_at(n), now).col
    }
    None => ww
  }
}
