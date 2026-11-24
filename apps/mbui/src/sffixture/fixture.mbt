// Made-up chats in the core's own shapes (ChatsView and the rest), for the app with no core: screenshots that are
// the same on every run (scripts/shots.sh home, web-home), and the web's preview. Every word here is made up.
//
// `mode`: "home" (signed in, the chats), "signin" (signed out), "loading" (the list being read), "empty" (a
// workspace with nothing in it yet); "chat" (the first row's chat open: chat_fixture.mbt), "chat-loading" (it being
// read), "chat-long" (thousands of messages in it); "long" (the chats and many weeks more of them: for flinging,
// scripts/android.sh fling-test); "home-pins" (the chats as a station that knows pins says them: one pinned, one kept);
// "home-share" (one of them shared and pictured from its row's menu, and in Slack); "long-paged" (a long account's
// chats, two hundred days of them, given by each list's window as the core gives them: firstRows, `chats.window` and
// `more`; scripts/instrbench.sh's `paged`).

///|
pub(all) struct Fixture {
  mode : String
  mut workspace : String
  /// the theme chosen (the prefs' `appearance`): light unless the mode ends in -dark or MBUI_DARK=1, so that
  /// screenshots do not follow the machine's own
  mut appearance : String
  mut window_zoom : String
  /// motion chosen (the prefs' `motion`: reduce, full; "" the system's)
  mut motion : String
  /// glass frost chosen (the prefs' `glassFrost`: "0".."100"; "" default clear)
  mut glass_frost : String
  /// haptics chosen (the prefs' `haptics`: off; "" on)
  mut haptics : String
  /// automatic updates chosen (the prefs' `appUpdate`: off; "" on)
  mut app_update : String
  /// how the composer sends (prefs `sendKey`): `mod`, or "" Enter
  mut send_key : String
  /// whether the app is on the test channel (the prefs' `testChannel`): a mode ending in -stable (before -dark) is on
  /// the stable one
  test_channel : Bool
  /// the experimental switches turned on here (the prefs' `experimental`, 实验性功能): the board's modes the board's on
  experimental : Map[String, Bool]
  archived : Map[String, Bool]
  hidden : Map[String, Bool]
  muted : Map[String, Bool]
  filters : Map[String, String]
  /// the faces chosen (the prefs' `fonts`), and those whose files the core has (fonts_fixture.mbt)
  fonts : Map[String, String]
  fonts_fetched : Map[String, Bool]
  /// the keys changed in 快捷键 (`keys.set`; the prefs' `keys`, the keymap's: keymap_fixture.mbt)
  keys : Map[String, Array[String]]
  mut version : Int
  /// the first row's chat: how many older pages have come in
  mut older : Int
  /// "home-motion": how far the list's changes have gone (a chat with news to the top, a new chat, one archived,
  /// a mark come); "share-card-motion": how far the card's figures have changed (fixture_fleet)
  mut step : Int
  /// each chat's side panel's tabs as kept on this device (the prefs' `chatTabs`, by `<station>:<session>` and
  /// `new:<workspace>`), changed by `chat.tabs.*` as the core's chat-tabs.ts changes them (its answers kept, src/sfkept);
  /// those its view shows after the last change, as the core said with it
  chat_tabs : Map[String, Json]
  tabs_shown : Map[String, Json]
  /// each sidebar's width and folding as kept on this device (the prefs' `sidebars`, by `<workspace>\n<group>`), as
  /// the core's prefs.ts keeps a map: by key, null letting one go
  sidebars : Map[String, Json]
  /// the look the card to share is drawn in (the prefs' `shareLook`; "" none kept): share-card-<key> (but -dark) opens
  /// it in that look
  mut share_look : String
  /// how a machine's CPU dial says it on this device (the prefs' `cpuDial`; "" none kept: idle)
  mut cpu_dial : String
  /// each chats' list's window as it was told (`chats.window`, by fixture_window_key), as the core's views.ts keeps it:
  /// only grows; long-paged's lists give that many of their rows, 50 where untold
  windows : Map[String, Int]
}

///|
/// The tabs kept to begin with: the new chat's Station 文件 (newchat-files), and what the first row's chat has open
/// beside it on the wide frame's screenshots (its agent's history, its services and jobs, agent 往来, 文件 and its
/// station's 文件 and page (chat-files-side, chat-drive-side; chat-station-side the page in front of 文件), a file of its in
/// the viewer: chat-view-side its Markdown, chat-view-side-image its picture, chat-view-side-video its film,
/// chat-view-side-audio its song, opened beside it before the app began).
pub fn fixture_chat_tabs(mode : String) -> Map[String, Json] {
  let kept = fn(tab : String) -> Json { { "tabs": [Json::string(tab)], "active": Json::string(tab) } }
  match mode {
    "newchat-files" => { "new:ws1": kept("files") }
    "chat-screen-tab" | "chat-browser-tab" | "chat-browser-agent-driving" => { "ws1/st1:s-c1": kept("screen:[\"ws-1/st-1\",\"browser:tab-1\"]") }
    "chat-letters-side" => { "ws1/st1:s-c1": kept("letters") }
    "chat-things-side" => { "ws1/st1:s-c1": kept("things") }
    "chat-jobs-side" => { "ws1/st1:s-c1": kept("jobs") }
    "chat-subchats-panel" => { "ws1/st1:s-c1": kept("subchats") }
    "chat-files-side" => { "ws1/st1:s-c1": kept("files") }
    "chat-drive-side" => { "ws1/st1:s-c1": kept("drive:[\"ws1/st1\"]") }
    "chat-station-side" => { "ws1/st1:s-c1": { "tabs": ["files", "station:[\"ws1/st1\"]"], "active": "station:[\"ws1/st1\"]" } }
    "chat-service-side" => { "ws1/st1:s-c1": kept("service:j-web") }
    "chat-history-side" | "chat-history-side-working" | "chat-model-pop" | "chat-model-accounts" => { "ws1/st1:s-c1": kept("s-c1") }
    "chat-tabs-side" => { "ws1/st1:s-c1": { "tabs": ["s-c1", "jobs"], "active": "jobs" } }
    "chat-terminal-side" => { "ws1/st1:s-c1": { "tabs": ["terminal:[\"ws1/st1\",\"term-2\",\"~/still.fail\"]", "s-c1"], "active": "terminal:[\"ws1/st1\",\"term-2\",\"~/still.fail\"]" } }
    "chat-view-side" | "chat-view-side-md-long" | "chat-view-side-md-wide" | "chat-view-side-image" | "chat-view-side-video" | "chat-view-side-audio" | "chat-view-side-mbui" | "chat-view-side-memory-mbui" =>
      { "ws1/st1:s-c1": kept(fixture_view_tab(mode)) }
    _ => {}
  }
}

///|
/// The file of the first row's chat open beside it in the viewer (chat-view-side: 说明.md; chat-view-side-md-long:
/// 长说明.md; chat-view-side-md-wide: 宽表格说明.md; chat-view-side-image: 界面草图.png; chat-view-side-video:
/// 演示录屏.mp4; chat-view-side-audio: 会议录音.m4a; chat-view-side-mbui: release.mbui; chat-view-side-memory-mbui:
/// memory-schemes.mbui), its tab as the app keeps it (sfbase's view_tab_key).
pub fn fixture_view_tab(mode : String) -> String {
  let name = match mode {
    "chat-view-side-md-long" => "长说明.md"
    "chat-view-side-md-wide" => "宽表格说明.md"
    "chat-view-side-image" => "界面草图.png"
    "chat-view-side-video" => "演示录屏.mp4"
    "chat-view-side-audio" => "会议录音.m4a"
    "chat-view-side-mbui" => "release.mbui"
    "chat-view-side-memory-mbui" => "memory-schemes.mbui"
    _ => "说明.md"
  }
  for f in preview_files() {
    if f.0.name == name {
      return @sfbase.view_tab_key("ws1/st1", "s-c1", f.0, None, false)
    }
  }
  ""
}

///|
/// The tabs shown to begin with where more than one is kept (chat-tabs-side: the agent's history behind 任务, the
/// panel's two tabs pointed at), as the core shows what is kept (chat-tabs.ts tabsOf).
pub fn fixture_tabs_shown(mode : String) -> Map[String, Json] {
  match mode {
    "chat-screen-tab" | "chat-browser-tab" | "chat-browser-agent-driving" => { "ws1/st1:s-c1": { "open": ["screen:[\"ws-1/st-1\",\"browser:tab-1\"]"], "shown": "screen:[\"ws-1/st-1\",\"browser:tab-1\"]" } }
    "chat-tabs-side" => { "ws1/st1:s-c1": { "open": ["s-c1", "jobs"], "shown": "jobs" } }
    "chat-terminal-side" => { "ws1/st1:s-c1": { "open": ["terminal:[\"ws1/st1\",\"term-2\",\"~/still.fail\"]", "s-c1"], "shown": "terminal:[\"ws1/st1\",\"term-2\",\"~/still.fail\"]" } }
    "chat-view-side" | "chat-view-side-md-long" | "chat-view-side-md-wide" | "chat-view-side-image" | "chat-view-side-video" | "chat-view-side-audio" | "chat-view-side-mbui" | "chat-view-side-memory-mbui" => {
      let tab = fixture_view_tab(mode)
      { "ws1/st1:s-c1": { "open": [Json::string(tab)], "shown": Json::string(tab) } }
    }
    _ => {}
  }
}

///|
/// What the core is asked of a chat's tabs (chat-tabs.ts: what is kept for `key`, the agents of `chat`, its view, as
/// far as their tabs go, whether it has a chat yet, its session; the `change`, when one is made), as kept.
pub fn fixture_tabs_ask(f : Fixture, key : String, chat : Json?, change : Json?) -> Json {
  let (station, rest) = match key.find(":") {
    Some(i) => (key.exact_view(end=i).to_owned(), key.exact_view(start=i + 1).to_owned())
    None => ("", "")
  }
  let agents = items(chat, "agents").map(fn(a) {
    let jobs = items(Some(a), "jobs").map(fn(j) { Json::object({ "id": Json::string(text(Some(j), "id")) }) })
    Json::object({
      "session": { "key": Json::string(text(field(Some(a), "session"), "key")) },
      "jobs": Json::array(jobs),
    })
  })
  let ask : Map[String, Json] = {
    "kept": f.chat_tabs.get(key).unwrap_or(Json::null()),
    "agents": Json::array(agents),
    "noChat": Json::boolean(flag(chat, "noChat")),
    "session": if station.contains("/") && chat is Some(_) { Json::string(rest) } else { Json::null() },
  }
  match change {
    Some(c) => ask["change"] = c
    None => ()
  }
  Json::object(ask)
}

///|
/// A chat's view with its side panel's tabs, as the core makes them of what is kept for it (the view's `tabs`).
pub fn fixture_with_tabs(f : Fixture, params : Map[String, Json], value : Json?) -> Json? {
  match value {
    Some(Object(m)) => {
      let key = text(Some(Json::object(params)), "station") + ":" + text(Some(Json::object(params)), "session")
      let m = m.copy()
      match f.tabs_shown.get(key) {
        Some(tabs) => m["tabs"] = tabs
        None =>
          match fixture_kept("chat.tabs", fixture_tabs_ask(f, key, value, None), None) {
            Some(Ok((tabs, _))) => m["tabs"] = tabs
            _ => ()
          }
      }
      Some(Json::object(m))
    }
    _ => value
  }
}

///|
/// `chat.tabs.open / close / front / clear / replace` (`chat`: its key, `tab`, `auto`; `was`, the tab replaced): what
/// is kept for the chat changed as the core changes it (nothing, where it says nothing changes).
pub fn fixture_tabs_call(f : Fixture, name : String, params : Json) -> Result[Json, Json] {
  let key = text(Some(params), "chat")
  let chat = match key.find(":") {
    Some(i) if key.exact_view(end=i).contains("/") =>
      fixture_topic_inner(f, "chat", {
        "station": Json::string(key.exact_view(end=i).to_owned()),
        "session": Json::string(key.exact_view(start=i + 1).to_owned()),
      })
    _ => None
  }
  let act = name.exact_view(start="chat.tabs.".length()).to_owned()
  let tab_str = match field(Some(params), "tab") {
    Some(String(t)) => t
    _ => ""
  }
  let existing_open = items(f.tabs_shown.get(key), "open")
  if tab_str.has_prefix("terminal:") || existing_open.any(fn(x) { x is String(s) && s.has_prefix("terminal:") }) {
    let cur : Array[String] = []
    for x in existing_open {
      if x is String(s) && !cur.contains(s) {
        cur.push(s)
      }
    }
    let mut shown = text(f.tabs_shown.get(key), "shown")
    match act {
      "open" => {
        if tab_str != "" && !cur.contains(tab_str) {
          cur.push(tab_str)
        }
        if tab_str != "" {
          shown = tab_str
        }
      }
      "front" => if cur.contains(tab_str) { shown = tab_str }
      "close" => {
        let idx = cur.search(tab_str)
        match idx {
          Some(i) => {
            cur.remove(i) |> ignore
            if shown == tab_str {
              shown = match cur.get(i) {
                Some(s) => s
                None => if i > 0 { cur.get(i - 1).unwrap_or("") } else { "" }
              }
            }
          }
          None => ()
        }
      }
      "clear" => {
        cur.clear()
        shown = ""
      }
      _ => ()
    }
    let arr = Json::array(cur.map(fn(s) { Json::string(s) }))
    let shown_json = if shown == "" { Json::null() } else { Json::string(shown) }
    f.chat_tabs[key] = { "tabs": arr, "active": shown_json }
    f.tabs_shown[key] = { "open": arr, "shown": shown_json }
    f.changed()
    return Ok(Json::null())
  }
  let change : Map[String, Json] = {
    "action": Json::string(act),
    "tab": if tab_str != "" { Json::string(tab_str) } else { Json::null() },
    "auto": Json::boolean(!(field(Some(params), "auto") is Some(False))),
  }
  // (a tab put in another's place: the one it replaces)
  match field(Some(params), "was") {
    Some(String(w)) => change["was"] = Json::string(w)
    _ => ()
  }
  match field(Some(params), "to") {
    Some(Number(n, ..)) => change["to"] = Json::number(n)
    _ => ()
  }
  let change = Json::object(change)
  match fixture_kept("chat.tabs", fixture_tabs_ask(f, key, chat, Some(change)), None) {
    Some(Ok((r, _))) => {
      match (field(Some(r), "next"), field(Some(r), "tabs")) {
        (Some(Object(_) as next), Some(tabs)) => {
          f.chat_tabs[key] = next
          f.tabs_shown[key] = tabs
          f.changed()
        }
        _ => ()
      }
      Ok(Json::null())
    }
    Some(Err(e)) => Err(e)
    None => Err({ "code": "not_kept", "message": "the core's answers are not bound (src/sfkept)" })
  }
}

///|
pub fn agent(maker : String, runtime : String) -> Json {
  let a : Map[String, Json] = {
    "runtime": Json::string(runtime),
    "agentText": Json::string(maker + " · " + runtime),
  }
  if maker != "" {
    a["maker"] = { "id": Json::string(maker) }
  }
  Json::object(a)
}

///|
pub fn person(id : String, name : String, mine : Bool) -> Json {
  {
    "id": Json::string(id),
    "name": Json::string(name),
    "email": Json::string(id),
    "via": "cloud",
    "shown": {
      "name": Json::string(name),
      "display": Json::string(if mine { "你" } else { name }),
      "mine": Json::boolean(mine),
    },
  }
}

///|
/// A row: its id and title, its station, when, and the rest as the view gives it.
pub fn row(
  id : String,
  title : String,
  station : String,
  ago : String,
  more : Map[String, Json],
) -> Json {
  let r : Map[String, Json] = {
    "id": Json::string(id),
    "session": Json::string("s-" + id),
    "thread": Json::number(id.length().to_double()),
    "title": Json::string(title),
    "agents": [agent("anthropic", "claude")],
    "unread": false,
    "mine": true,
    "lastActiveAt": 0,
    "station": Json::string(station),
    "stationName": Json::string(if station == "ws1/st1" { "Willow" } else { "Maple" }),
    "stationIcon": Json::string(
      if station == "ws1/st1" {
        "glyph:desktop"
      } else {
        "glyph:laptop:teal"
      },
    ),
    "time": { "lastActiveAt": { "at": 0, "ago": Json::string(ago), "full": "", "until": "", "past": true } },
  }
  for k, v in more {
    r[k] = v
  }
  // The core lets any made chat on an online station be swiped to archive, regardless of its state.
  if !more.contains("offline") && more.get("pending") != Some(Json::boolean(true)) {
    r["swipeArchive"] = Json::boolean(true)
    // its swipe asks first (the core's swipeAsk): started by someone else, that it goes off everyone's list; keeping
    // watch, in its watch's words; at work, that it is
    let state = match more.get("watch") {
      Some(Object(w)) =>
        match w.get("ask") {
          Some(String(ask)) => ask
          _ => ""
        }
      _ =>
        if more.get("state") == Some(Json::string("run")) {
          "此对话正在进行中。归档后，agent 完成当前回复即停止，等待中的任务也会停止。"
        } else {
          ""
        }
    }
    let others = match more.get("creator") {
      Some(Object(c)) if c.get("id") != Some(Json::string("lin@example.com")) => {
        let name = match c.get("name") {
          Some(String(n)) => n
          _ => ""
        }
        "这是\{name}发起的对话。归档后，workspace 里所有人的列表都不再显示它，agent 也不再接收新消息。"
      }
      _ => ""
    }
    if others + state != "" {
      r["swipeAsk"] = Json::string(others + state)
    }
  }
  // (its people and who started it as a row is sent them: client/core-ts schema.ts RowPerson, RowCreator; its thread's
  // place, `origin`, and `archivable` the core's)
  match r.get("people") {
    Some(Array(ps)) => r["people"] = Json::array(ps.map(row_person))
    _ => ()
  }
  match r.get("creator") {
    Some(Object(c)) => r["creator"] = { "id": c.get("id").unwrap_or(Json::string("")) }
    _ => ()
  }
  r.remove("origin")
  r.remove("archivable")
  Json::object(r)
}

///|
/// Person `p` (person) as a row's pictures are sent them: who, their email, their name, picture and whether it is the
/// viewer.
fn row_person(p : Json) -> Json {
  let shown = field(Some(p), "shown")
  let face : Map[String, Json] = { "name": Json::string(text(shown, "name")), "mine": Json::boolean(flag(shown, "mine")) }
  match field(shown, "picture") {
    Some(String(_) as pic) => face["picture"] = pic
    _ => ()
  }
  { "id": Json::string(text(Some(p), "id")), "email": Json::string(text(Some(p), "email")), "shown": Json::object(face) }
}

