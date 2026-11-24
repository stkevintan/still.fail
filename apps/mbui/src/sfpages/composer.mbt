// Where people write to a chat on the desktop (still.fail web/src/Chat.tsx ComposerView, ComposerTools, useComposerText's
// field, ComposerExtras, sendDraft; styles/composer.css.ts, Chat.css.ts composerText, composerToolbar, sendBtn,
// attachBtn, composerFiles, composerChoices, chatError; NewChat.css.ts's frosted box; dock.css.ts's width): a frosted
// capsule that grows into a box with its text, ＋ and send at its ends; opened (focused, written in, a file or a quote
// waiting, a new chat's roomy one) the text above and its row of ＋, the page's choices and send under it, the quotes
// and files waiting over the text. What it holds is the draft as the core keeps it (sfbase's compose.mbt). Enter sends,
// ⇧Enter starts a line; with nothing typed ↑ / ↓ go to the chat above or below; a file picked, pasted or carried in goes
// up to the chat's station at once.

///|
/// What the composer writes to and how it shows (ComposerProps): its station (where its files go up), its draft's key,
/// its chat's session (typing warms its agent; the `@` menu leaves it out; "" none), what its field says while empty,
/// the page's choices in its row (a new chat's), what it says before send and the control for it beside that (a chat's
/// 抄送), laid out roomy (its text over its row even for one line), locked (it takes words, nothing goes), its station
/// offline (no file taken in).
pub(all) struct ComposerSpec {
  station : String
  draft : String
  session : String
  placeholder : String
  toolbar : (() -> Unit)?
  /// what it says just before send (where a chat's messages are copied: each thread's mark, "slack" or "feishu", and
  /// its place), nothing to press: on one line and in its row once opened alike, in one place, going with send as it
  /// changes shape; empty nothing
  note : Array[(String, String)]
  /// what changes that, in its row once opened, just before what it says (a chat's 抄送); not on one line
  tail : (() -> Unit)?
  roomy : Bool
  locked : Bool
  offline : Bool
  warm_agent : Bool
}

