// A chat's side panel (panel.mbt) as nodes of the window's tree, beside the chat's page in the pane off the tape (the
// page made once: page_pane.mbt pane_made), the way there 4: its column as wide as the panel has slid in, a way set off
// at the change that opens or closes it (side_slides) and read where it is drawn, as the block's fold is (pane_view's
// fold_goes); over a page too narrow for both, over the page from its right edge, a shadow at its side; its edge the
// tree's (@sf.edge_node). Its bar the tree's over whatever tab is in front (panel_bar_node.mbt), under it: an agent's
// history, its head and steps nodes (history_head_node, sfpages' history_steps_node); a file in the viewer, its tools
// and stage (sfbase's viewer_tab_node); 任务, agent 往来 and 图片、文件和链接 what each shows (jobs_tab_node,
// letters_tab_node, sfpages' things_node); 文件 and a station's 文件 the tab's nodes (drive_tab_node.mbt), a station's
// page sfpages' station_node; a station's screen and terminal their nodes (side_screen_node, side_terminal_node). On the tape the panel is a panel of its own (tape_view's tape_side_node).

///|
/// Whether `front` (one the panel shows: side_shows) is one of the chat's agents' histories.
fn side_history_tab(front : String) -> Bool {
  front != "" &&
  !(front is ("jobs" | "files" | "letters" | "things" | "subchats")) &&
  tab_service(front) is None &&
  tab_file(front) is None &&
  station_tab(front) is None &&
  @sfbase.view_tab_file(front) is None
}

///|
/// Whether `front` is one the window's tree shows under the panel's bar rather than the panel's old view: an agent's
/// history, a file in the viewer, a station's screen, a station's 共享调试, 文件 and a station's 文件 (side_files_tab), a
/// station's page (side_station_tab), 任务, agent 往来, 图片、文件和链接 (side_own_tab).
fn side_node_tab(front : String) -> Bool {
  side_history_tab(front) ||
  @sfbase.view_tab_file(front) is Some(_) ||
  tab_service(front) is Some(_) ||
  tab_file(front) is Some(_) ||
  side_screen_tab(front) is Some(_) ||
  side_adb_tab(front) is Some(_) ||
  side_files_tab(front) is Some(_) ||
  side_station_tab(front) is Some(_) ||
  side_terminal_tab(front) ||
  side_own_tab(front)
}

///|
fn side_terminal_tab(front : String) -> Bool {
  station_tab(front) is Some(("terminal", _, _))
}

///|
/// Whether `front` is one of the chat's own tabs made as nodes (side_own_node): 任务, agent 往来, 图片、文件和链接.
fn side_own_tab(front : String) -> Bool {
  front is ("jobs" | "letters" | "things" | "subchats")
}

///|
/// The station and the screen of `front` where it is a station's screen (side_screen_node).
fn side_screen_tab(front : String) -> (String, String)? {
  match station_tab(front) {
    Some(("screen", station, screen)) => Some((station, screen))
    _ => None
  }
}

///|
/// What chat `r`'s panel shows: its tabs as its view has them; its last closed, while it slides out, those it had.
fn side_shown(src : Source, r : ChatRef) -> (Array[String], String) {
  let (tabs, front) = side_now(src, r)
  if tabs.length() > 0 {
    (tabs, front)
  } else {
    side_leaving(chat_key(r)).unwrap_or(([], ""))
  }
}

///|
/// How wide chat `r`'s panel is as node `n` is drawn, at rest: over a page too narrow for both its least (side_over_w),
/// else as side_width has it beside the page.
fn side_whole(src : Source, n : @view.View) -> Double {
  let pane = pane_w_at(src, n)
  if pane < side_both_least {
    dmin(side_over_w, pane)
  } else {
    side_width(pane)
  }
}

///|
/// Page `key`'s panel's column's way (panel_own's `goes`), made at rest at none the first time it is asked for: what
/// reads it before it first slides (side_narrower) is told as it sets off.
fn side_way(key : String) -> @motion.Way {
  match panel_own.goes.get(key) {
    Some(w) => w
    None => {
      let w = @motion.Way::new(0.0)
      panel_own.goes[key] = w
      w
    }
  }
}