///|
pub let me : Json = person("lin@example.com", "林", true)

///|
pub let ana : Json = person("ana@example.com", "Ana", false)

///|
pub let zhou : Json = person("zhou@example.com", "周", false)

///|
pub fn last(text : String) -> Json {
  { "seq": 1, "authorKind": "agent", "author": "a", "text": Json::string(text), "createdAt": 0, "preview": Json::string(text) }
}

///|
/// The web's demo's chats, its one station's, as its core lists them:
/// MBUI_FIXTURE=webdemo, the wide frame beside the web's story app-chat with the same chats (their people's pictures
/// letters here).
pub fn webdemo_days() -> Array[Json] {
  let lin = person("lin@acme.dev", "林晓", false)
  let chen = person("chen@acme.dev", "陈默", false)
  let zhou = person("zhou@acme.dev", "周宁", false)
  let one = fn(id, title, ago, more : Map[String, Json]) {
    let r = row(id, title, "ws1/st1", ago, more)
    match r {
      Object(m) => {
        m.remove("stationIcon")
        Json::object(m)
      }
      _ => r
    }
  }
  [
    {
      "label": "今天",
      "items": [
        one("safari", "把那个弄一下", "1 分钟前", {
          "last": last("还是不行"),
          "people": [lin, chen],
          "creator": { "id": "lin@acme.dev", "name": "林晓", "via": "cloud" },
        }),
        one("csv", "订单导出支持 CSV", "26 分钟前", {
          "unread": true,
          "tone": "done",
          "last": last("做好了：导出按当前筛选条件走流式写出，10 万行大约 2.3 秒，已合进 main（a3f9c21）。"),
          "agents": [agent("openai", "codex")],
          "people": [zhou],
        }),
        one("deps", "每周依赖升级", "58 分钟前", {
          "state": "block",
          "tone": "alert",
          "last": last("其余 23 个包都升好了，测试通过。只剩 React Router 8：它改了 loader 的写法，要动 14 个路由文件。这周要一起升吗？"),
          "people": [chen],
        }),
        one("p99", "排查 API p99 变慢", "20 小时前", {
          "last": last("罪魁是 orders 表少了 (user_id, created_at) 联合索引：上周的分页改动让查询走了全表扫描。"),
          "people": [lin],
        }),
      ],
    },
    {
      "label": "昨天",
      "items": [one("docs", "补一下部署文档", "26 小时前", { "last": last("谢谢，文档看过了"), "people": [chen] })],
    },
  ]
}

///|
/// 夜里的构建又失败了 as its row says what its menu offers besides the list's own (home-share): shared with the viewer's
/// other workspaces, a picture of it, it in Slack.
fn fix_row_share(r : Json) -> Json {
  match r {
    Object(m) if text(Some(r), "id") == "c3" => {
      let o = m.copy()
      o["mayShare"] = Json::boolean(true)
      o["mayPublish"] = Json::boolean(true)
      o["slackUrl"] = Json::string("https://example.slack.com/archives/C1/p1")
      Json::object(o)
    }
    other => other
  }
}

///|
/// 整理发布清单 as its row says its menu offers moving it to another station (home-move): the viewer an owner.
fn fix_row_move(r : Json) -> Json {
  match r {
    Object(m) if text(Some(r), "id") == "c1" => {
      let o = m.copy()
      o["mayMove"] = Json::boolean(true)
      Json::object(o)
    }
    other => other
  }
}

///|
/// A row as a station that knows pins says it (home-pins): 给设置页加一个深色模式开关 pinned, 盯着 CI，绿了告诉我 kept
/// (保留), the rest neither.
fn fix_pins(r : Json) -> Json {
  match r {
    Object(m) => {
      let o = m.copy()
      let id = text(Some(r), "id")
      o["pinned"] = Json::boolean(id == "c4")
      if id == "c5" {
        o["kept"] = Json::boolean(true)
      }
      Json::object(o)
    }
    other => other
  }
}

