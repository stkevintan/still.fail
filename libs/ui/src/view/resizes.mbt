// A height change declared makes its way (View::resizes): said on a node in a handler, its coming out another height
// in the change that handler commits is for that change's cause. From as tall as it was laid out last (or as tall as
// its way had it then, on a way already: its place and speed going on) to as tall as it comes out, that change's
// layout's to say, as what comes is (View::comes, from as tall as one in its place was, to all of it): one member of
// its column's one way (flex's ComeGroup, Tree::come_group_join), in a page's list's foot the list's; alone, as its
// spec says, else a Move by how far. Come out the same height, nothing, nothing kept: the declaration is of that one
// commit, dropped by the change's layout whatever came of it. Not declared, a height change is at once, as ever. What
// it holds is laid out at the size it comes to from the start, shown through it as it goes; what draws a ground by how
// tall it shows is given that where it is drawn (View::shown_by).

///|
/// In the change the handler it is said in commits, this node coming out another height is for that change's cause:
/// its way from as tall as it was to as tall as it comes out (`spec`: how long, ms, and on what curve, the share of the
/// way gone for the share of its time gone; none, a Move by how far; in a group with others, the group's). Nothing
/// where it comes out the same height, nor in a change that lays nothing of it out: nothing kept after it. `foot`:
/// what it holds keeps to its foot all the way, its bottom the node's bottom, cut at the node's top (a composer that
/// grows from its foot, the messages over it going up with it as one: the owner's 2026-10-30, 「以底部为 origin」);
/// else to its top, cut at its foot, as ever. Said of a node whose height can make no way where it is (grown, over what
/// holds it, or not laid out in its turn down a column nor along a row its structure said so: Tree::makes_way), it is
/// a fault (resizes_never_said), said with `loc`, the line that said it: it would only ever change at once.
#callsite(autofill(loc))
pub fn View::resizes(
  self : View,
  spec? : (Double, (Double) -> Double),
  foot? : Bool = false,
  uncut? : Bool = false,
  open_top? : Bool = false,
  loc~ : SourceLoc,
) -> View {
  guard self.live() is Some(n) else { return self }
  let tree = self.tree
  match tree.resizes_never_said(self.at, loc) {
    // (no boundary's: what it does is only whether a height goes its way, nothing to show another part for)
    Some(said) => {
      fault(said)
      return self
    }
    None => ()
  }
  let st = n.flex.style
  // (as tall as last actually placed on screen (n.lh), avoiding mid-flush Tree::measured_now() temporary layout
  // pollution before sibling structural updates; unplaced nodes fall back to n.flex.height)
  let from = if n.placed { n.lh } else { n.flex.height }
  // (its way and its foot said with it: told outside a change, what comes is measured and its end fixed in
  // View::comes itself)
  guard self.comes(self, from, 1.0, spec?, foot~, uncut~, open_top~) else { return self }
  let at = st.come_at
  // (in a page's list's foot on no way said: what a flight that carries a key in at this moment rises by, if one does
  // (Tree::feet_carried); those of another moment forgotten as one is said)
  if foot && spec is None && tree.list_of(self.at) != self.at {
    let resized = tree.motion_aux().feet_resized
    let gone = resized.iter().filter(fn(e) { e.1 != at }).map(fn(e) { e.0 }).to_array()
    for g in gone {
      resized.remove(g)
    }
    resized[self.at] = at
  }
  // (once the change is told whole and laid out (View::comes' wait, which measures it, and its column's group then):
  // come out as tall as it was, from rest, nothing of it goes)
  @signals.after_flush(fn() {
    @signals.after_flush(fn() {
      guard self.live() is Some(m) && m.coming && st.come_at == at else { return }
      if st.come_v == 0.0 && st.come_goal == st.come_goal && (st.come_goal - st.come_from).abs() < 1.0e-9 {
        (m.come_off)()
        come_done(tree, self, m)
      }
    })
  })
  self
}

