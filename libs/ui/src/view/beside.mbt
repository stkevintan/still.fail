// What goes beside another (a tip by what it tells of, a menu by its trigger): which side of its anchor, lined up how
// along it (Side, Along), where it goes then, kept in the window (place_beside: Radix's Popper, flip then shift; one
// way of working it out, the old frame's Ctx::place's and a node's, View::beside); a node said to go so placed by its
// anchor as the tree is laid out and placed, by its anchor's place then, not as it was drawn before.

///|
/// Which side of its anchor a layer's content goes.
#derive(Eq, Debug)
pub(all) enum Side {
  Top
  Right
  Bottom
  Left
}

///|
/// Where along the side it lines up with the anchor: their starts (the left, right to left the right), their middles,
/// their ends. (Where what a node holds lies along its own way, spread between its ends too, is Lies: words.mbt.)
#derive(Eq, Debug)
pub(all) enum Along {
  Start
  Middle
  End
}

///|
/// Where content `w` by `h` goes by an anchor (x, y, w, h, in a window `vw` by `vh`), Radix's Popper: on `side`,
/// `offset` away, lined up `along` it (moved `along_offset` further), kept `padding` inside the window (`flip`: to the
/// other side when it does not fit on its own and fits better there; moved along the side to stay in, and over the
/// anchor where it fits on neither: Radix's shift on both axes); `on`: the side it is on now, where it stays as long
/// as it has the room there (else as `side` and `flip` say); `rtl`: right to left, a start the right; `clear`: how
/// far in from the window's top, right, foot and left the system's bars reach (their safe area: the status bar, an
/// iPhone Duo's bars of the app's actions and tabs, the home indicator), kept clear as the window's own edges are;
/// `away`: a box of the window's own over all else of it (its own buttons, Tree::keeps_away) it would lie under where
/// placed so, its anchor clear of it: moved along its side till `padding` clear of it, where that keeps it in the
/// window, else past it across (below it, a box at the window's top). Its top left, and the side it went on.
pub fn place_beside(
  anchor : (Double, Double, Double, Double),
  w : Double,
  h : Double,
  vw : Double,
  vh : Double,
  side? : Side = Bottom,
  along? : Along = Middle,
  offset? : Double = 4.0,
  along_offset? : Double = 0.0,
  padding? : Double = 8.0,
  flip? : Bool = true,
  on? : Side,
  rtl? : Bool = false,
  clear? : (Double, Double, Double, Double) = (0.0, 0.0, 0.0, 0.0),
  away? : (Double, Double, Double, Double),
) -> (Double, Double, Side) {
  let (ax, ay, aw, ah) = anchor
  let (top, right, foot, left) = clear
  // the room on each side
  let room = fn(s : Side) {
    match s {
      Top => ay - top - offset - padding
      Bottom => vh - foot - (ay + ah) - offset - padding
      Left => ax - left - offset - padding
      Right => vw - right - (ax + aw) - offset - padding
    }
  }
  let opposite = fn(s : Side) {
    match s {
      Top => Bottom
      Bottom => Top
      Left => Right
      Right => Left
    }
  }
  let need = fn(s : Side) {
    match s {
      Top | Bottom => h
      Left | Right => w
    }
  }
  let side = match on {
    // (on that side still, where it has the room there: kept there, never back to its own for having the room again)
    Some(s) if room(s) >= need(s) => s
    _ =>
      if flip && room(side) < need(side) && room(opposite(side)) > room(side) {
        opposite(side)
      } else {
        side
      }
  }
  // right to left, a start is the right
  let across = side == Top || side == Bottom
  let along : Along = if rtl && across {
    match along {
      Start => End
      End => Start
      Middle => Middle
    }
  } else {
    along
  }
  let sign = if rtl && across { -1.0 } else { 1.0 }
  let line = fn(a0 : Double, alen : Double, len : Double) {
    match along {
      Start => a0
      Middle => a0 + (alen - len) / 2.0
      End => a0 + alen - len
    }
  }
  let (x, y) = match side {
    Top => (line(ax, aw, w) + along_offset * sign, ay - offset - h)
    Bottom => (line(ax, aw, w) + along_offset * sign, ay + ah + offset)
    Left => (ax - offset - w, line(ay, ah, h) + along_offset)
    Right => (ax + aw + offset, line(ay, ah, h) + along_offset)
  }
  // moved along to stay in the window, and across where neither side has the room for it: over its anchor rather
  // than out of the window (never past its start)
  let keep = fn(v : Double, len : Double, lo : Double, max : Double) {
    let hi = max - padding - len
    let v = if v < hi { v } else { hi }
    if v > lo + padding {
      v
    } else {
      lo + padding
    }
  }
  let x = keep(x, w, left, vw - right)
  let y = keep(y, h, top, vh - foot)
  let meets = fn(bx : Double, by : Double, bw : Double, bh : Double, o : (Double, Double, Double, Double)) {
    bx < o.0 + o.2 && o.0 < bx + bw && by < o.1 + o.3 && o.1 < by + bh
  }
  guard away is Some(o) && meets(x, y, w, h, o) && !meets(ax, ay, aw, ah, o) else { return (x, y, side) }
  // (along its side, to the side of the box its anchor's middle is on; where that leaves the window, past it across,
  // on whichever side of it has more room)
  let (ox, oy, ow, oh) = o
  let room_in = fn(lo : Double, hi : Double, v : Double, len : Double) { v >= lo + padding && v + len <= hi - padding }
  if across {
    let to = if ax + aw / 2.0 < ox + ow / 2.0 { ox - padding - w } else { ox + ow + padding }
    if room_in(left, vw - right, to, w) {
      return (to, y, side)
    }
    let to = if oy - top > vh - foot - (oy + oh) { oy - padding - h } else { oy + oh + padding }
    (x, keep(to, h, top, vh - foot), side)
  } else {
    let to = if ay + ah / 2.0 < oy + oh / 2.0 { oy - padding - h } else { oy + oh + padding }
    if room_in(top, vh - foot, to, h) {
      return (x, to, side)
    }
    let to = if ox - left > vw - right - (ox + ow) { ox - padding - w } else { ox + ow + padding }
    (keep(to, w, left, vw - right), y, side)
  }
}