///|
/// A row's or a chat's `opener`, as the core says one an agent opened (chat-opener, its sheet open: chat-opener-info): the chat of 和 Ana 一起看新版的引导页.
fn with_opener(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let m = m.copy()
      m["opener"] = {
        "station": "ws1/st1",
        "session": "s-c6",
        "title": "和 Ana 一起看新版的引导页",
        "text": "由「和 Ana 一起看新版的引导页」创建",
      }
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// A row made by the first row's chat's agent (chat-opened): its `opener` that chat.
fn opened_by_first(r : Json) -> Json {
  match r {
    Object(m) => {
      let m = m.copy()
      m["opener"] = { "station": "ws1/st1", "session": "s-c1", "title": "整理发布清单", "text": "由「整理发布清单」创建" }
      Json::object(m)
    }
    other => other
  }
}

///|
/// The first row's chat with the chats its agent made (chat-opened), as the core lists them: one waiting for the
/// viewer, one done, one in the archive.
fn with_opened(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let m = m.copy()
      m["opened"] = [
        {
          "station": "ws1/st2",
          "session": "s-c3",
          "title": "夜里的构建又失败了",
          "mark": "block",
          "stateLead": "need",
          "stateText": "要你帮忙：测试机的磁盘满了，要不要清理旧的缓存？",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c4",
          "title": "给设置页加一个深色模式开关",
          "stateLead": "done",
          "stateText": "做完了：开关和三处颜色都改好了",
          "led": true,
        },
        { "station": "ws1/st1", "session": "s-c12", "title": "旧版引导页的截图", "archived": true, "note": "已归档", "led": true },
      ]
      m["openedText"] = "创建了 3 个对话"
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// Rich led sub-chats fixture (chat-subchats-pop, chat-subchats-panel): 4 led sub-chats (running, waiting, done,
/// archived) plus 1 non-led chat opened for a person (excluded from sub-chats bar entry, popover, panel and sheet).
fn with_subchats(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let m = m.copy()
      m["opened"] = [
        {
          "station": "ws1/st1",
          "session": "s-c2",
          "title": "安卓构建与冒烟测试",
          "mark": "run",
          "stateText": "正在运行端到端用例",
          "led": true,
        },
        {
          "station": "ws1/st2",
          "session": "s-c3",
          "title": "夜里的构建又失败了",
          "mark": "block",
          "stateLead": "need",
          "stateText": "要你帮忙：测试机的磁盘满了，要不要清理旧的缓存？",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c4",
          "title": "给设置页加一个深色模式开关",
          "stateLead": "done",
          "stateText": "做完了：开关和三处颜色都改好了",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c12",
          "title": "旧版引导页的截图",
          "archived": true,
          "note": "已归档",
          "stateText": "需要你处理：归档前的残留提示",
          "led": true,
        },
        { "station": "ws1/st1", "session": "s-c9", "title": "给产品评审建的独立讨论", "stateLead": "done", "stateText": "已整理好议程" },
      ]
      m["openedText"] = "创建了 5 个对话"
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// Single active led sub-chat fixture (chat-subchats-one): 1 active led sub-chat with no stateText and no archived
/// group, reproducing the single-card hugs sheet sizing case.
fn with_subchats_one(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let m = m.copy()
      m["opened"] = [
        {
          "station": "ws1/st1",
          "session": "s-c2",
          "title": "执行：模型面板搜索同行布局与分段控件交互",
          "mark": "run",
          "led": true,
        },
      ]
      m["openedText"] = "创建了 1 个对话"
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// Single active led sub-chat fixture with stateText (chat-subchats-one-note): 1 two-line active led sub-chat with no
/// archived group, taller than the row estimate.
fn with_subchats_one_note(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let m = m.copy()
      m["opened"] = [
        {
          "station": "ws1/st1",
          "session": "s-c2",
          "title": "执行：模型面板搜索同行布局与分段控件交互",
          "mark": "run",
          "stateText": "正在运行端到端用例",
          "led": true,
        },
      ]
      m["openedText"] = "创建了 1 个对话"
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// Long led sub-chats fixture (chat-subchats-many): 2 active + 10 archived led sub-chats (several archived items carry
/// stale pre-archive `stateText` that must stay hidden), used to verify sheet scrolling and archived state hiding.
fn with_subchats_many(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let m = m.copy()
      m["opened"] = [
        {
          "station": "ws1/st1",
          "session": "s-c2",
          "title": "安卓构建与冒烟测试",
          "mark": "run",
          "stateText": "正在运行端到端用例",
          "led": true,
        },
        {
          "station": "ws1/st2",
          "session": "s-c3",
          "title": "夜里的构建又失败了",
          "mark": "block",
          "stateLead": "need",
          "stateText": "要你帮忙：测试机的磁盘满了，要不要清理旧的缓存？",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c12",
          "title": "旧版引导页的截图",
          "archived": true,
          "note": "已归档",
          "stateText": "需要你处理：归档前的残留提示",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c13",
          "title": "排查消息推送延迟问题",
          "archived": true,
          "note": "已归档",
          "stateText": "出错：额度已用完",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c14",
          "title": "整理季度发布回归清单",
          "archived": true,
          "note": "已归档",
          "stateText": "需要你处理：确认测试账号权限",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c15",
          "title": "重构侧栏拖拽动画参数",
          "archived": true,
          "note": "已归档",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c16",
          "title": "核对深色主题对比度边界",
          "archived": true,
          "note": "已归档",
          "stateText": "出错：额度已用完",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c17",
          "title": "补齐英文翻译缺失词条",
          "archived": true,
          "note": "已归档",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c18",
          "title": "压缩启动阶段首屏资源包",
          "archived": true,
          "note": "已归档",
          "stateText": "需要你处理：选择压缩等级",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c19",
          "title": "迁移旧版工作站配置格式",
          "archived": true,
          "note": "已归档",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c20",
          "title": "修复平板分屏切换偶发闪屏",
          "archived": true,
          "note": "已归档",
          "stateText": "出错：额度已用完",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c4",
          "title": "历史日志导出脚本清理",
          "archived": true,
          "note": "已归档",
          "stateText": "需要你处理：清理过期归档",
          "led": true,
        },
      ]
      m["openedText"] = "创建了 12 个对话"
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// Tall led sub-chats fixture (chat-subchats-tall): 1 waiting + 6 running + 14 done (mix of bare "已完成" and
/// summary "已完成：…") + 2 archived, all `led: true`, simulating a leader chat with 23 sub-chats.
fn with_subchats_tall(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let m = m.copy()
      m["opened"] = [
        {
          "station": "ws1/st2",
          "session": "s-c3",
          "title": "夜里的构建又失败了",
          "mark": "block",
          "stateLead": "need",
          "stateText": "要你帮忙：测试机的磁盘满了，要不要清理旧的缓存？",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c2",
          "title": "安卓构建与冒烟测试",
          "mark": "run",
          "stateText": "正在运行端到端用例",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-t1",
          "title": "iOS 弱网断线重连回归",
          "mark": "run",
          "stateText": "正在对比重连前后消息序号",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-t2",
          "title": "桌面端快捷键焦点环自查",
          "mark": "run",
          "stateText": "正在运行 4 档帧率测试",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-t3",
          "title": "Core-TS 主题增量字节预算检查",
          "mark": "run",
          "stateText": "正在生成 real-size 报告",
          "led": true,
        },
        {
          "station": "ws1/st2",
          "session": "s-t4",
          "title": "Station 跨站同步冲突合并验证",
          "mark": "run",
          "stateText": "正在运行三方合并测试",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-t5",
          "title": "离屏金属渲染对比视频生成",
          "mark": "run",
          "stateText": "正在录制 60fps 交互流",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d1",
          "title": "给设置页加一个深色模式开关",
          "stateLead": "done",
          "stateText": "已完成：开关和三处颜色都改好了",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d2",
          "title": "排查首页列表滚动掉帧",
          "stateLead": "done",
          "stateText": "已完成",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d3",
          "title": "补齐弹窗无障碍语义标签",
          "stateLead": "done",
          "stateText": "已完成：已通过全量 audit",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d4",
          "title": "整理多端字体缩放边界用例",
          "stateLead": "done",
          "stateText": "已完成",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d5",
          "title": "压缩首屏静态图标资源体积",
          "stateLead": "done",
          "stateText": "已完成：减少 180 KB",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d6",
          "title": "修复窄屏面包屑截断问题",
          "stateLead": "done",
          "stateText": "已完成",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d7",
          "title": "同步英文词条缺失翻译",
          "stateLead": "done",
          "stateText": "已完成",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d8",
          "title": "核对安全模式卡片按钮文案",
          "stateLead": "done",
          "stateText": "已完成：已对齐最新规范",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d9",
          "title": "清理旧版日志导出临时脚本",
          "stateLead": "done",
          "stateText": "已完成",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d10",
          "title": "优化大附件分片续传重试",
          "stateLead": "done",
          "stateText": "已完成",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d11",
          "title": "验证飞书群卡片回调签名",
          "stateLead": "done",
          "stateText": "已完成：单测全绿",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d12",
          "title": "检查平板横屏分栏最小宽度",
          "stateLead": "done",
          "stateText": "已完成",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d13",
          "title": "补充工作站迁移回滚说明",
          "stateLead": "done",
          "stateText": "已完成",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c4",
          "title": "收尾回归与变更日志核对",
          "stateLead": "done",
          "stateText": "已完成：已合入测试分支",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c12",
          "title": "旧版引导页的截图",
          "archived": true,
          "note": "已归档",
          "stateText": "需要你处理：归档前的残留提示",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c13",
          "title": "排查消息推送延迟问题",
          "archived": true,
          "note": "已归档",
          "stateText": "出错：额度已用完",
          "led": true,
        },
      ]
      m["openedText"] = "创建了 23 个对话"
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// Led sub-chats that ended without a state (chat-subchats-idle): 2 running, 1 waiting on its own work, 5 idle and 4
/// done, as the core orders them; idle ones fold with done.
fn with_subchats_idle(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let m = m.copy()
      m["opened"] = [
        {
          "station": "ws1/st1",
          "session": "s-c2",
          "title": "安卓构建与冒烟测试",
          "mark": "run",
          "stateText": "正在运行端到端用例",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-t1",
          "title": "iOS 弱网断线重连回归",
          "mark": "run",
          "stateText": "正在对比重连前后消息序号",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-w1",
          "title": "等 CI 跑完再合并分支",
          "stateLead": "wait",
          "stateText": "在等：PR 检查跑完",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-i1",
          "title": "排查侧栏偶发白屏",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-i2",
          "title": "核对英文词条长度",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-i3",
          "title": "试跑新版离屏渲染脚本",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-i4",
          "title": "整理旧版测试账号",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-i5",
          "title": "统计子会话平均耗时",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d1",
          "title": "给设置页加一个深色模式开关",
          "stateLead": "done",
          "stateText": "已完成：开关和三处颜色都改好了",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d2",
          "title": "排查首页列表滚动掉帧",
          "stateLead": "done",
          "stateText": "已完成",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d3",
          "title": "补齐弹窗无障碍语义标签",
          "stateLead": "done",
          "stateText": "已完成：已通过全量 audit",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c4",
          "title": "收尾回归与变更日志核对",
          "stateLead": "done",
          "stateText": "已完成：已合入测试分支",
          "led": true,
        },
      ]
      m["openedText"] = "创建了 12 个对话"
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// Many finished led sub-chats and none at work (chat-subchats-done-many): chat-subchats-tall's 14 done (bare 已完成 and
/// summaries) and 2 archived, nothing else: the list leads with the latest 3 done, the other 11 behind a press.
fn with_subchats_done_many(v : Json?) -> Json? {
  match with_subchats_tall(v) {
    Some(Object(m)) => {
      let m = m.copy()
      let kept = match m.get("opened") {
        Some(Array(a)) =>
          a.filter(fn(o) {
            match o {
              Object(f) => f.get("stateLead") is Some(String("done")) || f.get("archived") is Some(True)
              _ => false
            }
          })
        _ => []
      }
      m["opened"] = Json::array(kept)
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// Done-only led sub-chats fixture (chat-subchats-done-only): 3 unarchived done + 2 archived, verifying that the Done
/// done ones lead the list, all three shown (no more than the latest), Archived folded under them.
fn with_subchats_done_only(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let m = m.copy()
      m["opened"] = [
        {
          "station": "ws1/st1",
          "session": "s-c4",
          "title": "给设置页加一个深色模式开关",
          "stateLead": "done",
          "stateText": "已完成：开关和三处颜色都改好了",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d2",
          "title": "排查首页列表滚动掉帧",
          "stateLead": "done",
          "stateText": "已完成",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-d3",
          "title": "补齐弹窗无障碍语义标签",
          "stateLead": "done",
          "stateText": "已完成：已通过全量 audit",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c12",
          "title": "旧版引导页的截图",
          "archived": true,
          "note": "已归档",
          "stateText": "需要你处理：归档前的残留提示",
          "led": true,
        },
        {
          "station": "ws1/st1",
          "session": "s-c13",
          "title": "排查消息推送延迟问题",
          "archived": true,
          "note": "已归档",
          "led": true,
        },
      ]
      m["openedText"] = "创建了 5 个对话"
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// One led parent whose title is longer than a fixed crumb (chat-lineage-long).
fn with_lineage_long(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let m = m.copy()
      let parent : Json = {
        "station": "ws1/st1",
        "session": "s-c4",
        "title": "优化液态玻璃对标原生 iOS 27",
        "text": "由「优化液态玻璃对标原生 iOS 27」创建",
        "led": true,
      }
      m["opener"] = parent
      m["openers"] = [parent]
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// 3-level led ancestor chain plus 2 led sub-chats (chat-lineage): exercises multi-level breadcrumb + sub-chats entry.
fn with_lineage(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let m = m.copy()
      let root : Json = {
        "station": "ws1/st1",
        "session": "s-c6",
        "title": "根规划",
        "text": "由「根规划」创建",
        "led": true,
      }
      let mid : Json = {
        "station": "ws1/st1",
        "session": "s-c5",
        "title": "接口重构",
        "text": "由「接口重构」创建",
        "led": true,
      }
      let parent : Json = {
        "station": "ws1/st1",
        "session": "s-c4",
        "title": "任务拆分",
        "text": "由「任务拆分」创建",
        "led": true,
      }
      m["opener"] = parent
      m["openers"] = [root, mid, parent]
      m["opened"] = [
        {
          "station": "ws1/st1",
          "session": "s-c2",
          "title": "安卓构建与冒烟测试",
          "mark": "run",
          "stateText": "正在运行端到端用例",
          "led": true,
        },
        {
          "station": "ws1/st2",
          "session": "s-c3",
          "title": "夜里的构建又失败了",
          "mark": "block",
          "stateLead": "need",
          "stateText": "要你帮忙：测试机的磁盘满了，要不要清理旧的缓存？",
          "led": true,
        },
      ]
      m["openedText"] = "创建了 2 个对话"
      Some(Json::object(m))
    }
    other => other
  }
}

///|
/// The chats of the first workspace, newest first, by day.
pub fn fixture_days(f : Fixture) -> Array[Json] {
  let days = fixture_days_head(f)
  for d in 0..<long_days(f) {
    let items = Array::makei(6, fn(k) { long_row(d * 6 + k + 11) })
    days.push({ "daysAgo": Json::number((d + 5).to_double()), "at": 0, "label": Json::string("\{d + 5} 天前"), "items": kept(f, items) })
  }
  days
}

///|
/// The rows of `items` not archived.
fn kept(f : Fixture, items : Array[Json]) -> Json {
  Json::array(items.filter(fn(r) { !f.archived.contains(text(Some(r), "id")) }))
}

///|
/// How many days more of made-up chats "long" and "long-paged" have after the first ones: weeks more, six chats a day,
/// every word made up (long_row).
fn long_days(f : Fixture) -> Int {
  match f.mode {
    "long" => 40
    "long-paged" => 200
    _ => 0
  }
}

///|
// kept across runs: a table, never written
let long_topics : Array[String] = ["例会的记录", "接口的命名", "图标的尺寸", "崩溃的日志", "发布的说明", "测试的清单"]

///|
// kept across runs: a table, never written
/// (each with what leads it, as the core would say: none for words of their own)
let long_states : Array[(String, String, String)] = [
  ("做完了", "done", ""),
  ("等你回复", "", ""),
  ("监控中：每小时看一次", "watch", "监控中：每小时看一次"),
  ("写到一半", "", ""),
  ("要你帮忙看一眼", "", ""),
  ("已经交给评审", "", ""),
]

///|
/// Made-up chat `c<n>` of the days after the first ones (n from 11; long_days): the `k`th of six on day `d`.
fn long_row(n : Int) -> Json {
  let d = (n - 11) / 6
  let k = (n - 11) % 6
  let (said, lead, rest) = long_states[(d + k) % 6]
  let state : Map[String, Json] = { "stateText": Json::string(said) }
  if lead != "" {
    state["stateLead"] = Json::string(lead)
    state["stateRest"] = Json::string(rest)
  }
  row("c\{n}", "第 \{n} 个：" + long_topics[k], if k % 2 == 0 { "ws1/st1" } else { "ws1/st2" }, "\{d + 5} 天前", state)
}

///|
/// The `n` of a chat of the days after the first ones that `session` (its session `s-c<n>` or its id `c<n>`) can name,
/// in a mode that has them (long_days); None for any other.
fn long_number(f : Fixture, session : String) -> Int? {
  let id = if session.has_prefix("s-") { session.unsafe_substring(start=2, end=session.length()) } else { session }
  guard id.has_prefix("c") && id.length() > 1 && id.length() < 9 else { return None }
  let mut n = 0
  for ch in id.unsafe_substring(start=1, end=id.length()) {
    let digit = ch.to_int() - 48
    guard digit >= 0 && digit <= 9 else { return None }
    n = n * 10 + digit
  }
  if "c\{n}" == id && n >= 11 && n < 11 + long_days(f) * 6 { Some(n) } else { None }
}

///|
/// The first days of made-up chats, of every mode (fixture_days: those and long_days more).
fn fixture_days_head(f : Fixture) -> Array[Json] {
  if f.mode == "webdemo" {
    return webdemo_days()
  }
  if board_mode(f.mode) {
    return board_days(f)
  }
  let today = [
    row("c1", "整理发布清单", "ws1/st1", "2 分钟前", {
      "state": "run",
      "tone": "busy",
      "last": last("正在核对第三项：安装包的签名"),
      "agents": [agent("anthropic", "claude"), agent("openai", "codex")],
    }),
    row("c2", "首页的列表改成按天分组", "ws1/st1", "8 分钟前", {
      "unread": true,
      "tone": "wait",
      "decision": { "seq": 3, "options": [], "text": "待处理 · 分组的标题用相对日期还是具体日期？" },
      // (its line, and what leads it, as the core says them: client/core-ts present.ts rowStateLine)
      "stateText": "待处理 · 分组的标题用相对日期还是具体日期？",
      "stateLead": "decision",
      "stateLeadText": "待处理",
      "stateRest": " · 分组的标题用相对日期还是具体日期？",
      "people": [me, ana],
      "creator": { "id": "lin@example.com", "name": "林", "via": "cloud" },
    }),
    row("c3", "夜里的构建又失败了", "ws1/st2", "15 分钟前", {
      // (an agent asking for help: the core's tone for it is wait, the viewer's turn: decisions.ts tone)
      "state": "block",
      "tone": "wait",
      "stateText": "要你帮忙：测试机的磁盘满了，要不要清理旧的缓存？",
      "stateLead": "need",
      "stateRest": "测试机的磁盘满了，要不要清理旧的缓存？",
      "unread": true,
    }),
    row("c4", "给设置页加一个深色模式开关", "ws1/st1", "40 分钟前", {
      "unread": true,
      "tone": "done",
      "stateText": "做完了：开关和三处颜色都改好了",
      "stateLead": "done",
      "stateRest": "开关和三处颜色都改好了",
      "agents": [agent("deepseek", "dsh")],
    }),
    row("c5", "盯着 CI，绿了告诉我", "ws1/st2", "1 小时前", {
      "stateText": "监控中：每 5 分钟看一次主干的构建",
      "stateLead": "watch",
      "stateRest": "监控中：每 5 分钟看一次主干的构建",
      "stateAbout": 12,
      "watch": { "text": "监控中：主干构建", "ask": "「主干构建」仍在监控。归档会停止监控。" },
    }),
  ]
  // home-pins: rows from a station that knows pins, for their menus' 固定 and 保留
  let today = if f.mode == "home-pins" || f.mode == "chat-actions" { today.map(fix_pins) } else { today }
  let today = if f.mode == "home-share" { today.map(fix_row_share) } else { today }
  // home-move: 整理发布清单's menu offers 迁移到另一台 station (its viewer an owner: the core's mayMove)
  let today = if f.mode == "home-move" { today.map(fix_row_move) } else { today }
  // chat-opener: the first row's chat and 夜里的构建 opened by 和 Ana 一起看新版的引导页's agent (chat_create)
  let today = if f.mode.has_prefix("chat-opener") {
    today.mapi(fn(i, r) { if i == 0 || i == 2 { with_opener(Some(r)).unwrap_or(r) } else { r } })
  } else if f.mode.has_prefix("chat-opened") {
    // chat-opened: 夜里的构建 and 深色模式开关 made by the first row's chat's agent
    today.mapi(fn(i, r) { if i == 2 || i == 3 { opened_by_first(r) } else { r } })
  } else {
    today
  }
  // A station that supports personal hiding (used to exercise its menu and list).
  let today = if f.mode == "home-hide" {
    today.map(fn(r) {
      match r {
        Object(m) => {
          let v = m.copy()
          let first = text(Some(r), "id") == "c1"
          v["hidden"] = Json::boolean(first && f.hidden.get("c1").unwrap_or(false))
          v["muted"] = Json::boolean(first && f.muted.get("c1").unwrap_or(false))
          if first { v["thread"] = Json::number(17.0) }
          Json::object(v)
        }
        _ => r
      }
    })
  } else {
    today
  }
  let yesterday = [
    row("c6", "和 Ana 一起看新版的引导页", "ws1/st1", "昨天 21:14", {
      "last": last("Ana：第二屏的插画可以再小一点"),
      "people": [ana, me, zhou],
      "creator": { "id": "ana@example.com", "name": "Ana", "via": "cloud" },
    }),
    row("c7", "Slack 里问的报销流程", "ws1/st2", "昨天 18:02", {
      "connect": "slack-1",
      "originText": "Slack · 星火 · #行政",
      "last": last("已经把三个步骤整理成一页文档"),
    }),
    row("c8", "把旧的截图都换成新的", "ws1/st1", "昨天 10:30", {
      "settled": true,
      "archivable": true,
      "stateText": "做完了",
      "stateLead": "done",
      "stateRest": "",
    }),
  ]
  let earlier = [
    row("c9", "迁移数据库的演练", "ws1/st2", "星期三", {
      "offline": "Maple 离线",
      "last": last("演练到第二步时 Maple 断开了"),
      "agents": [agent("anthropic", "claude"), agent("openai", "codex"), agent("deepseek", "dsh"), agent("qwen", "dsh"), agent("kimi", "dsh")],
    }),
    row("c10", "周报的模板", "ws1/st1", "星期三", {
      // (an agent that failed in a chat the viewer started: present.ts session, marks.ts rowTone; its line the last
      // message, not the core's 出错：…, whose words the recorded screens' text has not got)
      "state": "failed",
      "tone": "alert",
      "last": last("模板放在共享文件夹的第一层"),
      "agents": [agent("gemini", "dsh")],
    }),
  ]
  if f.mode == "home-motion" {
    // 1: news in 盯着 CI, which goes to the top; 2: a new chat comes; 3: one archived goes; 4: a mark comes
    if f.step >= 1 {
      let ci = today.remove(4)
      today.insert(
        0,
        row("c5", "盯着 CI，绿了告诉我", "ws1/st2", "刚刚", {
          "unread": true,
          "tone": "done",
          "last": last("CI 绿了：主干 #812 的检查都过了"),
        }),
      )
      ignore(ci)
    }
    if f.step >= 2 {
      today.insert(
        0,
        row("c11", "看一下新的崩溃报告", "ws1/st1", "刚刚", {
          "state": "run",
          "tone": "busy",
          "last": last("正在读第一份报告"),
        }),
      )
    }
    if f.step >= 3 {
      f.archived["c8"] = true
    }
    if f.step >= 4 {
      let i = today.search_by(fn(r) { text(Some(r), "id") == "c4" }).unwrap()
      today[i] = row("c4", "给设置页加一个深色模式开关", "ws1/st1", "刚刚", {
        "unread": true,
        "tone": "alert",
        "stateText": "要你帮忙：深色模式下图标看不清，要不要换一套？",
        "stateLead": "need",
        "stateRest": "深色模式下图标看不清，要不要换一套？",
        "agents": [agent("deepseek", "dsh")],
      })
    }
  }
  [
    { "daysAgo": 0, "at": 0, "label": "今天", "items": kept(f, today) },
    { "daysAgo": 1, "at": 0, "label": "昨天", "items": kept(f, yesterday) },
    { "daysAgo": 4, "at": 0, "label": "星期三", "items": kept(f, earlier) },
  ]
}

///|
/// How many of a list's rows the core sends while it is told no window (views.ts WINDOW_UNTOLD).
let fixture_window_untold : Int = 50

///|
/// A chats' list's key among the windows (Fixture `windows`): its params, said or left to their defaults, as views.ts's
/// windowKey.
fn fixture_window_key(params : Map[String, Json]) -> String {
  let on = fn(k : String) { if params.get(k) is Some(True) { "1" } else { "0" } }
  text(Some(Json::object(params)), "scope") + "\u{1}" + on("mine") + on("watching") + on("hidden")
}

///|
/// The first `window` rows of `days`, in their days, and how many more there are (the core's views.ts firstRows).
fn first_rows(days : Array[Json], window : Int) -> (Array[Json], Int) {
  let mut left = window
  let mut more = 0
  let out : Array[Json] = []
  for d in days {
    let its = items(Some(d), "items")
    if left <= 0 {
      more += its.length()
      continue
    }
    if its.length() <= left {
      out.push(d)
    } else {
      match d {
        Object(m) => {
          let v = m.copy()
          v["items"] = Json::array(its[:left].to_owned())
          out.push(Json::object(v))
        }
        _ => out.push(d)
      }
      more += its.length() - left
    }
    left -= if its.length() < left { its.length() } else { left }
  }
  (out, more)
}

///|
/// One made-up chat's whole row (`chatRow {station, session}`): its row as the made-up lists make it, all of it (those
/// lists send it cut: listed_chats); null where none lists it. That row alone is made or read, as the core answers it
/// (its ChatItem): never the whole list it is found in, which a press on a row of a long list paid for in the
/// benchmark's frames (#5483: 36M instructions a press on `home`, 362M on `paged`). The same row as the first one of
/// `fixture_chats {scope, mine:false}`, then of the same with `hidden` (chat_row_wbtest.mbt holds it).
fn fixture_chat_row(f : Fixture, params : Map[String, Json]) -> Json? {
  let p = Some(Json::object(params))
  let station = text(p, "station")
  let session = text(p, "session")
  // (a chat made here, newChat.create's key: its row as the core gives a new chat's, 新对话, made on its station in
  // whichever workspace that is, the made-up lists' first row's look)
  if session.has_prefix("new:") && f.mode != "loading" && f.mode != "empty" {
    let rows = fixture_days_head(f).map(fn(d) { items(Some(d), "items") }).flatten()
    match rows.get(0) {
      Some(Object(m)) => {
        let r = m.copy()
        r["id"] = Json::string(session)
        r["session"] = Json::string(session)
        r["station"] = Json::string(station)
        r["title"] = Json::string("新对话")
        r["unread"] = Json::number(0.0)
        return Some(Json::object(r))
      }
      _ => ()
    }
  }
  // (as fixture_chats has them: the first workspace's alone, none while they are read or in a workspace with none)
  if f.mode == "loading" || f.mode == "empty" || @settings.workspace_of(station) != "ws1" {
    return Some(Json::null())
  }
  let asked = fn(r : Json) {
    let r = Some(r)
    text(r, "station") == station && (text(r, "session") == session || text(r, "id") == session)
  }
  // a long account's rows, made once (long_paged_days), as the app has them (paged_row)
  if f.mode == "long-paged" {
    for d in long_paged_days(f) {
      for r in items(Some(d), "items") {
        if asked(r) {
          return Some(paged_row(r))
        }
      }
    }
    return Some(Json::null())
  }
  // one of the days after the first ones, made alone (none of the first days is it)
  match long_number(f, session) {
    Some(n) => {
      let r = long_row(n)
      return Some(if asked(r) && !f.archived.contains(text(Some(r), "id")) { r } else { Json::null() })
    }
    None => ()
  }
  // of the first days: home-hide's shown rows first, then its hidden ones (fixture_chats with `hidden`); every other
  // mode lists none hidden
  let rows = fixture_days_head(f).map(fn(d) { items(Some(d), "items") }).flatten()
  let hide = f.mode == "home-hide"
  for hidden in [false, true] {
    for r in rows {
      if (!hide || flag(Some(r), "hidden") == hidden) && asked(r) {
        return Some(r)
      }
    }
    if !hide {
      break
    }
  }
  Some(Json::null())
}

///|
/// A long-paged account's days, made once (paged_days), as a core keeps its chats: what each page asks costs it no more.
fn long_paged_days(f : Fixture) -> Array[Json] {
  match paged_days.val {
    Some(d) => d
    None => {
      let d = fixture_days(f)
      paged_days.val = Some(d)
      d
    }
  }
}

///|
/// The row of chat `session` (its session, or its id) of station `station` in a made-up `chats` value, as it is made
/// (whole: each made-up row has what the core's whole row has).
pub fn whole_row_in(chats : Json?, station : String, session : String) -> Json? {
  for d in items(chats, "days") {
    for i in items(Some(d), "items") {
      let r = Some(i)
      if text(r, "station") == station && (text(r, "session") == session || text(r, "id") == session) {
        return Some(i)
      }
    }
  }
  None
}

///|
/// What a whole row says that the `chats` list's rows are made without (client/core-ts views.ts WHOLE_ONLY, and what
/// the list's shape, ListedChat, has not: its time in words, its kept and muted, whom it is shared with): read of the
/// chat's whole row (`chatRow`) as a press, a hold, a swipe or a pointer begins.
let whole_only : Array[String] = [
  "time", "swipeAsk", "watch", "decision", "xshare", "mayShare", "mayPublish", "mayMove", "slackUrl", "slackApp", "feishuUrl",
  "commaUrl", "commaApp", "kept", "muted",
]

///|
/// A made-up `chats` value as the core sends it: each row cut to what the list's rows carry (ListedChat).
pub fn listed_chats(v : Json) -> Json {
  guard v is Object(o) && o.get("days") is Some(Array(days)) else { return v }
  let out = o.copy()
  out["days"] = Json::array(
    days.map(fn(d) {
      guard d is Object(day) && day.get("items") is Some(Array(rows)) else { return d }
      let cut = day.copy()
      cut["items"] = Json::array(rows.map(listed_row))
      Json::object(cut)
    }),
  )
  Json::object(out)
}

///|
/// A made-up chat's row cut to what a row of the `chats` list carries.
pub fn listed_row(row : Json) -> Json {
  guard row is Object(o) && whole_only.iter().any(fn(k) { o.contains(k) }) else { return row }
  let out = o.copy()
  for k in whole_only {
    out.remove(k)
  }
  Json::object(out)
}

///|
pub fn fixture_chats(f : Fixture, params : Map[String, Json]) -> Json? {
  let scope = match params.get("scope") {
    Some(String(s)) => s
    _ => ""
  }
  // each with how many of its agents are at work, as the core says it (views.ts: looks.doing): Willow's one at work,
  // Maple down; the card to share's (share-card, and share-card-… over the rest of the app) more of them, on more stations
  // (each as its rows read it: its state and what it does are the stations' rows', client/core-ts schema.ts StationState)
  let stations : Json = if f.mode == "webdemo" {
    [{ "station": "ws1/st1" }]
  } else if f.mode.has_prefix("share-card") {
    [{ "station": "ws1/st1" }, { "station": "ws1/st3" }, { "station": "ws1/st4" }, { "station": "ws1/st2" }]
  } else {
    [{ "station": "ws1/st1" }, { "station": "ws1/st2" }]
  }
  let rich = f.mode.has_prefix("share-card")
  let running = if rich { 9 } else { 1 }
  if f.mode == "loading" {
    return None
  }
  let mine = params.get("mine") is Some(True)
  let watching = params.get("watching") is Some(True)
  let days = if scope == "ws1" && f.mode != "empty" && !watching {
    let all = if f.mode == "long-paged" { long_paged_days(f) } else { fixture_days(f) }
    if mine {
      // the viewer's: those they are in
      all.map(fn(d) {
        let items = match field(Some(d), "items") {
          Some(Array(a)) =>
            a.filter(fn(r) {
              match field(Some(r), "people") {
                Some(Array(ps)) => ps.iter().any(fn(p) { flag(field(Some(p), "shown"), "mine") })
                _ => true
              }
            })
          _ => []
        }
        let o : Map[String, Json] = {
          "label": Json::string(text(Some(d), "label")),
          "items": Json::array(items),
        }
        Json::object(o)
      })
    } else {
      all
    }
  } else {
    []
  }
  let hidden = params.get("hidden") is Some(True)
  let days = if f.mode == "home-hide" {
    days.filter_map(fn(d) {
      match d {
        Object(m) => {
          let v = m.copy()
          let found = items(Some(d), "items").filter(fn(r) { flag(Some(r), "hidden") == hidden })
          v["items"] = Json::array(found)
          if found.is_empty() { None } else { Some(Json::object(v)) }
        }
        _ => None
      }
    })
  } else if hidden {
    []
  } else {
    days
  }
  let empty = days.iter().all(fn(d) { items(Some(d), "items").length() == 0 })
  // (its first `limit` rows and how many more it has, as the core's firstRows gives them)
  let (days, more) = if f.mode == "long-paged" {
    first_rows(days, f.windows.get(fixture_window_key(params)).unwrap_or(fixture_window_untold))
  } else {
    (days, 0)
  }
  let chats : Json = {
    "stations": if scope == "ws1" { stations } else { [] },
    "days": Json::array(days),
    "leading": "agents",
    "note": { "reading": false, "failing": [], "empty": Json::boolean(empty) },
    // the stations at a glance (Station's place in the bar): Willow online, Maple not (the web's demo: its one, online)
    "glyph": if scope == "ws1" && f.mode != "webdemo" {
      {
        "online": if rich { 3 } else { 1 },
        "dim": if rich { 0 } else { 1 },
        "failing": if rich { 1 } else { 0 },
        "working": if rich { 3 } else { 0 },
        "connecting": 0,
        "label": "1 台在线",
        "running": Json::number(running.to_double()),
        "now": Json::string("\{running} 个 agent 正在运行"),
        "unit": "个 agent 正在运行",
      }
    } else {
      { "online": 1, "dim": 0, "failing": 0, "working": 0, "connecting": 0, "label": "1 台在线" }
    },
  }
  match chats {
    Object(m) if more > 0 => m["more"] = Json::number(more.to_double())
    _ => ()
  }
  if f.mode == "long-paged" {
    // (as the core's message comes to the app, more of a list asked from what it has: the rows it had kept as they
    // were, those new read from their text)
    match chats {
      Object(m) =>
        m["days"] = Json::array(
          items(Some(chats), "days").map(fn(d) {
            match d {
              Object(dm) => {
                let v = dm.copy()
                v["items"] = Json::array(items(Some(d), "items").map(paged_row))
                Json::object(v)
              }
              _ => d
            }
          }),
        )
      _ => ()
    }
    Some(chats)
  } else {
    Some(chats)
  }
}

///|
// kept across runs: let go of as a fixture is made (fixture)
/// A long-paged account's rows as the app has had them, by their keys.
let paged_rows : Map[String, Json] = Map([])

///|
/// Row `r` as the app has it: as it had it, else read from its text.
fn paged_row(r : Json) -> Json {
  let key = text(Some(r), "station") + "\u{1}" + text(Some(r), "id")
  match paged_rows.get(key) {
    Some(had) => had
    None => {
      let read = @json.parse(r.stringify()) catch { _ => r }
      paged_rows[key] = read
      read
    }
  }
}

///|
// kept across runs: let go of as a fixture is made (fixture)
/// A long-paged account's days, made once.
let paged_days : Ref[Array[Json]?] = Ref(None)

///|
///|
/// The made-up core changed: its version on by one, told to what follows its topics (@settings.fixture_changed), as
/// the core's message for a subscription is (src/core Sub.changes).
pub fn Fixture::changed(self : Fixture) -> Unit {
  self.version += 1
  @settings.fixture_changed()
}

///|
/// How many changes the made-up core made: its own (Fixture::changed) and its station's later ones, done as they came
/// (fix_done): what is worked out of its data is worked out again as this moves on.
pub fn Fixture::changes(self : Fixture) -> Int {
  self.version + fix_done.val
}

///|
pub fn fixture_topic(f : Fixture, name : String, params : Map[String, Json]) -> Topic {
  // (read in a computed, followed as the made-up core changes: Fixture::changed)
  @settings.fixture_followed()
  fix_tick()
  // (the same answer while the made-up core is as it was, as the core's own: a subscription's value kept, not worked
  // out again each time it is read)
  let version = f.changes() + @settings.fixture_version() + fix_browse.changes + fix_presets_said.val
  // (a draft's own changes, its words as they are typed: its topic's alone, fix_compose_call)
  let own = if name == "composer" {
    @settings.fixture_draft_followed()
    match fix_writes.get(text(Some(Json::object(params)), "key")) {
      Some(w) => w.version
      None => 0
    }
  } else {
    0
  }
  let key = name + "\u{1}" + f.mode + "\u{1}" + Json::object(params).stringify()
  match fixture_answers.get(key) {
    Some((at, at_own, t)) if at == version && at_own == own => return t
    _ => ()
  }
  let t = fixture_answer(f, name, params, version)
  fixture_answers[key] = (version, own, t)
  t
}

///|
/// The made-up core's answers given, by topic and what was asked, each as of the version it was given at, and its
/// draft's for a draft's topic (fixture_topic).
// kept across runs: let go as a fixture is made (fixture)
let fixture_answers : Map[String, (Int, Int, Topic)] = Map([])

///|
/// Topic `name` asked with `params`, worked out of the made-up core as it is (`version`).
fn fixture_answer(f : Fixture, name : String, params : Map[String, Json], version : Int) -> Topic {
  let value = fixture_topic_inner(f, name, params)
  // a station's network as the core gives it: how this device reaches it (`way`) in the list, its figures in the
  // `stationNet` view of its own (the made-up stations say both as `net`)
  // (the stations whole, as the made-up cores describe them, of which each of their topics is answered as the core
  // answers it: the settings' fixture_stations.mbt)
  let wholes = fn() {
    match name {
      // (files-reading: the stations not read yet, the files' sidebar waiting on them)
      _ if f.mode == "files-reading" => None
      "stations" => fixture_stations_behind(f, fixture_stations_way(value))
      _ =>
        fixture_stations_behind(
          f,
          fixture_stations_way(fixture_topic_inner(f, "stations", { "scope": Json::string(text(Some(Json::object(params)), "scope")) })),
        )
    }
  }
  let value = match name {
    "stations" =>
      match wholes() {
        Some(Array(a)) => Some(Json::array(a.map(@settings.station_row)))
        v => v
      }
    "station" => @settings.station_said(wholes(), text(Some(Json::object(params)), "station"), "")
    "terminals" => Some(fixture_terminals(text(Some(Json::object(params)), "station"), f.mode))
    "stationUpdates" => Some(fixture_station_updates(f, wholes()))
    "stationPart" => {
      let p = Some(Json::object(params))
      @settings.station_said(wholes(), text(p, "station"), text(p, "part"))
    }
    // (the connects a row each, `connect` one whole and `connectCandidates` its choice's, of the connects whole the
    // made-up cores describe: the settings' fixture_connects.mbt)
    "connects" => @settings.connects_rows(@settings.connects_of_stations(value, wholes()))
    "connect" | "connectCandidates" => {
      let p = Some(Json::object(params))
      let all = fixture_topic_inner(f, "connects", { "scope": Json::string(text(p, "scope")), "mine": Json::boolean(false) })
      @settings.connect_said(all, text(p, "station"), text(p, "id"), name == "connectCandidates")
    }
    // (the accounts a row each and `profile` one whole, of the accounts whole the made-up cores describe: the settings'
    // fixture_profiles.mbt)
    "profiles" => @settings.profiles_rows(@settings.profiles_of_stations(value, wholes()))
    "profile" =>
      @settings.profile_said(fixture_topic_inner(f, "profiles", { "scope": Json::string(text(Some(Json::object(params)), "scope")) }), params)
    "chat" if f.mode == "chat-subchats-tall" && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_subchats_tall(value))
    "chat" if f.mode == "chat-subchats-idle" && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_subchats_idle(value))
    "chat" if f.mode == "chat-subchats-done-only" && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_subchats_done_only(value))
    "chat" if f.mode == "chat-subchats-done-many" && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_subchats_done_many(value))
    "chat" if f.mode == "chat-subchats-many" && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_subchats_many(value))
    "chat" if f.mode == "chat-subchats-one" && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_subchats_one(value))
    "chat" if f.mode == "chat-subchats-one-note" && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_subchats_one_note(value))
    "chat" if f.mode.has_prefix("chat-subchats") && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_subchats(value))
    "chat" if f.mode == "chat-lineage-long" && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_lineage_long(value))
    "chat" if f.mode == "chat-lineage" && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_lineage(value))
    "chat" if f.mode.has_prefix("chat-opened") && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_opened(value))
    "chat" if f.mode.has_prefix("chat-opener") && params.get("session") is Some(String("s-c1")) =>
      fixture_with_tabs(f, params, with_opener(value))
    "chat" => fixture_with_tabs(f, params, value)
    "chatSubchats" => {
      let q = text(Some(Json::object(params)), "q").trim().to_owned()
      let chat_p : Map[String, Json] = Map([])
      match params.get("station") {
        Some(v) => chat_p["station"] = v
        None => ()
      }
      match params.get("session") {
        Some(v) => chat_p["session"] = v
        None => ()
      }
      match params.get("thread") {
        Some(v) => chat_p["thread"] = v
        None => ()
      }
      let parent = fixture_topic(f, "chat", chat_p).value
      let opened = items(parent, "opened")
      let words : Array[String] = []
      for part in q.to_lower().split(" ") {
        let w = part.to_owned()
        if w != "" {
          words.push(w)
        }
      }
      let titled : Array[Json] = []
      let body_hits : Array[Json] = []
      for item in opened {
        let o = Some(item)
        if words.is_empty() {
          titled.push(item)
          continue
        }
        let title_low = text(o, "title").to_lower()
        let state_low = text(o, "stateText").to_lower()
        let sess = text(o, "session")
        let body = match sess {
          "s-c2" => "已验证 Vulkan 渲染管线与端到端冒烟用例全部通过"
          "s-c3" => "测试机 /data 分区剩余空间不足，建议清理 gradle 缓存"
          "s-c4" => "深色模式开关已接入主题 token，对比度检查通过"
          "s-c12" => "旧版引导页归档前已导出 3x 高清截图与 Vulkan 基准数据"
          "s-c9" => "产品评审议程与演示截图已同步给团队成员"
          _ => "子会话执行日志：已完成回归验证与构建检查"
        }
        let body_low = body.to_lower()
        if words.iter().all(fn(w) { title_low.contains(w) }) {
          titled.push(item)
        } else if words.iter().all(fn(w) { state_low.contains(w) }) {
          body_hits.push(item)
        } else if words.iter().all(fn(w) { body_low.contains(w) }) {
          match item {
            Object(m) => {
              let out = m.copy()
              out["foundText"] = Json::string(body)
              let marks : Array[Json] = []
              for w in words {
                match body_low.find(w) {
                  Some(idx) => marks.push({ "from": Json::number(idx.to_double()), "to": Json::number((idx + w.length()).to_double()) })
                  None => ()
                }
              }
              out["foundMarks"] = Json::array(marks)
              body_hits.push(Json::object(out))
            }
            _ => body_hits.push(item)
          }
        }
      }
      for h in body_hits {
        titled.push(h)
      }
      Some({
        "items": Json::array(titled),
        "words": Json::array(words.map(Json::string)),
        "reading": false,
      })
    }
    "stationNet" => {
      let address = text(Some(Json::object(params)), "station")
      if new_fix.station_many {
        return { value: Some(fix_station_many_net(address).unwrap_or(Json::null())), error: None, version }
      }
      let ws = match address.find("/") {
        Some(i) => address.exact_view(end=i).to_owned()
        None => address
      }
      let mut net = None
      match fixture_topic_inner(f, "stations", { "scope": Json::string(ws) }) {
        Some(Array(list)) =>
          for x in list {
            if text(Some(x), "station") == address {
              net = field(Some(x), "net")
            }
          }
        _ => ()
      }
      // (answered whatever it has, as the core does: a station that says no network, none, client/core-ts views.ts
      // stationNet's `ok: null`)
      Some(net.unwrap_or(Json::null()))
    }
    "stationDiag" => {
      let address = text(Some(Json::object(params)), "station")
      let ws = match address.find("/") {
        Some(i) => address.exact_view(end=i).to_owned()
        None => address
      }
      let mut diag = None
      match fixture_topic_inner(f, "stations", { "scope": Json::string(ws) }) {
        Some(Array(list)) =>
          for x in list {
            if text(Some(x), "station") == address {
              diag = field(Some(x), "diag")
            }
          }
        _ => ()
      }
      Some(diag.unwrap_or(Json::null()))
    }
    _ => value
  }
  { value, error: None, version }
}