///|
/// What the composer keeps of its own: when the cursor left it (it stays a box a moment, LET_GO_MS), when typing last
/// warmed the agent's runtime, each quote's comment field, how it was laid out as it was last drawn (a new chat's
/// roomy, or a chat's: another, it has moved between the pages), which chat it was for (another: switched to, the
/// cursor put in it), the archived chats being restored and why restoring one failed (by their drafts).
priv struct Composing {
  /// by draft: whether it stays a box a moment after its cursor left (each chat's own: another chat's composer built
  /// beside it, or switched to, holds nothing of it)
  let_go : @sf.LiveMap[String, Bool]
  /// by draft: whether the cursor was in it since let_go was last set: a box held for a cursor asked that has not come
  /// (kept for a modal layer over it, or on its way) hides nothing of it that a box it had the cursor in hides
  had_focus : Map[String, Bool]
  /// by draft: the moment the box it stayed after the cursor left was last let go of (let_go's end): a change of its
  /// own then
  let_go_at : Map[String, Double]
  warmed : Map[String, Int]
  /// words typed into its field since it was last built (told the core as they were typed: composer_text's
  /// `on_change`), for its build to warm the agent's runtime
  comments : Map[String, @ui.Field]
  /// each draft's page's time on top (Ctx::page_stint) as it was last switched to it there: switched to it again in
  /// the same stint (two chats' composers built at once, the one under sliding away as another's comes over it), it
  /// does not take the cursor again; only the page come on top does
  took : Map[String, Int]
  /// the moment it was last switched to another chat and the one it was for till then (the switch as it was first built:
  /// each build and frame made at that moment starts from that one, frame_body may build it twice)
  /// the moment it was last laid out for another page (a new chat's roomy in the page, a chat's at its foot) and how it
  /// was laid out, the choices in its row and whether the soft keyboard was up till then (as draft_was)
  /// as they were before what this build is built at changed them (draft_was, roomy_was): as this build has them
  /// whether the soft keyboard was up as it was last built (new_chat.mbt's `wide` reads the same)
  /// whether what waits in it now was in it before it was switched to it at this moment (the same draft): what is put
  /// in since comes in (held_coming), what a draft opened with is there at once
  /// whether this build is the one that switched it to another chat (the first built for it): what its field says
  /// while empty put at once, as it is then (composer_text)
  /// whether a notice over a chat's composer, new to it, comes in (chat_notices: the chat shown before, composer_was)
  /// what each notice over a chat's composer said as it was last drawn, by its key: drawn so as it leaves
  notices_said : Map[String, (String, (Int, String, String, Bool)?, (Int, String, Bool)?, String??, String, Array[(Int, String, Bool)], (String, String)?)]
  /// the page's choices in its row as it was last built, as they were before this build's page (roomy_was), and those
  /// of the page it came from that this one has not, while they leave (a new chat's, gone to its chat)
  restoring : @sf.LiveMap[String, Bool]
  restore_errors : @sf.LiveMap[String, String]
  /// the draft its field was last built for and whether it was empty then (composer_foot_room)
  /// till when words last sent from which draft held it (composer_held): its ground's ways said before then are theirs,
  /// none of the list's (composer_way_for_list)
  /// the draft, its field's lines and whether it was open as it was last built, and when its lines last changed while
  /// it stayed open (-inf: not since it opened): what words sent stop its shape for (composer_view)
  /// what its field says while empty as it was last drawn, till another is to be said and it has faded out
  /// (composer_text)
  hint_shown : @signals.Signal[String]
  /// the cursor asked into it in this frame (it has it from the next): what it says while empty is
  /// what it says with the cursor in it already
  taking : @signals.Signal[Bool]
  /// its 抄送 menu open (cc_chooser)
  mut cc_open : Bool
  /// the cache choice menu open for this notice (composer_notice)
  cold_open : @signals.Signal[String]
  /// the shape its field's hint was last shown on (composer_hint): changed, the hint waits till it is there
  /// whether it is a box or a capsule and how roomy: the moment that last changed, what it was till then and what it is
  /// as built now (composer_opening)
  /// the cursor asked into it as it is next drawn, on any screen (composer_take_focus), and whose: the drafts that
  /// begin so ("" any)
  mut wanted : Bool
  /// the workspace in view as it was last built: in another, how it was laid out before is another workspace's page's,
  /// nothing it goes on from
  /// each quote's card's colour as it was last drawn, by quote: where its ground sets out from as it is sent
  /// (flying_quotes)
  grounds : Map[String, Int64]
  /// what its box changed shape for and how as it was built in what composer_shaped builds (None till it is)
  /// each draft's composer's corner as it was last built, where it stands (its place's): what its chat's list keeps clear
  /// for it is worked out from (composer_least), not from another composer's built last (a chat beside another's)
  corners : @sf.LiveMap[String, Double]
}

///|
/// A page come on top that draws no composer (设置, a place, another page of the pane): how the composer was last laid
/// out is no page's it goes on from as it is built again (a new chat's in the page, gone to 设置 and then to a chat, is
/// not flown from), laid out where it is at once (sfdesk's page_switch_to), its hint there as it is (no shape it had
/// before to come back from: composer_hint), and as at rest: the box it kept a moment after the cursor left let go of
/// (the cursor went with the page; no box held for it on a page with none, to fold to a capsule later on the next).
pub fn composer_page_left() -> Unit {
  composing.let_go.clear()
  composing.had_focus.clear()
}

///|
/// The cursor into the composer as it is next drawn, with touch too (its keyboard up): what opened it is for
/// writing (新建对话: pengxiao, 2026-10-25). `drafts`: only into one whose draft begins so (a new chat's, "new:"), not
/// into the one still drawn while the page it was asked for waits to come: that one opened then, to be let go of as the
/// new one came, was a box set out for nothing.
pub fn composer_take_focus(drafts? : String = "") -> Unit {
  ignore(drafts)
  composing.wanted = true
}

