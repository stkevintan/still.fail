// A tip as nodes of the window's tree (tip's, kit's tooltip's way): what a control is for, in a few words, shown by it
// as the mouse's pointer rests on it a while (at once where another tip of the same layer went a moment before), and
// while the keyboard's focus shows on it; shut by a press on it till the hand and the focus have left it; gone as either
// leaves, as its control takes input no more (said to take no press, it or what holds it; leaving; under a modal layer:
// View::takes_input, told at that cause), or goes. Each of these at its cause's moment: the rest's end a moment of the
// timeline, its control's state as it is then; drawn beside its control by where that is as the tree is placed
// (View::beside), in its layer (over all of the window), in the look tip_look draws (small words on the primary ink),
// set as the window's theme says as that changes.

///|
fn init {
  // (the window's tooltip slot, headless's, which knows no ui: forgotten as the app begins anew)
  @ui.on_reset(@headless.tip_slot_reset)
}

///|
/// Where a window's tips are drawn (a node over all of it, as it is given when a tip is first shown) and when the last
/// of them went (another shown within tooltip_skip_ms of it at once: kit's tip_closed): one for the window's tree, made
/// and let go with what holds it. `hands`: its tips handing their ground on, the next shown at once going from where
/// the one before was drawn (@motion.Handoff, within tooltip_skip_ms of its going).
pub struct TipLayer {
  layer : () -> @view.View?
  mut went_at : Double
  priv hands : @motion.Handoff
  priv active : @signals.Signal[@headless.TipOwner?]
  priv group : @headless.TooltipGroup[@headless.TipOwner]
}

///|
/// The tips' layer of a window, drawn in what `layer` gives (the node it is first shown in).
pub fn TipLayer::new(layer : () -> @view.View?) -> TipLayer {
  let active : @signals.Signal[@headless.TipOwner?] = @signals.signal(None, same=fn(a, b) { a == b })
  let group = @headless.TooltipGroup::new(
    fn() { active.get() },
    fn(k) { active.set(k) },
    open_delay_ms=tip_delay_ms,
    warmup_ms=@headless.tooltip_skip_ms,
  )
  { layer, went_at: -1.0e18, hands: @motion.Handoff::new(within=@headless.tooltip_skip_ms), active, group }
}

///|
/// What a tip can take over from (@motion.HandPart's tag): one on the same side of its control; one by the pointer
/// (`at_pointer`) none, nor is it taken over from.
fn tip_hand_tag(side : @view.Side, at_pointer : Bool) -> Int {
  if at_pointer {
    return -1
  }
  match side {
    Top => 0
    Right => 1
    Bottom => 2
    Left => 3
  }
}

///|
/// How a tip comes in (kit's tip_in: faded in, eased out, 120 ms); it goes symmetrically as pure fade (eased to leave).
let tip_in_ms : Double = 120.0

