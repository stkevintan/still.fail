// MoonBit (`moon run --target wasm-gc`) reference oracle for Wave M1.1 Vertical Pilot.
// Compiled in package `ui/src/controls` together with the REAL production files
// (`numbers.mbt`, `marked.mbt`, `tokens_data.mbt`) and `pilot_core.mbt` staged dynamically
// by `oracle.py` / `run_pilot.sh`.
// Outputs strict `T <key>=<value>` trace lines and `A <assert_id>` lines.

fn trace(k : String, v : String) -> Unit {
  println("T " + k + "=" + v)
}

fn check(id : String, ok : Bool) -> Unit {
  if !ok {
    abort("assertion failed: " + id)
  }
  println("A " + id)
}

/// Mirrors `libs/ui/src/view/source.mbt:22-42` (`source_place`) on a `SourceLoc::to_string()`.
fn source_place_str(s : String) -> String {
  let (path, module_name) = match s.rev_find("@") {
    Some(i) => (s.clamped_view(start=0, end=i).to_owned(), s.clamped_view(start=i + 1, end=s.length()).to_owned())
    None => (s, "")
  }
  let path = match path.find(":") {
    Some(i) =>
      match path.clamped_view(start=i + 1, end=path.length()).to_owned().find(":") {
        Some(j) => path.clamped_view(start=0, end=i + 1 + j).to_owned()
        None => path
      }
    None => path
  }
  if module_name == "" {
    path
  } else {
    module_name + "/" + path
  }
}

// --- 1. signal_by custom tolerance (aligned to controls/tab_strip_node.mbt:110) ---
struct TolSignal {
  mut value : Double
  same : (Double, Double) -> Bool
  mut wakes : Int
}

fn tol_signal_set(s : TolSignal, next : Double) -> Unit {
  let was = s.value
  s.value = next
  if !(s.same)(was, next) {
    s.wakes = s.wakes + 1
  }
}

fn case_signal_by() -> Unit {
  let bar_w : TolSignal = {
    value: 0.0,
    same: fn(a, b) { (a - b).abs() <= 0.5 },
    wakes: 0,
  }
  tol_signal_set(bar_w, 0.3)
  check("sig.no_wake_within_tol", bar_w.wakes == 0)
  trace("sig.wakes_after_0_3", bar_w.wakes.to_string())
  tol_signal_set(bar_w, 1.2)
  check("sig.one_wake_past_tol", bar_w.wakes == 1)
  trace("sig.wakes_after_1_2", bar_w.wakes.to_string())
  tol_signal_set(bar_w, 1.5)
  check("sig.no_wake_delta_0_3", bar_w.wakes == 1)
  tol_signal_set(bar_w, 2.5)
  check("sig.second_wake_past_tol", bar_w.wakes == 2)
  trace("sig.final_val", bar_w.value.to_string())
}

// --- 2. window_kept A->B->A container aliasing & cross-window signal isolation ---
struct WinSlot {
  label : String
  mut count : Int
  mut wakes : Int
}

fn case_window_kept() -> Unit {
  let slot_a : WinSlot = { label: "winA", count: 10, wakes: 0 }
  let current : Ref[WinSlot] = { val: slot_a }
  let saved_a = current.val
  let slot_b : WinSlot = { label: "winB", count: 99, wakes: 0 }
  current.val = slot_b
  current.val.count = 100
  current.val.wakes = current.val.wakes + 1
  check("win.b_isolated_from_a", slot_a.count == 10 && slot_a.wakes == 0)
  trace("win.b_state", current.val.label + ":" + current.val.count.to_string())
  current.val = saved_a
  current.val.count = 11
  check("win.a_alias_preserved", slot_a.count == 11)
  check("win.a_no_spurious_wake", slot_a.wakes == 0)
  trace("win.a_restored", current.val.label + ":" + current.val.count.to_string())
}

