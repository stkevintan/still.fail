// The windows of one run (@hostapi.windows_in_process: the desktops'): each window its own tree, its own frames and
// input, drawn by the same program over the same state of the app. What the window's runtime keeps of a window (its
// context, its tree and what the frames keep of it, the hand on it) is kept apart for each: the window the host draws
// or hands input from now is put in place for that (window_use) and the first one, 0, put back after, so that what
// comes between frames (a core's message, a decoded frame) finds the first window's in place, as in a run of one
// window. While no other window is open nothing here runs: a run of one window is as it was.
//
// What is kept of a window is said once below (window_kept_ui) and by what is over this package (window_kept): what
// is taken out of the globals as another window comes in, and what a window made anew starts with. What is not a
// window's own (the host's images, streams and native views by their ids, the text's caches, the core's messages, the
// runtime's fibers, what measures the run) stays one for all windows.

///|
priv struct WindowKept {
  /// what the window in place keeps taken out (the globals may then hold anything): its putting back
  take : () -> (() -> Unit)
  /// what a window made anew starts with, put in the globals
  fresh : () -> Unit
}

///|
fn[T] kept_ref(r : Ref[T], fresh : () -> T) -> WindowKept {
  { take: fn() { let v = r.val; fn() { r.val = v } }, fresh: fn() { r.val = fresh() } }
}

///|
fn[K : Hash + Eq, V] kept_map(m : Map[K, V]) -> WindowKept {
  {
    take: fn() {
      let held = m.copy()
      fn() {
        m.clear()
        for k, v in held {
          m[k] = v
        }
      }
    },
    fresh: fn() { m.clear() },
  }
}

///|
fn[K : Hash + Eq] kept_set(s : Set[K]) -> WindowKept {
  {
    take: fn() {
      let held = s.iter().collect()
      fn() {
        s.clear()
        for k in held {
          s.add(k)
        }
      }
    },
    fresh: fn() { s.clear() },
  }
}

///|
fn[T] kept_array(a : Array[T], fresh : () -> Array[T]) -> WindowKept {
  {
    take: fn() {
      let held = a.copy()
      fn() {
        a.clear()
        a.append(held)
      }
    },
    fresh: fn() {
      a.clear()
      a.append(fresh())
    },
  }
}

///|
fn[T] kept_fixed(a : FixedArray[T], fresh : () -> FixedArray[T]) -> WindowKept {
  let put = fn(from : FixedArray[T]) {
    for i in 0..<a.length() {
      a[i] = from[i]
    }
  }
  {
    take: fn() {
      let held = FixedArray::makei(a.length(), fn(i) { a[i] })
      fn() { put(held) }
    },
    fresh: fn() { put(fresh()) },
  }
}

///|
/// (taken by moving what it keeps out: a window's taking is always followed by another's putting back or a fresh one)
fn[V] kept_by_node(b : ByNode[V]) -> WindowKept {
  {
    take: fn() {
      let held : ByNode[V] = ByNode::new()
      b.swap(held)
      fn() { b.swap(held) }
    },
    fresh: fn() { b.clear() },
  }
}

///|
fn kept_struct(take : () -> (() -> Unit), fresh : () -> Unit) -> WindowKept {
  { take, fresh }
}

///|
/// What the window's runtime keeps of each window (the file's head says which), said once as the first window other
/// than the first is made (in parts: one function holding all of it is more than a Wasm engine compiles).
fn window_kept_ui() -> Array[WindowKept] {
  [..window_kept_tester(), ..window_kept_ui_0(), ..window_kept_ui_1(), ..window_kept_ui_2(), ..window_kept_ui_3(), ..window_kept_ui_4(), ..window_kept_ui_5(), ..window_kept_ui_6(), ..window_kept_ui_7(), ..window_kept_ui_8(), ..window_kept_ui_9(), ..window_kept_ui_10(), ..window_kept_ui_11()]
}