///|
/// What was refused as it is (编辑 under it) taken back into draft `key` to be written again, dropped from the outbox by
/// `discard` once it is: its words after what the draft holds already, put in its field as well as told (the core keeps
/// no new `rev` for `composer.text`: told alone, the field's own words were told back over them as the composer was next
/// built), its quotes the draft does not hold yet quoted again, the cursor in it.
pub fn outbox_edit(src : Source, key : String, now : Outgoing, discard : () -> Unit) -> Unit {
  let w = @signals.untracked(fn() { writing(src, key) })
  let held = @signals.untracked(fn() { w.text.get() })
  let merged = if held.trim() == "" {
    now.text
  } else if now.text.trim() == "" {
    held
  } else {
    held.trim_end().to_owned() + "\n" + now.text
  }
  w.field.set(merged)
  writing_text(src, w, merged)
  let quoted = @signals.untracked(fn() { w.quotes.get() })
  for q in now.quotes {
    let there = quoted.iter().any(fn(x) {
      let o = Some(x)
      text(o, "ts") == q.ts && text(o, "text") == q.text && text(o, "author") == q.author
    })
    if !there {
      writing_quote(src, w, {
        "author": Json::string(q.author),
        "text": Json::string(q.text),
        "comment": Json::string(q.comment),
        "ts": Json::string(q.ts),
        "role": Json::string(q.role),
      })
    }
  }
  w.field.focus()
  composer_take_focus()
  discard()
}

///|
let composing : Composing = {
  let_go: @sf.LiveMap::new(),
  had_focus: {},
  let_go_at: {},
  warmed: {},
  comments: {},
  took: {},
  notices_said: {},
  restoring: @sf.LiveMap::new(),
  restore_errors: @sf.LiveMap::new(),
  hint_shown: @signals.signal("", same=fn(a, b) { a == b }),
  taking: @signals.signal(false, same=fn(a, b) { a == b }),
  cc_open: false,
  cold_open: @signals.signal("", same=fn(a, b) { a == b }),
  wanted: false,
  grounds: {},
  corners: @sf.LiveMap::new(),
}

///|
fn composing_reset() -> Unit {
  comment_rows_live.clear()
  composer_foot_way.val = None
  composer_width_last.val = ("", "", 0.0, 0.0)
  composing.let_go.clear()
  composing.had_focus.clear()
  composing.let_go_at.clear()
  composing.warmed.clear()
  composing.comments.clear()
  composing.grounds.clear()
  composing.took.clear()
  composing.notices_said.clear()
  composing.restoring.clear()
  composing.restore_errors.clear()
  ref_keyed.val = ""
  composing.cc_open = false
  composing.cold_open.set("")
  composing.wanted = false
  composing.hint_shown.set("")
  composing.taking.set(false)
  composing.corners.clear()
  composing_node_reset()
}

///|
/// The composer's text field (its words, a flight's from: flight.mbt), its box, what is in it.
pub let composer_field_key : String = "composer/field"