///|
/// Page `key`'s panel's column opened (`open`) or closed, as node `n` comes to have it so: from none to some tabs or back
/// by a change asked here (side_changing's `asked`), slid in or out from where it is at that change's moment, as long as
/// it is wide; else there at once (a page opened with its tabs as they were left). Slid out, what it showed let go of
/// at its end.
fn side_slides(n : @view.View, src : Source, key : String, chat : String, open : Bool) -> Unit {
  let way = side_way(key)
  let target = if open { @signals.untracked(fn() { side_whole(src, n) }) } else { 0.0 }
  let was = @signals.untracked(fn() { panel_own.was.get(key) })
  match was {
    Some(was) if was != open && panel_own.asked.untracked() == key => {
      panel_own.asked.set("")
      let at = n.cause_at()
      let (cur_w, cur_v) = way.at(at)
      // (where the rows' words stand across as it sets off: turned back on its way, where its way has them drawn)
      let pane = @signals.untracked(fn() { pane_w_at(src, n) })
      let cur_side = if way.goes_at(at) {
        let prev = laid_toward(
          pane - cur_w,
          pane - way.value_at(way.starts_at()),
          pane - way.target(),
          from_side?=panel_own.from_side.get(key),
        )
        @sfpages.chat_row_side(prev.laid) + prev.across
      } else {
        @sfpages.chat_row_side(pane - cur_w)
      }
      panel_own.from_side[key] = cur_side
      if way.goes_at(at) {
        let v = @sf.dclamp(cur_v, -4000.0, 4000.0)
        way.go(target, @motion.moved(over=(target - cur_w).abs()), velocity=v, at~)
      } else {
        way.go(target, @motion.moved(over=(target - cur_w).abs()), at~)
      }
      // (the chat's rows laid out anew at where it goes, on their list's way from this moment: side_narrower)
      @sfbase.column_sets_off(chat, over=(target - cur_w).abs())
      if !open {
        let ends = way.end()
        n.at_moment(ends, fn() { if way.end() == ends { side_left(key) } }) |> ignore
      }
    }
    _ => {
      way.put(target)
      panel_own.from_side.remove(key)
      if !open {
        side_left(key)
      }
    }
  }
  if was != Some(open) {
    panel_own.was[key] = open
  }
}

///|
/// Whether page `key`'s panel's column is to slide to `open` from where it is and has not set off yet: a change asked
/// here (side_changing's `asked`) come to what the page reads, side_slides not yet told it. What reads where the column
/// is (side_col, side_narrower) is told it in the same pass as the change, before or after side_slides is (whichever
/// way the tree takes them): so it reads the column where its way sets off from, never where it is going for the frame
/// between (all of the page's width at once as it closes, the column at none, then back to the way's).
fn side_setting_off(key : String, open : Bool) -> Bool {
  match panel_own.was.get(key) {
    Some(was) => was != open && panel_own.asked.get() == key
    None => false
  }
}

///|
/// How wide page `key`'s panel's column is as node `n` is drawn: where its way has it while it goes, where it sets off
/// from as it is about to (side_setting_off), else all of it open (`open`), none closed.
fn side_col(src : Source, n : @view.View, key : String, open : Bool, pane? : Double) -> Double {
  match panel_own.goes.get(key) {
    Some(way) => {
      way.said()
      let t = n.drawn_while(fn(at) { way.goes_at(at) })
      if t != @double.infinity && way.goes_at(t) {
        return way.value_at(t)
      }
      if side_setting_off(key, open) {
        return way.target()
      }
    }
    None => ()
  }
  if open {
    match pane {
      Some(p) => if p < side_both_least { dmin(side_over_w, p) } else { side_width(p) }
      None => side_whole(src, n)
    }
  } else {
    0.0
  }
}

///|
/// How much narrower than it is drawn in node `n` chat page `serial`'s column is laid out (less than none: wider), and
/// how far across it is moved (chat_page_made's `narrower`): while its panel's column slides, as where it goes, from the
/// moment it sets off, moved across as laid_toward has it (the old list's laid_w and list_shift: laid out anew only as
/// the way sets off, its rows' heights going on the list's way from there; the rows' words where they stood as it set
/// off, going with the page to where they stand once it is there; laid out at the narrower end all the way it was
/// narrow at once and wide at once as the panel was gone, the user, 2026-11-09: 「打开关闭右侧面板，中间的变化不对」);
/// at rest, and over a page too narrow for both (the page as wide as it is), none, laid out as wide as it is.
fn side_narrower(src : Source, n : @view.View, serial : Int, pane : Double) -> @sfbase.ColumnLaid {
  // (a chat's; or the new chat's made as nodes beside its Station 文件 (new_side_node), its column centred in what it
  // is drawn in all the way, as it is at rest: by half of how much narrower it is laid out)
  let (key, open, centred) = match app.nav.page_of(serial) {
    Some((Chat(r), _)) => (chat_key(r), fn() { side_drawn_open(src, r, chat_key(r)) }, false)
    Some((NewChat, _)) =>
      match @sfbase.workspace_in_view(src).0 {
        Some(w) => ("new:" + w.id, fn() { new_files_open(src, w.id) && new_drive_station(src, w) is Some(_) }, true)
        None => return { by: 0.0, across: 0.0, laid: pane, toward: pane, toward_by: 0.0 }
      }
    _ => return { by: 0.0, across: 0.0, laid: pane, toward: pane, toward_by: 0.0 }
  }
  let way = side_way(key)
  way.said()
  let t = n.drawn_while(fn(at) { way.goes_at(at) })
  if pane < side_both_least {
    return { by: 0.0, across: 0.0, laid: pane, toward: pane, toward_by: 0.0 }
  }
  if t == @double.infinity || !way.goes_at(t) {
    let open = open()
    let to = if open { side_width(pane) } else { 0.0 }
    // (about to set off: as it is still, where the column is (side_setting_off), laid out anew only as the way sets off,
    // its rows told then: side_slides)
    if side_setting_off(key, open) {
      return { by: 0.0, across: 0.0, laid: pane - way.target(), toward: pane - way.target(), toward_by: 0.0 }
    }
    return { by: 0.0, across: 0.0, laid: pane - to, toward: pane - to, toward_by: 0.0 }
  }
  let laid = laid_toward(
    pane - way.value_at(t),
    pane - way.value_at(way.starts_at()),
    pane - way.target(),
    from_side?=panel_own.from_side.get(key),
  )
  if centred {
    { ..laid, across: -laid.by / 2.0 }
  } else {
    laid
  }
}

