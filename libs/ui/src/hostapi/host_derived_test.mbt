///|
test "retained Host derived defaults dispatch to self, never current host" {
  let prev = @hostapi.host()
  let a_req : Ref[Int] = Ref(0)
  let a_clip : Array[String] = []
  let a_frames : Array[(Int, Bytes, Int, Double)] = []
  let a_ptrs : Array[(Int, Bytes)] = []
  let b_calls : Ref[Int] = Ref(0)

  let host_a = {
    ..@hostapi.Host::noop(),
    window_corner: fn() { 12.0 },
    wall_ms: fn() { 1000.0 },
    now: fn() { 250.0 },
    request_frame: fn() { a_req.val = a_req.val + 1 },
    env: fn(k) { if k == "MBUI_AUTOSPACE" { "off" } else { "" } },
    clipboard_set: fn(text) { a_clip.push(text) },
    font_metrics: fn(_, _, _, out) { out[5] = 1.0 },
    st_frame: fn(id, data, key, ts) { a_frames.push((id, data, key, ts)) },
    st_pointer: fn(id, png, _, _, _, _) { a_ptrs.push((id, png)) },
  }

  let host_b = {
    ..@hostapi.Host::noop(),
    window_corner: fn() {
      b_calls.val = b_calls.val + 1
      99.0
    },
    wall_ms: fn() {
      b_calls.val = b_calls.val + 1
      5000.0
    },
    now: fn() {
      b_calls.val = b_calls.val + 1
      100.0
    },
    request_frame: fn() { b_calls.val = b_calls.val + 1 },
    env: fn(_) {
      b_calls.val = b_calls.val + 1
      ""
    },
    shape: fn(_, _, _, _, _) {
      b_calls.val = b_calls.val + 1
      0
    },
    clipboard_set: fn(_) { b_calls.val = b_calls.val + 1 },
    font_metrics: fn(_, _, _, out) {
      b_calls.val = b_calls.val + 1
      out[5] = 0.0
    },
    st_frame: fn(_, _, _, _) { b_calls.val = b_calls.val + 1 },
    st_pointer: fn(_, _, _, _, _, _) { b_calls.val = b_calls.val + 1 },
  }

  // Install host_b globally while invoking all 9 derived methods directly on retained host_a
  @hostapi.set_host(host_b)

  assert_eq(host_a.window_corner_at(1), 12.0)
  assert_eq(host_a.clock_at_wall(2000.0), 1250.0)
  host_a.request_frame_on()
  host_a.frames_paced(120.0)
  assert_eq(a_req.val, 2)
  assert_eq(host_a.words_spaced(), @hostapi.words_spaced_none)
  host_a.clipboard_set_html("plain", "<b>html</b>")
  assert_eq(a_clip, ["plain"])
  assert_true(host_a.lines_on_pixels())
  assert_eq(host_a.st_frame_shown(7, b"au", 1, 42.0, 1), 1)
  assert_eq(host_a.st_frame_shown(7, b"au", 0, 43.0, 0), 0)
  assert_eq(a_frames, [(7, b"au", 1, 42.0)])
  host_a.st_pointer_named(3, "arrow", fn() { b"png" }, 16.0, 16.0, 1.0, 2.0)
  assert_eq(a_ptrs, [(3, b"png")])

  // Global host_b must never have been touched
  assert_eq(b_calls.val, 0)

  @hostapi.set_host(prev)
}