///|
/// A tip saying `label` (as it changes; none said: no tip) of the control `anchor`, on its `side`, in `tips` (its
/// layer over all of the window). What shows it and what shuts it as the file's head says. `delay`: how long the
/// pointer rests on it before it shows; `skip`: shown at once where another of the layer went a moment before; `gap`:
/// how far from what it is beside; `at_pointer`: beside the pointer as it moves along the control, its middle level with
/// it (a tall thin thing's: an edge, usePointerTip), not the control's middle. `within`: shown by the pointer within
/// `anchor` as it is placed (View::pointer_within), over what it holds as over itself (a bar's name, what is pressed
/// there the bar's), not by its being pointed at; without it, by `anchor` pointed at (View::pointed), whatever it takes
/// of the hand, a control or none (a mark, a status). `repeats`: it says words the control shows itself (a file's
/// name on its card), whole: shown only where they show cut short there as it would show (View::words_cut_now: any words
/// in `anchor`, as the old tip's Ctx::shows_cut), none where they show whole; once shown, it goes as any does, not as
/// they come to show whole. `shortcut`: the action that does what the control does, its keys said after the words
/// (tip's: shortcut_keys, as the app says them; none while no keyboard is at hand). `pressed`: whether what a press on
/// it lands on is held (none: `anchor` itself), where that is a control `within` it (an update's key in what holds its
/// tip): its press shuts it as one on `anchor` does.
pub fn tip_node(
  tips : TipLayer,
  anchor : @view.View,
  label : () -> String,
  side? : @view.Side = Bottom,
  delay? : Double = tip_delay_ms,
  skip? : Bool = true,
  gap? : Double = tip_gap,
  at_pointer? : Bool = false,
  within? : Bool = false,
  repeats? : Bool = false,
  shortcut? : String = "",
  pressed? : () -> Bool,
) -> TipHand {
  if within {
    anchor.points(Is(true)) |> ignore
  }
  let open : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })
  // (a finger held on its control: Held while it is down, Lifted a while once it is let go, till then or the next
  // press, wherever it lands; Free otherwise)
  let hand : @signals.Signal[TipHeld] = @signals.signal(Free, same=fn(a, b) { a == b })
  let lifted_end : Ref[() -> Unit] = Ref(fn() {  })
  // (how it comes in, this time it is shown: from when, from how far in it was (shown again as it went: as far as it
  // had gone), whether it is in whole yet, and the moment that says so: this showing's own, let go as it goes)
  let fade = TipFade::new()
  let anchor_id = anchor.id()
  let owner = @headless.tip_node_owner()
  // (its ground handed on among its layer's tips: seen while its slot is its own and some of it is in)
  let glide = tips.hands.part(
    fn(t) {
      if @signals.untracked(fn() { @headless.tip_owns(owner) }) {
        fade.at(t)
      } else {
        0.0
      }
    },
    tag=tip_hand_tag(side, at_pointer),
  )
  // (pointer hover / warmup / repeats / takes_input / focus driven by @headless.TooltipGroup)
  let own_active : @signals.Signal[@headless.TipOwner?] = @signals.signal(None, same=fn(a, b) { a == b })
  let (group, group_slot) = if delay == tip_delay_ms && skip {
    (tips.group, tips.active)
  } else if skip {
    (
      @headless.TooltipGroup::new(
        fn() { tips.active.get() },
        fn(k) { tips.active.set(k) },
        open_delay_ms=delay,
        warmup_ms=@headless.tooltip_skip_ms,
      ),
      tips.active,
    )
  } else {
    (
      @headless.TooltipGroup::new(
        fn() { own_active.get() },
        fn(k) { own_active.set(k) },
        open_delay_ms=delay,
        warmup_ms=-1.0,
      ),
      own_active,
    )
  }
  let shut = @signals.signal(false, same=fn(a, b) { a == b })
  let over_now = fn() { @ui.pointing() is Mouse && (if within { anchor.pointed_in() } else { anchor.pointed() }) }
  let pressed_now = fn() {
    match pressed {
      Some(p) => p()
      None => anchor.pressed()
    }
  }
  anchor.reacts(fn() { (pressed_now(), over_now(), anchor.focus_shown()) }, at_start=false, fn(st) {
    let (down, over, focused) = st
    if down {
      shut.set(true)
    } else if !over && !focused {
      shut.set(false)
    }
  })
  let group_disabled = fn() {
    label() == "" || hand.get() != Free || shut.get() || pressed_now()
  }
  group.trigger(anchor, owner, disabled=group_disabled, within~, repeats~)
  // (made in its layer as it is first shown where there is one then (none yet: shown the next time it is, as there is
  // one), held there for its control, let go with it)
  let made = Ref(false)
  let holder_v : Ref[@view.View?] = Ref(None)
  let tip_id = Ref(0)
  let close_tip : Ref[() -> Unit] = Ref(fn() {  })
  // (Escape while it shows: its, before what is under it (a viewer it is over) is asked; gone, shut as a press shuts it)
  let escaped : Ref[() -> Unit] = Ref(fn() {  })
  let make = fn() -> Bool {
    guard (tips.layer)() is Some(l) else { return false }
    let holder = l.box(fn(h) { h.transitions_only().over(Is(true)) |> ignore }).lives_with(anchor)
    holder_v.val = Some(holder)
    holder.on_key(fn(k) {
      if k.code == @ui.key_escape && @signals.untracked(fn() { open.get() && @headless.tip_owns(owner) }) {
        (escaped.val)()
        true
      } else {
        false
      }
    })
    |> ignore
    holder.show(fn() { open.get() }, leave=@motion.pop_out_ms, fn(t) {
      t.over(Is(true)) |> ignore
      @headless.tooltip_bubble(t, label, fn(b) {
        tip_look_node(b, anchor_id, side, label, shortcut, fade, glide, gap, at_pointer, owner)
      })
      |> ignore
    })
    true
  }
  let set_open = fn(on : Bool) {
    if on == open.untracked() {
      return
    }
    // (saying what its control shows whole: not shown where that shows whole as it would show, at this moment)
    if on && repeats && !anchor.words_cut_now() {
      return
    }
    let at = anchor.cause_at()
    if on {
      // (another of the layer's showing or gone a moment ago, on the same side: taken over from where it is drawn now,
      // as fast as it goes, before this one takes the window's slot from it; there before tip_settled moments,
      // @motion.hand_spring)
      let taken = glide.came(at, @motion.hand_spring, takes=skip && !at_pointer)
      if !made.val {
        made.val = make()
      }
      if made.val {
        @headless.tip_claim(owner)
        if tip_id.val == 0 {
          tip_id.val = transient_next_id()
        }
        transient_tip_register(tip_id.val, anchor, fn() { (close_tip.val)() })
      }
      match taken {
        // (in whole at once, its ground going from where the other's was to its own place, its words with it)
        Some(_) => fade.put(1.0)
        // (in, as kit's tip_in: from where it is at this moment, eased out)
        None => fade.go(anchor, 1.0, at, tip_in_ms, Out)
      }
    } else {
      transient_tip_release(tip_id.val)
      // (out, as pop_out: from where it is at this moment, eased to leave, over as long as it is kept going)
      fade.go(anchor, 0.0, at, @motion.pop_out_ms, Leave)
      tips.went_at = at
      glide.left(at)
    }
    match holder_v.val {
      Some(h) if h.alive() => @view.transition(within=h, fn() { open.set(on) })
      _ => open.set(on)
    }
  }
  // (opened on its control (TipHand::open): the window's taps then, shut by the one after it)
  let opened_at = Ref(0)
  let hand_state = fn() {
    let held = hand.get()
    if held == Free {
      (Free, 0, true, true)
    } else {
      (
        held,
        match held {
          Lifted => anchor.window_downs()
          Opened => anchor.window_taps()
          _ => 0
        },
        anchor.takes_input(),
        label() != "",
      )
    }
  }
  let hand_before = Ref((Free, 0))
  anchor.reacts(hand_state, at_start=false, fn(s) {
    let (held, n, takes, says) = s
    let (was_held, was_n) = hand_before.val
    hand_before.val = (held, n)
    if held == Free {
      return
    }
    if held == was_held && n != was_n {
      if held == Lifted {
        (lifted_end.val)()
        hand.set(Free)
        return
      }
      if held == Opened && n > opened_at.val + 1 {
        hand.set(Free)
        return
      }
    }
    if !says || !takes {
      (lifted_end.val)()
      hand.set(Free)
    }
  })
  anchor.reacts(
    fn() { group.is_open(owner) || (hand.get() != Free && anchor.takes_input() && label() != "") },
    at_start=false,
    fn(want) {
      if want && made.val && open.untracked() {
        @headless.tip_claim(owner)
      }
      set_open(want)
    },
  )
  // (a new cause on a still-open anchor reclaims the shared window tip slot, e.g. after an old view displaced it)
  anchor.reacts(fn() { (over_now(), anchor.focus_shown()) }, at_start=false, fn(st) {
    let (over, focused) = st
    if (over || focused) &&
      made.val &&
      open.untracked() &&
      @signals.untracked(fn() { anchor.takes_input() && label() != "" && !pressed_now() && !shut.get() }) {
      @headless.tip_claim(owner)
    }
  })
  // (when takes_input returns after a modal layer closes while visible keyboard focus is still on anchor, reopen)
  anchor.reacts(fn() { anchor.takes_input() }, at_start=false, fn(takes) {
    if takes &&
      @signals.untracked(fn() { anchor.focus_shown() && label() != "" && hand.get() == Free && !shut.get() && !pressed_now() }) {
      group_slot.set(Some(owner))
      set_open(true)
    }
  })
  // (attached to a control that already has visible keyboard focus: show immediately)
  if @signals.untracked(fn() { anchor.focus_shown() && anchor.takes_input() && label() != "" }) {
    group_slot.set(Some(owner))
    set_open(true)
  }
  close_tip.val = fn() {
    if group_slot.untracked() == Some(owner) {
      group_slot.set(None)
    }
    if hand.untracked() != Free {
      (lifted_end.val)()
      hand.set(Free)
    }
    if open.untracked() {
      set_open(false)
    }
  }
  escaped.val = fn() {
    (close_tip.val)()
  }
  // (its control let go: nothing of it left pending; escaped/close_tip let go of last, as they name themselves through
  // set_open's make, a ring native's counting never frees)
  anchor.owns(fn() {
    fade.stop()
    glide.gone()
    transient_tip_release(tip_id.val)
    (lifted_end.val)()
    escaped.val = fn() {  }
    close_tip.val = fn() {  }
  })
  |> ignore
  {
    hold: fn() {
      (lifted_end.val)()
      hand.set(Held)
    },
    cancel: fn() {
      (lifted_end.val)()
      hand.set(Free)
    },
    open: fn(tapped) {
      (lifted_end.val)()
      // (the tap opening it told the window after its control took it: the one after it shuts it; opened otherwise (a
      // key, a screen reader), the next)
      let now = @signals.untracked(fn() { anchor.window_taps() })
      opened_at.val = if tapped { now } else { now - 1 }
      hand.set(Opened)
    },
    opened: fn() { hand.untracked() == Opened },
    lift: fn() {
      if hand.untracked() == Held {
        hand.set(Lifted)
        lifted_end.val = anchor.at_moment(anchor.cause_at() + @headless.tooltip_lifted_ms, fn() { hand.set(Free) })
      }
    },
  }
}

