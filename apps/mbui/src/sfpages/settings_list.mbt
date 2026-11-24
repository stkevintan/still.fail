// The settings' list, one for every frame: the page the gear opens on a small screen (SettingsHome.kt, the web's
// mobile/Settings.tsx), and the sidebar beside the settings' pages on a medium or large one (the web's SettingsNav). One
// list in one order, read once here: who is signed in and the workspace in view; then the workspace's, in small groups
// (who may reach what: security mode and the vault; where its agents run: its stations, connects and profiles; how its
// agents work: what they decide by themselves, what they remember, when chats are archived, what they used); then this
// device's (how it looks, whether it notifies, its bottom bar, its keys, its own station, what it keeps); then 关于.
// Each row has its icon and says how things stand at its end, what is wrong in red, so the list is worth a look before
// anything is opened. Station, 连接, Profile and 用量 are among them wherever the rail has them too: the settings are one
// more way to them, not where they live (the user, 2026-10-15). What a page holds that has a page of its own elsewhere
// (更新日志 in 关于, the system's permission in 通知) is not a row of its own.

///|
/// What a row of the settings' list is by: one of still.fail's line icons, the account's picture, the workspace's mark
/// (its emoji, its icon).
#derive(Eq)
pub(all) enum SettingsLead {
  Icon(String)
  Person
  Space(String, String)
}

///|
/// A row of the settings' list: the page it opens, its key, what it is by, its name, the line under it (the account's
/// and the workspace's), how things stand at its end (`bad` in red; `dot`, a red dot before it: something there is not
/// right, nothing wrong to say); `words`, what else it is found by (other names people call it, in both languages),
/// read by the search alone, never shown.
#derive(Eq)
pub(all) struct SettingsRow {
  route : @settings.Route
  key : String
  lead : SettingsLead
  title : String
  line : String
  value : String
  bad : Bool
  dot : Bool
  words : String
}

///|
/// A group of the list's rows, a heading over it where it has one; `key`, which group it is, whatever rows it has now
/// and whatever language its heading is in.
#derive(Eq)
pub(all) struct SettingsPart {
  key : String
  heading : String
  rows : Array[SettingsRow]
}

///|
fn settings_row(
  route : @settings.Route,
  key : String,
  icon : String,
  title : String,
  value? : String = "",
  bad? : Bool = false,
  dot? : Bool = false,
  words? : String = "",
) -> SettingsRow {
  { route, key, lead: Icon(icon), title, line: "", value, bad, dot, words }
}

