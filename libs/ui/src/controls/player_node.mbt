// The one player (player_parts.mbt's head says what it is and how it answers) as nodes of the window's tree, made once:
// what a viewer over the window plays (a chat's film or song), a drive's page plays (its folder's others and the
// subtitle beside it: player_list_node.mbt) and a file's tab beside a chat embeds (`embedded`). What it shows is bound to what it is worked out of (how the player stands, as its host tells it: its
// native view's signals; what it was told to do: `rev`), and what it does is done in a handler at the moment of its
// cause: a tap left single after a double tap's time, a note said for its time, what it waits on said once it has
// waited, its controls coming and going over their times from the moment that changed (what the old view's player did
// each frame, by the clock's moments here). Its picture is a native node of the
// tree's, placed where its zoom has it as each frame is drawn.

///|
/// What a player's nodes hold while they live: its player and its view's (player_parts.mbt's PlayerView: its zoom, where
/// its picture is), what it was told that its player keeps in no signal (`rev`, bumped as it is told), whether it is
/// ready, its controls (awake, the pointer near the bar or them, how far they show, gone once faded), what a double tap
/// said, what it waits on said and how fast its bytes come meanwhile, its menus open, a finger's drag on its picture and
/// where it has it, a held finger's speed (-1: none), a frame being saved; then what a finger's way on it holds, its
/// handler's alone.
priv struct PlayerNode {
  p : @player.Media
  v : PlayerView
  rev : @signals.Signal[Int]
  ready : @signals.Signal[Bool]
  awake : @signals.Signal[Bool]
  near_top : @signals.Signal[Bool]
  near_foot : @signals.Signal[Bool]
  shown : @motion.NodeWay
  faded : @signals.Signal[Bool]
  note : @signals.Signal[@player.MediaNote?]
  waited : @signals.Signal[Bool]
  rate : @signals.Signal[Double]
  rates : @signals.Signal[Bool]
  more : @signals.Signal[Bool]
  drag : @signals.Signal[PlayerDrag]
  drag_to : @signals.Signal[Double]
  drag_dy : @signals.Signal[Double]
  held : @signals.Signal[Double]
  taken_down : @signals.Signal[Bool]
  grabbing : @signals.Signal[Bool]
  listing : @signals.Signal[Bool]
  ended_off : @signals.Signal[String]
  embedded : Bool
  /// (embedded: how far in from the stage's edges what takes the hand is, as its picture is: clear of what lies at
  /// them, the side panel's edge)
  inset : Double
  pl : PlayList
  mut pending : Bool
  mut single : () -> Unit
  mut note_end : () -> Unit
  mut hold_end : () -> Unit
  mut down : (Double, Double)
  mut last : (Double, Double)
  mut moved : Bool
  mut long : Bool
  mut caught : Bool
  mut pinched : Bool
  mut pinch : (Double, Double, Double)
  fingers : Map[Int, (Double, Double)]
  speed : @ui.Velocity
  mut drag_from : Double
}

///|
fn PlayerNode::new(p : @player.Media, v : PlayerView, embedded : Bool, inset : Double, pl : PlayList) -> PlayerNode {
  let same_b = fn(a : Bool, b : Bool) { a == b }
  let same_d = fn(a : Double, b : Double) { a == b }
  {
    p,
    v,
    rev: @signals.signal(0),
    ready: @signals.signal(p.started(), same=same_b),
    awake: @signals.signal(true, same=same_b),
    near_top: @signals.signal(false, same=same_b),
    near_foot: @signals.signal(false, same=same_b),
    shown: @motion.NodeWay::new(1.0),
    faded: @signals.signal(false, same=same_b),
    note: @signals.signal(None, same=fn(a, b) { a == b }),
    waited: @signals.signal(false, same=same_b),
    rate: @signals.signal(-1.0, same=same_d),
    rates: @signals.signal(false, same=same_b),
    more: @signals.signal(false, same=same_b),
    drag: @signals.signal(NoDrag, same=fn(a, b) { a == b }),
    drag_to: @signals.signal(0.0, same=same_d),
    drag_dy: @signals.signal(0.0, same=same_d),
    held: @signals.signal(-1.0, same=same_d),
    taken_down: @signals.signal(false, same=same_b),
    grabbing: @signals.signal(false, same=same_b),
    listing: v.list_shown,
    ended_off: @signals.signal(v.ended_off),
    embedded,
    inset,
    pl,
    pending: false,
    single: fn() {  },
    note_end: fn() {  },
    hold_end: fn() {  },
    down: (0.0, 0.0),
    last: (0.0, 0.0),
    moved: false,
    long: false,
    caught: false,
    pinched: false,
    pinch: (0.0, 0.0, 0.0),
    fingers: Map([]),
    speed: @ui.Velocity::new(),
    drag_from: 0.0,
  }
}

///|
/// What it was told that its player keeps in no signal (its speed, its sound, its fill, where a finger moves it
/// through the time, its view opened again), read where a binding reads any of it.
fn PlayerNode::said(self : PlayerNode) -> Unit {
  self.rev.get() |> ignore
}

///|
/// `f` done to its player, and told.
fn PlayerNode::act(self : PlayerNode, f : () -> Unit) -> Unit {
  f()
  self.rev.set(self.rev.untracked() + 1)
}

///|
/// How it stands now, followed (its native view's signals, and what it was told).
fn PlayerNode::status(self : PlayerNode) -> @player.MediaStatus {
  self.said()
  self.p.status()
}

///|
/// What is playing (Media::frame's phase): failed, opening till it is ready, at its end, waiting for more, playing,
/// paused.
fn PlayerNode::phase(self : PlayerNode, s : @player.MediaStatus) -> @player.MediaPhase {
  if s.state < 0 {
    Failed
  } else if !self.ready.get() {
    Opening
  } else if s.ended {
    Ended
  } else if s.buffering {
    Buffering
  } else if s.playing {
    Playing
  } else {
    Paused
  }
}

///|
/// Whether it is a song: known to be, or once its host is done opening it and has said no size of a picture
/// (Media::frame's `audio`).
fn PlayerNode::audio(self : PlayerNode, s : @player.MediaStatus) -> Bool {
  self.said()
  let known = match self.p.track() {
    Some(t) => t.audio
    None => false
  }
  known ||
  (
    self.ready.get() &&
    (match self.p.native() {
      Some(n) => n.host_done()
      None => false
    }) &&
    s.width <= 0.0
  )
}

///|
/// Whether it plays (or waits for more), or will once a finger moving it through the time lets go (player_parts.mbt's plays).
fn PlayerNode::plays(self : PlayerNode) -> Bool {
  let s = self.status()
  ((s.playing || s.buffering) && !s.ended) || self.p.scrub_resumes()
}

///|
/// Whether its controls come (Media::frame's target): woken, the pointer near the bar or them, not playing, a song.
fn PlayerNode::wanted(self : PlayerNode) -> Bool {
  if self.embedded {
    return true
  }
  let s = self.status()
  self.awake.get() || self.near_top.get() || self.near_foot.get() || self.phase(s) != Playing || self.audio(s)
}

///|
/// Its speeds' menu open or closed (kept with its view as well, as the old player's view kept it).
fn PlayerNode::rates_open(self : PlayerNode, on : Bool) -> Unit {
  self.v.rates = on
  self.rates.set(on)
}

///|
/// Its controls brought back.
fn PlayerNode::wake(self : PlayerNode) -> Unit {
  self.awake.set(true)
}

///|
/// Whether its controls take presses (Media::frame's `on`): there or on their way, not gone.
fn PlayerNode::on(self : PlayerNode) -> Bool {
  !self.faded.get()
}

///|
/// Where it is among its frames now (player_parts.mbt's frames_of), followed.
fn PlayerNode::frames(self : PlayerNode) -> Frames {
  let s = self.status()
  frames_of(self.p, s, self.p.scrubbing().unwrap_or(s.position))
}

///|
/// Paused at the frame `d` from the one shown (the old player's step_frame), at once: a key's, a press's.
fn PlayerNode::step(self : PlayerNode, d : Int) -> Unit {
  let fr = @signals.untracked(fn() { self.frames() })
  self.act(fn() {
    self.p.pause()
    self.p.seek(fr.start_of(fr.at + d))
    @ui.log("player: frame \{fr.at + d + 1} of \{fr.count}")
  })
  self.wake()
}

///|
/// `delta` ms on (back, below 0), at once, its controls woken.
fn PlayerNode::jump(self : PlayerNode, delta : Double) -> Unit {
  self.act(fn() { self.p.seek_by(delta) })
  self.wake()
}

///|
/// Played or paused, its controls woken.
fn PlayerNode::play_pause(self : PlayerNode) -> Unit {
  self.act(fn() { self.p.play_pause() })
  self.wake()
}

///|
/// The frame shown asked to be saved (the old player's grab): taken as the host answers (PlayerNode::grab_taken), or given
/// up once it has been waited on media_grab_wait_ms from when it was asked, in `n`'s time.
fn PlayerNode::grab(self : PlayerNode, n : @view.View) -> Unit {
  let fr = @signals.untracked(fn() { self.frames() })
  match self.p.native() {
    Some(nv) if !self.grabbing.untracked() && !nv.grabbing() => {
      self.grabbing.set(true)
      self.v.grab_at = fr.at
      nv.grab_frame(fr.start_of(fr.at))
      n.at_moment(n.cause_at() + @player.media_grab_wait_ms, fn() {
        if self.grabbing.untracked() && nv.grabbing() {
          self.grabbing.set(false)
          nv.give_up_grab()
          (viewer_host().say)(t("android-chat.video.saveFrame.failed"))
        }
      })
      |> ignore
    }
    _ => ()
  }
  self.wake()
}

///|
/// A frame asked to be saved, taken as the host answers (the old player's take_grab): kept as a picture
/// (`<name>-<frame>.png`, to the device), or said it could not be.
fn PlayerNode::grab_taken(self : PlayerNode, name : String) -> Unit {
  guard self.grabbing.untracked() && self.p.native() is Some(nv) else { return }
  match nv.grabbed() {
    Some(png) => {
      self.grabbing.set(false)
      let base = match name.rev_find(".") {
        Some(i) if i > 0 => name.exact_view(end=i).to_owned()
        _ => name
      }
      if png.length() > 0 {
        (viewer_host().keep)(base + "-\{self.v.grab_at + 1}.png", "image/png", png)
      } else {
        (viewer_host().say)(t("android-chat.video.saveFrame.failed"))
      }
    }
    None => ()
  }
}

///|
/// A tap on its picture `w` wide at `x` (its own terms), at its moment in `n` (Media::stage's): left single once a
/// double tap's time has gone with no second (its controls hidden while they show over what plays, else woken); a
/// second within it a double one: on the left third back, on the right on, in the middle played or paused, said a
/// moment.
fn PlayerNode::tapped(self : PlayerNode, n : @view.View, x : Double, w : Double) -> Unit {
  let (_, double_ms, note_ms, _, _) = self.p.times()
  let at = n.cause_at()
  if self.pending {
    (self.single)()
    self.single = fn() {  }
    self.pending = false
    let third = w / 3.0
    let nudge = self.p.nudge_ms()
    let note : @player.MediaNote = if x < third {
      self.act(fn() { self.p.seek_by(-nudge) })
      Back(nudge)
    } else if x > third * 2.0 {
      self.act(fn() { self.p.seek_by(nudge) })
      Ahead(nudge)
    } else {
      // (at its end, whatever its host says of its playing: played again, as Media::play_pause does)
      let was = self.plays()
      self.act(fn() { self.p.play_pause() })
      if was {
        Paused
      } else {
        Played
      }
    }
    self.note.set(Some(note))
    (self.note_end)()
    self.note_end = n.at_moment(at + note_ms, fn() { self.note.set(None) }, later=true)
  } else {
    self.pending = true
    self.single = n.at_moment(at + double_ms, fn() {
      self.pending = false
      self.single = fn() {  }
      let playing = @signals.untracked(fn() { self.phase(self.status()) == Playing })
      if self.awake.untracked() && playing {
        self.awake.set(false)
      } else {
        self.wake()
      }
    })
  }
}