///|
/// `g`, put into draft `w` on `station` from outside its composer (sfbase's compose_given.mbt), taken into it now,
/// whichever view draws it: files the system's picker answered and files shared into the app go up (none where it takes
/// no files: `no_files`); a message's file quoted from its menu (sfpages menus.mbt) a quote with its file in its card; a
/// picture marked for this chat (a service's page, an image viewed) going up with a quote per mark, what is said of it
/// its comment (a page's mark's screenshot as its quote's picture, an image's as a file beside them); words a
/// visualization asked to send after what is written; a 文件 row by its path, or as a file where the chat takes what is
/// dragged in so.
fn given_into(src : Source, station : String, w : Writing, no_files : Bool, g : Given) -> Unit {
  match g {
    Picked(list) | Shared(list) =>
      if !no_files {
        for f in list {
          writing_add_picked(src, w, station, f)
        }
      }
    Quoted(author, ts, role, file) =>
      if !no_files {
        writing_quote(
          src,
          w,
          {
            "author": Json::string(author),
            "text": Json::string(text(Some(file), "name")),
            "ts": Json::string(ts),
            "role": Json::string(role),
          },
          file~,
        )
      }
    Followed(words) => {
      let said = followed_words(w, words)
      w.field.set(said)
      writing_text(src, w, said)
      w.field.focus()
    }
    // (a PDF's or another file's words and notes, as the viewer shows them: quotes alone, its file already the chat's)
    Marked(_, _, quotes, "pdf" | "file" as role) =>
      for q in quotes {
        writing_quote(src, w, {
          "author": Json::string(q.0),
          "text": Json::string(q.1),
          "comment": Json::string(q.2),
          "role": Json::string(role),
        })
      }
    Marked(name, bytes, quotes, kind) =>
      if !no_files {
        @signals.start_batch()
        if kind != "page" {
          writing_add(src, w, station, name, bytes)
        }
        for q in quotes {
          let quote : Json = {
            "author": Json::string(q.0),
            "text": Json::string(q.1),
            "comment": Json::string(q.2),
            "role": Json::string(kind),
          }
          if kind == "page" {
            writing_quote(src, w, quote, picture=(station, name, bytes))
          } else {
            writing_quote(src, w, quote)
          }
        }
        @signals.end_batch()
      }
    Dropped(d) =>
      if !no_files {
        writing_drop(src, w, station, [dropped_of(d)], drops_as_files(src, w.key))
      }
  }
}

///|
/// What draft `w` says once a visualization's `words` are put after what is written in it (a line between).
fn followed_words(w : Writing, words : String) -> String {
  let now = w.field.text()
  if now.trim() == "" {
    words
  } else {
    now.trim_end().to_owned() + "\n" + words
  }
}

///|
/// Whether what is carried into draft `key` goes as files (the chat's own choice, else the device's: prefs
/// `dropFiles`, `dropAs`), not named by its path.
pub fn drops_as_files(src : Source, key : String) -> Bool {
  let prefs = src.topic("prefs", {}).get().value
  match field(field(prefs, "dropFiles"), key) {
    Some(True) => true
    Some(False) => false
    _ => text(prefs, "dropAs") == "file"
  }
}

///|
/// A station's file or folder carried in: which station has it and where, and where it is in
/// that station's drive.
pub fn dropped_of(d : Dragged) -> Json {
  {
    "name": Json::string(d.name),
    "size": Json::number(d.size),
    "ref": {
      "station": Json::string(d.station),
      "stationName": Json::string(d.station_name),
      "path": Json::string(d.abs),
      "dir": Json::boolean(d.dir),
    },
    "drive": { "station": Json::string(d.station), "root": Json::string(d.root), "path": Json::string(d.path) },
  }
}

///|
/// Files the system's picker answered for draft `key`, given to its composer (sfbase's draft_give).
fn picked_into(key : String, files : Array[@hostapi.Picked]) -> Unit {
  if files.is_empty() {
    return
  }
  @sfbase.draft_give(key, Picked(files))
}

///|
/// The system's file picker for draft `w`: what is picked wakes its composer as the host's event tells it (`picked_into`).
pub fn pick_files(w : Writing) -> Unit {
  let key = w.key
  @ui.pick(Files, on_got=fn(files) { picked_into(key, files) }) |> ignore
}

///|
/// A file waiting's picture, if it is drawn as one: the bytes picked or pasted here, else (a draft kept, read again as
/// the app starts) an image's as the device keeps it (`composer.picture`), "" while that is read, or a video's put up
/// here while its first frame is read; None for any other file, and an image the device keeps none of (drawn as a file).
fn waiting_picture(src : Source, w : Writing, v : Json?) -> String? {
  let id = text(v, "id")
  match writing_pictures.get(id) {
    Some(picture) => Some(picture)
    None if file_kind(text(v, "name")) == "image" && waiting_as(v) is AnyFile =>
      match (src.draft_picture)(w.key, id) {
        "!" => None
        kept => Some(kept)
      }
    None if file_kind(text(v, "name")) == "video" && @sfbase.writing_put_here(id) && waiting_as(v) is AnyFile => Some("")
    None => None
  }
}

