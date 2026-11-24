// What the one player as nodes (player_node.mbt) has of a file of a folder (a drive's, played on its page): the
// folder's others of its kind as its playlist (the one before and the one after, 选集 docked at the right on a
// desktop's layout and a sheet from the foot on a phone's, the next one played at its end after a moment), the subtitle
// beside it read and said over the picture, opened where it was left on this device and where it is kept as it plays.
// What the old player's old player did by its Ctx each frame (player_media, desk_play_list, phone_list_sheet, ended_card,
// player_cue), each here at the moment of its cause.

///|
/// The folder's others a player steps through (`names`: in their order, the one playing among them by its `name`),
/// another of them played in its place by `go`.
priv struct PlayList {
  names : () -> Array[String]
  name : String
  go : (String) -> Unit
}

///|
/// Which of them plays (-1: none of them).
fn PlayList::index(self : PlayList) -> Int {
  (self.names)().search(self.name).unwrap_or(-1)
}

///|
/// Whether there are others to step to.
fn PlayList::many(self : PlayList) -> Bool {
  (self.names)().length() > 1
}

///|
/// The one after it, if any.
fn PlayList::next(self : PlayList) -> String? {
  next_in(self.name, (self.names)())
}

///|
/// The one before it, if any.
fn PlayList::prev(self : PlayList) -> String? {
  let i = self.index()
  if i > 0 {
    (self.names)().get(i - 1)
  } else {
    None
  }
}

///|
/// Which of how many it is ("" where there are no others).
fn PlayList::which(self : PlayList) -> String {
  let i = self.index()
  if self.many() && i >= 0 {
    "\{i + 1} / \{(self.names)().length()}"
  } else {
    ""
  }
}

///|
/// Another of them played in its place, what plays now paused first.
fn PlayerNode::go(self : PlayerNode, other : String) -> Unit {
  self.act(fn() { self.p.pause() })
  (self.pl.go)(other)
}

///|
/// The file `file` played as `key` while node `n` lives (the old player's player_media, at the moments of their causes):
/// opened once where it was left on this device is known (from its start where it was left within player_near_end_ms
/// of its end), or once that has been waited on player_place_ms from as `n` was made; the subtitle beside it (the
/// folder's `siblings`, as they are listed) read once the folder names one; where it is kept every player_keep_ms
/// while it plays. Its player, `n`'s: one opened under the key before it (a page gone that played the same file) let go
/// first; where it is kept and it closed as `n` is let go (player_let_go).
pub fn player_opened(n : @view.View, key : String, file : ViewerFile, siblings : () -> Array[ViewerEntry]) -> @player.Media {
  if playings.get(key) is Some(was) && was.opened.untracked() {
    player_let_go(key)
  }
  let pl = playing_for(key)
  pl.file = Some(file)
  n.owns(fn() {
    if playings.get(key) is Some(now) && physical_equal(now, pl) {
      player_let_go(key)
    }
  })
  |> ignore
  // (the wait on where it was left, given up as it opens)
  let waiting : Ref[() -> Unit] = Ref(fn() {  })
  let open = fn(start : Double) {
    if pl.opened.untracked() {
      return
    }
    (waiting.val)()
    waiting.val = fn() {  }
    pl.opened.set(true)
    pl.media.open(
      {
        name: file.name,
        mime: file.mime,
        audio: file.kind == "audio",
        read: player_read(file),
        direct: if file.stream is Some(_) { file.direct } else { "" },
      },
      start~,
    )
  }
  // where it was left, held on this device: waited on a moment at most from when it is first made
  if !pl.opened.untracked() {
    n.reacts(
      fn() {
        match (file.place)() {
          LeftAt(at, of) => Some(if at > 0.0 && (of <= 0.0 || at < of - player_near_end_ms) { at } else { 0.0 })
          NeverLeft => Some(0.0)
          NotKnown => None
        }
      },
      fn(start) {
        match start {
          Some(s) => open(s)
          None => ()
        }
      },
    )
    if !pl.opened.untracked() {
      waiting.val = n.at_moment(n.cause_at() + player_place_ms, fn() { open(0.0) })
    }
  }
  // the subtitle beside it, once the folder names one
  n.reacts(
    fn() {
      let all = siblings()
      match side_subtitle(file.name, all.filter(fn(e) { !e.dir }).map(fn(e) { e.name })) {
        Some(sub) =>
          match all.iter().find_first(fn(e) { e.name == sub && !e.dir }) {
            Some(side) if side.size <= player_subtitle_most => Some((sub, side.size, side.mtime))
            _ => None
          }
        None => None
      }
    },
    fn(told) {
      match (told, file.beside) {
        (Some((sub, _, _)), Some(beside)) if sub != pl.subtitle_of => {
          guard @signals.untracked(siblings).iter().find_first(fn(e) { e.name == sub && !e.dir }) is Some(side) else {
            return
          }
          pl.subtitle_of = sub
          pl.media.set_subtitle(true, [])
          beside(side, fn(r) {
            match r {
              Ok(bytes) => {
                let cues = @codec.parse_subtitles(sub, bytes)
                @ui.log("player: subtitle \{sub}: \{cues.length()} lines")
                pl.media.set_subtitle(true, cues)
              }
              Err(e) => @ui.log("player: subtitle \{sub} not read: \{e}")
            }
          })
        }
        _ => ()
      }
    },
  )
  // where it is, kept every 5 s while it is open and its length known (nothing shown waits for it: `later`)
  let keeping : Ref[() -> Unit] = Ref(fn() {  })
  n.reacts(fn() { pl.media.status().duration > 0.0 }, fn(known) {
    (keeping.val)()
    keeping.val = fn() {  }
    if known {
      fn next(at : Double) -> Unit {
        keeping.val = n.at_moment(at, later=true, fn() {
          if pl.media.started() {
            player_keep(pl, file)
            pl.keeps = pl.keeps + 1
          }
          next(at + player_keep_ms)
        })
      }
      next(n.cause_at() + player_keep_ms)
    }
  })
  pl.media
}

