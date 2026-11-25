///|
struct AlmostAtRest {
  rest : Double
  sampled : Array[Double]
  mover : @ui.Mover
}

///|
fn AlmostAtRest::rest_at(self : AlmostAtRest, _now : Double, _frame : Int) -> Double {
  self.rest
}

///|
fn AlmostAtRest::sample(self : AlmostAtRest, now : Double) -> Unit {
  self.sampled.push(now)
}

///|
/// What moves, as Ctx::moving is told it (Moving).
fn AlmostAtRest::as_moving(self : AlmostAtRest) -> @ui.Moving {
  @ui.Moving::new(fn(now, frame) { self.rest_at(now, frame) }, sample=fn(now) { self.sample(now) })
}

///|
test "a flow ends when a motion's rest is a rounding hair past its frame" {
  let before = 2366.6666666666665
  let rest = 2366.666666666667
  let t = @ui.Tester::new(fn(c) { c.box(w=Px(10.0), h=Px(10.0), fn() {  }) |> ignore })
  t.frame_at(before)
  t.set_frame_period(1000.0 / 60.0)
  let way : AlmostAtRest = { rest, sampled: [], mover: @ui.Mover::new() }
  t.ctx().set_out(way.mover, way.as_moving(), what="almost at rest") |> ignore
  assert_true(t.rest_of("") > t.time())
  assert_true(t.rest_of("") - t.time() < 1.0e-9)
  let f : Flow = {
    r: @core.Replay::parse(""),
    t,
    strict: false,
    said: [],
    one_by_one: Ref(false),
    at_step: [],
    followed: Ref(""),
    follow_ys: [],
  }
  f.end() |> ignore
  assert_true(t.time() >= rest)
  assert_true(way.sampled.iter().any(fn(at) { at >= rest }))
  t.assert_idle()
}
