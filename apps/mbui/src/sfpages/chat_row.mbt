// A chat's row in the chats' lists (still.fail web/src/Sidebar.tsx ChatRow, ArchiveButton, Rename.tsx TitleInput;
// web/src/mobile/Home.tsx ChatRow, SwipeArchive, useRowMenu, useRowArchive; Sidebar.css.ts navSession…, mobile/Home.css.ts
// mChatRow…): one row in every tier, the web's desktop row with a mouse and its phone row with a finger. Its state's
// mark before its title (bolder while something in it is unread), its station's mark, then where it stands or the
// last thing said, who is in it at the second line's end; pressed, its chat (where the shell has it). With a mouse:
// pointed at, its time in that place and 归档 at its top right; right clicked, its menu at the pointer; renamed in
// place. With a finger: 66 high and in the phone's type; held, its time, and held long its menu; a chat is swiped left
// to archive it. The menu is the presenters' (@sf.menu): 固定,
// 重命名, 保留, 复制会话链接, 转到频道, 归档, 分享给其他 workspace, 分享图片, each where the chat has it.
//
// One mark for one meaning everywhere (the user, 2026-10-28: 「agent 各种颜色和形状的点很混乱」).

///|
/// What the rows keep: the row whose title is being written in place (a mouse's 重命名, its key; "" none) and its field,
/// whether the field had the keyboard last frame (it losing it ends the rename); the row whose menu is open and the
/// presenter it is (lit meanwhile); the rows swiped off to be archived, until they have gone; each swiped row's being
/// past its line as last felt, and the press whose menu was last felt.
priv struct Rows {
  rename_field : @ui.Field
  mut menu_for : String
  mut menu_serial : Int
  swiped_off : Map[String, Bool]
  felt_past : Map[String, Bool]
}

///|
let rows : Rows = {
  rename_field: @ui.Field::new(),
  menu_for: "",
  menu_serial: -1,
  swiped_off: {},
  felt_past: {},
}

///|
fn chat_rows_reset() -> Unit {
  match row_primed.val {
    Some(reader) => { row_primed.val = None; reader.cancel() }
    None => ()
  }
  row_held.val = (0, false)
  row_left.val = ("", false)
  row_left_said.set("")
  row_renaming.set("")
  rows.rename_field.set("")
  rows.menu_for = ""
  rows.menu_serial = -1
  rows.swiped_off.clear()
  rows.felt_past.clear()
  match chat_menu_waits.val {
    Some(w) => w.end()
    None => ()
  }
  chat_menu_waits.val = None
}

///|
/// How long a finger holds a row before its time shows.
pub let hold_ms : Double = 450.0

///|
/// A row's chat as a page's.
fn row_ref(item : ChatItem) -> ChatRef {
  { station: item.station, session: item.session, title: item.title, station_name: item.station_name }
}

///|
/// Whether `item`'s row has its menu open (its ground stays lit, its time shown, meanwhile).
fn row_menu_open(item : ChatItem) -> Bool {
  rows.menu_for == @sfbase.row_name(item) && @sf.presented_drawn_of(rows.menu_serial)
}

///|
/// Whether `item`'s row should stay lifted for its finger menu (open, or replaced in place by another open sheet).
fn row_menu_lifting(item : ChatItem) -> Bool {
  rows.menu_for == @sfbase.row_name(item) && @sf.presented_open_chain_of(rows.menu_serial)
}

///|
/// What its station has not answered yet of a chat's pin, rename or archive (the core's `doing`, Sidebar.tsx
/// useDoingState, mobile/Home.tsx useDoing): under way, or why it failed a moment ago.
fn row_busy(src : Source, item : ChatItem) -> Bool {
  core_doing(src, row_calls, [("station", item.station), ("session", item.session)])
}

///|
fn row_failed(src : Source, item : ChatItem) -> String? {
  core_failed(src, row_calls, [("station", item.station), ("session", item.session)])
}

///|
// kept across runs: a table, never written
let row_calls : Array[String] = ["chat.pin", "chat.rename", "chat.archive"]

///|
/// A row let go without opening its chat (a scroll, a hold): release only the read made by this press.
fn unprime(src : Source, r : ChatRef, reader : @sfbase.TopicLease?) -> Unit {
  if !src.read_only && !readings.contains(r.station + "\u{1}" + r.session) {
    @sfbase.chat_inputs_left_from(src, r)
  }
  match reader { Some(reader) => reader.cancel(); None => () }
}

///|
/// The row pressed last, and whether the press has been a long one (its menu's: not a tap).
// kept across runs: put back by chat_rows_reset (rows)
let row_held : Ref[(Int, Bool)] = Ref((0, false))

///|
let row_primed : Ref[@sfbase.TopicLease?] = Ref(None)