///|
/// A chat's column drawn `now` wide on its way from `from` to `to`: laid out at `to` all the way (how much narrower
/// than it is drawn: less than none where it is drawn narrower, its page cutting it), moved across by as much further in
/// as its rows' words stood at `from` than they stand at `to`, less as much of it as the way has come
/// (chat_page_made's `narrower`): so they go with the page from where they stood as it set off to where they stand, never
/// stepping where they are laid out anew; what is arranged otherwise at `from` than at `to` drawn as much of the way
/// as is left to how it was at `from`. Where the way set off turned back on another (`from_side`: where the words stood
/// across then), from there; and past `from` as the way overshoots it, as far past (moved on as it goes, never held).
fn laid_toward(now : Double, from : Double, to : Double, from_side? : Double) -> @sfbase.ColumnLaid {
  let start_side = from_side.unwrap_or(@sfpages.chat_row_side(from))
  let raw = if (from - to).abs() > 0.5 { (from - now) / (from - to) } else { 1.0 }
  let gone = dmax(0.0, dmin(1.0, raw))
  {
    by: now - to,
    across: (start_side - @sfpages.chat_row_side(to)) * (1.0 - raw),
    laid: to,
    toward: from,
    toward_by: 1.0 - gone,
  }
}

///|
/// A chat's column drawn `now` wide on its way between `laid` and `wide` (the narrower end it is laid out at, the
/// wider): how much narrower it is laid out, and how far across it is moved, by as much of the way as it has come from
/// `laid` to `wide`, as far as its rows' words start further in at `wide` than at `laid` (chat_page_made's `narrower`):
/// none at the narrower end, all of it at the wider, so that they go across with the page all the way, never stepping
/// where the width crosses one of row_side's (a breadth that lays them out otherwise); what is arranged otherwise at
/// `wide` than at `laid` drawn as far of the way to how it is at `wide`.
fn laid_across(now : Double, laid : Double, wide : Double) -> @sfbase.ColumnLaid {
  let now = dmax(laid, dmin(now, wide))
  let part = if wide > laid { (now - laid) / (wide - laid) } else { 0.0 }
  {
    by: now - laid,
    across: part * (@sfpages.chat_row_side(wide) - @sfpages.chat_row_side(laid)),
    laid,
    toward: wide,
    toward_by: part,
  }
}