///|
/// What the made-up station says of a file a message names (GET /sessions/:key/peek): the rich chat's place.mbt, a few
/// of its lines round the one named; anything else not there.
pub fn fixture_file_peek(path : String) -> Json {
  match path {
    "src/list/place.mbt" =>
      {
        "kind": "text",
        "path": "/Users/lin/shop/src/list/place.mbt",
        "name": "place.mbt",
        "size": 2048,
        "mtime": 0,
        "type": "text/plain",
        "lines": {
          "start": 9,
          "text": ["///|", "/// Rows put in before the anchor move it with them.", "fn ListState::moved(self : ListState, at : Int, n : Int) -> Unit {", "  if self.anchor >= at {", "    self.anchor = self.anchor + n", "  }", "}"],
          "at": 12,
        },
        "time": { "mtime": { "at": 0, "ago": "5 分钟前", "full": "10/26 11:00", "until": "", "past": true } },
      }
    // a screenshot, its picture by its token (its bytes: fixture_peek_picture)
    "shots/list.png" =>
      {
        "kind": "image",
        "path": "/Users/lin/shop/shots/list.png",
        "name": "list.png",
        "size": 48213,
        "mtime": 0,
        "type": "image/png",
        "image": { "type": "image/png", "picture": "fix-shot" },
        "time": { "mtime": { "at": 0, "ago": "5 分钟前", "full": "10/26 11:00", "until": "", "past": true } },
      }
    _ => Json::null()
  }
}

///|
/// The pictures the made-up station's cards name, as the core answers them (`link.preview.picture`: a page's icon and
/// picture; `file.peek.picture`: a screenshot's), each its bytes beside `{ type }`; one it has none of, the core's
/// error; any other call, none of these.
pub fn fixture_peek_picture(name : String, params : Json) -> Result[(Json, Bytes), Json]? {
  let p = Some(params)
  let png = fn(of : String) -> Result[(Json, Bytes), Json]? { Some(Ok(({ "type": "image/png" }, fixture_file_png(of)))) }
  let none : Result[(Json, Bytes), Json]? = Some(Err({ "code": "no_picture", "message": "没有这张图片", "status": 404 }))
  match name {
    "link.preview.picture" =>
      match (text(p, "url"), text(p, "which")) {
        ("https://example.com/bench/shot", "icon") => png("compare.png")
        ("https://example.com/bench/shot", "image") => png("after.png")
        _ => none
      }
    "file.peek.picture" => if text(p, "path") == "shots/list.png" { png("before.png") } else { none }
    _ => None
  }
}

///|
/// What the made-up station says of one message of a chat a link names (GET /threads/:id/entries).
pub fn fixture_message_peek() -> Json {
  {
    "author": "林小满",
    "text": "列表按天分组做好了，今天和昨天之外的日子都写日期。",
    "time": { "at": { "at": 0, "ago": "5 分钟前", "full": "10/26 11:00", "until": "", "past": true } },
  }
}

///|
/// What the made-up station says of a web link (station/src/links/preview.ts): the rich chat's benchmark page as a
/// page, a pull request on GitHub as GitHub says it, anything else nothing to show of it.
pub fn fixture_link_preview(url : String) -> Json {
  match url {
    "https://example.com/bench/list" =>
      { "kind": "page", "url": url, "title": "列表滚动的性能数据", "site": "Example", "description": "每一帧的耗时" }
    // (a page with an icon and a picture, by their tokens: fixture_peek_picture)
    "https://example.com/bench/shot" =>
      {
        "kind": "page",
        "url": url,
        "title": "列表滚动截图",
        "site": "Example",
        "icon": "fix-icon",
        "image": "fix-image",
      }
    "https://github.com/acme/shop/actions/runs/9001" =>
      {
        "kind": "github_actions_run", "url": url, "repository": "acme/shop", "number": 42,
        "title": "Build and publish the desktop app", "workflow": "pipeline", "state": "in_progress",
        "branch": "main", "commit": "bc074d6", "elapsed": "11 分 0 秒",
        "counts": { "passed": 7, "running": 16, "skipped": 6 },
        "jobs": [
          { "name": "desktop-win", "step": "Build, pack and sign the beta Windows app", "url": url + "/job/123#step:2:1" },
          { "name": "check-linux", "step": "Full check (ts)", "url": url + "/job/456#step:3:1" },
        ],
      }
    "https://github.com/acme/shop/pull/128" =>
      {
        "kind": "github_pull_request",
        "url": url,
        "repository": "acme/shop",
        "number": 128,
        "title": "首页列表按天分组",
        "state": "merged",
        "author": { "login": "lin" },
        "additions": 120,
        "deletions": 8,
        "changedFiles": 4,
        "checks": { "passed": 9, "failed": 0, "pending": 0 },
        "updatedAt": 0,
        "time": { "updatedAt": { "at": 0, "ago": "3 小时前", "full": "10/26 09:00", "until": "", "past": true } },
      }
    _ => { "kind": "none" }
  }
}