///|
/// The settings' list as it stands, in its order, as the core says it: the topics its rows read are those the pages
/// they open read. `bars`: whether the window has the bottom bar; `kept`: what 本机缓存's row says (@settings.kept_said,
/// or kept_told: as last read, nothing asked of the core for it, what reads it asking: kept_ask).
fn settings_parts_of(core : Core, here : @settings.Here, bars~ : Bool, kept~ : String) -> Array[SettingsPart] {
  let w = @settings.workspace_view(core, here).value
  let stations = match @settings.stations_of(core, here).value {
    Some(Array(a)) => Some(a)
    _ => None
  }
  let connects = (core.topic)("connects", { "scope": Json::string(here.workspace), "mine": Json::boolean(false) }).get().value
  let lock = (core.topic)("lock", { "workspace": Json::string(here.workspace) }).get().value
  let vaults = (core.topic)("vaults", { "workspace": Json::string(here.workspace) }).get().value
  let profiles = (core.topic)("profiles", { "scope": Json::string(here.workspace) }).get().value
  let parts : Array[SettingsPart] = []
  // who is signed in, the workspace in view
  let me = if here.person != "" { here.person } else { here.email }
  let role = text(w, "role")
  let members = items(w, "members").length()
  let waiting = items(w, "added").length() + items(w, "invitations").length()
  let people = if (role == "owner" || role == "admin") && waiting > 0 {
    @sf.t("android-settings.members.waiting", args=[("n", members.to_string()), ("waiting", waiting.to_string())])
  } else {
    @sf.t("android-settings.members.count", args=[("n", members.to_string())])
  }
  parts.push({
    key: "who",
    heading: "",
    rows: [
      {
        route: Me,
        key: "me",
        lead: Person,
        title: me,
        line: here.email,
        value: "",
        bad: false,
        dot: false,
        words: @sf.t("android-settings.me.title") + " 个人资料 头像 邮箱 account profile avatar email",
      },
      {
        route: Workspace,
        key: "workspace",
        lead: Space(text(w, "emoji"), text(w, "icon")),
        title: if w is Some(_) { text(w, "name") } else { here.name },
        // (its line held before the workspace is read, a space: the row as tall as it will be, nothing under it moved
        // when it is said; its tile no taller than its words then, the ladder's inset over and under it)
        line: if w is Some(_) { @settings.role_label(role) + " · " + people } else { "\u{00A0}" },
        value: "",
        bad: false,
        dot: false,
        words: @sf.t("android-settings.workspace.title") + " 工作区 团队 组织 workspace team organization",
      },
    ],
  })
  // who may reach what: security mode where the workspace has it (still.fail's always; taken out only where the core
  // says there is none, so the rows under it never move up a row while looked at), and the vault
  let access : Array[SettingsRow] = []
  if lock is None || flag(lock, "available") {
    let attention = count(lock, "attention")
    let said = if lock is None {
      ""
    } else if !flag(lock, "locked") {
      @sf.t("web-mobile.settings.securityOff")
    } else if attention > 0 {
      @sf.t("web-mobile.settings.securityWaiting", args=[("n", attention.to_string())])
    } else {
      @sf.t("web-mobile.settings.securityOn")
    }
    access.push(settings_row(Security, "security", "shield-check", @sf.t("web-pages.security.title"), value=said, bad=attention > 0, words=settings_words_security))
  }
  access.push(
    settings_row(Vault, "vault", "key", @sf.t("android-settings.vault.title"), value=text(vaults, "statusText"), bad=flag(vaults, "statusBad"), words=settings_words_vault),
  )
  parts.push({ key: "access", heading: "", rows: access })
  // where its agents run: its stations, the chats' ways in, the agents' accounts (as many as their list has, those
  // that need a look as the core counts them)
  let online = match stations {
    Some(a) => a.filter(fn(x) { flag(Some(x), "online") }).length()
    None => 0
  }
  let short = count(profiles, "attention")
  let mut failing = 0
  for x in items(connects, "items") {
    if text(field(Some(x), "connect"), "presence") == "error" {
      failing += 1
    }
  }
  parts.push({
    key: "run",
    heading: "",
    rows: [
      settings_row(
        Stations,
        "stations",
        "server",
        "Station",
        value=match stations {
          Some(a) => @sf.t("android-settings.home.online", args=[("online", online.to_string()), ("total", a.length().to_string())])
          None => ""
        },
        dot=match stations {
          Some(a) => online < a.length()
          None => false
        },
        words=settings_words_stations,
      ),
      settings_row(
        Connects(""),
        "connects",
        "plug",
        @sf.t("android-settings.connects.title"),
        value=if connects is None {
          ""
        } else if failing > 0 {
          @sf.t("android-settings.home.failing", args=[("n", failing.to_string())])
        } else {
          @sf.t("android-settings.count", args=[("n", items(connects, "items").length().to_string())])
        },
        bad=failing > 0,
        words=settings_words_connects,
      ),
      settings_row(
        Profiles(""),
        "profiles",
        "quota",
        "Profile",
        value=if profiles is None {
          ""
        } else if short > 0 {
          @sf.t("android-settings.home.short", args=[("n", short.to_string())])
        } else {
          @sf.t("android-settings.count", args=[("n", items(profiles, "items").length().to_string())])
        },
        bad=short > 0,
        words=settings_words_profiles,
      ),
    ],
  })
  // how its agents work
  parts.push({
    key: "work",
    heading: "",
    rows: [
      settings_row(AutoDecisions, "decisions", "check", @sf.t("web-pages.automaticDecisions.title"), words=settings_words_decisions),
      settings_row(Memories, "memory", "brain", @sf.t("android-settings.memory"), words=settings_words_memory),
      settings_row(Archiving, "archiving", "archive", @sf.t("web-pages.archiving.title"), words=settings_words_archiving),
      settings_row(Backup, "backup", "disk", @sf.t("web-pages.backup.title"), words=settings_words_backup),
      settings_row(Usage, "usage", "chart", @sf.t("android-settings.home.usage"), words=settings_words_usage),
    ],
  })
  // this device's: what there is of it here (the bottom bar where the window has one, 2026-10-26: 「为啥中型屏会有这个
  // 设置」; the keys, this computer's station a computer's)
  let prefs = (core.topic)("prefs", Map([])).get().value
  let theme = match @settings.appearance(prefs) {
    "light" => @sf.t("android-settings.theme.light")
    "dark" => @sf.t("android-settings.theme.dark")
    _ => @sf.t("android-settings.theme.system")
  }
  // notifications as the core's `notify` says, or as switched while `notify.set` is out; refused by the system, in red
  let notify = (core.topic)("notify", Map([])).get().value
  let on = match @settings.notify_switched.get() {
    Some(v) => v
    None => notify is None || flag(notify, "on")
  }
  let refused = text(notify, "permission") == "denied"
  let device : Array[SettingsRow] = [
    settings_row(Appearance, "appearance", "sliders", @sf.t("android-settings.appearance.title"), value=theme, words=settings_words_appearance),
    settings_row(
      Notifications,
      "notifications",
      "bell",
      @sf.t("web-pages.settings.nav.notifications"),
      value=if refused {
        @sf.t("web-pages.permissions.state.denied")
      } else if on {
        @sf.t("web-pages.notifications.on")
      } else {
        @sf.t("web-pages.notifications.off")
      },
      bad=refused,
      words=settings_words_notifications,
    ),
  ]
  if bars {
    device.push(settings_row(BarSettings, "bars", "view-columns", @sf.t("android-misc.bar.title"), value=@settings.bars_value(core), words=settings_words_bars))
  }
  let platform = @ui.platform()
  if platform == 0 || platform == 3 || platform == 5 {
    device.push(settings_row(Shortcuts, "shortcuts", "keyboard", @sf.t("web-pages.settings.nav.shortcuts"), words=settings_words_shortcuts))
  }
  if @settings.local_station_managed() {
    device.push(settings_row(LocalStation, "local-station", "monitor", @sf.t("web-pages.localStation.title"), words=settings_words_local))
  }
  // 共享调试: on a phone its switch and which chats it is lent to; on every app, which chats were allowed, how long a
  // grant lasts, and the devices that approve it (their own page under 安全 of before, gone: the user, 2026-11-10, to
  // people there is one safe mode). Not the web's: a page signs nothing
  if platform != 4 {
    device.push(settings_row(AdbShare(""), "adb", "phone", @sf.t("android-misc.adb.title"), words=settings_words_adb))
  }
  device.push(settings_row(KeptFiles, "files", "disk", @sf.t("android-settings.files.title"), value=kept, words=settings_words_files))
  let exp = @settings.experimental_items_from(prefs)
  if !exp.is_empty() {
    let exp_on = exp.filter(fn(i) { i.1 }).length()
    device.push(
      settings_row(
        Experimental,
        "experimental",
        "sparks",
        @sf.t("web-pages.experimental.title"),
        value=if exp_on > 0 {
          @sf.t("web-pages.experimental.enabledCount", args=[("n", exp_on.to_string())])
        } else {
          ""
        },
        words=settings_words_experimental,
      ),
    )
  }
  parts.push({ key: "device", heading: @sf.t("android-settings.home.device"), rows: device })
  // 关于: this build, or the newer one there is
  let v = (core.version_now)()
  parts.push({
    key: "about",
    heading: "",
    rows: [
      settings_row(
        About,
        "about",
        "info",
        @sf.t("web-pages.settings.nav.about"),
        value=if v.ready != "" {
          @sf.t("android-settings.version.update", args=[("version", v.ready)])
        } else {
          @settings.build_version()
        },
        words=settings_words_about,
      ),
    ],
  })
  parts
}

///|
/// The row of the list a settings page is under (lit beside it): a page under one of them, that one's.
pub fn settings_row_of(r : @settings.Route) -> @settings.Route {
  match r {
    Fonts => Appearance
    SecurityOpen => Security
    VaultItems | VaultItem(_, _) => Vault
    AdbShare(_) => AdbShare("")
    Station(_) | StationMove(_) => Stations
    Profile(_, _) | NewProfile(_) | ProfileAccount(_) => Profiles("")
    Connects(_) | Connect(_, _) => Connects("")
    Memory(_) | MemoryDoc(_, _, _) => Memories
    AutoCompletion | AutoPolicy(_) => AutoDecisions
    StationArchiving(_) => Archiving
    StationBackup(_) => Backup
    UsagePrices(_) => Usage
    Permissions => Notifications
    Changelog => About
    KeptChat(_, _) => KeptFiles
    r => r
  }
}

///|
/// The search belongs to the settings list as it moves between a page and a sidebar. Its field follows edits and is
/// kept while a result is open, so going back to the list does not lose the search.
let settings_search_field : @ui.Field = @ui.Field::new()

///|
/// The result last opened from the search (a `find/` row's key; `""` a row of the list itself, or none): of the
/// results that open the same page, the one the sidebar lights. Let go as the search's words change.
// kept across runs: said as a result is opened, let go as the words change and as the search is reset
let settings_search_picked : @signals.Signal[String] = @signals.signal("")