///|
/// What a node goes beside (View::beside): its anchor, on which side of it, lined up how, how far off, kept how far
/// inside the window; `at_pointer`: beside the point of it the pointer is at while the pointer is on it, not all of it;
/// `along_offset`: moved that much further along its side, in its own points.
#derive(Eq, Debug)
pub(all) struct Beside {
  anchor : NodeId
  side : Side
  along : Along
  offset : Double
  padding : Double
  at_pointer : Bool
  width : BesideWidth
  along_offset : Double
  /// on the side it is on while it has the room there (View::beside's `holds_side`)
  holds_side : Bool
  /// optional outer host container whose left/right edges are cleared when `side` is `Left` or `Right`
  host : NodeId?
  /// whether to flip to the opposite side when `side` does not have room (default true)
  flip : Bool
  /// drawn only while where it goes beside is seen (View::beside's `while_seen`)
  while_seen : Bool
}

///|
/// How wide what goes beside another is (View::beside's `width`): as wide as what it holds says (`Own`), or as wide as
/// its anchor is laid out (`Anchor`: Radix's trigger width, a list a field offers as wide as the field).
#derive(Eq, Debug)
pub(all) enum BesideWidth {
  Own
  Anchor
}

///|
/// Placed beside node `anchor` (place_beside: on `side`, `offset` away, lined up `along` it, kept `padding` inside the
/// window, to the other side where it has not the room on its own), by where the anchor is and how big both are as the
/// tree is placed, each time it is: what it holds with it. Out of its holder's flow, as big as what it holds says (its
/// width, its words). Leaving, or its anchor gone or drawn nowhere (let go, left out of its row, leaving), where it
/// last went beside it: it follows its anchor while both are there, and never goes anywhere else. `at_pointer`: beside
/// the point in the window the pointer is at while it is on the anchor (Tree::point_at, placed again as it moves), as
/// the anchor were that point (a tip by the pointer along a tall thin thing); the pointer gone off it, by the point of
/// it the pointer was last at (following the anchor still); never on it, beside all of it. `width`: `Anchor`, as wide
/// as its anchor is laid out (Tree::beside_widened: in the same layout, before it is placed by it; as the anchor is
/// laid out, not as it is drawn bigger or smaller, which is its look's), its width said by nothing else. That takes
/// the anchor and it to be drawn at one scale at rest: where they are not (an anchor in a box drawn half as big, this
/// drawn whole over it), its width is the anchor's laid out, and it is not drawn as wide as the anchor is. `piece`:
/// beside a piece of the anchor, not all of it (a link in its words: mbui/ui's `runs_link_piece`, the box round its
/// pieces of line): asked as it is placed, given how wide and tall the anchor is laid out then, the piece in the
/// anchor's own terms (x, y, w, h); none where it has no such piece now (its words said again without it), where it
/// stays as it does when its anchor is drawn nowhere. Asked untracked, only as it is placed: what it reads changing
/// places nothing again by itself. The anchor's words set again, its size, its place or what holds it moving does (the
/// anchor laid out or placed again); a signal of the app's it reads does not: a piece by which of the words is picked
/// (View::runs_picked) stays by the words picked when it was last placed as the pick moves on, till something is laid
/// out or placed again. So it reads the anchor's words as they are laid out, nothing else. `along_offset`: moved
/// that much further along its side (Ctx::place's): right, or down, beside a side across the anchor; right to left, the
/// other way; from all of the anchor, or from its `piece` where it has one; in its own points, drawn as it is; kept in
/// the window as ever (`padding`). `holds_side`: on the side it is on for as long as it has the room there, to the other only for want of it there
/// (where its own has not the room, as ever), never back for its own having the room again: grown or shrunk, only its
/// edge away from its anchor moves while it stays (above it, its top; below it, its foot). Where the side it is on
/// comes to have not the room (it grew, the window was made smaller), placed as one placed afresh (its own side,
/// flipped where it has not the room there). `while_seen`: drawn only while where it goes beside (all of its anchor,
/// or its `piece`) is seen in the window, as what holds the anchor cuts it (a column that scrolls it, a row scrolling
/// across: Tree::seen_bounds) less what covers that column's top or is pinned over its foot (Tree::stays_bounds: the
/// bar it runs under, its composer); out of sight, or its anchor gone, put by, drawn nowhere or no piece of it there,
/// laid out nowhere (none of it drawn, pressed or read out), never where it last went beside it, and beside it again
/// as that is seen again. What stands for a pick by where it ends (a quote's pill: @ui's picked_end_piece), which a
/// layer over all of the window holds, is never left over what is round what scrolls its words; leaving, where it last
/// went, as ever, unless it was out of sight then.
pub fn View::beside(
  self : View,
  anchor : NodeId,
  side? : Side = Bottom,
  along? : Along = Middle,
  offset? : Double = 4.0,
  padding? : Double = 8.0,
  at_pointer? : Bool = false,
  width? : BesideWidth = Own,
  piece? : (Double, Double) -> (Double, Double, Double, Double)?,
  along_offset? : Double = 0.0,
  holds_side? : Bool = false,
  host? : NodeId,
  flip? : Bool = true,
  while_seen? : Bool = false,
) -> View {
  guard self.live() is Some(n) else { return self }
  n.beside_piece = piece
  // (beside another anchor now, or as wide as what it holds: what it was made as wide as before none of its own; said
  // beside one for the first time, none kept of a node let go before at its index)
  match n.beside {
    Some(was) => {
      // (beside another anchor: the point of the one before the pointer was last at nothing of this one's)
      if was.anchor != anchor {
        n.beside_point = None
      }
      if was.anchor != anchor || width == Own {
        self.tree.beside_narrowed(self.at, width == Own)
      }
    }
    None => self.tree.beside_widths.remove(self.at)
  }
  n.beside = Some({
    anchor,
    side,
    along,
    offset,
    padding,
    at_pointer,
    width,
    along_offset,
    holds_side,
    host,
    flip,
    while_seen,
  })
  if !self.tree.besides_at.contains(self.at) {
    self.tree.besides_at.push(self.at)
  }
  // (out of its holder's flow, as big as what it holds: where it is, its anchor's say)
  let st = n.flex.style
  st.position = Absolute
  st.set_inset_left(Pt(0.0))
  st.set_inset_top(Pt(0.0))
  st.set_inset_right(Auto)
  st.set_inset_bottom(Auto)
  self.tree.layout_marked_at(self.at)
  self
}