///|
/// What the player's nodes follow of it in `n`, from as it is made (what Media::frame did each frame, at the moments
/// of their causes): ready as its host says it is (the place it opens at sought once more there: Media::take_ready);
/// its decoder given up once it has waited media_decode_wait_ms from when all its bytes came; its controls coming
/// over wake_ms and going over sleep_ms from the moment that changed, gone (taking no press) once they have; what it
/// waits on said once it has waited wait_ms, and how fast its bytes come each whole second of it after the first; a
/// frame asked to be saved taken as the host answers.
fn PlayerNode::follow(self : PlayerNode, n : @view.View, name : String) -> Unit {
  let pn = self
  let (wait_ms, _, _, wake_ms, sleep_ms) = pn.p.times()
  n.reacts(fn() { pn.status() }, fn(_) {
    if pn.p.take_ready() {
      pn.ready.set(true)
    }
  })
  let stall : Ref[() -> Unit] = Ref(fn() {  })
  n.reacts(
    fn() {
      pn.said()
      pn.p.native().map(fn(v) { (v.id(), v.state(), v.decode_since()) })
    },
    fn(told) {
      (stall.val)()
      stall.val = fn() {  }
      match told {
        Some((_, 2, since)) if since >= 0.0 =>
          stall.val = n.at_moment(since + @player.media_decode_wait_ms, fn() {
            pn.act(fn() { pn.p.decode_given_up() })
          })
        _ => ()
      }
    },
  )
  // (its controls: there as it is made, as Media's are as it opens)
  let fade_end : Ref[() -> Unit] = Ref(fn() {  })
  n.reacts(fn() { pn.wanted() }, fn(on) {
    (fade_end.val)()
    fade_end.val = fn() {  }
    if on {
      pn.faded.set(false)
      pn.shown.go_ms(n, 1.0, wake_ms, ease=Out)
    } else {
      pn.shown.go_ms(n, 0.0, sleep_ms, ease=Out)
      fade_end.val = n.at_moment(pn.shown.end(), fn() { pn.faded.set(true) })
    }
  })
  let wait_end : Ref[() -> Unit] = Ref(fn() {  })
  n.reacts(
    fn() {
      let ph = pn.phase(pn.status())
      ph == Opening || ph == Buffering
    },
    fn(waits) {
      (wait_end.val)()
      wait_end.val = fn() {  }
      pn.waited.set(false)
      pn.rate.set(-1.0)
      if waits {
        let from = n.cause_at()
        wait_end.val = n.at_moment(from + wait_ms, fn() { pn.waited.set(true) })
        // (each whole second after the one it began in: how many bytes came over the last of them)
        let first = (from / 1000.0).floor() * 1000.0 + 1000.0
        let bytes = fn() {
          match pn.p.native() {
            Some(v) => @signals.untracked(fn() { v.bytes() })
            None => 0.0
          }
        }
        let tick : Ref[() -> Unit] = Ref(fn() {  })
        let said_end = wait_end.val
        // (a time nothing shown waits for, as long as it waits: `later`, as Media's every second was)
        fn second(at : Double, had : Double) -> Unit {
          tick.val = n.at_moment(at, later=true, fn() {
            let now = bytes()
            if had >= 0.0 {
              pn.rate.set(dmax(0.0, now - had))
            }
            second(at + 1000.0, now)
          })
        }
        second(first, -1.0)
        wait_end.val = fn() {
          said_end()
          (tick.val)()
        }
      }
    },
  )
  n.reacts(
    fn() {
      pn.said()
      pn.p.native().map(fn(v) { v.grabs_told() })
    },
    fn(_) { pn.grab_taken(name) },
  )
  n.owns(fn() {
    (fade_end.val)()
    (wait_end.val)()
    (stall.val)()
    (pn.single)()
    (pn.note_end)()
    (pn.hold_end)()
  })
  |> ignore
}

///|
/// The player `p` of `file` over a viewer's window as nodes in `parent`, its folder's others `list` (in their order,
/// `on_go` one of them played in its place: player_list_node.mbt; none, nothing of them shown):
/// `stage` how wide and tall it is laid out (its zoom fitted to that, clear of its bar and controls: player_room);
/// `still` (an image's key) shown where its picture will be until its first frame is; `flying`: its picture flown in or
/// back by the viewer (its bars and controls over that, on no ground of their own, answering nothing, its picture none
/// of its own); `going`: closed and drawn as it leaves (its controls away at once); back to `back_label` by `on_back`;
/// `move_beside`: the bar's 移到侧边 while it is offered, as that changes. A phone's or a desktop's, as wide as its stage is laid out.
/// `embedded`: in a stage of a page's own (a file's tab beside a chat), which has its name, its 下载 and its 全屏 over
/// it, as part of the page: no ground of its own; its picture (a song's view out of sight) fitted `margin` clear of the
/// edges of the room over its controls, seen only there however zoomed; the controls under that room, clear of the
/// stage's foot corners (player_room), in the page's colours with no ground of their own, always there and taking
/// presses; no bar, no back, no 选集, nothing that fills the screen or turns it sideways, no keys, no finger's drag down
/// to close it. The node.
#callsite(autofill(loc))
pub fn player_node(
  parent : @view.View,
  p : @player.Media,
  file : ViewerFile,
  stage : () -> (Double, Double),
  back_label~ : () -> String,
  on_back~ : () -> Unit,
  still~ : () -> String,
  flying~ : () -> Bool,
  going~ : () -> Bool,
  move_beside~ : () -> (() -> Unit)?,
  list? : () -> Array[String] = fn() { [] },
  on_go? : (String) -> Unit = fn(_) {  },
  embedded? : Bool = false,
  margin? : Double = 0.0,
  loc~ : SourceLoc,
) -> @view.View {
  let v = view_for(p.key(), margin~)
  // (what the view holds of the file it shows not held of another's; what it holds of the player, 选集 open, stays)
  if v.file != file.key {
    v.file = file.key
    // (the window's player's alone: one embedded fills nothing)
    if !embedded {
      native_full.set(false)
    }
    v.zoom.fit_now(at=parent.cause_at())
    v.ended_off = ""
  }
  let pn = PlayerNode::new(p, v, embedded, if embedded { margin } else { 0.0 }, { names: list, name: file.name, go: on_go })
  parent.box(made_for=loc, fn(n) {
    n.over(Is(true)) |> ignore
    pn.follow(n, file.name)
    // (where its picture is: its zoom told the room it has and its picture's size at the moment either changes)
    n.reacts(
      fn() {
        let (w, h) = stage()
        let (top, foot) = pn.room(w)
        let w = dmax(0.0, w - pn.panel(w))
        let s = pn.status()
        let natural = if s.width > 0.0 && s.height > 0.0 {
          (s.width, s.height)
        } else if file.facts.width > 0.0 && file.facts.height > 0.0 {
          (file.facts.width, file.facts.height)
        } else {
          match @ui.image_natural(still()) {
            Some((sw, sh)) if still() != "" && sw > 0.0 && sh > 0.0 => (sw, sh)
            _ => (0.0, 0.0)
          }
        }
        ((w, h - top - foot), natural)
      },
      fn(told) {
        let ((bw, bh), (nw, nh)) = told
        let at = n.cause_at()
        v.zoom.boxed(bw, bh, at~)
        if nw > 0.0 && nh > 0.0 {
          v.zoom.natural(nw, nh, at~)
        }
      },
    )
    v.placed_by = Some(fn() {
      let (x, y, w, h) = pn.picture_at(stage, n.cause_at())
      Some((x, y + pn.drag_dy.untracked(), w, h))
    })
    n.owns(fn() { v.placed_by = None }) |> ignore
    n.pick(at_once=true, fn() { layout(stage().0) is Small }, fn(k, small) {
      k.over(Is(true)) |> ignore
      if small {
        phone_player_node(k, pn, file, stage, on_back, still, flying, going)
        play_list_sheet_node(k, pn)
      } else {
        desk_player_node(k, pn, file, stage, back_label, on_back, still, flying, going, move_beside)
      }
    })
  })
}

///|
/// Where its picture shows in its stage at `t` (the old player's picture_place): where its zoom has it then (fitted until
/// zoomed in), clear of what its room keeps over it, or filling the screen turned sideways (cropped); its size not known
/// yet, a point in the middle.
fn PlayerNode::picture_at(
  self : PlayerNode,
  stage : () -> (Double, Double),
  t : Double,
) -> (Double, Double, Double, Double) {
  let (whole, h) = stage()
  let w = dmax(0.0, whole - self.panel(whole))
  let s = self.status()
  if self.p.fills() && self.p.is_sideways() {
    return self.p.picture_rect(s, w, h)
  }
  let (top, foot) = self.room(whole)
  match self.v.zoom.rect_at(t) {
    Some((x, y, pw, ph)) => (x, y + top, pw, ph)
    None if self.embedded => {
      let (x, y, pw, ph) = self.p.picture_rect(s, w, dmax(0.0, h - top - foot))
      (x, y + top, pw, ph)
    }
    None => self.p.picture_rect(s, w, h)
  }
}

///|
/// How far in from its stage's top and foot its picture is fitted, the stage `w` wide (player_room's, embedded where
/// it is).
fn PlayerNode::room(self : PlayerNode, w : Double) -> (Double, Double) {
  player_room(w, embedded=self.embedded)
}

///|
/// How much of its stage `w` wide 选集 takes at its right: docked there while it is open, on a desktop's layout, the
/// folder's others there to step to; else none.
fn PlayerNode::panel(self : PlayerNode, w : Double) -> Double {
  if !self.embedded && !(layout(w) is Small) && self.listing.get() && self.pl.many() {
    desk_panel_w
  } else {
    0.0
  }
}

///|
/// Where its picture is as `node` is drawn (its zoom's way read as it goes), a drag down taking it with the finger.
fn PlayerNode::picture_on(
  self : PlayerNode,
  node : @view.View,
  stage : () -> (Double, Double),
) -> (Double, Double, Double, Double) {
  let z = self.v.zoom
  z.told()
  let t = node.drawn_while(fn(at) { z.goes_at(at) })
  let (x, y, w, h) = self.picture_at(stage, t)
  (x, y + self.drag_dy.get(), w, h)
}

///|
/// Its picture in `parent`: its native view where its zoom has it as each frame is drawn, the still over it until its
/// first frame shows (the old player's player_still); none of its own while it flies (the viewer's flight draws it), nor a
/// song's (none to show). Kept past its node: the player closes its view.
fn picture_node(
  parent : @view.View,
  pn : PlayerNode,
  stage : () -> (Double, Double),
  still : () -> String,
  flying : () -> Bool,
  from : Double,
) -> Unit {
  let song = fn() { pn.audio(pn.status()) }
  // (a song embedded in a page: its view placed all the same, its host keeping it as it keeps one shown (Apple's
  // WebKit plays media only in a view put in the window: apple_views.m's prime_webm_grab), but wholly above the room
  // over its controls, which clips it, so no hole is cut in the page for it and nothing of it is seen)
  let shows = fn() { !flying() && (!song() || pn.embedded) }
  let out_of_sight = fn() {
    let (w, h) = stage()
    (dmax(1.0, w), dmax(1.0, h - pn.room(w).1))
  }
  parent.pick(
    at_once=true,
    fn() {
      pn.said()
      match pn.p.native() {
        Some(nv) if nv.here() && shows() => nv.id()
        _ => -1
      }
    },
    fn(k, id) {
      // (in the stage's own terms: `from` where the node it is in starts, in from the stage's edges)
      k.over(Is(true)).offset(Is((from, from))) |> ignore
      match pn.p.native() {
        Some(nv) if id >= 0 => {
          @ui.native(k, nv, kept=true)
          .over(Is(true))
          .offset(By(fn() {
            if song() {
              (0.0, -out_of_sight().1)
            } else {
              let (x, y, _, _) = pn.picture_on(k, stage)
              (x, y)
            }
          }))
          .width(By(fn() { Some(if song() { out_of_sight().0 } else { pn.picture_on(k, stage).2 }) }))
          .height(By(fn() { Some(if song() { out_of_sight().1 } else { pn.picture_on(k, stage).3 }) }))
          |> ignore
          k.box(fn(s) {
            s
            .over(Is(true))
            .offset(By(fn() {
              let (x, y, _, _) = pn.picture_on(s, stage)
              (x, y)
            }))
            .width(By(fn() { Some(pn.picture_on(s, stage).2) }))
            .height(By(fn() { Some(pn.picture_on(s, stage).3) }))
            .image(By(fn() {
              if still() != "" && !nv.shown() {
                Some((still(), "", player_px))
              } else {
                None
              }
            }))
            |> ignore
          })
          |> ignore
        }
        _ => ()
      }
    },
  )
}

///|
/// A node `n` drawn over the picture, its own words at `look` in `ink`: what said, centred (a pill).
#callsite(autofill(loc))
fn said_words_node(
  n : @view.View,
  words : () -> String,
  size : @ui.TextSize,
  ink : () -> Int64,
  weight? : Int = 400,
  loc~ : SourceLoc,
) -> @view.View {
  n.box(made_for=loc, fn(w) {
    w
    .words(By(words))
    .words_look(By(fn() {
      let (px, line) = @ui.tree_theme().text_size(size)
      { size: px, weight, line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
    }))
    .ink(By(ink))
    |> ignore
  })
}

///|
/// Whether it waits (opening, or for more as it plays) and has waited long enough to say so (PlayerNode::follow's
/// wait_ms).
fn PlayerNode::waits(self : PlayerNode) -> Bool {
  let ph = self.phase(self.status())
  (ph == Opening || ph == Buffering) && self.waited.get()
}

///|
/// What it waits on as a line of its own in `parent`: a spinner, then 正在打开 or 正在缓冲 and how fast its bytes come,
/// at `size` in `ink`, in a room as wide as the widest it says (said anew each second, the line keeps its width). Its
/// bar's, beside its tools (a phone's bar, the bar across the top); in the middle where it has none. The line's node.
#callsite(autofill(loc))
fn player_wait_node(parent : @view.View, pn : PlayerNode, size : @ui.TextSize, ink : () -> Int64, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(line) {
    line.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(@ui.Space::S2.px())).presses(Is(false)) |> ignore
    progress_spinner_node(line, fn() { None }, size=player_pill_spinner) |> ignore
    let what = fn() {
      t(if pn.phase(pn.status()) == Opening { "common.opening" } else { "web-pages.drive.player.buffering" })
    }
    let said = fn() {
      let r = pn.rate.get()
      if r >= 0.0 {
        what() + " · " + file_size(r) + "/s"
      } else {
        what()
      }
    }
    said_words_node(line, said, size, ink).min_width(By(fn() {
      if pn.rate.get() < 0.0 {
        None
      } else {
        let (px, h) = @ui.tree_theme().text_size(size)
        let look : @view.WordsLook = { size: px, weight: 400, line: h, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
        let most = player_rate_widest.fold(init=0.0, fn(w, r) {
          dmax(w, @view.words_measure(what() + " · " + r, look, 1.0e9, 1.0).0)
        })
        Some(dmax(most, @view.words_measure(said(), look, 1.0e9, 1.0).0))
      }
    }))
    |> ignore
  })
}

