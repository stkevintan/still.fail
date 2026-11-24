// The page round the parts, as component libraries' sites are (Storybook, shadcn/ui, Ant Design, Primer): the list of
// them at the side (by group, with a search over it), an overview of all of them as cards, and a part's page: what it
// is, its Playground (its arguments changed by controls, the call they make written under it), each of its states in a
// card with the lines that make it, and its functions as the library declares them. Light or dark and the width the
// parts are shown at over it. In a narrow window the list is a sheet a button in the bar opens.

///|
/// A part, as the list names it and the page shows it: its key (?STORY=), its group, its name, the file it is in under
/// src/sf, what it is, its functions (their file under src/sf, their name), its Playground, and its states, each what
/// it is said to show and how it is made in the card given.
priv struct Story {
  key : String
  group : String
  name : String
  file : String
  about : String
  api : Array[(String, String)]
  play : (() -> Play)?
  cases : Array[(String, (@view.View) -> Unit)]
}

///|
/// The width the parts are shown at: 小屏's, a page's at 中屏, or all of what is left of the window.
let widths : Array[(String, Double?)] = [("390", Some(390.0)), ("768", Some(768.0)), ("全宽", None)]

///|
/// How wide the list at the side is: 248, wider as the words grow past 1.3× (at 2×, its title on one line still).
fn side_width() -> Double {
  248.0 * @sf.dmax(1.0, @ui.font_scale() / 1.3)
}

///|
/// Whether a window this wide shows the list at its side (else a sheet the bar's button opens).
fn side_shown(w : Double) -> Bool {
  w >= 720.0
}

///|
/// The old frame round the tree: on 小屏 the library's menus, picks and questions are its, as the app's frame has them.
pub fn stories_view(c : @ui.Ctx) -> Unit {
  @sf.presented(c)
}

///|
/// The page, opened on the part whose key is `first` (?STORY=; "" or one not known: the overview): what is shown is the
/// overview of all the parts (-1), or a part, by its place in the list (the foundations first). Made by the browser's
/// page (src/sfstories) and by the offscreen renderer (MBUI_FIXTURE=stories:<key>, src/sfwasmfilm) alike.
pub fn stories_tree(first : String) -> (@view.View) -> Unit {
  fn(root) { stories_made(root, first) }
}

