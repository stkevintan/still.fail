// A way sets out only for its cause (the user, 2026-11-18: 显式因果底座). Where a part of the tree says it moves only
// for a cause said (View::transitions_only, on its root: what it holds with it), what changes there is at once, Δt 0,
// unless the change is told inside `transition` (a person's act in a handler, a live cause a page has judged so): what
// comes or goes there then makes its way in or closes it, what is declared to resize goes its way, what moves for a
// cause moves (@motion.moves_for), as anywhere else. Outside one, what it makes or lets go is there or gone at once and
// marked as an answer's change is (Tree::answer_mark), so what judges how things move takes it as such. What is not so
// said goes as it always has: an answer's change at once (answering.mbt), any other's on its way.
//
// A transition told inside a change being committed (a handler run by Tree::event, a watch run by a flush, an outer
// batch) is held till that change is told whole, as an answer told there is (answer_held): what that flush runs is
// the transition's. `within`: only what is in that node is the transition's; none, all of it.

///|
/// How deep in `transition` it is now, the nodes each was said within (-1: none said, all of the tree), and those of
/// one told inside a change being committed, held till it is told whole.
// kept across runs: counted up and down around each transition
let transition_depth : Ref[Int] = Ref(0)

///|
// kept across runs: pushed and popped around each transition
let transition_scopes : Array[Int] = []

///|
// kept across runs: held while a change a transition was told in is told, let go of once it is
let transition_held : Ref[Array[Int]] = Ref([])

///|
/// `f`, a cause's change (a person's act, a live cause a page judged so): what it changes in a part of the tree said to
/// move only for a cause (View::transitions_only) makes its way there, as anywhere else. `within`: only in that node.
pub fn transition(f : () -> Unit, within? : View) -> Unit {
  transition_run(
    match within {
      Some(v) => v.at
      None => -1
    },
    f,
  )
}

///|
/// `transition`'s work, the node it is within by its index (-1: none said): one body for every caller.
fn transition_run(scope_at : Int, f : () -> Unit) -> Unit {
  if transition_depth.val == 0 {
    match active_event_tree.val {
      Some(t) if t.batch_owed_at >= 0.0 => {
        let owed = t.batch_owed_at
        t.batch_owed_at = -1.0
        t.settle_now(owed)
      }
      _ => ()
    }
  }
  // (told inside a change, a flush or a batch: what its writes tell runs once that is told whole, after `f` is over;
  // held till then, the one entry this put let go of once it is)
  transition_held.val = transition_held.val + [scope_at]
  let let_go = fn() {
    let held = transition_held.val
    let mut i = held.length() - 1
    while i >= 0 && held[i] != scope_at {
      i = i - 1
    }
    if i >= 0 {
      let rest : Array[Int] = []
      for j, s in held {
        if j != i {
          rest.push(s)
        }
      }
      transition_held.val = rest
    }
  }
  // (let go of once what waits for the change to be told whole has run too, what a structure settles then (a page's
  // list's set-out, View::resizes' measure) the transition's still: last among what waits as it is let go)
  @signals.after_flush(fn() { @signals.after_flush(let_go) })
  transition_scopes.push(scope_at)
  transition_depth.val += 1
  @signals.start_batch()
  f()
  // (what it wrote told now where nothing holds it back, while it is still the transition's: below, as it is over)
  @signals.end_batch_in_turn()
  transition_depth.val -= 1
  transition_scopes.pop() |> ignore
}

///|
/// Whether a transition is being told now (`transition`, or a change it was told in, held till told whole).
pub fn transition_now() -> Bool {
  transition_depth.val > 0 || transition_held.val.length() > 0
}

///|
/// Whether a transition's marks are left set: never, once what told it is over (answer_marks_left).
fn transition_marks_left() -> Bool {
  transition_depth.val > 0 || transition_scopes.length() > 0 || transition_held.val.length() > 0
}

///|
/// This node and all it holds move only for a cause said (`transition`): what changes there outside one is at once.
pub fn View::transitions_only(self : View) -> View {
  guard self.live() is Some(n) else { return self }
  if !n.transitions_only {
    n.transitions_only = true
    self.tree.transitions_only_set += 1
  }
  self
}