///|
/// The result ↑ and ↓ in the sidebar's field have come to (its key, `""` none): what Enter opens, lit meanwhile.
// kept across runs: said by ↑ and ↓, let go as the words change, a result is opened and the search is reset
let settings_search_active : @signals.Signal[String] = @signals.signal("")

///|
pub fn settings_search_reset() -> Unit {
  settings_search_field.set("")
  settings_search_picked.set("")
  settings_search_active.set("")
}

///|
/// Result `r` of the settings' list (one pressed, or Enter's) opened by `open`: which of them it was kept
/// (settings_search_picked: a `find/` row's key, a row of the list's none), so the sidebar lights it alone.
pub fn settings_search_chose(r : SettingsRow, open : (@settings.Route) -> Unit) -> Unit {
  settings_search_picked.set(if r.key.has_prefix("find/") { r.key } else { "" })
  settings_search_active.set("")
  open(r.route)
}

///|
/// The search's words as they are typed apart (any run of spaces, the full-width space and tabs between them), lower
/// case, none empty.
fn settings_search_words(query : String) -> Array[String] {
  let out : Array[String] = []
  for w in query.to_lower().split(" ") {
    for w in w.split("\u{3000}") {
      for w in w.split("\t") {
        let w = w.trim(chars="\n\r").to_owned()
        if w != "" {
          out.push(w)
        }
      }
    }
  }
  out
}

///|
// kept across runs: a value (no field of it changes)
let settings_search_page : @ui.Style = @ui.css("w=Full pb=S3 clip=true")

///|
/// The field in a sidebar's band (settings_search_node's): the band's own room round it.
// kept across runs: a value (no field of it changes)
let settings_search_side : @ui.Style = @ui.css("w=Full")

///|
/// The same search control (settings_search's) as nodes, over the settings' list made once: the library's field to look
/// through a list by (@sf.search_input_node); 12 under it. Its field an editor of its own (a Field is one editor's: the list made once while
/// another of it still leaves, the sidebar's old one), what it holds the list's words (settings_search_field: kept as a
/// result is opened, the sidebar's the same), each told the other's as they change. Its words as far in as where its
/// list stands (`at`) has them (band_pad_in); on a page (`page`), 12 under it, as its blocks are apart.
/// `results`: what its words find now, in the list's order (read as a key is pressed, never as it is made); with them
/// Enter opens by `choose` the one ↑ and ↓ came to, else the first, and Escape empties the field while it holds
/// words. `steps`: ↑ and ↓ go along the results while it holds words and finds some (where the list lights the one they
/// are at: the sidebar's); with no words they are left to what they were.
pub fn settings_search_node(
  parent : @view.View,
  at? : @sf.ListAt = Whole,
  page? : Bool = true,
  results? : () -> Array[SettingsRow],
  choose? : (SettingsRow) -> Unit,
  steps? : Bool = false,
) -> Unit {
  let own = @ui.Field::new(text=@signals.untracked(fn() { settings_search_field.text() }))
  let on_page = page
  // (what the words find, as a key is pressed: none while it holds no words)
  let found = fn() -> Array[SettingsRow] {
    match results {
      Some(f) if settings_search_words(own.text()).length() > 0 => @signals.untracked(f)
      _ => []
    }
  }
  let target = fn() -> SettingsRow? {
    let all = found()
    let active = settings_search_active.untracked()
    for r in all {
      if active != "" && r.key == active {
        return Some(r)
      }
    }
    all.get(0)
  }
  // (↑ ↓: the one before or after the one they are at, the first or the last to begin with, held at the ends)
  let step = fn(by : Int) -> Bool {
    let all = found()
    if all.is_empty() {
      return false
    }
    let active = settings_search_active.untracked()
    let mut at_now = -1
    for i, r in all {
      if r.key == active {
        at_now = i
      }
    }
    let next = if at_now < 0 {
      if by > 0 { 0 } else { all.length() - 1 }
    } else {
      let n = at_now + by
      if n < 0 { 0 } else if n >= all.length() { all.length() - 1 } else { n }
    }
    settings_search_active.set(all[next].key)
    true
  }
  parent.box(fn(page) {
    @sf.style_node(page, fn() { if on_page { settings_search_page } else { settings_search_side } })
    page.reacts(fn() { own.text() }, fn(w) { settings_search_field.set(w) })
    page.reacts(fn() { settings_search_field.text() }, fn(w) {
      if @signals.untracked(fn() { own.text() }) != w {
        own.set(w)
      }
    })
    let submitted = match choose {
      Some(open) =>
        Some(fn(_w : String) {
          match target() {
            Some(r) => open(r)
            None => ()
          }
        })
      None => None
    }
    @sf.search_input_node(
      page,
      own,
      fn() { @sf.t("web-pages.settings.search") },
      at~,
      edited=fn(_) {
        settings_search_picked.set("")
        settings_search_active.set("")
      },
      submitted?,
      // (↑ ↓ along the results, taken only while there is a result to go to)
      step?=if steps { Some(step) } else { None },
      step_can=fn() { !found().is_empty() },
      escape=fn() {
        if own.text() == "" {
          false
        } else {
          own.set("")
          settings_search_reset()
          true
        }
      },
      cleared=fn() {
        settings_search_picked.set("")
        settings_search_active.set("")
      },
    )
    |> ignore
  })
  |> ignore
}