///|
/// Float over what holds it (`View::over(Is(true))`) and, when `anchor` is `Some`, place it beside `anchor`
/// (`View::beside` with the same placement parameters).
#callsite(autofill(loc))
pub fn View::float_beside(
  self : View,
  anchor : View?,
  side? : Side = Bottom,
  along? : Along = Middle,
  offset? : Double = 4.0,
  padding? : Double = 8.0,
  at_pointer? : Bool = false,
  width? : BesideWidth = Own,
  piece? : (Double, Double) -> (Double, Double, Double, Double)?,
  along_offset? : Double = 0.0,
  holds_side? : Bool = false,
  host? : NodeId,
  loc~ : SourceLoc,
) -> View {
  self.over(Is(true), loc~) |> ignore
  match anchor {
    Some(a) =>
      self.beside(
        a.id(),
        side~,
        along~,
        offset~,
        padding~,
        at_pointer~,
        width~,
        piece?,
        along_offset~,
        holds_side~,
        host?,
      )
    None => self
  }
}

///|
/// Placed beside the node `anchor` says as that changes (View::beside, all else as it says): bound as any property is
/// (View::bind: set again as what it reads changes, at that change's moment, before anything is laid out or worked out
/// for it, so what reads where it goes as of that moment, Moves of @motion among them, reads it beside its new anchor,
/// View::laid_window_now), let go with the node. Another anchor: beside it as the tree is next placed, at once, from the
/// side it is on where `holds_side` says so and it has the room there; nothing of where the pointer was on the one
/// before kept, and as wide as the new one where `width` says `Anchor`. What carries it there on a way is its own
/// (@motion's moves_for, by the same that says its anchor): where it is placed is only ever beside its anchor now.
#callsite(autofill(loc))
pub fn View::beside_by(
  self : View,
  anchor : Live[NodeId],
  side? : Side = Bottom,
  along? : Along = Middle,
  offset? : Double = 4.0,
  padding? : Double = 8.0,
  at_pointer? : Bool = false,
  width? : BesideWidth = Own,
  piece? : (Double, Double) -> (Double, Double, Double, Double)?,
  along_offset? : Double = 0.0,
  holds_side? : Bool = false,
  host? : NodeId,
  loc~ : SourceLoc,
) -> View {
  self.bind(loc~, BesideOf, anchor, Place, fn(a) {
    self.beside(a, side~, along~, offset~, padding~, at_pointer~, width~, piece?, along_offset~, holds_side~, host?)
    |> ignore
  })
  self
}

///|
/// Where node `at` is laid out in the window as of the layout under way (Tree::measured_now's), across and down: each
/// that holds it where it is laid out in what holds it, its offset with it (Tree::off_now), up to the first of them
/// (it too) that goes beside another, which is where it goes beside it as that is laid out (Tree::beside_laid), not
/// its holder's top left where its own layout has it. `seen`: those going beside another whose places are being worked
/// out under this one (a ring of them goes beside nothing: Tree::besides_placed's).
fn Tree::laid_window_at(self : Tree, at : Int, seen : Array[Int]) -> (Double, Double) {
  let mut x = 0.0
  let mut y = 0.0
  let mut i = at
  while i >= 0 {
    let m = self.nodes[i]
    match self.beside_laid(i, seen) {
      Some((bx, by)) => return (x + bx, y + by)
      None => ()
    }
    // (a slot lays out nothing of its own: what it holds is placed in the one that holds it)
    if !m.slot {
      let (dx, dy) = self.off_now(m)
      x = x + m.flex.left + dx
      y = y + m.flex.top + dy
    }
    i = m.parent
  }
  (x, y)
}

///|
/// How wide node `at` is laid out as of the layout under way: as wide as its anchor is where it goes beside it so
/// (BesideWidth's Anchor: what Tree::beside_widened will make it as it is placed), else its own.
fn Tree::laid_width_of(self : Tree, at : Int) -> Double {
  let n = self.nodes[at]
  match n.beside {
    // (none of a part put by at rest, held by no node: View::park)
    Some(b) if b.width == Anchor &&
      self.alive_id(b.anchor) &&
      self.held_from_root(at) &&
      self.held_from_root(b.anchor.at) &&
      !self.leaving_at(at) &&
      !self.out_at(b.anchor.at) &&
      !self.leaving_at(b.anchor.at) =>
      self.nodes[b.anchor.at].flex.width
    _ => n.flex.width
  }
}