///|
/// How a finger holds a tip open (tip_node): not at all, held down on its control, let go of it a moment ago, tapped open
/// (till the next tap).
#derive(Eq)
enum TipHeld {
  Free
  Held
  Lifted
  Opened
}

///|
/// What a control tells its tip of a finger (tip_node's): held on it long enough (`hold`: shown at once, as long as it
/// stays down), let go after (`lift`: shown on tooltip_lifted_ms more, or till the next press, wherever it lands),
/// called off instead (`cancel`: the system took the touch, its control was taken from the hand: gone, none of it
/// kept).
pub struct TipHand {
  hold : () -> Unit
  lift : () -> Unit
  cancel : () -> Unit
  /// shown till the next tap, wherever it lands (about's): after the finger's tap on its control that opens it where
  /// `tapped` (told the window after its control took it), else (a key, a screen reader) the next one
  open : (Bool) -> Unit
  /// whether it is so opened now (not shut since: a tap after, `cancel`)
  opened : () -> Bool
}

///|
/// How far a tip is in (0 none of it, 1 all of it) as it comes and goes (tip_node): one way at a time, from where the
/// one before had it at the moment it was turned (`from`, worked out of that one as of then: the same however far it had
/// got), to `to` over `ms` from `start` as `ease` has it; while it goes (`moving`, till the moment it ends: the clock
/// read no longer than that), the moment it ends its own, let go as another way is set out.
priv struct TipFade {
  mut from : Double
  mut to : Double
  mut start : Double
  mut ms : Double
  mut ease : @ui.Ease
  moving : @signals.Signal[Bool]
  mut due : (() -> Unit)?
}