///|
/// The side panel of the chat page `serial` of the stack (a chat's, or the new chat's once it becomes one) in node `v`,
/// the row its page is in, after it, read by `src` (the page's, chat_page_made's: what it reads let go with the page): its column (side_col), moved aside with the page; in it, while it shows anything,
/// the panel as wide as it is at rest (cut to the column while it slides beside the page) and its edge. The new chat's,
/// while the page is that, made as nodes with it (its new_node's), its Station 文件 alone:
/// new_side_node.
fn side_panel_node(v : @view.View, src : Source, serial : Int, tips : @sf.TipLayer) -> Unit {
  let chat = fn() {
    match app.nav.page_of(serial) {
      Some((Chat(r), _)) => Some(r)
      _ => None
    }
  }
  // (the new chat's, made as nodes as the page was)
  let new_of = fn() {
    match app.nav.page_of(serial) {
      Some((NewChat, _)) => @sfbase.workspace_in_view(src).0
      _ => None
    }
  }
  let key = fn() {
    match chat() {
      Some(r) => Some(chat_key(r))
      None => new_of().map(fn(w) { "new:" + w.id })
    }
  }
  v.pick(at_once=true, key, fn(col, key) {
    guard key is Some(key) else {
      col.width(Is(Some(0.0))) |> ignore
      return
    }
    guard @signals.untracked(chat) is Some(r) else {
      match @signals.untracked(new_of) {
        Some(w) => new_side_node(col, src, w, key, tips)
        None => col.width(Is(Some(0.0))) |> ignore
      }
      return
    }
    let open = fn() { side_drawn_open(src, r, key) }
    col.reacts(open, fn(open) { side_slides(col, src, key, r.station + "\u{1}" + r.session, open) })
    // (opened only for a tab over the whole window and closed with it: let go of, side_unseen)
    col.reacts(
      fn() { side_now(src, r).0.is_empty() },
      fn(none) {
        if none && side_unseen.untracked() == key {
          side_unseen.set("")
        }
      },
      at_start=false,
    )
    // (its page kept under another, shown no more: what a file's tab plays here paused, as when its tab is let go)
    col.reacts(fn() { app.nav.shows(serial) }, fn(shows) {
      if !shows {
        @sfbase.tab_players_pause(chat=tabs_key(r))
      }
    })
    let pane = col.memo(fn() { pane_w_at(src, col) })
    let over = fn() { pane() < side_both_least }
    let whole = fn() {
      let w = pane()
      if w < side_both_least {
        dmin(side_over_w, w)
      } else {
        side_width(w)
      }
    }
    let at = col.memo(fn() { side_col(src, col, key, open(), pane=pane()) })
    col
    .shrink(Is(0.0))
    .width(By(fn() { Some(if over() { 0.0 } else { at() }) }))
    .clips(By(fn() { !over() && at() < whole() }))
    .offset(By(fn() { (pane_aside_at(src, col), 0.0) }))
    .key_context("Chat")
    .on_action("panel.tab.close", fn(_) { side_close_front(src, r) })
    .on_action("panel.tab.reopen", fn(_) { side_reopen_key(src, r) })
    .on_action("panel.tab.prev", fn(_) { side_step(src, r, -1) })
    .on_action("panel.tab.next", fn(_) { side_step(src, r, 1) })
    |> ignore
    col.show(at_once=true, fn() { side_shown(src, r).0.length() > 0 }, fn(p) {
      p
      .grow(Is(1.0))
      .min_height(Is(Some(0.0)))
      .width(By(fn() { Some(whole()) }))
      .offset(By(fn() { (if over() { -at() } else { 0.0 }, 0.0) }))
      .ground(By(fn() { if over() { 0L } else { @sf.theme().p.bg } }))
      |> ignore
      p.show(at_once=true, over, fn(bg) {
        bg.over(Is(true)) |> ignore
        @sf.drawer_surface_decorate(bg, solid=fn() { @sf.theme().p.bg }, clips=false) |> ignore
      })
      // its bar over whatever tab is in front, the tree's; none where what is in front has its own (side_own_bar_node)
      p.show(at_once=true, fn() {
        let (tabs, front) = side_shown(src, r)
        !side_own_bar_node(p, tabs, front, false)
      }, fn(b) {
        side_bar_clip_node(b, src, at, fn(inner) {
          side_bar_node(inner, src, r, fn() { side_shown(src, r) }, false, tips)
        })
      })
      let prev_front : Ref[(String, Int)?] = Ref(None)
      p.pick(at_once=true, fn() { history_in_front(src, r) }, fn(q, agent) {
        q.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
        let (tabs, front) = @signals.untracked(fn() { side_shown(src, r) })
        let cur_idx = tabs.search(front).unwrap_or(0)
        match prev_front.val {
          Some((old_agent, old_idx)) if old_agent != agent && agent != "" && agent != tab_full_mark && !@ui.reduced_motion() => {
            let dir = if cur_idx >= old_idx { 1.0 } else { -1.0 }
            let way = @motion.NodeWay::new(0.0)
            way.go_from(q, 0.0, 1.0, @motion.tween(140.0, ease=Out))
            q
            .offset(By(fn() { (dir * 8.0 * (1.0 - way.shown(q)), 0.0) }))
            .alpha(By(fn() { way.shown(q) }))
            .carries_until(fn() { way.ends_at() })
            |> ignore
          }
          _ => ()
        }
        prev_front.val = if agent == "" || agent == tab_full_mark { None } else { Some((agent, cur_idx)) }
        if agent == tab_full_mark {
          // (over the whole window: nothing of it here meanwhile, tab_full_node.mbt)
          ()
        } else if agent == "" {
          // (no tab of the tree's in front: nothing, every tab the panel shows is the tree's, side_node_tab)
          ()
        } else if @sfbase.view_tab_file(agent) is Some(_) {
          tab_held_beside(q, r, agent)
          side_view_node(q, src, r, agent, fn(n) { side_whole(src, n) }, full_of(r, agent))
        } else if tab_service(agent) is Some(job) {
          tab_held_beside(q, r, agent)
          service_tab_node(q, src, r, job, None, full_of(r, agent), None, tips)
        } else if tab_file(agent) is Some((session, path, name)) {
          tab_held_beside(q, r, agent)
          file_tab_node(q, src, r, session, path, name, full_of(r, agent), tips)
        } else if side_screen_tab(agent) is Some(_) {
          side_screen_node(q, src, r, agent, fn() { side_shown(src, r).0 }, false, shows=pane_shows(serial))
        } else if side_adb_tab(agent) is Some(station) {
          side_adb_node(q, src, station)
        } else if side_files_tab(agent) is Some(station) {
          side_files_node(q, src, r, station, fn() { @sf.foot_corner(@sf.button_height(), ftab_side, ftab_under) }, tips)
        } else if side_station_tab(agent) is Some(station) {
          side_station_node(q, src, station, tips, fn() { side_whole(src, q) }, false)
        } else if side_terminal_tab(agent) {
          side_terminal_node(q, src, r, agent)
        } else if side_own_tab(agent) {
          side_own_node(q, src, r, agent, tips, @sf.pane_foot_card)
        } else {
          side_history_node(q, src, r, agent, tips)
        }
      })
    })
    // its edge, beside the page only
    col.show(at_once=true, fn() { !over() && open() }, fn(e) { side_edge_node(e, src, fn() { side_change(src, r, "clear", None) }, tips) })
  })
}