///|
/// The chats a chat's agent made (ChatView `opened`) as a menu's items (its info's next menu): each its title (已归档
/// after one in the archive), where it stands its mark (opened_icon); chosen, `then` (what showed them closed), its chat
/// opened.
pub fn opened_items(opened : Array[@sfbase.OpenedChat], then? : () -> Unit = fn() {  }) -> Array[@sf.MenuItem?] {
  opened.map(fn(o) {
    let label = if o.archived { o.chat.title + " · " + o.note } else { o.chat.title }
    Some(
      @sf.menu_item_of(label, icon=opened_icon(o), fn() {
        then()
        open_page(Chat(o.chat))
      }),
    )
  })
}

///|
/// The mark of a chat a chat's agent made (ChatView `opened`), where it stands: what it needs of the viewer (a bell),
/// failed, at work, done, in the archive; else the mark of a chat made by another's agent.
pub fn opened_icon(o : @sfbase.OpenedChat) -> String {
  if o.archived {
    "archive"
  } else {
    match (o.state_lead, o.mark) {
      ("need", _) | ("decision", _) | (_, "block") => "bell"
      (_, "failed") => "close"
      (_, "run") => "wait"
      ("done", _) => "check"
      _ => "spawned"
    }
  }
}

///|
/// The made-up chat of row `i` of a chats' list in its bones (chat_rows_sample): its title and line as long as a chat's
/// are, an agent in it.
pub fn sample_chat(i : Int) -> ChatItem {
  let title = sample_titles[i % sample_titles.length()]
  let line = sample_lines[i % sample_lines.length()]
  @sfbase.chat_item({
    "id": Json::string("sample/" + i.to_string()),
    "session": Json::string("sample/" + i.to_string()),
    "title": Json::string(@sf.sample_words(title)),
    "last": { "preview": Json::string(@sf.sample_words(line)) },
    "agents": [{ "key": "sample", "maker": { "id": "anthropic" } }],
  })
}

///|
/// How long the made-up chats' titles and lines are (letters).
// kept across runs: a table, never written
let sample_titles : Array[Int] = [7, 10, 6, 12, 8, 9, 5, 11]

///|
// kept across runs: a table, never written
let sample_lines : Array[Int] = [14, 11, 16, 9, 13, 15, 10, 12]

///|
/// A row held, all the way up: how much it is drawn in from the screen's sides (a card of it, @sf.lift_over).
let row_lift_inset : Double = 0.045

///|
/// A finger's row whose chat was gone back from: how long its ground stays (about a phone's page sliding off, 350, and
/// as long again), and how long it then takes to fade.
pub let left_lit_ms : Double = 700.0

///|
pub let left_fade_ms : Double = 400.0

///|
/// The finger's row whose chat is in view or was gone back from last, till its ground has faded, and whether its
/// going back is marked (the time its ground stays counted from).
// kept across runs: put back by chat_rows_reset, forgotten once its ground has faded
let row_left : Ref[(String, Bool)] = Ref(("", false))

///|
/// A finger's row's height at the default size of words (higher at the system's set larger: sf's list_row_node).
pub let touch_row_h : Double = @sf.touch_list_row_h

///|
// kept across runs: a value (no field of it changes)
pub let row_last : @ui.Style = @ui.css("w=Full")

///|
/// The title's mark's column (navMarkSlot, mMarkSlot: 10, the mark in its middle).
// kept across runs: a value (no field of it changes)
let mark_slot : @ui.Style = @ui.css("w=S2_5 align=ACenter")

///|
/// The title of a chat settled (all its work done or dropped) or of an offline station's, stepped back: in the muted
/// grey (navSession[data-settled], [data-offline]); a settled one says so by the archive box leading its second line
/// (@sfbase.row_lead), its words going no lighter. Not faded: half its ink was 2.7 to 1 on the sidebar, too faint to read
/// for a row that still opens (mbui ui/contrast.mbt).
// kept across runs: a value (no field of it changes)
let title_dim : @ui.TextStyle = @ui.text_style(color=Muted)

///|
/// (its state line where the core says one: the words pressed for the message it is about)
// kept across runs: a value (no field of it changes)
let state_box : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
/// When, in the aside's place while pointed at or held (navTime, mChatTime: 11 or 12, subtle).
// kept across runs: a value (no field of it changes)
let row_time : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, wrap=false)

///|
/// What stands at a row's title's end (Sidebar.css.ts sessionKind): a column 16 wide, its mark (12) in the middle.
// kept across runs: a value (no field of it changes)
pub let kind_slot : @ui.Style = @ui.css("w=S4 align=ACenter")

///|
/// How wide that column is (kind_slot's S4).
let kind_slot_w : Double = 16.0

///|
pub let kind_mark : Double = 12.0

