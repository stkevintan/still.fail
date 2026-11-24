// A station's card over where a chat names it, and its part under an agent's card, as nodes in a hover card
// (settings' station_peek_card_node, station_peek_part_node in @sf.hover_card_node) on one fixture: what each says
// and draws up (by a relay, a way still chosen, coming back) and down, a mark of its own or none, its name long, its
// screens' menu open (with screens and with none), and the audit's faults of each.

///|
/// The fixture's station.
// kept across runs: a value
let peek_at : String = "ws1/st1"

///|
/// The fixture's source (chat-station-tag), what the core says of its station changed by `change` (the topic's name,
/// what it says): as the station whole (`station`), its row (`stations`) and its screens.
fn peek_src(change : (String, Json?) -> Json?) -> Source {
  let base = @sffixture.fixture("chat-station-tag")
  {
    ..base,
    topic_read: fn(topic, params) {
      let got = (base.topic_read)(topic, params)
      { ..got, value: change(topic, got.value) }
    },
  }
}

///|
/// `v`, the station (the station's own topic, or the station among `stations`' rows) its fields `kv` said in place of
/// its own.
fn peek_said_as(v : Json?, kv : Array[(String, Json)]) -> Json? {
  let one = fn(x : Json) -> Json {
    match x {
      Object(m) => {
        let o = m.copy()
        for p in kv {
          o[p.0] = p.1
        }
        Json::object(o)
      }
      _ => x
    }
  }
  match v {
    Some(Array(a)) => Some(Json::array(a.map(fn(x) { if text(Some(x), "station") == peek_at { one(x) } else { x } })))
    Some(x) => Some(one(x))
    None => None
  }
}

///|
/// The states compared, by name: what each changes.
fn peek_cases() -> Array[(String, (String, Json?) -> Json?)] {
  let station = fn(kv : Array[(String, Json)]) {
    fn(topic : String, v : Json?) { if topic == "station" { peek_said_as(v, kv) } else { v } }
  }
  [
    ("as the fixture", fn(_t, v) { v }),
    ("by a relay", station([("way", { "path": "中继", "via": "relay" })])),
    ("a way chosen", station([("way", { "via": "choosing" })])),
    ("coming back", station([("reconnecting", true)])),
    ("down", station([("online", false)])),
    ("down, updating", station([("online", false), ("problems", [{ "key": "updating", "text": "正在更新，马上回来" }])])),
    ("no mark", station([("icon", ""), ("emoji", "")])),
    ("an emoji", station([("icon", ""), ("emoji", "🌳")])),
    (
      "a long name",
      fn(topic, v) {
        if topic == "stations" {
          peek_said_as(v, [("name", "Willow 的工作站，放在三楼机房最里面那排的第二台")])
        } else {
          v
        }
      },
    ),
    (
      "with screens",
      fn(topic, v) {
        if topic == "screens" {
          Some({ "screens": [{ "id": "desktop", "title": "Willow 的屏幕", "kind": "desktop" }] })
        } else {
          v
        }
      },
    ),
  ]
}

///|
/// Where the trigger is (as the chat's bar's tag): 40 in, 40 down, 120 by 32.
// kept across runs: a value
let peek_trigger : (Double, Double, Double, Double) = (40.0, 40.0, 120.0, 32.0)

///|
/// A Tester's words and rectangles, a line each (message_words_node_wbtest's said_drawn_back, nothing moved).
fn peek_drawn(t : @ui.Tester) -> Array[String] {
  t.words().filter(fn(w) { w.5 > 0.0 || w.3 > 0.0 }).map(fn(w) { "\{w.0}@\{w.1},\{w.2} \{w.3}x\{w.4} a\{w.5}" }) +
  t.drawn_rects().map(fn(r) { "\{r.0},\{r.1} \{r.2}x\{r.3} \{r.4}" })
}

///|
/// The pointer resting on the trigger till a card is in whole; then, `menu` (its words' key), on that card's row of
/// those words till its menu is.
fn peek_rest_on(t : @ui.Tester, menu : String) -> Unit {
  let (x, y, w, h) = peek_trigger
  t.move_to(x + w / 2.0, y + h / 2.0)
  t.run_for(hover_open_ms + @ui.move_most_ms)
  if menu != "" {
    // (`menu` the words' key, read now the run's Tester is made)
    let menu = @sf.t(menu)
    match t.find(menu) {
      Some((mx, my)) => {
        t.move_to(mx, my)
        t.run_for(@ui.move_most_ms)
      }
      None => @halt.saying("no \{menu} drawn")
    }
  }
}