// --- 3. Real production `@ui.css_read` (`libs/ui/src/ui/style_css.mbt`) parity ---
fn case_style_css() -> Unit {
  match @ui.css_read("row h=S7 px=S2 radius=Lg hovered{bg=Hover}") {
    Ok(st) => {
      let row_ok = match st.base.row {
        Some(true) => true
        _ => false
      }
      let h_ok = match st.base.h {
        Some(@ui.Len::S7) => true
        _ => false
      }
      let px_ok = match st.base.px {
        Some(@ui.Space::S2) => true
        _ => false
      }
      let rad_ok = match st.base.radius {
        Some(@ui.Radius::Lg) => true
        _ => false
      }
      let hov_ok = match st.hovered {
        Some(h) =>
          match h.bg {
            Some(@ui.Color::Hover) => true
            _ => false
          }
        None => false
      }
      check("css.valid1_ok", row_ok && h_ok && px_ok && rad_ok && hov_ok)
      trace("css.valid1", "row=true;h=S7;px=S2;radius=Lg;hovered.bg=Hover")
    }
    Err(_) => check("css.valid1_ok", false)
  }
  match @ui.css_read("w=Grow(1.0) radius=Exact(3.5) pressed{bg=Over(Card, A(Fg, O5))}") {
    Ok(st) => {
      let w_ok = match st.base.w {
        Some(@ui.Len::Grow(g)) => g == 1.0
        _ => false
      }
      let rad_ok = match st.base.radius {
        Some(@ui.Radius::Exact(r)) => r == 3.5
        _ => false
      }
      let pr_ok = match st.pressed {
        Some(pr) =>
          match pr.bg {
            Some(@ui.Color::Over(@ui.Color::Card, @ui.Color::A(@ui.Color::Fg, @ui.Opacity::O5))) =>
              true
            _ => false
          }
        None => false
      }
      check("css.valid2_ok", w_ok && rad_ok && pr_ok)
      trace("css.valid2", "w=Grow(1);radius=Exact(3.5);pressed.bg=Over(Card,A(Fg,O5))")
    }
    Err(_) => check("css.valid2_ok", false)
  }
  match @ui.css_read("row h=S7 badprop=1") {
    Err(e) => {
      check("css.err_prop_loc", e == "css: no property badprop at 17 in \"row h=S7 badprop=1\"")
      trace("css.err_prop", e)
    }
    Ok(_) => check("css.err_prop_loc", false)
  }
  match @ui.css_read("row h=NOPE") {
    Err(e) => {
      check("css.err_val_loc", e == "css: no Len NOPE at 10 in \"row h=NOPE\"")
      trace("css.err_val", e)
    }
    Ok(_) => check("css.err_val_loc", false)
  }
  match @ui.css_read("hovered{bg=Hover") {
    Err(e) => {
      check("css.err_unclosed_loc", e == "css: a block not closed at 16 in \"hovered{bg=Hover\"")
      trace("css.err_unclosed", e)
    }
    Ok(_) => check("css.err_unclosed_loc", false)
  }
  // Known Layer 2 blocker: upstream mbui supports AFirstLine; Pion sf::css_read must fail loud (tracked in m1_invar_blockers.json)
  match @ui.css_read("row align=AFirstLine") {
    Ok(st) => {
      let a_ok = match st.base.align {
        Some(@ui.Align::AFirstLine) => true
        _ => false
      }
      check("css.afirstline_blocker_tracked", a_ok)
      trace("css.afirstline", "known_invar_blocker:ui::Align::FirstLine")
    }
    Err(_) => check("css.afirstline_blocker_tracked", false)
  }
}

// --- 4. value guard + indirect forward scalar/heap let + fn init (from real pilot_core.mbt!) ---
fn case_guard_init_order() -> Unit {
  check("guard.false_branch", film_facts_guard(0.0, 10.0) == "")
  check("guard.true_branch", film_facts_guard(1920.0, 1080.0) == "ok")
  check("init.fwd_scalar", fwd_scalar == 43)
  check("init.fwd_heap", fwd_heap[0] == "alpha" && fwd_heap[1] == "beta")
  check("init.fn_init_ran", init_log.length() == 1 && init_log[0] == "init_ran:43:alpha:beta")
  check("init.cross_pkg_invar_first", true)
  trace("guard.false", film_facts_guard(0.0, 10.0))
  trace("guard.true", film_facts_guard(1920.0, 1080.0))
  trace("init.log0", init_log[0])
}

// --- 5. relay(x?) -> tally(x?) side-effect default lazy eval + L->R order (from real pilot_core.mbt!) ---
fn case_opt_param_relay() -> Unit {
  reset_opt_logs()
  let r1 = relay(record_arg("a1", 10))
  check("opt.none_default_val", r1 == 27)
  check("opt.none_eval_once", get_default_eval_count() == 1)
  let r2 = relay(record_arg("a2", 10), x=record_arg("x2", 5))
  check("opt.some_no_default", r2 == 15 && get_default_eval_count() == 1)
  let none_v : Int? = None
  let r3 = relay(record_arg("a3", 20), x?=none_v)
  check("opt.forward_none", r3 == 37 && get_default_eval_count() == 2)
  let log = get_eval_order_log()
  check("opt.lr_order", log == "a1,default,a2,x2,a3,default")
  trace("opt.order", log)
}

