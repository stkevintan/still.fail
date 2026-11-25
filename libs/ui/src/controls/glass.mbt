// still.fail's glass (web mobile/styles/pages.css.ts and ui/styles/glass.ts), as
// @ui.Glass for a box's `glass=`. Haze's blur radius is cssBlur(px) = (px - 0.5) / 0.57735 dp, which RenderEffect
// takes as a deviation of px dp: CSS blur(px)'s, what @ui.Glass's blur is. Each has its solid ground for where the
// system asks for less transparency: what the glass would be with nothing under it (the page's paper under its tint).

///|
/// A capsule floating over the list (mFloating, the composer's): iOS 27 liquid glass (`ios27Dark` / `ios27Light`
/// neutral tint when `tint` is `None`, or caller-supplied `tint` such as drag-over accent), its blur, bezel and
/// refraction the small screen's bottom bar's (`glass_tab_bar`) so the composer and the bar read as one glass;
/// `solid` preserves the opaque raised fallback under `MBUI_GLASS=solid`; `spot`, where a press lights it (points from
/// its top left: float_pill_group_node's).
pub fn glass_floating(tint? : Int64, spot? : (Double, Double)? = None) -> @ui.Glass {
  let t = theme()
  let solid = over(t.p.bg, alpha(tint.unwrap_or(t.p.raised), 0.72))
  @glass.liquid_floating_glass(tint~, solid~, spot~)
}

///|
/// Single-layer iOS 27 liquid glass for anchored popovers (`anchored_popover_shell`: menus, panels, picks, hover panels; `small_panel_node`).
pub fn glass_menu(merge? : Double = 0.0) -> @ui.Glass {
  let g = @glass.liquid_panel_glass(solid=panel_ground())
  if merge > 0.0 {
    { ..g, merge }
  } else {
    g
  }
}

///|
/// Three-anchor continuous optical interpolation for iOS 27.0 in-place liquid-droplet popover morphing:
/// - `stage == 0.0`: bar-pill anchor, bit-identical to `glass_bar_pill` (`a=0x67`, `blur=2.0`, `bezel=14`, `refr=20`, `rim=0.60`, `chroma=0.06`);
/// - `stage == 0.5`: mid-flight translucent droplet (`a=0x93` light / `0x88` dark, `blur=4.0`, `bezel=18`, `refr=16`, `rim=0.78`, `chroma=0.045`;
///   `refr/bezel=0.89 < 1.0` prevents fold-over while keeping backdrop text legible during morph);
/// - `stage == 1.0`: resting translucent menu anchor, bit-identical to `glass_menu` (`a=0xBF` light / `0xA8` dark, `blur=6.0`, `bezel=20`, `refr=26`, `rim=0.60`, `chroma=0.03`).
/// Alpha stays strictly within `0x67..0xBF` (at or above `kind == 6`'s `regMix` upper knee) for zero flash.
fn glass_menu_morph(
  stage : Double,
  merge? : Double = 0.0,
  layer? : Int = 0,
  break_gap? : Double = 0.0,
) -> @ui.Glass {
  @glass.liquid_menu_morph_glass(
    stage,
    solid=panel_ground(),
    dark=theme().dark,
    merge~,
    layer~,
    break_gap~,
  )
}

///|
/// Single-layer iOS 27 liquid glass for floating toast capsules (`toaster_node`): light translucent glass with
/// dark ink in Light mode, dark translucent glass with light ink in Dark mode.
pub fn glass_toast() -> @ui.Glass {
  @glass.liquid_toast_glass()
}

///|
/// High-translucency neutral single-layer iOS 27 liquid glass for floating controls over media (`viewer_steps_node`,
/// `viewer_page_glass`): desaturated backdrop (`saturation=0.55`, `blur=4.0`) prevents vivid saturated photos from
/// turning circular discs into colored stickers while keeping crisp 9/12 bezel refraction, specular rim, and legible
/// `<` / `>` chevrons in both Light and Dark themes.
pub fn glass_viewer_clear(spot? : (Double, Double)? = None) -> @ui.Glass {
  @glass.liquid_viewer_clear_glass(spot~, solid=theme().p.canvas)
}