///|
/// What a made-up topic says (fixture_topic: as the screens' fixtures have it, before the core's shapes are made of it).
pub fn fixture_topic_inner(f : Fixture, name : String, params : Map[String, Json]) -> Json? {
  let account : Json = { "sub": "u1", "email": "lin@example.com", "name": "林" }
  let value : Json? = match name {
    "accounts" =>
      match f.mode {
        "signin" => Some([])
        "home-accounts" => Some([account, { "sub": "u2", "email": "lin@work.example", "name": "林" }])
        _ => Some([account])
      }
    // a chat's files downloaded (downloads_fixture.mbt)
    "downloads" => Some(fixture_downloads_topic())
    // the phone's 共享调试 as a request's card for it goes by: its switch on (chat-phone-off, chat-phone-step-off: off);
    // this device off the person's own lock, its request to be approved first (chat-phone-outside), or no lock of
    // theirs yet, the request as the core says it then: nothing first (chat-phone-none). Granted on the phone (-linked-,
    // -step-): lent to the chat's station as the card says it holds the phone (fixture_phone_lend)
    "adbShare" if f.mode.has_prefix("chat-phone") =>
      Some({
        "sharing": false,
        "phase": "off",
        "tunnels": 0,
        "on": f.mode != "chat-phone-off" && f.mode != "chat-phone-step-off",
        "lends": fixture_phone_lend(f.mode),
        "pairPort": if f.mode == "chat-phone-step-code" { Json::number(37115.0) } else { Json::null() },
        "personal": if f.mode == "chat-phone-multi" {
          // (two accounts signed in here: another's lock has this device on it; the workspace's account, u1, is to be
          // approved on its own, a trusted device of theirs showing the code once it asks)
          [
            { "sub": "s-work", "email": "lin@work.example", "standing": "member", "devices": [] },
            {
              "sub": "u1",
              "email": "lin@example.com",
              "standing": "outside",
              "devices": [],
              "pair": if fix_phone_join.val {
                { "state": "code", "devices": 1, "untilText": "14:05 前有效", "showing": ["MacBook Pro"] }
              } else {
                Json::null()
              },
            },
          ]
        } else {
          [
            {
              "sub": "s",
              "email": "lin@example.com",
              "standing": match f.mode {
                "chat-phone-outside" => "outside"
                "chat-phone-none" => "none"
                _ => "member"
              },
              "devices": [],
            },
          ]
        },
        "grants": match f.mode {
          "chat-phone-outside" => [{ "id": "p-1", "status": "pending", "sub": "s", "join": true }]
          "chat-phone-multi" => [{ "id": "p-1", "status": "pending", "sub": "u1", "join": true }]
          "chat-phone-none" => [{ "id": "p-1", "status": "pending", "sub": "s" }]
          _ => []
        },
      })
    // the workspace's rigs (its stations that only run tasks) as a request's card for one goes by: on an app whose device is on its person's own
    // lock (chat-rig-web: a web page; chat-rig-outside: a device its trusted devices have not approved yet)
    "rigs" if f.mode.has_prefix("chat-rig") =>
      Some({
        "locked": false,
        "app": f.mode != "chat-rig-web",
        "personal": if f.mode == "chat-rig-outside" { "outside" } else { "member" },
        "rigs": [],
      })
    // what a web link in a message is, as the link's station says it (the core's `linkPreview`: peeks.mbt)
    "linkPreview" => Some(fixture_link_preview(text(Some(Json::object(params)), "url")))
    // what a file a message names is, as the station reads it under its agent's working directory (peeks.mbt)
    "filePeek" => Some(fixture_file_peek(text(Some(Json::object(params)), "path")))
    // one message of a chat a link names, as its station reads it (peeks.mbt)
    "messagePeek" => Some(fixture_message_peek())
    // what is written, as the core's composers keep it (compose_fixture.mbt): its files up at once
    "composer" => Some(fix_compose_view(f, text(Some(Json::object(params)), "key")))
    // signed in with no workspace yet: landing, landing-invited (an invitation waiting), blocked (the
    // account not let into this app), landing-code (still.fail cloud asking for an invite code to make one)
    "workspaces" if f.mode == "landing" ||
      f.mode == "landing-invited" ||
      f.mode == "blocked" ||
      f.mode == "landing-code" => {
      let o : Map[String, Json] = {
        "account": account,
        "workspaces": [],
        "invitations": if f.mode == "landing-invited" {
          [{ "id": "inv1", "name": "星火工作室", "inviter": "安娜", "role": "member" }]
        } else {
          []
        },
        "loaded": true,
      }
      if f.mode == "blocked" {
        o["blocked"] = "此账号暂未开放测试版"
      }
      Some([Json::object(o)])
    }
    "workspaces" =>
      Some([
        {
          "account": account,
          "workspaces": if f.mode == "webdemo" {
            [{ "id": "ws1", "name": "Acme", "stations": 1, "members": 3 }]
          } else {
            [
              { "id": "ws1", "name": "星火工作室", "stations": 2, "members": 3 },
              { "id": "ws2", "name": "个人", "stations": 1, "members": 1 },
            ]
          },
          "invitations": [],
          "loaded": true,
        },
      ])
    "prefs" => {
      let lf : Map[String, Json] = Map([])
      for k, v in f.filters {
        lf[k] = Json::string(v)
      }
      let o : Map[String, Json] = {
        "workspace": Json::string(f.workspace),
        "chatTabs": Json::object(f.chat_tabs),
        "listFilter": Json::object(lf),
        "sidebars": Json::object(f.sidebars),
        "remoteTabs": Json::object(f_remote_tabs(f)),
        "terminalZoom": if f_terminal_zoom(f) == "" { Json::null() } else { Json::string(f_terminal_zoom(f)) },
        "screenQuality": f_screen_prefs(f).get("screenQuality").unwrap_or(Json::null()),
        "screenFps": f_screen_prefs(f).get("screenFps").unwrap_or(Json::null()),
        "appearance": Json::string(f.appearance),
        "windowZoom": Json::string(f.window_zoom),
        "motion": Json::string(f.motion),
        "glassFrost": if f.glass_frost == "" { Json::null() } else { Json::string(f.glass_frost) },
        "haptics": Json::string(f.haptics),
        "appUpdate": Json::string(f.app_update),
        "shareLook": if f.share_look == "" { Json::null() } else { Json::string(f.share_look) },
        "cpuDial": if f.cpu_dial == "" { Json::null() } else { Json::string(f.cpu_dial) },
        "fonts": fixture_fonts(f.fonts),
        "faces": fixture_faces(f.fonts),
        "keys": fixture_keys(f.keys),
        "sendKey": if f.send_key == "" { Json::null() } else { Json::string(f.send_key) },
        // (实验性功能 and the channel, as the core's prefs.ts shows them: features.ts)
        "testChannel": Json::boolean(f.test_channel),
        "experimental": fixture_experimental_json(f.experimental),
        "features": fixture_features_json(f.test_channel, f.experimental),
        "experimentalItems": fixture_experimental_items_json(f.test_channel, f.experimental),
        "keymap": fixture_keymap(f.keys, send_key=f.send_key),
        // the rail as the core says it (rail.ts railView), none kept: its default
        "railView": match fixture_kept("railView", {}, None) {
          // (home-foot: no bell in the rail, what it would list in the sidebar's foot)
          Some(Ok((v, _))) if f.mode.has_prefix("home-foot") => rail_unbelled(v)
          Some(Ok((v, _))) => v
          _ => Json::null()
        },
      }
      // the board's (board_fixture.mbt)
      board_prefs_into(o)
      if f.mode == "home-stale-build" {
        o["staleBuild"] = Json::boolean(true)
      }
      // the drive's ways, the files' page's tabs and favourites (browse_fixture.mbt)
      fix_browse_prefs_into(o)
      // whether what was opened and let go is brought, up to how big (downloads_fixture.mbt)
      fix_fill_prefs_into(o)
      Some(Json::object(o))
    }
    "fonts" => Some(fixture_fonts_topic(f))
    "driveBrowse" | "filesTabs" => fix_browse_topic(f, name, params)
    "job" | "previewLoad" => fixture_service_topic(f, name, params)
    "shareIn" => fixture_share_topic(params)
    "imageNear" => fixture_image_near(params)
    // (待处理 open, Maple offline: decide_fixture.mbt)
    "chats" if f.mode.has_prefix("home-attention") || f.mode.has_prefix("home-foot") => fixture_chats(f, params).map(fn(v) { listed_chats(fix_with_trouble(v, params)) })
    "chats" if f.mode == "home-syncing" => fixture_chats(f, params).map(fn(v) { listed_chats(fix_with_syncing(v)) })
    "chats" if f.mode == "home-restart-interrupted" && f.step == 0 =>
      fixture_chats(f, params).map(fn(v) {
        let base = listed_chats(v)
        match base {
          Object(m) => {
            let m = m.copy()
            m["interrupted"] = Json::array([
              {
                "station": "ws1/st1",
                "stationName": "AFK-东京服务器",
                "count": 12,
                "chats": [
                  { "key": "s-c1", "thread": 1, "title": "修复登录态失效续跑问题" },
                  { "key": "s-c2", "thread": 2, "title": "检查 macOS 内存压力检测逻辑" },
                  { "key": "s-c3", "thread": 3, "title": "排查飞书长连接断连原因" },
                ],
              },
            ])
            Json::object(m)
          }
          _ => base
        }
      })
    "chats" => fixture_chats(f, params).map(listed_chats)
    // (one chat's whole row, of the same made-up chats: what the list's rows are cut from)
    "chatRow" => fixture_chat_row(f, params)
    "fleet" => Some(fixture_fleet(f))
    "agentRates" => Some({
      "title": "实时输出速度",
      "total": "≈ 154 token/s",
      "status": "3 个会话正在输出",
      "basis": "按模型输出估算；每个会话包含并行的子 agent。",
      "rows": [
        { "key": "1", "title": "准备发布说明", "sub": "Studio · GPT-6", "rate": "≈ 72 token/s", "station": "studio", "chat": "1" },
        { "key": "2", "title": "排查构建失败", "sub": "Studio · Claude", "rate": "≈ 49 token/s", "station": "studio", "chat": "2" },
        { "key": "3", "title": "改进工作区搜索", "sub": "Laptop · GPT-6", "rate": "≈ 33 token/s", "station": "laptop", "chat": "3" },
      ],
      "more": "",
      "notes": [],
    })
    // (the Profile overview's pools, as the core makes them of the made-up accounts: the settings' fixture_overview)
    "profilesOverview" => Some(@settings.fixture_overview())
    "railCard" => fixture_rail_card(params)
    "search" => fixture_search(f, params)
    // the archive's chats (the settings' made-up ones): the wide frame's sidebar lists them
    "archive" => @settings.fixture_topic(f.mode, name, params)
    // (the web's demo has none)
    "workspaceMarks" if f.mode == "webdemo" => Some({ "workspaces": { "ws1": {} } })
    // home-attention-login: and another chat's login card waiting for the viewer, first, in its own words
    "workspaceMarks" if f.mode == "home-attention-login" => Some(fix_attention_marks(login=true))
    "workspaceMarks" if f.mode == "home-attention" || f.mode.has_prefix("home-shared") =>
      Some(fix_attention_marks())
    "workspaceMarks" if board_mode(f.mode) => Some(board_marks())
    "workspaceMarks" =>
      Some({
        "workspaces": {
          // (each with what the other has waiting)
          "ws1": { "alert": 1, "unread": 2, "wait": 1, "tone": "alert", "others": "done" },
          "ws2": { "alert": 0, "unread": 2, "tone": "done", "others": "alert" },
        },
        // what the badge counts, as the core says it (the prefs' badgeKinds, or their defaults)
        "badgeKinds": { "on": true, "wait": true, "failed": true, "done": true, "message": true, "services": true },
      })
    // (the workspaces read slowly, the device's data not opened: with MBUI_HOLD=workspaces, the splash saying so)
    "status" if f.mode == "reading-slow" =>
      Some({
        "state": "trouble",
        "text": "本机数据无法打开，只能从网络读取 · 共 4 项 · 172 KB/s",
        "items": [],
        "lines": ["本机数据无法打开，只能从网络读取"],
      })
    "status" => Some({ "items": [] })
    // what the last update brought: said on MBUI_FIXTURE=home-news only
    "changelog" if f.mode == "home-news" =>
      Some({
        "build": 1310,
        "tabs": [],
        "news": {
          "build": "0.1.1310",
          "entries": [
            { "text": ["设置里可以注销账号", "聊天顶栏会提示 station 更新"] },
            { "text": ["执行历史里可以认领 Slack 用户", "后台任务的面板可以拖高"] },
          ],
        },
      })
    // (chat-screens-pc: the same chat on a device with no adb to lend, a Mac's or a PC's)
    "adbCard" if f.mode == "chat-screens-pc" =>
      Some({ "title": "共享调试", "line": "仅安卓 app 支持共享调试", "sharing": false, "lendable": false })
    "screenCard" | "adbCard" | "terminalCard" => fixture_link_card(name, params)
    "pick" if params.get("of") is Some(String(o)) && o.has_prefix("session:") => Some(fix_session_pick())
    "pick" if params.get("of") is Some(String("connect-new:preset")) && preset_model_cleared.val =>
      match fix_pick() {
        Object(o) => {
          let m = o.copy()
          m["value"] = { "model": Json::null(), "runtime": Json::string(new_fix.runtime), "effort": Json::string(new_fix.effort) }
          m["valueOption"] = Json::null()
          m["changed"] = Json::boolean(true)
          if m.get("combos") is Some(Array(cs)) {
            m["combos"] = Json::array(
              cs.map(fn(c) {
                match c {
                  Object(co) => {
                    let cm = co.copy()
                    cm["selected"] = Json::boolean(false)
                    Json::object(cm)
                  }
                  other => other
                }
              }),
            )
          }
          Some(Json::object(m))
        }
        other => Some(other)
      }
    "presets" =>
      if new_fix.presets_late && !text(Some(Json::object(params)), "station").has_suffix("st2") {
        None
      } else {
        Some(fix_presets_of(text(Some(Json::object(params)), "station")))
      }
    // (a preset whole, and the other members': the new chat's preset menu's and its dialog's)
    "preset" => fix_preset_one(text(Some(Json::object(params)), "id"))
    "otherPresets" => Some(fix_other_presets())
    // (the person's drafts of 待派发: board_fixture.mbt)
    "boardDrafts" => Some(board_drafts_topic(text(Some(Json::object(params)), "scope")))
    "newChat" | "pick" => fixture_new_topic(f, name, scope=text(Some(Json::object(params)), "scope"))
    // none left up long, as the core answers it (the first page waits for it); decide_fixture.mbt's modes say theirs
    "longJobs" if !decide_mode(f.mode) => Some({ "groups": [], "lit": false, "ids": [] })
    _ =>
      match decide_fixture_topic(f, name, params) {
        Some(v) => v
        // the settings' pages (src/sfapp/settings/fixture.mbt): theirs first on their own screenshots, else the chats'
        None if f.mode.has_prefix("settings") || f.mode.has_prefix("place-") =>
          match @settings.fixture_topic(f.mode, name, params) {
            Some(v) => Some(v)
            None => fixture_chat_topic(f, name, params)
          }
        None =>
          match fixture_chat_topic(f, name, params) {
            Some(v) => Some(v)
            None => @settings.fixture_topic(f.mode, name, params)
          }
      }
  }
  value
}

///|
/// The made-up stations as the core lists them: each one's `net` left out, how this device reaches it (`way`: its
/// path and via) in its place.
pub fn fixture_stations_way(v : Json?) -> Json? {
  match v {
    Some(Array(list)) =>
      Some(
        Json::array(
          list.map(fn(x) {
            match x {
              Object(o) => {
                let m : Map[String, Json] = Map([])
                for k, val in o {
                  if k != "net" {
                    m[k] = val
                  }
                }
                match o.get("net") {
                  Some(n) =>
                    m["way"] = { "path": Json::string(text(Some(n), "path")), "via": Json::string(text(Some(n), "via")) }
                  None => ()
                }
                Json::object(m)
              }
              _ => x
            }
          }),
        ),
      )
    _ => v
  }
}

///|
/// `base` answering `ms` late, as a phone's core across its thread does: each call's answer and each topic's first value
/// (src/sffilm's MBUI_CORE_MS: what shows meanwhile filmed too). What is due comes at its moment, told then as the
/// made-up core's change (fix_later), what reads it reading it anew.
pub fn round_trip(base : Source, ms : Double) -> Source {
  round_trip_by(base, fn() { ms })
}

///|
/// `base` answering as round_trip does, each ask `ms()` late as it is asked: a test's own setup answered at once, what
/// it watches late (a chat opened once the first is shown: its view on its way while the test looks).
pub fn round_trip_by(base : Source, ms : () -> Double) -> Source {
  let read : Map[String, Bool] = Map([])
  {
    ..base,
    call: fn(name, params, done) { (base.call)(name, params, fn(r) { fix_later(ms(), fn() { done(r) }) }) },
    topic_read: fn(name, params) {
      @settings.fixture_followed()
      let t = base.topic(name, params).get().snapshot()
      let k = name + Json::object(params).stringify()
      // (its first value come late: set at its moment and told then (fix_later), what reads it following the made-up
      // core's changes as it reads it (fixture_followed); nothing set as it is read)
      match read.get(k) {
        Some(true) => t
        Some(false) => { value: None, error: None, version: -1 }
        None => {
          read[k] = false
          fix_later(ms(), fn() {
            read[k] = true
            fix_first.val = true
          })
          { value: None, error: None, version: -1 }
        }
      }
    },
  }
}

///|
/// `f` done `ms` from now by the made-up core of round_trip_again, as fix_later does it but told as no change of the
/// made-up station's (fix_now's fixture_changed): what it does is answer the client, which the client is told itself.
fn made_core_later(ms : Double, f : () -> Unit) -> Unit {
  match (fix_clock.val, fix_ctx.val) {
    // (between frames at its moment, as a device's core's answer comes: under a Tester its fake host's, in no frame's
    // own work)
    (None, Some(_)) => @ui.later_between_frames(ms, "made core", f)
    _ => fix_later(ms, f)
  }
}

///|
/// What the made-up core says to the client (`text`, one of its messages) posted as a core's is, taken by the client at
/// its moment between frames (a timer of the window's runtime, or the test's clock), while `live` says it is the core
/// still: told to `heard` then. Outside what the made-up core works out itself, so a count of what the app runs can set
/// that apart (scripts/instrbench.sh: round_trip_again's own).
fn made_core_post(text : String, heard : (String) -> Unit, live : () -> Bool) -> Unit {
  made_core_later(0.0, fn() {
    if live() {
      heard("in " + text)
      // (on the core's channel, as a device's core posts it: what changes only a topic's signal, or answers a call
      // whose answer does no more, taken as it comes, the rest as the next frame begins: sfcore's listen)
      @ui.outside_post("core", text)
    }
  })
}

