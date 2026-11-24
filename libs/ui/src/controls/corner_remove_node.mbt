// What waits to go, with its ✕ hung on its top right corner (files.mbt with_corner_remove's), as nodes of the window's
// tree, made once: the ✕ a button over mbui's headless button (@headless.button), its look here.

///|
/// What `body` makes in a box of `parent`, rounded `corner`, with its ✕ hung on its top right corner (with_corner_remove's:
/// 20 round, solid in the ink's, the page's ✕ on it, its centre on the corner's curve where it turns 45°, reaching past
/// the top as far as past the right edge), over it. `hung`: the room it reaches into past the right edge kept at its
/// end (a file of a row: what comes next stands the row's gap past it), else it reaches into the room round it (a page
/// as wide as it is given). The ✕ named `label` (read out a button, as it changes), turned `turn` of a whole turn's
/// radians as it is drawn (an eighth: a ＋, which puts back what was taken out), `press` done as it is pressed.
/// `whole`: pressed anywhere on it too, the same (what `body` makes takes no press of its own then: its ✕'s layer, all
/// over it, takes them, the ✕ in it). The box `body` makes in (what is faded, as what waits to go is, the ✕ never).
#callsite(autofill(loc))
pub fn with_corner_remove_node(
  parent : @view.View,
  label : () -> String,
  corner : Double,
  body : (@view.View) -> Unit,
  press : () -> Unit,
  hung? : Bool = true,
  whole? : Bool = false,
  turn? : (@view.View) -> Double,
  loc~ : SourceLoc,
) -> @view.View {
  let reach = corner_remove_reach(corner)
  let mut inner : @view.View? = None
  parent.box(made_for=loc, fn(outer) {
    if hung {
      outer.padding(Is((0.0, 0.0, reach, 0.0))) |> ignore
    }
    inner = Some(
      outer.box(fn(i) {
        i.fills_across(Is(true)) |> ignore
        i.box(fn(b) {
          b.fills_across(Is(true)) |> ignore
          if whole {
            b.presses(Is(false)) |> ignore
          }
          body(b)
        })
        |> ignore
        // (over its top right corner, as far past its right edge as past its top; all over it where it is pressed
        // anywhere)
        i.box(fn(layer) {
          layer.over(Is(true)).lines_up(Is(Some(End))) |> ignore
          if whole {
            layer.presses(Is(true)).on_press(press) |> ignore
          }
          @headless.button(layer, label, fn(_) { press() }, fn(x, _) {
            x
            .width(Is(Some(corner_remove_side)))
            .height(Is(Some(corner_remove_side)))
            .radius(Is(corner_remove_side / 2.0))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .offset(Is((reach, -reach)))
            .ground(By(fn() { theme().p.text }))
            .focus_ring_theme()
            .flies_fade()
            |> ignore
            let mark = icon_node(x, "close", card_close_icon, By(fn() { theme().p.canvas }))
            match turn {
              Some(f) => mark.turn(By(fn() { f(mark) })) |> ignore
              None => ()
            }
          })
          |> ignore
        })
        |> ignore
      }),
    )
  })
  |> ignore
  inner.unwrap()
}