///|
/// The agent whose history chat `r`'s panel has in front, or the file in the viewer; "" another tab.
fn history_in_front(src : Source, r : ChatRef) -> String {
  let front = side_shown(src, r).1
  if side_node_tab(front) {
    full_elsewhere(r, front)
  } else {
    ""
  }
}

///|
/// Agent `agent`'s history in chat `r`'s panel, in node `q` (as large as the panel under its bar, side_bar_node): its
/// head (history_head_node) and its steps the rest (sfpages' history_steps_node), nodes.
fn side_history_node(q : @view.View, src : Source, r : ChatRef, agent : String, tips : @sf.TipLayer) -> Unit {
  context_node(q)
  history_head_node(q, src, r, agent, tips)
  q.box(fn(s) {
    s.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    @sfpages.history_steps_node(s, src, r.station, agent, tips)
  })
  |> ignore
  // (what its press asked, taken over by what it read as it was made: side_front_pressed)
  @sfbase.shown_read(side_tab_shown_at(r, agent))
}

///|
/// File tab `tab` in chat `r`'s panel, in node `q` (as large as the panel under its bar, side_bar_node, or over the
/// whole window: tab_full_node.mbt): the file's tools (`tools`: over the whole window the bar's) and its stage (sfbase's
/// viewer_tab_node), `width()` wide, its 全屏 `full`.
fn side_view_node(
  q : @view.View,
  src : Source,
  r : ChatRef,
  tab : String,
  width : (@view.View) -> Double,
  full : (() -> Unit)?,
  tools? : Bool = true,
) -> Unit {
  q.box(fn(s) {
    s.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    @sfbase.viewer_tab_node(s, src, tabs_key(r), tab, fn() { width(s) }, full, tools~)
  })
  |> ignore
}

///|
/// A page's panel's edge (ResizeHandle) in node `n`, over its column's left, half over the page: dragged, its width
/// (kept while the app runs); pressed, the panel closed (`close`); pressed twice, its own width again.
fn side_edge_node(n : @view.View, src : Source, close : () -> Unit, tips : @sf.TipLayer) -> Unit {
  let held = @signals.signal(false, same=fn(a, b) { a == b })
  n.over(Is(true)).width(Is(Some(@sf.handle_w))).offset(Is((-@sf.handle_out, 0.0))) |> ignore
  // (dragged on past either end, its line drawn aside as a string, sprung back as it is let go)
  let pull = @sf.EdgePull::new()
  let e = @sf.edge_node(
    n,
    fn() { @sf.t("web-pages.chat.resizePanel") + " · " + @sf.t("web-pages.chat.closePanel") },
    fn() { side_whole(src, n) },
    fn() { panel_min },
    fn() { panel_max },
    Left,
    fn(said, _) {
      match said {
        Dragging(x) | Dropped(x) => panel_own.width.set(Some(x))
        Pressed => close()
        Twice => panel_own.width.set(None)
        Untouched => ()
      }
    },
    fn(h) { held.set(h) },
    tips~,
    side=Left,
    pull~,
  )
  e.box(fn(g) {
    g.over(Is(true)) |> ignore
    @sf.edge_look_node(g, fn() { false }, fn() { e.pointed() || e.focus_shown() || held.get() }, fn() { held.get() }, pull~)
    |> ignore
  })
  |> ignore
}

