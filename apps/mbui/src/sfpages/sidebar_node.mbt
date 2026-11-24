// The chats' lists (sidebar.mbt's) as nodes of the window's tree: 全部, 我参与的 and 监控中 side by side on one track,
// slid from one to another as the filter changes, each as the core's `chats` view lists it now: its days under their
// headings, a row each (chat_row_node), each line made only while it shows (View::scrolls_window); while it is read the
// rows to come, what is wrong over them, an empty list's words. While the hand is on a list its rows keep their places
// (sfbase's held_order).

///|
/// What the frame gives the lists made once (ListsFrame's, as they are now): the room over them and at their foot, how
/// far down what is over them covers their box (`under`), their ground, what stands at a list's top before its words and
/// rows (`before`) and after its words (`after`), each said for a list's filter and its view; the lists on the track
/// after the three, and which of all of them is shown; where the lists stand; whether they are in view (`watched`: what
/// changes meanwhile comes and goes; not while another page is over them, the list as it is come back to).
pub(all) struct ListsNodeFrame {
  top : () -> Double
  under : () -> Double
  foot : () -> Double
  ground : () -> Int64
  before : (String, ChatsView?) -> Array[NodePart]
  after : (String, ChatsView?) -> Array[NodePart]
  others : Array[(@view.View) -> Unit]
  shown : () -> Int
  at : @sf.ListAt
  watched : () -> Bool
}

///|
/// Something a frame puts in a list made once (ListPart's): its key among the list's lines, what makes it.
pub(all) struct NodePart {
  key : String
  make : (@view.View) -> Unit
}

///|
/// The chats' lists of the workspace in view (`workspace`) in node `v`, as `frame` says: the track the filter slides,
/// a list's width a step (the theme's slide), the lists on it each its whole width. Tips in `tips`, pictures asked for
/// on `stint`.
pub fn chats_lists_node(
  v : @view.View,
  src : Source,
  workspace : () -> Workspace?,
  frame : ListsNodeFrame,
  tips : @sf.TipLayer,
  stint : () -> Int,
) -> Unit {
  // (as large as what holds it gives it: over all of it, its frame's)
  v.clips(Is(true)) |> ignore
  // a chat archived from its row: its 撤销 offered there toast_action_ms, as a toast's, then over (archived_here: its
  // line leaves the list, RowsMotion::undo_over); timed here, where a row's block made again does not take it along
  let undo_due = Ref(fn() {  })
  v.owns(fn() {
    (undo_due.val)()
    undo_due.val = fn() {  }
  })
  |> ignore
  v.reacts(fn() { archived_here.get().map(fn(a) { a.n }) }, fn(n) {
    (undo_due.val)()
    undo_due.val = fn() {  }
    guard n is Some(n) else { return }
    undo_due.val = v.at_moment(
      v.cause_at() + @sf.toast_action_ms,
      fn() {
        match archived_here.untracked() {
          Some(a) if a.n == n && !a.undone => archived_here.set(None)
          _ => ()
        }
      },
      later=true,
    )
  })
  // the search's page open over them (search.mbt: from a list's field, or by ⌘K laid out Small): the lists up and away
  // under it
  let away = search_away_node(v)
  // (another workspace's lists another track, in its place at once: no way down the column, nor along the track from
  // where the one before stood; each made standing at its own filter)
  v.switch_by(fn() { workspace().map(fn(w) { w.id }) }, fn(p, id) {
    guard id is Some(id) else { return }
    // (a list's width a step: the theme's slide, a Move as long as it goes, from as wide as the lists are as it is said;
    // made at the filter shown as the workspace comes, so it slides only as the filter changes in it)
    // (at rest the one shown alone drawn; sliding from one to another, those from the one it came from till it is there)
    let at = @motion.NodeWay::new(@signals.untracked(frame.shown).to_double())
    let rest : @signals.Signal[Int] = @signals.signal(@signals.untracked(frame.shown))
    let due = Ref(fn() {  })
    p.reacts(frame.shown, fn(k) {
      let (_, _, w, _) = p.laid_window_now()
      at.go(p, k.to_double(), @sf.theme().chat_list.slide.per_unit(w))
      (due.val)()
      due.val = p.at_moment(at.end(), fn() { rest.set(k) })
    }, at_start=false)
    p.owns(fn() {
      (due.val)()
      due.val = fn() {  }
    })
    |> ignore
    p
    .grow(Is(1.0))
    .min_height(Is(Some(0.0)))
    // (gone by half way, what the search finds coming in after: never the lists' words and its seen one over another)
    .alpha(By(fn() { dmax(0.0, 1.0 - 2.0 * away()) }))
    .offset(By(fn() { (0.0, -search_list_rise * away()) }))
    |> ignore
    let all = list_filters.length() + frame.others.length()
    // (which of the lists have been shown in this workspace: what is made of them is kept from then)
    let shown_once : Array[@signals.Signal[Bool]] = Array::makei(all, fn(i) {
      @signals.signal(@signals.untracked(frame.shown) == i)
    })
    p.reacts(frame.shown, fn(k) {
      if k >= 0 && k < all {
        shown_once[k].set(true)
      }
    })
    // (the filter's menu opened: the three lists read and made by the time one is picked, kept from then)
    let opened_before = filter_menu_opened.untracked()
    p.reacts(fn() { filter_menu_opened.get() }, fn(n) {
      if n > opened_before {
        for k in 0..<list_filters.length() {
          if list_filters[k] != "hidden" { shown_once[k].set(true) }
        }
      }
    })
    // Release optimistic-hidden stations once core stops listing them so a subsequent restart shows the card again.
    p.reacts(
      fn() -> Array[String]? {
        if !@sfbase.restart_interrupted_gone.is_empty() {
          match @sfbase.chats_of(src, id, "all").0 {
            Some(v) => Some(v.interrupted.map(fn(item) { item.station }))
            None => None
          }
        } else {
          None
        }
      },
      fn(stations) {
        guard stations is Some(stations) else { return }
        if @sfbase.restart_interrupted_gone.is_empty() {
          return
        }
        let listed : Map[String, Bool] = Map([])
        for station in stations {
          listed[station] = true
        }
        if @sfbase.restart_interrupted_gone.keys().any(fn(k) { !listed.contains(k) }) {
          @sfbase.restart_interrupted_gone.retain(fn(k, _) { listed.contains(k) })
        }
      },
    )
    p.each(at_once=true, fn() { Array::makei(all, fn(i) { i }) }, fn(i) { i }, fn(lane, idx) {
      let i = idx.untracked()
      lane
      .over(Is(true))
      .shift(By(fn() { (i.to_double() - at.shown(lane), 0.0) }))
      // (out of view: no taller than nothing, so its list makes none of its rows; its height back as it comes)
      .max_height(By(fn() {
        let (a, b) = ((frame.shown)(), rest.get())
        if i < (if a < b { a } else { b }) || i > (if a < b { b } else { a }) {
          Some(0.0)
        } else {
          None
        }
      }))
      .clips(Is(true))
      // (read out only while it is the list shown: one slid off to a side, or on its way off, is out of view, its rows
      // none a screen reader is to read, and none of what changes as the filter does)
      .hides(By(fn() { (frame.shown)() != i }))
      |> ignore
      // (made once it is shown, or as the filter's menu opens (what it would show read by the time one is picked),
      // kept from then while the workspace is: each row only while it is in view; where it is scrolled to its list's
      // own, kept by the list's key: list_scroll)
      // (at once: a list made as it is first shown, or as the filter's menu opens, takes no way down the lane)
      lane.show(fn() { shown_once[i].get() }, at_once=true, fn(l) {
        l.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        if i < list_filters.length() {
          chats_pane_node(l, src, id, list_filters[i], frame, fn() { (frame.shown)() == i }, tips, stint)
        } else {
          (frame.others[i - list_filters.length()])(l)
        }
      })
    })
  })
}