///|
/// The part of the tree this node moves with for a cause said: the nearest node holding it (itself too) said to move
/// only for one (View::transitions_only), else the tree's root. A cause judged in a part of it (a card decided in a
/// chat's list) is told within that (`transition`'s `within`), so what the change moves round it goes its way too.
pub fn View::transitions_root(self : View) -> View {
  guard self.live() is Some(_) else { return self }
  let mut i = self.at
  let mut steps = 0
  while i >= 0 && i < self.tree.nodes.length() && steps < 256 {
    if self.tree.nodes[i].transitions_only {
      return self.tree.handle(i)
    }
    if self.tree.nodes[i].parent < 0 {
      return self.tree.handle(i)
    }
    i = self.tree.nodes[i].parent
    steps = steps + 1
  }
  self
}

///|
/// Whether what changes in this node now makes its way (Tree::allows_transition).
pub fn View::allows_transition(self : View) -> Bool {
  guard self.live() is Some(_) else { return false }
  self.tree.allows_transition(self.at)
}

///|
/// Whether node `at` or one holding it is said to move only for a cause (View::transitions_only).
fn Tree::transitions_only_at(self : Tree, at : Int) -> Bool {
  guard self.transitions_only_set > 0 else { return false }
  let mut i = at
  let mut steps = 0
  while i >= 0 && i < self.nodes.length() && steps < 256 {
    if self.nodes[i].transitions_only {
      return true
    }
    i = self.nodes[i].parent
    steps = steps + 1
  }
  false
}

///|
/// Whether node `at` is within a transition being told now (one said within it or a node holding it, or within none).
fn Tree::transition_holds(self : Tree, at : Int) -> Bool {
  // (a part said to move only for a cause is its own: a transition said within a node holding it reaches no further
  // in than that part's root (a chat's list's live cause does not move its composer, a part of its own in the list's
  // foot); one said within it or in it, or within none, does)
  let within = fn(s : Int) {
    if s < 0 {
      return true
    }
    let mut i = at
    let mut steps = 0
    while i >= 0 && i < self.nodes.length() && steps < 256 {
      if i == s {
        return true
      }
      if self.nodes[i].transitions_only {
        return false
      }
      i = self.nodes[i].parent
      steps = steps + 1
    }
    false
  }
  if transition_depth.val > 0 && transition_scopes.iter().any(within) {
    return true
  }
  transition_held.val.iter().any(within)
}

///|
/// Whether what changes in node `at` now may make its way as far as transitions go: where it is said to move only for
/// a cause, only within a transition told now; elsewhere always (what else holds a way back is each one's own).
fn Tree::transition_gate(self : Tree, at : Int) -> Bool {
  !self.transitions_only_at(at) || self.transition_holds(at)
}

///|
/// Whether what changes in node `at` now makes its way: not as an answer is told (answering.mbt), and where it is said
/// to move only for a cause, only within a transition told now.
pub fn Tree::allows_transition(self : Tree, at : Int) -> Bool {
  if answered.val || self.answer_holds(at) || answering_now() {
    return false
  }
  self.transition_gate(at)
}

///|
/// Whether what changes in this node now may make its way as far as transitions go (Tree::transition_gate): not where
/// it is said to move only for a cause and no transition holds it; what holds an answer's change back is each one's.
pub fn View::transition_gate(self : View) -> Bool {
  guard self.live() is Some(_) else { return false }
  self.tree.transition_gate(self.at)
}

///|
/// The transitions told now, as the nodes each was said within (none where none is told): what a structure marked by
/// a write now keeps, to be done in them as it is next run (Tree::structured_by), whenever that is.
fn transition_marked() -> Array[Int] {
  if transition_depth.val > 0 {
    transition_scopes + transition_held.val
  } else if transition_held.val.length() > 0 {
    transition_held.val.copy()
  } else {
    []
  }
}

///|
/// `f` done within the transitions `scopes` (kept as what it reads was marked: transition_marked), as when they were
/// told; none, as it is.
fn transition_again(scopes : Array[Int], f : () -> Unit) -> Unit {
  if scopes.is_empty() {
    f()
    return
  }
  for s in scopes {
    transition_scopes.push(s)
  }
  transition_depth.val += 1
  f()
  transition_depth.val -= 1
  for _ in scopes {
    transition_scopes.pop() |> ignore
  }
}
