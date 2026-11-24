// Progressive variable-blur scroll-edge backdrop (`UIScrollEdgeEffect.soft`).

///|
/// Which edge of a scroll viewport a `liquid_scroll_edge_node` softens.
#derive(Eq, Debug)
pub(all) enum ScrollEdgeSide {
  Top
  Bottom
}

///|
/// Decorates an existing scroll-edge fill node `fill` in place (zero wrapper nodes, one binding) with
/// `liquid_scroll_edge_glass(bg=bg())` while `active()` is true, and `None` when inactive (zero hidden glass).
pub fn liquid_scroll_edge_fill_decorate(
  fill : @view.View,
  bg : () -> Int64,
  active? : () -> Bool = fn() { true },
) -> @view.View {
  fill.glass(
    By(fn() {
      if active() {
        Some(liquid_scroll_edge_glass(bg=bg()))
      } else {
        None
      }
    }),
  )
}

///|
/// Native four-platform progressive variable-blur scroll-edge backdrop (`UIScrollEdgeEffect.soft`, `progressive=true`)
/// anchored to the `Top` or `Bottom` edge of `parent`.
///
/// Blurs scrolled content smoothly over `fade_h` within a `base_h`-tall band, emits zero hidden glass
/// instances when `base_h(fill) <= 0.0`, and when `shield=true` (default) blocks click-through onto scrolled content
/// behind floating top/bottom bars without affecting hover.
#callsite(autofill(loc))
pub fn liquid_scroll_edge_node(
  parent : @view.View,
  base_h : (@view.View) -> Double,
  fade_h : (@view.View) -> Double,
  side? : ScrollEdgeSide = Top,
  bg? : () -> Int64,
  bg_by? : (@view.View) -> Int64,
  from_top? : Bool = false,
  shield? : Bool = true,
  pure? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let build_scrim = fn(scrim : @view.View) {
    scrim
    .width_share(Is(1.0))
    .height(By(fn() { Some(base_h(scrim)) }))
    .fades(
      By(fn() {
        match side {
          Top => (0.0, 0.0, 0.0, fade_h(scrim))
          Bottom => (0.0, fade_h(scrim), 0.0, 0.0)
        }
      }),
    )
    |> ignore
    scrim.box(fn(fill) {
      // Register fill in inputs_in via pointed() while keeping points=false when shield=true so Tree::target_at
      // visits fill and applies Node::covers to block click-through onto scrolled content without affecting hover.
      fill
      .width_share(Is(1.0))
      .height_share(Is(1.0))
      .glass(
        By(fn() {
          if base_h(fill) > 0.0 {
            let color = match bg_by {
              Some(f) => f(fill)
              None =>
                match bg {
                  Some(f) => f()
                  None => clear
                }
            }
            Some(liquid_scroll_edge_glass(bg=color, pure~))
          } else {
            None
          }
        }),
      )
      .points(Is(false))
      |> ignore
      if shield {
        @signals.untracked(fn() { fill.pointed() }) |> ignore
      }
    })
    |> ignore
  }
  match side {
    Top =>
      parent.box(made_for=loc, fn(scrim) {
        scrim.over(Is(true), from_top~) |> ignore
        build_scrim(scrim)
      })
    Bottom =>
      parent.box(made_for=loc, fn(wrap) {
        wrap.over(Is(true)).points(Is(false)).lies_along(Is(End)) |> ignore
        wrap.box(build_scrim) |> ignore
      })
  }
}