///|
fn stories_made(root : @view.View, first : String) -> Unit {
  // (no core: the real core's answers to the library's pure calls, kept; the faces its avatars draw; MBUI_DARK=1 the
  // dark theme)
  @sf.kept_call.val = Some(@sfkept.answer)
  @sf.give_faces()
  if @ui.env("MBUI_DARK") == "1" {
    @sf.set_dark(Some(true))
  }
  // (the library's words, the app's catalog's: what its parts say themselves, 取消 and the like)
  @sf.set_words(@sfbase.fill)
  @ui.set_tree_theme(@sf.ui_theme_now)
  // (the workbench's size of words, input and language, as MBUI_FONT_SCALE, MBUI_POINTING and MBUI_LANG say: matrix.mbt)
  let env = env_started()
  let tips = @sf.TipLayer::new(fn() { Some(root) })
  let all = foundations() + motion_stories(tips) + stories(tips, layer=fn() { Some(root) }) + workbench_stories(env)
  let chosen = @signals.signal(all.search_by(fn(s) { s.key == first }).unwrap_or(-1))
  let width = @signals.signal(2)
  let query = @signals.signal("")
  let wide = fn() { side_shown(root.window_w()) }
  // (the list's width; what is left of the window the parts', said as a width so that what shares its room by it (a
  // filled segmented) is given that room, not what it holds)
  let side_w = fn() { if wide() { side_width() } else { 0.0 } }
  let main_w = fn() { Some(@sf.dmax(0.0, root.window_w() - side_w())) }
  // (the bar's 跳转, what the jump goes beside however it is asked: by its button or by ⌘K / Ctrl+K)
  let jump : Ref[@view.View?] = Ref(None)
  // (what is drawn under it all: the root's own ground is the host's)
  root.box(fn(page) {
    page
    .grow(Is(1.0))
    .row(Is(true))
    .ground(By(fn() { @sf.theme().p.bg }))
    .keymap(Is(jump_keys))
    .on_action(jump_action, fn(_) {
      jump_open(all, chosen, jump)
      true
    })
    |> ignore
    page.show(wide, at_once=true, fn(side) { side_node(side, all, chosen, query) })
    page.box(fn(main) {
      main.width(By(main_w)) |> ignore
      bar_node(main, all, chosen, width, query, wide, jump, env)
      main.box(fn(held) {
        held.grow(Is(1.0)).min_height(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        held.scrolls(@view.Scroll::new(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(col) {
          col.width(By(main_w)) |> ignore
          col.pick(fn() { chosen.get() }, at_once=true, fn(at, i) {
            if i < 0 {
              overview_node(at, all, chosen)
            } else {
              story_node(at, all[i], fn() { widths[width.get()].1 })
            }
          })
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  @sf.presented_nodes(root)
  @sfbase.toasts_node(root, fn() { 24.0 }) |> ignore
}

///|
/// The jump's action, and its keys: ⌘K, and Ctrl+K where there is no ⌘.
let jump_action : String = "kit.jump"

///|
// kept across runs: a value (no field of it changes)
let jump_keys : @view.Keymap = @view.Keymap::new([
  { keys: [{ code: @ui.key_of_char('k'), mods: @ui.mod_cmd }], action: jump_action, when: Always },
  { keys: [{ code: @ui.key_of_char('k'), mods: @ui.mod_ctrl }], action: jump_action, when: Always },
])

///|
/// Whether part `s` is one `query` finds: its name, key, group or file holding it, case aside.
fn found(s : Story, query : String) -> Bool {
  let q = query.trim(chars=" ").to_lower()
  q == "" || [s.name, s.key, s.group, s.file].iter().any(fn(w) { w.to_lower().contains(q) })
}

///|
/// The rows of the list: 总览, then each group's name over its parts `query` finds; `picked` told the one pressed.
fn list_rows(
  list : @view.View,
  all : Array[Story],
  chosen : @signals.Signal[Int],
  query : @signals.Signal[String],
  picked : () -> Unit,
) -> Unit {
  // (a row a key: -1 the overview, a part its place in the list, a group's name -2 less the place of its first part)
  let keys = fn() {
    let q = query.get()
    let out = [-1]
    let mut group = ""
    for i, s in all {
      if found(s, q) {
        if s.group != group {
          group = s.group
          out.push(-2 - i)
        }
        out.push(i)
      }
    }
    out
  }
  list.each(keys, fn(k) { k }, at_once=true, fn(row, k) {
    let key = k.untracked()
    if key == -1 {
      @sf.choice_row_node(
        row,
        fn() { "总览" },
        fn() { chosen.get() < 0 },
        press=fn() {
          chosen.set(-1)
          picked()
        },
        compact=true,
      )
    } else if key < -1 {
      let named = all[-2 - key].group
      row.box(fn(h) {
        h.padding(Is((12.0, 14.0, 12.0, 4.0))) |> ignore
        @sf.words_node(h, fn() { named }, fn() { @sf.caption }) |> ignore
      })
      |> ignore
    } else {
      let i = key
      @sf.choice_row_node(
        row,
        fn() { all[i].name },
        fn() { chosen.get() == i },
        press=fn() {
          chosen.set(i)
          picked()
        },
        compact=true,
      )
    }
  })
}

///|
/// The search over the list.
fn search_node(v : @view.View, query : @signals.Signal[String]) -> Unit {
  @sf.input_node(
    v,
    @ui.Field::new(text=@signals.untracked(fn() { query.get() })),
    placeholder="搜索组件",
    small=true,
    edited=fn(t) { query.set(t) },
  )
  |> ignore
}

///|
/// The list at the side: the library's name, the search, the rows.
fn side_node(side : @view.View, all : Array[Story], chosen : @signals.Signal[Int], query : @signals.Signal[String]) -> Unit {
  let brand = @ui.env("MBUI_BRAND")
  side.width(By(fn() { Some(side_width()) })).ground(By(fn() { @sf.theme().p.sidebar })) |> ignore
  side.box(fn(head) {
    head.padding(Is((20.0, 20.0, 20.0, 8.0))).gap(Is(4.0)) |> ignore
    @sf.words_node(
      head,
      fn() {
        if brand == "" {
          "still.fail 组件"
        } else if @sf.language() == "en" {
          brand
        } else {
          "\{brand} 组件"
        }
      },
      fn() { @sf.title },
    )
    |> ignore
    // (where its parts are, and how many pages: two words side by side, not joined in one line)
    head.box(fn(r) {
      r.row(Is(true)).wraps(Is(Some(4.0))).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
      @sf.words_node(r, fn() { "libs/ui/src/controls" }, fn() { @sf.meta }) |> ignore
      @sf.pill_node(r, fn() {
        if brand != "" && @sf.language() == "en" {
          "\{all.length()} stories"
        } else {
          "\{all.length()} 页"
        }
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  side.box(fn(s) {
    s.padding(Is((16.0, 4.0, 16.0, 8.0))) |> ignore
    search_node(s, query)
  })
  |> ignore
  side.box(fn(held) {
    held.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    held.scrolls(@view.Scroll::new(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(list) {
      list.padding(Is((8.0, 0.0, 8.0, 24.0))) |> ignore
      list_rows(list, all, chosen, query, fn() {  })
    })
    |> ignore
  })
  |> ignore
}

///|
/// The bar over what is shown: in a narrow window the button that opens the list; its name and file; the width the
/// parts are shown at (where the window has the room for it to mean anything); the jump to any page (⌘K); the colour
/// theme's dots in a panel of their own; light or dark. `jump` says what the jump goes beside, its button. Before the
/// jump, the workbench's 环境 (matrix.mbt): its words saying what is chosen where the bar has the room, else its icon.
fn bar_node(
  main : @view.View,
  all : Array[Story],
  chosen : @signals.Signal[Int],
  width : @signals.Signal[Int],
  query : @signals.Signal[String],
  wide : () -> Bool,
  jump : Ref[@view.View?],
  env : Env,
) -> Unit {
  // (the room for 环境's words beside the width's choice and the bar's buttons, more chosen said longer)
  let env_worded = fn() { main.window_w() >= 1008.0 }
  main.box(fn(bar) {
    bar
    .row(Is(true))
    .gap(By(fn() { if wide() { 12.0 } else { 4.0 } }))
    .padding(By(fn() { if wide() { (24.0, 14.0, 24.0, 14.0) } else { (8.0, 8.0, 8.0, 8.0) } }))
    .lines_up(Is(Some(Middle)))
    |> ignore
    bar.show(fn() { !wide() }, at_once=true, fn(b) {
      @sf.icon_button_opens_node(b, "list", fn() { "组件" }, fn(opener) {
        @sf.panel_nodes(
          "组件",
          fn(body, close) {
            search_node(body, query)
            body.box(fn(list) { list_rows(list, all, chosen, query, close) }) |> ignore
          },
          from=@sf.Anchor::Node(opener),
        )
      })
      |> ignore
    })
    bar.box(fn(name) {
      // (what the bar's buttons leave, never what its words would want: at 2× words its file is wider than a phone)
      name.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).gap(Is(2.0)) |> ignore
      @sf.words_node(
        name,
        fn() {
          let i = chosen.get()
          if i < 0 {
            "总览"
          } else {
            all[i].name
          }
        },
        fn() { bar_name },
      )
      |> ignore
      @sf.words_node(
        name,
        fn() {
          let i = chosen.get()
          if i < 0 {
            "\{all.length()} 页"
          } else {
            let f = all[i].file
            if f.contains("/") {
              f
            } else {
              library_path + f
            }
          }
        },
        fn() { bar_file },
      )
      |> ignore
    })
    |> ignore
    bar.show(wide, at_once=true, fn(w) {
      @sf.seg_node(w, fn() { widths.map(fn(w) { w.0 }) }, fn() { width.get() }, fn(i) { width.set(i) }, said="宽度") |> ignore
    })
    bar.show(env_worded, at_once=true, fn(e) {
      @sf.button_opens_node(e, fn() { env.words() }, fn(opener) { env_open(opener, env) }, tone=Ghost, icon="devices")
      |> ignore
    })
    bar.show(fn() { !env_worded() }, at_once=true, fn(e) {
      @sf.icon_button_opens_node(e, "devices", fn() { env.words() }, fn(opener) { env_open(opener, env) }) |> ignore
    })
    jump.val = Some(
      @sf.icon_button_node(bar, "search", fn() { "跳转到页面" }, fn() { jump_open(all, chosen, jump) }, shortcut="⌘K"),
    )
    @sf.icon_button_opens_node(bar, "sliders", fn() { "主题色" }, fn(opener) {
      @sf.panel_nodes(
        "主题色",
        fn(body, _) {
          // (6 in from the panel's own padding: each dot a circle concentric with the panel's corners, 12 in, and the
          // room a press reaches round it whole)
          body.box(fn(b) {
            b.pad(Is(accents_in)) |> ignore
            accents_node(b)
          })
          |> ignore
        },
        from=@sf.Anchor::Node(opener),
        fits=true,
      )
    })
    |> ignore
    @sf.icon_button_node(
      bar,
      "moon",
      fn() { if @sf.theme().dark { "浅色" } else { "深色" } },
      fn() { @sf.set_dark(Some(!@signals.untracked(fn() { @sf.theme().dark }))) },
      icon_now=fn() { if @sf.theme().dark { "sun" } else { "moon" } },
    )
    |> ignore
  })
  |> ignore
  main.box(fn(rule) { @sf.style_node(rule, fn() { @sf.rule_line }) }) |> ignore
}

///|
/// Where the library's files are, as the bar names a part's.
let library_path : String = "libs/ui/src/controls/"

///|
/// The bar's file under the part's name: as the page's meta, on one line, cut short where the bar has not the room.
// kept across runs: a value (no field of it changes)
let bar_file : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Cut, wrap=false)

///|
/// The bar's part's name: as a desk's strong words, on one line, cut short where the bar has not the room (a phone's
/// at 2× words).
// kept across runs: a value (no field of it changes)
let bar_name : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Semibold, color=Fg, w=Cut, wrap=false)

///|
/// The colour themes (@sf.accents, and a hue of one's own) as the app's 外观 offers them, its dots in their own colours:
/// one chosen, every part drawn in it at once.
fn accents_node(v : @view.View) -> Unit {
  @sf.accent_pick_node(
    v,
    fn() { accent_names },
    fn() { "五彩色" },
    fn() { "自定义" },
    fn() { "色相" },
    fn() { @sf.accent_key() },
    fn(key) { @sf.set_accent(key) },
  )
}

///|
/// How far in the bar's panel holds its dots past its own padding.
let accents_in : Double = 6.0

///|
/// The colour themes' names, as @sf.accents has them.
// kept across runs: a value (no element of it changes)
let accent_names : Array[String] = ["暖橙", "蓝", "青", "紫", "粉"]

///|
/// The jump to any page (⌘K, the bar's 跳转): a pick of every page by its name, the foundations and the parts, its
/// search over them (what is typed finds a page by its name, its group or its file; Enter goes to the first found),
/// beside the bar's button; chosen, that page.
fn jump_open(all : Array[Story], chosen : @signals.Signal[Int], jump : Ref[@view.View?]) -> Unit {
  guard jump.val is Some(at) else { return }
  let choices = [@sf.choice("-1", "总览", note="\{all.length()} 页")]
  for i, s in all {
    choices.push(@sf.choice(i.to_string(), s.name, note=s.group, value=s.file))
  }
  @sf.pick("跳转到页面", choices, chosen.untracked().to_string(), fn(k) {
    let i = @string.parse_int(k[:]) catch { _ => return }
    chosen.set(i)
  }, from=Node(at), along=End)
}

///|
/// A box in which what is made shows and takes nothing (a thumbnail of a part).
fn still_box(v : @view.View, make : (@view.View) -> Unit) -> Unit {
  v.box(fn(b) {
    b.in_use(Is(false)) |> ignore
    make(b)
  })
  |> ignore
}

///|
/// All the parts as cards, each its name, its group and its first state drawn small; pressed, its page.
fn overview_node(page : @view.View, all : Array[Story], chosen : @signals.Signal[Int]) -> Unit {
  let brand = @ui.env("MBUI_BRAND")
  let narrow = fn() { page.window_w() < 720.0 }
  page.padding(By(fn() { if narrow() { (16.0, 16.0, 16.0, 48.0) } else { (24.0, 24.0, 24.0, 48.0) } })).gap(Is(16.0))
  |> ignore
  @sf.words_node(
    page,
    fn() {
      if brand == "" {
        "still.fail 的界面都由这些部件拼成（libs/ui/src/controls）。最前面是设计基石：色板、字阶、同心圆角、光影与动效；之后每个部件一页：它的各种状态、可调参数的 Playground、示例代码和 API。按 ⌘K 跳到任意一页。"
      } else if @sf.language() == "en" {
        "Production components built with mbui (libs/ui/src/controls). Design foundations, interactive playgrounds, and API examples. Press ⌘K to jump to any story."
      } else {
        "基于 mbui 构建的生产级组件库（libs/ui/src/controls）。涵盖设计基石、可调参数 Playground 与 API 示例。按 ⌘K 快速跳转任意组件页。"
      }
    },
    fn() { @sf.lead },
  )
  |> ignore
  page.box(fn(grid) {
    grid.row(Is(true)).wraps(Is(Some(16.0))).gap(Is(16.0)) |> ignore
    for i, s in all {
      grid.box(fn(card) {
        card
        .basis(Is(Some(260.0)))
        .grow(Is(1.0))
        .min_width(Is(Some(0.0)))
        .ground(By(fn() { @sf.theme().p.paper }))
        .edge(By(fn() { (1.0, @sf.theme().p.line) }))
        .radius(Is(12.0))
        .clips(Is(true))
        .cursor(Is(Some(Hand)))
        .says(Is(Some(@view.said(Button, label=s.name))))
        .on_press(fn() { chosen.set(i) })
        |> ignore
        card.box(fn(thumb) {
          thumb.height(Is(Some(132.0))).pad(Is(16.0)).clips(Is(true)).bounds_input(Is(true)) |> ignore
          match s.cases.get(0) {
            Some((_, make)) => still_box(thumb, make)
            None => ()
          }
        })
        |> ignore
        card.box(fn(r) { @sf.style_node(r, fn() { @sf.rule_line }) }) |> ignore
        card.box(fn(foot) {
          foot.padding(Is((16.0, 10.0, 16.0, 12.0))).gap(Is(2.0)) |> ignore
          @sf.words_node(foot, fn() { s.name }, fn() { @sf.desk_strong }) |> ignore
          // (its group as a tag, its file beside it)
          foot.box(fn(r) {
            r.row(Is(true)).wraps(Is(Some(4.0))).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
            @sf.pill_node(r, fn() { s.group }) |> ignore
            @sf.words_node(r, fn() { s.file }, fn() { @sf.meta }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    }
  })
  |> ignore
}

///|
/// A card on the page's ground: `make` in it.
fn card_node(v : @view.View, make : (@view.View) -> Unit) -> Unit {
  v.box(fn(card) {
    card
    .ground(By(fn() { @sf.theme().p.paper }))
    .edge(By(fn() { (1.0, @sf.theme().p.line) }))
    .radius(Is(12.0))
    .pad(By(fn() { if card.window_w() < 720.0 { 14.0 } else { 20.0 } }))
    .gap(Is(12.0))
    .min_width(Is(Some(0.0)))
    |> ignore
    make(card)
  })
  |> ignore
}

///|
/// A heading of a part's page.
fn heading_node(v : @view.View, words : String) -> Unit {
  v.box(fn(h) {
    h.padding(Is((0.0, 12.0, 0.0, 0.0))) |> ignore
    @sf.words_node(h, fn() { words }, fn() { @sf.wide_heading }) |> ignore
  })
  |> ignore
}

///|
/// Code as a block with its copy key.
fn code_node(v : @view.View, code : () -> String) -> Unit {
  @sf.code_block_node(v, code, fn() { "moonbit" }, fn() { None })
}

///|
/// A part's page: what it is; its Playground; each of its states in a card under what it shows, the lines that make it
/// a press away; its functions. As wide as `width` says at most.
fn story_node(page : @view.View, s : Story, width : () -> Double?) -> Unit {
  page
  .padding(By(fn() { if page.window_w() < 720.0 { (16.0, 16.0, 16.0, 48.0) } else { (24.0, 20.0, 24.0, 48.0) } }))
  .gap(Is(16.0))
  .min_width(Is(Some(0.0)))
  |> ignore
  @sf.words_node(page, fn() { s.about }, fn() { @sf.lead }) |> ignore
  match s.play {
    Some(make) => {
      let play = make()
      heading_node(page, "Playground")
      page.box(fn(at) {
        at.max_width(By(width)).min_width(Is(Some(0.0))).gap(Is(8.0)) |> ignore
        card_node(at, fn(card) {
          card.box(fn(shown) {
            shown.min_height(Is(Some(64.0))).lines_up(Is(Some(Start))).padding(Is((0.0, 4.0, 0.0, 12.0))) |> ignore
            (play.preview)(shown)
          })
          |> ignore
          card.box(fn(r) { @sf.style_node(r, fn() { @sf.rule_line }) }) |> ignore
          (play.controls)(card)
        })
        code_node(at, play.code)
      })
      |> ignore
    }
    None => ()
  }
  heading_node(page, if s.group == foundations_group { "标本" } else { "示例" })
  for c in s.cases {
    let (label, make) = c
    let code = case_code(label)
    let open = @signals.signal(false)
    page.box(fn(case) {
      case.gap(Is(8.0)).max_width(By(width)).min_width(Is(Some(0.0))) |> ignore
      case.box(fn(head) {
        head.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
        head.box(fn(l) {
          l.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(l, fn() { label }, fn() { @sf.caption }) |> ignore
        })
        |> ignore
        if code != "" {
          @sf.link_node(head, fn() { if open.get() { "收起代码" } else { "代码" } }, fn() { open.set(!open.get()) }, icon="file-code")
          |> ignore
        }
      })
      |> ignore
      card_node(case, make)
      case.show(fn() { open.get() }, fn(c) { code_node(c, fn() { code }) })
    })
    |> ignore
  }
  let apis = s.api.map(fn(a) { api_of(a.0, a.1) }).filter(fn(a) { a != "" })
  if !apis.is_empty() {
    heading_node(page, "API")
    page.box(fn(at) {
      at.max_width(By(width)).min_width(Is(Some(0.0))).gap(Is(12.0)) |> ignore
      for a in apis {
        code_node(at, fn() { a })
      }
    })
    |> ignore
  }
}