///|
/// Whether `k` is the dark-over-picture media ink (white text on dark video surface) rather than
/// the theme-adaptive audio stage ink.
fn player_is_picture_ink(k : MediaInk) -> Bool {
  k.text == media_dark_text && k.stage == media_dark_stage
}

///|
/// Single-layer iOS 27 Liquid Glass recipe for floating player controls and status overlays:
/// uses `@glass.liquid_viewer_dark_glass` over video pictures (`picture == true`, white ink) and
/// `@glass.liquid_floating_glass` over audio stages (`picture == false`, theme-adaptive ink),
/// keeping `ink().ground` as the `MBUI_GLASS=solid` fallback.
fn player_surface_glass(ink : () -> MediaInk, spot : (Double, Double)?) -> @ui.Glass {
  let k = ink()
  if player_is_picture_ink(k) {
    @glass.liquid_viewer_dark_glass(spot~, solid=k.ground, sharing=true)
  } else {
    @glass.liquid_floating_glass(spot~, solid=k.ground, sharing=true)
  }
}

///|
/// 0.5pt hairline border used when `MBUI_GLASS=solid` degrades floating player surfaces to solid.
fn player_solid_edge(ink : () -> MediaInk) -> (Double, Int64) {
  if player_is_picture_ink(ink()) {
    (control_edge_w, 0xFFFFFF26L)
  } else {
    (control_edge_w, theme().p.line)
  }
}