///|
/// A tip none of which is in, going nowhere.
fn TipFade::new() -> TipFade {
  { from: 0.0, to: 0.0, start: 0.0, ms: 0.0, ease: Out, moving: @signals.signal(false, same=fn(a, b) { a == b }), due: None }
}

///|
/// How far in it is at `t`, by the way it goes now.
fn TipFade::at(self : TipFade, t : Double) -> Double {
  if self.ms <= 0.0 || t >= self.start + self.ms {
    return self.to
  }
  let p = (t - self.start) / self.ms
  self.from + (self.to - self.from) * self.ease.at(if p < 0.0 { 0.0 } else { p })
}

///|
/// It set going to `to` from `at` over `ms` as `ease` has it, from where it is at `at`; its end, the moment `node` says
/// it is (its own, the way before's let go).
fn TipFade::go(self : TipFade, node : @view.View, to : Double, at : Double, ms : Double, ease : @ui.Ease) -> Unit {
  self.from = self.at(at)
  self.to = to
  self.start = at
  self.ms = ms
  self.ease = ease
  self.stop()
  self.moving.set(true)
  self.due = Some(node.at_moment(at + ms, fn() { self.moving.set(false) }))
}

///|
/// All of it in (`to`) at once, going nowhere (shown in place of another of its layer: tip_node's handoff).
fn TipFade::put(self : TipFade, to : Double) -> Unit {
  self.from = to
  self.to = to
  self.start = 0.0
  self.ms = 0.0
  self.stop()
  self.moving.set(false)
}