///|
/// One of the lists (chats_pane's) of workspace `id` filtered by `filter` in node `v`: its states (being read, failing,
/// empty) and its days under the room `frame` keeps over them; `current`, the one shown.
fn chats_pane_node(
  v : @view.View,
  src : Source,
  id : String,
  filter : String,
  frame : ListsNodeFrame,
  current : () -> Bool,
  tips : @sf.TipLayer,
  stint : () -> Int,
) -> Unit {
  let key = "chats/" + id + "/" + filter
  let read = fn() { @sfbase.chats_of(src, id, filter) }
  let scroll = list_scroll(key)
  // (while the hand is on the list or it glides, its rows keep their places; a row the viewer moved goes at once)
  let held = fn() { v.pointed_in() || scroll.in_hand() || scroll.goes_on() }
  // its days in the order shown, and its rows by their names: worked out once as what is read, or the hand on it,
  // changes (held_order), what its lines and rows read
  let ordered : @signals.Signal[Array[ChatDay]] = @signals.signal([])
  // (by name, each row told only as its own chat changes, comes or goes: one row's words changed wake no other row)
  let rows : @signals.KeyedList[String, ChatItem] = @signals.keyed_list(same=fn(a, b) { physical_equal(a, b) || a == b })
  // (its days' lines by their keys, told only as a row or a day comes, goes or moves: not as a row's words change)
  let day_lines : @signals.Signal[Array[String]] = @signals.signal([])
  // (how many times the order shown has been said: what follows it told as it changes)
  let revision : @signals.Signal[Int] = @signals.signal(0)
  let seen : Ref[Array[ChatDay]] = Ref([])
  let stamp = Ref(0)
  // A count alone helps diagnose the work of opening a list, without recording any chat's name or contents.
  let recorded_rows = Ref(-1)
  // what of its rows and days comes, goes and goes ahead of others as the list changes while it is watched (ListRows'):
  // its lines as last shown, the rows going still among them (each after the line it came after, as it was), each
  // line coming or going and since when; told by a number as they change
  let motion = RowsMotion::new()
  // (the order last said and whether the hand held it then: let go with nothing new, what was held back is put in its
  // place quietly, RowsMotion::said)
  let said_stamp = Ref(-1)
  let said_hold = Ref(false)
  v.reacts(
    fn() {
      // (the core's days, a new array each time they change: told by a number as they do)
      // (and whether what changed since the app was last with the stations is still coming in: ChatsView's syncing)
      let (days, syncing) = match read().0 {
        Some(view) => (view.days, view.syncing is Some(_))
        None => ([], false)
      }
      if !physical_equal(days, seen.val) {
        seen.val = days
        stamp.val += 1
      }
      // (and its page's stay on top: what changed while it was off the top said as it is put back there, RowsMotion::said;
      // and whether it is the core's answer now or what it said before it was let go of: chats_live)
      (stamp.val, held(), stint(), @sfbase.chats_live(src, id, filter), syncing)
    },
    fn(at) {
      let days = seen.val
      let hold = at.1 && !@sfbase.viewer_moved(key, days)
      // (only whether it is still catching up changed: nothing of its rows to say again, what comes next told by it)
      if at.0 == said_stamp.val &&
        hold == said_hold.val &&
        at.2 == motion.stint &&
        (!at.3 || motion.had) {
        motion.syncing = at.4
        return
      }
      // (the hand let go of the list (gone to the chat beside it) with nothing come meanwhile: the order it held back
      // put in place quietly, no row seen to run off and back for the hand leaving; what comes while it is away, as ever)
      let let_go = at.0 == said_stamp.val && said_hold.val && !hold
      said_stamp.val = at.0
      said_hold.val = hold
      let shown = @sfbase.held_order(key, days, hold)
      let by_name : Map[String, ChatItem] = Map([])
      let names : Array[String] = []
      for d in shown {
        for item in d.items {
          let name = @sfbase.row_name(item)
          if !by_name.contains(name) {
            names.push(name)
          }
          by_name[name] = item
        }
      }
      let lines = day_keys(shown)
      if @hostapi.perf_recording() && by_name.length() != recorded_rows.val {
        recorded_rows.val = by_name.length()
        @hostapi.perf_line("chat-list: filter=\{filter} rows=\{recorded_rows.val}")
      }
      motion.said(
        v,
        lines,
        by_name,
        @signals.untracked(current),
        @signals.untracked(current) && @signals.untracked(frame.watched) && !let_go,
        at.2,
        @sfbase.chats_window_asked(id, filter),
        at.3,
        at.4,
      )
      let apply = fn() {
        ordered.set(shown)
        rows.reset(names, by_name)
        day_lines.set(lines)
        revision.set(revision.untracked() + 1)
      }
      if motion.watched {
        @view.transition(within=v, apply)
      } else {
        apply()
      }
    },
  )
  let days = fn() { ordered.get() }
  // its lines' keys before its days (its room under the bar, what the frame puts at its top, its states) and whether
  // its days follow: worked out anew as what is read changes, what follows it told only where these do, not as a row's
  // words or state do
  let lead_lines = @signals.computed(fn(_) {
    let (view, _) = read()
    let out = ["top"]
    if search_tucked(view) {
      out.push("search")
    }
    for p in (frame.before)(filter, view) {
      out.push("part/" + p.key)
    }
    match view {
      None => {
        out.push("wait")
        (out, false)
      }
      Some(v) => {
        match v.note {
          Some(n) if v.days.length() == 0 && (n.reading || n.failing.length() > 0) => out.push("wait")
          _ => ()
        }
        match v.note {
          Some(n) if n.empty && v.days.length() == 0 => out.push("empty")
          _ => ()
        }
        for p in (frame.after)(filter, Some(v)) {
          out.push("part/" + p.key)
        }
        (out, true)
      }
    }
  })
  // its lines' keys: those before its days, its days, its foot
  let keys = fn() {
    let (lead, has_days) = lead_lines.get()
    let out = lead.copy()
    if has_days {
      out.append(motion.lines(day_lines.get()))
    }
    out.push("foot")
    out
  }
  // (each row's chat by its name, as the days have it now: what reads it told only as that row's chat changes)
  let item_of = fn(name : String) -> ChatItem? { rows.get(name) }
  // (the shown one's rows: those an archived chat's neighbour is looked for in)
  v.reacts(fn() { (current(), revision.get()) }, fn(_) {
    if @signals.untracked(current) {
      listed.val = @signals.untracked(days).map(fn(d) { d.items }).fold(init=[], fn(a, b) { a + b })
      match @signals.untracked(read).0 {
        Some(view) => @sfbase.open_listed(view)
        None => ()
      }
    }
  })
  // Prewarm shaping and subpixel glyph rasterization for upcoming offscreen rows after a drawn frame
  // without creating View nodes or scheduling extra frames.
  let warm_queued : Ref[Bool] = Ref(false)
  let warm_env : Ref[String] = Ref("")
  let warmed : Set[String] = Set([])
  v.owns(fn() {
    warm_queued.val = false
    warm_env.val = ""
    warmed.clear()
  })
  |> ignore
  v.reacts(fn() { (current(), revision.get(), v.words_scale()) }, fn(_) {
    if !@signals.untracked(current) || warm_queued.val {
      return
    }
    warm_queued.val = true
    @ui.after_drawn_frame(fn() {
      warm_queued.val = false
      if !v.alive() || !@signals.untracked(current) || !@ui.words_ahead_able() {
        return
      }
      @signals.untracked(fn() {
        let (list_x, _, list_w, list_h) = v.laid_window_now()
        if list_w <= 0.0 || list_h <= 0.0 {
          return
        }
        let words_scale = v.words_scale()
        let theme = @sf.theme()
        let l = theme.chat_list
        let env_key = "\{id}|\{filter}|\{list_x}|\{list_w}|\{words_scale}|\{theme.dark}"
        if warm_env.val != env_key || warmed.length() > 256 {
          warm_env.val = env_key
          warmed.clear()
        }
        let row_pad = match frame.at {
          Whole => @sf.phone_row_in.px()
          Side | Tape => @sf.band_pad_in(frame.at)
        }
        let base_x = list_x + @sf.list_line_in(frame.at) + row_pad
        let marked_x = base_x + row_mark_w() + row_mark_gap()
        let heading_x = list_x +
          (match frame.at {
            Whole => @ui.Space::S5.px()
            Side | Tape => @sf.list_line_in(frame.at) + @sf.heading_in_at(frame.at)
          })
        let top_cov = (frame.top)()
        let scroll_y = scroll.drawn(v.tree)
        let row_h = dmax(1.0, l.row_h)
        let vis_start = dmax(0.0, (scroll_y - top_cov) / row_h).to_int()
        let vis_count = dmax(1.0, (list_h - top_cov) / row_h).to_int()
        let start = if vis_start + vis_count > 2 { vis_start + vis_count - 2 } else { 0 }
        let heading_look = @ui.style_words(l.heading_words)
        let heading_tab = @ui.style_tabular(l.heading_words)
        let mut idx = 0
        let mut count = 0
        for d in days() {
          if count >= 20 {
            break
          }
          let mut day_warmed = false
          for item in d.items {
            let cur = idx
            idx = idx + 1
            if cur < start {
              continue
            }
            if count >= 20 {
              break
            }
            if !day_warmed {
              day_warmed = true
              let hk = "h/" + d.label
              if !warmed.contains(hk) {
                warmed.add(hk)
                @ui.words_ahead(d.label, heading_look, heading_x, words_scale, tabular=heading_tab) |> ignore
              }
            }
            let rk = "r/" + @sfbase.row_name(item)
            if warmed.contains(rk) {
              continue
            }
            warmed.add(rk)
            count = count + 1
            let title_text = if item.hidden == Some(true) {
              item.title + " · " + @sf.t("web-main.filter.hidden")
            } else {
              item.title
            }
            let title_style = if item.unread { l.title_unread } else { l.title }
            let title_ox = if @sfbase.row_tone(item) != "" { marked_x } else { base_x }
            @ui.words_ahead(
              title_text,
              @ui.style_words(title_style),
              title_ox,
              words_scale,
              tabular=@ui.style_tabular(title_style),
            )
            |> ignore
            let state = match item.state_text {
              Some(s) => Some(s)
              None => item.decision_text
            }
            match state {
              Some(st) => {
                let lead = @sfbase.row_lead(item)
                let turn = lead == "decision" || lead == "need"
                let st_style = if item.unsent {
                  l.state_alert
                } else if turn {
                  l.state_turn
                } else {
                  l.state_quiet
                }
                match lead {
                  "need" | "done" | "archive" | "wait" | "watch" =>
                    if item.state_rest != "" {
                      @ui.words_ahead(
                        item.state_rest,
                        @ui.style_words(st_style),
                        marked_x,
                        words_scale,
                        tabular=@ui.style_tabular(st_style),
                      )
                      |> ignore
                    }
                  "decision" if item.state_lead_text != "" && st.has_prefix(item.state_lead_text) => {
                    let lead_style = st_style.then(l.state_lead)
                    let lead_w = @ui.words_ahead(
                      item.state_lead_text,
                      @ui.style_words(lead_style),
                      base_x,
                      words_scale,
                      tabular=@ui.style_tabular(lead_style),
                    )
                    let rest = st.clamped_view(start=item.state_lead_text.length()).to_owned()
                    @ui.words_ahead(
                      rest,
                      @ui.style_words(st_style),
                      base_x + lead_w,
                      words_scale,
                      tabular=@ui.style_tabular(st_style),
                    )
                    |> ignore
                  }
                  _ =>
                    @ui.words_ahead(
                      st,
                      @ui.style_words(st_style),
                      base_x,
                      words_scale,
                      tabular=@ui.style_tabular(st_style),
                    )
                    |> ignore
                }
              }
              None =>
                match item.last {
                  Some(last) if last != "" =>
                    @ui.words_ahead(
                      last,
                      @ui.style_words(l.last),
                      base_x,
                      words_scale,
                      tabular=@ui.style_tabular(l.last),
                    )
                    |> ignore
                  _ => ()
                }
            }
          }
        }
        @ui.words_ahead_flush()
      })
    })
  })
  let lead = fn() {
    match read().0 {
      Some(view) => view.leading
      None => "agents"
    }
  }
  // (how many more the core has, read anew only as its list changes, not each time the column is scrolled)
  let more = @signals.computed(fn(_) { @sfbase.chats_more(src, id, filter) })
  // (a window made taller: the list told the first window of it, where it holds fewer and the core has more; it never
  // shrinks)
  let held_rows = @signals.computed(fn(_) { @sfbase.chats_held(read().0) })
  v.reacts(fn() { (v.window_h(), more.get(), held_rows.get()) }, fn(at) {
    @sfbase.chats_window_for(src, id, filter, at.0, at.2, at.1)
  })
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  // (a chat's row in line `line`, its key as it is now (`key`: "r/" and its name, another's as the row is taken for
  // another, View::scrolls_window's reused): as its chat is now, the last it was where it is gone from the list (its
  // archive's 撤销 offered in its line, made again as that is scrolled back to))
  let row_line = fn(line : @view.View, key : () -> String) {
    let name = fn() { key().exact_view(start=2).to_owned() }
    let found = match @signals.untracked(fn() { item_of(name()) }) {
      Some(i) => Some(i)
      None => motion.gone_item(@signals.untracked(key))
    }
    guard found is Some(first) else { return }
    // (looked up once as its key or the days change, not by each of what of the row reads it: the last it was where it
    // is gone)
    // (what reads it woken only where the row comes out otherwise: a row its station's state makes anew at each change
    // of the list, offline or reconnecting, is the same row)
    let now = @signals.computed(
      fn(was : ChatItem?) {
        match item_of(name()) {
          Some(i) => i
          None => was.unwrap_or(first)
        }
      },
      same=fn(a, b) { physical_equal(a, b) || a == b },
    )
    let item = fn() { now.get() }
    let on = fn() {
      match open_chat() {
        Some(r) => @sfbase.row_is(item(), r)
        None => false
      }
    }
    // (gone from the list: its line closing its room where it was (the list's `goes`), drawn as it was; archived from
    // it, its line kept, the row's own node showing its tray there, till that is over and its room closes so)
    chat_row_node(
      line,
      src,
      tips,
      item,
      @signals.untracked(lead),
      on,
      frame.at,
      stint,
      list_ground=frame.ground,
      more=true,
      kept=fn() { motion.kept_line(key()) },
    )
    |> ignore
  }
  // (an archive's 撤销 over, or another's said: the line of the one before leaves)
  v.reacts(fn() { archived_here.get().map(fn(a) { a.n }) }, fn(_) { motion.undo_over(v, archived_here.untracked()) }, at_start=false)
  // (its bar along its right, clear of what is over its top and at its foot: the band, the bars)
  v.scrolls_window(
    scroll,
    keys,
    est=@signals.untracked(fn() { @sf.theme().chat_list.row_h }),
    bar=@ui.tree_scroll_bar(),
    top_covered=frame.top,
    bar_clear=fn() { ((frame.top)(), (frame.foot)()) },
    // (what comes, goes or goes ahead of others as the list changes while it is watched makes its way, the list's own:
    // RowsMotion says which)
    comes=fn(k) { motion.comes(k) },
    // (and a part at its top a person's act took away (a restart's card let go of, in a transition): closing its room
    // as it goes, the rows under it not jumping up into it; one the data took away goes at once, outside a transition)
    goes=fn(k) { motion.goes(k) || k.has_prefix("part/") },
    reorders=fn(k) { motion.moves(k) },
    // scrolled to within a screen of its foot while the core has more of its rows: its window a step more, the rows
    // added coming into the list it holds. A screen, not a screen and a half: its first window is what its room shows
    // and a screen more (sfbase's first_window), its foot a screen and a little below at rest, which a screen and a
    // half would have grown the moment it opened
    near_foot=(1.0, fn() { more.get() > 0 }, fn() {
      @sfbase.chats_grow(src, id, filter, @signals.untracked(fn() { held_rows.get() }), @signals.untracked(fn() { more.get() }))
    }),
    fn(b, k) {
    b.box(fn(line) {
      @sf.style_node(line, fn() { @sf.list_line(frame.at) })
      match k {
        "top" => line.height(By(fn() { Some((frame.top)() + @sf.theme().chat_list.top_in) })) |> ignore
        "foot" => line.height(By(fn() { Some((frame.foot)() + @sf.list_foot_in(frame.at)) })) |> ignore
        "search" => {
          let tucked = @signals.computed(fn(_) { search_tucked(read().0) })
          let reveal = match frame.at {
            Whole => {
              let revealed = @signals.computed(fn(_) {
                if !tucked.get() {
                  1.0
                } else {
                  let band = @sf.theme().chat_list
                  let vis_bottom = (frame.top)() + band.top_in + band.band_h - scroll.drawn(line.tree)
                  let emerged = vis_bottom - (frame.under)()
                  if emerged <= 0.5 {
                    0.0
                  } else if emerged >= 22.5 {
                    1.0
                  } else {
                    (emerged - 0.5) / 22.0
                  }
                }
              })
              fn() { revealed.get() }
            }
            Side | Tape => fn() { 1.0 }
          }
          let field = search_field_node(line, frame.at, reveal~)
          // the list's first time with its rows: the search tucked over them out of view, the first line after it at the
          // foot of what covers the list (frame.under: a phone's top bar, not the room under it; a side column's band,
          // the room over the list), there once scrolled to (Scroll::tucks: as far as the room over the list and the
          // field's line come to past that foot)
          scroll.tucks(
            field,
            fn() {
              match frame.at {
                Side | Tape => (frame.top)()
                Whole => (frame.under)()
              }
            },
            kept=fn() { tucked.get() },
          )
        }
        "wait" => list_waiting_node(line, src, read, frame.at, tips, stint)
        "empty" => list_empty_node(line, read, filter, frame.at)
        _ if k.has_prefix("part/") => {
          let part = k.exact_view(start=5).to_owned()
          let (view, _) = @signals.untracked(read)
          let parts = (frame.before)(filter, view) + (frame.after)(filter, view)
          match parts.iter().find_first(fn(p) { p.key == part }) {
            Some(p) => (p.make)(line)
            None => ()
          }
        }
        _ if k.has_prefix("h/") => @sf.list_heading_node(line, fn() { k.exact_view(start=2).to_owned() }, frame.at)
        // (a row of the list's, or one archived from it whose line is kept, its 撤销 there)
        _ => row_line(line, fn() { k })
      }
    })
    |> ignore
  },
    // (a chat's row, and a day's heading, as it no more shows, taken by the next of its kind to come to show: its key
    // that one's, not made and let go as the list is scrolled; one gone, as it was, not)
    reused=fn(k) {
      if k.has_prefix("r/") && motion.gone_item(k) is None {
        Some(0)
      } else if k.has_prefix("h/") {
        Some(1)
      } else {
        None
      }
    },
    make_reused=fn(b, key) {
      b.box(fn(line) {
        @sf.style_node(line, fn() { @sf.list_line(frame.at) })
        if b.reused_kind() == Some(1) {
          @sf.list_heading_node(line, fn() { key().exact_view(start=2).to_owned() }, frame.at)
        } else {
          row_line(line, key)
        }
      })
      |> ignore
    },
  )
  |> ignore
}