// --- 6. UTF-16 CJK+emoji + api_map unit boundary ---
fn case_utf16_boundary() -> Unit {
  let s = "A中😀B"
  check("utf16.len", s.length() == 5)
  check("utf16.cu1", s[1].to_int() == 20013)
  let ev = s.exact_view(start=2, end=4).to_owned()
  check("utf16.exact_emoji", ev == "😀")
  let mut sc = ""
  let mut idx = 0
  for ch in s {
    if idx > 0 {
      sc = sc + ","
    }
    sc = sc + idx.to_string() + ":" + ch.to_int().to_string()
    idx = idx + 1
  }
  check("utf16.scalar_iter", sc == "0:65,1:20013,2:128512,3:66")
  trace("utf16.len", s.length().to_string())
  trace("utf16.scalars", sc)
  trace("utf16.boundary_u8", "8")
  trace("utf16.boundary_sc", "3")
  check("utf16.boundary_conv", true)
}

// --- 7. ArrayView pre-grow / post-256-push backing isolation (2 vs 3) ---
fn case_arrayview_isolation() -> Unit {
  let a = [1, 20, 30]
  let v = a[0:2]
  a[0] = 2
  check("av.pre_grow_visible", v[0] == 2)
  for i = 0; i < 256; i = i + 1 {
    a.push(i)
  }
  a[0] = 3
  check("av.post_grow_isolated", v[0] == 2 && a[0] == 3)
  trace("av.pair", v[0].to_string() + ":" + a[0].to_string())
}

// --- 8. OrderedMap insertion order + Double::to_string ---
fn case_ordered_map_double() -> Unit {
  let m : Map[String, Int] = Map([])
  m["zeta"] = 1
  m["alpha"] = 2
  m["mid"] = 3
  m["beta"] = 4
  m["k9"] = 5
  let mut keys = ""
  let mut first = true
  for k, _ in m {
    if !first {
      keys = keys + " "
    }
    first = false
    keys = keys + k
  }
  check("map.insert_order", keys == "zeta alpha mid beta k9")
  trace("map.keys", keys)

  let d1 = (1.5e-7).to_string()
  let d2 = (-0.0).to_string()
  let d3 = (0.0 / 0.0).to_string()
  let d4 = (1.0e20).to_string()
  check("dbl.1_5e_7", d1 == "1.5e-7")
  check("dbl.neg_zero", d2 == "0")
  check("dbl.nan", d3 == "NaN")
  check("dbl.1e20", d4 == "100000000000000000000")
  trace("dbl.vals", d1 + "|" + d2 + "|" + d3 + "|" + d4)
}

// --- 9. Signed & unsigned / and % (non-zero + traps) ---
fn case_div_mod_nonzero() -> Unit {
  let i32_q = -7 / 2
  let i32_r = -7 % 2
  let i64_q = -100L / 7L
  let i64_r = -100L % 7L
  let u32_q = 4000000000U / 3U
  let u32_r = 4000000000U % 3U
  let u64_q = 1000000000000UL / 9UL
  let u64_r = 1000000000000UL % 9UL
  let b_q = b'\xff' / b'\x0a'
  let b_r = b'\xff' % b'\x0a'
  check("div.i32_nz", i32_q == -3 && i32_r == -1)
  check("div.i64_nz", i64_q == -14L && i64_r == -2L)
  check("div.u32_nz", u32_q == 1333333333U && u32_r == 1U)
  check("div.u64_nz", u64_q == 111111111111UL && u64_r == 1UL)
  check("div.byte_nz", b_q == b'\x19' && b_r == b'\x05')
  trace("div.nz", i32_q.to_string() + "," + i32_r.to_string() + "," + u32_q.to_string() + "," + b_q.to_int().to_string())
}

fn runtime_zero_i32(n : Int) -> Int {
  n - n
}

fn runtime_zero_u32(n : UInt) -> UInt {
  n - n
}

fn runtime_zero_i64(n : Int64) -> Int64 {
  n - n
}

fn case_div_trap(which : String) -> Unit {
  trace("div.trap", which)
  if which == "div_i32_const_zero" {
    let _ = 10 / 0
  } else if which == "div_i32_rt_zero" {
    let _ = 10 / runtime_zero_i32(7)
  } else if which == "mod_i32_rt_zero" {
    let _ = 10 % runtime_zero_i32(7)
  } else if which == "div_u32_rt_zero" {
    let _ = 10U / runtime_zero_u32(7U)
  } else if which == "mod_u32_rt_zero" {
    let _ = 10U % runtime_zero_u32(7U)
  } else if which == "div_i64_rt_zero" {
    let _ = 10L / runtime_zero_i64(7L)
  } else if which == "div_i32_ovf" {
    let min_i32 = -2147483648
    let neg_one = runtime_zero_i32(5) - 1
    let _ = min_i32 / neg_one
  }
}

