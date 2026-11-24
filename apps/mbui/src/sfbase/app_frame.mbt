// What the app does each frame and between frames whichever frame draws it (the phone's, the desktop's): its light
// or dark, accent and language as the prefs say, where its attention is (told the core), the system's say (a link it was
// opened with, back on screen, the menu bar's items, the network), the number on its icon.

///|
/// The words' language as the core says it (its prefs' `lang`: as chosen, else the device's), I18n.kt's follow, and the
/// product they name (its `product`): told
/// each frame (appearance) and as the app's tree is made, before any page of nodes says a word.
pub fn language_said(src : Source) -> Unit {
  language_from_prefs(src.topic("prefs", {}).get().value)
}

///|
/// The language and product named by a prefs value already read.
pub fn language_from_prefs(prefs : Json?) -> Unit {
  @sf.set_language(if prefs is Some(_) { Some(text(prefs, "lang")) } else { None })
  // and the product the words name, its cloud's (still.fail, monoid)
  @sf.set_product(text(prefs, "product"))
}

///|
/// Experimental switches on this device (实验性功能: `farviewNative`, `board`), told their signals as the
/// kept choices change and as the app's tree is made, before any page of nodes; turning `board` off puts away any
/// active board state and returns Home to the ordinary chat list.
pub fn features_from_prefs(prefs : Json?) -> Unit {
  let fv = @settings.feature_from(prefs, "farviewNative")
  if fv != farview_told.val {
    farview_told.val = fv
    farview_native.set(fv)
  }
  let bd = @settings.feature_from(prefs, "board")
  if bd != board_told.val {
    let was_on = board_told.val
    board_told.val = bd
    board_feature.set(bd)
    if was_on && !bd {
      board_transient_reset()
      (board_listed.val)()
    }
  }
  let si = @settings.feature_from(prefs, "selectionIntent")
  if si != selection_intent_told.val {
    selection_intent_told.val = si
    selection_intent_feature.set(si)
  }
  let cq = @settings.feature_from(prefs, "cmdQuote")
  if cq != cmd_quote_told.val {
    cmd_quote_told.val = cq
    cmd_quote_feature.set(cq)
  }
}

///|
/// The experimental switches last told from `prefs`: none on as a run begins.
let farview_told : Ref[Bool] = Ref(false)

///|
let board_told : Ref[Bool] = Ref(false)

///|
let selection_intent_told : Ref[Bool] = Ref(false)

///|
let cmd_quote_told : Ref[Bool] = Ref(false)

///|
/// Light or dark, as this device is set (the prefs' `appearance`), or as the system is (@hostapi.system_dark)
/// when it follows it; the host told when it changes (its bars follow, or are as dark as the frame's page says:
/// `page_dark`).
pub fn appearance(c : @ui.Ctx, src : Source, page_dark : Bool?) -> Unit {
  let prefs = src.topic("prefs", {}).get().value
  // the words' language too, the core's (its `lang`: as chosen, else the device's), I18n.kt's follow
  language_said(src)
  let dark = appearance_from_prefs(prefs, @ui.system_dark())
  // the system bars follow the page under them: the player's and a picture's or a video's in the viewer are dark
  // whatever the theme, a reader's as dark as its paper
  let bars = match page_dark {
    Some(d) => d
    None => dark
  }
  // (told once the frame's builds are over, as the last saw the page)
  if prefs is Some(_) && told_bars.val != Some(bars) {
    c.after_build("bars", fn() {
      if told_bars.val != Some(bars) {
        told_bars.val = Some(bars)
        @hostapi.set_dark(bars)
      }
    })
  }
}

///|
let told_bars : Ref[Bool?] = Ref(None)

///|
let told_dark : Ref[Bool?] = Ref(None)

///|
fn parse_frost_pct(s : String) -> Int? {
  if s == "" || s.length() > 3 {
    return None
  }
  let mut n = 0
  for i in 0..<s.length() {
    let c = s[i].to_int()
    if c < 48 || c > 57 {
      return None
    }
    n = n * 10 + (c - 48)
  }
  if n >= 0 && n <= 100 { Some(n) } else { None }
}