///|
/// The size a station's mark `icon` is drawn at in that column: a glyph (`glyph:`, and the line icons such as
/// unplugged) is drawn in a 24 grid with room of its own round it (2.5 a side), so at the column's 16 its lines span
/// 12.7, as wide as a logo, an emoji or a picture filling `kind_mark`; drawn at 12 it read smaller than the marks
/// under it and off their line.
pub fn kind_mark_of(icon : String) -> Double {
  if icon.has_prefix("glyph:") {
    kind_glyph
  } else {
    kind_mark
  }
}

///|
/// A line icon in that column (kind_mark_of): the column's width.
let kind_glyph : Double = 16.0

///|
/// A row's icons (16).
let row_icon : Double = 16.0

///|
/// Whether a row offers its menu (right clicked, held, its 归档 key): a chat its station has, while that station is
/// there; one asked for here that did not go (its first message unsent, nobody making it now), whatever its station:
/// archived here alone (chat_menu_items), its station never having had it. One still being made offers none.
fn row_menu_offered(item : ChatItem) -> Bool {
  if item.pending {
    item.unsent
  } else {
    item.offline is None
  }
}

///|
/// What a chat's menu offers (a row's, and the "…" of the chat's page, one and the same, 2026-11-06 Peng Xiao: 「这里的...和
/// 侧边栏右键点击 chat，我感觉需要统一一下」). `page`: the page's own of share_items (chat_extra_items, from its view, which it
/// has read already), in place of the row's. What shares it or takes it elsewhere (复制会话链接, 接力到频道 for a thread with an
/// agent, and share_items: 分享给其他 workspace, 分享图片, 在 Slack／飞书打开) is one item, 分享, its own menu from
/// `share_from` (where the menu was opened), where there are two or more of them (左子健, 2026-11-09: 菜单有点太多了，只把分享收进一个).
/// `here`: a row's of a list made once, its 归档 said where the row was (archive_row's `here`). `asks_rename`: 重命名
/// asked over the page on every input, where its chat shows no title of a row's to be its field (a board's card);
/// `archived` done as it is archived from here, before it is (a board's card's: its chat no more beside the board).
fn chat_menu_items(
  src : Source,
  item : ChatItem,
  share_from~ : () -> @sf.Beside,
  page? : Array[@sf.MenuItem?],
  here? : Bool = false,
  asks_rename? : Bool = false,
  archived? : () -> Unit = fn() {  },
  along? : @ui.Along = Start,
) -> Array[@sf.MenuItem?] {
  let r = row_ref(item)
  let items : Array[@sf.MenuItem?] = []
  // a chat asked for here that its station has not made (its first message did not go): its station knows nothing of
  // it to pin, rename or share, so it is only archived, here alone (the core drops it: archive_row says no 撤销)
  if item.pending {
    items.push(
      Some(
        @sf.menu_item_of(@sf.t("web-main.chat.archive"), icon="archive", fn() {
          archived()
          archive_row(src, item, here~)
        }),
      ),
    )
    return items
  }
  match item.pinned {
    Some(p) =>
      items.push(
        Some(
          @sf.menu_item_of(@sf.t(if p { "web-main.chat.unpin" } else { "web-main.chat.pin" }), icon="pin", fn() {
            @ui.haptic(Confirm)
            act(
              src,
              @sf.t(if p { "android-chat.unpin.verb" } else { "android-chat.pin.verb" }),
              "",
              "chat.pin",
              { "station": Json::string(item.station), "session": Json::string(item.session), "pinned": Json::boolean(!p) },
            )
          }),
        ),
      )
    None => ()
  }
  items.push(
    Some(
      @sf.menu_item_of(@sf.t("web-main.chat.rename"), icon="edit", fn() {
        // asked where the presenters ask it: with keyboard and mouse the row's title its own field, on a
        // touch over the page; where no row's title shows it, over the page on both
        if asks_rename {
          @sf.ask(
            @sf.t("android-chat.rename.title"),
            @sf.t("common.save"),
            fn(title) { rename(src, item, title) },
            value=item.title,
            placeholder=@sf.t("android-chat.rename.field"),
            hint=@sf.t("android-chat.rename.note"),
          )
          return
        }
        @sf.ask_here(
          @sf.t("android-chat.rename.title"),
          @sf.t("common.save"),
          fn(title) { rename(src, item, title) },
          fn() {
            row_renaming.set(@sfbase.row_name(item))
          },
          value=item.title,
          placeholder=@sf.t("android-chat.rename.field"),
          hint=@sf.t("android-chat.rename.note"),
        )
      }),
    ),
  )
  match item.thread {
    Some(th) if !item.connect && item.agents.length() > 0 =>
      items.push(
        Some(
          @sf.menu_item_of(@sf.t("web-main.chat.regenerateTitle"), icon="refresh", fn() {
            if !src.read_only {
              toast_later(@sf.t("web-main.chat.regenerateTitle.start"))
            }
            act(
              src,
              @sf.t("web-main.chat.regenerateTitle.verb"),
              "",
              "chat.regenerateTitle",
              { "station": Json::string(item.station), "thread": Json::number(th) },
              done=@sf.t("web-main.chat.regenerateTitle.done"),
            )
          }),
        ),
      )
    _ => ()
  }
  match item.thread {
    Some(th) if item.pinned != Some(true) =>
      items.push(
        Some(
          @sf.menu_item_of(@sf.t(if item.kept { "web-main.chat.unkeep" } else { "web-main.chat.keep" }), icon="shield-check", fn() {
            act(
              src,
              @sf.t(if item.kept { "web-main.chat.unkeep.what" } else { "web-main.chat.keep.what" }),
              "",
              "chat.keep",
              { "station": Json::string(item.station), "thread": Json::number(th), "kept": Json::boolean(!item.kept) },
              done=@sf.t(if item.kept { "web-main.chat.unkeep.done" } else { "web-main.chat.keep.done" }),
            )
          }),
        ),
      )
    _ => ()
  }
  match (item.thread, item.hidden) {
    (Some(_), Some(hidden)) =>
      items.push(Some(@sf.menu_item_of(@sf.t(if hidden { "web-main.chat.unhide" } else { "web-main.chat.hide" }), icon=if hidden { "eye" } else { "eye-off" }, fn() {
        hide_row(src, item, !hidden)
      })))
    _ => ()
  }
  match (item.thread, item.muted) {
    (Some(thread), Some(muted)) =>
      items.push(Some(@sf.menu_item_of(@sf.t(if muted { "web-main.chat.unmute" } else { "web-main.chat.mute" }), icon="bell", fn() {
        act(
          src,
          @sf.t(if muted { "web-main.chat.unmute" } else { "web-main.chat.mute" }),
          "",
          "chat.mute",
          { "station": Json::string(item.station), "thread": Json::number(thread), "muted": Json::boolean(!muted) },
          done=@sf.t(if muted { "web-main.chat.unmutedNotice" } else { "web-main.chat.mutedNotice" }),
          at_once=true,
        )
      })))
    _ => ()
  }
  // with the chat's own state (pinned, kept), not last: a sheet's last row is over the screen's foot, where a thumb
  // going home or back lands on it
  items.push(
    Some(
      @sf.menu_item_of(@sf.t("web-main.chat.archive"), icon="archive", fn() {
        archived()
        archive_row(src, item, here~)
      }),
    ),
  )
  // (a line between the groups: the chat itself; where else it is and goes)
  rule_after(items)
  // the chat an agent opened it from: gone to (its own page, its row as it is)
  match item.opener {
    Some(o) =>
      items.push(
        Some(
          @sf.menu_item_of(@sf.t("web-main.chat.openOpener", args=[("title", o.chat.title)]), icon="spawned", fn() {
            open_page(Chat(o.chat))
          }),
        ),
      )
    None => ()
  }
  // to another station of its workspace (its owners and admins: the core's mayMove), its stations picked among
  if item.may_move {
    items.push(
      Some(@sf.menu_item_of(@sf.t("web-pages.stations.move.menu"), icon="move", further=true, fn() { open_chat_move(src, item, from=share_from()) })),
    )
  }
  // what shares it or takes it elsewhere: one 分享 where there are two or more
  let shared : Array[@sf.MenuItem?] = []
  let link = @sfbase.chat_link(item.station, item.session)
  if link != "" {
    shared.push(
      Some(
        @sf.menu_item_of(@sf.t("web-main.chat.copyLink"), icon="copy", fn() {
          @sfbase.copy_chat_link(item.title, link)
        }),
      ),
    )
  }
  // relayed to a channel: a chat with an agent to go on there
  match item.thread {
    Some(th) if item.agents.length() > 0 =>
      shared.push(
        Some(
          @sf.menu_item_of(@sf.t("web-main.relay.action"), icon="arrow-up-right", further=true, fn() {
            open_relay(src, r, th, from=Unanchored)
          }),
        ),
      )
    _ => ()
  }
  // shared, a picture of it, it in Slack or Feishu: the page's and a row's alike (share_items)
  shared.append(
    match page {
      Some(own) => own
      None =>
        share_items(
          src,
          r,
          item.thread,
          may_share=item.may_share,
          may_publish=item.may_publish,
          slack_url=item.slack_url,
          slack_app=item.slack_app,
          feishu_url=item.feishu_url,
          comma_url=item.comma_url,
          comma_app=item.comma_app,
        )
    },
  )
  items.append(share_menu(shared, share_from, along~))
  // (no line closing the menu: nothing after the chat's own group)
  if items.last() is Some(None) {
    items.pop() |> ignore
  }
  items
}