///|
/// waiting_picture read by a node of the window's tree (the composer's and the board's made as nodes): told as the
/// picture picked here is kept or let go and as the device's kept one of a draft comes, where the map and the source's
/// read alone tell nothing.
fn waiting_picture_told(src : Source, w : Writing, v : Json?) -> String? {
  let id = text(v, "id")
  match @sfbase.writing_picture_told(id) {
    Some(picture) => Some(picture)
    None if file_kind(text(v, "name")) == "image" && waiting_as(v) is AnyFile =>
      match src.draft_picture_told(w.key, id) {
        "!" => None
        kept => Some(kept)
      }
    None if file_kind(text(v, "name")) == "video" && @sfbase.writing_put_here(id) && waiting_as(v) is AnyFile => Some("")
    None => None
  }
}

///|
/// Whether a file waiting is going up now (its tile darkened with a spinner, its card saying how far): not up, not
/// failed, nor a new chat's, which waits for its message (nothing going up yet).
fn going_now(v : Json?) -> Bool {
  field(v, "done") is None && text(v, "error") == "" && field(v, "waits") is None
}

///|
/// What a file waiting that is no picture is drawn as (waiting_card): a station's file named by its path, a link shared
/// in, pasted words, or any other file.
priv enum WaitingAs {
  ByPath
  Link
  Pasted
  AnyFile
}

///|
fn waiting_as(v : Json?) -> WaitingAs {
  let ref_ = field(v, "ref")
  match ref_ {
    Some(Object(_)) if text(ref_, "mode") != "file" => ByPath
    _ if field(v, "link") is Some(Object(_)) => Link
    _ if field(v, "pasted") is Some(Object(_)) => Pasted
    _ => AnyFile
  }
}

///|
/// Whether pasted words waiting can be put back as words (✎ on their card): while they are kept, and no chat is being
/// made for them.
fn restorable(w : Writing, v : Json?) -> Bool {
  field(field(v, "pasted"), "text") is Some(String(_)) && !w.starting.get()
}

///|
/// What a waiting file's ✕ is called: pasted words' their own, a link's or a file's by its name.
fn remove_label(v : Json?, name : String) -> String {
  if field(v, "pasted") is Some(Object(_)) {
    @sf.t("web-main.composer.removePaste")
  } else {
    match field(v, "link") {
      Some(Object(_)) as l => @sf.t("web-main.file.remove", args=[("name", text(l, "url"))])
      _ => @sf.t("web-main.file.remove", args=[("name", name)])
    }
  }
}

///|
/// How much of a waiting file the station has (its `sent` of its size), once it says.
fn gone_up(v : Json?) -> Double? {
  match field(v, "sent") {
    Some(Number(sent, ..)) => Some(sent / dmax(number(v, "size"), 1.0))
    _ => None
  }
}

///|
/// How long it stays a box after it loses the cursor (LET_GO_MS); how long its change of shape takes.
pub let let_go_ms : Double = 300.0

///|
/// Typing warms the agent's runtime at most once a minute.
let warm_every_ms : Double = 60000.0

///|
/// The words' size and line are the theme's (Type.input: the screen's), the most it grows to (480, or 40% of the window).
let text_most : Double = 480.0

///|
let text_window_share : Double = 0.4

///|

///|
/// ＋'s icon (Plus 18; send's is the theme's round glyph) and a picture's ↻ (18).
let plus_icon : Double = 18.0

///|
/// What is faint where it cannot be pressed (attachBtn :disabled: .4); send not ready: the text at 18% over the box's
/// ground; pointed at, the text at 82% over the canvas.
let faint : Double = 0.4

///|
/// Dragged over (composerBox[data-dragging]): the focus ring's colour at 8% over its ground.
let drag_tint : Double = 0.08

///|
/// How far in the capsule's round buttons stand (the theme's: keyboard and mouse's 32, a finger's 36) alone: 8.
let capsule_pad_alone : Double = 8.0