///|
/// A list read the first time, or with no rows to show while it waits on a station or cannot read one (list_waiting's)
/// in `v`: the rows to come in their bones, what is wrong over them in red, as many as the theme's chats' list has them.
fn list_waiting_node(
  v : @view.View,
  src : Source,
  read : () -> (ChatsView?, String?),
  at : @sf.ListAt,
  tips : @sf.TipLayer,
  stint : () -> Int,
) -> Unit {
  let note = fn() {
    match read().0 {
      Some(v) => v.note
      None => None
    }
  }
  let reading = fn() {
    match note() {
      Some(n) => n.reading
      None => true
    }
  }
  @sf.waiting_node(
    v,
    fn(s) {
      let l = @sf.theme().chat_list
      let n = if @signals.untracked(reading) { l.waiting_rows } else { l.waiting_noted }
      for i in 0..<n {
        let item = sample_chat(i)
        chat_row_node(s, src, tips, fn() { item }, "agents", fn() { false }, at, stint, more=i + 1 < n) |> ignore
      }
    },
    error=fn() { read().1.unwrap_or("") },
    note=fn() {
      match note() {
        Some(nt) => { reading: nt.reading, text: nt.text.unwrap_or(@sf.t("common.reading")), failing: nt.failing }
        None => { reading: true, text: @sf.t("common.reading"), failing: [] }
      }
    },
  )
}