///|
/// Where node `at`, said to go beside another (View::beside), goes in the window as of the layout under way: as
/// Tree::besides_placed places it, worked out the same way of where its anchor and it are laid out (Tree::
/// laid_window_at, its anchor's width and height, the piece of it, the pointer's point on it, the side it holds,
/// place_beside) and setting nothing of what that keeps; leaving, its anchor gone, drawn nowhere or no piece of it
/// there, where it last went beside it (Node's beside_last, from where what holds it is laid out), as besides_placed
/// keeps it. None where it goes beside nothing (none said, beside itself or what it holds, a ring of them, never placed
/// beside it yet): where its own layout has it.
fn Tree::beside_laid(self : Tree, at : Int, seen : Array[Int]) -> (Double, Double)? {
  let n = self.nodes[at]
  guard n.beside is Some(b) else { return None }
  guard !seen.contains(at) else { return None }
  let stay = fn() -> (Double, Double)? {
    match n.beside_last {
      Some((lx, ly, _, _)) => {
        let (hx, hy) = if n.parent >= 0 { self.laid_window_at(n.parent, seen) } else { (0.0, 0.0) }
        Some((hx + lx, hy + ly))
      }
      None => None
    }
  }
  guard self.alive_id(b.anchor) else { return stay() }
  // (put by at rest, or its anchor so (View::park): in no scene, nothing of it worked out)
  if !self.held_from_root(at) ||
    !self.held_from_root(b.anchor.at) ||
    self.leaving_at(at) ||
    self.out_at(b.anchor.at) ||
    self.leaving_at(b.anchor.at) {
    return stay()
  }
  // (beside itself or what it holds: where it is laid out)
  let mut i = b.anchor.at
  while i >= 0 {
    if i == at {
      return None
    }
    i = self.nodes[i].parent
  }
  seen.push(at)
  let (ax, ay) = self.laid_window_at(b.anchor.at, seen)
  seen.pop() |> ignore
  let a = self.nodes[b.anchor.at]
  let (aw, ah) = (a.flex.width, a.flex.height)
  let (ax, ay, aw, ah) = match n.beside_piece {
    None => (ax, ay, aw, ah)
    Some(f) =>
      match @signals.untracked(fn() { f(aw, ah) }) {
        Some((x, y, w, h)) => (ax + x, ay + y, w, h)
        None => return stay()
      }
  }
  let (px, py) = self.pointer_xy
  let rect = if b.at_pointer && px >= ax && py >= ay && px < ax + aw && py < ay + ah {
    (px, py, 0.0, 0.0)
  } else {
    match (b.at_pointer, n.beside_point) {
      (true, Some((ox, oy))) => (ax + ox, ay + oy, 0.0, 0.0)
      _ => (ax, ay, aw, ah)
    }
  }
  let rect = match (b.side, b.host) {
    (Left | Right, Some(h)) if self.alive_id(h) &&
      h.at != at &&
      !seen.contains(h.at) &&
      self.held_from_root(h.at) &&
      !self.out_at(h.at) &&
      !self.leaving_at(h.at) => {
      let mut k = h.at
      let mut in_at = false
      while k >= 0 {
        if k == at {
          in_at = true
          break
        }
        k = self.nodes[k].parent
      }
      if in_at {
        rect
      } else {
        seen.push(at)
        let (host_x, _) = self.laid_window_at(h.at, seen)
        seen.pop() |> ignore
        let hw = self.laid_width_of(h.at)
        let left_x = if rect.0 < host_x { rect.0 } else { host_x }
        let right_x = dmax(rect.0 + rect.2, host_x + hw)
        (left_x, rect.1, right_x - left_x, rect.3)
      }
    }
    _ => rect
  }
  let on = if b.holds_side { n.went } else { None }
  let (x, y, _) = place_beside(
    rect,
    self.laid_width_of(at),
    n.flex.height,
    self.last_w,
    self.last_h,
    side=b.side,
    on?,
    along=b.along,
    offset=b.offset,
    along_offset=b.along_offset,
    padding=b.padding,
    flip=b.flip,
    clear=self.clear.untracked(),
    away?=self.away,
  )
  Some((x, y))
}