///|
/// The settings found by name under a row of the list (its children): what each is called, the page that holds it, and
/// what else it is found by. Only the children of rows offered now (a page this device has, a state the core says).
fn settings_children_of(
  row : SettingsRow,
  core : Core,
  here : @settings.Here,
  wide : Bool,
) -> Array[(String, String, @settings.Route, String)] {
  match row.key {
    "me" =>
      [
        ("devices", @sf.t("web-pages.settings.account.sessions"), Me, "登录设备 会话 session device"),
        ("sign-out", @sf.t("android-settings.me.signOutOnly"), Me, "登出 切换账号 logout sign out"),
        ("delete-account", @sf.t("android-settings.me.delete"), Me, "删除账号 销户 delete account"),
      ]
    "workspace" =>
      [
        ("name", @sf.t("android-settings.workspace.name"), Workspace, "工作区名称 重命名 图标 emoji rename icon"),
        ("members", @sf.t("android-settings.members.title"), Workspace, "成员 邀请 角色 添加成员 移除 member invite role owner admin"),
        ("relays", @sf.t("android-settings.ways.title"), Workspace, "中继 转发 网络 节点 relay iroh mesh"),
      ]
    "security" => {
      let lock = (core.topic)("lock", { "workspace": Json::string(here.workspace) }).get().value
      if flag(lock, "locked") {
        [
          ("my-devices", @sf.t("web-pages.security.myDevices"), Security, "受信任设备 我的设备 本机 续期 移除 trusted my device"),
          ("other-members", @sf.t("web-pages.security.otherMembers"), Security, "其他成员 成员设备 member device"),
          ("turn-off", @sf.t("web-pages.security.turnOff"), Security, "关闭安全模式 停用 turn off disable"),
        ]
      } else {
        [
          ("turn-on", @sf.t("web-pages.security.turnOn"), SecurityOpen, "开启安全模式 启用 turn on enable"),
          ("signing", @sf.t("web-pages.security.signing"), Security, "受信任设备 签名设备 trusted signing device"),
        ]
      }
    }
    "vault" =>
      [
        ("all", @sf.t("web-pages.vault.all"), VaultItems, "全部密钥 密钥列表 查看 添加密钥 Slack all secrets items"),
        ("timeout", @sf.t("android-settings.vault.lasts.title"), Vault, "授权时限 默认最长授权 有效期 自动锁 approval timeout duration"),
      ]
    "stations" => {
      // (the workspace's stations by name, each straight to its page)
      let a : Array[(String, String, @settings.Route, String)] = []
      match @settings.stations_of(core, here).value {
        Some(Array(list)) =>
          for st in list {
            let address = text(Some(st), "station")
            let name = text(Some(st), "name")
            if address != "" && name != "" {
              a.push(("st/" + address, name, Station(address), "station 服务器 机器 " + address))
            }
          }
        _ => ()
      }
      a.append([
        ("devices", @sf.t("web-pages.devices.title"), Stations, "外设 硬件 串口 摄像头 开发板 手机 device usb serial tcp adb"),
        ("agent-env", @sf.t("web-pages.stations.agentEnv"), Stations, "环境变量 Agent env environment variable"),
        ("station-search", @sf.t("web-pages.stations.search.personal"), Stations, "搜索个人数据 Spotlight 邮件 备忘录 personal search"),
        ("software", @sf.t("web-pages.stations.software"), Stations, "软件与更新 版本 回退 更新 channel software version update"),
        ("move", @sf.t("web-pages.stations.move.title"), Stations, "迁移 搬迁 转移 废弃 station move migrate"),
        ("add", @sf.t("web-pages.settings.stations.add"), Stations, "添加 station 新机器 Docker add join"),
      ])
      a
    }
    "connects" => {
      // (the workspace's connects by name, each straight to its page)
      let a : Array[(String, String, @settings.Route, String)] = []
      let connects = (core.topic)("connects", { "scope": Json::string(here.workspace), "mine": Json::boolean(false) }).get().value
      for x in items(connects, "items") {
        let station = text(Some(x), "station")
        let c = field(Some(x), "connect")
        let id = text(c, "id")
        let name = text(c, "name")
        if station != "" && id != "" && name != "" {
          a.push(("cn/" + station + "/" + id, name, Connect(station, id), text(c, "kind") + " 连接 机器人 connect bot"))
        }
      }
      a.push(("add", @sf.t("android-settings.flow.title"), Connects(""), "添加连接 接入 Slack 飞书 Feishu Lark Comma 机器人 add connect bot"))
      a
    }
    "profiles" =>
      [
        ("quota", @sf.t("android-settings.quota.title"), Profiles(""), "额度 配额 用量池 速率 概览 allowance quota pool overview"),
        ("add", @sf.t("android-misc.bar.action.profiles"), Profiles(""), "添加账号 添加 Profile 登录 Claude Codex Gemini OpenAI Anthropic API"),
      ]
    "decisions" =>
      [
        ("completion", @sf.t("web-pages.automaticDecisions.completion"), AutoCompletion, "归档建议 归档策略 完成判断 模型判断 archive policy completion"),
      ]
    "archiving" =>
      [
        ("suggest", @sf.t("web-pages.appearance.archive.title"), Archiving, "提示归档 做完就提示 按模型判断 archive hint suggest"),
        ("automatic", @sf.t("web-pages.archiving.auto.title"), Archiving, "自动归档 空闲天数 Slack 归档 idle days auto archive"),
      ]
    "backup" =>
      [
        ("unified", @sf.t("web-pages.backup.unified.title"), Backup, "统一备份设置 批量应用 自动互备 备份方式 unified backup mode"),
        ("s3", @sf.t("web-pages.stations.copies.s3Heading"), Backup, "R2 S3 Cloudflare 对象存储 加密密钥 恢复密钥 object storage"),
      ]
    "usage" => [("prices", @sf.t("android-misc.usage.prices"), UsagePrices(7), "价目表 模型单价 价格 计费 Token price rate model cost")]
    "appearance" => {
      let a : Array[(String, String, @settings.Route, String)] = [
        ("theme", @sf.t("web-pages.appearance.theme.title"), Appearance, "深色 浅色 跟随系统 暗黑 亮色 夜间 theme dark light system"),
        ("accent", @sf.t("web-pages.appearance.accent.title"), Appearance, "强调色 主题色 颜色 配色 橙 蓝 绿 紫 粉 五彩 随机 accent color hue rainbow multicolor"),
        ("fonts", @sf.t("web-pages.appearance.fonts.title"), Fonts, "正文字体 代码字体 等宽 字号 字体大小 font typeface monospace size"),
        ("glass", @sf.t("web-pages.appearance.glass.title"), Appearance, "液态玻璃 玻璃 磨砂 透明 清晰度 liquid glass frost"),
        ("motion", @sf.t("web-pages.appearance.motion.title"), Appearance, "动效 动画 减弱动态效果 过渡 animation motion reduce"),
        ("haptics", @sf.t("web-pages.appearance.haptics.title"), Appearance, "触感 震动 振动 反馈 haptic vibration"),
        ("language", @sf.t("common.language"), Appearance, "中文 英文 English 多语言 界面语言 language locale zh en"),
      ]
      if @ui.window_zoom_supported() {
        a.push(("zoom", @sf.t("desktop.menu.zoom"), Appearance, "界面缩放 窗口缩放 放大 缩小 比例 zoom scale"))
      }
      if @ui.takes_drops() {
        a.push(("drop", @sf.t("web-pages.appearance.drop.title"), Appearance, "拖拽 拖放 发送文件 引用路径 drag drop file path"))
      }
      // (the rail's own, beside the settings' sidebar alone, not an iPhone Duo's)
      if wide && !@sf.native_on() {
        a.push(("rail", @sf.t("web-main.rail.title"), Appearance, "侧栏 侧边栏 导航条 自定义侧边条 rail sidebar customize"))
      }
      a
    }
    "experimental" =>
      @settings.experimental_items(core).map(fn(e) {
        (
          e.0,
          @sf.t("web-pages.experimental." + e.0 + ".title"),
          Experimental,
          @sf.t("web-pages.experimental." + e.0 + ".description") + " " + e.0,
        )
      })
    "notifications" =>
      [
        ("ways", @sf.t("web-pages.notifications.ways.title"), Notifications, "横幅 声音 角标 图标数字 提醒方式 banner sound badge"),
        ("kinds", @sf.t("web-pages.notifications.kinds.title"), Notifications, "待处理 失败 完成 新消息 后台服务 通知类别 wait failed done message"),
        ("preview", @sf.t("web-pages.notifications.preview"), Notifications, "显示消息内容 预览 隐藏内容 preview content"),
        ("permissions", @sf.t("web-pages.settings.nav.permissions"), Permissions, "系统权限 通知权限 授权 允许 permission system"),
      ]
    "shortcuts" =>
      [
        ("sending", @sf.t("web-main.shortcuts.sending"), Shortcuts, "回车发送 Enter ⌘Enter Ctrl+Enter 换行 发送消息 send message"),
      ]
    "files" =>
      [
        ("fill", @sf.t("android-settings.files.fill.title"), KeptFiles, "后台下载 自动下载 离线文件 background download fill"),
        ("clear", @sf.t("android-settings.files.clearAll"), KeptFiles, "清除缓存 清理空间 删除缓存 clear cache storage"),
      ]
    "about" => {
      let a : Array[(String, String, @settings.Route, String)] = [
        ("version", @sf.t("web-pages.settings.nav.version"), About, "版本号 当前版本 version build"),
      ]
      if (core.version_now)().asks {
        a.push(("auto-update", @sf.t("android-settings.version.auto"), About, "自动更新 自动升级 auto update"))
        a.push(("check-update", @sf.t("android-settings.version.check"), About, "检查更新 检测新版本 升级 check update"))
      }
      a.append([
        ("changelog", @sf.t("web-pages.settings.nav.changelog"), Changelog, "发版说明 更新记录 新功能 修复 release notes changelog"),
        ("terms", @sf.t("common.legal.terms"), About, "用户协议 条款 terms of service"),
        ("privacy", @sf.t("common.legal.privacy"), About, "隐私条款 数据保护 privacy policy"),
      ])
      if (core.reporting)() is Some(_) {
        a.push(("telemetry", @sf.t("common.telemetry.title"), About, "崩溃报告 遥测 统计 匿名数据 telemetry crash report"))
      }
      if @hostapi.perf_state() >= 0 {
        a.push(("perf", @sf.t("web-pages.about.perf.title"), About, "性能日志 诊断日志 打开日志文件夹 卡顿记录 performance log folder"))
      }
      if @ui.platform() != 4 {
        a.push(("dht", @sf.t("web-pages.about.dht.title"), About, "DHT 网络 查找 Station 中继 公司网络 防火墙 network relay lookup firewall"))
      }
      a
    }
    _ => []
  }
}

