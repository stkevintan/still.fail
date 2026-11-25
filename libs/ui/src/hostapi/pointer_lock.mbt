///|
/// The pointer held by the window (`on`) or let go of: held, the system's pointer is hidden and stays where it is, the
/// mouse's moves come as moves where it stays, how far each went taken by pointer_delta_take (a game's view turned by
/// the mouse with no edge to stop it). The host lets go of it by itself as the window goes out of focus (or the app out
/// of the front); a host with nothing for it holds nothing.
pub fn set_pointer_lock(on : Bool) -> Unit {
  (current.val.pointer_lock)(on)
}

///|
/// Whether the window holds the pointer now (set_pointer_lock; let go of by the host as the window went out of focus).
pub fn pointer_locked() -> Bool {
  (current.val.pointer_locked)()
}

///|
/// How far the mouse moved (across, down, as a browser's `movementX`/`movementY` there: points on macOS, the mouse's
/// own counts on Windows) since this was last
/// asked, while the pointer is held (set_pointer_lock); taken, so the next asks from now. (0, 0) where it is not held.
pub fn pointer_delta_take() -> (Double, Double) {
  let out : FixedArray[Double] = FixedArray::make(2, 0.0)
  (current.val.pointer_delta)(out)
  (out[0], out[1])
}

///|
/// The most game controllers a host says (gamepads).
pub let gamepads_most : Int = 4

///|
/// The numbers of each controller a host writes (gamepads): its slot, connected (1) or not, its buttons, its sticks
/// across and down, its triggers.
pub let gamepad_fields : Int = 9

///|
/// How far a stick moves before it counts (a controller at rest drifts this far): as a browser's are read.
pub let gamepad_dead_zone : Double = 0.06

///|
/// A game controller as the host reads it now: its slot (0..3), its buttons as the W3C Standard Gamepad's 17 bits (0
/// A, 1 B, 2 X, 3 Y, 4 LB, 5 RB, 6 LT, 7 RT, 8 back, 9 start, 10 L3, 11 R3, 12–15 the pad up, down, left, right, 16
/// home), its sticks past the dead zone (-1..1, down positive as the Standard Gamepad's), its triggers (0..1).
#derive(Eq, Debug)
pub(all) struct Gamepad {
  index : Int
  buttons : Int
  lx : Double
  ly : Double
  rx : Double
  ry : Double
  lt : Double
  rt : Double
}

///|
/// A stick's axis past the dead zone (gamepad_dead_zone), within -1..1: 0 inside it.
pub fn gamepad_axis(a : Double) -> Double {
  if a.is_nan() || a.abs() <= gamepad_dead_zone {
    0.0
  } else if a > 1.0 {
    1.0
  } else if a < -1.0 {
    -1.0
  } else {
    a
  }
}

///|
fn gamepad_trigger(v : Double) -> Double {
  if v.is_nan() || v < 0.0 {
    0.0
  } else if v > 1.0 {
    1.0
  } else {
    v
  }
}

///|
/// The game controllers connected now, by slot (none where the host reads none).
pub fn gamepads() -> Array[Gamepad] {
  let out : FixedArray[Double] = FixedArray::make(gamepads_most * gamepad_fields, 0.0)
  let n = (current.val.gamepads)(out)
  let pads : Array[Gamepad] = []
  for i in 0..<(if n < gamepads_most { n } else { gamepads_most }) {
    let o = i * gamepad_fields
    if out[o + 1] != 0.0 {
      pads.push({
        index: out[o].to_int(),
        buttons: out[o + 2].to_int() & 0x1FFFF,
        lx: gamepad_axis(out[o + 3]),
        ly: gamepad_axis(out[o + 4]),
        rx: gamepad_axis(out[o + 5]),
        ry: gamepad_axis(out[o + 6]),
        lt: gamepad_trigger(out[o + 7]),
        rt: gamepad_trigger(out[o + 8]),
      })
    }
  }
  pads
}