///|
/// What goes beside another placed by it (View::beside), as the tree is placed now (Tree::laid_out, where anything was
/// laid out or placed again): each after what it goes beside where that goes beside another in turn, and after what
/// holds it where that does (a chain of them in its order, whatever order they were made or said in), what lands
/// elsewhere than it was composed again there. What goes beside itself or what it holds, or beside what comes round to
/// it again (a ring of them), goes beside nothing: where it is laid out, each time. Those let go dropped.
fn Tree::besides_placed(self : Tree) -> Unit {
  let live = self.besides_at.filter(fn(at) { self.nodes[at].live && self.nodes[at].beside is Some(_) })
  // (those let go, or beside nothing now: no width kept for them)
  if live.length() != self.besides_at.length() && self.beside_widths.length() > 0 {
    for at in self.besides_at {
      if !live.contains(at) {
        self.beside_widths.remove(at)
      }
    }
  }
  self.besides_at.clear()
  self.besides_at.append(live)
  // (1 being placed, 2 placed beside its anchor, 3 refused: where it is laid out)
  let state : Map[Int, Int] = Map([])
  fn set_unplaced(at : Int, unplaced : Bool) -> Unit {
    let n = self.nodes[at]
    n.beside_unplaced = unplaced
    let out = n.flex.left_out() || unplaced
    if out != n.out {
      n.out = out
      self.outs_changed = true
      self.sizes_due = true
      self.outs_gone.push(at)
      self.work.composed = self.work.composed + 1
      self.composed.push({ at, gen: n.gen })
      self.places_rev = self.places_rev + 1
      self.touched(at, words=true, state=true, kids=true)
      self.hits_bump()
    }
  }

  fn refused(at : Int) -> Unit {
    state[at] = 3
    set_unplaced(at, false)
    // (on no side of anything)
    self.nodes[at].went = None
    // (where it is laid out, as if it went beside nothing: never where it went last)
    let n = self.nodes[at]
    let (lx, ly) = (n.lx, n.ly)
    self.place(at)
    if n.lx != lx || n.ly != ly {
      self.work.composed = self.work.composed + 1
      self.composed.push({ at, gen: n.gen })
      self.places_rev = self.places_rev + 1
      self.hits_bump()
    }
  }

  fn place_one(at : Int) -> Bool {
    match state.get(at) {
      Some(1) => return false
      Some(2) => return true
      Some(_) => return false
      None => ()
    }
    state[at] = 1
    let n = self.nodes[at]
    // (where it was last beside its anchor, kept: placed again by what changed of its own (its fading, its size), it
    // stays there, never where it is laid out; never placed beside it yet: kept out of sight rather than drawn at
    // (0, 0) in its holder where its anchor is drawn but gives no place beside it yet (`hides`: no piece of it, not
    // in the window's terms); where its anchor is gone, put by or drawn nowhere (a page parked, a button the system
    // draws in its own bar), where it is laid out, as before)
    // (said to be drawn only while where it goes beside is seen (View::beside's `while_seen`): beside nothing seen, laid
    // out nowhere, never where it last went; leaving, where it last went as ever, unless it was out of sight already)
    let while_seen = n.beside is Some(b) && b.while_seen
    let unseen = fn() {
      if self.held_from_root(at) {
        set_unplaced(at, true)
      }
      state[at] = 2
      true
    }
    let stay = fn(hides : Bool) {
      if while_seen && (n.beside_unplaced || !self.leaving_at(at)) {
        return unseen()
      }
      match n.beside_last {
        Some((lx, ly, px, py)) => {
          set_unplaced(at, false)
          // (as big as about the point it last went from: its max_shift kept there, View::scale)
          let ls = n.scaled_at(n.lw, n.lh, px, py)
          if lx != n.lx || ly != n.ly || px != n.lpx || py != n.lpy || ls != n.ls {
            n.lx = lx
            n.ly = ly
            n.lpx = px
            n.lpy = py
            n.ls = ls
            self.work.composed = self.work.composed + 1
            self.composed.push({ at, gen: n.gen })
            self.places_rev = self.places_rev + 1
            self.hits_bump()
          }
        }
        None => if hides && self.held_from_root(at) { set_unplaced(at, true) }
      }
      state[at] = 2
      true
    }
    guard n.beside is Some(b) && self.alive_id(b.anchor) else {
      // (beside nothing now, its anchor gone: on no side of it, where it last was beside it)
      if n.went is Some(_) {
        self.sizes_due = true
      }
      n.went = None
      return stay(false)
    }
    // (leaving, or its anchor drawn nowhere (left out of its row, leaving): where it last was beside it, following
    // nothing on its way out)
    // (put by at rest, or its anchor so (View::park): in no scene, nothing of it worked out or placed)
    if !self.held_from_root(at) ||
      !self.held_from_root(b.anchor.at) ||
      self.leaving_at(at) ||
      self.out_at(b.anchor.at) ||
      self.leaving_at(b.anchor.at) {
      return stay(false)
    }
    // (beside itself or what it holds: refused)
    let mut i = b.anchor.at
    while i >= 0 {
      if i == at {
        refused(at)
        return false
      }
      i = self.nodes[i].parent
    }
    let host_at : Int? = match b.host {
      Some(h) if self.alive_id(h) &&
        h.at != at &&
        self.held_from_root(h.at) &&
        !self.out_at(h.at) &&
        !self.leaving_at(h.at) => {
        let mut k = h.at
        let mut in_at = false
        while k >= 0 {
          if k == at {
            in_at = true
            break
          }
          k = self.nodes[k].parent
        }
        if in_at { None } else { Some(h.at) }
      }
      _ => None
    }
    // (what goes beside another among its anchor, its outer host, and what holds it, placed first: where they
    // are placed is what it is placed by; one that comes round to it again, or is refused, refuses it)
    let starts : Array[Int] = [b.anchor.at, n.parent]
    match host_at {
      Some(hat) => starts.push(hat)
      None => ()
    }
    for start in starts {
      let mut i = start
      while i >= 0 {
        if self.nodes[i].beside is Some(_) && !place_one(i) {
          refused(at)
          return false
        }
        i = self.nodes[i].parent
      }
    }
    self.work.besides = self.work.besides + 1
    // (as wide as its anchor is laid out, where it says so: laid out so alone, here, before it is placed by its size)
    if b.width == Anchor {
      self.beside_widened(at, self.nodes[b.anchor.at].lw)
    }
    // (where its anchor is drawn and how big, where what holds it is: in the window's terms as the scene is composed,
    // Tree::projected; it goes there as big as what holds it draws it, its own scale about where it went after)
    guard self.window_place(b.anchor.at) is Some((ax, ay, ascale)) else { return stay(true) }
    let a = self.nodes[b.anchor.at]
    let (hx, hy, hs) = match self.window_place(n.parent) {
      Some(p) => p
      None => (0.0, 0.0, 1.0)
    }
    // (where it is beside: all of its anchor as drawn now; by the pointer, the point it is at, while it is on it)
    let (ax, ay, aw, ah) = match n.beside_piece {
      None => (ax, ay, a.lw * ascale, a.lh * ascale)
      // (a piece of it: as it is laid out now, where it is drawn; none now, where it last was beside it)
      Some(f) =>
        match @signals.untracked(fn() { f(a.lw, a.lh) }) {
          Some((x, y, w, h)) => (ax + x * ascale, ay + y * ascale, w * ascale, h * ascale)
          None => return stay(true)
        }
    }
    // (said to go beside it only while that is seen: none of it within what the column or row that holds it shows,
    // less what covers its top or is pinned over its foot, nor within the window, laid out nowhere till it is again)
    if b.while_seen {
      let (sx0, sy0, sx1, sy1) = self.stays_bounds(b.anchor.at)
      let (x0, y0) = (dmax(sx0, 0.0), dmax(sy0, 0.0))
      let (x1, y1) = (dmin(sx1, self.last_w), dmin(sy1, self.last_h))
      // (a piece no wide, a pick's end: seen where it lies on or between the edges across, its line in sight down)
      if ax + aw < x0 || ax > x1 || ay + ah <= y0 || ay >= y1 {
        return unseen()
      }
    }
    let (px, py) = self.pointer_xy
    // (the pointer gone off it: by the point of it the pointer was last at, as the anchor is now, never jumping to all of
    // it; never on it (shown by the keyboard's focus), beside all of it)
    let rect = if b.at_pointer && px >= ax && py >= ay && px < ax + aw && py < ay + ah {
      n.beside_point = Some(((px - ax) / ascale, (py - ay) / ascale))
      (px, py, 0.0, 0.0)
    } else {
      match (b.at_pointer, n.beside_point) {
        (true, Some((ox, oy))) => (ax + ox * ascale, ay + oy * ascale, 0.0, 0.0)
        _ => (ax, ay, aw, ah)
      }
    }
    let rect = match (b.side, host_at) {
      (Left | Right, Some(hat)) =>
        match self.window_place(hat) {
          Some((host_x, _, host_scale)) => {
            let hw = self.nodes[hat].lw * host_scale
            let left_x = if rect.0 < host_x { rect.0 } else { host_x }
            let right_x = dmax(rect.0 + rect.2, host_x + hw)
            (left_x, rect.1, right_x - left_x, rect.3)
          }
          None => rect
        }
      _ => rect
    }
    // (holding the side it is on: kept there while it has the room there)
    let on = if b.holds_side { n.went } else { None }
    let (x, y, went) = place_beside(
      rect,
      n.lw * hs,
      n.lh * hs,
      self.last_w,
      self.last_h,
      side=b.side,
      on?,
      along=b.along,
      offset=b.offset,
      along_offset=b.along_offset * hs,
      padding=b.padding,
      flip=b.flip,
      clear=self.clear.untracked(),
      away?=self.away,
    )
    // (where it grows from, where it is drawn bigger or smaller about the side it went on: View::scale's FromBeside)
    if n.went != Some(went) {
      self.sizes_due = true
    }
    n.went = Some(went)
    let (px, py) = self.pivot_of(at, n.lw, n.lh)
    // (as big about the side it went on, its max_shift kept from there: Tree::place had the side it went on last)
    let ls = n.scaled_at(n.lw, n.lh, px, py)
    let (lx, ly) = ((x - hx) / hs, (y - hy) / hs)
    n.beside_last = Some((lx, ly, px, py))
    set_unplaced(at, false)
    if lx != n.lx || ly != n.ly || px != n.lpx || py != n.lpy || ls != n.ls {
      n.lx = lx
      n.ly = ly
      n.lpx = px
      n.lpy = py
      n.ls = ls
      self.work.composed = self.work.composed + 1
      self.composed.push({ at, gen: n.gen })
      self.places_rev = self.places_rev + 1
      self.hits_bump()
    }
    state[at] = 2
    true
  }

  for at in self.besides_at {
    place_one(at) |> ignore
  }
}