///|
/// What the prefs say of how the app looks and moves (`prefs`, as read), with the system dark or not (`system_dark`):
/// motion, haptics, the experimental switches, light or dark and the accent, told as the frame (appearance) and the
/// app's tree tell them, before any page of nodes is made and laid out in what they were before; whether dark.
pub fn appearance_from_prefs(prefs : Json?, system_dark : Bool) -> Bool {
  // motion as this device is set (the prefs' `motion`: reduce, full), else as the system's
  @ui.set_motion_chosen(match text(prefs, "motion") {
    "reduce" => Some(true)
    "full" => Some(false)
    _ => None
  })
  // liquid glass frost as this device is set (the prefs' `glassFrost`: 0..100), else 0 (default clear)
  let frost_s = @settings.pref_from(prefs, "glassFrost")
  let frost_v = match parse_frost_pct(frost_s) {
    Some(n) => n.to_double() / 100.0
    None => 0.0
  }
  @ui.set_glass_frost(frost_v)
  // haptics as this device is set (the prefs' `haptics`: off), else on
  @ui.set_haptics(text(prefs, "haptics") != "off")
  // the experimental switches as chosen here (the prefs' `features`)
  features_from_prefs(prefs)
  let dark = @settings.dark(prefs, system_dark)
  @sf.set_dark(Some(dark))
  // the accent as this device is set (the prefs' `accent`, as chosen here a moment ago), else still.fail's orange; one
  // shown a moment over it while 外观's dot is pointed at (accent_preview) kept till it ends
  accent_set_here.val = @settings.pref_from(prefs, "accent")
  @sf.set_accent(accent_shown.val.unwrap_or(accent_set_here.val))
  // (the host told once the prefs are read: not the system's first, then the one chosen)
  if prefs is Some(_) && told_dark.val != Some(dark) {
    told_dark.val = Some(dark)
    // (said on the log for scripted runs: e2e/flows checks the theme was taken)
    @hostapi.log(if dark { "theme: dark" } else { "theme: light" })
  }
  dark
}

///|
/// The accent the prefs say (appearance_from_prefs), and one shown a moment over it (外观's dot pointed at, unchosen:
/// accent_preview): None, none.
// kept across runs: put back by accent_preview_reset (reset)
let accent_set_here : Ref[String] = Ref("")

///|
// kept across runs: put back by accent_preview_reset (reset)
let accent_shown : Ref[String?] = Ref(None)

///|
// kept across runs: put back by accent_preview_reset (reset)
let rainbow_seeded : Ref[Bool] = Ref(false)

///|
/// Picks this run's colour for 五彩色 (`rainbow`) once from the opening wall time `now_ms`, so each page load or app
/// launch lands on a fresh hue while staying deterministic for a given clock in tests.
pub fn rainbow_seed_once(now_ms : Double) -> Unit {
  if !rainbow_seeded.val {
    rainbow_seeded.val = true
    @sf.set_rainbow_hue(@sf.rainbow_hue_of_seed(now_ms.to_int64()))
  }
}

///|
/// The window shown a moment in the colour theme `key` (its dot pointed at in 外观), over the one set, till
/// accent_preview_end; or, None, back to the one set.
pub fn accent_preview(key : String?) -> Unit {
  accent_shown.val = key
  @sf.set_accent(key.unwrap_or(accent_set_here.val))
}

///|
/// A colour theme chosen while one was shown a moment: shown as chosen at once, what the prefs say then taking over.
pub fn accent_chosen(key : String) -> Unit {
  accent_shown.val = None
  @sf.set_accent(key)
}

///|
/// As at the start (the app's reset): nothing shown over the accent set.
pub fn accent_preview_reset() -> Unit {
  accent_set_here.val = ""
  accent_shown.val = None
  rainbow_seeded.val = false
}

///|
/// What this app last told the core of its attention (`client.focus`): shown, in front, the workspace in view, whether
/// its new chat is the page shown; and where to tell it again when the system says the app left the front between
/// frames.
priv struct Attention {
  mut told : Bool
  mut visible : Bool
  mut focused : Bool
  mut workspace : String
  mut new_chat : Bool
  mut src : Source?
}

///|
/// The latest cellular network state told by the system before a source was available (flushed on attend).
// kept across runs: put back as a run begins (app_frame_reset)
let cellular_pending : Ref[Bool?] = Ref(None)

///|
let attention : Attention = {
  told: false,
  visible: false,
  focused: false,
  workspace: "",
  new_chat: false,
  src: None,
}