/// Hide only from this person's lists, or put the chat back; undo uses the same personal mark.
fn hide_row(src : Source, item : ChatItem, hidden : Bool) -> Unit {
  guard item.thread is Some(thread) else { return }
  let words = @sf.t(if hidden { "web-main.chat.hide" } else { "web-main.chat.unhide" })
  act(
    src,
    words,
    "",
    "chat.hide",
    { "station": Json::string(item.station), "thread": Json::number(thread), "hidden": Json::boolean(hidden) },
    done=@sf.t(if hidden { "web-main.chat.hiddenNotice" } else { "web-main.chat.unhiddenNotice" }),
    done_action=if hidden { @sf.t("android-chat.archived.undo") } else { "" },
    done_run=fn() { hide_row(src, item, false) },
    at_once=true,
  )
}

///|
/// A line ending a menu's group: after an item only (none first, none twice).
fn rule_after(items : Array[@sf.MenuItem?]) -> Unit {
  if items.last() is Some(Some(_)) {
    items.push(None)
  }
}

///|
/// A chat renamed `title` (`chat.rename`): nothing when it is no different.
fn rename(src : Source, item : ChatItem, title : String) -> Unit {
  let words = title.trim(chars=" \n\t").to_owned()
  if words == "" || words == item.title {
    return
  }
  let p : Map[String, Json] = {
    "station": Json::string(item.station),
    "session": Json::string(item.session),
    "title": Json::string(words),
  }
  match item.thread {
    Some(th) => p["thread"] = Json::number(th)
    None => ()
  }
  act(src, @sf.t("android-chat.rename.verb"), "", "chat.rename", Json::object(p))
}