///|
/// Node `at`, beside its anchor as wide as that is laid out (View::beside's `Anchor`), made `w` wide where it was not
/// already: its width said so in its style, it and what it holds laid out alone at once in what holds it (Tree::
/// laid_over_alone: absolute in it, nothing else moves) and placed by that (Tree::walk, what it changed to be drawn again as
/// any layout's), in the layout under way, before it is placed beside its anchor by its size: never a layout of all of
/// it again, nothing marked to be laid out later, nothing read back. Only where the anchor's width changed (and as it is
/// first placed); its width kept in the layout's own (Tree's beside_widths), never told a binding.
fn Tree::beside_widened(self : Tree, at : Int, w : Double) -> Unit {
  let n = self.nodes[at]
  if self.beside_widths.get(at) == Some(w) {
    return
  }
  self.beside_widths[at] = w
  n.flex.style.set_width(Pt(w))
  n.flex.dirty = true
  // (laid out over the rest in what holds it, as the layout of all of it lays it out there: Tree::laid_over_alone)
  guard n.parent >= 0 else { return }
  let gen = self.laid_over_alone(at, n.parent)
  self.walk(at, gen, true)
  // (another size: what follows sizes told, and what is pointed at worked out again by its new box, as after any
  // layout)
  self.sizes_due = true
  self.hits_bump()
}

///|
/// What goes beside another as wide as it (BesideWidth's Anchor), in a layout read before it is placed (Tree::
/// measured_now): each made as wide as its anchor is laid out in it, where it was not already, and laid out alone so in
/// what holds it (what it holds broken into lines again, as tall as that makes it), nothing placed: placed by that
/// layout as the rest of it is (Tree's alone_laid, walked as the frame places what was laid out), where Tree::
/// besides_placed finds it as wide already. So where it goes and how big it is, read of that layout (View::
/// laid_window_now), is what the frame places it at, its height too.
fn Tree::besides_widened_now(self : Tree) -> Unit {
  for at in self.besides_at {
    let n = self.nodes[at]
    guard n.live && n.beside is Some(b) && b.width == Anchor && n.parent >= 0 && self.held_from_root(at) else { continue }
    guard self.alive_id(b.anchor) && self.held_from_root(b.anchor.at) && !self.leaving_at(at) && !self.out_at(b.anchor.at) && !self.leaving_at(b.anchor.at) else {
      continue
    }
    let w = self.nodes[b.anchor.at].flex.width
    if self.beside_widths.get(at) == Some(w) {
      continue
    }
    self.beside_widths[at] = w
    n.flex.style.set_width(Pt(w))
    n.flex.dirty = true
    let gen = self.laid_over_alone(at, n.parent)
    self.alone_laid.push((at, gen))
    self.sizes_due = true
  }
}

///|
/// Node `at` beside another anchor now (`own`: as wide as what it holds again): the width it was made as wide as its
/// anchor no longer kept, made again by the next (its own again where `own`, laid out so as anything said of it is).
/// Nothing where it was never made so.
fn Tree::beside_narrowed(self : Tree, at : Int, own : Bool) -> Unit {
  guard self.beside_widths.contains(at) else { return }
  self.beside_widths.remove(at)
  if own {
    self.nodes[at].flex.style.set_width(Auto)
  }
}

///|
/// Where node `at` is drawn in the window as the tree is placed now and how big (Tree::projected), none where it is no
/// live node.
fn Tree::window_place(self : Tree, at : Int) -> (Double, Double, Double)? {
  if at < 0 || at >= self.nodes.length() || !self.nodes[at].live {
    return None
  }
  let (x, y, _, s) = self.projected(at)
  Some((x, y, s))
}

///|
/// It let go as `owner` is, wherever it is held (what is drawn elsewhere for another, a tip in a layer over all of the
/// window for the control it tells of: its scope the other's, nothing of it left once that one goes); laid out nowhere
/// (none of it drawn, pressed or read out) from the moment `owner` starts leaving (View::on_leaving), at once, back as
/// that comes back (View::come_back). It.
pub fn View::lives_with(self : View, owner : View) -> View {
  let hidden = @signals.signal(false, same=fn(a, b) { a == b })
  // (bound in its own scope, not in what is being made where it is said (its owner's, perhaps): at rest with that as
  // that leaves, it would be told nothing)
  self.owning(fn() { self.laid_nowhere(By(fn() { hidden.get() })) |> ignore })
  owner.on_leaving(fn() { hidden.set(true) }) |> ignore
  owner.on_back(fn() { hidden.set(false) }) |> ignore
  owner.owns(fn() {
    guard self.live() is Some(_) else { return }
    match self.parent() {
      Some(p) => p.drop(self)
      None => self.let_go()
    }
  })
  |> ignore
  self
}