///|
/// The station of `front` where it is a station's 共享调试 tab (the settings' page of it, focused on that station).
fn side_adb_tab(front : String) -> String? {
  match station_tab(front) {
    Some(("adb", station, _)) => Some(station)
    _ => None
  }
}

///|
/// A station's 共享调试 tab in a chat's panel, in node `q` (as large as the panel under its bar): the settings' page of
/// it (@settings.adb_node), its step for `station` first, in the workspace in view, its head with no back (the tab is
/// the way to close it).
fn side_adb_node(q : @view.View, src : Source, station : String) -> Unit {
  q.box(fn(s) {
    s.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    s.switch_by(fn() { @sfbase.workspace_in_view(src).0.map(fn(w) { w.id }) }, fn(p, _id) {
      guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
      p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      let core = settings_core(src, w)
      // (the step of the account the workspace is reached through: another signed in here lends it nothing)
      let here = fn() { @settings.here_of(core, w.id, w.name) }
      @settings.adb_node(p, core, station, on_back=fn() {  }, frame=fn() { { back: None, top: 0.0, foot: 0.0, named: false } }, sub=fn() {
        here().sub
      })
    })
  })
  |> ignore
}

///|
/// A station terminal tab in chat `r`'s side panel, rendered as a pure node (`sfpages.terminal_node`).
fn side_terminal_node(q : @view.View, src : Source, r : ChatRef, tab : String) -> Unit {
  guard station_terminal_at(r, tab) is Some(at) else { return }
  let cur_tab = Ref(tab)
  q.box(fn(s) {
    s.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).clips(Is(true)) |> ignore
    // (its dark screen a line in from the panel's edge, on the panel's ground: never edge to edge with the chat's page
    // beside it, whose ground is not its own (gaps.mbt's rule 9); the panel's edge drawn over that line)
    s.ground(By(fn() { @sf.theme().p.bg })).padding(Is((1.0, 0.0, 0.0, 0.0))) |> ignore
    // (in a box of its own: what the terminal's pane says of its own padding leaves that line where it is)
    s.box(fn(t) {
      t.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
      @sfpages.terminal_pane_node(
        t,
        src,
        at,
        back=fn() { @sf.t("common.back") },
        on_back=fn() { side_change(src, r, "close", Some(cur_tab.val)) },
        top=fn() { 0.0 },
        width=fn() { side_whole(src, s) },
        in_tab=true,
        keep_open=fn() {
          let open_tabs = @signals.untracked(fn() { side_now(src, r).0 })
          open_tabs.contains(cur_tab.val) ||
          (!at.terminal.has_prefix("new") &&
          open_tabs.any(fn(t) { station_tab(t) == Some(("terminal", at.station, at.terminal)) }))
        },
        on_resolved=fn(real_id, real_cwd) {
          let next_cwd = if real_cwd != "" { real_cwd } else { at.cwd }
          let next_tab = station_tab_key("terminal", at.station, screen=real_id)
          panel_terminal_pages[tabs_key(r) + "/" + next_tab] = {
            ..at,
            terminal: real_id,
            cwd: next_cwd,
          }
          let prev = cur_tab.val
          cur_tab.val = next_tab
          if prev != next_tab {
            panel_terminal_pages.remove(tabs_key(r) + "/" + prev)
            side_ask(src, r, "open", Some(next_tab))
            side_ask(src, r, "close", Some(prev))
          }
        },
        on_switch_page=fn(next) {
          if !station_page_beside(src, r, next) {
            @sfbase.open_page(next)
          }
        },
      )
    })
    |> ignore
  })
  |> ignore
}

///|
/// Station screen tab `tab` in chat `r`'s panel (`tabs` the panel's as they are now; `on_tape`: a panel of its own on the
/// tape), in node `q` (as large as the panel under its bar): its page (sfpages' screen_node) beside its chat, its × the
/// tab's, alone in the panel upright the panel's bar its own (side_own_bar_node), its view let go of as the tab goes
/// (closed, another in front, its chat left) unless it is the page on top over all of it.
fn side_screen_node(
  q : @view.View,
  src : Source,
  r : ChatRef,
  tab : String,
  tabs : () -> Array[String],
  on_tape : Bool,
  shows? : () -> Bool = fn() { true },
) -> Unit {
  guard station_tab_page(r, tab) is Some(Screen(at)) else { return }
  side_screen_page_node(q, src, r, tab, at, tabs, on_tape, shows)
}