///|
/// What lies in the middle of its stage in `parent` (the old player's player_cover, player_waits, player_ask, the phone's
/// pill): a song's mark and its name; what it waits on once it has waited, where it has no bar to say it in
/// (player_wait_node); why it failed (a card on the night, its 重试 where trying again may help); a pill of what a
/// double tap did, a held finger's 2×, where a finger along it has gone (`pill`, "" none).
fn middle_node(parent : @view.View, pn : PlayerNode, name : String, pill : () -> String) -> Unit {
  let ink = fn() { media_ink(!pn.audio(pn.status())) }
  // (a song's mark and name, but where why it failed is said in their place: its card over them, nothing of them
  // round it)
  parent.show(at_once=true, fn() { pn.audio(pn.status()) && pn.phase(pn.status()) != Failed }, fn(c) {
    c
    .over(Is(true))
    .padding(Is((32.0, 0.0, 32.0, 0.0)))
    .gap(Is(@ui.Space::S4.px()))
    .lines_up(Is(Some(Middle)))
    .presses(Is(false))
    |> ignore
    c.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    icon_node(c, "file-audio", desk_cover_icon, By(fn() { ink().muted })) |> ignore
    c.box(fn(w) {
      w
      .words(Is(name))
      .words_look(By(fn() {
        let (px, line) = @ui.tree_theme().text_size(Title)
        { size: px, weight: 600, line, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
      }))
      .words_centered(Is(true))
      .ink(By(fn() { ink().text }))
      |> ignore
    })
    |> ignore
    c.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
  })
  // what it waits on, once it has waited, where it has no bar of its own to say it in (a page's stage, beside the
  // system's bars): its bar's else (player_wait_node); why it failed
  parent.show(at_once=true, fn() { (pn.embedded || native_on()) && pn.waits() }, fn(m) {
    m.over(Is(true)).lines_up(Is(Some(Middle))).presses(Is(false)) |> ignore
    m.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    m.box(fn(pill) {
      pill
      .padding(Is((@ui.Space::S3.px(), @ui.Space::S1_5.px(), @ui.Space::S3.px(), @ui.Space::S1_5.px())))
      .radius(By(fn() { @ui.tree_theme().corner(Xl1_5) }))
      |> ignore
      if pn.embedded {
        pill.ground(By(fn() { ink().ground })) |> ignore
      } else {
        @glass.liquid_capsule_decorate(
          pill,
          glass=fn(spot) { player_surface_glass(ink, spot) },
          shadow=glass_control_shadow,
          solid_edge=fn() { player_solid_edge(ink) },
        )
        |> ignore
      }
      player_wait_node(pill, pn, Ui, fn() { ink().text }) |> ignore
    })
    |> ignore
    m.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
  })
  parent.show(at_once=true, fn() { pn.phase(pn.status()) == Failed }, fn(m) {
    m.over(Is(true)).lines_up(Is(Some(Middle))).padding(Is((@ui.Space::S4.px(), 0.0, @ui.Space::S4.px(), 0.0))) |> ignore
    m.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    failed_card_node(m, pn, ink)
    m.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
  })
  parent.show(at_once=true, fn() { pill() != "" }, fn(m) {
    m.over(Is(true)).lines_up(Is(Some(Middle))).presses(Is(false)) |> ignore
    m.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    m.box(fn(b) {
      b
      .padding(Is((@ui.Space::S3.px(), @ui.Space::S1_5.px(), @ui.Space::S3.px(), @ui.Space::S1_5.px())))
      .radius(By(fn() { @ui.tree_theme().corner(Xl1_5) }))
      |> ignore
      if pn.embedded {
        b.ground(By(fn() { ink().ground })) |> ignore
      } else {
        @glass.liquid_capsule_decorate(
          b,
          glass=fn(spot) { player_surface_glass(ink, spot) },
          shadow=glass_control_shadow,
          solid_edge=fn() { player_solid_edge(ink) },
        )
        |> ignore
      }
      said_words_node(b, pill, Ui, fn() { ink().text }) |> ignore
    })
    |> ignore
    m.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
  })
}

///|
/// Why it failed, a card alone in its stage's middle (the old player's player_ask, on the night over a picture): its
/// title, the line the answer turns on (its format's, where its media type says which), 重试 across its foot where
/// trying again may help (not where its format or its file cannot be played).
#callsite(autofill(loc))
fn failed_card_node(parent : @view.View, pn : PlayerNode, ink : () -> MediaInk, loc~ : SourceLoc) -> Unit {
  let state = fn() { pn.status().state }
  let title = fn() {
    t(if pn.audio(pn.status()) { "android-misc.drive.player.failed" } else { "android-chat.video.failed" })
  }
  let note = fn() {
    pn.said()
    let format = match pn.p.track() {
      Some(track) => player_format(track.mime)
      None => None
    }
    match (state(), format) {
      (-2, Some(format)) => t("android-misc.drive.player.unsupportedFormat", args=[("format", format)])
      (-2, None) => t("android-misc.drive.player.unsupported")
      (-3, _) => t("android-misc.drive.player.damaged")
      (-4, Some(format)) => t("android-misc.drive.player.unplayableFormat", args=[("format", format)])
      (-4, None) => t("android-misc.drive.player.unplayable")
      _ => ""
    }
  }
  night_card_node(parent, ink, title, note, fn(foot) {
    night_button_node(foot, fn() { t("android-misc.drive.player.retry") }, fn() {
      pn.act(fn() { pn.p.retry() })
      pn.ready.set(pn.p.started())
    }, ink)
    |> ignore
  }, buttons=fn() { state() != -2 && state() != -3 && state() != -4 }, embedded=pn.embedded, loc~)
}

///|
/// A card that asks over a player's stage in `parent` (the old player's player_ask): a confirming dialog's width whatever
/// it says (its seconds counting down move nothing), its title and the line the answer turns on (`note`, none while
/// "") in its middle, its buttons (`foot`'s) across its foot while `buttons()`, concentric with its foot corners.
#callsite(autofill(loc))
fn night_card_node(
  parent : @view.View,
  ink : () -> MediaInk,
  title : () -> String,
  note : () -> String,
  foot : (@view.View) -> Unit,
  buttons? : () -> Bool = fn() { true },
  embedded? : Bool = false,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(card) {
    // (a confirming dialog's width, less where the stage is narrower: in from its sides as what holds it has it)
    card
    .width_share(Is(1.0))
    .max_width(Is(Some(confirm_w)))
    .padding(Is((card_pad, card_pad, card_pad, card_pad)))
    .gap(Is(ask_card_gap))
    .radius(Is(card_corner))
    |> ignore
    if embedded {
      card.ground(By(fn() { ink().ground })) |> ignore
    } else {
      @glass.liquid_capsule_decorate(
        card,
        glass=fn(spot) { player_surface_glass(ink, spot) },
        shadow=glass_overlay_shadow,
        solid_edge=fn() { player_solid_edge(ink) },
        clips=false,
      )
      |> ignore
    }
    card.box(fn(w) {
      w.gap(Is(@ui.Space::S0_5.px())) |> ignore
      w.box(fn(l) {
        l
        .words(By(title))
        .words_look(By(fn() {
          let (px, line) = @ui.tree_theme().text_size(Ui)
          { size: px, weight: 600, line: @ui.tree_theme().leading(L5).unwrap_or(line), wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
        }))
        .words_centered(Is(true))
        .ink(By(fn() { ink().text }))
        |> ignore
      })
      |> ignore
      w.show(at_once=true, fn() { note() != "" }, fn(l) {
        l
        .words(By(note))
        .words_look(By(fn() {
          let (px, line) = @ui.tree_theme().text_size(Caption)
          { size: px, weight: 400, line: @ui.tree_theme().leading(L4_75).unwrap_or(line), wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
        }))
        .words_centered(Is(true))
        .ink(By(fn() { ink().muted }))
        |> ignore
      })
    })
    |> ignore
    card.show(at_once=true, buttons, fn(f) {
      // (its buttons concentric with the card's foot corners: ask_buttons_across's foot_reach)
      let h = button_height()
      let reach = card_foot_in(h) - card_pad
      // (each its share across it, going on to another line where it has not the room: ask_buttons_across's)
      f
      .row(Is(true))
      .gap(Is(@ui.Space::S2.px()))
      .margin(Is((reach, 0.0, reach, reach)))
      .wraps(By(fn() { Some(ask_foot_lines()) }))
      .wraps_at_least(Is(true))
      |> ignore
      foot(f)
    })
  })
  |> ignore
}

///|
/// A button on the night across what holds it (button's `on_night` Primary: the white, its words the night, a step
/// toward the words under the hand), a button's height and words; `press` as it is pressed. The node.
#callsite(autofill(loc))
fn night_button_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  ink : () -> MediaInk,
  ghost? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  // (on the night over a picture; a song's card on the page's own ground, the theme's buttons: player_ask's on_the_night)
  let night = fn() { ink().text == media_dark_text }
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, fn(v, b) {
    let lit = fn() { b.focus_shown() || b.hovered() || b.pressed() }
    let hand = @motion.NodeWay::new(0.0)
    v.reacts(lit, fn(on) { hand.go_ms(v, if on { 1.0 } else { 0.0 }, dur_ms) })
    let h = button_height()
    // (its share of the foot, kept at what it holds where it goes on to another line: button_node's across a foot)
    v
    .grow(Is(1.0))
    .basis(Is(Some(0.0)))
    .keeps_held(Is(true))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .height(Is(Some(h)))
    .padding(Is((button_padx, 0.0, button_padx, 0.0)))
    .radius(Is(h / 2.0))
    .focus_ring_theme()
    .ground(By(fn() {
      let p = theme().p
      match (ghost, night()) {
        // (the night's plain button, as the old view's on the night: a step towards its lit one under the hand)
        (true, true) => mix(stage_plain_lit, hand.shown(v), stage_plain)
        (false, true) => mix(0xFFFFFFFFL, hand.shown(v), share_ink)
        (true, false) => over(p.chip, alpha(p.hover, hand.shown(v)))
        (false, false) => mix(p.primary_hover, hand.shown(v), p.primary)
      }
    }))
    |> ignore
    v.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    v.box(fn(w) {
      w
      .words(By(label))
      .words_look(By(fn() {
        { size: theme().t.ui, weight: if theme().touch { 600 } else { 500 }, line: theme().t.ui_line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
      }))
      .ink(By(fn() {
        match (ghost, night()) {
          (true, true) => share_ink
          (false, true) => share_ground
          (true, false) => theme().p.text
          (false, false) => theme().p.bg
        }
      }))
      |> ignore
    })
    |> ignore
    v.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
  })
}

///|
/// One of the controls' round keys in `parent` (the old player's media_key and phone_key): `side` across, its icon `icon()`
/// `icon_size` across, in the quieter ink till the hand is on it (`bright`: the words' always; `lit`: on, the words at
/// 16% under it), the words at 10% under the hand; named `label()` (its tip in `tips` where there are tips), taking no
/// press while `on()` holds not (faded where `faint`); `press` as it is pressed; `ripples`: a finger's press ripples over
/// it (a phone's). The node.
#callsite(autofill(loc))
fn media_key_node(
  parent : @view.View,
  icon : () -> String,
  label : () -> String,
  on : () -> Bool,
  ink : () -> MediaInk,
  press : () -> Unit,
  side? : Double = media_key_d,
  icon_size? : Double = viewer_back_icon,
  bright? : Bool = false,
  lit? : () -> Bool = fn() { false },
  faint? : Bool = true,
  ripples? : Bool = false,
  tips? : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  let rippled : Ref[PressLook?] = Ref(None)
  let down : ((@view.Drag) -> Unit)? = if ripples {
    Some(fn(d) { if rippled.val is Some(r) { (r.down)(d) } })
  } else {
    None
  }
  let tapped : ((@view.Drag) -> Unit)? = if ripples {
    Some(fn(d) { if rippled.val is Some(r) { (r.tapped)(d) } })
  } else {
    None
  }
  @headless.toggle(
    made_for=loc,
    parent,
    Button,
    label,
    lit,
    fn(_) { press() },
    disabled=fn() { !on() },
    hold=@headless.Hold::new(@ui.touch_slop(), @ui.long_press_ms, fn() { false }, down?=down, tapped?=tapped),
    fn(v, b) {
      let hot = fn() { on() && (b.hovered() || b.pressed() || b.focus_shown()) }
      let pad = (side - icon_size) / 2.0
      v
      .width(Is(Some(side)))
      .height(Is(Some(side)))
      .padding(Is((pad, pad, pad, pad)))
      .radius(Is(side / 2.0))
      .alpha(By(fn() { if faint && !on() { media_off } else { 1.0 } }))
      .ground(By(fn() {
        let k = ink()
        if lit() {
          alpha(k.text, media_lit_share)
        } else if hot() && !ripples {
          alpha(k.text, media_hot_share)
        } else {
          no_ground
        }
      }))
      |> ignore
      v.box(fn(i) {
        i
        .width(Is(Some(icon_size)))
        .height(Is(Some(icon_size)))
        .shapes(By(fn() { tool_shapes_sized(icon(), icon_size) }))
        .drawn_as(By(fn() { "/icon/" + icon() + "/" }))
        .tint(By(fn() {
          let k = ink()
          if bright || hot() || lit() || ripples {
            k.text
          } else {
            k.muted
          }
        }))
        |> ignore
      })
      |> ignore
      rippled.val = if ripples {
        Some(press_look(v, Is(side / 2.0), fn() { false }))
      } else {
        None
      }
      match tips {
        Some(tl) => tip_node(tl, v, label, side=Top) |> ignore
        None => ()
      }
    },
  )
}

///|
/// Icon `name` drawn `size` across in no colour of its own (the node's tint).
fn tool_shapes_sized(name : String, size : Double) -> Array[@ui.Shape] {
  match icon_numbers(name) {
    Some(d) => icon_shapes(d, size / 24.0, 0x000000FFL)
    None => []
  }
}

///|
/// How faint a key that cannot be pressed is (media_key_box's disabled: 35%).
let media_off : Double = 0.35

///|
/// The speed as a figure in `parent` (the old player's media_rate, a desktop's; phone_speed, a phone's: `phone`): what it
/// plays at in the code face in 600, on the words at 10% (a phone's bare till pressed or while its menu is open); named
/// `label()`, its menu of speeds over it as it is pressed (speed_menu's: each a choice, the one it plays at checked),
/// chosen as it closes. The node.
#callsite(autofill(loc))
fn speed_node(
  parent : @view.View,
  pn : PlayerNode,
  ink : () -> MediaInk,
  label : () -> String,
  phone~ : Bool,
  tips? : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  let words = fn() {
    pn.said()
    speed_label(pn.p.speed())
  }
  let layer = parent.tree.root()
  let b = @headless.disclosure(
    made_for=loc,
    parent,
    label,
    fn() { pn.rates.get() },
    fn(_) {
      pn.rates_open(!pn.rates.untracked())
      pn.wake()
    },
    fn(v, d) {
      let lit = fn() { pn.rates.get() }
      v
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .presses(By(fn() { pn.on() }))
      |> ignore
      if phone {
        v
        .min_width(Is(Some(phone_key_side)))
        .min_height(Is(Some(phone_key_side)))
        .padding(Is((@ui.Space::S2.px(), 2.0, @ui.Space::S2.px(), 2.0)))
        .radius(Is(1.0e6))
        .ground(By(fn() { if lit() { alpha(ink().text, media_lit_share) } else { no_ground } }))
        |> ignore
      } else {
        v
        .min_width(Is(Some(media_rate_w)))
        .min_height(Is(Some(media_rate_h)))
        .padding(Is((@ui.Space::S2.px(), 2.0, @ui.Space::S2.px(), 2.0)))
        .margin(Is((0.0, 0.0, @ui.capsule_in(card_corner, media_rate_h) - media_bar_pad, 0.0)))
        .radius(Is(1.0e6))
        .focus_ring_theme()
        .ground(By(fn() { alpha(ink().text, media_rate_share) }))
        |> ignore
        hover_ground_node(
          v,
          lit=Some(fn() { d.hovered() || d.pressed() || d.focus_shown() }),
          color=fn() { alpha(ink().text, media_hot_share) },
        )
      }
      v.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      v.box(fn(w) {
        w
        .words_runs(By(fn() { [@ui.span(words(), weight=media_strong, mono=true, color=ink().text)] }))
        .words_look(By(fn() {
          let (px, line) = @ui.tree_theme().text_size(Meta)
          { size: px, weight: 400, line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
        }))
        |> ignore
      })
      |> ignore
      v.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      match tips {
        Some(tl) => tip_node(tl, v, label, side=Top) |> ignore
        None => ()
      }
    },
  )
  // (its menu made as it opens, over the window, living as long as it does)
  let holder = layer.box(fn(h) { h.over(Is(true)) |> ignore }).lives_with(b)
  holder.show(at_once=true, fn() { pn.rates.get() }, fn(m) {
    m.over(Is(true)).opened_by(@view.ByNode(b.id())) |> ignore
    menu_node(
      m,
      fn() { true },
      fn(_) { b },
      fn() {
        pn.said()
        player_speeds.map(fn(sp) {
          Some(
            menu_item_of(speed_label(sp), chosen=sp == pn.p.speed(), fn() {
              pn.act(fn() { pn.p.set_speed(sp) })
              pn.wake()
            }),
          )
        })
      },
      "",
      Start,
      @ui.Space::S1_5.px(),
      false,
      false,
      fn(item) {
        pn.rates_open(false)
        (item.select)()
      },
      fn() { pn.rates_open(false) },
      min_w=player_speeds_w,
      side=Top,
    )
  })
  b.owns(fn() { pn.rates_open(false) }) |> ignore
  b
}

///|
/// A timeline in `parent` (the old player's desk_play_timeline and phone_timeline): `h` high, thumb-free Apple-style
/// fluid scrubber track (5pt rest, 7.5pt hover, 10pt active via paint-layer `ground_drawn`, laid == 0, 0 extra glass)
/// with full-width buffered segment at 22% and active fill in the words ink;
/// pressed or dragged along, the picture goes with it frame by frame (Media::scrub_to: each time where a frame starts,
/// where the file's frames are read), sent there once let go (Media::scrub_done). `pointed`: with a mouse over it (or
/// dragging), the time where it points over it (a desktop's). Read out a slider of where it is.
#callsite(autofill(loc))
fn timeline_node(
  parent : @view.View,
  pn : PlayerNode,
  h : Double,
  ink : () -> MediaInk,
  pointed~ : Bool,
  loc~ : SourceLoc,
) -> Unit {
  let dur = fn() { pn.status().duration }
  let part = fn(ms : Double) {
    let d = dur()
    if d <= 0.0 {
      0.0
    } else {
      dmin(1.0, dmax(0.0, ms / d))
    }
  }
  let shown = fn() {
    pn.said()
    let s = pn.status()
    match (pn.p.scrubbing(), pn.drag.get()) {
      (Some(x), _) => part(x)
      (None, AlongTime) => part(pn.drag_to.get())
      _ => part(s.position)
    }
  }
  let swell = @motion.NodeWay::new(0.0)
  let active = @signals.signal(false)
  parent.box(made_for=loc, fn(room) {
    room.height(Is(Some(h))) |> ignore
    room.by_room(fn(held, r) {
      // what a finger or the pointer does along it (Media::timeline): held on it a frame (as a frame drawn while it is
      // down sees it held) or moved, the picture goes with it frame by frame (Media::scrub_to: the very frame, each
      // time where a frame starts), the frame let go on sent once let go (Media::scrub_done); let go before that where
      // it went down, a tap, there at once,
      // played or paused as it was (Media::seek_near: the nearest key frame)
      let inset = player_track_inset
      let pending : Ref[(Double, Double)?] = Ref(None)
      let dragging = Ref(false)
      let held_due : Ref[() -> Unit] = Ref(fn() {  })
      let frac_at = fn(x : Double, w : Double) -> Double? {
        if w <= 0.0 {
          None
        } else {
          Some(dmin(1.0, dmax(0.0, (x - inset) / dmax(1.0, w - 2.0 * inset))))
        }
      }
      let at_x = fn(x : Double, w : Double) -> Double? {
        let d = @signals.untracked(dur)
        if d <= 0.0 {
          None
        } else {
          match frac_at(x, w) {
            Some(k) => {
              let fr = @signals.untracked(fn() { pn.frames() })
              Some(fr.snap(k * d))
            }
            None => None
          }
        }
      }
      let scrub = fn(x : Double, w : Double) {
        match at_x(x, w) {
          Some(ms) => {
            pn.act(fn() { pn.p.scrub_to(ms) })
            pn.wake()
          }
          None => ()
        }
      }
      let node : Ref[@view.View?] = Ref(None)
      let drag = fn(e : @view.Drag) {
        guard node.val is Some(on) else { return }
        match e.kind {
          Down => {
            active.set(true)
            pending.val = Some((e.x, e.w))
            dragging.val = false
            // (held a frame, as a frame drawn while it is down saw it held (Ctx::pressed): moved through the time from
            // where it went down; let go before that, a tap)
            (held_due.val)()
            held_due.val = on.at_moment(on.cause_at() + @ui.frame_period_default, fn() {
              match pending.val {
                Some((x, w)) => {
                  pending.val = None
                  dragging.val = true
                  scrub(x, w)
                }
                None => ()
              }
            })
          }
          Moved => {
            // (moved: through the time with it at once, from its first step)
            (held_due.val)()
            held_due.val = fn() {  }
            dragging.val = true
            pending.val = None
            scrub(e.x, e.w)
          }
          Up => {
            (held_due.val)()
            held_due.val = fn() {  }
            if dragging.val || pn.p.scrubbing() is Some(_) {
              let target = at_x(e.x, e.w)
              pn.act(fn() { pn.p.scrub_done(at?=target) })
              pn.wake()
            } else if pending.val is Some(_) {
              match at_x(e.x, e.w) {
                Some(ms) => {
                  pn.act(fn() { pn.p.seek_near(ms) })
                  pn.wake()
                }
                None => ()
              }
            }
            pending.val = None
            dragging.val = false
            active.set(false)
          }
          Off => {
            (held_due.val)()
            held_due.val = fn() {  }
            if pn.p.scrubbing() is Some(_) {
              pn.act(fn() { pn.p.scrub_done() })
            }
            pending.val = None
            dragging.val = false
            active.set(false)
          }
        }
      }
      @headless.slider(
        held,
        fn() { t("web-pages.drive.player.position") },
        fn() { shown() },
        min=0.0,
        max=1.0,
        step=0.0,
        // (from the keyboard or a screen reader: there at once, as a tap is)
        fn(k) {
          let d = @signals.untracked(dur)
          if d <= 0.0 {
            return
          }
          let fr = @signals.untracked(fn() { pn.frames() })
          pn.act(fn() { pn.p.seek_near(fr.snap(k * d)) })
          pn.wake()
        },
        thumb_room=2.0 * inset,
        disabled=fn() { !pn.on() || dur() <= 0.0 },
        value_text=fn(k) { clock(k * @signals.untracked(dur)) },
        drag~,
        fn(v, sl) {
          node.val = Some(v)
          v.owns(fn() { (held_due.val)() }) |> ignore
          v.reacts(at_start=false, fn() { sl.disabled() }, fn(off) {
            if off {
              (held_due.val)()
              held_due.val = fn() {  }
              if pn.p.scrubbing() is Some(_) {
                pn.act(fn() { pn.p.scrub_done() })
              }
              pending.val = None
              dragging.val = false
              active.set(false)
            }
          })
          v.reacts(
            at_start=false,
            fn() {
              if sl.disabled() {
                0.0
              } else if active.get() {
                1.0
              } else if v.pointer_within() {
                0.5
              } else {
                0.0
              }
            },
            fn(target) { swell.go(v, target, @motion.snappy_damped) },
          )
          v.height(Is(Some(h))).padding(Is((inset, 0.0, inset, 0.0))).lines_up(Is(None)) |> ignore
          let look = @glass.ScrubberLook::new(
            track_color=fn() { alpha(ink().text, media_track_share) },
            fill_color=fn() { ink().text },
            buffered=Some(fn() { part(pn.status().buffered) }),
            buffered_color=Some(fn() { alpha(ink().text, media_came_share) }),
            focus_shown=Some(fn() { sl.focus_shown() }),
            focus_color=Some(fn() { @ui.tree_theme().focus }),
            disabled=fn() { sl.disabled() },
          )
          v.box(fn(slot) {
            slot.height(Is(Some(h))).fills_across(Is(true)) |> ignore
            @glass.fluid_scrubber_look(
              slot,
              fn(_) { shown() },
              fn(n) { swell.shown(n) },
              look,
              loc~,
            )
          })
          |> ignore
          // the time where the pointer is over it, over it
          if pointed {
            let at = fn() {
              let x = v.pointer_piece(fn(x, _) { x.round().to_int() })
              if x < 0 || !pn.on() || dur() <= 0.0 || r.width() <= 0.0 || !(v.pointer_within() || v.pressed()) {
                None
              } else {
                let track = dmax(1.0, r.width() - 2.0 * inset)
                let cx = dmin(dmax(inset, r.width() - inset), dmax(inset, x.to_double()))
                Some((cx, dmin(1.0, dmax(0.0, (cx - inset) / track))))
              }
            }
            // det-ok(width-structure): shown while the pointer is over the track; the width only places it, never shows it
            v.show(at_once=true, fn() { at() is Some(_) }, fn(tip) {
              tip
              .over(Is(true))
              .width(Is(Some(desk_pointed_w)))
              .height(Is(Some(@ui.Space::S5.px())))
              .radius(By(fn() { @ui.tree_theme().corner(Md) }))
              .ground(By(fn() { @ui.tree_theme().color(VeilDeep) }))
              .lines_up(Is(Some(Middle)))
              .presses(Is(false))
              .offset(By(fn() {
                match at() {
                  Some((x, _)) => (x - desk_pointed_w / 2.0, -desk_pointed_up)
                  None => (0.0, 0.0)
                }
              }))
              |> ignore
              tip.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
              tip.box(fn(w) {
                w
                .words_runs(By(fn() {
                  match at() {
                    Some((_, k)) => [@ui.span(clock(k * dur()), mono=true, color=@ui.tree_theme().color(OnVeil))]
                    None => []
                  }
                }))
                .words_look(By(fn() {
                  let (px, line) = @ui.tree_theme().text_size(Caption)
                  { size: px, weight: 400, line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
                }))
                |> ignore
              })
              |> ignore
              tip.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
            })
          }
        },
      )
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Where it is said, in `parent` (player_parts.mbt's where_runs): in the code face, the time in the words' ink in 600, then
/// its length (paused or moved through, the time to the millisecond and which frame of how many at what rate) in the
/// quieter ink, at `size`, on one line.
#callsite(autofill(loc))
fn where_node(
  parent : @view.View,
  pn : PlayerNode,
  ink : () -> MediaInk,
  size : @ui.TextSize,
  leading? : @ui.Leading,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(w) {
    w
    .words_runs(By(fn() {
      let s = pn.status()
      let picture = !pn.audio(s)
      where_runs(pn.p, pn.frames(), s, pn.plays(), picture, ink())
    }))
    .words_look(By(fn() {
      let th = @ui.tree_theme()
      let (px, own) = th.text_size(size)
      let line = match leading {
        Some(l) => th.leading(l).unwrap_or(own)
        None => own
      }
      { size: px, weight: 400, line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
    }))
    |> ignore
  })
}

///|
/// Whether the window fills the screen (beside the system's bars: the player fills the window), followed as the window
/// is told it changes and as the player was told to.
fn PlayerNode::is_full(self : PlayerNode) -> Bool {
  self.said()
  if native_on() {
    native_full.get()
  } else {
    @ui.window_inset_now() |> ignore
    @ui.full_screen()
  }
}

///|
/// 全屏 (the old player's desk_player `full`): beside the system's bars the window filled, the bars put away; else the
/// window filling the screen, or back as it was (and as the player is left).
fn PlayerNode::full(self : PlayerNode) -> Unit {
  if native_on() {
    native_full.set(!native_full.untracked())
  } else {
    let on = @ui.full_screen()
    @hostapi.set_full_screen(!on)
    self.v.fulled = !on
  }
  self.rev.set(self.rev.untracked() + 1)
  self.wake()
}

///|
/// Back from it (the old player's desk_leave): the window as it was if it made it fill the screen, then `on_back`.
fn PlayerNode::leave(self : PlayerNode, on_back : () -> Unit) -> Unit {
  native_full.set(false)
  if self.v.fulled {
    self.v.fulled = false
    if @ui.full_screen() {
      @hostapi.set_full_screen(false)
    }
  }
  on_back()
}

///|
/// The keys (player_parts.mbt's head; the keymap's player.*, player_bindings) in `n`, where it is up (not flying): each done
/// at its key's moment.
fn PlayerNode::keys(self : PlayerNode, n : @view.View, on_back : () -> Unit, flying : () -> Bool) -> Unit {
  let pn = self
  let z = pn.v.zoom
  n.key_context("Player").key_context("Viewer") |> ignore
  let up = fn() { !@signals.untracked(flying) }
  let able = fn(action : String, f : (Double) -> Unit, can : () -> Bool) {
    n.on_action("player." + action, fn(a) {
      f(a.at)
      true
    }, can=fn() { up() && can() })
    |> ignore
  }
  let on = fn(action : String, f : (Double) -> Unit) { able(action, f, fn() { true }) }
  let playing = fn() { @signals.untracked(fn() { pn.plays() }) }
  on("play", fn(_) { pn.play_pause() })
  on("frame_back", fn(_) { pn.step(-1) })
  on("frame_on", fn(_) { pn.step(1) })
  on("back", fn(_) { if playing() { pn.jump(-pn.p.nudge_ms()) } else { pn.step(-1) } })
  on("on", fn(_) { if playing() { pn.jump(pn.p.nudge_ms()) } else { pn.step(1) } })
  on("jump_back", fn(_) { pn.jump(-pn.p.nudge_ms()) })
  on("jump_on", fn(_) { pn.jump(pn.p.nudge_ms()) })
  let loud = fn(by : Double) {
    let (volume, _) = pn.p.volume()
    pn.act(fn() { pn.p.set_volume(volume + by) })
    pn.wake()
  }
  on("louder", fn(_) { loud(player_volume_key) })
  on("quieter", fn(_) { loud(-player_volume_key) })
  on("mute", fn(_) {
    pn.act(fn() { pn.p.toggle_mute() })
    pn.wake()
  })
  let picture = fn() { @signals.untracked(fn() { !pn.audio(pn.status()) }) }
  able("full", fn(_) { pn.full() }, fn() { picture() && @ui.platform() == 0 })
  able(
    "subtitle",
    fn(_) {
      pn.act(fn() { pn.p.toggle_subtitle() })
      pn.wake()
    },
    fn() { @signals.untracked(fn() { pn.p.subtitle().0 }) },
  )
  let go_to = fn(other : () -> String?) {
    match @signals.untracked(other) {
      Some(o) => pn.go(o)
      None => ()
    }
  }
  able("next", fn(_) { go_to(fn() { pn.pl.next() }) }, fn() {
    @signals.untracked(fn() { pn.pl.next() }) is Some(_)
  })
  able("prev", fn(_) { go_to(fn() { pn.pl.prev() }) }, fn() {
    @signals.untracked(fn() { pn.pl.prev() }) is Some(_)
  })
  let zooms = fn() { picture() && z.nw > 0.0 }
  able("zoom_in", fn(at) { z.zoom_to(z.scale * player_zoom_step, z.bw / 2.0, z.bh / 2.0, true, at~) }, zooms)
  able("zoom_out", fn(at) { z.zoom_to(z.scale / player_zoom_step, z.bw / 2.0, z.bh / 2.0, true, at~) }, zooms)
  able("zoom_reset", fn(at) { z.reset(at~) }, zooms)
  able("zoom_whole", fn(at) { z.zoom_to(player_whole, z.bw / 2.0, z.bh / 2.0, true, at~) }, zooms)
  on("escape", fn(_) {
    if pn.rates.untracked() {
      pn.rates_open(false)
    } else if pn.more.untracked() {
      pn.more.set(false)
    } else if pn.listing.untracked() {
      pn.list_open(false)
    } else {
      pn.leave(on_back)
    }
  })
  // (in flight, before its keys are its own: Escape the viewer's, as it is over an image in flight)
  n.on_action("viewer.escape", fn(_) {
    on_back()
    true
  }, can=fn() { @signals.untracked(flying) })
  |> ignore
}

// ── a desktop's ─────────────────────────────────────────────────────────

///|
/// The player over the window as a desktop's layout has it, in `n` (the old player's desk_player, its folder's others
/// none): its ground (a film's black, none while it flies); its stage (a click shows or hides its controls, a double
/// one plays or pauses in its middle and jumps 15 s on its sides; the wheel with ⌘ or ⌃ zooms round the pointer, alone
/// moves what is zoomed in) and its picture; what lies in its middle; the bar along the top (beside the system's bars,
/// theirs); the controls over its foot; the pointer along the top or over the foot keeping them while it is there.
#callsite(autofill(loc))
fn desk_player_node(
  parent : @view.View,
  pn : PlayerNode,
  file : ViewerFile,
  stage : () -> (Double, Double),
  back_label : () -> String,
  on_back : () -> Unit,
  still : () -> String,
  flying : () -> Bool,
  going : () -> Bool,
  move_beside : () -> (() -> Unit)?,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(n) {
    let z = pn.v.zoom
    let picture = fn() { !pn.audio(pn.status()) }
    let ink = fn() { media_ink(picture()) }
    let room = fn() { pn.room(stage().0) }
    let panel = fn() { pn.panel(stage().0) }
    let embedded = pn.embedded
    // (embedded, the controls in the page's colours on its own ground)
    let cink = fn() { if embedded { media_pane_ink() } else { ink() } }
    n
    .over(Is(true))
    .ground(By(fn() { if flying() || embedded { no_ground } else { ink().stage } }))
    |> ignore
    // (embedded, no keys: what is typed is the page's)
    if !embedded {
      pn.keys(n, on_back, flying)
    }
    // (filling the window beside the system's bars: back leaves that first)
    n.show(at_once=true, fn() { !embedded && native_on() && native_full.get() }, fn(b) {
      b.width(Is(Some(0.0))).height(Is(Some(0.0))).takes_back(fn() { native_full.set(false) }) |> ignore
    })
    let tips_at : Ref[@view.View?] = Ref(None)
    let tips = TipLayer::new(fn() { tips_at.val })
    // the stage: a click or a finger's tap on it, a wheel over it
    n.box(fn(s) {
      s
      .over(Is(true))
      .presses(By(fn() { !flying() }))
      .cursor(Is(Some(Arrow)))
      // (embedded, the room over its controls alone, what is zoomed in seen only there, what takes the hand in from
      // its edges as the picture is)
      .margin(Is((pn.inset, pn.inset, pn.inset, 0.0)))
      .height(By(fn() { if embedded { Some(dmax(0.0, stage().1 - room().1 - pn.inset)) } else { None } }))
      .clips(Is(embedded))
      .on_drag(fn(d) {
        match d.kind {
          Down => {
            pn.down = (d.wx, d.wy)
            pn.last = (d.wx, d.wy)
            pn.moved = false
          }
          Moved => {
            let (x0, y0) = pn.down
            if (d.wx - x0).abs() > @ui.touch_slop() || (d.wy - y0).abs() > @ui.touch_slop() {
              pn.moved = true
            }
            // (zoomed in: what is zoomed moved with the pointer or finger, as the wheel moves it)
            if pn.moved && picture() && z.nw > 0.0 && z.zoomed_at(d.at) {
              z.pan(d.wx - pn.last.0, d.wy - pn.last.1, at=d.at)
            }
            pn.last = (d.wx, d.wy)
          }
          Up => if !pn.moved { pn.tapped(s, d.x, d.w) }
          Off => ()
        }
      })
      .on_wheel(fn(w) {
        if !picture() || z.nw <= 0.0 || (w.dx == 0.0 && w.dy == 0.0) {
          return
        }
        let at = w.at
        if (w.mods & (@ui.wheel_mod_ctrl | @ui.wheel_mod_cmd)) != 0 {
          let fine = (w.mods & @ui.wheel_mod_ctrl) != 0 && w.dy.abs() < player_pinch_step
          let k = @dmath.exp(-w.dy * (if fine { player_pinch_rate } else { player_wheel_rate }))
          z.zoom_to(z.scale_at(at) * k, w.x + pn.inset, w.y + pn.inset - room().0, false, at~)
        } else if z.zoomed_at(at) {
          if (w.mods & @ui.wheel_mod_shift) != 0 && w.dx == 0.0 {
            z.pan(-w.dy, 0.0, at~)
          } else {
            z.pan(-w.dx, -w.dy, at~)
          }
        }
      })
      |> ignore
      picture_node(s, pn, stage, still, flying, -pn.inset)
    })
    |> ignore
    // what lies over the picture: in what 选集 leaves of it (embedded, in the room over the controls)
    n.box(fn(mid) {
      // (what is over it fills it whole: as wide as what 选集 leaves)
      mid
      .over(Is(true))
      .width(By(fn() { Some(dmax(0.0, stage().0 - panel())) }))
      .height(By(fn() { if embedded { Some(dmax(0.0, stage().1 - room().1)) } else { None } }))
      |> ignore
      // (what a double click did said a moment in its middle, as a phone's double tap is)
      middle_node(mid, pn, file.name, fn() {
        match pn.note.get() {
          Some(note) => phone_note_words(note)
          None => ""
        }
      })
      cue_node(mid, pn, fn() { embedded || pn.wanted() }, fn() {
        if embedded {
          desk_cue_apart
        } else {
          desk_cue_over(stage().0, false)
        }
      }, fn() { 0.0 })
      ended_card_node(mid, pn, ink)
    })
    |> ignore
    // the bar along the top (beside the system's bars, an iPhone Duo's: its actions in them; embedded, the page's own
    // over it)
    n.show(at_once=true, fn() { !native_on() && !embedded }, fn(b) {
      b.over(Is(true)) |> ignore
      let bar_ink = fn() -> ViewerInk {
        if picture() {
          let k = ink()
          {
            ground: k.stage,
            ink: k.text,
            muted: k.muted,
            line: alpha(k.text, player_dark_line),
            hover: alpha(k.text, media_hot_share),
            chosen: alpha(k.text, player_dark_chosen),
          }
        } else {
          page_viewer_ink()
        }
      }
      let facts = fn() {
        let s = pn.status()
        let f = if picture() { film_facts(file.facts, s, pn.frames()) } else { "" }
        joined([pn.pl.which(), file_size(file.size), f], " · ")
      }
      viewer_bar_node(
        b,
        back_label,
        fn() { file.name },
        facts,
        fn() { file.title },
        fn() { pn.faded.get() && !pn.listing.get() },
        fn(_) { 1.0 },
        fn() { (viewer_host().room)().0 },
        fn() { stage().0 },
        bar_ink,
        fn(row, corner) {
          // what it waits on, once it has waited, beside its tools (player_wait_node)
          row.show(at_once=true, fn() { pn.waits() }, fn(r) {
            r.row(Is(true)).padding(Is((@ui.Space::S2.px(), 0.0, @ui.Space::S2.px(), 0.0))) |> ignore
            player_wait_node(r, pn, Meta, fn() { bar_ink().muted }) |> ignore
          })
          // 选集, where the folder has others
          row.show(at_once=true, fn() { pn.pl.many() }, fn(r) {
            r.row(Is(true)) |> ignore
            tool_node(
              r,
              fn() { { icon: "list", label: t("web-pages.drive.player.list"), on: pn.listing.get(), disabled: false } },
              bar_ink,
              corner,
              fn() { pn.list_open(!pn.listing.untracked()) },
              tip=tips,
            )
            |> ignore
          })
          row.show(at_once=true, fn() { move_beside() is Some(_) }, fn(r) {
            r.row(Is(true)) |> ignore
            tool_node(
              r,
              fn() { { icon: "panel-open", label: t("web-main.preview.moveBeside"), on: false, disabled: false } },
              bar_ink,
              corner,
              fn() {
                match @signals.untracked(move_beside) {
                  Some(f) => f()
                  None => ()
                }
              },
              tip=tips,
            )
            |> ignore
          })
          tool_node(
            row,
            fn() { { icon: "download", label: t("web-main.preview.download"), on: false, disabled: false } },
            bar_ink,
            corner,
            fn() { (file.save)() },
            tip=tips,
          )
          |> ignore
        },
        fn() { pn.leave(on_back) },
        tips,
      )
      |> ignore
    })
    // 选集, docked at the right under the bar
    n.show(at_once=true, fn() { panel() > 0.0 }, fn(d) {
      d.over(Is(true)) |> ignore
      play_list_docked_node(d, pn, picture)
    })
    // the controls over the foot (embedded, as far up from the stage's foot as a panel's corner is round, its keys in
    // no corner of what holds the stage), in the middle of what 选集 leaves
    n.box(fn(l) {
      l
      .over(Is(true))
      .lines_up(Is(Some(Middle)))
      .padding(By(fn() { (0.0, 0.0, panel(), if embedded { pane_corner } else { media_bar_in + (viewer_host().room)().1 }) }))
      |> ignore
      l.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      l.box(fn(bar) {
        let narrow = fn() { desk_narrow(stage().0) }
        bar
        .width(By(fn() { Some(dmin(media_bar_most, dmax(0.0, stage().0 - panel() - 2.0 * media_bar_in))) }))
        .padding(By(fn() { (media_bar_pad, if narrow() { desk_time_over } else { media_bar_top }, media_bar_pad, media_bar_foot()) }))
        .radius(By(fn() { @ui.tree_theme().corner(Xl3) }))
        .alpha(By(fn() { if going() { 0.0 } else { pn.shown.shown(bar) } }))
        .presses(By(fn() { pn.on() && !flying() && !going() }))
        |> ignore
        if embedded {
          bar.ground(Is(no_ground)) |> ignore
        } else {
          @glass.liquid_capsule_decorate(
            bar,
            glass=fn(spot) { player_surface_glass(ink, spot) },
            active=fn() { !going() && pn.shown.shown(bar) > 0.001 },
            shadow=glass_control_shadow,
            solid_edge=fn() { player_solid_edge(ink) },
            clips=false,
          )
          |> ignore
        }
        desk_controls_node(bar, pn, file, cink, narrow, tips)
      })
      |> ignore
    })
    |> ignore
    // (a mouse's pointer along the top or over the foot: the controls kept while it is there)
    n.box(fn(top) {
      // (taking nothing of the pointer: what is under it, the bar's buttons, still lit under it; whether it is within
      // it is where it is, whatever is over it, View::pointer_within)
      top.over(Is(true)).height(By(fn() { Some(room().0) })) |> ignore
      top.reacts(fn() { top.pointer_within() && pointer_rests() }, fn(near) { pn.near_top.set(near) })
    })
    |> ignore
    n.box(fn(foot) {
      foot.over(Is(true)) |> ignore
      foot.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      foot.box(fn(f) {
        f.height(By(fn() { Some(desk_controls_foot(stage().0, embedded)) })) |> ignore
        f.reacts(fn() { f.pointer_within() && pointer_rests() }, fn(near) { pn.near_foot.set(near) })
      })
      |> ignore
    })
    |> ignore
    tips_at.val = Some(n.box(fn(t) { t.over(Is(true)) |> ignore }))
  })
  |> ignore
}

///|
/// The controls in `bar` (the old player's desk_play_controls, its folder's others none): under 640 where it is said a line
/// of its own over the timeline; the timeline; 15 s back, a frame back, play, a frame on, 15 s on; where it is; the
/// sound, the speed, the frame saved, full screen (a film's, macOS's or beside the system's bars); what left the row
/// short of room (保存此帧 first, then the speed) in its ⋯.
#callsite(autofill(loc))
fn desk_controls_node(
  parent : @view.View,
  pn : PlayerNode,
  file : ViewerFile,
  ink : () -> MediaInk,
  narrow : () -> Bool,
  tips : TipLayer,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(bar) {
    let on = fn() { pn.on() }
    let picture = fn() { !pn.audio(pn.status()) }
    let ready = fn() { pn.status().duration > 0.0 }
    bar.show(at_once=true, narrow, fn(line) {
      line.min_height(Is(Some(desk_time_h))).padding(Is((@ui.Space::S2_5.px(), 0.0, 0.0, 0.0))).lines_up(Is(None)) |> ignore
      line.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      where_node(line, pn, ink, Meta, leading=L4) |> ignore
      line.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    })
    timeline_node(bar, pn, media_timeline_h(), ink, pointed=true)
    bar.box(fn(row) {
      row.row(Is(true)).min_height(Is(Some(media_row_h()))).gap(Is(@ui.Space::S3.px())).lines_up(Is(Some(Middle))) |> ignore
      row.box(fn(g) {
        g.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(keys_apart(size=media_key_d))) |> ignore
        // (the one before and the one after, where the folder has others)
        let step_to = fn(other : () -> String?) {
          fn() {
            match @signals.untracked(other) {
              Some(o) => pn.go(o)
              None => ()
            }
          }
        }
        g.show(at_once=true, fn() { pn.pl.many() }, fn(k) {
          media_key_node(k, fn() { "skip-back" }, fn() { t("web-pages.drive.player.prev") }, fn() { on() && pn.pl.prev() is Some(_) }, ink, step_to(
              fn() { pn.pl.prev() },
            ), icon_size=viewer_tool_icon, tips~)
          |> ignore
        })
        media_key_node(g, fn() { "back-15" }, fn() { t("web-pages.drive.player.back15") }, on, ink, fn() {
          pn.jump(-pn.p.nudge_ms())
        }, tips~)
        |> ignore
        g.show(at_once=true, picture, fn(k) {
          media_key_node(k, fn() { "chevron-left" }, fn() { t("android-chat.video.prev") }, fn() { on() && ready() }, ink, fn() {
            pn.step(-1)
          }, icon_size=viewer_tool_icon, tips~)
          |> ignore
        })
        media_key_node(
          g,
          fn() { if pn.plays() { "pause" } else { "play" } },
          // (its key said where Space plays it: not embedded, where what is typed is the page's)
          fn() {
            t(
              match (pn.plays(), pn.embedded) {
                (true, false) => "web-main.video.pauseKey"
                (false, false) => "web-main.video.playKey"
                (true, true) => "android-chat.video.pause"
                (false, true) => "android-chat.video.play"
              },
            )
          },
          on,
          ink,
          fn() { pn.play_pause() },
          bright=true,
          tips~,
        )
        |> ignore
        g.show(at_once=true, picture, fn(k) {
          media_key_node(k, fn() { "chevron-right" }, fn() { t("android-chat.video.next") }, fn() { on() && ready() }, ink, fn() {
            pn.step(1)
          }, icon_size=viewer_tool_icon, tips~)
          |> ignore
        })
        media_key_node(g, fn() { "forward-15" }, fn() { t("web-pages.drive.player.forward15") }, on, ink, fn() {
          pn.jump(pn.p.nudge_ms())
        }, tips~)
        |> ignore
        g.show(at_once=true, fn() { pn.pl.many() }, fn(k) {
          media_key_node(k, fn() { "skip-forward" }, fn() { t("web-pages.drive.player.next") }, fn() { on() && pn.pl.next() is Some(_) }, ink, step_to(
              fn() { pn.pl.next() },
            ), icon_size=viewer_tool_icon, tips~)
          |> ignore
        })
      })
      |> ignore
      row.box(fn(m) {
        m.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).clips(Is(true)).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
        m.show(at_once=true, fn() { !narrow() }, fn(w) {
          w.row(Is(true)) |> ignore
          where_node(w, pn, ink, Meta) |> ignore
        })
      })
      |> ignore
      row.box(fn(g) {
        g.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(keys_apart(size=media_key_d))).fits(Is(true)) |> ignore
        volume_node(g, pn, ink, tips)
        // the speed, as a figure: its menu of speeds
        let speed_slot : Ref[@view.View?] = Ref(None)
        g.box(fn(slot) {
          slot.drops(Is(player_drop_speed)) |> ignore
          speed_slot.val = Some(slot)
          speed_node(slot, pn, ink, fn() { t("web-pages.drive.player.rate") }, phone=false, tips~) |> ignore
        })
        |> ignore
        // the subtitle, where there is one beside it: its words shown or not
        let subs_on = fn() { pn.p.subtitle().1 }
        let subs_label = fn() { t(if subs_on() { "web-pages.drive.player.captionsOff" } else { "web-pages.drive.player.captionsOn" }) }
        let subs_flip = fn() {
          pn.act(fn() { pn.p.toggle_subtitle() })
          pn.wake()
        }
        let subs_slot : Ref[@view.View?] = Ref(None)
        g.show(at_once=true, fn() { pn.p.subtitle().0 }, fn(slot) {
          slot.drops(Is(player_drop_subtitle)) |> ignore
          subs_slot.val = Some(slot)
          slot.owns(fn() { subs_slot.val = None }) |> ignore
          media_key_node(slot, fn() { "captions" }, subs_label, on, ink, subs_flip, icon_size=viewer_tool_icon, lit=subs_on, tips~)
          |> ignore
        })
        // 保存此帧: paused, the frame shown at its own size
        let grabs = fn() { on() && !pn.plays() && ready() && !pn.grabbing.get() }
        let save_slot : Ref[@view.View?] = Ref(None)
        g.show(at_once=true, picture, fn(slot) {
          slot.drops(Is(player_drop_grab)) |> ignore
          save_slot.val = Some(slot)
          media_key_node(slot, fn() { "camera" }, fn() { t("android-chat.video.saveFrame") }, grabs, ink, fn() {
            pn.grab(slot)
          }, icon_size=viewer_tool_icon, tips~)
          |> ignore
        })
        // 全屏: the window filling the screen (macOS's), back as it was; beside the system's bars, the window filled
        g.show(at_once=true, fn() { picture() && !pn.embedded && (@ui.platform() == 0 || native_on()) }, fn(k) {
          media_key_node(
            k,
            fn() { if pn.is_full() { "shrink" } else { "expand" } },
            fn() { t(if pn.is_full() { "web-pages.drive.player.unfull" } else { "web-pages.drive.player.full" }) },
            on,
            ink,
            fn() { pn.full() },
            icon_size=viewer_tool_icon,
            tips~,
          )
          |> ignore
        })
        // what left the row, in its ⋯ (there only while something did), opened over it as the speeds are
        g.box(fn(slot) {
          slot.drops(Is(-1)) |> ignore
          more_node(
            slot,
            pn,
            ink,
            on,
            grabs,
            fn() {
              match save_slot.val {
                Some(s) => s.left_out()
                None => false
              }
            },
            fn() {
              match speed_slot.val {
                Some(s) => s.left_out()
                None => false
              }
            },
            fn() {
              match subs_slot.val {
                Some(s) => s.left_out()
                None => false
              }
            },
            subs_label,
            subs_flip,
            tips,
          )
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    ignore(file)
  })
  |> ignore
}

///|
/// The ⋯ in `slot` (the old player's desk_play_controls' more): what left the row short of room, in its menu over it
/// (保存此帧 where `grab_out` says it left, then the speeds under their name, the one it plays at chosen, where
/// `speed_out` says the speed left).
fn more_node(
  slot : @view.View,
  pn : PlayerNode,
  ink : () -> MediaInk,
  on : () -> Bool,
  grabs : () -> Bool,
  grab_out : () -> Bool,
  speed_out : () -> Bool,
  subs_out : () -> Bool,
  subs_label : () -> String,
  subs_flip : () -> Unit,
  tips : TipLayer,
) -> Unit {
  let k = media_key_node(slot, fn() { "more" }, fn() { t("web-main.menu.more") }, on, ink, fn() {
    pn.more.set(!pn.more.untracked())
    pn.wake()
  }, icon_size=viewer_tool_icon, lit=fn() { pn.more.get() }, tips~)
  let holder = slot.tree.root().box(fn(h) { h.over(Is(true)) |> ignore }).lives_with(k)
  holder.show(at_once=true, fn() { pn.more.get() }, fn(m) {
    m.over(Is(true)).opened_by(@view.ByNode(k.id())) |> ignore
    menu_node(
      m,
      fn() { true },
      fn(_) { k },
      fn() {
        pn.said()
        let gone : Array[MenuItem?] = []
        if subs_out() {
          gone.push(Some(more_line(subs_label(), "captions", disabled=!on(), on_press=subs_flip)))
        }
        if grab_out() {
          gone.push(Some(more_line(t("android-chat.video.saveFrame"), "camera", disabled=!grabs(), on_press=fn() { pn.grab(k) })))
        }
        if speed_out() {
          if !gone.is_empty() {
            gone.push(None)
          }
          gone.push(Some(menu_item_of(t("web-pages.drive.player.rate"), fn() {  }, heading=true)))
          for sp in player_speeds {
            gone.push(
              Some(
                menu_item_of(speed_label(sp), fn() {
                    pn.act(fn() { pn.p.set_speed(sp) })
                    pn.wake()
                  }, chosen=sp == pn.p.speed(), disabled=!on()),
              ),
            )
          }
        }
        gone
      },
      "",
      End,
      @ui.Space::S1_5.px(),
      false,
      false,
      fn(item) {
        pn.more.set(false)
        (item.select)()
      },
      fn() { pn.more.set(false) },
      side=Top,
    )
  })
  k.owns(fn() { pn.more.set(false) }) |> ignore
}

///|
/// The sound in `parent` (the old player's desk_volume): a key that mutes, and beside it a line 72 wide to press or drag
/// along (in twentieths), how loud on it in the words, a 10 head.
#callsite(autofill(loc))
fn volume_node(parent : @view.View, pn : PlayerNode, ink : () -> MediaInk, tips : TipLayer, loc~ : SourceLoc) -> Unit {
  let silent = fn() {
    pn.said()
    let (volume, muted) = pn.p.volume()
    muted || volume == 0.0
  }
  let shown = fn() {
    pn.said()
    let (volume, muted) = pn.p.volume()
    if muted {
      0.0
    } else {
      volume
    }
  }
  // (a finger's: only the key, the sound's own buttons beside it)
  let slider = !(native_input() is Finger)
  parent.box(made_for=loc, fn(r) {
    r
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .gap(Is(keys_apart(size=media_key_d)))
    .padding(Is((0.0, 0.0, if slider { @ui.Space::S1_5.px() } else { 0.0 }, 0.0)))
    |> ignore
    media_key_node(
      r,
      fn() { if silent() { "volume-x" } else { "volume" } },
      fn() { t(if silent() { "web-pages.drive.player.unmute" } else { "web-pages.drive.player.mute" }) },
      fn() { pn.on() },
      ink,
      fn() {
        pn.act(fn() { pn.p.toggle_mute() })
        pn.wake()
      },
      icon_size=viewer_tool_icon,
      tips~,
    )
    |> ignore
    if slider {
      let step = 1.0 / desk_volume_steps
      let swell = @motion.NodeWay::new(0.0)
      let active = @signals.signal(false)
      let last_vol : Ref[Int] = Ref(-1)
      let set_at = fn(d : @view.Drag) {
        if d.w > 0.0 {
          let frac = dmin(1.0, dmax(0.0, d.x / d.w))
          let pct = (frac * 100.0).round().to_int()
          let prev = if last_vol.val >= 0 {
            last_vol.val
          } else {
            (@signals.untracked(shown) * 100.0).round().to_int()
          }
          if pct != prev {
            last_vol.val = pct
            pn.act(fn() { pn.p.set_volume(pct.to_double() / 100.0) })
            pn.wake()
          }
        }
      }
      let drag = fn(d : @view.Drag) {
        match d.kind {
          Down => {
            active.set(true)
            last_vol.val = (@signals.untracked(shown) * 100.0).round().to_int()
            set_at(d)
          }
          Moved => set_at(d)
          Up => {
            set_at(d)
            active.set(false)
            last_vol.val = -1
          }
          Off => {
            active.set(false)
            last_vol.val = -1
          }
        }
      }
      @headless.slider(
        r,
        fn() { t("web-pages.drive.player.volume") },
        shown,
        min=0.0,
        max=1.0,
        step~,
        fn(to) {
          pn.act(fn() { pn.p.set_volume(to) })
          pn.wake()
        },
        thumb_room=0.0,
        disabled=fn() { !pn.on() },
        drag~,
        fn(v, sl) {
          v.reacts(at_start=false, fn() { sl.disabled() }, fn(off) {
            if off {
              active.set(false)
              last_vol.val = -1
            }
          })
          v.reacts(
            at_start=false,
            fn() {
              if sl.disabled() {
                0.0
              } else if active.get() {
                1.0
              } else if v.pointer_within() {
                0.5
              } else {
                0.0
              }
            },
            fn(target) { swell.go(v, target, @motion.snappy_damped) },
          )
          v.width(Is(Some(desk_volume_w))).height(Is(Some(media_timeline_h()))).lies_along(Is(Middle)) |> ignore
          let look = @glass.ScrubberLook::new(
            track_color=fn() { alpha(ink().text, media_track_share) },
            fill_color=fn() { ink().text },
            focus_shown=Some(fn() { sl.focus_shown() }),
            focus_color=Some(fn() { @ui.tree_theme().focus }),
            disabled=fn() { sl.disabled() },
          )
          @glass.fluid_scrubber_look(
            v,
            fn(_) { shown() },
            fn(n) { swell.shown(n) },
            look,
            loc~,
          )
        },
      )
      |> ignore
    }
  })
  |> ignore
}

// ── a phone's ───────────────────────────────────────────────────────────

///|
/// The player as a phone's page has it, in `n` (the old player's phone_player, its folder's others none): its ground; its
/// stage, what a finger does on it (phone_fingers) and its picture, taken down with a finger; what lies over it (a
/// song's cover, what it waits on, a double tap's note, a held finger's 2×, where a finger along it has gone); the bar
/// at the top (back, its name, 下载: beside the system's bars, theirs); the controls at the foot. Its bar and controls
/// away while a finger takes it down, once it was taken down, and as it goes.
#callsite(autofill(loc))
fn phone_player_node(
  parent : @view.View,
  pn : PlayerNode,
  file : ViewerFile,
  stage : () -> (Double, Double),
  on_back : () -> Unit,
  still : () -> String,
  flying : () -> Bool,
  going : () -> Bool,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(n) {
    let picture = fn() { !pn.audio(pn.status()) }
    let ink = fn() { media_ink(picture()) }
    let back = fn() {
      if pn.p.is_sideways() {
        pn.act(fn() { pn.p.upright() })
      } else {
        on_back()
      }
    }
    let embedded = pn.embedded
    // (embedded, the controls under the room over them, on the page's own ground in its colours, always there)
    let cink = fn() { if embedded { media_pane_ink() } else { ink() } }
    let foot = fn() { if embedded { phone_embedded_foot() } else { 0.0 } }
    let room_h = fn() { if embedded { Some(dmax(0.0, stage().1 - foot())) } else { None } }
    // (embedded, what takes the hand in from the stage's edges as its picture is)
    let hand_h = fn() { room_h().map(fn(h) { dmax(0.0, h - pn.inset) }) }
    n
    .over(Is(true))
    .ground(By(fn() { if flying() || embedded { no_ground } else { ink().stage } }))
    |> ignore
    // (embedded, no keys: what is typed is the page's)
    if !embedded {
      pn.keys(n, on_back, flying)
    }
    // (turned sideways: back turns it upright first)
    n.show(at_once=true, fn() { !embedded && pn.p.is_sideways() }, fn(b) {
      b.width(Is(Some(0.0))).height(Is(Some(0.0))).takes_back(fn() { pn.act(fn() { pn.p.upright() }) }) |> ignore
    })
    n.box(fn(s) {
      s
      .over(Is(true))
      .presses(By(fn() { !flying() }))
      .cursor(Is(Some(Arrow)))
      .margin(Is((pn.inset, pn.inset, pn.inset, 0.0)))
      .height(By(hand_h))
      .clips(Is(embedded))
      .on_drag(fn(d) { phone_fingers(s, pn, d, stage, back) }, fingers=2, whole=true)
      |> ignore
      picture_node(s, pn, stage, still, flying, -pn.inset)
    })
    |> ignore
    let pill = fn() {
      let s = pn.status()
      match (pn.note.get(), pn.held.get() >= 0.0, pn.drag.get()) {
        (_, _, AlongTime) => {
          pn.said()
          clock(pn.p.scrubbing().unwrap_or(pn.drag_to.get())) + " / " + (if s.duration > 0.0 { clock(s.duration) } else { "--:--" })
        }
        (_, true, _) => t("web-pages.drive.player.held")
        (Some(note), _, _) => phone_note_words(note)
        _ => ""
      }
    }
    // what lies over the picture (embedded, in the room over the controls)
    n.box(fn(mid) {
      mid.over(Is(true)).height(By(room_h)) |> ignore
      middle_node(mid, pn, file.name, pill)
      cue_node(mid, pn, fn() { embedded || pn.wanted() }, fn() { if embedded { desk_cue_apart } else { phone_cue_over() } }, fn() {
        0.0
      })
      ended_card_node(mid, pn, ink)
    })
    |> ignore
    // (closed, drawn as it leaves, or dragged down to close: its controls away at once, none of them seen, pressed or
    // read out (View::hides) from that moment, not when it is gone)
    let away = fn() { pn.drag.get() == DownClose || pn.taken_down.get() || going() }
    let shown = fn(node : @view.View) { if away() { 0.0 } else { pn.shown.shown(node) } }
    let live = fn() { pn.on() && pn.drag.get() != DownClose && !pn.taken_down.get() && !flying() && !going() }
    let tips_at : Ref[@view.View?] = Ref(None)
    let tips = TipLayer::new(fn() { tips_at.val })
    // the bar at the top: back, the name, which of the folder's it is, 选集, 下载 (beside the system's bars, an iPhone
    // Duo's: its actions in them; embedded, the page's own over it)
    n.show(at_once=true, fn() { !native_on() && !embedded }, fn(top) {
      top.over(Is(true)) |> ignore
      top.box(fn(r) { r.height(By(fn() { Some((viewer_host().room)().0) })) |> ignore }) |> ignore
      top.box(fn(place) {
        place
        .padding(By(fn() {
          let (l, r) = sides_clear_of(@ui.Space::S2.px())
          (l, @ui.Space::S1_5.px(), r, @ui.Space::S1_5.px())
        }))
        .alpha(By(fn() { shown(place) }))
        .hides(By(away))
        |> ignore
        place.box(fn(h) {
          h
          .row(Is(true))
          .height(Is(Some(@ui.Space::S12.px())))
          .padding(Is((@ui.Space::S1.px(), 0.0, @ui.Space::S1.px(), 0.0)))
          .gap(Is(@ui.Space::S1.px()))
          .radius(Is(@ui.Space::S12.px() / 2.0))
          .lines_up(Is(Some(Middle)))
          .presses(By(live))
          |> ignore
          @glass.liquid_capsule_decorate(
            h,
            glass=fn(spot) { player_surface_glass(ink, spot) },
            active=fn() { !away() && shown(place) > 0.001 },
            shadow=glass_control_shadow,
            solid_edge=fn() { player_solid_edge(ink) },
          )
          |> ignore
          media_key_node(h, fn() { "chevron-left" }, fn() { t("common.back") }, live, ink, back, side=phone_key_side, faint=false, ripples=true)
          |> ignore
          h.box(fn(nm) {
            nm.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).clips(Is(true)).padding(Is((@ui.Space::S1.px(), 0.0, @ui.Space::S1.px(), 0.0))) |> ignore
            said_words_node(nm, fn() { file.name }, Ui, fn() { ink().text }, weight=600) |> ignore
          })
          |> ignore
          // what it waits on, once it has waited, after its name (player_wait_node)
          h.show(at_once=true, fn() { pn.waits() }, fn(w) {
            w.row(Is(true)).padding(Is((0.0, 0.0, @ui.Space::S1.px(), 0.0))) |> ignore
            player_wait_node(w, pn, Meta, fn() { ink().muted }) |> ignore
          })
          h.show(at_once=true, fn() { pn.pl.which() != "" }, fn(w) {
            w.row(Is(true)) |> ignore
            said_words_node(w, fn() { pn.pl.which() }, Meta, fn() { ink().muted }) |> ignore
          })
          h.show(at_once=true, fn() { pn.pl.many() }, fn(k) {
            k.row(Is(true)) |> ignore
            media_key_node(
              k,
              fn() { "list" },
              fn() { t("web-pages.drive.player.list") },
              live,
              ink,
              fn() { pn.list_open(true) },
              side=phone_key_side,
              faint=false,
              ripples=true,
              lit=fn() { pn.listing.get() },
            )
            |> ignore
          })
          // 下载, as every file opened has it
          media_key_node(
            h,
            fn() { "download" },
            fn() { t("web-main.preview.download") },
            live,
            ink,
            fn() { (file.save)() },
            side=phone_key_side,
            faint=false,
            ripples=true,
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    // the controls at the foot
    n.box(fn(l) {
      l.over(Is(true)).lines_up(Is(Some(Middle))) |> ignore
      l.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      l.box(fn(place) {
        place
        .padding(By(fn() {
          if embedded {
            // (clear of the corners of what holds the stage, none of the window's bars beside it)
            (@ui.Space::S2.px(), @ui.Space::S2.px(), @ui.Space::S2.px(), pane_corner)
          } else {
            let (lp, rp) = sides_clear_of(@ui.Space::S2.px())
            (lp, @ui.Space::S2.px(), rp, @ui.Space::S2.px())
          }
        }))
        .fills_across(Is(true))
        .lines_up(Is(Some(Middle)))
        .alpha(By(fn() { shown(place) }))
        .hides(By(away))
        |> ignore
        place.box(fn(c) {
          c
          .width_share(Is(1.0))
          .max_width(Is(Some(phone_controls_most)))
          .padding(Is((phone_keys_in, @ui.Space::S2.px(), phone_keys_in, phone_controls_foot())))
          .radius(By(fn() { @ui.tree_theme().corner(Xl3) }))
          .presses(By(live))
          // (a finger down anywhere on them keeps them a while)
          .on_drag(fn(d) { if d.kind == Down { pn.wake() } })
          |> ignore
          if embedded {
            c.ground(Is(no_ground)) |> ignore
          } else {
            @glass.liquid_capsule_decorate(
              c,
              glass=fn(spot) { player_surface_glass(ink, spot) },
              active=fn() { !away() && shown(place) > 0.001 },
              shadow=glass_control_shadow,
              solid_edge=fn() { player_solid_edge(ink) },
            )
            |> ignore
          }
          phone_controls_node(c, pn, cink, live)
        })
        |> ignore
      })
      |> ignore
      l.box(fn(r) { r.height(By(fn() { Some(if embedded { 0.0 } else { (viewer_host().room)().1 }) })) |> ignore }) |> ignore
    })
    |> ignore
    tips_at.val = Some(n.box(fn(t) { t.over(Is(true)) |> ignore }))
    ignore(tips)
  })
  |> ignore
}

///|
/// `more` in from either side, and past what the system has at the window's sides while the app has turned the device
/// sideways (sides_clear's, as numbers).
fn sides_clear_of(more : Double) -> (Double, Double) {
  let b = if @hostapi.turned_sideways() { @ui.system_bars() } else { { top: 0.0, bottom: 0.0, left: 0.0, right: 0.0 } }
  (more + dmax(0.0, b.left), more + dmax(0.0, b.right))
}

///|
/// A phone's controls in `c` (the old player's phone_controls, its folder's others none): where it is over the timeline;
/// 15 s back or (paused, a film) a frame back, play, 15 s on or a frame on; the speed, the frame saved (paused), fit or
/// fill (sideways), sideways (a film's). Taking presses while `on()`.
#callsite(autofill(loc))
fn phone_controls_node(parent : @view.View, pn : PlayerNode, ink : () -> MediaInk, on : () -> Bool, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(c) {
    let picture = fn() { !pn.audio(pn.status()) }
    let inspect = fn() { picture() && !pn.plays() && pn.status().duration > 0.0 }
    // (embedded, a line as tall as a desktop's said over its timeline, so the room over them is known:
    // phone_embedded_foot)
    c.box(fn(w) {
      w.padding(Is((@ui.Space::S2_5.px(), 0.0, 0.0, 0.0))).row(Is(true)) |> ignore
      if pn.embedded {
        w.min_height(Is(Some(desk_time_h))).lines_up(Is(Some(Middle))) |> ignore
        where_node(w, pn, ink, Meta, leading=L4) |> ignore
      } else {
        where_node(w, pn, ink, Meta) |> ignore
      }
    })
    |> ignore
    timeline_node(c, pn, phone_timeline_h(), ink, pointed=false)
    c.box(fn(row) {
      row.row(Is(true)).min_height(Is(Some(phone_row_h()))).lines_up(Is(Some(Middle))).gap(Is(keys_apart(size=phone_key_side))).fits(Is(true)) |> ignore
      let key = fn(parent : @view.View, icon : () -> String, label : () -> String, press : () -> Unit, lit : () -> Bool) {
        media_key_node(parent, icon, label, on, ink, press, side=phone_key_side, faint=false, ripples=true, lit~) |> ignore
      }
      let off = fn() { false }
      // (the one before and the one after, where the folder has others: the first to leave short of room)
      let step = fn(slot : @view.View, icon : String, label : String, other : () -> String?) {
        slot.drops(Is(phone_drop_steps)) |> ignore
        media_key_node(slot, fn() { icon }, fn() { t(label) }, fn() { on() && other() is Some(_) }, ink, fn() {
          match @signals.untracked(other) {
            Some(o) => pn.go(o)
            None => ()
          }
        }, side=phone_key_side, faint=false, ripples=true)
        |> ignore
      }
      row.show(at_once=true, fn() { pn.pl.many() }, fn(slot) {
        step(slot, "skip-back", "android-misc.drive.player.prev", fn() { pn.pl.prev() })
      })
      key(row, fn() { if inspect() { "chevron-left" } else { "back-15" } }, fn() {
        t(if inspect() { "android-chat.video.prev" } else { "android-misc.drive.player.back15" })
      }, fn() { if @signals.untracked(inspect) { pn.step(-1) } else { pn.jump(-pn.p.nudge_ms()) } }, off)
      key(row, fn() { if pn.plays() { "pause" } else { "play" } }, fn() {
        t(if pn.plays() { "android-chat.video.pause" } else { "android-chat.video.play" })
      }, fn() { pn.play_pause() }, off)
      key(row, fn() { if inspect() { "chevron-right" } else { "forward-15" } }, fn() {
        t(if inspect() { "android-chat.video.next" } else { "android-misc.drive.player.forward15" })
      }, fn() { if @signals.untracked(inspect) { pn.step(1) } else { pn.jump(pn.p.nudge_ms()) } }, off)
      row.show(at_once=true, fn() { pn.pl.many() }, fn(slot) {
        step(slot, "skip-forward", "android-misc.drive.player.next", fn() { pn.pl.next() })
      })
      row.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      speed_node(row, pn, ink, fn() { t("android-misc.drive.player.speed") }, phone=true) |> ignore
      // the subtitle, where there is one beside it: its words shown or not
      row.show(at_once=true, fn() { pn.p.subtitle().0 }, fn(slot) {
        key(slot, fn() { "captions" }, fn() {
          t(if pn.p.subtitle().1 { "android-misc.drive.player.subtitlesOff" } else { "android-misc.drive.player.subtitlesOn" })
        }, fn() {
          pn.act(fn() { pn.p.toggle_subtitle() })
          pn.wake()
        }, fn() { pn.p.subtitle().1 })
      })
      row.show(at_once=true, inspect, fn(slot) {
        slot.drops(Is(phone_drop_grab)) |> ignore
        media_key_node(
          slot,
          fn() { "camera" },
          fn() { t("android-chat.video.saveFrame") },
          fn() { on() && !pn.grabbing.get() },
          ink,
          fn() { pn.grab(slot) },
          side=phone_key_side,
          faint=false,
          ripples=true,
        )
        |> ignore
      })
      // turned sideways the picture can fill the screen (cropped) or fit in it
      row.show(at_once=true, fn() { picture() && !pn.embedded && pn.p.is_sideways() }, fn(slot) {
        key(slot, fn() {
          pn.said()
          if pn.p.fills() { "shrink" } else { "expand" }
        }, fn() {
          pn.said()
          t(if pn.p.fills() { "android-misc.drive.player.fit" } else { "android-misc.drive.player.fill" })
        }, fn() {
          pn.act(fn() { pn.p.toggle_fill() })
          pn.wake()
        }, fn() {
          pn.said()
          pn.p.fills()
        })
      })
      row.show(at_once=true, fn() { picture() && !pn.embedded }, fn(slot) {
        key(slot, fn() { "landscape" }, fn() {
          t(if pn.p.is_sideways() { "android-misc.drive.player.unfull" } else { "android-misc.drive.player.full" })
        }, fn() {
          pn.act(fn() { pn.p.toggle_sideways() })
          // (turned: the layout it had held from this moment, the window still as it was, never the one its turned
          // window would have once the system turns it (a phone's turned wide as a tablet: tokens.mbt's layout))
          ignore(layout(slot.window_w()))
          pn.wake()
        }, fn() { pn.p.is_sideways() })
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// A finger's event on a phone's stage `s` (the old player's phone_gestures, at its own moment): two zoom it round the point
/// between them; one along it moves through the time (the picture going with it frame by frame, paused meanwhile:
/// Media::scrub_to), down it takes the picture down and closes it past player_close_dy (`back`: sideways, upright
/// first), held still it plays at 2× until let go; zoomed in, one moves what is shown (let go moving, it goes on,
/// slowing). A tap or a double tap is the player's own (PlayerNode::tapped), not when the finger did any of these, nor
/// when it came down on the picture flinging (stopping it).
fn phone_fingers(
  s : @view.View,
  pn : PlayerNode,
  d : @view.Drag,
  stage : () -> (Double, Double),
  back : () -> Unit,
) -> Unit {
  let z = pn.v.zoom
  let at = d.at
  let (x, y) = (d.wx, d.wy)
  let picture = @signals.untracked(fn() { !pn.audio(pn.status()) })
  let pinch_now = fn() {
    let pts = pn.fingers.values().to_array()
    let (x1, y1) = pts[0]
    let (x2, y2) = pts[1]
    ((x1 + x2) / 2.0, (y1 + y2) / 2.0, ((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2)).sqrt())
  }
  let (ox, oy) = (d.x - d.wx + pn.inset, d.y - d.wy + pn.inset)
  match d.kind {
    Down => {
      pn.fingers[d.finger] = (x, y)
      if pn.fingers.length() == 1 {
        // a finger come down on it flinging stops it there (caught: no tap)
        pn.caught = z.stop_fling(at~)
        pn.down = (x, y)
        pn.last = (x, y)
        pn.moved = false
        pn.long = false
        pn.speed.reset()
        pn.speed.add(at, x, y)
        // held still: 2× while it is held (playing)
        (pn.hold_end)()
        pn.hold_end = s.at_moment(at + @ui.long_press_ms, fn() {
          pn.long = true
          let playing = @signals.untracked(fn() { pn.status().playing })
          if !pn.moved && !pn.pinched && pn.held.untracked() < 0.0 && playing && pn.fingers.length() == 1 {
            pn.held.set(pn.p.speed())
            pn.act(fn() { pn.p.set_speed(player_held_speed) })
          }
        })
      } else if picture && z.nw > 0.0 {
        (pn.hold_end)()
        pn.pinch = pinch_now()
        pn.pinched = true
        pn.drag.set(MoveZoom)
      }
    }
    Moved => {
      pn.fingers[d.finger] = (x, y)
      if pn.fingers.length() >= 2 {
        if picture && z.nw > 0.0 {
          let (cx, cy, dist) = pinch_now()
          let (was_x, was_y, was_d) = (pn.pinch.0, pn.pinch.1, pn.pinch.2)
          if was_d > 0.0 && dist > 0.0 {
            z.transform(cx + ox, cy + oy, dist / was_d, cx - was_x, cy - was_y, at~)
          }
          pn.pinch = (cx, cy, dist)
        }
        return
      }
      let (dx0, dy0) = (x - pn.down.0, y - pn.down.1)
      // (a finger's own small shake no drag: past the system's touch slop either way, as a list takes it)
      if !pn.moved && (dx0.abs() > @ui.touch_slop() || dy0.abs() > @ui.touch_slop()) {
        pn.moved = true
        (pn.hold_end)()
      }
      pn.speed.add(at, x, y)
      let s0 = @signals.untracked(fn() { pn.status() })
      if pn.drag.untracked() == NoDrag && pn.moved && !pn.pinched {
        pn.drag.set(
          if z.zoomed_at(at) {
            MoveZoom
          } else if dx0.abs() > dy0.abs() && s0.duration > 0.0 {
            AlongTime
          } else if dy0 > 0.0 && !pn.embedded {
            DownClose
          } else {
            MoveZoom
          },
        )
        pn.drag_from = s0.position
        pn.drag_to.set(s0.position)
        pn.wake()
      }
      match pn.drag.untracked() {
        AlongTime => {
          // a screen's width is as much as player_drag_span of it (all of it, a short one)
          let span = dmin(s0.duration, player_drag_span)
          let to = dmax(0.0, dmin(s0.duration, pn.drag_from + dx0 / dmax(1.0, stage().0) * span))
          pn.drag_to.set(to)
          let fr = @signals.untracked(fn() { pn.frames() })
          pn.act(fn() { pn.p.scrub_to(fr.snap(to)) })
        }
        DownClose => pn.drag_dy.set(dmax(0.0, dy0))
        MoveZoom =>
          if !pn.pinched {
            z.pan(x - pn.last.0, y - pn.last.1, at~)
          }
        NoDrag => ()
      }
      pn.last = (x, y)
    }
    Up | Off => {
      pn.fingers.remove(d.finger)
      if !pn.fingers.is_empty() {
        // one of two let go: the pinch over, the one left followed from where it is next
        pn.pinch = (0.0, 0.0, 0.0)
        pn.last = pn.fingers.values().to_array()[0]
        return
      }
      (pn.hold_end)()
      pn.hold_end = fn() {  }
      let was = pn.drag.untracked()
      let held = pn.held.untracked() >= 0.0
      if d.kind == Up {
        pn.speed.up(at, x, y)
      }
      match was {
        AlongTime => pn.act(fn() { pn.p.scrub_done() })
        DownClose =>
          if d.kind == Up && pn.drag_dy.untracked() > player_close_dy {
            // going (not turned upright first): its picture stays where the finger left it, to go from there
            pn.taken_down.set(!pn.p.is_sideways())
            back()
          }
        // let go moving: on at the finger's speed, slowing, to a stop or its edge
        MoveZoom =>
          if !pn.pinched && d.kind == Up {
            let (vx, vy) = pn.speed.get_at(at)
            z.fling(vx, vy, at~)
          }
        NoDrag => ()
      }
      if held {
        pn.act(fn() { pn.p.set_speed(pn.held.untracked()) })
        pn.held.set(-1.0)
      }
      pn.drag.set(NoDrag)
      if !pn.taken_down.untracked() {
        pn.drag_dy.set(0.0)
      }
      // pinched smaller than fitted and let go: back to fitted, as an image is
      let pinched = pn.pinched
      if pinched && z.scale_at(at) < z.fit() {
        z.reset(at~)
      }
      pn.pinched = false
      // a tap or a double tap (none of the above)
      if d.kind == Up && was == NoDrag && !held && !pn.long && !pn.caught && !pinched {
        pn.tapped(s, d.x, d.w)
      }
    }
  }
}

///|
/// How big a still is decoded for the stage (sfbase's stage_px).
let player_px : Int = 4096