///|
/// Let a rename go, including the field's identity, so the same row can be renamed again.
fn stop_rename() -> Unit {
  row_renaming.set("")
}

///|
/// The field in the title's place: the row's head across, its mark's place too (the mark
/// left out while it shows), 24 high on the canvas, 4 taller than the title's line without making the row taller; a 1
/// line round it in the strong grey; the title's words (13 on 24). In the row's top corners: a capsule (its shape its
/// height's) standing where it is concentric with both (@sf.capsule_in: the row's 18 its distance and its half, 6), as
/// far from the row's top as from its sides; all four corners alike, not the row's followed in two and its own 6 in the
/// others (the user, 2026-10-26). Its words its half in from its end, as a capsule field's are (@sf.input's), not 6 in
/// where the title's were (the user, 2026-10-26: 离首字太近). Its sides where its list stands (`at`): in a side column a
/// row's words' (band_pad_in); across the whole screen the ladder's inset, 8, as #3806 (5b8b71713d) made it (the user,
/// 2026-11-09, asked a phone's search fields back to 12, not this).
fn rename_box(at : @sf.ListAt) -> @ui.Style {
  let d = @ui.capsule_in(@sf.row_corner, rename_h)
  let words_in = match at {
    Side | Tape => @sf.band_pad_in(at)
    Whole => @sf.corner_inset
  }
  let side = words_in - d
  let over = @sf.row_top_in_y - d
  rename_look.then(
    @ui.style(
      px=@sf.room_of(rename_words_in),
      mx=@sf.room_of(-side),
      mt=@sf.room_of(-over),
      mb=@sf.room_of(over - rename_taller),
    ),
  )
}

///|
// kept across runs: a value (no field of it changes)
let rename_look : @ui.Style = @ui.css("w=Full h=S6 radius=Full bg=Bg border=B0_5 justify=JCenter")

///|
/// Its height (h=S6).
let rename_h : Double = 24.0

///|
/// Its words in from either end: its half, as a capsule field's are.
let rename_words_in : Double = rename_h / 2.0

///|
let rename_taller : Double = 4.0

///|
let rename_size : Double = 13.0

///|
let rename_line : Double = 24.0

///|
/// The rows of the list in view as last drawn, in order (the chat beside one archived goes to the next of them).
// kept across runs: said by the list in view as it is drawn
let listed : Ref[Array[ChatItem]] = Ref([])