///|
/// A list with nothing in it (list_empty's) in `v`: across the whole screen, the phone's illustration and what to do (a
/// new chat; with no station, the stations); in a side column (`at`), the sidebar's words (with no station, its link to
/// them).
fn list_empty_node(v : @view.View, read : () -> (ChatsView?, String?), filter : String, at : @sf.ListAt) -> Unit {
  let stations = fn() {
    match read().0 {
      Some(v) => v.stations
      None => 0
    }
  }
  v.switch_by(fn() {
    if at != Whole {
      0
    } else if stations() == 0 && filter == "all" {
      1
    } else {
      2
    }
  }, fn(p, which) {
    match which {
      0 =>
        p.box(fn(b) {
          @sf.style_node(b, fn() { said_box })
          match filter {
            "mine" => @sf.words_node(b, fn() { @sf.t("web-main.sidebar.noneMine") }, fn() { said_words }) |> ignore
            "watching" => @sf.words_node(b, fn() { @sf.t("web-main.sidebar.noneWatching") }, fn() { said_words }) |> ignore
            "hidden" => @sf.words_node(b, fn() { @sf.t("web-main.filter.hiddenEmpty") }, fn() { said_words }) |> ignore
            _ =>
              b.switch_by(fn() { stations() > 0 }, fn(q, some) {
                if some {
                  @sf.words_node(q, fn() { @sf.t("web-main.sidebar.none") }, fn() { said_words }) |> ignore
                } else {
                  @sf.note_link_node(q, fn() { @sf.t("web-main.sidebar.noStation.before") }, fn() {
                    @sf.t("web-main.sidebar.noStation.link")
                  }, fn() { open_page(Place("stations")) })
                }
              })
          }
        })
        |> ignore
      1 =>
        p.box(fn(b) {
          @sf.style_node(b, fn() { empty_first })
          @sf.drawable_node(b, if @sf.theme().dark { "illus_no_station_dark" } else { "illus_no_station" }, illustration_w) |> ignore
          @sf.words_node(b, fn() { @sf.t("android-settings.station.first") }, fn() { empty_title }) |> ignore
          @sf.words_node(b, fn() { @sf.t("android-settings.station.firstNote") }, fn() { empty_note }) |> ignore
        })
        |> ignore
      _ =>
        p.box(fn(b) {
          @sf.style_node(b, fn() { empty_box })
          @sf.drawable_node(b, if @sf.theme().dark { "illus_new_chat_dark" } else { "illus_new_chat" }, illustration_w) |> ignore
          match filter {
            "mine" => @sf.words_node(b, fn() { @sf.t("android-chat.home.empty.mine") }, fn() { empty_words }) |> ignore
            "watching" =>
              @sf.words_node(b, fn() { @sf.t("android-chat.home.empty.watching") }, fn() { empty_words }) |> ignore
            "hidden" => @sf.words_node(b, fn() { @sf.t("web-main.filter.hiddenEmpty") }, fn() { empty_words }) |> ignore
            _ => {
              @sf.words_node(b, fn() {
                @sf.t(if stations() > 1 { "android-chat.home.empty.many" } else { "android-chat.home.empty.one" })
              }, fn() { empty_note })
              |> ignore
              @sf.action_box_node(b, fn() { @sf.t("android-chat.newChat") }, fn(_) { open_page(NewChat) }, fn(k) {
                @sf.words_node(k, fn() { @sf.t("android-chat.newChat") }, fn() { empty_link }) |> ignore
              })
              |> ignore
            }
          }
        })
        |> ignore
    }
  })
}


