// Regression: dragging/tapping the 液态玻璃 slider on 外观 updates @ui.glass_frost() immediately via
// optimistic prefs + app_looks_told before prefs.set RPC returns, and restores 0.0 at 0%.

///|
test "外观: 液态玻璃 slider updates @ui.glass_frost() optimistically before prefs.set RPC answers" {
  new_run()
  let base = fixture("settings")
  let held_rpc : Array[Json] = []
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "prefs.set" {
        held_rpc.push(params)
      } else {
        (base.call)(name, params, done)
      }
    },
  }
  app.nav.push(Settings)
  app.nav.push(Setting(Appearance))
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=1400.0, platform=2)
  t.draw()
  assert_true(@ui.glass_frost().abs() < 0.001, msg="initial frost must be 0.0, got \{@ui.glass_frost()}")
  let sl = t.get(Slider, label="液态玻璃")
  let (sx, sy, sw, sh) = sl.rect
  // Tap middle (~50%) while prefs.set RPC is held (unanswered)
  t.tap(sx + sw / 2.0, sy + sh / 2.0)
  t.draw()
  assert_true(!held_rpc.is_empty(), msg="expected prefs.set RPC to be sent")
  assert_true((@ui.glass_frost() - 0.5).abs() < 0.02, msg="optimistic frost must reach ~0.5 before RPC answers, got \{@ui.glass_frost()}")
  // Tap left end (0%) while prefs.set RPC is still held -> returns to 0.0 immediately
  t.tap(sx + 2.0, sy + sh / 2.0)
  t.draw()
  assert_true(@ui.glass_frost().abs() < 0.001, msg="optimistic frost must return to 0.0 before RPC answers, got \{@ui.glass_frost()}")
}