///|
/// Archives a row's chat: its 归档 key, its menu's, its swipe;
/// one keeping watch only once asked, in the core's words (its swipe also one at work: `ask`, the core's swipeAsk). Its chat in view goes to
/// the chat after it in the list (else before it; else the list alone) at once. `here` (from a row of a list made
/// once): said where its row was, by what its swipe uncovers there, with its 撤销 (archived_here: the core's list has it
/// gone), felt as something done; else said at once in a toast with its 撤销. Why not, when not (`failed` told then).
fn archive_row(
  src : Source,
  item : ChatItem,
  ask? : String? = item.watch_ask,
  here? : Bool = false,
  then? : () -> Unit = fn() {  },
  failed? : () -> Unit = fn() {  },
) -> Unit {
  let params : Map[String, Json] = {
    "station": Json::string(item.station),
    "session": Json::string(item.session),
    "archived": Json::boolean(true),
  }
  match item.thread {
    Some(th) => params["thread"] = Json::number(th)
    None => ()
  }
  let run = fn() {
    then()
    leave_archived(item)
    // (one its station never made: the core gives it up here, and there is nothing to ask back, so no 撤销)
    if item.pending {
      act(
        src,
        @sf.t("android-chat.archive.verb"),
        "",
        "chat.archive",
        Json::object(params),
        done=@sf.t("web-main.chat.archivedNamed", args=[("title", item.title)]),
        at_once=true,
        failed~,
      )
      return
    }
    if here {
      // (one at a time: another's 撤销 over as this one is said)
      archived_n.val += 1
      let n = archived_n.val
      // (its 撤销 asks it back and says nothing more: its row coming back over its tray says it; why not, act's toast)
      let undo = fn() {
        let back = params.copy()
        back["archived"] = Json::boolean(false)
        act(src, @sf.t("android-misc.archive.restoreWhat"), "", "chat.archive", Json::object(back))
      }
      // (its line not kept, a toast in its place: as from anywhere else)
      let toast = fn() {
        @sfbase.toast_later(
          @sf.t("web-main.chat.archivedNamed", args=[("title", item.title)]),
          action=@sf.t("android-chat.archived.undo"),
          run=@sfbase.archive_undo(src, params),
        )
      }
      archived_here.set(Some({ name: @sfbase.row_name(item), n, undo, toast, undone: false }))
      @ui.haptic(Confirm)
      act(src, @sf.t("android-chat.archive.verb"), "", "chat.archive", Json::object(params), failed=fn() {
        // (why not is act's toast; its row back in its place, nothing said there)
        match archived_here.untracked() {
          Some(a) if a.n == n => archived_here.set(None)
          _ => ()
        }
        failed()
      })
      return
    }
    act(
      src,
      @sf.t("android-chat.archive.verb"),
      "",
      "chat.archive",
      Json::object(params),
      done=@sf.t("web-main.chat.archivedNamed", args=[("title", item.title)]),
      done_action=@sf.t("android-chat.archived.undo"),
      done_run=@sfbase.archive_undo(src, params),
      at_once=true,
      failed~,
    )
  }
  match ask {
    Some(ask) =>
      @sf.confirm(@sf.t("android-chat.archive.ask", args=[("title", item.title)]), ask, @sf.t("android-chat.archive"), run)
    None => run()
  }
}

///|
/// A chat archived from a list's row while what its row uncovered stays in its place saying so (chat_row_node's tray):
/// the row's name, which archive it is (archived_n's), what asks it back, what says it in a toast with its 撤销 where
/// its list keeps no line for it (RowsMotion::said), whether 撤销 was pressed (its row on its way back over it).
priv struct ArchivedHere {
  name : String
  n : Int
  undo : () -> Unit
  toast : () -> Unit
  undone : Bool
}

///|
/// The chat archived last from a row, its 撤销 offered where its row was till that is pressed, its time is out
/// (toast_action_ms: chats_lists_node) or another is archived so (one at a time).
// kept across runs: put back by sidebar_reset
let archived_here : @signals.Signal[ArchivedHere?] = @signals.signal_by(None, same=fn(a, b) {
  match (a, b) {
    (Some(x), Some(y)) => x.n == y.n && x.undone == y.undone
    (None, None) => true
    _ => false
  }
})

///|
/// How many chats were archived from a row so far (which one archived_here says).
// kept across runs: put back by sidebar_reset
let archived_n : Ref[Int] = Ref(0)

///|
/// Away from an archived chat's page if it is the one in view: to its neighbour in the list, else the list alone.
fn leave_archived(item : ChatItem) -> Unit {
  let open = match app.nav.top() {
    Chat(r) => @sfbase.row_is(item, r)
    _ => false
  }
  if !open {
    return
  }
  let rows = listed.val
  let at = rows.search_by(fn(i) { i.station == item.station && i.id == item.id })
  let next = match at {
    Some(k) if k + 1 < rows.length() => Some(rows[k + 1])
    Some(k) if k > 0 => Some(rows[k - 1])
    _ => None
  }
  match next {
    Some(n) => open_page(Chat(row_ref(n)))
    None => (@sfbase.shell.val.home)()
  }
}

///|
/// Let go past this share of its width (or flung left), a swiped row is archived.
let archive_at_share : Double = 0.35

///|
/// How fast a fling left must be (points per ms) to archive a row that went at least `fling_from_share` of the line
/// across: a deliberate flick, not the sideways drift of a finger scrolling the list.
let fling_speed : Double = 1.0

