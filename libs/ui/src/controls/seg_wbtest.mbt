// Segmented choice helpers (seg.mbt): thumb contrast and option_widths math.

///|
/// The thumb on the dark theme's track on every ground it may lie on: seen clearly off both 6% and 9.4% tracks
/// (>= 1.65:1, matching native iOS 27.0 resting `#68686E` with zero border/shadow) and chosen words read at >= 4.5:1.
test "the dark theme's segmented thumb seen off its track on every ground, its words read on it" {
  let lifted = @ui.Theme::narrow_dark().lifted
  let wrong : Array[String] = []
  for p in [("dark", dark_palette), ("web dark", web_dark)] {
    let (name, pal) = p
    let grounds = [
      ("page", pal.bg),
      ("canvas", pal.canvas),
      ("raised", pal.raised),
      ("sidebar", pal.sidebar),
      ("list", pal.list),
      ("selected", pal.selected),
      ("paper", pal.paper),
      ("card", pal.card),
      ("card2", pal.card2),
      ("chip", pal.chip),
    ]
    for g in grounds {
      for track_kind in [("6%", over(g.1, alpha(pal.text, 0.06))), ("9.4%", over(g.1, 0xFFFFFF18L))] {
        let track = track_kind.1
        let thumb = over(track, lifted)
        let seen = @ui.contrast_ratio(thumb, track)
        let read = @ui.contrast_ratio(pal.text, thumb)
        if seen < 1.65 {
          wrong.push("\{name}: the thumb on a \{track_kind.0} track on the \{g.0} \{seen}:1, under 1.65")
        }
        if read < 4.5 {
          wrong.push("\{name}: the chosen words on the thumb on the \{g.0} \{read}:1, under 4.5")
        }
      }
    }
  }
  if wrong.length() > 0 {
    fail(wrong.join("\n"))
  }
}

///|
test "option_widths: alike, none narrower than its words and sides; then their sides narrower; then their words smaller alike, to the least it may; then not side by side" {
  // words 40, 100 and 60 wide, 12 either side, 8 at the least
  let at = fn(room : Double, smallest : Double) { option_widths([40.0, 100.0, 60.0], room, 12.0, 8.0, smallest) }
  assert_eq(at(450.0, 1.0), ([150.0, 150.0, 150.0], Whole))
  // (the longer's 124 its own, the others sharing the rest)
  assert_eq(at(300.0, 1.0), ([88.0, 124.0, 88.0], Whole))
  // (their sides 10)
  assert_eq(at(260.0, 1.0), ([60.0, 120.0, 80.0], Whole))
  // (their words at 3/4, 8 either side: as far as they may go, to 0.7 of their size)
  assert_eq(at(198.0, 0.7), ([46.0, 91.0, 61.0], Smaller(0.75)))
  // (not that far: not side by side)
  assert_eq(at(198.0, 0.8), ([], Menu))
  assert_eq(at(248.0, 1.0), ([56.0, 116.0, 76.0], Whole))
  assert_eq(at(247.0, 1.0).1, Menu)
}