///|
/// About which point of it a node is drawn bigger or smaller (View::scale): `At` shares of its width and height (0.5,
/// 0.5: its middle); `FromBeside` the edge of it toward what it goes beside (View::beside), on the side it went on as
/// it was last placed (the side it was said to go on before), where along it it is lined up: grown out of its anchor,
/// as a popover grows from what opened it (kit's grown_from). Not beside anything: its middle. `Drawn` the middle of what
/// it and what it holds draw, as they are laid out (the boxes of those with a ground, words, shapes, lines, a picture or
/// an old view of their own): what is grown and shrunk where it is, not about a page's width (a room opening on a line
/// to one side: reveal's, an old view's Ctx::held_look). `DrawnSide(y)`: across, the side what it and what it holds
/// draw (Drawn's, words drawn alone as their lines are laid out) is laid from: its start, its end, or its middle where it
/// is centred (Tree::pivot_of); down, `y` of its height (0: its top): what a block on its way down a column is drawn at
/// as big as it shows, all of it within what shows of it (a page's list's key, View::scrolls_window), a reply growing
/// from its start, one's own bubble from its end, never a line moving sideways to its place.
#derive(Eq, Debug)
pub(all) enum Pivot {
  At(Double, Double)
  FromBeside
  Drawn
  DrawnSide(Double)
}

///|
/// Whether it is about what is drawn, across or both ways (Drawn, DrawnSide): worked out again as that
/// changes.
fn Pivot::drawn(self : Pivot) -> Bool {
  match self {
    Drawn | DrawnSide(_) => true
    _ => false
  }
}

///|
/// How big `self` is placed (`ls`), laid out `w` by `h` about `(px, py)`: where `scale_shift` caps how far its farthest
/// corner may stand off its laid-out place, a wider swing (`scale_peak`) is narrowed in proportion so the whole way in
/// and out keeps its ease without standing still at the cap. Its swing in (0.97 to 1 and back to 0.97) is its widest
/// from its first frame, so all of the way in and out is narrowed alike; one going smaller from 1 with no way in has
/// its widest grow as it goes, held at the cap from `most / far` on. Grown inside a list's block (`flip_in`): as it says.
fn Node::scaled_at(self : Node, w : Double, h : Double, px : Double, py : Double) -> Double {
  let (_, _, fo, _) = self.flip_in
  let s = self.look.scale * fo
  let most = self.look.scale_shift
  if most > 0.0 && fo == 1.0 && s != 1.0 {
    let far = dmax(dmax(px, w - px), dmax(py, h - py))
    let peak = dmax(self.look.scale_peak, (s - 1.0).abs())
    if far > 0.0 && far * peak > most {
      return 1.0 + (s - 1.0) * (most / (far * peak))
    }
  }
  s
}

///|
/// Where node `self` is drawn bigger or smaller about, in points where it is its own, laid out `w` by `h`.
fn Node::pivot_at(self : Node, w : Double, h : Double) -> (Double, Double) {
  // (matched one after the other, no pair made: asked of every node drawn turned or scaled, each frame)
  match self.look.pivot {
    At(x, y) => (x * w, y * h)
    Drawn => (0.5 * w, 0.5 * h)
    DrawnSide(y) => (0.5 * w, y * h)
    FromBeside =>
      match self.beside {
        None => (0.5 * w, 0.5 * h)
        Some(b) => {
          let across = match b.along {
            Start => 0.0
            Middle => 0.5
            End => 1.0
          }
          let side = match self.went {
            Some(s) => s
            None => b.side
          }
          match side {
            Bottom => (across * w, 0.0)
            Top => (across * w, h)
            Right => (0.0, across * h)
            Left => (w, across * h)
          }
        }
      }
  }
}

///|
/// How big node `id` is drawn, its scale and its holders' (View::scale; 1: as laid out, or no live node): what its own
/// terms are worth in the window's (Tree::projected).
pub fn Tree::drawn_scale(self : Tree, id : NodeId) -> Double {
  if self.alive_id(id) {
    self.projected(id.at).3
  } else {
    1.0
  }
}

///|
/// How big it is drawn (Tree::drawn_scale's).
pub fn View::drawn_scale(self : View) -> Double {
  self.tree.drawn_scale(self.id())
}

///|
/// A finger or a button went down in the window at `at`, wherever it lands (the host's, before it goes to
/// what takes it): one change at that moment, told to what follows the window's presses (View::window_downs).
pub fn Tree::went_down(self : Tree, at : Double, x? : Double = -1.0, y? : Double = -1.0) -> Unit {
  self.event(at, fn() {
    let (count, _, _) = self.pressed_anywhere.untracked()
    self.pressed_anywhere.set((count + 1, x, y))
    self.held_anywhere.set(true)
  })
}

///|
/// What went down in the window let go (or called off) at `at`, wherever it is: nothing held anywhere from then, told to
/// what follows it (View::window_held).
pub fn Tree::went_up(self : Tree, at : Double) -> Unit {
  self.event(at, fn() { self.held_anywhere.set(false) })
}

///|
/// Whether a finger or a button is down anywhere in the window now (an old view's `c.press().down`), followed: what
/// waits for the hand to carry no press (a hover card opens only on a pointer carrying none, from when it was let go).
pub fn View::window_held(self : View) -> Bool {
  self.tree.held_anywhere.get()
}

///|
/// How many times a finger or a button has gone down anywhere in the window (Tree::went_down), followed: what closes at
/// the next press, wherever it lands (a tip a finger held open, once let go).
pub fn View::window_downs(self : View) -> Int {
  self.tree.pressed_anywhere.get().0
}

///|
/// Where the most recent window press went down, in window coordinates, as the host told it.
pub fn View::window_down_point(self : View) -> (Double, Double) {
  let (_, x, y) = self.tree.pressed_anywhere.get()
  (x, y)
}

///|
/// A tap in the window at `at`, wherever it landed (the host's, as the old frame's Ctx::tapped_anywhere has one: a
/// press let go without dragging, not taken by what it went down on), told after what it landed on took it: one change
/// at that moment, told to what follows the window's taps (View::window_taps).
pub fn Tree::tapped(self : Tree, at : Double) -> Unit {
  self.event(at, fn() { self.tapped_anywhere.set(self.tapped_anywhere.untracked() + 1) })
}