///|
/// Dark translucent liquid glass for floating white-ink media viewer capsules (`dark_glass` / `viewer_marks_node`):
/// neutral dark iOS 27 glass with controlled saturation (`0.65`) and 9/12 liquid bevel refraction.
pub fn glass_viewer_dark(spot? : (Double, Double)? = None) -> @ui.Glass {
  @glass.liquid_viewer_dark_glass(spot~)
}

///|
/// Thin `@sf` bottom bar glass decorator delegating to `@glass.liquid_tab_bar_surface_decorate`: `v` drawn in the
/// bottom bar's glass at the `spot` and `merge` `glass_spec` answers as each frame is drawn,
/// `sharing()` where it does not merge given `share_when_unmerged`. Returns `v` for chaining.
pub fn tab_bar_surface_decorate(
  v : @view.View,
  glass_spec : () -> ((Double, Double)?, Double),
  share_when_unmerged? : Bool = false,
) -> @view.View {
  @glass.liquid_tab_bar_surface_decorate(v, glass_spec, share_when_unmerged~)
}

///|
/// The bottom bar's shadow by theme: delegates to `glass_control_shadow()` so all persistent liquid glass controls
/// share one calibrated outside-only shadow.
pub fn tab_bar_shadow() -> Raised {
  let (sigma, dy, color) = glass_control_shadow()
  { sigma, dy, color }
}

///|
/// The pill under the place shown inside glass: black at 7.1% on light grounds, white at 12% in the dark.
pub fn glass_selection() -> Int64 {
  if theme().dark {
    0xFFFFFF1FL
  } else {
    0x00000012L
  }
}

///|
/// A control's knob held (a switch's, a segmented choice's thumb): clear liquid glass lens, its rim narrower and
/// bending less, as small as it is.
pub fn glass_knob() -> @ui.Glass {
  let t = theme()
  @glass.liquid_knob_glass(solid=over(t.p.bg, alpha(t.p.raised, 0.72)))
}

///|
/// Thin `@sf` bottom bar lens decorator delegating to `@glass.liquid_tab_lens_surface_decorate`: `v` drawn in the
/// held lens's glass (its solid ground the theme's raised) as far as `press()` holds it, and
/// given `shadow`, that shadow outside only. Returns `v` for chaining.
pub fn tab_lens_surface_decorate(
  v : @view.View,
  press : () -> Double,
  shadow? : (Double, Double, Int64),
) -> @view.View {
  @glass.liquid_tab_lens_surface_decorate(v, press, solid=fn() { theme().p.raised }, shadow?)
}

///|
/// The shadow under the bottom bar's pressed lens: zeroed (`shadow_none`) for shadow-free lifted droplets.
pub let tab_lens_raised : Raised = { sigma: 0.0, dy: 0.0, color: 0x00000000L }

///|
/// Theme-aware outer shadow under the bottom bar's pressed lens: zeroed (`shadow_none`).
pub fn tab_lens_raised_for(_dark : Bool) -> Raised {
  tab_lens_raised
}

///|
fn track_glass_ink() -> Int64 {
  if theme().dark { 0x7878805CL } else { 0x78787833L }
}

///|
/// How far a sheet reaches on under the window's foot (sheet_node's: its foot's corners out of sight).
let sheet_under : Double = pane_corner

///|
/// The scrim under a sheet at its fullest: black at 28%.
pub let sheet_scrim : Int64 = 0x00000047L

///|
/// A sheet or floating side drawer over the page: single-layer symmetric 80% iOS 26 liquid glass (`0xFDFCFDCC` in
/// Light, `0x202020CC` in Dark, aligned with PR #8057 symmetric density curve; `blur=12`, `bezel=20`,
/// `refraction=24`). Degrades to opaque `t.p.bg` under `MBUI_GLASS=solid`.
pub fn glass_sheet() -> @ui.Glass {
  @glass.liquid_sheet_glass(solid=theme().p.bg)
}