///|
fn window_kept_ui_0() -> Array[WindowKept] {
  [
    kept_ref(the_ctx, fn() { Ctx::new() }),
    kept_ref(modifiers_said, fn() { @signals.signal(0) }),
    kept_ref(g_view, fn() { fn(_c) { () } }),
    kept_ref(frame_afters, fn() { [] }),
    kept_ref(drawn_frame_afters, fn() { [] }),
    kept_ref(window_title_said, fn() { "" }),
    kept_ref(building, fn() { false }),
    kept_ref(wheel_went, fn() { 0 }),
    kept_ref(wheel_old_target, fn() { 0 }),
    kept_ref(wheel_back, wheel_back_fresh),
    kept_set(bone_insts),
    kept_map(code_fields),
    kept_array(code_clears, fn() { [] }),
    kept_ref(code_clears_said, fn() { @signals.signal(0) }),
    kept_ref(tree_window_corner, fn() { @signals.signal(0.0, same=fn(a, b) { a == b }) }),
    kept_ref(tree_window_zoom, fn() { @signals.signal(1.0, same=fn(a, b) { a == b }) }),
    kept_ref(tree_theme_said, fn() { @signals.signal_by(None, same=fn(a, b) {
  match (a, b) {
    (Some(x), Some(y)) => physical_equal(x, y) || x == y
    (None, None) => true
    _ => false
  }
}) }),
    kept_ref(tree_theme_of, fn() { @signals.signal_by(None, same=fn(a, b) {
  match (a, b) {
    (Some(x), Some(y)) => physical_equal(x, y)
    (None, None) => true
    _ => false
  }
}) }),
    kept_ref(tree_inset_said, fn() { @signals.signal(None, same=fn(a, b) { a == b }) }),
    kept_ref(glass_forced_said, fn() { @signals.signal(-1, same=fn(a, b) { a == b }) }),
    kept_ref(glass_light_angle_said, fn() { @signals.signal(0.0, same=fn(a, b) { a == b }) }),
    kept_ref(glass_frost_said, fn() { @signals.signal(0.0, same=fn(a, b) { a == b }) }),
    kept_ref(inset_said, inset_said_new),
    kept_ref(zoomed_said, zoomed_said_new),
    kept_ref(snap_said, snap_said_new),
    kept_by_node(tree_links),
    kept_map(corner_scale_at),
    kept_set(tree_pictures),
    kept_map(tree_frame_ids),
    kept_struct(fn() { let held = { ..known_nodes }; fn() { known_nodes.window_put(held) } }, fn() { known_nodes.window_put(IdentMap::new()) }),
    kept_ref(known_made, fn() { 0 }),
    kept_ref(known_pass, fn() { 0 }),
    kept_map(cycle_frame),
    kept_ref(cycle_tagged, fn() { 0 }),
  ]
}

///|
fn window_kept_ui_1() -> Array[WindowKept] {
  [
    kept_struct(fn() { let held = { ..picked }; fn() { picked.window_put(held) } }, fn() { picked.window_put({
  from: no_spot,
  to: no_spot,
  spans: {},
  dragging: false,
  list: 0,
  across: 0,
  layer: OldLayer(0),
  made: 0,
  finger: false,
  island: None,
  word: None,
  handle: 0,
  grab_x: 0.0,
  grab_y: 0.0,
}) }),
    kept_struct(fn() { let held = { ..desk }; fn() { desk.window_put(held) } }, fn() { desk.window_put({
  mutable_menus: [],
  menus: [],
  mutable_keys: [],
  keys: [],
  shown: 0,
  old_shape: 0,
  pasting: None,
  pasted: {},
  next_mouse_drags: [],
  mouse_drags: true,
  selecting: false,
  sel_color: 0x3B82F64DL,
  next_sels: [],
  sels: [],
}) }),
    kept_ref(sel_moved, fn() { (0.0, 0.0) }),
    kept_ref(sel_read, fn() { None }),
    kept_map(drags),
    kept_map(press_followers),
    kept_ref(press_following, fn() { None }),
    kept_struct(fn() { let held = { ..dr }; fn() { dr.window_put(held) } }, fn() { dr.window_put({
  entries: [],
  build: 0,
  any: false,
  framing: false,
  bypass: -1,
  mode: 0,
  targets_said: false,
  overlaying: false,
  overlay: [],
  moves: [],
  raised: [],
  scrims: [],
  raising: false,
  tops: [],
  covers: [],
  over_cover: [],
  covering: false,
  over_layers: [],
  over_all: false,
  carry: [],
  cycling: -1,
  rows_soft: [],
}) }),
    kept_struct(fn() { let held = { ..dropping }; fn() { dropping.window_put(held) } }, fn() { dropping.window_put({ words: None, paths: None }) }),
    kept_map(tree_drops),
    kept_map(files_on),
    kept_ref(files_on_held, fn() { 0 }),
    kept_ref(finger_held, fn() { -1.0 }),
    kept_array(next_finger_ends, fn() { [None, None] }),
    kept_array(finger_ends, fn() { [None, None] }),
    kept_array(islands_built, fn() { [] }),
    kept_struct(fn() { let held = { ..pace }; fn() { pace.window_put(held) } }, fn() { pace.window_put({ at: -1.0, rung: -1 }) }),
    kept_ref(frame_told_at, fn() { "" }),
    kept_array(frame_told_moments, fn() { [] }),
    kept_array(build_causes, fn() { [] }),
    kept_ref(told_sets, fn() { 0 }),
    kept_ref(frame_start_sets, fn() { 0 }),
    kept_ref(build_told_more, fn() { false }),
    kept_ref(frame_clock, fn() { @signals.signal(0.0) }),
  ]
}