///|
/// `base` answering through the app's own client of its core (src/core's Client), as a core across its thread does: a
/// topic's first value `ms` late each time the client subscribes to it, what changes of it after told as it changes,
/// and none of it after the client lets it go (its unsubscribe, sent once no reader of it is left anywhere); so what is
/// asked again and when is the client's to say, as on a device, never this made-up core's own count of who reads what.
/// Calls are carried by the client to this core, answered by `base`'s and posted back on the core's channel, as a
/// device's are. What the client sends and what is
/// answered are the same messages a run's trace keeps (src/core's trace.mbt), told to `heard` as they go. `late`, where
/// said, how late each topic is answered by its name and params (as a page reads them), in `ms`'s place. `delta_of`,
/// where said, what changed of a topic's value as the core's keyed ops (by its name and params): a change after its
/// first value sent as those (`{id, delta}`), as the core sends it, not its value whole again.
pub fn round_trip_again(
  base : Source,
  ms : Double,
  heard? : (String) -> Unit = fn(_) {  },
  late? : (String, Map[String, Json]) -> Double,
  delta_of? : (String, Map[String, Json]) -> Array[Json]?,
) -> Source {
  // (the topic and params a page read, by what the client puts on the wire for them: what to answer it with)
  let named : Map[String, (String, Map[String, Json])] = Map([])
  // (what is answered for each subscription the client holds, by its id: called to stop)
  let live : Map[Int, () -> Unit] = Map([])
  // (what each subscription last gave of its value, its JSON's text; and what was kept by each version said as one was
  // let go of with `keep` (the client's Client::keep): asked again with that version, answered `same` where the value is
  // that still, as the core answers it)
  let gave : Map[Int, String] = Map([])
  let kept_texts : Map[String, String] = Map([])
  let wire_key = fn(name : String, wire : Map[String, Json]) { @sfbase.wire_topic_key(name, wire) }
  // (whether this one is the core still: one another took the core's place from (a test after, a kept conversation)
  // says nothing more, all it answers stopped)
  let mine = Ref(0)
  let give = fn(text : String) {
    made_core_post(text, heard, fn() {
      if mine.val == 0 || @core.served() != mine.val {
        for _, stop in live {
          stop()
        }
        live.clear()
        return false
      }
      true
    })
  }
  let send = fn(text : String) {
    heard("out " + text)
    let j = @json.parse(text) catch { _ => return }
    guard j is Object(m) && m.get("id") is Some(Number(n, ..)) else { return }
    let id = n.to_int()
    match (m.get("subscribe"), m.get("unsubscribe"), m.get("call")) {
      (Some(Object(t)), _, _) => {
        let topic = match t.get("topic") {
          Some(String(x)) => x
          _ => return
        }
        let wire : Map[String, Json] = Map([])
        for k, v in t {
          if k != "topic" {
            wire[k] = v
          }
        }
        let (name, params) = named.get(wire_key(topic, wire)).unwrap_or((topic, wire))
        let have = match m.get("have") {
          Some(String(h)) => kept_texts.get(h)
          _ => None
        }
        let on = Ref(true)
        let stop : Ref[() -> Unit] = Ref(fn() {  })
        live[id] = fn() {
          on.val = false
          (stop.val)()
        }
        // its first value `ms` late (or as `late` says), each change after as it comes
        let due = match late {
          Some(by) => by(name, params)
          None => ms
        }
        made_core_later(due, fn() {
          guard on.val else { return }
          // (owned by nothing: what follows the topic is the client's subscription, let go only by its unsubscribe.
          // Made so as it is made where nothing reads and no owner is set: a timer of the window's runtime, run
          // outside the frame's reading (ui's fx_frame_start), or a test's fix_clock_set between frames. One made as a
          // frame is read would be that frame's, and is a fault: @signals.effect_in_watch)
          // (what it gave last: a value worked out again the same is no change, and a core sends none for it)
          let last : Ref[String] = Ref("")
          // (the version it gave last, where what changed is sent as ops: -1 none yet)
          let gave_at = Ref(-1)
          stop.val = @signals.effect(fn() {
            let now = base.topic(name, params).get().snapshot()
            // (a change after its first value, as the core sends it: its ops alone)
            if gave_at.val >= 0 && now.version != gave_at.val && now.error is None {
              match delta_of {
                Some(f) =>
                  match f(name, params) {
                    Some(ops) => {
                      gave_at.val = now.version
                      // (what it gave whole is no longer what it holds: nothing kept of it to answer `same` by)
                      gave.remove(id)
                      let out = ({ "id": Json::number(id.to_double()), "delta": Json::array(ops) } : Json).stringify()
                      @signals.after_flush(fn() { if on.val { give(out) } })
                      return
                    }
                    None => ()
                  }
                None => ()
              }
            }
            let m : Json? = match (now.value, now.error) {
              (Some(v), _) => Some({ "id": Json::number(id.to_double()), "value": v })
              (_, Some(e)) => Some({ "id": Json::number(id.to_double()), "error": e })
              _ => None
            }
            match m {
              Some(m) => {
                let text = m.stringify()
                if text != last.val {
                  let first = last.val == ""
                  last.val = text
                  gave_at.val = now.version
                  let said = match now.value {
                    Some(v) => v.stringify()
                    None => ""
                  }
                  gave[id] = said
                  // (asked with the version of a value kept that is its value still: `same`, no value)
                  let out = if first && have is Some(h) && h == said && said != "" {
                    ({ "id": Json::number(id.to_double()), "same": Json::boolean(true) } : Json).stringify()
                  } else {
                    text
                  }
                  @signals.after_flush(fn() { if on.val { give(out) } })
                }
              }
              None => ()
            }
          })
        })
      }
      (_, Some(True), _) => {
        match live.get(id) {
          Some(stop) => {
            stop()
            live.remove(id)
          }
          None => ()
        }
        // (let go of with `keep`: the version of what it gave last, its value kept by it)
        if m.get("keep") is Some(True) {
          let v = "k" + id.to_string()
          match gave.get(id) {
            Some(said) if said != "" => kept_texts[v] = said
            _ => ()
          }
          give(({ "id": Json::number(id.to_double()), "v": Json::string(v) } : Json).stringify())
        }
        gave.remove(id)
      }
      (_, _, Some(String(call))) =>
        (base.call)(call, m.get("params").unwrap_or(Json::null()), fn(r) {
          let answer : Json = match r {
            Ok(v) => { "id": Json::number(id.to_double()), "ok": v }
            Err(e) => { "id": Json::number(id.to_double()), "error": e }
          }
          // (`ms` late, as a topic's first value is: a round trip across the core's thread)
          made_core_later(ms, fn() { give(answer.stringify()) })
        })
      _ => ()
    }
  }
  // (the client's core this one from the first read on, once: given up for good once another takes the core's place
  // (a Tester begun anew, a kept conversation), never taken back)
  let serving = fn() {
    if mine.val == 0 {
      // (the core's channel taken as a device's app takes it: sfcore's listen, as far as this package knows its lists,
      // the calls whose answers change only signals; what more a run said there kept)
      @ui.on_message("core", @core.receive)
      @ui.on_message_said("core", @core.receive_said)
      @ui.on_messages_ahead("core", @core.receive_ahead)
      for name in @sfbase.calls_said() {
        @core.said(name)
      }
      mine.val = @core.serve(send)
      // (as the app's client tells it: a chat list's first window before the list, a chat's before the chat:
      // src/stillfail's main)
      @core.client.tells_before(@sfbase.chats_told_before)
    }
  }

  let wire = fn(name : String, params : Map[String, Json]) { @sfbase.core_topic_params(name, params) }
  {
    ..base,
    // (a call carried by the client to this core and answered on its channel, as a device's app calls its core:
    // stillfail's core_source; one whose answer nobody reads given none to read it)
    call: fn(name, params, done) {
      serving()
      if @sfbase.unread_answer(done) {
        @core.call(name, params~)
        return
      }
      @core.call(name, params~, on_done=done)
    },
    topic_read: fn(name, params) {
      serving()
      let w = wire(name, params)
      named[wire_key(name, w)] = (name, params)
      let s = @core.follow_topic(name, params=w)
      { value: s.value, error: s.error, version: s.version }
    },
    topic_key: fn(name, params) { wire_key(name, wire(name, params)) },
    topic_keyed: fn(name, params, field, keys) {
      serving()
      @core.keyed_of(name, wire(name, params), field, keys)
    },
    waits: fn(name, params) {
      serving()
      @core.follow_topic(name, params=wire(name, params)).waiting
    },
    generation: fn(name, params) { @core.client.topic_generation(name, params=wire(name, params)) },
    release: fn(name, params) { @core.release_topic(name, params=wire(name, params)) },
    leave: fn(name, params, reason) {
      if reason is @sfbase.TopicLeave::Owned(stop) {
        stop()
        return
      }
      @core.leave_topic(name, params=wire(name, params))
    },
    refresh: fn(name, params) { @core.refresh_topic(name, params=wire(name, params)) },
  }
}

///|
fn init {
  // (a made-up core's place given back as every run begins: the engine's, or what the run sets)
  @ui.on_reset(fn() { @core.serve_end() })
}

///|
/// `base` with the topics named in `held` never come (src/sffilm's MBUI_HOLD): what shows while they are read the
/// first time, filmed.
pub fn held_topics(base : Source, held : Array[String]) -> Source {
  let held = of_wholes(held)
  {
    ..base,
    topic_read: fn(name, params) {
      if held.contains(name) {
        { value: None, error: None, version: -1 }
      } else {
        base.topic(name, params).get().snapshot()
      }
    },
  }
}

///|
/// `base` with the topics named in `failed` failing to be read, the core saying why as `why` (src/sffilm's MBUI_FAILED):
/// what shows when reading them fails, filmed.
pub fn failed_topics(base : Source, failed : Array[String], why : String) -> Source {
  let failed = of_wholes(failed)
  {
    ..base,
    topic_read: fn(name, params) {
      if failed.contains(name) {
        { value: None, error: Some({ "message": Json::string(why) }), version: 1 }
      } else {
        base.topic(name, params).get().snapshot()
      }
    },
  }
}

///|
/// Topics named, with a station's page and its parts where the stations are among them, one connect's and its choice's
/// where the connects are: "the stations not read" is each of their topics not read.
fn of_wholes(names : Array[String]) -> Array[String] {
  let out = names.copy()
  if names.contains("stations") {
    out.push("station")
    out.push("stationPart")
  }
  if names.contains("connects") {
    out.push("connect")
    out.push("connectCandidates")
  }
  out
}

///|
/// Whether `mode` is of the stable channel (its name ends in -stable, before -dark).
pub fn fixture_stable_mode(mode : String) -> Bool {
  mode.has_suffix("-stable") || mode.has_suffix("-stable-dark")
}

///|
/// The core's experimental features (client/core-ts/src/features.ts `FEATURES`, stage `experimental`), in its order,
/// each with its `betaOnly`: what this made-up core says of them (scripts/features-check.ts holds it to the core's).
let fixture_experimental_features : Array[(String, Bool)] = [
  ("farviewNative", true),
  ("board", false),
  ("selectionIntent", false),
  ("cmdQuote", false),
]

///|
/// The core's `beta` features of the device's own (features.ts `FEATURES`, stage `beta`, not `station`), in its order:
/// on as the made-up app is of the test channel, off on stable (scripts/features-check.ts holds it to the core's).
let fixture_beta_features : Array[String] = []

///|
/// The prefs' `experimental`: the switches on of those the core has.
fn fixture_experimental_json(on : Map[String, Bool]) -> Json {
  let out : Map[String, Json] = Map([])
  for e in fixture_experimental_features {
    if on.get(e.0) == Some(true) {
      out[e.0] = Json::boolean(true)
    }
  }
  Json::object(out)
}

///|
/// The prefs' `features` (features.ts `featuresOf`): the device's own, a `beta` one on the test channel alone, a
/// `betaOnly` one never on a stable app.
fn fixture_features_json(test_channel : Bool, on : Map[String, Bool]) -> Json {
  let out : Map[String, Json] = Map([])
  for id in fixture_beta_features {
    out[id] = Json::boolean(test_channel)
  }
  for e in fixture_experimental_features {
    out[e.0] = Json::boolean((!e.1 || test_channel) && on.get(e.0) == Some(true))
  }
  Json::object(out)
}

///|
/// The prefs' `experimentalItems` (features.ts `experimentalItemsOf`): a `betaOnly` one on the test channel alone.
fn fixture_experimental_items_json(test_channel : Bool, on : Map[String, Bool]) -> Json {
  let out : Array[Json] = []
  for e in fixture_experimental_features {
    if !e.1 || test_channel {
      out.push({ "id": Json::string(e.0), "enabled": Json::boolean(on.get(e.0) == Some(true)) })
    }
  }
  Json::array(out)
}

///|
/// The experimental switches a fixture of `mode` begins with on: the board's in the board's modes (a test's of the
/// board sees it), Farview's own tabs in `farview` (a film of a Farview tab, MBUI_WINDOW its screen).
fn fixture_experimental(mode : String) -> Map[String, Bool] {
  if board_mode(mode) {
    { "board": true }
  } else if mode == "farview" {
    { "farviewNative": true }
  } else {
    Map([])
  }
}

///|
/// Where a fixture's own number is kept in its `windows` (whose keys are a workspace's, a scope's and a filter's, each
/// line apart: never this): what is kept of it apart from `Fixture` (its remote tabs, its terminals' zoom) is kept by
/// that number, so `Fixture`'s shape, which every unit that reads one is compiled by, stays as it was.
let fixture_id_key = "\u{0}fixture_id"

///|
priv struct FixtureIds {
  mut last : Int
}

///|
fn FixtureIds::next(self : FixtureIds) -> Int {
  self.last += 1
  self.last
}

///|
// kept across runs: only ever counts up, each fixture's its own
let fixture_ids : FixtureIds = { last: 0 }

///|
// kept across runs: by fixture_ids', each fixture's alone
let fixture_remote_tabs : Map[Int, Map[String, Json]] = Map([])

///|
// kept across runs: by fixture_ids', each fixture's alone
let fixture_terminal_zooms : Map[Int, String] = Map([])

///|
// kept across runs: by fixture_ids', each fixture's alone (a screen's 画质 and 帧率 kept by the prefs: `screenQuality`,
// `screenFps`)
let fixture_screen_prefs : Map[Int, Map[String, Json]] = Map([])

///|
/// The fixture's screens' 画质 and 帧率 as the prefs keep them (none: 自动).
fn f_screen_prefs(f : Fixture) -> Map[String, Json] {
  let id = fixture_id(f)
  match fixture_screen_prefs.get(id) {
    Some(m) => m
    None => {
      let m : Map[String, Json] = Map([])
      fixture_screen_prefs[id] = m
      m
    }
  }
}

///|
fn fixture_id(f : Fixture) -> Int {
  f.windows.get(fixture_id_key).unwrap_or(0)
}

///|
/// The fixture's remote workbench's tabs as the prefs keep them (`remoteTabs`, by workspace).
fn f_remote_tabs(f : Fixture) -> Map[String, Json] {
  let id = fixture_id(f)
  match fixture_remote_tabs.get(id) {
    Some(m) => m
    None => {
      let m : Map[String, Json] = Map([])
      fixture_remote_tabs[id] = m
      m
    }
  }
}

///|
/// The fixture's terminals' zoom as the prefs keep it (`terminalZoom`, "" none).
fn f_terminal_zoom(f : Fixture) -> String {
  fixture_terminal_zooms.get(fixture_id(f)).unwrap_or("")
}

///|
/// A made-up core of `mode` as it begins (fixture: what it serves).
fn made_fixture(mode : String) -> Fixture {
  {
    mode: if mode == "" { "home" } else { mode },
    workspace: "ws1",
    appearance: if mode.has_suffix("-dark") || @ui.env("MBUI_DARK") == "1" {
      "dark"
    } else {
      "light"
    },
    motion: "",
    glass_frost: @ui.env("MBUI_GLASS_FROST"),
    window_zoom: "",
    haptics: "",
    app_update: "",
    send_key: "",
    test_channel: !fixture_stable_mode(mode),
    experimental: fixture_experimental(mode),
    archived: {},
    hidden: {},
    muted: {},
    filters: {},
    fonts: if mode == "settings-fonts-coming" { { "ui": "noto-sans-sc" } } else { {} },
    fonts_fetched: {},
    keys: {},
    version: 1,
    older: 0,
    step: 0,
    chat_tabs: fixture_chat_tabs(mode),
    tabs_shown: fixture_tabs_shown(mode),
    sidebars: {},
    windows: Map::from_array([(fixture_id_key, fixture_ids.next())]),
    cpu_dial: "",
    share_look: if mode.has_prefix("share-card-") && mode != "share-card-dark" && mode != "share-card-motion" {
      // (share-card-<key>-coming, -failed: its files of the looks on their way, not had)
      let look = mode.unsafe_substring(start="share-card-".length(), end=mode.length())
      if look.has_suffix("-coming") || look.has_suffix("-failed") {
        look.unsafe_substring(start=0, end=look.length() - "-coming".length())
      } else {
        look
      }
    } else {
      ""
    },
  }
}