///|
/// Tells the core where this app's attention is, as the Android app's activity and App.kt do: shown and in front or
/// not (`client.focus {visible, focused}`, as the system says: @ui.app_visible, app_focused) and the workspace in view
/// (`workspace`); a chat's own place (`chat`, `left`) is chat.mbt's. Only a change is told. What is read follows from
/// it: the core marks a chat read only while a page in view (visible) shows its end, and shows no notice of a chat
/// one in front shows. `new_chat`: the page on top is the workspace's new chat (`newChat`), which the core keeps as
/// what the workspace goes back to (the wide frame lands on it as the app opens again: sfdesk's frame.mbt land) in
/// place of the chat shown before it.
pub fn attend(src : Source, workspace : String, new_chat : Bool) -> Unit {
  if attention.src is None {
    // the system's say between frames (Android's activity pausing: no frame comes after it)
    @ui.on_app_change(fn(_, _) {
      match attention.src {
        Some(s) => {
          attend(s, attention.workspace, attention.new_chat)
          // what lives only while shown let go as the app goes behind (the screens live in their cards: ScreenLinks.kt
          // Peek, under STARTED)
          if !@ui.app_visible() {
            (shell.val.behind)(s)
          }
        }
        None => ()
      }
      notices_app_change(@ui.app_visible(), @ui.app_awake())
    })
  }
  attention.src = Some(src)
  if !src.read_only && cellular_pending.val is Some(on) {
    cellular_pending.val = None
    (src.call)("client.network", { "cellular": Json::boolean(on) }, answer_unread)
  }
  let visible = @ui.app_visible()
  let focused = @ui.app_focused()
  if attention.told &&
    visible == attention.visible &&
    focused == attention.focused &&
    workspace == attention.workspace &&
    new_chat == attention.new_chat {
    return
  }
  attention.told = true
  attention.visible = visible
  attention.focused = focused
  attention.workspace = workspace
  attention.new_chat = new_chat
  let params : Map[String, Json] = {
    "visible": Json::boolean(visible),
    "focused": Json::boolean(focused),
    "workspace": Json::string(workspace),
  }
  if new_chat {
    params["newChat"] = Json::string(workspace)
  }
  (src.call)("client.focus", Json::object(params), answer_unread)
}

///|
/// What was chosen in the system's own bars (@hostapi.nav_bar) since the wide frame last took it, oldest first:
/// what takes them (sfdesk's rail_native.mbt, in the island under the frame) built again as one comes, not kept as it
/// was till something else of its changes (an iPhone Duo's ⓘ, 2026-11-01: its popover only once a finger moved).
// kept across runs: emptied as a run begins (sfbase's reset)
pub let nav_tapped : @signals.Signal[Array[String]] = @signals.signal([], same=fn(a, b) { a == b })

///|
/// Where the system said the item last chosen in its bars is (@hostapi.nav_tapped_at: x, y, width, height; no width:
/// none said), followed by what is put where one was chosen (its mark, over the frame): moved there as it is said.
// kept across runs: put back by what sets nav_tapped_at back (sfdesk's rail_native.mbt)
pub let nav_tapped_place : @signals.Signal[(Double, Double, Double, Double)] = @signals.signal(
  (0.0, 0.0, 0.0, 0.0),
  same=fn(a, b) { a == b },
)

///|
/// What the system said between frames (@hostapi.system_channel; its handler set as the package starts, before the first
/// frame takes what came with the app's start), to the core: back on screen after `away` ms off it, the
/// core gives up requests that went out before and reconnects links gone quiet (MainActivity.kt wake: `client.wake
/// {away}`, client/core-ts src/wake.ts), and a newer build is asked for again (onStart's checkUpdates); the default
/// network changed, every link it had is taken for dead (NetworkWatch: `client.wake {away: 0, network: true}`).
fn system_said(json : String) -> Unit {
  let said = @hostapi.system_said(json)
  for s in said {
    match s {
      // a link the system opened the app with (links.mbt): opened once the app can (signed in, its workspace known)
      Link(url) => link_opened_with(app_link(url))
      // shown over another app, or in its own window again (share.mbt)
      Over(over) => share_over.set(over)
      // a tab or an item of the system's own bars chosen (sfdesk's rail_native.mbt takes it as it draws)
      NavTapped(id) => {
        let at = @hostapi.nav_tapped_at
        nav_tapped_place.set((at[0], at[1], at[2], at[3]))
        let taps = nav_tapped.untracked().copy()
        taps.push(id)
        nav_tapped.set(taps)
      }
      // whether the default network is cellular: kept so startup reports before attend are sent once a source exists
      Cellular(on) => cellular_pending.val = Some(on)
      // (how far the bars reach in over the view: mbui keeps it, @ui.system_bars, bars.mbt)
      _ => ()
    }
  }
  let src = match attention.src {
    Some(s) => s
    None => return
  }
  if src.read_only {
    return
  }
  if cellular_pending.val is Some(on) {
    cellular_pending.val = None
    (src.call)("client.network", { "cellular": Json::boolean(on) }, answer_unread)
  }
  for s in said {
    match s {
      Shown(away~) => {
        (src.call)("client.wake", { "away": Json::number(away) }, answer_unread)
        update_check(src, false)
      }
      // 检查更新 from the menu bar (menu_bar.mbt)
      Menu("update.check") => update_from_menu(src)
      // one of the pages' actions from the menu bar: done as its keys are (keymap.mbt ask_action)
      Menu(action) => @settings.ask_action(action)
      // a package handed to the system's installer could not be installed
      InstallAllow(..) => toast_later(@sf.t("android-chat.file.allowInstall", args=[("app", @sf.product())]))
      InstallFailed(error~, ..) => toast_later(@sf.t("android-chat.file.installFailed", args=[("error", error)]))
      Network =>
        (src.call)(
          "client.wake",
          { "away": Json::number(0.0), "network": Json::boolean(true) },
          fn(_) {  },
        )
      _ => ()
    }
  }
}