///|
fn window_kept_ui_2() -> Array[WindowKept] {
  [
    kept_ref(frame_watch, fn() { None }),
    kept_ref(layout_watch, fn() { None }),
    kept_ref(layout_said, fn() { "" }),
    kept_ref(layout_clock_at, fn() { "" }),
    kept_ref(laying, fn() { false }),
    kept_ref(layout_coming, fn() { false }),
    kept_ref(paint_watch, fn() { None }),
    kept_ref(paint_phase, fn() { 0 }),
    kept_ref(clock_read_at, fn() { "" }),
    kept_ref(paint_clock_at, fn() { "" }),
    kept_ref(wall_read, fn() { false }),
    kept_ref(built_why, fn() { "" }),
    kept_ref(painted_why, fn() { "" }),
    kept_ref(watch_said, fn() { "" }),
    kept_ref(frame_built, fn() { false }),
    kept_ref(frame_running, fn() { false }),
    kept_ref(frame_moment, fn() { -1.0 }),
    kept_ref(frame_serial, fn() { 0 }),
    kept_ref(paint_said, fn() { "" }),
    kept_ref(clock_read_who, fn() { None }),
    kept_ref(layout_clock_who, fn() { None }),
    kept_ref(paint_clock_who, fn() { None }),
    kept_ref(part_clock_at, fn() { "" }),
    kept_ref(clock_reads, fn() { 0 }),
  ]
}

///|
fn window_kept_ui_3() -> Array[WindowKept] {
  [
    kept_ref(part_clock_who, fn() { None }),
    kept_ref(built_motion, fn() { "" }),
    kept_struct(fn() { let held = { ..looks_base }; fn() { looks_base.window_put(held) } }, fn() { looks_base.window_put({
  inst: FixedArray::make(0, 0.0),
  spans: [],
  n: 0,
  looks: false,
  ok: false,
  left: false,
  told_same: false,
  wake: -1.0,
  wake_by: "",
  built_at: -1.0,
  built: false,
  settled: false,
}) }),
    kept_ref(scroll_paint_uncompared, fn() { false }),
    kept_struct(fn() { let held = { ..paint_base }; fn() { paint_base.window_put(held) } }, fn() { paint_base.window_put({ sig: 0L, had: false, laid_same: false, root: 0, wake: -1.0 }) }),
    kept_ref(in_looks, fn() { false }),
    kept_struct(fn() { let held = { ..looks_own }; fn() { looks_own.window_put(held) } }, fn() { looks_own.window_put({ wake: -1.0, cycling: false }) }),
    kept_ref(looks_drawn, fn() { false }),
    kept_ref(painted_alone, fn() { false }),
    kept_ref(looks_frames, fn() { 0 }),
    kept_ref(paints_alone, fn() { 0 }),
    kept_struct(fn() { let held = { ..looks_tells }; fn() { looks_tells.window_put(held) } }, fn() { looks_tells.window_put({ now: [], before: [] }) }),
    kept_ref(looks_heads_only, fn() { false }),
    kept_ref(events_seen, fn() { 0 }),
    kept_ref(typed_frame_last, fn() { -1 }),
    kept_ref(typed_seen, fn() { 0 }),
    kept_ref(outside_seen, fn() { 0 }),
    kept_struct(fn() { let kept = { ..gaps_steady }; fn() { gaps_steady.window_put(kept) } }, fn() {
      let (held, file) = (gaps_steady.held, gaps_steady.file)
      gaps_steady.window_put({
  held: true,
  file: "",
  ways: {},
  found: Set([]),
  window: (-1.0, -1.0),
  words: -1.0,
})
      gaps_steady.held = held
      gaps_steady.file = file
    }),
    kept_struct(fn() { let held = { ..glass_paint }; fn() { glass_paint.window_put(held) } }, fn() { glass_paint.window_put({
  run: 0,
  frost_run: 0,
  liquid_run: 0,
  liquid_blur: 0.0,
  liquid_first: -1,
  liquid_y0: 0.0,
  liquid_y1: 0.0,
  run_start: -1,
  run_len: 0,
  solid: false,
  frost: 0.0,
  contrast: false,
  forced: -1,
  in_group: 0,
  ink_x: 0.0,
  ink_y: 0.0,
  ink_r: 0.0,
  ink_bare: false,
  ink_line: false,
}) }),
    kept_struct(fn() { let held = { ..hand }; fn() { hand.window_put(held) } }, fn() { hand.window_put({
  over: @signals.keyed(),
  pressed: @signals.keyed(),
  press_on: @signals.keyed(),
  clicked: @signals.keyed(),
  double: @signals.keyed(),
  held: @signals.keyed(),
  focus: @signals.keyed(),
  focus_id: @signals.signal(0),
  shown: @signals.keyed(),
  pointer: @signals.signal((0.0, 0.0), same=fn(a, b) { a.0 == b.0 && a.1 == b.1 }),
  down: @signals.signal(false),
  pointing: @signals.signal(Finger),
  beyond: @signals.signal(false),
  events: @signals.signal(0),
  typed: @signals.signal(0),
  presses: @signals.signal(0),
  asked: @signals.keyed(),
  over_now: [],
}) }),
    kept_struct(fn() { let held = { ..turns }; fn() { turns.window_put(held) } }, fn() { turns.window_put({
  over: {},
  left: {},
  down: false,
  down_at: 0.0,
  pointer_in: {},
  keys_in: {},
  start: 0.0,
}) }),
    kept_ref(window_size, fn() { @signals.signal((0.0, 0.0), same=fn(a, b) { a == b }) }),
    kept_ref(pixel_grid, fn() { @signals.signal((0.0, false), same=fn(a, b) { a == b }) }),
    kept_array(damage_known, fn() { [] }),
  ]
}

