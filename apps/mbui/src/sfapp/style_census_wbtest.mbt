// How many values of each kind the app's screens use (mbui's Tester::census over the fixtures' screens, narrow and
// wide, light and dark): sizes of words with their lines, weights, paddings and gaps, corners, colours. The styles'
// migration (mbui's ui/style.mbt) brings each down; scripts/style_census.sh prints them, and the values. What the old
// views draw and the window's tree's nodes are counted both (Tester::census: the tree's as each is set, Tree::styled).

///|
/// The screens counted: the fixtures' modes (scripts/shots.sh's) and the settings' pages.
let census_modes : Array[String] = [
  "home", "chat", "chat-compose", "chat-attach", "chat-quote", "chat-cards", "chat-md", "files", "drive", "drive-sub",
  "reader", "history", "chat-info", "chat-jobs", "video", "service", "share-in", "lock-code", "lock-wrong",
  "lock-waiting",
]

///|
let census_pages : Array[String] = [
  "home", "appearance", "me", "workspace", "security", "vault", "stations", "station:ws1/st1", "profiles",
  "profile:ws1/st1#cc", "connects", "memory:ws1/st1", "usage", "archive",
]

///|
test "styles: how many values of each kind the app's screens use" {
  let kinds : Array[(String, Map[String, Bool])] = [
    ("text", {}),
    ("weight", {}),
    ("space", {}),
    ("radius", {}),
    ("color", {}),
  ]
  let take = fn(k : @ui.Census) {
    for v in k.text {
      kinds[0].1[v] = true
    }
    for v in k.weight {
      kinds[1].1[v] = true
    }
    for v in k.space {
      kinds[2].1[v] = true
    }
    for v in k.radius {
      kinds[3].1[v] = true
    }
    for v in k.color {
      kinds[4].1[v] = true
    }
  }
  let screens : Array[(String, String)] = census_modes.map(fn(m) { (m, "") })
  for p in census_pages {
    screens.push(("settings", p))
  }
  for s in screens {
    for dark in ["", "-dark"] {
      for size in style_ref_sizes {
        let (_, w, h) = size
        new_run()
        @settings.reset()
        let src = fixture(s.0 + dark)
        let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform=platform_of(w))
        if s.1 != "" {
          open_setting(s.1)
        }
        t.draw()
        t.run_for(@ui.move_most_ms)
        take(t.census())
      }
    }
  }
  let counts = StringBuilder()
  for k in kinds {
    let values = k.1.keys().collect()
    values.sort()
    // (scripts/style_census.sh prints these)
    println("census " + k.0 + " " + values.length().to_string() + ": " + values.join(" "))
    counts.write_string(k.0 + " " + values.length().to_string() + "\n")
  }
  // Two fractional spaces are derived from the card's corner for a button and a shorter chooser in its foot; they
  // follow that corner and the controls' heights, rather than adding independent spacing tokens.
  // The settings' list and 关于 on the window's tree keep their list's scroll bar's thumb as a node while at rest (unseen
  // then), so its existing look is counted where the old list built none at rest: a corner of 1.5 and the bar's two inks
  // (24272B42, ECECED42), no token of its own.
  // 外观's 主题色 draws each accent other than the orange as a dot of its own colour, by day and by night (@sf.accents:
  // four of them, eight colours), and 自定义's outline round its ＋ (the ink at 24%, by day and by night): what the
  // setting shows, not a style's.
  // A station's dials, wide, are still 36 apart (dials_node's dl_row_wide), but as nodes that is a row's gap across,
  // which the tree's census does not count (Tree::styled: a node's paddings and its gap down only); the old view's
  // dials were its last 36.
  // The chats' lists keep room under their last row to scroll their tucked search out of view (Scroll::tucks' room,
  // 39 where the rows are short of a screen), worked out as they are laid out, no token of its own.
  // 记忆 shows recent diffs inline (tool_diff's faint_ground, red_bg, green_bg and green_ink, by day and by night).
  // Fewer once the settings' last old page (已归档) went to nodes and the old pages' parts with it (settings parts.mbt's
  // nav bar, section heads, empty and waiting rows): text 35 to 32, space 23 to 21, radius 23 to 22.
  // The glass controls share a neutral track colour, one for each theme.
  // One fewer once 设置 › 安全 was made of the library's rows (its own Web/Mobile rows' sizes gone): text 32 to 31.
  // Fewer once 小屏's bottom bar is made as nodes and its old view gone (its slots and offsets said by the tree, not as an
  // old box's padding and gap): space 21 to 19.
  // One more once chatPage is on by default on beta: 大屏's new chat page is made by new_chat_node, whose column keeps
  // new_column_in (32) from the pane's sides as its padding (the old new_chat took twice that off its width, so it was
  // never counted): space 19 to 20, no new spacing token.
  // Fewer once 小屏's bar is a glass capsule beside a glass circle (no notch, its disc and its ball's own colours gone):
  // radius 22 to 20, color 83 to 81.
  // One more once 小屏's compact 50pt bar uses a 25pt capsule radius and 21pt concentric pill radius: radius 20 to 21.
  // One more once top bar action pill groups (`bar_pill_group_node`) add 19pt/17pt concentric capsule radii: radius 21 to 22.
  // Two more once a page's room under its last block is its list's end_room (padding under what it scrolls) in place of
  // a block that tall (a block's height is not counted): pg_foot's 30 and desk_foot_h's 80, no new spacing token:
  // space 20 to 22.
  // One more once Appearance renders the Liquid Glass `@sf.value_slider_node` (6pt track / 24pt capsule thumb):
  // radius 22 to 23.
  // Four more once iOS 27 pressed-lens calibration updates resting Switch/Slider thumb shadows and Switch/Segmented track grounds:
  // color 83 to 87.
  // One fewer text style once pushed narrow sub-pages use the single-row floating inline Liquid Glass top bar instead of
  // the second-row 28pt Large Title: text 31 to 30.
  // One fewer text style once the compact grouped stations list reuses standard row title/meta typography: text 30 to 29.
  inspect(counts.to_string(), content=(
    #|text 29
    #|weight 4
    #|space 22
    #|radius 23
    #|color 87
    #|













































  ))
}