///|
/// The system's say has its handler before the first frame (what is posted as the app starts, a link it was opened
/// with, would be left with none).
fn init {
  @ui.on_message(@hostapi.system_channel, fn(json, _) { system_said(json) })
  // what the phone has for 共享调试, as its host says by itself (the app's Android: AdbShare.java)
  @ui.on_message("native:adb.phone", fn(json, _) { @settings.adb_phone_said(json) })
  // its notifications' words, for a share a chat's grant starts with no page shown (AdbShare.java `adb.texts`)
  @ui.native_call("adb.texts", @settings.adb_texts()) |> ignore
}

///|
/// A link the system opened the app with, as the core reads it (`link.parse`): one of still.fail's desktop app's own
/// (stillfail://, stillfail-beta://: …//o/<workspace>/<station>/<chat>, as the web's /o/ page hands an item
/// to that app, which this one takes as it is built in its place: scripts/mac-app.sh) as the same page's on the
/// cloud; any other as it is.
pub fn app_link(url : String) -> String {
  for scheme in ["stillfail://", "stillfail-beta://", "monoid://", "monoid-beta://"] {
    if url.has_prefix(scheme) {
      return "\{cloud_origin()}/\{url.exact_view(start=scheme.length())}"
    }
  }
  url
}

///|
/// Shown over another app (the host's say, @hostapi.system_channel `over`): only the share sheet is drawn.
pub let share_over : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

///|
/// The workspace in view (the one switched to here, else the one last open, else the first once every account has
/// answered; None while none is known yet: the prefs, which say the one last open, not read yet among them), every
/// workspace, whether every account has answered, whether invitations wait.
pub fn workspace_in_view(src : Source) -> (Workspace?, Array[Workspace], Bool, Bool) {
  let ws = src.topic("workspaces", {}).get().snapshot()
  let prefs = src.topic("prefs", {}).get().snapshot()
  let (all, answered, invited) = workspaces_of(ws.value)
  // (the first before the prefs are read, the one last open once they are: a workspace shown, then another)
  if app.picked.get() == "" && prefs.value is None && prefs.error is None {
    return (None, all, answered, invited)
  }
  let kept = if app.picked.get() != "" {
    app.picked.get()
  } else {
    text(prefs.value, "workspace")
  }
  let current = match all.iter().find_first(fn(w) { w.id == kept }) {
    Some(w) => Some(w)
    None =>
      if all.length() > 0 && (kept == "" || answered) {
        Some(all[0])
      } else {
        None
      }
  }
  (current, all, answered, invited)
}

///|
/// The number last put on the app's icon (-1 none yet), as a signal: what said to put it there, from what it read, is
/// built again as it is put (else what is kept of it says it again, the number put already).
// kept across runs: put back as a run begins (app_frame_reset)
let badge_told : @signals.Signal[Int] = @signals.signal(-1, same=fn(a, b) { a == b })

///|
/// Each frame signed in: the number on the app's icon (the desktop app's followBadge), the core's badge, else what is
/// wrong and what waits in every workspace; told as it changes, once the frame's builds are over.
pub fn badge_frame(c : @ui.Ctx, src : Source) -> Unit {
  let marks = src.topic("workspaceMarks", marks_asked()).get().value
  let badge = match field(marks, "badge") {
    Some(Number(_, ..)) => count(marks, "badge")
    _ =>
      match field(marks, "workspaces") {
        Some(Object(m)) => m.values().fold(init=0, fn(n, x) { n + count(Some(x), "alert") + count(Some(x), "wait") })
        _ => 0
      }
  }
  if marks is Some(_) && badge != badge_told.get() {
    c.after_build("badge", fn() {
      badge_told.set(badge)
      @ui.set_badge(badge)
    })
  }
}

///|
/// As at the start: nothing told the core, the host or the icon yet, nothing said by the system waiting.
fn app_frame_reset() -> Unit {
  badge_told.set(-1)
  told_bars.val = None
  told_dark.val = None
  farview_told.val = false
  board_told.val = false
  selection_intent_told.val = false
  cmd_quote_told.val = false
  attention.told = false
  attention.visible = false
  attention.focused = false
  attention.workspace = ""
  attention.new_chat = false
  attention.src = None
  cellular_pending.val = None
  share_over.set(false)
}

///|
/// Whether the app is shown (what it last told the core: `client.focus`); before it told anything, shown.
pub fn app_in_front() -> Bool {
  !attention.told || attention.visible
}