///|
/// Where each list made once is scrolled to, by its key (its workspace's and filter's): kept while the app runs, the
/// same as it is left and come back to.
// kept across runs: put back as a run begins (sidebar_reset)
let list_scrolls : Map[String, @view.Scroll] = Map([])

///|
/// Each of the lists made once at its top (what is tucked over its rows in view): as a recording's list at its top
/// (sfapp's tape: listTop) has it.
pub fn lists_top() -> Unit {
  for _, s in list_scrolls {
    s.put(0.0)
  }
}

///|
/// List `key`'s scroll (list_scrolls'), made the first time it is asked for.
fn list_scroll(key : String) -> @view.Scroll {
  match list_scrolls.get(key) {
    Some(s) => s
    None => {
      let s = @view.Scroll::list()
      list_scrolls[key] = s
      s
    }
  }
}

///|
/// Whether a list as `view` says has the search at its top (sidebar.mbt's lines'): out of view till the list is pulled
/// down past its first row (Telegram's; asked 2026-11-14, a mouse's as a finger's, ⌘K beside it), while it has rows to
/// look in; not where the system's glass has a search of its own (sfdesk's chats.mbt sidebar_glass).
fn search_tucked(view : ChatsView?) -> Bool {
  if @sf.native_able() {
    return false
  }
  match view {
    Some({ note: Some({ empty: true, .. }), .. }) | None => false
    Some(_) => true
  }
}