///|
/// Searchable settings below a list row (settings_children_of's) as rows of the list: each names its parent and opens
/// the page that owns the setting; entries with their own page go there directly.
fn settings_search_children(row : SettingsRow, core : Core, here : @settings.Here, wide : Bool) -> Array[SettingsRow] {
  let lead = match row.lead {
    Person => Icon("user")
    Space(_, _) => Icon("users")
    lead => lead
  }
  settings_children_of(row, core, here, wide).map(fn(e) {
    {
      route: e.2,
      key: "find/" + row.key + "/" + e.0,
      lead,
      title: e.1,
      line: row.title,
      value: row.title,
      bad: false,
      dot: false,
      words: e.3,
    }
  })
}

///|
/// Every word must be present, case independently, in what the row is called and found by, or its line. A child must
/// match one word itself: searching a parent's name alone shows that row, not every setting under it. Its parent may
/// supply the other words.
fn settings_search_matches(row : SettingsRow, words : Array[String], child : Bool) -> Bool {
  let own = (row.title + " " + row.words).to_lower()
  let all = (own + " " + row.line).to_lower()
  let mut own_match = false
  for word in words {
    if !all.contains(word) {
      return false
    }
    if own.contains(word) {
      own_match = true
    }
  }
  !child || own_match
}

///|
/// What the search's words (`query`) find of the list's `parts`, in its order: each row they find, and under it the
/// settings of its they find. A setting on its row's own page, its row found and named whole by the words already,
/// is that row's (searching 通知 shows 通知, not each of its page's sections as well).
fn settings_found(
  parts : Array[SettingsPart],
  core : Core,
  here : @settings.Here,
  query : String,
  wide : Bool,
) -> Array[SettingsPart] {
  if query == "" {
    return parts
  }
  let words = settings_search_words(query)
  if words.is_empty() {
    return parts
  }
  let found : Array[SettingsPart] = []
  for part in parts {
    let rows : Array[SettingsRow] = []
    for row in part.rows {
      let parent_matched = settings_search_matches(row, words, false)
      if parent_matched {
        rows.push(row)
      }
      // (what the row is called: the account's and the workspace's rows by their own names and by what they are)
      let own_names = match row.key {
        "me" => row.title + " " + @sf.t("android-settings.me.title") + " 个人资料 account profile"
        "workspace" => row.title + " " + @sf.t("android-settings.workspace.title") + " 工作区 workspace"
        _ => row.title
      }
      let named = parent_matched && words.iter().all(fn(w) { own_names.to_lower().contains(w) })
      for child in settings_search_children(row, core, here, wide) {
        if named && child.route == row.route {
          continue
        }
        if settings_search_matches(child, words, true) {
          rows.push(child)
        }
      }
    }
    if !rows.is_empty() {
      found.push({ key: part.key, heading: part.heading, rows })
    }
  }
  found
}

///|
/// What else the list's rows are found by (SettingsRow's `words`).
let settings_words_security : String = "安全模式 个人锁 生物识别 指纹 面容 配对 批准 security safe mode lock biometric touch id face id pairing"

///|
let settings_words_vault : String = "密码 凭证 令牌 密钥库 vault secret token api key password credential"

///|
let settings_words_stations : String = "机器 服务器 节点 主机 算力 沙箱 station server host machine node rig sandbox"

///|
let settings_words_connects : String = "Slack 飞书 Feishu Lark Comma 机器人 频道 群 接入 connect bot integration channel"

///|
let settings_words_profiles : String = "模型 账号 额度 配额 订阅 Claude Codex Gemini OpenAI Anthropic API Cursor Devin profile model quota allowance subscription"

///|
let settings_words_decisions : String = "自动审批 自动决定 完结判断 automatic decision completion"

///|
let settings_words_memory : String = "技能 提示词 规则 知识库 memory skill MEMORY.md AGENTS.md prompt"