///|
/// What draws this node's ground given, where it is drawn, how tall node `of` (this one or one holding it) shows then,
/// on its way or at rest (its height as it is laid out at that frame): `f` given that height, its ground as it draws it
/// (GroundShape, View::ground_drawn's), worked out again at each frame `of` is laid out on its way, nothing of it read
/// by a build. Till this node goes.
pub fn View::shown_by(self : View, of : View, f : (Double) -> GroundShape) -> View {
  guard self.live() is Some(_) && of.live() is Some(_) else { return self }
  let tree = self.tree
  let me = self.at
  let them = of.at
  tree.shown_bys[me] = (of.id(), f)
  let fs = match tree.shown_followers.get(them) {
    Some(fs) => fs
    None => {
      let fs = []
      tree.shown_followers[them] = fs
      fs
    }
  }
  fs.push(me)
  self.owns(fn() {
    tree.shown_bys.remove(me)
    match tree.shown_followers.get(them) {
      Some(fs) => {
        let left = fs.filter(fn(f) { f != me })
        if left.is_empty() {
          tree.shown_followers.remove(them)
        } else {
          fs.clear()
          fs.append(left)
        }
      }
      None => ()
    }
  })
  |> ignore
  tree.place_marked_at(me)
  self
}

///|
/// What draws this node's ground (View::shown_by) worked out of where the boxes node `of` lays out are drawn (past any
/// slot: a page's list's blocks, its spacers), drawn again as any of them is placed or drawn off anew (moved by its
/// layout, by a way it is drawn off on: a list's `flips`), so what it draws goes with them in every frame they go,
/// never where they were last told to rest. Till this node goes.
pub fn View::ground_by_placed(self : View, of : View) -> View {
  guard self.live() is Some(_) && of.live() is Some(_) else { return self }
  let tree = self.tree
  let me = self.at
  let them = of.at
  let fs = match tree.placed_followers.get(them) {
    Some(fs) => fs
    None => {
      let fs = []
      tree.placed_followers[them] = fs
      fs
    }
  }
  fs.push(me)
  self.owns(fn() {
    match tree.placed_followers.get(them) {
      Some(fs) => {
        let left = fs.filter(fn(f) { f != me })
        if left.is_empty() {
          tree.placed_followers.remove(them)
        } else {
          fs.clear()
          fs.append(left)
        }
      }
      None => ()
    }
  })
  |> ignore
  self
}

///|
/// Node `at` placed: what draws its ground by where the boxes beside it are drawn (View::ground_by_placed, of the box
/// that lays it out, past any slot) drawn again, its ground alone, no place of it moved (as Tree::flip_in_by's ground).
fn Tree::placed_told(self : Tree, at : Int) -> Unit {
  let mut h = self.nodes[at].parent
  while h >= 0 && self.nodes[h].slot {
    h = self.nodes[h].parent
  }
  guard h >= 0 && self.placed_followers.get(h) is Some(fs) else { return }
  for f in fs {
    if f != at && self.nodes[f].live {
      self.places_rev = self.places_rev + 1
      self.touched(f, words=false)
      self.composed.push({ at: f, gen: self.nodes[f].gen })
    }
  }
}

///|
/// Whether what node `id` holds keeps to its foot now, its height on a way said so (View::resizes `foot`): an old view
/// hosted in it is placed from its foot, cut at its top, as a node's children are (flex's come_keep_foot).
pub fn Tree::holds_to_foot(self : Tree, id : NodeId) -> Bool {
  guard self.alive_id(id) else { return false }
  let n = self.nodes[id.at]
  n.coming && n.flex.style.come_foot
}