///|
/// How far towards the line (`archive_at_share`) a row flung left must have gone for the fling to archive it.
let fling_from_share : Double = 0.5

///|
/// Whether a row `w` wide let go `at` across (to the left: negative), its finger going `vx` (points per ms), is
/// archived: landing past the line on from that speed (@ui.lands_past), or flung left from past `fling_from_share` of
/// the way to it.
fn swipe_archives(at : Double, w : Double, vx : Double) -> Bool {
  let line = w * archive_at_share
  @ui.lands_past(at, vx, -line) || (vx < -fling_speed && at < -line * fling_from_share)
}

///|
/// Whether a finger moved (dx, dy) from where it went down on a row takes it for the row's swipe to archive: left
/// past the slop and plainly across (at most half as far up or down), so one scrolling the list that drifts a little
/// sideways as it sets off scrolls it.
fn swipe_claims(dx : Double, dy : Double) -> Bool {
  dx < -@ui.touch_slop() && dx.abs() > 2.0 * dy.abs()
}

///|
/// How long a swiped row's 归档 takes to fill in ink. Let go to archive, it goes off to the left on a Move as long as
/// what is left of its width, as fast as the finger let it go.
let swipe_fill_ms : Double = 140.0

///|
// kept across runs: a value (no field of it changes)
let swipe_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, wrap=false)

///|
/// Whether a row's title is being written in place (what the frame holds open meanwhile).
pub fn renaming() -> Bool {
  row_renaming.get() != ""
}

///|
/// Esc to a row's title being written in place: let be, the keyboard let go (`blur`). Whether there was one.
pub fn rename_escape(blur : () -> Unit) -> Bool {
  if row_renaming.untracked() == "" {
    return false
  }
  stop_rename()
  blur()
  true
}

///|
/// The chat in view's "…" (a menu from `from`): its items (chat_menu_of) shown.
pub fn open_chat_menu(
  src : Source,
  scope : String,
  r : ChatRef,
  extra : Array[@sf.MenuItem?],
  from~ : @sf.Beside,
  along? : @ui.Along = Start,
) -> Unit {
  ignore(scope)
  match chat_menu_waits.val {
    Some(w) => {
      chat_menu_waits.val = None
      w.end()
    }
    None => ()
  }
  // (its chat's whole row not answered yet, asked as its page opened and held while it is open (chat_whole_held): the
  // menu opened whole the moment it is, while what it was asked in stays as it was (sfbase's press_wait: the chat
  // left, the workspace switched or something else put up, it opens nothing; what it read is the page's, let go of
  // with it). The system's bars' … too, told once the frame's builds are over (sfdesk rail_native.mbt))
  let w = @sfbase.press_wait(fn() { chat_menu_whole(src, r, extra, share_from=fn() { from }, along~) is Some(_) }, fn() {
    match chat_menu_whole(src, r, extra, share_from=fn() { from }, along~) {
      Some(items) => @sf.menu(items, from~, along~)
      None => ()
    }
  })
  chat_menu_waits.val = if w.waiting() { Some(w) } else { None }
}

///|
/// What waits to open the chat's "…" asked before its chat's whole row was answered (open_chat_menu): ended as
/// another is asked, or the run ends; given up as what it was asked in goes (press_wait).
// kept across runs: put back by chat_rows_reset
let chat_menu_waits : Ref[@sfbase.PressWait?] = Ref(None)


///|
/// What the chat in view's "…" offers: what a row's menu offers (chat_menu_items) for its chat's whole row (the core's
/// `chatRow`, held while its page is open: @sfbase.chat_whole_held), else (an archived one, one its station does not
/// list) its link alone; `extra` the page's own (chat_extra_items). None while that is not answered: what opens it
/// waits for it (open_chat_menu). Apart from showing them: the system's bars take them as a menu of their own
/// (rail_native.mbt bar_chat). `scope`: the workspace in view (the row is its station's own).
pub fn chat_menu_of(
  src : Source,
  scope : String,
  r : ChatRef,
  extra : Array[@sf.MenuItem?],
  share_from~ : () -> @sf.Beside,
) -> Array[@sf.MenuItem?] {
  ignore(scope)
  chat_menu_whole(src, r, extra, share_from~).unwrap_or([])
}