///|
/// Thin `@sf` floating capsule surface decorator delegating to `@glass.liquid_capsule_decorate` with `glass_floating`
/// optics (supports dynamic `tint`, `extra_blur`, `sharing`, and opt-in `with_edge`/`with_shadow`/`clips`).
pub fn floating_capsule_decorate(
  v : @view.View,
  sharing? : Bool = false,
  tint? : () -> Int64?,
  extra_blur? : () -> Double,
  active? : () -> Bool,
  with_edge? : Bool = false,
  with_shadow? : Bool = true,
  clips? : Bool = false,
) -> @view.View {
  @glass.liquid_capsule_decorate(
    v,
    tone=Floating,
    sharing~,
    glass=fn(spot) {
      let custom = match tint {
        Some(f) => f()
        None => None
      }
      let g = glass_floating(tint?=custom, spot~)
      if sharing {
        g.sharing()
      } else {
        g
      }
    },
    extra_blur?,
    active?,
    shadow=glass_control_shadow,
    solid_edge=@glass.liquid_solid_edge,
    with_edge~,
    with_shadow~,
    clips~,
  )
}

///|
/// Thin `@sf` floating panel surface decorator delegating to `@glass.liquid_panel_surface_decorate` with
/// `panel_ground()`, `glass_overlay_shadow`, and `overlay_solid_edge`.
pub fn panel_surface_decorate(
  v : @view.View,
  radius? : Double,
  solid? : () -> Int64,
  merge? : () -> Double,
  active? : () -> Bool = fn() { true },
  clips? : Bool = false,
) -> @view.View {
  @glass.liquid_panel_surface_decorate(
    v,
    radius?,
    solid=match solid {
      Some(f) => f
      None => panel_ground
    },
    merge?,
    active~,
    shadow=glass_overlay_shadow,
    solid_edge=overlay_solid_edge,
    clips~,
  )
}

///|
/// Thin `@sf` floating side-drawer surface decorator delegating to `@glass.liquid_drawer_surface_decorate` with
/// `panel_ground()`, `glass_overlay_shadow`, and 1pt `panel_edge()` fallback under `MBUI_GLASS=solid`.
pub fn drawer_surface_decorate(
  v : @view.View,
  radius? : Double,
  solid? : () -> Int64,
  active? : () -> Bool = fn() { true },
  clips? : Bool = false,
) -> @view.View {
  @glass.liquid_drawer_surface_decorate(
    v,
    radius?,
    active~,
    solid=match solid {
      Some(f) => f
      None => panel_ground
    },
    shadow=glass_overlay_shadow,
    solid_edge=fn() { (1.0, panel_edge()) },
    clips~,
  )
}

///|
/// Thin `@sf` search capsule decorator delegating to `@glass.liquid_capsule_decorate` with `search_capsule_glass`,
/// `glass_overlay_shadow`, `overlay_solid_edge`, and `active` gating (zero hidden glass when inactive).
pub fn search_capsule_decorate(
  v : @view.View,
  active? : () -> Bool,
  solid? : () -> Int64,
  clips? : Bool = false,
) -> @view.View {
  @glass.liquid_capsule_decorate(
    v,
    tone=Floating,
    sharing=false,
    glass=fn(_) {
      match solid {
        Some(f) => search_capsule_glass(solid=f())
        None => search_capsule_glass()
      }
    },
    active?,
    shadow=glass_overlay_shadow,
    solid_edge=overlay_solid_edge,
    clips~,
  )
}

///|
/// Top-edge progressive blur soft scroll-edge backdrop whose ground depends on the fill node (`(@view.View) -> Int64`),
/// delegating directly to `@glass.liquid_scroll_edge_node`.
#callsite(autofill(loc))
pub fn top_scroll_edge_by_node(
  parent : @view.View,
  base_h : (@view.View) -> Double,
  fade_h : (@view.View) -> Double,
  ground : (@view.View) -> Int64,
  from_top? : Bool = false,
  shield? : Bool = true,
  loc~ : SourceLoc,
) -> @view.View {
  @glass.liquid_scroll_edge_node(
    parent,
    base_h,
    fade_h,
    side=Top,
    bg_by=ground,
    from_top~,
    shield~,
    loc~,
  )
}

///|
/// Thin `@sf` progressive blur scroll-edge fill decorator delegating to `@glass.liquid_scroll_edge_fill_decorate`
/// (zero wrapper nodes, one binding; emits `None` when `active()` is false).
pub fn scroll_edge_fill_decorate(
  fill : @view.View,
  ground : () -> Int64,
  active? : () -> Bool = fn() { true },
) -> @view.View {
  @glass.liquid_scroll_edge_fill_decorate(fill, ground, active~)
}