///|
/// Why node `at`'s height said to make its way (View::resizes, at `loc`) never can where it is, said; None where it can,
/// or where it is not known yet (the tree never laid out). Only what its place in the tree decides, whatever the moment:
/// reduced motion, an answer's change or a height that comes out the same are no fault (they do it at once, or nothing,
/// as asked), being grown, over what holds it, or laid out by a row it makes no way along is.
fn Tree::resizes_never_said(self : Tree, at : Int, loc : SourceLoc) -> String? {
  if self.last_w < 0.0 || self.makes_way(at) {
    return None
  }
  let n = self.nodes[at]
  let st = n.flex.style
  let why = if st.position == @flex.PositionType::Absolute {
    "it is over what holds it (absolute), no turn of its own down a column"
  } else if st.grow > 0.0 {
    "it is grown (grow \{st.grow}): as tall as what holds it leaves it, never as tall as it comes out"
  } else {
    let mut p = n.parent
    while p >= 0 && self.nodes[p].slot {
      p = self.nodes[p].parent
    }
    if p < 0 {
      "it is held by nothing that lays it out"
    } else {
      "what lays it out is a row, which it makes no way along (no structure of the row said so: View::comes)"
    }
  }
  let (made, part) = self.source_of({ at, gen: n.gen })
  let made_said = if made == "" {
    ""
  } else if part != "" {
    ", the node made at \{made} (in \{part})"
  } else {
    ", the node made at \{made}"
  }
  Some(
    "View::resizes said at \{source_place(loc)} of a node whose height can make no way: \{why}\{made_said}; its height changes at once",
  )
}

///|
/// How tall it is at the moment of the change under way and how fast its height goes then (points a ms): where its way
/// has it (flex's come_state), on one; else as it was placed last, still. Nothing is laid out for it: what a part sets off
/// from as it lets go of a way its height is on (a composer's ground held as tall as it was, going on as fast).
pub fn View::height_going_now(self : View) -> (Double, Double) {
  guard self.live() is Some(n) else { return (0.0, 0.0) }
  match (n.coming, @flex.come_state(n.flex.style, self.tree.cause_now())) {
    (true, Some((tall, speed))) => (tall, speed)
    _ => (n.lh, 0.0)
  }
}

///|
/// Share `[0.0, 1.0]` of `item`'s laid-out height currently covered by `self`'s animating height (`View::comes` /
/// `View::resizes`), read at draw time without laying out: `1.0` at rest or when `self` already covers `item`.
pub fn View::come_share_of(self : View, item : View) -> Double {
  guard self.live() is Some(m) && item.live() is Some(it) else { return 1.0 }
  let said = match m.come_said {
    Some(s) => s
    None => {
      let s = @signals.signal(0)
      m.come_said = Some(s)
      s
    }
  }
  said.get() |> ignore
  if !m.coming {
    return 1.0
  }
  let st = m.flex.style
  let whole = st.come_whole
  let ends = st.come_ends
  if whole != whole || ends != ends {
    return 0.0
  }
  let t = item.drawn_while(fn(now) { now < ends })
  let at = if t == @double.infinity { ends } else { t }
  let shown_h = @flex.come_tall_at(st, whole, at)
  let mut rel_y = 0.0
  let mut cur = item.at
  let mut found = false
  while cur >= 0 {
    if cur == self.at {
      found = true
      break
    }
    let cn = self.tree.nodes[cur]
    if !cn.slot {
      rel_y = rel_y + cn.flex.top
    }
    cur = cn.parent
  }
  if !found || it.flex.height <= 0.5 {
    return 1.0
  }
  let hi = dmax(whole, st.come_from)
  let lo = dmin(whole, st.come_from)
  if rel_y + it.flex.height <= lo + 0.5 {
    return 1.0
  }
  let x = (shown_h - rel_y) / it.flex.height
  if x <= 0.0 {
    return 0.0
  }
  // When trailing padding makes `hi - rel_y > it.flex.height` (`r > 1`), cap `x` with a C1-tangent
  // parabola from `a = 2 - r` to `(r, 1.0)` so `scale * h <= shown_h - rel_y` everywhere and velocity
  // reaches 0 smoothly at `shown_h = hi` instead of hard-clamping at `x = 1`.
  let r = (hi - rel_y) / it.flex.height
  if r <= 1.001 {
    dclamp(x, 0.0, 1.0)
  } else if x >= r {
    1.0
  } else if r >= 2.0 {
    let u = 1.0 - x / r
    1.0 - u * u
  } else {
    let a = 2.0 - r
    if x <= a {
      x
    } else {
      let d = r - x
      1.0 - d * d / (4.0 * (r - 1.0))
    }
  }
}