///|
/// Where the composer stands at a panel's foot (composer_place): how much further in than its box (composer_side) its
/// capsule stands from the panel's left, its right and its foot, and how far in its round buttons stand in it (as high
/// as it is there: capsule_h). Its box, opened, is as far in as makes it concentric with a panel's foot corner
/// (@sf.pane_foot_in), its `corner` what that makes it (@sf.pane_composer_corner), a card's alone.
pub(all) struct ComposerPlace {
  capsule_in : (Double, Double, Double)
  capsule_pad : Double
  corner : Double
}

///|
/// Standing in no panel's corners (ComposerPlace).
// kept across runs: a value (no field of it changes)
pub let composer_alone : ComposerPlace = {
  capsule_in: (0.0, 0.0, 0.0),
  capsule_pad: capsule_pad_alone,
  corner: @sf.card_corner,
}

///|
/// How wide the composer opened sets what is typed in it, at the foot of a pane `pane` wide (its box less its padding
/// and its words' room's sides: text_open's px=S2): where what the viewer sent breaks its lines too (its bubble's,
/// message.mbt mine_most).
pub fn composer_words_width(pane : Double) -> Double {
  composer_width(pane) - 2.0 * @sf.composer_pad - 2.0 * 8.0
}

///|
/// What went wrong (chatError: under the box, 32 in, 10 under it; fieldError's red).
// kept across runs: a value (no field of it changes)
let error_box : @ui.Style = @ui.css("w=Full px=S8 pt=S1 pb=S2_5")

///|
// kept across runs: a value (no field of it changes)
let composer_error_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Danger, leading=L5)

///|
/// The files of a draft still going up as it is sent (composer.ts take's `uploads`: neither up nor failed, nor a link
/// or a file named by its path, which go as words), its quotes' own pictures among them.
fn going_files(w : Writing) -> Array[Json] {
  @sfbase.writing_files(w).filter(fn(f) {
    let v = Some(f)
    field(v, "done") is None &&
    text(v, "error") == "" &&
    field(v, "link") is None &&
    text(field(v, "ref"), "mode") != "path"
  })
}

///|
/// The files of a draft that are up, as its message has them (its quotes' own pictures among them): one put up from
/// here naming its upload (`upload`), as the core's row does (file_key).
fn up_files(w : Writing) -> Array[Json] {
  @sfbase.writing_files(w).filter_map(fn(f) {
    match field(Some(f), "done") {
      Some(Object(done)) if @sfbase.writing_put_here(text(Some(f), "id")) => {
        let a = done.copy()
        a["upload"] = Json::string(text(Some(f), "id"))
        Some(Json::object(a))
      }
      done => done
    }
  })
}

///|
/// The quotes of a draft as its message has them (composer.ts sentQuote): what is said about each trimmed, its own
/// picture named as its file goes.
fn sent_quotes(w : Writing) -> Array[Json] {
  w.quotes.get().map(fn(q) {
    let v = Some(q)
    let own = field(v, "own")
    let file = match field(own, "done") {
      Some(done) if text(Some(done), "name") != "" => text(Some(done), "name")
      _ => text(own, "name")
    }
    Json::object({
      "author": Json::string(text(v, "author")),
      "text": Json::string(text(v, "text")),
      "comment": Json::string(text(v, "comment").trim(chars=" \n\t").to_owned()),
      "ts": Json::string(text(v, "ts")),
      "role": Json::string(text(v, "role")),
      "file": Json::string(file),
    })
  })
}

///|
/// What a file waiting is in the message it goes with (file_key: one put up from here, or one with its picture here
/// still going up (`going`: an image, a video), its upload; any other its path), "" none.
fn flying_key(v : Json?, going : Bool, pictured : Bool) -> String {
  let id = text(v, "id")
  match field(v, "done") {
    Some(_) if @sfbase.writing_put_here(id) => @sfbase.upload_path(id)
    Some(done) => text(Some(done), "path")
    None if going && pictured => @sfbase.upload_path(id)
    None => ""
  }
}