///|
/// What 选集 is drawn in: a film's on its dark (its own list ground), a song's on the page; its words, the quieter
/// ones, the one playing's ground, the hand's.
fn list_ink(picture : Bool) -> ViewerInk {
  if picture {
    {
      ground: player_list_dark,
      ink: media_dark_text,
      muted: media_dark_muted,
      line: alpha(media_dark_text, player_dark_line),
      hover: alpha(media_dark_text, media_hot_share),
      chosen: alpha(media_dark_text, player_dark_chosen),
    }
  } else {
    let pal = theme().p
    { ground: pal.canvas, ink: pal.text, muted: pal.muted, line: pal.line, hover: pal.hover, chosen: pal.selected }
  }
}

///|
/// The folder's others in `col` (a column it fills, a page's list of them): each numbered, its name, the one playing
/// on the chosen ground in 500 with ▶ (✓ paused); one pressed (not the one playing) plays in its place (and `done`).
#callsite(autofill(loc))
fn play_list_rows_node(col : @view.View, pn : PlayerNode, ink : () -> ViewerInk, done : () -> Unit, loc~ : SourceLoc) -> Unit {
  col.box(made_for=loc, fn(l) {
    style_node(l, fn() { desk_panel_list })
    let index = @signals.computed(fn(_) { pn.pl.index() })
    l.scrolls_window(
      @view.Scroll::list(),
      fn() { Array::makei((pn.pl.names)().length(), fn(i) { i }) },
      fn(row, i) {
        row.height(Is(Some(desk_row_h))) |> ignore
        let name = fn() { (pn.pl.names)().get(i).unwrap_or("") }
        let now = fn() { index.get() == i }
        @headless.button(row, name, fn(_) {
          done()
          if !@signals.untracked(now) {
            pn.go(@signals.untracked(name))
          }
        }, fn(b, s) {
          style_node(b, fn() { desk_list_row })
          b.ground(By(fn() { if now() { ink().chosen } else { no_ground } })) |> ignore
          hover_ground_node(b, on=fn() { !now() }, lit=Some(fn() { s.focus_shown() || s.hovered() || s.pressed() }), color=fn() {
            ink().hover
          })
          b.box(fn(num) {
            style_node(num, fn() { desk_chapter_number }, in_row=true)
            words_node(num, fn() { "\{i + 1}" }, fn() { desk_chapter_n_words.then(@ui.text_style(color=Data(ink().muted))) })
            |> ignore
          })
          |> ignore
          b.box(fn(w) {
            style_node(w, fn() { desk_grow_clip }, in_row=true)
            words_node(w, name, fn() { (if now() { desk_list_now } else { desk_list_words }).then(@ui.text_style(color=Data(ink().ink))) })
            |> ignore
          })
          |> ignore
          b.show(now, fn(i) {
            i
            .width(Is(Some(desk_check_icon)))
            .height(Is(Some(desk_check_icon)))
            .shapes(By(fn() { tool_shapes_sized(if pn.plays() { "play" } else { "check" }, desk_check_icon) }))
            .tint(By(fn() { ink().ink }))
            |> ignore
          })
        })
        |> ignore
      },
      est=desk_row_h,
      slop=@ui.touch_slop(),
      bar=@ui.tree_scroll_bar(),
    )
    |> ignore
  })
  |> ignore
}