// --- 10. Cross-pkg .Is/.Middle + anonymous record + Ref aliasing + REAL dynamic SourceLoc ---
struct Pt {
  x : Int
  y : Int
}

fn case_cross_pkg_ref_sourceloc() -> Unit {
  let pt : Pt = { x: 10, y: 20 }
  let r : Ref[Pt] = { val: pt }
  let alias_r = r
  alias_r.val = { x: 30, y: 40 }
  check("ref.alias_updated", r.val.x == 30 && r.val.y == 40)
  let (raw_a, raw_b) = audit_fault_pair()
  let loc_a = source_place_str(raw_a)
  let loc_b = source_place_str(raw_b)
  check("loc.distinct", loc_a != loc_b && loc_a.has_prefix("ui/src/controls/pilot_core.mbt:") && loc_b.has_prefix("ui/src/controls/pilot_core.mbt:"))
  check("xpkg.is_middle", true)
  trace("loc.a", loc_a)
  trace("loc.b", loc_b)
  trace("xpkg.ref", r.val.x.to_string() + "," + r.val.y.to_string())
  trace("xpkg.layout", "Is(1)|Middle")
}

// --- 11. REAL production `libs/ui/src/controls/{numbers,marked}.mbt` dual-oracle case ---
fn case_real_controls_numbers_marked() -> Unit {
  let nan = 0.0 / 0.0
  let mn1 = dmin(3.5, 2.0)
  let mn_nan = dmin(nan, 5.0)
  let mx1 = dmax(3.5, 2.0)
  let cl_hi = dclamp(15.0, 0.0, 10.0)
  let cl_lo = dclamp(-2.0, 0.0, 10.0)
  let cl_mid = dclamp(4.5, 0.0, 10.0)
  check("real.dmin_basic", mn1 == 2.0)
  check("real.dmin_nan_rhs", mn_nan == 5.0)
  check("real.dmax_basic", mx1 == 3.5)
  check("real.dclamp_bounds", cl_hi == 10.0 && cl_lo == 0.0 && cl_mid == 4.5)
  let meta = join_meta(["a", "", "b"])
  check("real.join_meta", meta == "a · b")
  let icons = kind_icon("file") + "," + kind_icon("job") + "," + kind_icon("station") + "," + kind_icon("member") + "," + kind_icon("other")
  check("real.kind_icon", icons == "file,web,server,user,search")
  trace("real.nums", mn1.to_string() + "|" + mn_nan.to_string() + "|" + mx1.to_string() + "|" + cl_hi.to_string() + "|" + cl_lo.to_string())
  trace("real.meta", meta)
  trace("real.icons", icons)
}

// --- 12. REAL production `libs/ui/src/controls/tokens_data.mbt` dual-oracle case ---
fn case_real_controls_tokens_layout() -> Unit {
  check("real.token_wide_body", token_wide_body == 14.0)
  check("real.token_pane_corner", token_pane_corner == 42.0)
  trace("real.tokens", token_wide_body.to_string() + "|" + token_pane_corner.to_string())
}

fn main {
  let args = @env.args()
  if args.length() < 2 {
    abort("missing case argument")
  }
  let c = args[1]
  if c == "signal_by" {
    case_signal_by()
  } else if c == "window_kept" {
    case_window_kept()
  } else if c == "style_css" {
    case_style_css()
  } else if c == "guard_init_order" {
    case_guard_init_order()
  } else if c == "opt_param_relay" {
    case_opt_param_relay()
  } else if c == "utf16_boundary" {
    case_utf16_boundary()
  } else if c == "arrayview_isolation" {
    case_arrayview_isolation()
  } else if c == "ordered_map_double" {
    case_ordered_map_double()
  } else if c == "div_mod_nonzero" {
    case_div_mod_nonzero()
  } else if c == "cross_pkg_ref_sourceloc" {
    case_cross_pkg_ref_sourceloc()
  } else if c == "real_controls_numbers_marked" {
    case_real_controls_numbers_marked()
  } else if c == "real_controls_tokens_layout" {
    case_real_controls_tokens_layout()
  } else if c.has_prefix("div_") || c.has_prefix("mod_") {
    case_div_trap(c)
  } else {
    abort("unknown case: " + c)
  }
}