///|
/// Words sent into chat `r` (`v` its view, `rk` its station and session) from draft `w`, in its list already as `row`
/// (sent_local): what the core takes off the draft (`composer.take`) goes (`chat.send`), whichever view drew the
/// composer. Not taken in at all (the core refused it, or went away with it): back in the composer unless something new
/// is written there, saying why; one the station did not take waits in the outbox, which says so.
fn sent_into_chat(src : Source, r : ChatRef, v : ChatView, w : Writing, rk : String, row : String) -> Unit {
  writing_take(src, w, fn(taken) {
    guard taken is Some(_) else {
      sent_local_gone(rk, row)
      return
    }
    let to = match v.thread {
      Some(th) => ToThread(th)
      None => ToSession(r.session)
    }
    send_taken(src, r.station, to, taken.unwrap(), fn(said) {
      match said {
        // (gone for good: what it took of the draft, its files' bytes, let go of)
        SentTaken => @sfbase.writing_committed(w)
        SentRefused(e) | SentKept(e) => {
          sent_local_gone(rk, row)
          @ui.haptic(Reject)
          let why = @sf.t("web-main.draft.notSent", args=[("error", e)])
          if said is SentRefused(_) {
            writing_restore(src, w, why, unless_written=true)
          } else {
            // (in the outbox, which sends it: never put back, its files' bytes let go of as one taken)
            @sfbase.writing_committed(w)
            toast_later(why)
          }
        }
      }
    })
  })
}

///|
/// How long the composer takes to open from a capsule or to be let go to one: its field passing by its ＋ and send is
/// kept off them on this clock (composer_hint_wbtest).
pub let composer_shape_ms : Double = 300.0

///|
/// Whether the composer's 抄送 menu is open now (cc_chooser).
pub fn composer_cc_open() -> Bool {
  composing.cc_open
}

///|
// kept across runs: a value (no field of it changes)
let cc_place : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let cc_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, wrap=false, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let cc_words_lit : @ui.TextStyle = cc_words.then(@ui.text_style(color=Fg))

///|
// kept across runs: a value (no field of it changes)
let cc_note_box : @ui.Style = @ui.css("row px=S2 gap=S2 align=ACenter")


///|
/// How far a chat's composer stands from the foot of a pane `pane` wide at rest (composer_foot_in).
fn composer_foot_at(pane : Double) -> Double {
  if composer_across(pane) {
    composer_side()
  } else {
    composer_foot_wide
  }
}

///|
/// How far under the composer its room is since a page's way set it off (composer_foot_in), and the way it was on as it
/// was last asked ("" none) and when that is there: none till then, and none once the window takes the pane across with no way going.
let composer_foot_way : Ref[(@motion.Anim, String, Double)?] = Ref(None)

///|
/// Draft, page_way id, starting pane width, and starting composer width (composer_width_in); reset by composing_reset.
// kept across runs: reset by composing_reset
let composer_width_last : Ref[(String, String, Double, Double)] = Ref(("", "", 0.0, 0.0))

///|
/// Width of a composer in a tree node `w` wide while its column is on `c` (`@sfbase.column_laid`): smoothly interpolated
/// between `c.laid` and `c.toward` so its edges never hit the piecewise clamp corner at `composer_most` mid-flight.
fn composer_width_on(w : Double, c : @sfbase.ColumnLaid) -> Double {
  if c.toward_by <= 0.0 || (c.toward - c.laid).abs() <= 0.5 {
    composer_width(w)
  } else {
    let cw0 = composer_width(c.laid)
    let cw1 = composer_width(c.toward)
    cw0 + (cw1 - cw0) * c.toward_by
  }
}

///|
/// Whether a chat's composer reaches across a pane `pane` wide, as far from its sides as from its foot
/// (composer_foot_in), not narrower than it in its middle.
fn composer_across(pane : Double) -> Bool {
  composer_width(pane) >= pane - 2.0 * composer_side() - 0.5
}

///|
let composer_foot_wide : Double = 16.0