///|
/// A source of made-up chats (see the top of this file for `mode`).
pub fn fixture(mode : String) -> Source {
  fixture_answers.clear()
  paged_days.val = None
  board_started_rows.clear()
  // the board shown and its drafts, as the prefs keep them (but board-list: the same chats as Home's list)
  board_prefs_seed(mode)
  paged_rows.clear()
  fixture_preview(mode)
  if mode == "newchat-preset-many" {
    new_fix.presets.clear()
    new_fix.presets.push_iter(fix_preset_many().iter())
    new_fix.preset = "p-arch"
  }
  if mode == "newchat-station-many" {
    new_fix.station_many = true
  }
  let f = made_fixture(mode)
  if f.mode == "drive-motion" {
    // the folder changing on its own: a note made at 2 s, 发布清单.md taken out at 3.6 s (rows_view's rows coming and
    // going where they are)
    fix_later(2000.0, fn() {
      let a = fix_folder(fix_docs, "")
      a.insert(4, fix_entry("新建的笔记.md", false, 1200, "刚刚"))
      @settings.fixture_changed()
    })
    fix_later(3600.0, fn() {
      let a = fix_folder(fix_docs, "")
      match a.search_by(fn(e) { text(Some(e), "name") == "发布清单.md" }) {
        Some(i) => a.remove(i) |> ignore
        None => ()
      }
      @settings.fixture_changed()
    })
  }
  if f.mode == "settings-workspace-motion" || f.mode == "settings-stations-motion" || f.mode == "settings-connects-motion" || f.mode == "settings-vault-motion" {
    // the workspace changing on its own: a person and a station come at 2 s, one of each goes at 3.6 s
    fix_later(2000.0, fn() { @settings.fixture_motion(1) })
    fix_later(3600.0, fn() { @settings.fixture_motion(2) })
  }
  if f.mode == "share-card-motion" {
    // the card's figures changing on their own, a step every 1.6 s from 2 s (fixture_fleet)
    for k in 1..=3 {
      fix_later(2000.0 + (k - 1).to_double() * 1600.0, fn() { f.step = k })
    }
  }
  if f.mode == "home-motion" {
    // the list changing on its own, a step every 1.6 s from MBUI_MOTION_AT ms (2000) after it starts: rows moving,
    // coming, going, for the recordings of the Home rows' motion
    let at = {
      let w = @ui.env("MBUI_MOTION_AT")
      let mut v = 0
      for ch in w {
        let d = ch.to_int() - 48
        if d >= 0 && d <= 9 {
          v = v * 10 + d
        }
      }
      if w == "" {
        2000.0
      } else {
        v.to_double()
      }
    }
    for k in 1..=4 {
      fix_later(at + (k - 1).to_double() * 1600.0, fn() { f.step = k })
    }
  }
  // the phone's word on 共享调试 said already (the app's Android: AdbShare.java), as a chat's card of it goes by: all it
  // takes, the card lending from where it is
  if f.mode == "chat-screens" || f.mode == "chat-screens-cold" {
    @settings.adb_phone_said(
      "{\"supported\":true,\"developer\":true,\"wireless\":true,\"wifi\":true,\"canSwitch\":false}",
    )
  }
  // (chat-phone-linked-…: a phone with all it takes, its approved request's card under it saying what its station waits
  // on; -desk: a computer, no adb of its own. chat-phone-step-<what>: approved, on a phone that lacks <what> first:
  // developer (Developer options), wifi, wireless (Wireless debugging the app may not turn on), refused (the same, the
  // phone having refused the app's grant))
  if f.mode.has_prefix("chat-phone-linked-") && !f.mode.has_suffix("-desk") {
    @settings.adb_phone_said(
      "{\"supported\":true,\"developer\":true,\"wireless\":true,\"wifi\":true,\"canSwitch\":false}",
    )
  }
  if f.mode.has_prefix("chat-phone-step-") {
    let what = f.mode.unsafe_substring(start="chat-phone-step-".length(), end=f.mode.length())
    @settings.adb_phone_said(
      Json::object({
        "supported": Json::boolean(true),
        "developer": Json::boolean(what != "developer"),
        "wireless": Json::boolean(what != "wireless" && what != "refused"),
        "wifi": Json::boolean(what != "wifi"),
        "canSwitch": Json::boolean(false),
        "switchRefused": Json::boolean(what == "refused"),
      }).stringify(),
    )
  }
  // (chat-phone-lacks: a phone without Developer options yet, its request's card saying so)
  if f.mode == "chat-phone-lacks" {
    @settings.adb_phone_said(
      "{\"supported\":true,\"developer\":false,\"wireless\":false,\"wifi\":true,\"canSwitch\":false}",
    )
  }
  let images = @sfbase.ChatImages::new()
  let read_bytes = fn(name : String, params : Json, done : (Result[(Json, Bytes), Json]) -> Unit) {
    match fixture_kept(name, params, None) {
      Some(r) => {
        done(r.map(fn(a) { (a.0, a.1.unwrap_or(Bytes::make(0, b'\x00'))) }))
        return
      }
      None => ()
    }
    // a file of the share card's looks held where a test holds them (fixture_looks_held)
    if name == "fonts.share" && fixture_looks_held.val is Some(held) {
      held.push((text(Some(params), "file"), done))
      return
    }
    // (share-card-<key>-coming: never answered; -failed: not had)
    if name == "fonts.share" && f.mode.has_prefix("share-card-") && f.mode.has_suffix("-coming") {
      return
    }
    if name == "fonts.share" && f.mode.has_prefix("share-card-") && f.mode.has_suffix("-failed") {
      done(Err({ "code": "fonts", "message": "下载返回 404" }))
      return
    }
    // the faces' files (fonts_fixture.mbt)
    match fixture_fonts_read(f, name, params~) {
      Some(r) => {
        done(r)
        return
      }
      None => ()
    }
    // a download's, as the made-up core keeps it (downloads_fixture.mbt)
    if name == "download.read" && fixture_download_read(params, done) {
      return
    }
    // a chat's made-up files (the preview's), and those its messages name by their paths; else the made-up drive's
    if name.has_prefix("station.file") || name == "file.open" {
      fixture_fetch(name, params, done)
      return
    }
    // the player's made-up films (play_fixture.mbt)
    if name == "drive.read" && fixture_play_read(params, done) {
      return
    }
    // a link's card's pictures, a picture file's peek's (fixture_peek_picture)
    match fixture_peek_picture(name, params) {
      Some(r) => {
        done(r)
        return
      }
      None => ()
    }
    match fixture_drive_read(name, params) {
      Some(r) => done(r)
      None => done(Err({ "code": "unknown_call", "message": "这份假数据没有 " + name }))
    }
  }
  {
    topic_read: fn(name, params) { fixture_topic(f, name, params) },
    topic_key: @sfbase.exact_topic_key,
    topic_keyed: fn(_, _, _, _) { None },
    topic_scope: None,
    topic_alive: fn() { true },
    topic_lease_own: None,
    call: fn(name, params, done) {
      // (answered at once, as a core's answer comes from outside: what it changes of what is no signal taken so; but one
      // whose answer changes only signals, as the core's is taken as it comes, sfbase's calls_said. One asked as a read
      // works its value out (the client's chats.window before a chat's topic) once that read is over, as a core's
      // message is heard between what the app runs: @ui.answered_from_outside)
      let done = fn(r) { @ui.answered_from_outside(fn() { done(r) }, told=!@sfbase.call_said(name)) }
      // a chats' list's window: kept as the core keeps it, growing only, the list given by it as the core's comes, from
      // outside, not in the middle of what asked it (fix_later)
      if name == "chats.window" {
        match params {
          Object(p) => {
            let key = fixture_window_key(p)
            let rows = match p.get("rows") {
              Some(Number(n, ..)) => n.to_int()
              _ => 0
            }
            fix_later(0.0, fn() {
              if rows > f.windows.get(key).unwrap_or(0) {
                f.windows[key] = rows
                f.changed()
              }
            })
          }
          _ => ()
        }
        done(Ok(Json::null()))
        return
      }
      match fixture_board_call(f, name, params) {
        Some(r) => {
          done(r)
          return
        }
        None => ()
      }
      match fixture_kept(name, params, None) {
        Some(r) => {
          done(r.map(fn(a) { a.0 }))
          return
        }
        None => ()
      }
      // a workspace asked to be made, still.fail cloud wanting an invite code first (landing-code)
      if name == "workspace.create" && f.mode == "landing-code" && text(Some(params), "invite_code") == "" {
        done(Err({ "code": "invite_code_required", "message": "invite code required" }))
        return
      }
      // asked back (a toast's 撤销, the archive's 还原): in the lists again, as well as out of the archive
      if name == "chat.archive" && field(Some(params), "archived") is Some(False) {
        f.archived.remove(text(Some(params), "session").clamped_view(start=2).to_owned())
        f.changed()
      }
      // safe mode's change of this device (verified once, on again as it was): at work a moment, as its station takes it,
      // then done
      if @settings.fixture_lock_doing(name, params) {
        fix_later(1200.0, fn() {
          @settings.fixture_lock_done()
          done(Ok(Json::null()))
        })
        return
      }
      // a code typed on a page that waits: the trusted device asks its person there, who is not through its prompt the
      // first time (the same code typed again lets it in)
      if @settings.fixture_pair_typed(name) {
        fix_later(800.0, fn() {
          @settings.fixture_pair_asking()
          fix_later(2500.0, fn() { done(@settings.fixture_pair_answer()) })
        })
        return
      }
      match @settings.fixture_call(name, params) {
        Some(r) => {
          done(r)
          return
        }
        None => ()
      }
      // the drive browsed (browse_fixture.mbt)
      match fixture_browse_call(f, name, params) {
        Some(r) => {
          done(r)
          return
        }
        None => ()
      }
      // a ```mermaid block's chart, as the core makes it (its code a box's words: what the core's mermaid.ts makes of it
      // is the core's to test) and mermaid as the app gives it the core
      if name == "mermaid.load" {
        done(Ok(Json::object({})))
        return
      }
      if name == "mermaid.chart" {
        let code = text(Some(params), "code").replace_all(old="&", new="&amp;").replace_all(old="<", new="&lt;")
        done(
          Ok({
            "svg": Json::string("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 320 160\"><rect width=\"320\" height=\"160\" fill=\"#ffffff\"/>" +
            "<text x=\"16\" y=\"80\">" + code + "</text></svg>"),
            "width": ToJson::to_json(320.0),
            "height": ToJson::to_json(160.0),
          }),
        )
        return
      }
      if name == "file.peek" {
        match fixture_file_peek(text(Some(params), "path")) {
          Object(_) as found => done(Ok(found))
          _ => done(Err({ "code": "not_found", "message": "找不到文件" }))
        }
        return
      }
      // the faces' files (fonts_fixture.mbt)
      if fixture_fonts_call(f, name, params, done) {
        return
      }
      // a chat's files downloaded (downloads_fixture.mbt)
      match fixture_downloads_call(f, name, params) {
        Some(r) => {
          done(r)
          return
        }
        None => ()
      }
      match name {
        "session.retry" => {
          if f.mode == "chat-turn-failed" || f.mode == "chat-turn-unanswered" {
            f.step += 1
            f.changed()
          } else if f.mode == "chat-turn-failed-repeated" {
            // (its agent at it, then failing again alike a moment later: one more folded into the notice)
            f.step = 1
            f.changed()
            fix_later(fix_failed_again_ms, fn() {
              f.step = 2
              f.changed()
            })
          }
          done(Ok(Json::object({})))
        }
        "session.reassign" => {
          if f.mode == "chat-turn-limit" {
            f.step += 1
            f.changed()
          }
          done(Ok(Json::object({})))
        }
        "session.cancelRetry" => {
          if f.mode == "chat-overload-after" {
            f.step += 1
            f.changed()
          }
          done(Ok(Json::object({})))
        }
        "station.resumeInterrupted" | "station.dismissInterrupted" => {
          if f.mode == "home-restart-interrupted" {
            f.step += 1
            f.changed()
          }
          done(Ok(Json::object({})))
        }
        "chat.archive" => {
          let session = text(Some(params), "session")
          f.archived[session.clamped_view(start=2).to_owned()] = true
          f.changed()
          done(Ok(Json::object({})))
        }
        "chat.hide" => {
          if f.mode == "home-hide" && field(Some(params), "thread") is Some(Number(17.0, ..)) {
            f.hidden["c1"] = flag(Some(params), "hidden")
            f.changed()
          }
          done(Ok(Json::object({})))
        }
        "chat.mute" => {
          if f.mode == "home-hide" && field(Some(params), "thread") is Some(Number(17.0, ..)) {
            f.muted["c1"] = flag(Some(params), "muted")
            f.changed()
          }
          done(Ok(Json::object({})))
        }
        // a visualization's widget kept nothing yet; what it keeps is taken (viz.mbt)
        "widget.state" => done(Ok({ "state": Json::null() }))
        "widget.setState" => done(Ok(Json::object({})))
        // how many of a chat's last messages it opens on, as the core's window (fix_window_of)
        "chat.window" => {
          match (fix_session_of(params), field(Some(params), "rows")) {
            (Some(session), Some(Number(n, ..))) => fix_windows[session] = n.to_int()
            _ => ()
          }
          done(Ok(Json::null()))
        }
        "chat.older" => {
          // a chat its window holds less of than the device does grows the window, as the core's does; one given
          // whole brings a page more of what the device holds (rich_chat's)
          match fix_session_of(params) {
            Some(session) if fix_windowed.get(session) is Some(true) => {
              let rows = match field(Some(params), "rows") {
                Some(Number(n, ..)) => n.to_int()
                _ => fix_window_grows
              }
              fix_windows[session] = fix_windows.get(session).unwrap_or(0) + rows
            }
            _ => f.older += 1
          }
          f.changed()
          done(Ok(Json::object({})))
        }
        // a screen's preview's frame taken (chat-screens): the fixture sends no other
        "screen.ack" => done(Ok(Json::object({})))
        // what a simulator's 日志 and 重启 App read (screen-simulator)
        "screen.logs" => {
          let line = fn(at : String, level : String, words : String) -> Json {
            { "at": "2026-11-02 " + at + ".000000+0800", "level": Json::string(level), "app": "Demo", "text": Json::string(words) }
          }
          let after = if params is Object(o) && o.get("after") is Some(Number(n, ..)) { n } else { 0.0 }
          done(Ok(if after > 0.0 {
            { "next": 3.0, "lines": [] }
          } else {
            {
              "next": 3.0,
              "lines": [
                line("13:23:09", "Default", "Loaded 12 workouts"),
                line("13:23:10", "Debug", "HealthKit authorized: true"),
                line("13:23:11", "Error", "Sync failed: The network connection was lost."),
              ],
            }
          }))
        }
        "screen.apps" =>
          done(Ok({
            "apps": [
              { "id": "fail.still.demo", "name": "Demo", "running": true },
              { "id": "fail.still.other", "name": "Other", "running": false },
            ],
          }))
        "screen.relaunch" => done(Ok(Json::object({})))
        // 远程's new tab of a station's browser (a heading's ＋, place-remote modes): made, and listed by the station
        // from now on (a blank tab: settings' fx_remote_tabs)
        "screen.openBrowser" if f.mode.has_prefix("place-remote") => {
          let p = Some(params)
          @settings.fixture_remote_made_said(text(p, "station"), "browser:" + text(p, "id"))
          done(Ok(Json::object({})))
        }
        "screen.settings" | "screen.setSetting" => done(Ok({ "appearance": "light", "textSize": "large" }))
        "chat.tabs.open"
        | "chat.tabs.close"
        | "chat.tabs.closeOthers"
        | "chat.tabs.closeRight"
        | "chat.tabs.move"
        | "chat.tabs.reopen"
        | "chat.tabs.front"
        | "chat.tabs.clear"
        | "chat.tabs.replace" =>
          done(fixture_tabs_call(f, name, params))
        "decision.show" => done(Ok(Json::null()))
        "keys.set" => {
          let r = fixture_keys_set(f.keys, params)
          f.changed()
          done(Ok(r))
        }
        "board.drafts" => {
          board_drafts_set(params)
          f.changed()
          done(Ok(Json::object({})))
        }
        "prefs.set" => {
          match field(Some(params), "windowZoom") {
            Some(String(z)) => f.window_zoom = z
            Some(Null) => f.window_zoom = ""
            _ => ()
          }
          match field(Some(params), "workspace") {
            Some(String(w)) => f.workspace = w
            _ => ()
          }
          match field(Some(params), "appearance") {
            Some(String(a)) => f.appearance = a
            _ => ()
          }
          match field(Some(params), "shareLook") {
            Some(String(l)) => f.share_look = l
            _ => ()
          }
          match field(Some(params), "cpuDial") {
            Some(String(d)) => f.cpu_dial = d
            Some(Null) => f.cpu_dial = ""
            _ => ()
          }
          match field(Some(params), "motion") {
            Some(String(m)) => f.motion = m
            Some(Null) => f.motion = ""
            _ => ()
          }
          match field(Some(params), "glassFrost") {
            Some(String(g)) => f.glass_frost = g
            Some(Null) => f.glass_frost = ""
            _ => ()
          }
          match field(Some(params), "haptics") {
            Some(String(h)) => f.haptics = h
            Some(Null) => f.haptics = ""
            _ => ()
          }
          match field(Some(params), "appUpdate") {
            Some(String(u)) => f.app_update = u
            Some(Null) => f.app_update = ""
            _ => ()
          }
          match field(Some(params), "sendKey") {
            Some(String(k)) => f.send_key = k
            Some(Null) => f.send_key = ""
            _ => ()
          }
          // (a switch of 实验性功能: true on, null off)
          match field(Some(params), "experimental") {
            Some(Object(m)) =>
              for k, v in m {
                match v {
                  True => f.experimental[k] = true
                  _ => f.experimental.remove(k)
                }
              }
            _ => ()
          }
          match field(Some(params), "listFilter") {
            Some(Object(m)) =>
              for k, v in m {
                match v {
                  String(s) => f.filters[k] = s
                  _ => ()
                }
              }
            _ => ()
          }
          match field(Some(params), "sidebars") {
            Some(Object(m)) =>
              for k, v in m {
                match v {
                  Null => f.sidebars.remove(k)
                  _ => f.sidebars[k] = v
                }
              }
            _ => ()
          }
          match field(Some(params), "remoteTabs") {
            Some(Object(m)) =>
              for k, v in m {
                match v {
                  Null => f_remote_tabs(f).remove(k)
                  _ => f_remote_tabs(f)[k] = v
                }
              }
            _ => ()
          }
          match field(Some(params), "terminalZoom") {
            Some(String(z)) => fixture_terminal_zooms[fixture_id(f)] = z
            Some(Null) => fixture_terminal_zooms.remove(fixture_id(f))
            _ => ()
          }
          // a screen's 画质 and 帧率 (null: 自动)
          for k in ["screenQuality", "screenFps"] {
            match field(Some(params), k) {
              Some(Null) => f_screen_prefs(f).remove(k)
              Some(v) => f_screen_prefs(f)[k] = v
              None => ()
            }
          }
          // the board's (board_fixture.mbt)
          board_prefs_set(params)
          // the drive's ways, the files' page's tabs, its favourites
          fix_browse_prefs_set(params) |> ignore
          fix_fill_prefs_set(params)
          // a place's face (null: back to the app's own)
          match field(Some(params), "fonts") {
            Some(Object(m)) =>
              for k, v in m {
                match v {
                  String(s) => f.fonts[k] = s
                  _ => f.fonts.remove(k)
                }
              }
            _ => ()
          }
          f.changed()
          done(Ok(Json::object({})))
        }
        _ =>
          match fixture_new_call(f, name, params) {
            Some(r) => done(r)
            None if name == "shareIn.open" => done(fixture_share_call(name, params).unwrap())
            None =>
              match fixture_card_call(f, name, params) {
                Some(r) => done(r)
                None =>
              match fixture_chat_call(f, name, params) {
                Some(r) => done(r)
                None if name == "link.parse" =>
                  done(Ok(fixture_link_parse(text(Some(params), "url"))))
                None =>
                  match decide_fixture_call(name) {
                    Some(r) => done(r)
                    None => done(Err({ "code": "unknown_call", "message": "这份假数据没有 " + name }))
                  }
              }
              }
          }
      }
    },
    read_bytes,
    // a chat's made-up files, whole: here at once, nothing said of how far they have got; a picture coming never whole
    // (MBUI_FIXTURE=chat-preview-coming, -coming-part: how much has come said once, preview_coming)
    read_going: fn(name, params, on_value, done) {
      if name == "station.file" && preview_coming.val is Some((held, said)) && text(Some(params), "name") == held {
        match said {
          Some(v) => on_value(v)
          None => ()
        }
        return
      }
      fixture_fetch(name, params, done)
    },
    stream: fn(name, params, _bytes, on_value, done) {
      // a player's part read: as read_bytes answers it, its bytes in one piece
      if name == "station.file.part" || name == "drive.read" {
        read_bytes(name, params, fn(r) {
          match r {
            Ok((v, b)) => {
              on_value({ "loaded": Json::number(b.length().to_double()) }, Some(b))
              done(Ok(v))
            }
            Err(e) => done(Err(e))
          }
        })
        return 0
      }
      // a file's part going up (composer.mbt upload_part): as the station takes it, all of it at once
      if name == "station.upload.part" {
        match fixture_chat_call(f, name, params) {
          Some(r) => done(r)
          None => done(Err({ "code": "unknown_call", "message": "这份假数据没有 " + name }))
        }
        return 0
      }
      fixture_stream(name, params, on_value, done, mode=f.mode)
    },
    cancel: fn(_) {  },
    waits: fn(_, _) { false },
    generation: fn(_, _) { (0, true) },
    call_bytes: fn(name, params, bytes, done) {
      // (a Farview tab's stage: its bar's ← → and address done as a host does them)
      if name == "farview.send" && fixture_farview_said(bytes) {
        done(Ok(Json::null()))
        return
      }
      match fixture_kept(name, params, Some(bytes)) {
        Some(r) => {
          done(r.map(fn(a) { a.0 }))
          return
        }
        None => ()
      }
      if fixture_fonts_call(f, name, params, done) {
        return
      }
      match fixture_chat_call(f, name, params) {
        Some(r) => done(r)
        None => done(Err({ "code": "unknown_call", "message": "这份假数据没有 " + name }))
      }
    },
    sign_in: fn() {  },
    signing_in: fn() { false },
    sign_in_step: fn() { Idle },
    // (board-many's people's faces their own pictures: board_face; none for any other)
    picture: fn(url, _) { board_face(f.mode, url) },
    picture_waits: fn(_) { false },
    fatal: fn() { None },
    // (chat-image-coming: its pictures asked of their station, so much of each heard, never here)
    file: fn(station, key, name) {
      match (if f.mode == "chat-image-coming" { coming_heard(name) } else { None }) {
        Some(far) =>
          images.get(station, @sfbase.file_image_id(station, key, name), "mem:fixture/" + name, fn(heard, _) { heard(far) })
        None => fixture_file(name)
      }
    },
    // a video's still: its first frame as the station makes it (the made-up ones' each a picture of its own)
    poster: fn(_, _, name) { fixture_file(name) },
    // (a made-up draft's pictures are the page's own: compose_fixture.mbt)
    draft_picture: fn(_, _) { "!" },
    images,
    now: fn() { 0.0 },
    leave: fn(_, _, __reason) {
      if __reason is @sfbase.TopicLeave::Owned(__stop) { __stop(); return }
      },
    release: fn(_, _) {  },
    refresh: fn(_, _) {  },
    read_only: false,
    // (a made-up core's lists are set up as each test's page asks for them: asked ahead where a test says so)
    reads_ahead: fn() { false },
    asks_devices: fn() { true },
    asks_outline: fn() { true },
    switches_ahead: fn() { true },
    asks_station_updates: fn() { true },
    asks_station_move: fn() { true },
    asks_station_workspaces: fn() { true },
    asks_terminals: fn() { true },
    asks_agent_rates: fn() { true },
    swr_views: fn() { false },
    gates_opens: fn() { false },
  }
}