///|
fn window_kept_ui_4() -> Array[WindowKept] {
  [
    kept_array(lists_scrolled, fn() { [] }),
    { take: fn() { presented.window_take() }, fresh: fn() { presented.window_fresh() } },
    kept_ref(presented_share, fn() { 1.0 }),
    kept_ref(presented_ms, fn() { 0.0 }),
    kept_ref(inputs_since, fn() { false }),
    kept_ref(press_moment, fn() { -1.0 }),
    kept_ref(inputs_taken, fn() { false }),
    kept_map(kept_nodes),
    kept_struct(fn() { let held = { ..nodes_run }; fn() { nodes_run.window_put(held) } }, fn() { nodes_run.window_put({
  fresh: true,
  evented: false,
  evented_only: -1,
  typed_alone: false,
  whole: true,
  part_fresh: false,
  told: false,
  told_by: (0, 0),
  told_at: None,
  pass: 0,
  building: None,
  aside: 0,
  kept: 0,
  built: 0,
  built_read: 0,
  kept_at: [],
  built_at: [],
  built_asked: false,
  on: true,
}) }),
    kept_ref(aside_why, fn() { "" }),
    kept_struct(fn() { let held = { ..parts_run }; fn() { parts_run.window_put(held) } }, fn() { parts_run.window_put({ ctx: None }) }),
    kept_struct(fn() { let held = { ..kept_clock }; fn() { kept_clock.window_put(held) } }, fn() { kept_clock.window_put({ frame: @signals.signal(0), dues: [] }) }),
    kept_ref(moves_said, fn() { 0 }),
    kept_map(list_counts),
    kept_map(list_keys_seen),
    kept_map(list_hand_watches),
    kept_map(list_hand_dirty),
    kept_array(list_fast_info_reads, fn() { [] }),
    kept_map(list_fast_place_reads),
    kept_map(tells_follow_lists),
    kept_array(list_fast_tells, fn() { [] }),
    kept_ref(rows_laid_by, fn() { None }),
    kept_map(made_roots),
    kept_array(made_placed, fn() { [] }),
    kept_map(made_presses),
    kept_map(island_presses),
    kept_map(island_lists),
  ]
}

///|
fn window_kept_ui_5() -> Array[WindowKept] {
  [
    kept_ref(frame_end_sets, fn() { -1 }),
    kept_ref(frame_quiet, fn() { false }),
    kept_map(made_double_presses),
    kept_map(made_beside_presses),
    kept_map(keys_taken),
    kept_array(stacked_views, fn() { [] }),
    kept_map(native_nodes),
    kept_map(picture_at),
    kept_ref(nav_serial, fn() { 0 }),
    kept_ref(nav_stint, fn() { 0 }),
    kept_ref(stacks_said, fn() { @signals.signal(0) }),
    kept_array(nav_views, fn() { [] }),
    kept_ref(nav_views_made, fn() { 0 }),
    kept_map(nav_veils),
    kept_map(nav_clips),
    kept_array(nav_clips_now, fn() { [] }),
    kept_ref(layer_opened, fn() { 0 }),
    kept_map(layer_back_spent),
    kept_set(layer_retired_ids),
    kept_array(row_keep, fn() { [] }),
    kept_ref(row_targets_again, fn() { None }),
    // (when the hand last did something is the person's, one hand for every window: put back, a window keeps the later
    // of its own and what was done in the one before it; made anew, it starts from it)
    kept_struct(fn() {
      let kept = { ..rows_steady }
      fn() {
        let hand = dmax(rows_steady.hand, kept.hand)
        rows_steady.window_put(kept)
        rows_steady.hand = hand
      }
    }, fn() {
      let (held, file, hand) = (rows_steady.held, rows_steady.file, rows_steady.hand)
      rows_steady.window_put({
  held: true,
  file: "",
  seen: {},
  found: Set([]),
  lists: {},
  window: (-1.0, -1.0),
  words: -1.0,
  turned: {},
  went: {},
  hand: -1.0e9,
  judged: -1.0e9,
  laids: {},
  tree_gens: {},
  anchors: {},
})
      rows_steady.held = held
      rows_steady.file = file
      rows_steady.hand = hand
    }),
    kept_array(hits_before, fn() { [] }),
    kept_map(bars_hand),
    kept_map(sideways),
    kept_array(shows_asked, fn() { [] }),
    kept_struct(fn() { let kept = { ..sizes_steady }; fn() { sizes_steady.window_put(kept) } }, fn() {
      let (held, file) = (sizes_steady.held, sizes_steady.file)
      sizes_steady.window_put({
  held: true,
  file: "",
  seen: {},
  found: Set([]),
  found_across: Set([]),
  window: (-1.0, -1.0),
  bars: (-1.0, -1.0, -1.0, -1.0),
  words: -1.0,
  hand: -1.0e9,
  puts: {},
  laids: {},
  judged: -1.0e9,
})
      sizes_steady.held = held
      sizes_steady.file = file
    }),
    kept_set(tree_scroll_held_at),
    kept_map(tree_field_boxes),
  ]
}