///|
let settings_words_archiving : String = "自动归档 归档会话 闲置 archive idle"

///|
let settings_words_backup : String = "备份 恢复 互备 r2 s3 对象存储 backup restore"

///|
let settings_words_usage : String = "费用 开销 花费 账单 统计 Token 成本 usage cost spend billing token"

///|
let settings_words_appearance : String = "深色 浅色 暗色 亮色 夜间 界面 样式 动效 玻璃 appearance dark light mode look ui style"

///|
let settings_words_notifications : String = "消息提醒 推送 横幅 角标 声音 勿扰 notification push banner badge sound alert"

///|
let settings_words_bars : String = "底栏 底部栏 导航栏 标签栏 bottom bar tab bar nav"

///|
let settings_words_shortcuts : String = "热键 按键 键盘 绑定 发送 回车 keymap hotkey keyboard shortcut keybinding"

///|
let settings_words_local : String = "本地 本机 服务 开机自启 守护进程 安装 卸载 local station daemon service install"

///|
let settings_words_adb : String = "手机 安卓 真机 无线调试 USB ADB Android phone wireless debug"

///|
let settings_words_files : String = "缓存 存储 空间 清理 磁盘 下载 文件 cache storage disk space clean clear download"

///|
let settings_words_experimental : String = "实验 预览 测试开关 Beta Labs experimental preview feature flag"

///|
let settings_words_about : String = "版本 更新 升级 日志 隐私 条款 诊断 about version update upgrade changelog privacy terms log"

///|
/// The list as a sidebar's (beside the settings' pages on a medium or large screen) made once as nodes in `v`: the same
/// rows in the same groups, a sidebar's rows (the theme's side_row, as its other rows of one line), the room of a
/// heading between two groups with none; what it finds as the search's words say now (settings_search_field), each as
/// the core says it. `lit()`: the row of the page beside it, as that changes. `open`: a row pressed, its page. `at`:
/// where the list stands (a side column, the tape's). `here`: who and where, as that changes. One row lit at most:
/// while the search finds, the one ↑ and ↓ came to, else the result opened, else the row of the page beside it, else
/// the one result alone that opens that page. What it finds now, its rows in its order, given back (for the
/// search's keys: read as they are pressed).
pub fn settings_side_rows_node(
  v : @view.View,
  core : Core,
  here : () -> @settings.Here,
  lit : () -> @settings.Route?,
  open : (@settings.Route) -> Unit,
  at : @sf.ListAt,
) -> () -> Array[SettingsRow] {
  let query = fn() { settings_search_field.text().trim(chars=" \t\n\r\u{3000}").to_owned().to_lower() }
  // (no bottom bar beside a sidebar: a medium or large screen's, except an iPhone Duo's, where the system's tab
  // bar is the bar; what is kept asked of the core as it is asked to be read again, as the page's list asks it)
  let parts = @signals.computed(fn(_) {
    settings_found(settings_parts_of(core, here(), bars=@sf.native_on(), kept=@settings.kept_told()), core, here(), query(), true)
  })
  let searching = fn() { query() != "" }
  // (while the search finds: the one row lit, by its key (settings_side_rows_node's order of them); none at all with
  // no words, each row then lit by the page beside it as ever)
  let chosen = @signals.computed(fn(_) -> String {
    let found = parts.get()
    let now = lit()
    let active = settings_search_active.get()
    if active != "" {
      return active
    }
    let picked = settings_search_picked.get()
    if picked != "" {
      for p in found {
        for r in p.rows {
          if r.key == picked && Some(r.route) == now {
            return picked
          }
        }
      }
    }
    let under = now.map(settings_row_of)
    let mut only = ""
    let mut alike = 0
    for p in found {
      for r in p.rows {
        if !r.key.has_prefix("find/") {
          if under == Some(r.route) {
            return r.key
          }
        } else if Some(r.route) == now {
          only = r.key
          alike += 1
        }
      }
    }
    if alike == 1 {
      only
    } else {
      ""
    }
  })
  let lights = fn(r : SettingsRow) {
    if searching() {
      chosen.get() == r.key
    } else {
      lit().map(settings_row_of) == Some(r.route)
    }
  }
  v.reacts(fn() { @settings.kept_asked() }, fn(_) { @settings.kept_ask(core) })
  // (its lines in their order: a heading over a group, the room between two groups with none, the rows; none found)
  let lines = fn() -> Array[String] {
    let out = []
    let found = parts.get()
    if found.is_empty() && query() != "" {
      out.push("empty")
    }
    for k, part in found {
      if part.heading != "" {
        out.push("head/" + part.key)
      } else if k > 0 {
        out.push("apart/" + part.key)
      }
      for row in part.rows {
        out.push("row/" + row.key)
      }
    }
    out
  }
  let part_of = fn(key : String) { parts.get().iter().find_first(fn(p) { p.key == key }) }
  // (the row by its key, and whether another of its group is under it)
  let row_of = fn(key : String) -> (SettingsRow, Bool)? {
    for p in parts.get() {
      for i, r in p.rows {
        if r.key == key {
          return Some((r, i + 1 < p.rows.length()))
        }
      }
    }
    None
  }
  // (as the search's words change, at once: the list is what they find, never on its way to it)
  v.each(lines, fn(k) { k }, at_once=true, fn(line, k) {
    let k = k.untracked()
    if k == "empty" {
      // (its words where the rows' and the field's start: the sidebar's hint, as far in as its rows' words)
      line.box(fn(e) {
        @sf.style_node(e, fn() { @sf.side_hint_at(at) })
        @sf.words_node(e, fn() { @sf.t("common.noMatch") }, fn() { @sf.secondary }) |> ignore
      })
      |> ignore
    } else if k.has_prefix("head/") {
      let key = k.unsafe_substring(start=5, end=k.length())
      // (its words as they are now, told on only as they change: not each time another row's does)
      let heading = @signals.computed(fn(_) { part_of(key).map(fn(p) { p.heading }).unwrap_or("") })
      @sf.list_heading_node(line, fn() { heading.get() }, at)
    } else if k.has_prefix("apart/") {
      line.box(fn(a) { @sf.style_node(a, fn() { settings_side_apart }) }) |> ignore
    } else {
      settings_side_row_node(line, k.unsafe_substring(start=4, end=k.length()), row_of, lights, open, at)
    }
  })
  fn() {
    let out : Array[SettingsRow] = []
    for p in parts.untracked() {
      out.append(p.rows)
    }
    out
  }
}

///|
/// The room between two groups with no heading (list_apart's).
// kept across runs: a value (no field of it changes)
let settings_side_apart : @ui.Style = @ui.css("w=Full h=S3_5")