///|
/// What of a list's lines comes, goes and moves among them by data as it changes while it is watched, its list's own
/// way (View::scrolls_window's `comes`, `goes`, `reorders`: the column's one way, the framework's): a row or a day new
/// to it comes where it is, its room opening; one gone closes its room where it was, drawn as it was; one gone ahead of
/// others closes where it was and opens where it is now, in the same way (the user, 2026-10-31: 「原地缩下去再从目标点挤出
/// 来更合理」). What this keeps is only what the list cannot
/// know: whether a change is one it is watched through (not the first time it has rows, nor the list not shown, nor
/// one its page took back from the stack's shelf: a new stint), the lines that come there at once all the same (a
/// page more's, after the last it had; a row archived here come back), and the rows archived from their row whose
/// line is kept (their 撤销 offered there) till that is over.
priv struct RowsMotion {
  mut last : Array[String]
  mut last_items : Map[String, ChatItem]
  mut had : Bool
  // (the page's stay on top it was last said in: Nav's stint)
  mut stint : Int
  // (how many rows it held as it was last said: rows held grown within a window asked past that, a page more came)
  mut held : Int
  // (whether its last change was said while it is watched: what came, went or moved by it makes its way)
  mut watched : Bool
  // (the lines new to it by its last change that are there at once all the same)
  quiet : Set[String]
  // (rows gone from it that were archived from their rows (archived_here's): kept among its lines, each after the line
  // it came after, as it was, while their 撤销 is offered; their line closing as a row gone does once that is over
  // (undo_over: `closed`), or the list's again as their chat comes back)
  undo_lines : Map[String, (ChatItem?, String)]
  closed : Set[String]
  told : @signals.Signal[Int]
  // (whether it was catching up as it was last said: what the stations bring in then, the last of it too, is there at
  // once)
  mut syncing : Bool
}