///|
fn window_kept_ui_6() -> Array[WindowKept] {
  [
    kept_set(tree_scaled_at),
    kept_set(tree_drawn_scaled),
    kept_ref(tree_nodes_from, fn() { -1 }),
    kept_set(tree_draws_at),
    kept_set(tree_marks_at),
    kept_set(tree_moved_at),
    kept_set(tree_fixed_h_at),
    kept_map(stream_nodes),
    kept_struct(fn() { let held = { ..targets_kept }; fn() { targets_kept.window_put(held) } }, fn() { targets_kept.window_put({
  found: false,
  key: (0, 0, 0, [], false, false),
  stale: true,
  watch: None,
  layers_from: 0,
}) }),
    kept_ref(targets_finds, fn() { 0 }),
    kept_ref(targets_island, fn() { None }),
    kept_map(helds),
    kept_map(marks_at),
    kept_map(dues),
    kept_fixed(touch_slots, fn() { FixedArray::make(2, 0) }),
    kept_fixed(touch_down, fn() { FixedArray::make(2, false) }),
    kept_array(touch_extra, fn() { [] }),
    kept_ref(touch_extra_next, fn() { 2 }),
    kept_ref(moves_batched, fn() { false }),
    kept_ref(last_touch_x, fn() { 0.0 }),
    kept_ref(last_touch_y, fn() { 0.0 }),
    kept_map(tree_fields),
    kept_array(tree_fields_asked, fn() { [] }),
    kept_map(tree_field_focus_told),
    kept_map(tree_field_menu_areas),
    kept_array(field_menu_asked, fn() { [] }),
    kept_ref(field_menu_seq, fn() { 0 }),
    kept_map(@view.dashed_edges_kept()),
    kept_map(@view.notches_kept()),
    kept_map(@view.shadows_out_kept()),
    kept_map(@view.cuts_across_kept()),
    kept_map(@view.magnifiers_kept()),
    kept_ref(tree_fields_rev, fn() { 0 }),
    kept_ref(tree_fields_drawn, fn() { @signals.signal(0) }),
    kept_ref(tree_field_hovered, fn() { None }),
    kept_map(tree_natives),
    kept_ref(tree_natives_rev, fn() { 0 }),
    kept_ref(tree_hits_passed, fn() { 0 }),
  ]
}

///|
fn window_kept_ui_7() -> Array[WindowKept] {
  [
    kept_map(picked_shown),
    kept_ref(picked_now_said, fn() { @signals.signal(None, same=fn(a, b) { a == b }) }),
    kept_ref(field_menu_now_said, fn() { @signals.signal(None, same=fn(a, b) { a == b }) }),
    kept_ref(tree_finger_read, fn() { @signals.signal(None, same=fn(a, b) { a == b }) }),
    kept_map(picked_spans_said),
    kept_map(picked_row_said),
    kept_map(row_picked_memos),
    kept_ref(picked_finger_said, fn() { @signals.signal(false) }),
    kept_ref(tree_sels_made, fn() { 0 }),
    kept_ref(tree_edge, fn() { None }),
    kept_ref(tree_finger_hold, fn() { None }),
    kept_map(cmd_pick_scopes),
    kept_ref(cmd_hover, fn() { None }),
    kept_ref(cmd_pick_down, fn() { None }),
    kept_ref(cmd_sel_underline, fn() { None }),
    kept_map(tree_streams),
    kept_ref(tree_streams_rev, fn() { 0 }),
    kept_map(unbuilt_watch),
    kept_ref(view_app, fn() { None }),
    kept_array(old_islands, fn() { [] }),
    kept_ref(old_made, fn() { 0 }),
    kept_array(old_placed, fn() { [] }),
    kept_ref(old_placed_said, fn() { @signals.signal(0) }),
    kept_by_node(old_placed_off),
    kept_ref(old_whole, fn() { true }),
    kept_map(old_boxes),
    kept_by_node(old_box_of),
    kept_ref(view_held, fn() { None }),
    kept_ref(view_nothing_down, fn() { None }),
    kept_ref(view_down, fn() { None }),
    kept_ref(view_down_slot0, fn() { false }),
    kept_ref(view_down2, fn() { None }),
    kept_map(view_down_extra),
    kept_ref(view_handed, fn() { None }),
    kept_ref(downs_made, fn() { 0 }),
  ]
}