///|
/// A row of the sidebar's list (settings_side_rows_node's) by its `key` in `parent`, as row_of has it now: its mark, its
/// words, how things stand at its end (left out where the row has not the room: its words whole till then, cut only
/// where they alone have not); the pointer's ground on it, the selected one's while `lights` says it is the one lit;
/// the room of another under it while one is. Pressed, its page; read out a link named by its words.
fn settings_side_row_node(
  parent : @view.View,
  key : String,
  row_of : (String) -> (SettingsRow, Bool)?,
  lights : (SettingsRow) -> Bool,
  open : (@settings.Route) -> Unit,
  at : @sf.ListAt,
) -> Unit {
  // (the row as it is now, told on only as it changes: a change of another row's, of a count elsewhere in the
  // settings, runs none of this one's bindings)
  let held = @signals.computed(fn(_) { row_of(key) })
  let row = fn() { held.get().map(fn(r) { r.0 }) }
  let said = fn(f : (SettingsRow) -> String) { fn() { row().map(f).unwrap_or("") } }
  let selected = fn() {
    match row() {
      Some(r) => lights(r)
      None => false
    }
  }
  parent.box(fn(o) {
    @sf.style_node(o, fn() {
      if held.get().map(fn(r) { r.1 }).unwrap_or(false) {
        @sf.list_more(at)
      } else {
        settings_side_last
      }
    })
    o.box(fn(r) {
      @sf.style_node(r, fn() { @sf.side_row_at(at).then(settings_side_across).then(@sf.row_least_h()) })
      r.fits(Is(true)) |> ignore
      @sf.presses_node(r, fn() {
        match @signals.untracked(row) {
          Some(x) => settings_search_chose(x, open)
          None => ()
        }
      })
      r.says(By(fn() { Some(@view.said(Link, label=said(fn(x) { x.title })())) })) |> ignore
      @sf.nav_ground_node(r, selected)
      // (what it is by: a line icon in its mark's column, the account's a person's, the workspace's people's)
      let icon = match @signals.untracked(row).map(fn(x) { x.lead }) {
        Some(Icon(name)) => name
        Some(Person) => "user"
        Some(Space(_, _)) => "users"
        None => ""
      }
      if icon != "" {
        @sf.icon_node(r, icon, settings_side_mark, By(fn() { @sf.theme().p.muted })) |> ignore
      }
      r.box(fn(w) {
        @sf.style_node(w, fn() { settings_side_words }, in_row=true)
        @sf.words_node(w, said(fn(x) { x.title }), fn() { @sf.theme().chat_list.title.then(settings_side_title) }) |> ignore
      })
      |> ignore
      r.show(fn() { said(fn(x) { x.value })() != "" }, fn(e) {
        // (what the row holds itself leaves where it has not the room: what is at its end, before its title is cut)
        e.drops(Is(1)) |> ignore
        e.box(fn(end) {
          @sf.style_node(end, fn() { settings_side_end })
          end.show(fn() { row().map(fn(x) { x.dot }).unwrap_or(false) }, fn(d) { @sf.state_dot_node(d, fn() { "error" }) })
          @sf.words_node(end, said(fn(x) { x.value }), fn() {
            let words = @sf.theme().chat_list.last.then(settings_side_said)
            if row().map(fn(x) { x.bad }).unwrap_or(false) {
              words.then(@sf.bad)
            } else {
              words
            }
          })
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// The last row of a group: no room of another under it.
// kept across runs: a value (no field of it changes)
let settings_side_last : @ui.Style = @ui.css("w=Full")


///|
/// A sidebar row's mark's side (ICON's 16).
let settings_side_mark : Double = 16.0

///|
/// A sidebar row's mark, words and what is at its end, across its middle.
// kept across runs: a value (no field of it changes)
let settings_side_across : @ui.Style = @ui.css("align=ACenter")

///|
/// A sidebar row's words: what the row leaves its mark and what is at its end (settings_side_rows).
// kept across runs: a value (no field of it changes)
let settings_side_words : @ui.Style = @ui.style(w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let settings_side_title : @ui.TextStyle = @ui.text_style(w=Cut)

///|
// kept across runs: a value (no field of it changes)
let settings_side_end : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let settings_side_said : @ui.TextStyle = @ui.text_style(w=Hug)


///|
/// The list as a page of its own made once as nodes (the gear's on a small screen) in node `v`: who
/// is signed in and the workspace on cards of their own, each group on its card under its heading. The page's frame
/// and how far it is scrolled kept whatever changes; its cards and their rows each a node of its own by its group's key
/// and its own, come, gone and in their order as the core says which there are (security mode where the
/// workspace has none, the bottom bar's where the window has one), what each says (a heading, a row's words and how
/// things stand at its end) followed as it changes, in the language as it is. What a row is by: its icon; the account's
/// picture and the workspace's mark (settings_row_node's). `open`: a row pressed, its page. `here`: who
/// and where, as that changes. `bars`: whether the window has the bottom bar (the shell's to say), as that changes. `stint`: the page's time on top
/// (its stack's entry's), what a picture is asked for on.
pub fn settings_home_node(
  v : @view.View,
  core : Core,
  here : () -> @settings.Here,
  open : (@settings.Route) -> Unit,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  bars~ : () -> Bool,
  stint~ : () -> Int,
) -> Unit {
  // (the bottom bar's row where the shell says the window has the bar, as that changes; what is kept asked of the core as
  // it is asked to be read again, not as the list is worked out)
  let query = fn() { settings_search_field.text().trim(chars=" \t\n\r\u{3000}").to_owned().to_lower() }
  // (worked out again as what it reads changes, what reads it told only where its rows come out otherwise: a change of
  // a topic it reads that its rows do not say wakes nothing under it)
  let parts = @signals.computed(
    fn(_) {
      settings_found(settings_parts_of(core, here(), bars=bars(), kept=@settings.kept_told()), core, here(), query(), false)
    },
    same=fn(a, b) { a == b },
  )
  v.reacts(fn() { @settings.kept_asked() }, fn(_) { @settings.kept_ask(core) })
  // (its cards: each by its group's key (the account's and the workspace's by their rows'), its heading, its rows' keys; the account and the workspace each a card of
  // their own, as large as who and where they are)
  // (what a query finds another list, by the query: each card's key says it, so the cards a query typed or changed
  // finds are another set in the place of the ones before, there at once (page_node's pg_blocks_read), not each row
  // making its way in and out of the cards it was in, a card's rows and the cards beside it on ways of their own)
  let cards_now : @signals.Computed[Array[(String, String, Array[String])]] = @signals.computed(
    fn(_) {
      let out = []
      let q = query()
      let found_by = if q == "" { "" } else { "?" + q }
      for part in parts.get() {
        let identity = part.rows.iter().any(fn(r) { !(r.lead is Icon(_)) })
        let groups = if identity { part.rows.map(fn(r) { [r] }) } else { [part.rows] }
        for i, rows in groups {
          if rows.length() > 0 {
            // (a card by its group's key; the account's and the workspace's each by its own row's too)
            let id = (if identity { part.key + "/" + rows[0].key } else { part.key }) + found_by
            out.push((id, if i == 0 { part.heading } else { "" }, rows.map(fn(r) { r.key })))
          }
        }
      }
      out
    },
    same=fn(a, b) { a == b },
  )
  let cards = fn() { cards_now.get() }
  let card_of = fn(id : String) {
    let all = cards()
    all.search_by(fn(c) { c.0 == id }).map(fn(i) { all[i] })
  }
  let row_of = fn(key : String) -> SettingsRow? {
    for p in parts.get() {
      for r in p.rows {
        if r.key == key {
          return Some(r)
        }
      }
    }
    None
  }
  let blocks = fn() -> Array[String] {
    let all = ["settings-search"]
    let found = cards()
    if found.is_empty() && query() != "" {
      all.push("settings-search-empty")
    }
    for card in found {
      all.push(card.0)
    }
    all
  }
  @sf.page_node(v, fn() { @sf.t("android-settings.title") }, on_back=fn() { settings_search_reset(); on_back() }, frame~, blocks, fn(
    block,
    id,
  ) {
    if id == "settings-search" {
      // (what it finds, as a key is pressed in it: Enter opens the first)
      settings_search_node(
        block,
        results=fn() {
          let out : Array[SettingsRow] = []
          for p in parts.untracked() {
            out.append(p.rows)
          }
          out
        },
        choose=fn(r) { settings_search_chose(r, open) },
      )
    } else if id == "settings-search-empty" {
      @sf.page_note_node(block, fn() { @sf.t("common.noMatch") })
    } else {
      let heading = fn() { card_of(id).map(fn(c) { c.1 }).unwrap_or("") }
      block.show(fn() { heading() != "" }, fn(h) { @sf.heading_node(h, heading) })
      @sf.group_node(block, fn(g) {
        g.each(fn() { card_of(id).map(fn(c) { c.2 }).unwrap_or([]) }, fn(k) { k }, fn(rb, key) {
          let key = key.untracked()
          settings_row_node(rb, core, here, key, row_of, open, stint)
        })
      })
    }
  })
}

///|
/// The settings' list's row `key` in node `v` (settings_home_node's): what it says as row_of has it now; what it is by
/// as nodes: its icon; the account's picture (on the page's time on top, `stint`), else its
/// initial; the workspace's mark (a picture put up filling its square, else its glyph or emoji in it, else its first
/// letter).
fn settings_row_node(
  v : @view.View,
  core : Core,
  here : () -> @settings.Here,
  key : String,
  row_of : (String) -> SettingsRow?,
  open : (@settings.Route) -> Unit,
  stint : () -> Int,
) -> Unit {
  // (its row looked up once as the list changes, and what of it reads it woken only where this row comes out otherwise)
  let row_now = @signals.computed(fn(_) { row_of(key) }, same=fn(a, b) { a == b })
  let row = fn() { row_now.get() }
  let said = fn(f : (SettingsRow) -> String) { fn() { row().map(f).unwrap_or("") } }
  let shown = @signals.untracked(row)
  let lead : @sf.RowLead = match shown.map(fn(r) { r.lead }) {
    Some(Icon(name)) => LeadIcon(name)
    Some(Person) =>
      LeadMade(fn(l) {
        @sf.avatar_node(l, fn() { here().email }, said(fn(r) { r.title }), fn() {
          let p = here().picture
          if p == "" { "" } else { (core.picture)(p, stint()) }
        }, @sf.identity_mark)
      })
    Some(Space(_, _)) => LeadTile(fn(l) { settings_space_node(l, row, stint) })
    None => NoLead
  }
  @sf.link_row_node(
    v,
    said(fn(r) { r.title }),
    fn() {
      match @signals.untracked(row) {
        Some(r) => settings_search_chose(r, open)
        None => ()
      }
    },
    value=said(fn(r) { if r.key.has_prefix("find/") { "" } else { r.value } }),
    value_bad=fn() { row().map(fn(r) { r.bad }).unwrap_or(false) },
    value_dot=fn() { row().map(fn(r) { r.dot }).unwrap_or(false) },
    note=said(fn(r) { r.line }),
    strong=shown.map(fn(r) { !(r.lead is Icon(_)) }).unwrap_or(false),
    note_cut=shown.map(fn(r) { r.lead is Space(_, _) }).unwrap_or(false),
    lead~,
  )
}

///|
/// The workspace's mark on its row (its Space) in `parent`: in its square (workspace_tile), a
/// picture put up filling it on the card's ground; else on the chips' ground one of still.fail's icons or an emoji, 26,
/// else its first letter, muted; each as `row` says it now.
fn settings_space_node(parent : @view.View, row : () -> SettingsRow?, stint : () -> Int) -> Unit {
  let mark = fn() {
    match row() {
      Some({ lead: Space(emoji, icon), title, .. }) => (emoji, icon, title)
      _ => ("", "", "")
    }
  }
  let picture = fn() {
    let icon = mark().1
    icon.has_prefix("https://") || icon.has_prefix("http://") || icon.has_prefix("data:image/")
  }
  parent.box(fn(t) {
    let side = @sf.row_tile_side_node(parent, t)
    t
    .width(By(side))
    .height(By(side))
    .radius(By(fn() { @ui.tree_theme().corner(@sf.small_radius) }))
    // (the row's lead tile (LeadTile): the ladder's inset (8) from its start, top and foot, concentric with its corners
    // there, the small block's 10)
    .clips(Is(true))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() {
      let p = @sf.theme().p
      if picture() { p.card } else { p.chip }
    }))
    |> ignore
    let ink = fn() { @sf.theme().p.text }
    t.show(picture, fn(p) {
      @sf.station_mark_node(p, fn() { mark().0 }, fn() { mark().1 }, @sf.identity_mark, ink, stint)
    })
    t.show(fn() { !picture() && @sf.has_station_mark(mark().0, mark().1) }, fn(p) {
      @sf.station_mark_node(p, fn() { mark().0 }, fn() { mark().1 }, @sf.workspace_tile_mark, ink, stint)
    })
    t.show(fn() { !picture() && !@sf.has_station_mark(mark().0, mark().1) }, fn(l) {
      l
      .words(By(fn() { @sf.initial(mark().2) }))
      .words_look(By(fn() { @ui.style_words(@sf.workspace_letter) }))
      .ink(By(fn() { @ui.style_ink(@sf.workspace_letter) }))
      |> ignore
    })
  })
  |> ignore
}