///|
/// A newer build of the app offered, `version` (its 更新 in the wide frame's sidebar, the settings' version row, the
/// update dialog with what it brings), as an update source would say it, from the made-up source (fixture_updates)
/// unless one is given: for a made-up run's pictures of it (src/sffix, src/sffilm: MBUI_UPDATE=<version>).
pub fn fixture_update(version : String) -> Unit {
  update.available.set(Some({
    "versionName": Json::string(version),
    "file": Json::string("android/stillfail-beta-\{version}.apk"),
    "size": Json::number(23515867.0),
    "news": ["改进：对话列表滑到底时不再多停一下", "修复：图片预览关闭后偶尔留下一块空白", "新增：设置里可以给 station 起别名"],
  }))
  if update.source is None {
    fixture_updates()
  }
}

///|
/// The newer build offered (fixture_update) as the host says it goes: `phase` (downloading, ready, allow…), how far
/// (`percent`, -1 not known), put in place by itself while the app is away where `away` (Android's).
pub fn fixture_update_goes(version : String, phase : String, percent? : Int = -1, away? : Bool = true) -> Unit {
  let said : Json = {
    "phase": Json::string(phase),
    "percent": Json::number(percent.to_double()),
    "error": Json::string(""),
    "file": Json::string("stillfail-beta-\{version}.apk"),
    "away": Json::boolean(away),
  }
  @ui.update_told_as(said.stringify())
}

///|
/// A made-up source of newer builds, this build's version code 1300 (the changelog's build): asked, it answers the
/// build offered then (fixture_update; none newer where none is), `ms` later (a round trip's; src/sffilm:
/// MBUI_UPDATES_MS=<ms>).
pub fn fixture_updates(ms? : Double = 0.0) -> Unit {
  update_version.val = 1300
  set_update_source(
    Some({
      check: fn(_, _, done) {
        let answer = fn() { done(Ok(update.available.get().unwrap_or(Json::null()))) }
        if ms > 0.0 {
          fix_later(ms, answer)
        } else {
          answer()
        }
      },
      url: fn(file) { file },
    }),
  )
}

///|
/// The core's pure calls (`markdown`, `code.ink`, `reader.*`, `commands.find`) as the real core answered them, kept (src/sfkept: bound
/// by a run without a core); None for any other.
pub fn fixture_kept(name : String, params : Json, bytes : Bytes?) -> Result[(Json, Bytes?), Json]? {
  // (⌘K's words are the core's in its language: the made-up core's is the app's)
  let params = match (name, params) {
    ("commands.find", Object(m)) => {
      let m = m.copy()
      m["lang"] = Json::string(@sf.language())
      Json::object(m)
    }
    _ => params
  }
  match @sf.kept_call.val {
    Some(kept) => kept(name, params, bytes)
    None => None
  }
}

///|
/// The card shared of the agents at work (the core's `fleet` view, views/fleet.ts), as the made-up workspace has it:
/// its one Claude subscription's tokens, Willow's one chat at work; the card to share's (share-card, share-card-…) three
/// kinds of subscription (six Claude accounts' 2.5 亿 tokens, two ChatGPT's, two OpenCode Go's: 3.1 亿 in all, as the
/// week's input tokens say), nine chats at work on three stations, and their week. share-card-motion's changes on its
/// own, a step at a time (Fixture's `step`): the first model's tokens and what they cost, and the week's (1); a chat
/// archived today, one fewer at work (2); a model of ChatGPT's come (3).
pub fn fixture_fleet(f : Fixture) -> Json {
  if !f.mode.has_prefix("share-card") {
    return {
      "at": "10月26日 04:12",
      "spent": [
        {
          "kind": "claude",
          "name": "Claude 订阅",
          "accounts": 1,
          "accountsText": "1 个账号",
          "tokens": 42000000,
          "share": 1.0,
          "lead": "用 1 个 Claude 订阅账号消耗了",
          "models": [
            { "name": "Opus 5.5", "tokens": 42000000, "tokensText": "4200 万", "costText": "$96.40", "lineText": "4200 万 · $96.40", "of": "token，折合 $96.40" },
          ],
        },
      ],
      "chats": 1,
      "chatsText": "1 个对话正在运行",
      "where": "今天用了 1 台设备",
      "devices": 1,
    }
  }
  // (how far the card's figures have changed, share-card-motion's)
  let step = if f.mode == "share-card-motion" { f.step } else { 0 }
  let (opus, opus_cost, week_tokens, week_cost, today_cost) = if step >= 1 {
    ("2.3 亿", "$1,556", "3.3 亿", "$2,047", "$498")
  } else {
    ("2.1 亿", "$1,420", "3.1 亿", "$1,911", "$362")
  }
  // each day's chats archived (57 in all, 12 today; 58 and 13 once one more is), as a share of the most on a day
  let counts = [5, 7, 4, 10, 8, 11, if step >= 2 { 13 } else { 12 }]
  let most = counts[6].to_double()
  let shares = counts.map(fn(n) { n.to_double() / most })
  let gpt : Array[Json] = [
    { "name": "GPT-5.5 Codex", "tokens": 47000000, "tokensText": "4700 万", "costText": "$262", "lineText": "4700 万 · $262", "of": "token，折合 $262" },
  ]
  if step >= 3 {
    gpt.push({ "name": "GPT-6 Astra", "tokens": 6000000, "tokensText": "600 万", "costText": "$41", "lineText": "600 万 · $41", "of": "token，折合 $41" })
  }
  let labels = ["10/20", "10/21", "10/22", "10/23", "10/24", "10/25", "10/26"]
  {
    "at": "10月26日 04:12",
    "spent": [
      {
        "kind": "claude",
        "name": "Claude 订阅",
        "accounts": 6,
        "accountsText": "6 个账号",
        "tokens": 252000000,
        "share": 0.81,
        "lead": "用 6 个 Claude 订阅账号消耗了",
        "models": [
          {
            "name": "Opus 5.5",
            "tokens": if step >= 1 { 230000000 } else { 210000000 },
            "tokensText": opus,
            "costText": opus_cost,
            "lineText": "\{opus} · \{opus_cost}",
            "of": "token，折合 \{opus_cost}",
          },
          { "name": "Sonnet 5.5", "tokens": 38000000, "tokensText": "3800 万", "costText": "$171", "lineText": "3800 万 · $171", "of": "token，折合 $171" },
          { "name": "Haiku 4.5", "tokens": 4000000, "tokensText": "400 万", "costText": "$13.20", "lineText": "400 万 · $13.20", "of": "token，折合 $13.20" },
        ],
      },
      {
        "kind": "chatgpt",
        "name": "ChatGPT 订阅",
        "accounts": 2,
        "accountsText": "2 个账号",
        "tokens": 47000000,
        "share": 0.15,
        "lead": "用 2 个 ChatGPT 订阅账号消耗了",
        "models": Json::array(gpt),
      },
      {
        "kind": "opencode",
        "name": "OpenCode Go 订阅",
        "accounts": 2,
        "accountsText": "2 个账号",
        "tokens": 11000000,
        "share": 0.04,
        "lead": "用 2 个 OpenCode Go 订阅账号消耗了",
        "models": [
          { "name": "Kimi K2", "tokens": 8000000, "tokensText": "800 万", "costText": "$32.40", "lineText": "800 万 · $32.40", "of": "token，折合 $32.40" },
          { "name": "GLM-4.6", "tokens": 3000000, "tokensText": "300 万", "costText": "$12.70", "lineText": "300 万 · $12.70", "of": "token，折合 $12.70" },
        ],
      },
    ],
    "chats": if step >= 2 { 8 } else { 9 },
    "chatsText": if step >= 2 { "8 个对话正在运行" } else { "9 个对话正在运行" },
    "where": "今天用了 3 台设备",
    "devices": 3,
    "tasks": 312,
    "tasksText": "近 7 天 agent 跨设备执行了 312 个任务",
    "tasksPer": "平均每个对话 5.2 个",
    "today": {
      "title": "今天",
      "stats": [
        { "label": "归档的对话", "value": "\{counts[6]} 个" },
        { "label": "折合费用", "value": today_cost },
      ],
    },
    "week": {
      "title": "近 7 天",
      "stats": [
        { "label": "归档的对话", "value": if step >= 2 { "58 个" } else { "57 个" } },
        { "label": "输入 token", "value": week_tokens },
        { "label": "折合费用", "value": week_cost },
      ],
      "days": Json::array(
        shares.mapi(fn(i, x) {
          Json::object({
            "label": Json::string(labels[i]),
            "share": Json::number(x),
            "value": Json::string("\{counts[i]} 个"),
            "today": Json::boolean(i == 6),
          })
        }),
      ),
    },
  }
}

///|
/// The phone's lendings in the `adbShare` of a chat-phone `mode`: granted on the phone, lent to the chat's station
/// (Willow) and held as the card says (chat_fixture with_cards' fix_phone_link; Wireless debugging off for the steps
/// that lack it); none where it is not lent there (its switch off, Developer options or Wi-Fi missing: `gone`).
fn fixture_phone_lend(mode : String) -> Json {
  let adb = match mode {
    "chat-phone-step-wireless" | "chat-phone-step-refused" => "off"
    "chat-phone-step-code" => "unpaired"
    _ if mode.has_prefix("chat-phone-linked-") && !mode.has_suffix("-desk") && mode != "chat-phone-linked-gone" =>
      mode.unsafe_substring(start="chat-phone-linked-".length(), end=mode.length())
    _ => ""
  }
  if adb == "" {
    return []
  }
  [{ "station": "ws1/st1", "phase": "offered", "adb": adb, "serial": "127.0.0.1:37762", "tunnels": 0 }]
}

///|
/// The stations whole `v` where a mode shows their newer releases waiting (`…station-updates…`): each one's own software
/// a release behind, not updating itself (its page, its part and `stationUpdates` all saying so; one that lists none
/// given one), every one up and a third (Cedar) beside them, the second under way (40%), the third failed; else as
/// they are.
fn fixture_stations_behind(f : Fixture, v : Json?) -> Json? {
  guard f.mode.contains("station-updates") && v is Some(Array(stations)) else { return v }
  let own : Json = {
    "id": "station",
    "name": "Station",
    "installed": true,
    "version": "0.1.4765",
    "shownText": "0.1.4765",
    "updatable": true,
    "checkedAt": 1.0,
  }
  let up = Ref(0)
  // (every one up, and a third, Cedar, made of Maple: several waiting, each as it may stand)
  let all : Array[Json] = stations.map(fn(s) {
    match s {
      Object(m) => {
        let w = m.copy()
        w["online"] = Json::boolean(true)
        w["problems"] = Json::array([])
        Json::object(w)
      }
      _ => s
    }
  })
  match all.get(1) {
    Some(Object(m)) => {
      let w = m.copy()
      w["station"] = Json::string("ws1/st3")
      w["id"] = Json::string("st3")
      w["name"] = Json::string("Cedar")
      all.push(Json::object(w))
    }
    _ => ()
  }
  Some(
    Json::array(
      all.map(fn(s) {
        match (s, field(Some(s), "overview")) {
          (Object(m), Some(Object(ov))) => {
            let state = if flag(Some(s), "online") {
              up.val += 1
              match up.val {
                2 => "updating"
                3 => "failed"
                _ => "idle"
              }
            } else {
              "idle"
            }
            let behind = fn(u : Json) -> Json {
              match u {
                Object(um) => {
                  let o = um.copy()
                  let version = text(Some(u), "version")
                  o["latest"] = Json::string("0.1.4800")
                  o["newer"] = Json::boolean(version != "0.1.4800")
                  o["auto"] = Json::boolean(false)
                  o["state"] = Json::string(state)
                  o["tipText"] = Json::string("")
                  if state == "updating" {
                    o["percent"] = Json::number(40.0)
                    o["progress"] = Json::string("正在下载 0.1.4800：40%")
                  }
                  if state == "failed" {
                    o["message"] = Json::string("下载中断：网络连接已断开")
                  }
                  Json::object(o)
                }
                _ => u
              }
            }
            let updates = items(Some(Json::object(ov)), "updates")
            let has = updates.iter().any(fn(u) { text(Some(u), "id") == "station" })
            let o = ov.copy()
            let all : Array[Json] = if has { [] } else { [own] }
            all.append(updates)
            o["updates"] = Json::array(all.map(fn(u) { if text(Some(u), "id") == "station" { behind(u) } else { u } }))
            let w = m.copy()
            w["overview"] = Json::object(o)
            Json::object(w)
          }
          _ => s
        }
      }),
    ),
  )
}

///|
/// The stations' newer releases waiting for this person (the core's `stationUpdates`, views/station-updates.ts), of the
/// stations whole the made-up cores describe (`wholes`): only where a mode shows them (`…station-updates…`: the
/// sidebar's and Home's key of them, their dialog), each up whose own software is newer and does not update itself; none
/// elsewhere, so no other screen shows their key.
fn fixture_station_updates(f : Fixture, wholes : Json?) -> Json {
  let listed : Array[Json] = []
  if f.mode.contains("station-updates") {
    let stations = match wholes {
      Some(Array(a)) => a
      _ => []
    }
    for s in stations {
      let own = items(field(Some(s), "overview"), "updates").iter().find_first(fn(u) { text(Some(u), "id") == "station" })
      guard flag(Some(s), "online") && own is Some(u) else { continue }
      guard flag(Some(u), "newer") && flag(Some(u), "updatable") && !flag(Some(u), "auto") else { continue }
      let state = match text(Some(u), "state") {
        "updating" => "updating"
        "failed" => "failed"
        _ => "offered"
      }
      let item : Map[String, Json] = {
        "station": Json::string(text(Some(s), "station")),
        "name": Json::string(text(Some(s), "name")),
        "state": Json::string(state),
        "versionText": Json::string(text(Some(u), "version") + " → " + text(Some(u), "latest")),
        "canUpdate": Json::boolean(state != "updating"),
      }
      if state == "updating" {
        item["percent"] = Json::number(40.0)
        item["detail"] = Json::string(text(Some(u), "progress"))
      }
      if state == "failed" {
        item["detail"] = Json::string(text(Some(u), "message"))
      }
      if f.mode == "station-updates-stale" && state == "offered" && listed.is_empty() {
        item["stale"] = Json::boolean(true)
        item["detail"] = Json::string("版本已超过 7 天，请尽快升级")
      }
      listed.push(Json::object(item))
    }
  }
  let n = listed.filter(fn(i) { text(Some(i), "state") != "updating" }).length()
  let any_stale = listed.iter().any(fn(i) { text(Some(i), "state") != "updating" && flag(Some(i), "stale") })
  {
    "items": Json::array(listed),
    "offered": Json::number(n.to_double()),
    "labelText": Json::string(
      if n > 0 {
        if any_stale { "\{n} 台 station 需要更新" } else { "\{n} 台 station 有新版本" }
      } else {
        ""
      },
    ),
    "titleText": "Station 更新",
  }
}

///|
/// How long after 重试 is pressed on chat-turn-failed-repeated its agent fails again alike, one more folded.
pub let fix_failed_again_ms : Double = 1500.0

///|
/// The rail as the core says it (`railView`) with no bell in it (home-foot): 待处理 left out of every workspace's.
fn rail_unbelled(v : Json) -> Json {
  let out = fn(rail : Json?) -> Json {
    match rail {
      Some(Object(r)) => {
        let o = r.copy()
        match r.get("items") {
          Some(Array(xs)) => o["items"] = Json::array(xs.filter(fn(x) { x != Json::string("attention") }))
          _ => ()
        }
        Json::object(o)
      }
      Some(x) => x
      None => Json::null()
    }
  }
  match v {
    Object(m) => {
      let o = m.copy()
      o["all"] = out(m.get("all"))
      match m.get("by") {
        Some(Object(by)) => {
          let b : Map[String, Json] = Map([])
          for k, r in by {
            b[k] = out(Some(r))
          }
          o["by"] = Json::object(b)
        }
        _ => ()
      }
      Json::object(o)
    }
    _ => v
  }
}