///|
fn window_kept_ui_8() -> Array[WindowKept] {
  [
    kept_fixed(view_fingers, fn() { FixedArray::make(3, -1) }),
    kept_map(view_fingers_extra),
    kept_ref(view_due, fn() { @signals.signal(0) }),
    kept_ref(view_hits_seen, fn() { 0 }),
    kept_ref(view_due_at, fn() { "" }),
    kept_by_node(view_blocks),
    kept_struct(fn() { let held = { ..view_paint_work }; fn() { view_paint_work.window_put(held) } }, fn() { view_paint_work.window_put({ made: 0, copied: 0, handed: 0 }) }),
    kept_ref(view_logic_at, fn() { 0.0 }),
    kept_ref(view_window, fn() { (0.0, 0.0) }),
    kept_ref(old_place_seen, fn() { None }),
    kept_ref(old_laid, fn() { @signals.signal("", same=fn(a, b) { a == b }) }),
    kept_ref(view_island_seen, fn() { (
  false,
  [],
  "false ",
) }),
    kept_array(tree_over_scrim, fn() { [] }),
    kept_ref(glyphs_held_sc, fn() { 0.0 }),
    kept_ref(island_building, fn() { None }),
    kept_map(old_box_owners),
    kept_ref(view_input_to, fn() { -3 }),
    kept_ref(old_around, fn() { false }),
    kept_array(old_hits, fn() { [] }),
    kept_array(next_old_hits, fn() { [] }),
    kept_array(old_hits_rects, fn() { [] }),
    kept_array(old_hits_clips, fn() { [] }),
    kept_map(old_cuts),
    kept_array(old_scrolls_rects, fn() { [] }),
    kept_array(old_bars, fn() { [] }),
  ]
}

///|
fn window_kept_ui_9() -> Array[WindowKept] {
  [
    kept_by_node(view_shape_bands),
    kept_by_node(view_pictures),
    kept_ref(view_pictures_cut, fn() { 0 }),
    kept_ref(view_bands_made, fn() { 0 }),
    kept_ref(view_point, fn() { None }),
    kept_ref(view_over_words, fn() { false }),
    kept_ref(view_point_seen, fn() { (-1, false, -1) }),
    kept_ref(view_point_owed, fn() { false }),
    kept_map(tree_said_ids),
    kept_by_node(tree_said_of),
    kept_ref(tree_said_next, fn() { -2_000_000_000 }),
    kept_ref(old_show_due, fn() { None }),
    kept_ref(old_focus_shown, fn() { 0 }),
    kept_ref(old_focus_parked, fn() { None }),
    kept_ref(nav_focus_due, fn() { None }),
    kept_array(layer_focus_open, fn() { [] }),
    kept_map(leaving_ime_nodes),
    kept_ref(view_shape_of, fn() { OfOld }),
    kept_map(thumbs_yielded),
    kept_ref(yields_said, fn() { 0 }),
    kept_ref(yields_seen, fn() { [] }),
    kept_array(layer_hits, fn() { [] }),
    kept_array(next_layer_hits, fn() { [] }),
    kept_map(old_anchor_rects),
    kept_ref(back_progress, fn() { -1.0 }),
    kept_map(tree_movers),
    kept_map(tree_glide_movers),
  ]
}

///|
fn window_kept_ui_10() -> Array[WindowKept] {
  [
    kept_array(list_heads, fn() { [] }),
    kept_array(offsets_flat, fn() { [] }),
    kept_map(stretch_painted),
    kept_ref(list_riding, fn() { None }),
    kept_by_node(ride_kept),
    kept_array(ride_walked, fn() { [] }),
    kept_by_node(ride_unkept),
    kept_map(ride_groups),
    kept_array(ride_groups_gone, fn() { [] }),
    kept_array(ride_spans, fn() { [] }),
    kept_array(ridings, fn() { [] }),
    kept_ref(ridings_rows, fn() { 0 }),
    kept_ref(ride_drawn, fn() { 0 }),
    kept_ref(ride_glyphs_gone, fn() { 0 }),
    kept_map(ride_caps),
    kept_ref(ride_heads, fn() { 0 }),
    kept_ref(old_lists_moved, fn() { false }),
    kept_by_node(island_watches),
    kept_array(list_ride_at, fn() { [] }),
    kept_ref(window_zoom_wanted, fn() { @signals.signal(1.0, same=fn(a, b) { a == b }) }),
    kept_ref(window_zoom_drawn, fn() { 1.0 }),
    kept_ref(zoom_wheel_kept, fn() { false }),
    kept_map(words_kept),
    kept_map(words_sel),
  ]
}