///|
/// 选集 docked at the right of `parent` under the bar (a desktop's layout, the old player's desk_play_list), on a film's
/// dark or the page: its head (选集, which of how many, its close), then the folder's others.
#callsite(autofill(loc))
fn play_list_docked_node(parent : @view.View, pn : PlayerNode, picture : () -> Bool, loc~ : SourceLoc) -> Unit {
  let ink = fn() { list_ink(picture()) }
  let close = fn() { pn.list_open(false) }
  parent.box(made_for=loc, fn(place) {
    place.over(Is(true)) |> ignore
    place.box(fn(top) { style_node(top, fn() { desk_panel_top() }) }) |> ignore
    place.box(fn(row) {
      style_node(row, fn() { desk_panel_row })
      row.box(fn(room) { style_node(room, fn() { desk_panel_room }, in_row=true) }) |> ignore
      row.box(fn(p) {
        style_node(p, fn() { desk_panel_box.then(@ui.style(bg=Data(ink().ground))) }, in_row=true)
        // (a press on it its own: not the picture's under it)
        ground_node(p) |> ignore
        p.box(fn(head) {
          style_node(head, fn() { desk_list_head })
          // (its title cut short where it has not the room: its close stays in the panel)
          words_node(head, fn() { t("web-pages.drive.player.list") }, fn() {
            desk_panel_title.then(@ui.text_style(color=Data(ink().ink)))
          })
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          .cuts(Is(true))
          .allow_ellipsis(Is(true))
          |> ignore
          head.box(fn(n) {
            style_node(n, fn() { desk_grow }, in_row=true)
            words_node(n, fn() { pn.pl.which() }, fn() { desk_panel_note.then(@ui.text_style(color=Data(ink().muted))) }) |> ignore
          })
          |> ignore
          // (its close a tool of the bar's, as the old view's viewer_tool: its ground only under the hand)
          tool_node(head, fn() { { icon: "close", label: t("common.close"), on: false, disabled: false } }, ink, Is(tool_side / 2.0), close)
          |> ignore
        })
        |> ignore
        p.box(fn(b) {
          b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          play_list_rows_node(b, pn, ink, fn() {  })
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// 选集 as a sheet from the window's foot (a phone's layout, the old player's phone_list_sheet), on the page's own ground:
/// its title and which of how many, then the folder's others; one picked plays and closes it. Let go (dragged down, a
/// press outside, back), closed.
#callsite(autofill(loc))
fn play_list_sheet_node(parent : @view.View, pn : PlayerNode, loc~ : SourceLoc) -> Unit {
  let close = fn() { pn.list_open(false) }
  let ink = fn() { list_ink(false) }
  let x : PanelOf = {
    title: t("web-pages.drive.player.list"),
    description: "",
    w: panel_w,
    fits: false,
    wide: false,
    live: None,
    tall: player_list_sheet,
    grows: false,
    focus: false,
    ruled: false,
    fade_out_together: false,
    form: false,
    popover: false,
    stage: false,
    above: None,
    heads_itself: true,
    side: Bottom,
    along: Start,
    offset: panel_offset,
    match_panel: 0,
    scrolls_under: false,
    on_back: None,
    nodes: {
      body: fn(col, _) {
        col.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        col.box(fn(head) {
          style_node(head, fn() { layout_sheet_head })
          head.box(fn(w) {
            w
            .grow(Is(1.0))
            .words(By(fn() { t("web-pages.drive.player.list") }))
            .words_look(By(fn() { { ..@ui.style_words(sheet_title_words), line: -@ui.tree_theme().text_line } }))
            .ink(By(fn() { @ui.style_ink(sheet_title_words) }))
            |> ignore
          })
          |> ignore
          head.show(fn() { pn.pl.which() != "" }, fn(n) {
            words_node(n, fn() { pn.pl.which() }, fn() { desk_panel_note.then(@ui.text_style(color=Data(theme().p.muted))) }) |> ignore
          })
        })
        |> ignore
        col.box(fn(b) {
          b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          play_list_rows_node(b, pn, ink, close)
        })
        |> ignore
      },
      foot: None,
      hugs: false,
      hugs_centred: false,
      steps: false,
      sheet_heads: true,
      heads: false,
      top: 0.0,
      most: None,
      flush: false,
      head_end: None,
    },
  }
  parent.box(made_for=loc, fn(layer) {
    layer.over(Is(true)).stacked(Is(0)) |> ignore
    sheet_node(
      layer,
      fn() { pn.listing.get() },
      fn() { [{ n: 0, x, close, from: Unanchored }] },
      close,
    )
  })
  |> ignore
}

///|
/// 选集 open or closed (kept with its view: open still for the next one played in its place).
fn PlayerNode::list_open(self : PlayerNode, on : Bool) -> Unit {
  self.v.listing = on
  self.listing.set(on)
  self.wake()
}

///|
/// At its end, the next one in `parent`'s middle (the old player's ended_card): played in a moment (player_next_ms, the
/// seconds left said as they pass), or now, or not (let go); a card that asks, on the night over a picture, its way
/// out first and what it does last across its foot. Gone to, the card is done with.
#callsite(autofill(loc))
fn ended_card_node(parent : @view.View, pn : PlayerNode, ink : () -> MediaInk, loc~ : SourceLoc) -> Unit {
  let other = fn() {
    match pn.pl.next() {
      Some(o) if pn.phase(pn.status()) == Ended && pn.ended_off.get() != o => Some(o)
      _ => None
    }
  }
  // 选集 opened over the card (by its own button or the system's bar): the one to play is the person's to pick, so the
  // next one is let go as 取消 lets it go, the card gone at once and nothing played as 选集 closes. Open as it ended (a
  // 中屏's or 大屏's docked beside the picture, kept open from one to the next), the card comes and plays on as ever.
  parent.reacts(fn() { pn.listing.get() }, at_start=false, fn(on) {
    guard on && @signals.untracked(fn() { pn.phase(pn.status()) == Ended }) else { return }
    if @signals.untracked(fn() { pn.pl.next() }) is Some(o) && pn.ended_off.untracked() != o {
      pn.ended_off.set(o)
      pn.v.ended_off = o
    }
  })
  parent.box(made_for=loc, fn(layer) {
    layer.over(Is(true)).presses(By(fn() { other() is Some(_) })) |> ignore
    layer.pick(at_once=true, other, fn(m, o) {
      guard o is Some(o) else { return }
      let seconds = (player_next_ms / player_second_ms).round().to_int()
      let left = @signals.signal(seconds)
      let from = m.cause_at()
      let go_now = fn() {
        pn.ended_off.set(o)
        pn.v.ended_off = o
        pn.go(o)
      }
      // (what is shown does not wait for these: the card at any moment is whole, its next second and the next one
      // to come by time, as a toast's going)
      for k in 1..<seconds {
        m.at_moment(from + k.to_double() * player_second_ms, later=true, fn() { left.set(seconds - k) }) |> ignore
      }
      m.at_moment(from + player_next_ms, later=true, go_now) |> ignore
      m.over(Is(true)).lines_up(Is(Some(Middle))).padding(Is((@ui.Space::S4.px(), 0.0, @ui.Space::S4.px(), 0.0))) |> ignore
      m.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      let note = fn() {
        t("android-misc.drive.player.nextOne", args=[("name", o)]) +
        " · " +
        t("web-pages.drive.player.nextIn", args=[("n", left.get().to_string())])
      }
      night_card_node(m, ink, fn() { t("android-misc.drive.player.ended") }, note, fn(foot) {
        night_button_node(foot, fn() { t("common.cancel") }, fn() {
          pn.ended_off.set(o)
          pn.v.ended_off = o
        }, ink, ghost=true)
        |> ignore
        night_button_node(foot, fn() { t("android-misc.drive.player.next") }, go_now, ink) |> ignore
      })
      m.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    })
  })
  |> ignore
}

///|
/// The subtitle's lines over the picture in `parent` (the old player's player_cue): in the middle of what is left of its
/// width (`right` kept clear: 选集 docked there), `over()` off its foot while `up()` (clear of the controls), lower
/// (28) once they go; on a veil, in its words.
#callsite(autofill(loc))
fn cue_node(parent : @view.View, pn : PlayerNode, up : () -> Bool, over : () -> Double, right : () -> Double, loc~ : SourceLoc) -> Unit {
  let words = fn() { pn.p.cue_now() }
  parent.box(made_for=loc, fn(l) {
    l
    .over(Is(true))
    .presses(Is(false))
    .padding(By(fn() { (@ui.Space::S4.px(), 0.0, @ui.Space::S4.px() + right(), if up() { over() } else { @ui.Space::S7.px() }) }))
    |> ignore
    l.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    l.show(at_once=true, fn() { words() != "" }, fn(row) {
      row.row(Is(true)) |> ignore
      row.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      row.box(fn(b) {
        style_node(b, fn() { desk_cue_box }, in_row=true)
        b.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        words_node(b, words, fn() { desk_cue_words }) |> ignore
      })
      |> ignore
      row.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    })
  })
  |> ignore
}