///|
/// Station screen tab `tab`'s page (`at`) in node `q` (side_screen_node's).
fn side_screen_page_node(
  q : @view.View,
  src : Source,
  r : ChatRef,
  tab : String,
  at : @sfbase.ScreenAt,
  tabs : () -> Array[String],
  on_tape : Bool,
  shows : () -> Bool,
) -> Unit {
  q.box(fn(s) {
    s.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    s.owns(fn() {
      match app.nav.top() {
        Screen(top) if top.station == at.station && top.screen == at.screen => ()
        Place("remote") if @sfpages.remote_has_screen(src, at.station, at.screen) => ()
        _ => @sfpages.screen_left(src, at.station, at.screen)
      }
    })
    |> ignore
    // (the page on top over all of it showing the same screen, its 全屏 from here: the one viewer of it is that page's,
    // this one made again as it goes)
    s.show(at_once=true, fn() { !(app.nav.top() is Screen(top) && top.station == at.station && top.screen == at.screen) }, fn(b) {
      b.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
      b.pick(at_once=true, fn() {
        let (ww, wh) = b.window()
        screen_tab_alone(tabs()) && !column_short.get() && ww <= wh
      }, fn(p, alone) {
        p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        @sfpages.screen_node(
          p,
          src,
          at,
          fn() { { back: None, top: 0.0, foot: 0.0, named: false } },
          on_close=fn() { side_change(src, r, "close", Some(tab)) },
          in_tab=true,
          own_bar=if alone { Some(side_bar_look_node(on_tape)) } else { None },
        )
        // on the tape, out of sight while another panel is in use at rest; off the tape, out of sight while another page
        // covers its chat in the pane: let go of as a page under another is (its last frame kept, the stream and its hold
        // on the screen given back), opened again as it comes over
        let hidden = if on_tape { tape_side_hidden } else { fn() { !shows() } }
        p.reacts(hidden, fn(h) { @sfpages.screen_covered(src, at.station, at.screen, h) })
        p.owns(fn() { @sfpages.screen_covered(src, at.station, at.screen, false) }) |> ignore
      })
    })
  })
  |> ignore
}

///|
/// Whether the side panel of the chat on the stack (the last there) shows `station`'s `screen` in front: what lets that
/// screen's view go as a page of it leaves the stack keeps it for the panel (sfapp's pages_left: its 全屏 from the panel,
/// gone back to it).
pub fn side_screen_shown(src : Source, station : String, screen : String) -> Bool {
  let pages = app.nav.pages()
  for i = pages.length() - 1; i >= 0; i = i - 1 {
    match pages[i] {
      Chat(r) | History(r, _, _) => {
        let front = side_shown(src, r).1
        return side_screen_tab(front) == Some((station, screen))
      }
      _ => ()
    }
  }
  false
}

///|
/// One of chat `r`'s own tabs (`tab`: side_own_tab) in its panel, in node `q` (as large as the panel under its bar,
/// side_bar_node): what the tab shows, nodes: 任务 (a service pressed opening its own tab, in front), agent 往来 and
/// 图片、文件和链接 once the chat's thread is known (在对话里看 going to the message in the chat). A card across its foot is laid as `foot_card` says (in the panel's corners).
fn side_own_node(
  q : @view.View,
  src : Source,
  r : ChatRef,
  tab : String,
  tips : @sf.TipLayer,
  foot_card : () -> @ui.Style,
) -> Unit {
  q.box(fn(s) {
    @sf.floating_host_lend(s)
    s.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).clips(Is(true)) |> ignore
    if tab == "subchats" {
      s.padding(Is((8.0, 8.0, 8.0, 12.0))) |> ignore
      @sfpages.subchats_list_node(
        s,
        fn() {
          match @sfbase.chat_view_now(src, r) {
            Some(cv) => cv.opened
            None => []
          }
        },
        src~,
        chat=r,
        show_head=true,
        fills=true,
        include_opened=true,
      )
      return
    }
    if tab == "jobs" {
      jobs_tab_node(s, src, r, tips, foot_card, fn(job) {
        // (over the whole window, the command key not held as it was pressed: sfbase's tab_full.mbt; not in the panel
        // yet, only to go there, lone)
        let full = @sfbase.full_asked()
        let lone = full && !side_now(src, r).0.contains("service:" + job)
        side_tab_open(src, r, "service:" + job)
        if full {
          @sfbase.tab_full_open(r, "service:" + job, lone~)
        }
      })
      // (what its press asked, taken over by what it read as it was made: side_front_pressed)
      @sfbase.shown_read(side_tab_shown_at(r, tab))
      return
    }
    // (once its view, and so its thread, is read: what both show is the thread's)
    // (its head alone: sfbase's chat_view_now)
    s.switch_by(fn() { @sfbase.chat_view_now(src, r).bind(fn(v) { v.thread }) }, fn(t, thread) {
      t.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      guard thread is Some(th) else { return }
      if tab == "letters" {
        let first = @signals.untracked(fn() { @sfbase.chat_view_now(src, r) })
        guard first is Some(first) else { return }
        letters_tab_node(t, src, r, th, fn() { @sfbase.chat_view_now(src, r).unwrap_or(first) }, tips)
      } else {
        @sfpages.things_node(t, src, r, th, fn(seq) { @sfbase.go_to(r, seq) }, beside=true)
      }
    })
  })
  |> ignore
}