///|
fn window_kept_ui_11() -> Array[WindowKept] {
  [
    kept_struct(fn() { let kept = { ..words_over }; fn() { words_over.window_put(kept) } }, fn() {
      let (held, file) = (words_over.held, words_over.file)
      words_over.window_put({ held: true, file: "", pairs: Set([]), frames: [] })
      words_over.held = held
      words_over.file = file
    }),
    kept_array(words_over_closing_pairs, fn() { [] }),
    kept_map(tree_terminals),
    kept_ref(tree_terminals_rev, fn() { 0 }),
    kept_ref(drive_acting, fn() { false }),
  ]
}

///|
fn IdentMap::window_put(self : IdentMap, o : IdentMap) -> Unit {
  self.state = o.state
  self.keys = o.keys
  self.vals = o.vals
  self.held = o.held
  self.taken = o.taken
}

///|
fn Picked::window_put(self : Picked, o : Picked) -> Unit {
  self.from = o.from
  self.to = o.to
  self.spans = o.spans
  self.dragging = o.dragging
  self.list = o.list
  self.across = o.across
  self.layer = o.layer
  self.made = o.made
  self.finger = o.finger
  self.island = o.island
  self.word = o.word
  self.handle = o.handle
  self.grab_x = o.grab_x
  self.grab_y = o.grab_y
}

///|
fn Desk::window_put(self : Desk, o : Desk) -> Unit {
  self.mutable_menus = o.mutable_menus
  self.menus = o.menus
  self.mutable_keys = o.mutable_keys
  self.keys = o.keys
  self.shown = o.shown
  self.old_shape = o.old_shape
  self.pasting = o.pasting
  self.pasted = o.pasted
  self.next_mouse_drags = o.next_mouse_drags
  self.mouse_drags = o.mouse_drags
  self.selecting = o.selecting
  self.sel_color = o.sel_color
  self.next_sels = o.next_sels
  self.sels = o.sels
}

///|
fn DrawState::window_put(self : DrawState, o : DrawState) -> Unit {
  self.entries = o.entries
  self.build = o.build
  self.any = o.any
  self.framing = o.framing
  self.bypass = o.bypass
  self.mode = o.mode
  self.targets_said = o.targets_said
  self.overlaying = o.overlaying
  self.overlay = o.overlay
  self.moves = o.moves
  self.raised = o.raised
  self.scrims = o.scrims
  self.raising = o.raising
  self.tops = o.tops
  self.covers = o.covers
  self.over_cover = o.over_cover
  self.covering = o.covering
  self.over_layers = o.over_layers
  self.over_all = o.over_all
  self.carry = o.carry
  self.cycling = o.cycling
  self.rows_soft = o.rows_soft
}

///|
fn Dropping::window_put(self : Dropping, o : Dropping) -> Unit {
  self.words = o.words
  self.paths = o.paths
}

///|
fn Pace::window_put(self : Pace, o : Pace) -> Unit {
  self.at = o.at
  self.rung = o.rung
}

///|
fn LooksBase::window_put(self : LooksBase, o : LooksBase) -> Unit {
  self.inst = o.inst
  self.spans = o.spans
  self.n = o.n
  self.looks = o.looks
  self.ok = o.ok
  self.left = o.left
  self.told_same = o.told_same
  self.wake = o.wake
  self.wake_by = o.wake_by
  self.built_at = o.built_at
  self.built = o.built
  self.settled = o.settled
}

///|
fn PaintBase::window_put(self : PaintBase, o : PaintBase) -> Unit {
  self.sig = o.sig
  self.had = o.had
  self.laid_same = o.laid_same
  self.root = o.root
  self.wake = o.wake
}

///|
fn LooksOwn::window_put(self : LooksOwn, o : LooksOwn) -> Unit {
  self.wake = o.wake
  self.cycling = o.cycling
}

///|
fn LooksTold::window_put(self : LooksTold, o : LooksTold) -> Unit {
  self.now = o.now
  self.before = o.before
}

///|
fn GapsSteady::window_put(self : GapsSteady, o : GapsSteady) -> Unit {
  self.held = o.held
  self.file = o.file
  self.ways = o.ways
  self.found = o.found
  self.window = o.window
  self.words = o.words
}