///|
/// Whether a gesture's finger let go since this was last asked was its tap (View::gesture's: not moved past its slop,
/// not held, not called off), as what took it said it; asked, none since: the host's, to tell the window's taps by
/// (Tree::tapped).
pub fn Tree::gesture_tap_taken(self : Tree) -> Bool {
  let was = self.gesture_tapped
  self.gesture_tapped = false
  was
}

///|
/// How many taps there have been anywhere in the window (Tree::tapped), followed: what a tap anywhere lets go of (a tip
/// a finger tapped open).
pub fn View::window_taps(self : View) -> Int {
  self.tree.tapped_anywhere.get()
}


///|
/// Whether what a finger or a button at (`x`, `y`) of the window is for, as the tree is now, is this node (Tree::target_at:
/// the topmost drawn there that takes it, by the one projection): where a press let go lands, its own or another's.
pub fn View::finger_target(self : View, x : Double, y : Double) -> Bool {
  self.finger_target_id(x, y) == Some(self.id())
}

///|
/// The node that takes a finger at this window position, if it is a press or drag target.
pub fn View::finger_target_id(self : View, x : Double, y : Double) -> NodeId? {
  match self.tree.target_at(x, y) {
    Pressed(id) | Dragged(id) => Some(id)
    _ => None
  }
}

///|
/// What its words measure and how they are drawn changed for all of them (the system's size of words, how the theme
/// shapes them): every node with words laid out and drawn again.
pub fn Tree::words_again(self : Tree) -> Unit {
  // (told as a room is laid out (the system's size of words asked of the host as words are measured in it between
  // frames, a Tester's set before): every node marked once all of it is laid out, a change of its own then, as what is
  // marked outside a room is; the room's own node marked in its own layout would be a fault)
  if self.rooming >= 0 {
    self.once_laid_out(fn() { self.words_again() })
    return
  }
  // (what shows words, and what is measured as what it hosts is: View::measured)
  for at, n in self.nodes {
    if n.live && (n.look.words != "" || n.flex.measure is Some(_)) {
      self.layout_marked_at(at)
      self.look_marked_at(at)
      // (cut short: what of them is kept, at their size now)
      self.cut_applied(at)
    }
  }
  self.words_redone.set(self.words_redone.untracked() + 1)
}

///|
/// Surgically mark only nodes referencing preview/try `face` for relayout and repaint, without incrementing global
/// `words_redone` (preserving offscreen height caches of unrelated virtual lists).
pub fn Tree::words_again_for_face(self : Tree, face : Int) -> Unit {
  if self.rooming >= 0 {
    self.once_laid_out(fn() { self.words_again_for_face(face) })
    return
  }
  for at, n in self.nodes {
    if !n.live {
      continue
    }
    let rl = n.look.runs_look
    let mut hit = false
    match rl.cjk {
      Some(ov) if ov.face == face => hit = true
      _ => ()
    }
    if !hit {
      match rl.code_cjk {
        Some(ov) if ov.face == face => hit = true
        _ => ()
      }
    }
    if !hit {
      for run in n.look.runs {
        if run.face == Some(face) {
          hit = true
          break
        }
      }
    }
    if hit {
      self.layout_marked_at(at)
      self.look_marked_at(at)
      self.cut_applied(at)
    }
  }
  if face >= 0 && face < self.face_redone.length() {
    let sig = self.face_redone[face]
    sig.set(sig.untracked() + 1)
  }
}

///|
/// How many times all its words were measured anew (Tree::words_again), followed: what is laid out by how wide its words
/// are and keeps something of it (a bar never narrower once open) says it again as they change.
pub fn View::words_redone(self : View) -> Int {
  self.tree.words_redone.get()
}

///|
/// What it draws called by name, as it changes (an icon's: "/icon/copy/", as an old view's icon is called), for what
/// finds things on screen by what they show (a test's, a scripted run's: Tester::locate's icon:NAME); drawn and read
/// out as ever.
#callsite(autofill(loc))
pub fn View::drawn_as(self : View, name : Live[String], loc~ : SourceLoc) -> View {
  self.bind(loc~, DrawnAs, name, Said, fn(s) { self.tree.nodes[self.at].look.drawn_as = s })
  self
}

///|
/// What node `id` draws called by name (View::drawn_as; "" none, or no live node).
pub fn Tree::drawn_name(self : Tree, id : NodeId) -> String {
  if self.alive_id(id) {
    self.nodes[id.at].look.drawn_as
  } else {
    ""
  }
}


///|
/// It laid out never narrower than it has been (a bar never narrower once open, as what it holds gives way or goes):
/// at each change of what `by` reads (what sets how wide it is laid out: its words, what it holds, the room, the
/// theme, the size of words), how wide it is laid out as of that change's own moment (View::laid_size), kept as its
/// least width, no more than `most` says it may be as that changes. Whatever frames are drawn between two changes, the
/// same: what is kept is what each change laid it out at, never what a frame happened to see.
#callsite(autofill(loc))
pub fn[T : Eq] View::keeps_width(
  self : View,
  by : () -> T,
  most? : () -> Double = fn() { @double.infinity },
  loc~ : SourceLoc,
) -> View {
  let widest : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })
  self.min_width(loc~,
    By(fn() {
      let w = widest.get()
      let m = most()
      if w <= 0.0 {
        None
      } else if w < m {
        Some(w)
      } else {
        Some(m)
      }
    }),
  )
  |> ignore
  // (the window's size among them: its first frame's too, the first it is laid out in)
  // (measured once for each change, once it is told whole: what else it tells made and set first (a node shown in it,
  // its words said again, told after this), whether a frame is drawn after it or not)
  let asked = Ref(false)
  self.reacts(fn() { (by(), self.window()) }, fn(_) {
    if asked.val {
      return
    }
    asked.val = true
    @signals.after_flush(fn() {
      asked.val = false
      // (laid out as of the change's moment, all it told counted: the layout's own, read and not placed by,
      // Tree::measured_now)
      guard self.live() is Some(n) else { return }
      self.tree.measured_now()
      let w = n.flex.width
      if w > widest.untracked() {
        widest.set(w)
      }
    })
  })
  self
}