///|
fn RowsMotion::new() -> RowsMotion {
  {
    last: [],
    last_items: {},
    had: false,
    stint: 0,
    held: 0,
    watched: false,
    quiet: Set([]),
    undo_lines: {},
    closed: Set([]),
    told: @signals.signal(0),
    syncing: false,
  }
}

///|
/// The days `days` as lines (a heading and its rows each), by their keys.
fn day_keys(days : Array[ChatDay]) -> Array[String] {
  let out = []
  for d in days {
    out.push("h/" + d.label)
    for item in d.items {
      out.push("r/" + @sfbase.row_name(item))
    }
  }
  out
}

///|
/// Whether line `key` is one of its days' (a heading or a row): what comes, goes or moves by data; the rest of the
/// list's lines (its room, the search, what the frame puts in it, its states) there and gone at once, as they were,
/// but for a part the frame puts in it going by a person's act (the list's `goes`).
fn day_line(key : String) -> Bool {
  key.has_prefix("r/") || key.has_prefix("h/")
}

///|
/// The list's days now said (their lines `lines`, day_keys', its rows `by_name`) in node `v`'s timeline, `current` whether it is the list in view,
/// `watched` whether it is the list shown, in its page's stay on top `stint`, the window its list was last told it grows
/// to `asked` (chats_window_asked): whether what came, went and went ahead makes its way. What changed while its page was
/// off the top (on 小屏 kept on the stack's shelf at rest, its list said again only as it is taken back: a new stint) is
/// there at once, as on a page made anew; so are the rows a page more brings (its rows held grown within a window asked
/// past what it held, the lines new to it after the last it had), only a chat that arrives coming where it is (the
/// coordinator of the migration's ruling, 2026-11-13: a page more's rows opening one by one, measured as they opened, a
/// fling into them showed the list's ground). `live`: what is said is the core's answer now (sfbase's chats_live), not
/// what it said before the list was let go of; till it is, and as it is first told, nothing of it makes its way.
/// `syncing`: what changed since the app was last with the stations is still coming (ChatsView's syncing): what the
/// stations bring in then, and the batch that ends it, is there at once, but a row archived here from the list.
fn RowsMotion::said(
  self : RowsMotion,
  v : @view.View,
  lines : Array[String],
  by_name : Map[String, ChatItem],
  current : Bool,
  watched : Bool,
  stint : Int,
  asked : Int,
  live : Bool,
  syncing : Bool,
) -> Unit {
  let was = self.last
  let catching_up = syncing || self.syncing
  self.syncing = syncing
  self.quiet.clear()
  // (archived here and come back (撤销, or its archive refused): the list's again, in the line it kept, no way in)
  let mut back = false
  for k in lines {
    if self.undo_lines.contains(k) {
      self.undo_lines.remove(k)
      self.quiet.add(k)
      back = true
    }
    self.closed.remove(k)
  }
  // (a page more come: more rows held than before, a window past what it held asked)
  let held = by_name.length()
  let paged = held > self.held && asked > self.held
  self.held = held
  // (what the core answers first, and what it said before it was let go of shown till it does (`live` not yet: a
  // workspace or 设置 come back from), is where it is at once: only what changes after its answer is seen to)
  let watched = watched &&
    live &&
    !@view.answering_now() &&
    self.had &&
    !lines.is_empty() &&
    stint == self.stint &&
    (!catching_up || archived_here.untracked() is Some(_))
  self.stint = stint
  self.watched = watched
  if watched && !(was == lines) {
    // (after the last line it had, in a page more that came: there at once)
    match was.last() {
      Some(l) if paged =>
        match lines.search(l) {
          Some(p) =>
            for i in (p + 1)..<lines.length() {
              self.quiet.add(lines[i])
            }
          None => ()
        }
      _ => ()
    }
    // (archived from its row: its line kept whole after the last line before it that stays, its 撤销 there)
    let here : Set[String] = Set([])
    for k in lines {
      here.add(k)
    }
    let mut kept_after = ""
    for k in was {
      if !here.contains(k) && k.has_prefix("r/") && !self.undo_lines.contains(k) {
        let name = k.exact_view(start=2).to_owned()
        match archived_here.untracked() {
          Some(a) if a.name == name && !a.undone => {
            self.undo_lines[k] = (self.last_items.get(name), kept_after)
            back = true
          }
          _ => ()
        }
      }
      if here.contains(k) {
        kept_after = k
      }
    }
    // (at rest once its way is over: a Move's longest from its cause)
    let end = v.cause_at() + @ui.move_most_ms
    if end > rows_rest_at.val {
      rows_rest_at.val = end
    }
  }
  if back {
    @view.transition(within=v, fn() { self.told.set(self.told.untracked() + 1) })
  }
  // (archived from its row in the list in view, its line not kept (the list's last row gone with it, or its page not
  // on top as the core said it gone): said in a toast with its 撤销 as from anywhere else, never left unsaid)
  if current {
    match archived_here.untracked() {
      Some(a) if !a.undone => {
        let k = "r/" + a.name
        if was.contains(k) && !lines.contains(k) && !self.undo_lines.contains(k) {
          archived_here.set(None)
          (a.toast)()
        }
      }
      _ => ()
    }
  }
  self.had = self.had || (live && !lines.is_empty())
  self.last = lines
  self.last_items = by_name
}