///|
/// chat_menu_of's items, None while its chat's whole row is not answered.
fn chat_menu_whole(
  src : Source,
  r : ChatRef,
  extra : Array[@sf.MenuItem?],
  share_from~ : () -> @sf.Beside,
  along? : @ui.Along = Start,
) -> Array[@sf.MenuItem?]? {
  let held = @sfbase.chat_whole_held(src, r)
  let found : ChatItem? = match (held.value, held.error) {
    (Some(Object(_) as v), _) => Some(@sfbase.chat_item(v))
    (Some(_), _) | (_, Some(_)) => None
    _ => return None
  }
  let items : Array[@sf.MenuItem?] = match found {
    Some(item) => chat_menu_items(src, item, share_from~, page=extra, along~)
    None => {
      let link = @sfbase.chat_link(r.station, r.session)
      let shared : Array[@sf.MenuItem?] = []
      if link != "" {
        shared.push(
          Some(
            @sf.menu_item_of(@sf.t("web-main.chat.copyLink"), icon="copy", fn() {
              @sfbase.copy_chat_link(r.title, link)
            }),
          ),
        )
      }
      shared.append(extra)
      share_menu(shared, share_from, along~)
    }
  }
  let reports = feedback_reports(src, r)
  if reports.length() > 0 {
    if items.length() > 0 {
      items.push(None)
    }
    for f in reports {
      let fv = Some(f)
      let id = text(fv, "id")
      items.push(
        Some(
          @sf.menu_item_of(@sf.t("web-main.feedback.menu", args=[("label", text(fv, "label"))]), icon="said", fn() {
            open_feedback(src, r, id)
          }),
        ),
      )
    }
  }
  Some(items)
}

///|
/// What shares a chat or takes it elsewhere (`shared`), in its menu: one item, 分享, its own menu from `share_from`, where
/// there are two or more; else as they are.
fn share_menu(shared : Array[@sf.MenuItem?], share_from : () -> @sf.Beside, along? : @ui.Along = Start) -> Array[@sf.MenuItem?] {
  if shared.length() < 2 {
    return shared
  }
  [
    Some(
      @sf.menu_item_of(@sf.t("web-main.chat.share"), icon="share", further=true, fn() {
        @sf.menu(shared, from=share_from(), title=@sf.t("web-main.chat.share.title"), along~)
      }),
    ),
  ]
}

///|
/// What the chat's page's menu has beyond the list's own (`chat`, the core's view of it): as a row's (share_items), from
/// its page's view.
pub fn chat_extra_items(src : Source, r : ChatRef, chat : Json?) -> Array[@sf.MenuItem?] {
  share_items(
    src,
    r,
    opt_number(field(chat, "thread"), "id"),
    may_share=flag(field(chat, "xshare"), "may"),
    may_publish=flag(field(chat, "publish"), "may"),
    slack_url=text(chat, "slackUrl"),
    slack_app=text(chat, "slackApp"),
    feishu_url=text(chat, "feishuUrl"),
    comma_url=text(chat, "commaUrl"),
    comma_app=text(chat, "commaApp"),
  )
}

///|
/// What is done with chat `r` (its `thread`) beyond the list's own, in a row's menu and its page's "…" alike: 分享给其他
/// workspace, 分享图片, 在 Slack 打开, 在飞书打开 or 在 Comma 打开, each where the viewer may.
fn share_items(
  src : Source,
  r : ChatRef,
  thread : Double?,
  may_share~ : Bool,
  may_publish~ : Bool,
  slack_url~ : String,
  slack_app~ : String,
  feishu_url~ : String,
  comma_url~ : String,
  comma_app~ : String,
) -> Array[@sf.MenuItem?] {
  let items : Array[@sf.MenuItem?] = []
  if may_share {
    items.push(
      Some(
        @sf.menu_item_of(@sf.t("web-pages.chat.xshare"), icon="users", fn() {
          open_xshare(src, r, thread, from=Unanchored)
        }),
      ),
    )
  }
  match thread {
    Some(th) if may_publish =>
      items.push(
        Some(
          @sf.menu_item_of(@sf.t("web-pages.chat.shareImage"), icon="image-upload", fn() { open_publish(src, r, th) }),
        ),
      )
    _ => ()
  }
  if slack_url != "" {
    items.push(
      Some(
        @sf.menu_item_of(@sf.t("web-pages.chat.openInSlack"), icon="external", fn() {
          if !@sfbase.open_slack(slack_app, slack_url) {
            @sfbase.toast_later(@sf.t("android-chat.link.failed"))
          }
        }),
      ),
    )
  }
  if feishu_url != "" {
    items.push(
      Some(
        @sf.menu_item_of(@sf.t("web-pages.chat.openInFeishu"), icon="external", fn() {
          if !@ui.open_url(feishu_url) {
            @sfbase.toast_later(@sf.t("android-chat.link.failed"))
          }
        }),
      ),
    )
  }
  if comma_url != "" || comma_app != "" {
    items.push(
      Some(
        @sf.menu_item_of(@sf.t("web-pages.chat.openInComma"), icon="external", fn() {
          if !@sfbase.open_slack(comma_app, comma_url) {
            @sfbase.toast_later(@sf.t("android-chat.link.failed"))
          }
        }),
      ),
    )
  }
  items
}