///|
/// Its end's moment let go of (another way set out, its control gone).
fn TipFade::stop(self : TipFade) -> Unit {
  match self.due {
    Some(s) => s()
    None => ()
  }
  self.due = None
}

///|
/// How far in it is as drawn now: by the clock while it goes, where it went once it is there.
fn TipFade::shown(self : TipFade, t : @view.View) -> Double {
  if self.moving.get() {
    self.at(t.drawn_at())
  } else {
    self.to
  }
}

///|
/// A tip's node `t` as tip_look draws it (tip_ground, tip_edge, tip_words), beside `anchor` on `side`, saying `label`,
/// then the keys of action `shortcut` where there are any as it is shown, each a cap of its own at its end (key_caps,
/// tip_cap_node): its look and its words set as the window's theme says, as that changes; in and out as `fade` says.
/// With keys it stands `tip_key_in` over, under and after them, as tall as one without (its words' line, tip_cap_over
/// over and under it), its last cap concentric with its corners at its end (tip_cap_round), its words as far from its
/// start as a tip of words alone has them.
#callsite(autofill(loc))
fn tip_look_node(
  t : @view.View,
  anchor : @view.NodeId,
  side : @view.Side,
  label : () -> String,
  shortcut : String,
  fade : TipFade,
  glide : @motion.HandPart,
  gap : Double,
  at_pointer : Bool,
  owner : @headless.TipOwner,
  loc~ : SourceLoc,
) -> Unit {
  let theme = fn() { @ui.tree_theme() }
  let px = @ui.Space::px(S2_5)
  let py = @ui.Space::px(S1_25)
  // (whether it says keys, as it is shown: a keyboard come or gone while it shows, so the next time it is)
  let keys = @signals.untracked(fn() { key_caps(shortcut_keys(shortcut)) })
  t
  .beside(anchor, side~, along=Middle, offset=gap, at_pointer~)
  // (with keys: its words as far from its start as a tip of words alone, its last cap tip_key_in from its top, end and
  // foot, concentric with its corners there)
  .padding(
    Is(
      if keys.is_empty() {
        (px, py, px, py)
      } else if @signals.untracked(fn() { label() }) == "" {
        (tip_key_in, tip_key_in, tip_key_in, tip_key_in)
      } else {
        (px, tip_key_in, tip_key_in, tip_key_in)
      },
    ),
  )
  .max_width(Is(Some(tip_widest)))
  |> ignore
  @glass.liquid_tooltip_surface_decorate(
    t,
    radius=tip_round,
    active=fn() { @headless.tip_owns(owner) },
    solid=panel_ground,
    shadow=glass_overlay_shadow,
    solid_edge=@glass.liquid_overlay_solid_edge,
    panel=true,
  )
  // (its ground in first, its words after, as kit's tip_in and pop_out have them (ground_first): the ground the first
  // half of the way in, the words the second; going, the other way round)
  .alpha(By(fn() {
    let a = if @headless.tip_owns(owner) { fade.shown(t) } else { 0.0 }
    if a * 2.0 < 1.0 {
      a * 2.0
    } else {
      1.0
    }
  }))
  .hides(By(fn() { !@headless.tip_owns(owner) }))
  |> ignore
  let words_look = fn(wrap : Bool) -> @view.WordsLook {
    let (size, line) = theme().text_size(Meta)
    { size, weight: 400, line, wrap, tracking: @view.letters_own, balance: false, max_lines: 0 }
  }
  t.box(made_for=loc, fn(w) {
    if !keys.is_empty() {
      // (its words, then its keys' caps, on its words' first line however many lines they break into: the words as
      // far from the caps' top and foot as their line is shorter than the caps)
      style_node(w, fn() { tip_key_line })
      w.box(fn(l) {
        l
        .padding(Is((0.0, tip_cap_over, 0.0, tip_cap_over)))
        .shrink(Is(1.0))
        .words(By(fn() { label() }))
        .words_look(By(fn() { words_look(true) }))
        .ink(By(fn() { library_theme().p.text }))
        |> ignore
      })
      |> ignore
      w.box(fn(q) {
        style_node(q, fn() { tip_caps_node })
        for cap in keys {
          tip_cap_node(q, cap)
        }
      })
      |> ignore
    } else {
      w.words(By(fn() { label() })).words_look(By(fn() { words_look(true) })).ink(By(fn() { library_theme().p.text })) |> ignore
    }
    // (its ground handed on among its layer's tips, its words with it: from where the one before was drawn, from its
    // middle)
    glide.draws(t, carries=w)
    w
    .alpha(By(fn() {
      // (of its ground's: what of the words shows over as much of the ground as there is)
      let a = fade.shown(t)
      let ground = if a * 2.0 < 1.0 { a * 2.0 } else { 1.0 }
      let words = if a * 2.0 - 1.0 > 0.0 { a * 2.0 - 1.0 } else { 0.0 }
      if ground > 0.0 {
        words / ground
      } else {
        0.0
      }
    }))
    |> ignore
  })
  |> ignore
}