///|
/// Whether line `key`, come to the list by its last change, comes making its way (View::scrolls_window's `comes`).
fn RowsMotion::comes(self : RowsMotion, key : String) -> Bool {
  self.watched && day_line(key) && !self.quiet.contains(key)
}

///|
/// Whether line `key`, gone from the list, closes its way where it was (View::scrolls_window's `goes`): one archived
/// here whose 撤销 is over, too.
fn RowsMotion::goes(self : RowsMotion, key : String) -> Bool {
  day_line(key) && (self.watched || self.closed.contains(key))
}

///|
/// Whether line `key`, staying among them, makes its way where it moved to by its last change (View::scrolls_window's
/// `reorders`).
fn RowsMotion::moves(self : RowsMotion, key : String) -> Bool {
  self.watched && day_line(key)
}

///|
/// The days' lines `lines` (day_keys') with the rows archived here whose line is kept among them, each after the line
/// it came after (the first, before all).
fn RowsMotion::lines(self : RowsMotion, lines : Array[String]) -> Array[String] {
  self.told.get() |> ignore
  if self.undo_lines.is_empty() {
    return lines
  }
  let out = lines.copy()
  let order = self.undo_lines.to_array()
  order.sort_by(fn(a, b) { a.0.compare(b.0) })
  for g in order {
    let (k, (_, after)) = g
    let mut at = 0
    if after != "" {
      for i, kk in out {
        if kk == after {
          at = i + 1
        }
      }
    }
    out.insert(at, k)
  }
  out
}

///|
/// Whether line `key` is a row archived from it whose line is kept, its 撤销 offered there or its room closing once that
/// is over (its tray shown in it all the while), followed.
fn RowsMotion::kept_line(self : RowsMotion, key : String) -> Bool {
  self.told.get() |> ignore
  self.undo_lines.contains(key) || self.closed.contains(key)
}

///|
/// The lines of rows archived from them whose 撤销 is over (all but the one `here` says, while it is offered): each
/// gone from the list now, its room closing as a row gone does (`goes`), from `v`'s cause's moment.
fn RowsMotion::undo_over(self : RowsMotion, v : @view.View, here : ArchivedHere?) -> Unit {
  let over = self.undo_lines.keys().filter(fn(k) { !(here is Some(a) && "r/" + a.name == k) }).collect()
  if over.is_empty() {
    return
  }
  for k in over {
    self.undo_lines.remove(k)
    self.closed.add(k)
  }
  let end = v.cause_at() + @ui.move_most_ms
  if end > rows_rest_at.val {
    rows_rest_at.val = end
  }
  @view.transition(within=v, fn() { self.told.set(self.told.untracked() + 1) })
}

///|
/// The chat of row `key` archived here whose line is kept, as it was; None for a row in the list.
fn RowsMotion::gone_item(self : RowsMotion, key : String) -> ChatItem? {
  match @signals.untracked(fn() { self.undo_lines.get(key) }) {
    Some((item, _)) => item
    None => None
  }
}

///|
/// When the rows of the lists made once last set coming, going or ahead of others are at rest (-1: none yet), as a
/// scripted run waits for a list's rows to be in place (a row come in, its room open).
// kept across runs: put back by sidebar_reset
let rows_rest_at : Ref[Double] = Ref(-1.0)

///|
/// When the lists' rows set moving last are at rest (rows_rest_at's).
pub fn rows_rest() -> Double {
  rows_rest_at.val
}