///|
/// Where `front` is 文件 (the workspace's stations', "": the chat's station first) or a station's 文件 tab (that
/// station's alone), which station: the tab made as nodes (drive_tab_node.mbt).
fn side_files_tab(front : String) -> String? {
  if front == "files" {
    return Some("")
  }
  match station_tab(front) {
    Some(("drive", station, _)) => Some(station)
    _ => None
  }
}

///|
/// 文件 (`station` "") or station `station`'s 文件 in chat `r`'s panel, in node `q` (as large as the panel under its
/// bar): the tab made as nodes (files_tab_node) in the workspace in view, what it adds going into the chat's draft, a
/// station's kept where it is by its own scope (station_files_scope); 添加 at its foot as `foot` lays it; what is said
/// of what the pointer rests on in `tips`.
fn side_files_node(q : @view.View, src : Source, r : ChatRef, station : String, foot : () -> @ui.Style, tips : @sf.TipLayer) -> Unit {
  q.box(fn(s) {
    s.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).clips(Is(true)) |> ignore
    s.pick(fn() { @sfbase.workspace_in_view(src).0.map(fn(w) { w.id }) }, fn(p, id) {
      guard id is Some(ws) else { return }
      p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      if station == "" {
        files_tab_node(p, src, ws, tabs_key(r), r.station, foot, tips)
      } else {
        files_tab_node(p, src, ws, tabs_key(r), station, foot, tips, only_station=true, scope=station_files_scope(r, station))
      }
    })
  })
  |> ignore
}

///|
/// The station of `front` where it is a station's page tab (its page, Setting(Station), beside the chat).
fn side_station_tab(front : String) -> String? {
  match station_tab(front) {
    Some(("station", station, _)) => Some(station)
    _ => None
  }
}

///|
/// Station `station`'s page tab in a chat's panel, in node `q` (as large as the panel under its bar): its page made
/// once (sfpages' station_node), in the workspace in view, as a settings' page is made in a pane (page_pane's: its
/// frame's core, a fixture's dialog, a right click copying what is picked), laid out by the panel's `width` (narrow or
/// wide, page_node's look), its head with no back (the tab is the way to close it), its name the tab's (named); on the
/// tape (`on_tape`), in a panel of its own, its cards the panel's (@sf.pane_lent), as tape_made's pages are.
fn side_station_node(
  q : @view.View,
  src : Source,
  station : String,
  tips : @sf.TipLayer,
  width : () -> Double,
  on_tape : Bool,
) -> Unit {
  q.box(fn(s) {
    s.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    s.pick(fn() { @sfbase.workspace_in_view(src).0.map(fn(w) { w.id }) }, fn(p, _id) {
      guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return }
      p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      let core = settings_core(src, w)
      let here = fn() { @settings.here_of(core, w.id, w.name) }
      @settings.frame(core, @signals.untracked(here))
      // (a dialog a fixture's mode puts up over its page, before the page is made: setting_page's)
      settings_fixture(src, core)
      if on_tape {
        p.lends(@sf.pane_lent, true) |> ignore
      }
      context_node(p)
      @sfpages.station_node(p, core, src, here, station, on_back=fn() {  }, frame=fn() {
        { back: None, top: 0.0, foot: 0.0, named: true }
      }, width~, tips~)
    })
  })
  |> ignore
}

///|
/// Wraps a side panel's top bar (`make`) in a container that clips it clear of Windows' own window keys (`| - □ ×`)
/// while the panel slides (`at() < side_whole`), without shrinking the bar's inner layout width.
fn side_bar_clip_node(
  parent : @view.View,
  src : Source,
  at : () -> Double,
  make : (@view.View) -> Unit,
) -> Unit {
  if !@ui.window_keys_own() {
    make(parent)
    return
  }
  parent.box(fn(c) {
    let sliding_win = fn() { at() < side_whole(src, c) - 0.5 }
    c
    .shrink(Is(0.0))
    .clips(By(sliding_win))
    .width(
      By(fn() {
        if sliding_win() {
          Some(dmax(0.0, at() - @sf.window_keys_room(roots=@ui.tree_corner_roots_now())))
        } else {
          None
        }
      }),
    )
    |> ignore
    c.box(fn(inner) {
      inner.shrink(Is(0.0)).width(By(fn() { Some(side_whole(src, inner)) })) |> ignore
      make(inner)
    })
    |> ignore
  })
  |> ignore
}