///|
fn GlassPaint::window_put(self : GlassPaint, o : GlassPaint) -> Unit {
  self.run = o.run
  self.frost_run = o.frost_run
  self.liquid_run = o.liquid_run
  self.liquid_blur = o.liquid_blur
  self.liquid_first = o.liquid_first
  self.liquid_y0 = o.liquid_y0
  self.liquid_y1 = o.liquid_y1
  self.run_start = o.run_start
  self.run_len = o.run_len
  self.solid = o.solid
  self.frost = o.frost
  self.contrast = o.contrast
  self.forced = o.forced
  self.in_group = o.in_group
  self.ink_x = o.ink_x
  self.ink_y = o.ink_y
  self.ink_r = o.ink_r
  self.ink_bare = o.ink_bare
  self.ink_line = o.ink_line
}

///|
fn Hand::window_put(self : Hand, o : Hand) -> Unit {
  self.over = o.over
  self.pressed = o.pressed
  self.press_on = o.press_on
  self.clicked = o.clicked
  self.double = o.double
  self.held = o.held
  self.focus = o.focus
  self.focus_id = o.focus_id
  self.shown = o.shown
  self.pointer = o.pointer
  self.down = o.down
  self.pointing = o.pointing
  self.beyond = o.beyond
  self.events = o.events
  self.typed = o.typed
  self.presses = o.presses
  self.asked = o.asked
  self.over_now = o.over_now
}

///|
fn Turns::window_put(self : Turns, o : Turns) -> Unit {
  self.over = o.over
  self.left = o.left
  self.down = o.down
  self.down_at = o.down_at
  self.pointer_in = o.pointer_in
  self.keys_in = o.keys_in
  self.start = o.start
}

///|
fn NodesRun::window_put(self : NodesRun, o : NodesRun) -> Unit {
  self.fresh = o.fresh
  self.evented = o.evented
  self.evented_only = o.evented_only
  self.typed_alone = o.typed_alone
  self.whole = o.whole
  self.part_fresh = o.part_fresh
  self.told = o.told
  self.told_by = o.told_by
  self.told_at = o.told_at
  self.pass = o.pass
  self.building = o.building
  self.aside = o.aside
  self.kept = o.kept
  self.built = o.built
  self.built_read = o.built_read
  self.kept_at = o.kept_at
  self.built_at = o.built_at
  self.built_asked = o.built_asked
  self.on = o.on
}

///|
fn PartsRun::window_put(self : PartsRun, o : PartsRun) -> Unit {
  self.ctx = o.ctx
}

///|
fn KeptClock::window_put(self : KeptClock, o : KeptClock) -> Unit {
  self.frame = o.frame
  self.dues = o.dues
}

///|
fn RowsSteady::window_put(self : RowsSteady, o : RowsSteady) -> Unit {
  self.held = o.held
  self.file = o.file
  self.seen = o.seen
  self.found = o.found
  self.lists = o.lists
  self.window = o.window
  self.words = o.words
  self.turned = o.turned
  self.went = o.went
  self.hand = o.hand
  self.judged = o.judged
  self.laids = o.laids
  self.tree_gens = o.tree_gens
  self.anchors = o.anchors
}

///|
fn SizesSteady::window_put(self : SizesSteady, o : SizesSteady) -> Unit {
  self.held = o.held
  self.file = o.file
  self.seen = o.seen
  self.found = o.found
  self.found_across = o.found_across
  self.window = o.window
  self.bars = o.bars
  self.words = o.words
  self.hand = o.hand
  self.puts = o.puts
  self.laids = o.laids
  self.judged = o.judged
}

///|
fn TargetsKept::window_put(self : TargetsKept, o : TargetsKept) -> Unit {
  self.found = o.found
  self.key = o.key
  self.stale = o.stale
  self.watch = o.watch
  self.layers_from = o.layers_from
}

///|
fn ViewPaintWork::window_put(self : ViewPaintWork, o : ViewPaintWork) -> Unit {
  self.made = o.made
  self.copied = o.copied
  self.handed = o.handed
}

///|
fn WordsOver::window_put(self : WordsOver, o : WordsOver) -> Unit {
  self.held = o.held
  self.file = o.file
  self.pairs = o.pairs
  self.frames = o.frames
}

///|
/// What a Tester's checks keep of each window's last frames (a frame of the looks alone held to one built whole, what
/// it presented, its rows checked, its picking): each window's frames held to its own.
fn window_kept_tester() -> Array[WindowKept] {
  [
    kept_array(looks_nodes, fn() { [] }),
    kept_ref(kept_presented, fn() { None }),
    kept_ref(placed_presented, fn() { None }),
    kept_ref(picking_painting, fn() { None }),
    kept_ref(picking_painted_last, fn() { None }),
    kept_ref(rows_checking, fn() { None }),
    kept_ref(tree_frames_was, fn() { None }),
    kept_ref(host_presented, fn() { @damage.Damage::new() }),
    kept_ref(host_parts_last, fn() { [] }),
    kept_ref(host_hash_last, fn() { 0L }),
    kept_ref(glyph_moves_seen, fn() { glyph_moves.val }),
  ]
}