///|
/// What the nodes draw: the trigger, `body` in a hover card over it (a tile, padded or not; a finger's tap its own, as
/// the chat's bar's tag), the pointer resting on it; the fixture's station's states as `change` says; the card's row
/// `menu` rested on too.
fn peek_new(change : (String, Json?) -> Json?, body : (@view.View) -> Unit, padded? : Bool = false, menu? : String = "") -> @ui.Tester {
  @sf.set_words(@sfbase.fill)
  let src = peek_src(change)
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      match @sfbase.workspace_in_view(src).0 {
        Some(w) => @settings.panels_frame(@sfbase.settings_core(src, w), w.id)
        None => ()
      }
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let (x, y, w, h) = peek_trigger
      root.box(fn(f) {
        f.padding(Is((x, y, 0.0, 0.0))) |> ignore
        f.box(fn(k) {
          k.width(Is(Some(w))).height(Is(Some(h))).says(Is(Some(@view.said(Text, label="peek-trigger")))) |> ignore
          @sf.hover_card_node(tips, k, body, tile=true, padded~, tapped=fn() {  }) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=1280.0,
    h=800.0,
    platform=0,
  )
  peek_rest_on(t, menu)
  t
}

///|
/// Of the audit's faults, those of its machine faded while it is reconnecting (peek_faded, 0.45: its allowance's chips'
/// words and its network's then fainter than the contrast asks), and the rest. Kept as it is, its colour the
/// product's (BRIEF: contrast is how it looks): said exactly `peek_faded_faults` times where it is coming back, so that
/// mended, this goes.
fn peek_faded_apart(faults : Array[String], name : String) -> (Array[String], Array[String]) {
  let faded = faults.filter(fn(f) {
    name == "coming back" &&
    f.has_prefix("words ") &&
    f.contains(":1, under 4.5") &&
    (f.contains("ui/src/controls/meter_atoms_node.mbt:") || f.contains("stillfail/src/sfapp/settings/station_net_node.mbt:"))
  })
  (faded, faults.filter(fn(f) { !faded.contains(f) }))
}

///|
/// How many such a reconnecting station's card has: its three chips' marks and figures (a mark run on into its figure
/// one line of words: fill_chip's chip_joined), its network's words.
let peek_faded_faults : Int = 12

///|
/// What a card or a part says in state `name`, words each that must be drawn (`part`: the part under an agent's card,
/// whose head says no more of a station down than why), and words that must not be (its machine where it is down).
fn peek_says(name : String, part : Bool) -> (Array[String], Array[String]) {
  let said = "Apple M1 Pro · 2 个 agent 在工作"
  let machine = ["CPU", "空闲 72%", "内存剩 5.8 G", "磁盘剩 420 G", "直连", "38 ms", "96 KB/s", "1.4 MB/s"]
  let ways = ["屏幕", "文件", "机器详情"]
  match name {
    "down" =>
      (
        ["Willow", @sfbase.fill("android-settings.stations.offline", [("app", "still.fail")])] +
        (if part { [] } else { [said] }) +
        ways,
        machine + (if part { [said] } else { [] }),
      )
    "down, updating" => (["Willow", "正在更新，马上回来"] + (if part { [] } else { [said] }) + ways, machine)
    "no mark" => (["Willow", said] + (if part { ["W"] } else { [] }) + machine + ways, [])
    "an emoji" => (["🌳", "Willow", said] + machine + ways, [])
    "a long name" => (["Willow 的工作站，放在三楼机房最里面那排的第二台", said] + machine + ways, [])
    _ => (["Willow", said] + machine + ways, [])
  }
}

///|
/// What is wrong of what Tester `t` draws in state `name` (a card, or a `part`): words it should say and does not, or
/// should not and does; the audit's faults but those of its machine faded while it comes back, and those as many as
/// they are said to be.
fn peek_state_faults(t : @ui.Tester, name : String, part : Bool) -> Array[String] {
  let faults = []
  let drawn = t.words().filter(fn(w) { w.5 > 0.0 || w.3 > 0.0 }).map(fn(w) { w.0 })
  let (must, never) = peek_says(name, part)
  for w in must {
    if !drawn.contains(w) {
      faults.push("\{name}: \{w} not drawn: \{Repr(drawn)}")
    }
  }
  for w in never {
    if drawn.contains(w) {
      faults.push("\{name}: \{w} drawn: \{Repr(drawn)}")
    }
  }
  let (faded, a) = peek_faded_apart(t.audit(), name)
  if a.length() > 0 {
    faults.push("\{name}: audit: \{Repr(a)}")
  }
  if faded.length() != (if name == "coming back" { peek_faded_faults } else { 0 }) {
    faults.push("\{name}: \{faded.length()} faded words fainter than the contrast asks: \{Repr(faded)}")
  }
  faults
}

///|
test "a station's card as nodes: what it says in each state, each drawn otherwise than the fixture's, no fault of the audit's but its faded machine's" {
  let faults = []
  let mut first : Array[String] = []
  for case in peek_cases() {
    let (name, change) = case
    let t = peek_new(change, fn(b) { @settings.station_peek_card_node(b, peek_at, fn() { 0 }) })
    let new = peek_drawn(t)
    assert_true(new.length() > 4, msg="\{name}: the card drawn: \{Repr(new)}")
    // (each state drawn otherwise than the fixture's, but its screens, which show only in its menu)
    if first.length() == 0 {
      first = new
    } else if name != "with screens" && new == first {
      faults.push("\{name}: drawn as the fixture is")
    }
    faults.append(peek_state_faults(t, name, false))
  }
  assert_eq(faults, [], msg=faults.join("\n"))
}

///|
/// What stands over a station's part in its card in the tests (its agent's card in the app): 40 high.
// kept across runs: a value (no field of it changes)
let peek_over_part : @ui.Style = @ui.css("w=Full h=S10")

///|
test "a station's part as nodes (under its agent's, in one card): what it says in each state, each up or down drawn otherwise than the fixture's, no fault of the audit's but its faded machine's" {
  let faults = []
  let mut first : Array[String] = []
  for case in peek_cases() {
    let (name, change) = case
    // (under something as its agent's card is, not in the card's corner: its square is round as a block within)
    let t = peek_new(change, fn(b) {
      b.box(fn(o) { @sf.style_node(o, fn() { peek_over_part }) }) |> ignore
      @settings.station_peek_part_node(b, peek_at, fn() { 0 })
    })
    let new = peek_drawn(t)
    assert_true(new.length() > 4, msg="\{name}: the part drawn: \{Repr(new)}")
    // (its dot says only whether it is up, not how it is reached: by a relay or a way still chosen, as the fixture)
    if first.length() == 0 {
      first = new
    } else if !["with screens", "by a relay", "a way chosen"].contains(name) && new == first {
      faults.push("\{name}: drawn as the fixture is")
    }
    faults.append(peek_state_faults(t, name, true))
  }
  assert_eq(faults, [], msg=faults.join("\n"))
}

///|
test "a station's card as nodes, its 屏幕 rested on: its menu beside it, with the fixture's screens, with one and with one and its browser" {
  let faults = []
  let with_browser = (
    "with screens and its browser",
    fn(topic : String, v : Json?) -> Json? {
      if topic == "screens" {
        Some({
          "screens": [{ "id": "desktop", "title": "Willow 的屏幕", "kind": "desktop" }],
          "browser": true,
          "control": true,
        })
      } else {
        v
      }
    },
  )
  for case in peek_cases().filter(fn(c) { c.0 == "as the fixture" || c.0 == "with screens" }) + [with_browser] {
    let (name, change) = case
    // (its 屏幕's words read once the run's Tester is made: peek_rest_on's)
    let menu = "android-misc.screen.section"
    let shut = peek_drawn(peek_new(change, fn(b) { @settings.station_peek_card_node(b, peek_at, fn() { 0 }) }))
    let t = peek_new(change, fn(b) { @settings.station_peek_card_node(b, peek_at, fn() { 0 }) }, menu~)
    let open = peek_drawn(t)
    // (its menu drawn over what the card drew)
    if open.length() <= shut.length() {
      faults.push("\{name}: no menu drawn")
    }
    // its items as the station's screens are: grouped where there are more kinds than one (screens, its browser: the
    // pages agents drive in it)
    let items = if name == "with screens" {
      ["Willow 的屏幕"]
    } else if name == "with screens and its browser" {
      ["Willow 的屏幕", "打开浏览器"]
    } else {
      ["Willow 的屏幕", "浏览器", "发布清单 - 文档"]
    }
    let rows = t.words().filter(fn(w) { w.0 == "机器详情" })
    // (no heading where no agent drives pages: each part one kind of row, its icon telling it, and 屏幕 the row rested on)
    if name == "with screens and its browser" {
      for heading in ["屏幕", "浏览器"] {
        if t.words().any(fn(w) { w.0 == heading && w.5 > 0.0 && rows.any(fn(r) { w.1 > r.1 }) }) {
          faults.push("\{name}: heading \{heading} drawn beside the card")
        }
      }
    }
    for item in items {
      match (t.words().filter(fn(w) { w.0 == item && w.5 > 0.0 }), rows) {
        ([w, ..], [r, ..]) =>
          // (beside the card: starting past where its rows' words do)
          if w.1 <= r.1 {
            faults.push("\{name}: \{item} at \{w.1}, not beside the card's rows at \{r.1}")
          }
        _ => faults.push("\{name}: \{item} not drawn")
      }
    }
  }
  assert_eq(faults, [], msg=faults.join("\n"))
}