///|
/// A key's cap in a tip's row of them (`parent`): `cap` (⌘, ⇧, K, Ctrl, Esc) in the tip's words' ink at the caption's
/// size, 500, in the middle of a box as high as the tip's words' line and tip_cap_over over and under it, as wide at
/// least, tip_cap_round round, its ground and line the tip's words mixed into its ground (opaque: no line seen through a
/// ground under it), as the theme says as that changes.
#callsite(autofill(loc))
fn tip_cap_node(parent : @view.View, cap : String, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(k) {
    style_node(k, fn() { tip_cap_node_look })
    let side = fn() { node_sp(k, @ui.tree_theme().text_size(Meta).1) + 2.0 * tip_cap_over }
    k
    .height(By(fn() { Some(side()) }))
    .min_width(By(fn() { Some(side()) }))
    .radius(Is(tip_cap_round))
    .ground(By(fn() { mix(library_theme().p.text, tip_cap_ground, panel_ground()) }))
    |> ignore
    k.box(fn(w) {
      w
      .words(Is(cap))
      .words_look(
        By(fn() {
          let (size, line) = @ui.tree_theme().text_size(Caption)
          { size, weight: 500, line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
        }),
      )
      .ink(By(fn() { mix(library_theme().p.text, tip_cap_ink, panel_ground()) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The keys of a shortcut as the app says them, each a cap of its own: on an Apple keyboard its marks (⌃ ⌥ ⇧ ⌘) one a
/// cap each and the key after them one (`⌘⇧F`, `⌘ Enter`); elsewhere each part between `+` (`Ctrl+Shift+F`), a `+`
/// where a part would be empty the key itself (`Ctrl++`). None for none.
pub fn key_caps(keys : String) -> Array[String] {
  let caps : Array[String] = []
  let is_mark = fn(c : Char) { c == '⌃' || c == '⌥' || c == '⇧' || c == '⌘' }
  let said = keys.trim(chars=" ").to_owned()
  let chars = said.to_array()
  if chars.is_empty() {
    return caps
  }
  if is_mark(chars[0]) {
    let mut at = 0
    while at < chars.length() && is_mark(chars[at]) {
      caps.push(chars[at].to_string())
      at += 1
    }
    let rest = StringBuilder(capacity=chars.length() - at)
    for i in at..<chars.length() {
      rest.write_char(chars[i])
    }
    let key = rest.to_string().trim(chars=" ").to_owned()
    if key != "" {
      caps.push(key)
    }
    return caps
  }
  let mut part : Array[Char] = []
  for c in chars {
    if c == '+' && !part.is_empty() {
      caps.push(String::from_array(part).trim(chars=" ").to_owned())
      part = []
    } else {
      part.push(c)
    }
  }
  if !part.is_empty() {
    caps.push(String::from_array(part).trim(chars=" ").to_owned())
  }
  caps
}

///|
/// A tip's ground: the primary ink in light (a dark charcoal over the page); in the dark not that ink (the light grey,
/// a glare of a block) but what floats lifted `tip_lift` toward the words, a step over a menu's (panel_ground).
pub fn tip_ground() -> Int64 {
  let t = theme()
  if t.dark {
    mix(t.p.text, tip_lift, t.p.raised)
  } else {
    t.p.primary
  }
}

///|
/// A tip's line (how wide, its colour): in the dark a faint one, its words' ink at `tip_edge_seen`, cutting it off a dark
/// ground; none in light, its dark ground off the light page by itself.
pub fn tip_edge() -> (Double, Int64) {
  let t = theme()
  if t.dark {
    (1.0, alpha(t.p.text, tip_edge_seen))
  } else {
    (0.0, 0L)
  }
}

///|
/// A tip's words: on the primary ink's in light, the words' own ink in the dark.
pub fn tip_words() -> Int64 {
  let t = theme()
  if t.dark {
    t.p.text
  } else {
    t.p.on_primary
  }
}

///|
let tip_lift : Double = 0.05

///|
let tip_edge_seen : Double = 0.09

///|
/// A tip's caps: how far over and under its words' line they reach (so the tip, tip_key_in round them, is as tall as one
/// of words alone, 5 round them), how round the tip is (the library's small corner), how far in from them the tip
/// stands over, under and after them (concentric: tip_round less it), and how much of the tip's words their ground and
/// words are (opaque, no line round them).
let tip_cap_over : Double = 1.0

///|
let tip_round : Double = small_corner

///|
let tip_key_in : Double = 4.0

///|
let tip_cap_round : Double = @ui.concentric(tip_round, tip_key_in)

///|
let tip_cap_ground : Double = 0.12

///|
let tip_cap_ink : Double = 0.88

///|
// kept across runs: a value (no field of it changes)
let tip_caps_node : @ui.Style = @ui.css("row gap=S0_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let tip_cap_node_look : @ui.Style = @ui.css("row px=S1_25 align=ACenter justify=JCenter")

///|
/// How far a tip is from its control (kit's tooltip `offset`), and how wide it may grow (tip_max).
let tip_gap : Double = floating_trigger_gap

///|
let tip_widest : Double = match tip_max {
  Fixed(v) => v
  _ => 0.0
}
