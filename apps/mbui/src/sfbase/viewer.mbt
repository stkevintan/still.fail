// A file of a chat opened over the whole screen (still.fail apps/android chat/screens/FilePreview.kt, VideoViewer.kt,
// FileKinds.kt kindOf, ChatFiles.kt FileData; web/src/FilePreview.tsx): images to zoom (a double tap, the bar's − and
// +, the wheel) and pan (mbui's @motion.Zoom); videos played by the system's player (a native view over the
// canvas, src/ui/native.mbt), its bytes read through the core a part at a time (`station.file.part`); PDFs drawn by the
// system page by page; HTML in a page of its own (a native web view: its scripts on, nothing of the app's reachable);
// Markdown rendered; CSV as a table; code and text as they are. Anything else says it cannot be shown and offers the
// download. One bar floats at the top with its name and tools. Back (or ×) closes it; a picture closes as well by a
// tap on it, a finger taking it down or a trackpad's two going down it (darksky, 2026-11-15).
//
// An image or a video flies from the chat's thumbnail and back into it; a video closed
// so keeps the frame it was left at, which its thumbnail shows and where it goes on from when opened again
// (FileViewers.frames). Its bytes stream (the Android app reads it whole first): a finger along its timeline puts its
// player in a mode of seeks one after another (NativeView::scrub), and the host keeps what it read.
//
// Not yet, against the Android app: pinching on iOS (no second finger told there yet). The bars are frosted glass over
// what the app draws (a picture, a document); over a native view (a video, a page) a solid tint, as it cannot be
// blurred.


///|
pub fn pv(key : String) -> String {
  tr(key)
}

///|
pub fn pv_fill(key : String, args : Array[(String, String)]) -> String {
  let w = @sf.t(key, args~)
  if w != key {
    return w
  }
  let mut s = pv(key)
  for a in args {
    s = s.replace_all(old="{" + a.0 + "}", new=a.1)
  }
  s
}

// ── what a file is ───────────────────────────────

///|
#derive(Eq)
pub(all) enum PKind {
  KImage
  KVideo
  KAudio
  KPdf
  KMarkdown
  KCsv
  KHtml
  KMbui
  KCode
  KText
}

///|
/// What a file shows as by its name: its kind (None: look at its bytes), its type, its language (code).
pub fn preview_kind(name : String) -> (PKind?, String, String) {
  let lower = @sf.lower(name)
  match lower {
    "dockerfile" => return (Some(KCode), "text/plain", "docker")
    "makefile" => return (Some(KCode), "text/plain", "make")
    "cmakelists.txt" => return (Some(KCode), "text/plain", "cmake")
    _ => ()
  }
  let ext = match lower.rev_find(".") {
    Some(i) if i > 0 => lower.exact_view(start=i + 1).to_owned()
    _ => ""
  }
  let media : (PKind, String)? = match ext {
    "png" => Some((KImage, "image/png"))
    "jpg" | "jpeg" => Some((KImage, "image/jpeg"))
    "gif" => Some((KImage, "image/gif"))
    "webp" => Some((KImage, "image/webp"))
    "svg" => Some((KImage, "image/svg+xml"))
    "avif" => Some((KImage, "image/avif"))
    "bmp" => Some((KImage, "image/bmp"))
    "ico" => Some((KImage, "image/x-icon"))
    "mp4" | "m4v" => Some((KVideo, "video/mp4"))
    "webm" => Some((KVideo, "video/webm"))
    "mov" => Some((KVideo, "video/quicktime"))
    "ogv" => Some((KVideo, "video/ogg"))
    "3gp" => Some((KVideo, "video/3gpp"))
    "3g2" => Some((KVideo, "video/3gpp2"))
    "mp3" => Some((KAudio, "audio/mpeg"))
    "m4a" => Some((KAudio, "audio/mp4"))
    "aac" => Some((KAudio, "audio/aac"))
    "wav" => Some((KAudio, "audio/wav"))
    "ogg" | "oga" | "opus" => Some((KAudio, "audio/ogg"))
    "flac" => Some((KAudio, "audio/flac"))
    "pdf" => Some((KPdf, "application/pdf"))
    "md" | "markdown" => Some((KMarkdown, "text/markdown"))
    "csv" => Some((KCsv, "text/csv"))
    "tsv" => Some((KCsv, "text/tab-separated-values"))
    "html" | "htm" => Some((KHtml, "text/html"))
    "mbui" => Some((KMbui, "application/json"))
    "wasm" => Some((KMbui, "application/wasm"))
    _ => None
  }
  match media {
    Some((k, t)) => return (Some(k), t, if k == KHtml { "html" } else if ext == "mbui" { "json" } else { "" })
    None => ()
  }
  if ["txt", "text", "log", "out", "err", "lock", "bat", "cmd", "hex"].contains(ext) {
    return (Some(KText), "text/plain", "")
  }
  let language = match ext {
    "mjs" | "cjs" => "js"
    "mts" | "cts" => "ts"
    "h" | "m" => "c"
    "hh" | "hpp" | "cc" | "cxx" | "mm" => "cpp"
    "kts" => "kotlin"
    "yml" => "yaml"
    "zsh" | "sh" => "bash"
    "psm1" | "psd1" => "ps1"
    "patch" => "diff"
    "conf" | "cfg" => "ini"
    "env" => "dotenv"
    "gradle" => "groovy"
    "plist" | "svg" => "xml"
    "mbui" | "ipynb" | "jsonl" | "ndjson" => "json"
    "mbti" => "mbt"
    e => e
  }
  if code_languages.contains(language) {
    return (Some(KCode), "text/plain", language)
  }
  (None, "application/octet-stream", "")
}

///|
// kept across runs: a table, never written
pub let code_languages : Array[String] = [
  "ts", "tsx", "js", "jsx", "json", "jsonc", "json5", "py", "rs", "go", "java", "kt",
  "swift", "c", "cpp", "cs", "rb", "php", "bash", "fish", "ps1", "yaml", "toml", "xml",
  "sql", "css", "scss", "less", "html", "vue", "svelte", "lua", "dart", "diff", "ini",
  "dotenv", "groovy", "scala", "r", "pl", "ex", "exs", "erl", "hs", "ml", "clj", "zig",
  "nim", "proto", "graphql", "tex", "vim", "nix", "tf", "hcl", "docker", "make", "cmake",
  "asm", "wasm", "sol", "prisma", "astro", "mbt",
]

// ── the viewer's state ─────────────────────────────────────────────────

///|
/// Over this a file is not read into memory to be shown; above SHOW_LIMIT only its start
/// shows as text; a table shows TABLE_ROWS rows at most.
pub let big_file : Double = 16.0 * 1024.0 * 1024.0

///|
pub let show_limit : Int = 2 * 1024 * 1024

///|
pub let table_rows : Int = 2000

///|
/// Dark whatever the theme, as a viewer of pictures: its text, what is quieter, its canvas.
pub let dark_text : Int64 = 0xF4F4F5FFL

///|
pub let dark_muted : Int64 = 0xFFFFFF99L

///|
/// The file open, and how far it has got.
pub(all) struct Viewer {
  station : String
  /// the session that keeps it
  key : String
  file : Attachment
  /// its name at the station (the last part of its path)
  name : String
  /// a file of a station's drive (open_file), read by `drive.read`; None: a chat's, read by `station.file`
  drive : DriveFile?
  /// a file a message names by its path (`file.path`, as the agent wrote it), read by `file.open`, whatever it is now
  named : Bool
  kind : PKind?
  mime : String
  /// a file of no known kind: text (its first bytes UTF-8, no NULs)? None while asked
  sniffed : @signals.Signal[Bool?]
  sniffing : @signals.Signal[Bool]
  bytes : @signals.Signal[Bytes?]
  /// a chat's big image: what `bytes` holds is its station's preview (`station.file` with `preview`: at most 2048
  /// across), the image itself read in its place only as it is zoomed into, saved, shared or installed
  /// (Viewer::whole_due)
  previewed : @signals.Signal[Bool]
  /// zoomed in past fitted, as its zoom was last told (viewer_tree.mbt): what asks for the image itself in place of
  /// its preview
  zoomed_in : @signals.Signal[Bool]
  fetching : @signals.Signal[Bool]
  /// how much of it has come while it is read whole, and its whole size where the station says it (FileData.progress)
  got : @signals.Signal[(Double, Double?)?]
  error : @signals.Signal[String?]
  /// a file told of (not shown): asked for (to save)
  mut asked : Bool
  mut save_after : Bool
  /// …or to be handed to another app (分享: Viewer::ask_share), as its whole comes
  mut share_after : Bool
  /// …or to be put on the clipboard (复制: Viewer::ask_copy), as its whole comes
  mut copy_after : Bool
  /// …or to draw its marks onto its whole (标注完成: Viewer::finish_marks), as its whole comes
  mut marks_after : Bool?
  /// a chat's file asked to be downloaded by the core (downloads.mbt), said to it in the next frame (the old bars');
  /// told as it is asked (`asked_told`: the window's tree's viewer says it to the core then, and saves what was asked
  /// for to be saved as its whole comes, each once)
  mut download_asked : Bool
  asked_told : @signals.Signal[Int]
  /// …or to be installed (an APK)
  mut install_after : Bool
  /// the bars shown: till a tap (a click) hides them, and another brings them back (the user, 2026-10-28; a picture's
  /// tap closes it instead, darksky 2026-11-15); told as it
  /// changes (`awake_told`: what shows the bars follows it)
  mut awake : Bool
  awake_told : @signals.Signal[Int]
  /// a mouse's pointer along the top, where the bar is: there while it is, hidden or not
  mut near_bar : Bool
  zoom : @motion.Zoom
  vzoom : @motion.Zoom
  /// 源码 rather than 预览
  mut source : Bool
  /// told as `source` changes (Viewer::set_source): what shows it and what says it follow it
  source_told : @signals.Signal[Int]
  mut page : @ui.NativeView?
  mut pdf : @ui.Pdf?
  /// what is picked and marked in its PDF (viewer_pdf_marks.mbt)
  pdf_marks : PdfMarks
  /// what is marked in its Markdown file (viewer_md_marks.mbt)
  md_marks : MdMarks
  /// what is marked in its code or text lines (viewer_lines_marks.mbt)
  lines_marks : LinesMarks
  mut text : String?
  /// its words highlighted, a line each (code, or Markdown's source), read once: None until then, Some([]) when not
  mut colored : Array[Array[@ui.Run]]?
  /// whether they were coloured for the dark theme
  mut colored_dark : Bool
  /// code and text shown as they come, a part at a time (viewer_flow.mbt), once its first part is asked
  mut flow : Flow?
  /// told as its flow is begun (Viewer::read_on): what follows what it shows as it comes (its parts) follows it from then
  flow_told : @signals.Signal[Int]
  /// the image's key once its bytes are given
  mut image : String
  /// the preview image's key (`mem:preview-p/<id>`), distinct from the whole image's (`mem:preview/<id>`)
  mut preview_image : String
  /// drawn once (its way in set going), closed (only drawn going), how far it has faded in (0 … 1, a motion)
  mut started : Bool
  mut closing : Bool
  fade : @motion.Way
  // a finger on the stage: where it was last frame, how far it has gone
  mut held : Bool
  mut last_x : Double
  mut last_y : Double
  mut moved : Double
  // two fingers: how far apart and where between them last frame (0: none), whether this press pinched
  mut pinch_d : Double
  mut pinch_x : Double
  mut pinch_y : Double
  mut pinched : Bool
  /// a read of the video's file, logged the first times
  reads : @signals.Signal[Int]
  /// how a song's player stands, pinned for a fixture's shot
  mut pinned : @player.MediaStatus?
  /// what it steps through (an image): its chat's images, a folder's
  steps : Stepping
  /// Where this occurrence is in its chat, distinct from the file shared by other messages or quotes.
  at : String
  /// a finger moving it sideways to the one before or after (fitted, not zoomed)
  mut swiping : Bool
  /// a finger (fitted) taking it down to close it (Zoom::pull), or a trackpad's two doing so (`wheel_pulling`, how far
  /// across and down they have it: `pull_x`, `pull_y`)
  mut pulling : Bool
  mut wheel_pulling : Bool
  mut pull_x : Double
  mut pull_y : Double
  /// where the finger went down (in the window's terms; on the stage, `down_lx`, `down_ly`: the canvas's own)
  mut down_x : Double
  mut down_y : Double
  mut down_lx : Double
  mut down_ly : Double
  /// zoomed in, its left and its right edge in the stage as the finger went down (a fling on past one goes beside it)
  mut at_left : Bool
  mut at_right : Bool
  /// the finger came down on it flinging, and stopped it there: no tap
  mut caught : Bool
  /// where the strip was as the finger went down (a slide still going on caught there): what the swipe let go is
  /// measured from
  mut strip_down : Double
  /// a video opened again: where it was left (ms; -1 from its start), until its player is ready to go on from there
  mut start_at : Double
  /// a video closing into its thumbnail: the frame it shows being grabbed first (what it goes back with), and where
  /// it was then
  mut leaving_grab : Bool
  mut left_at : Double
  /// that frame, grabbed, while its picture is not decoded ("" none waited for): its player shown, paused, where it
  /// is till the picture can be drawn in its place (Viewer::left_with_picture)
  mut leaving_pic : String
  /// told as leaving_grab or leaving_pic changes (Viewer::grab_set): what is done at its going's end follows it
  grab_told : @signals.Signal[Int]
  /// a desktop's song: played in the player a drive's is, not the phone's strip
  mut media : @player.Media?
  /// a desktop's image put on the clipboard: how many times (its check shown a while after each)
  mut copied : Int
  /// how wide the floating bar has been (it never narrows once open: @sf.viewer_frame_bar)
  mut head_w : Double
  /// which opening of a viewer it is (the window's tree picks its node by it: viewer_tree.mbt)
  serial : Int
  /// drawn by a node of the window's tree (viewer_tree.mbt), not by the old view's layer
  mut in_tree : Bool
  /// how many layers of the window's tree it has been drawn in (viewer_node): the last the one it is in
  mut tree_layers : Int
  /// closed back into its thumbnail drawn by the window's tree (Viewer::shut): its picture's node let go of at once,
  /// flown back by the tree (viewer_tree.mbt's image_layer, film_shared)
  tree_back : @signals.Signal[Bool]
  /// its picture flown by the window's tree, from a thumbnail of a chat's page made as nodes or back into it
  /// (View::shared's `told`: Viewer::tree_way_told): its fade that flight's growing, its picture none of it
  tree_way : @signals.Signal[Bool]
  /// when that flight ends (the clock's ms), as it is told (Viewer::tree_way_told): told again as the flight goes on
  /// longer (the chat moved under it on its way back), what ends it following
  tree_way_end : @signals.Signal[Double]
  /// the fingers on its stage by their ids (Drag's `finger`), where each is now; how fast the one moving it goes, by
  /// its events' own moments; what calls off the hold waited for (its picture's menu)
  fingers : Map[Int, (Double, Double)]
  speed : @ui.Velocity
  mut hold_off : () -> Unit
  /// what calls off a tap's close waited for (a second tap zooms instead), and a trackpad's pull let go of (back, once
  /// its wheel rests)
  mut tap_off : () -> Unit
  mut wheel_off : () -> Unit
  /// how far the picture is lifted over the keyboard while marking (its way said as the keyboard or what is written
  /// changes, at that moment: viewer_tree.mbt)
  lift : @motion.Way
  /// a tab's beside a chat (viewer_tab.mbt), not the one over the whole window: its stage starts under the tab's own
  /// tools, nothing of the window's bars over it
  beside : Bool
  /// a film or a song played as its player opens (the whole window's always; a tab's only as the person opened it
  /// beside just now: viewer_tab.mbt's tab_asked), else there paused until its play key
  mut plays_now : Bool
  /// moved beside from the whole window's player before its own is made: the speed it played at, how loud, its sound
  /// off or not, its player made so (viewer_tab.mbt's play_asked)
  mut play_how : (Double, Double, Bool)?
}

///|
/// How many viewers have been opened: the next one's `serial`.
// kept across runs: only a count
let viewers_opened : Ref[Int] = Ref(0)

///|
/// A video closed back into its thumbnail keeps the frame it was left at: the
/// thumbnail shows it from then on, and opened again the video goes on from there. By the thumbnail's id (Viewer::id):
/// the frame's image, where it was (ms).
pub let pv_frames : Map[String, (String, Double)] = Map([])

///|
/// What a node of the window's tree read of pv_frames (pv_frame_track), by the thumbnail's id: told as its frame is kept
/// or let go, made as one is first read so, let go as nothing reads it any more. The old views' reads track nothing.
// kept across runs: let go with pv_frames (viewer's clear)
let pv_frames_told : Map[String, @signals.Signal[Int]] = Map([])

///|
/// The frame kept for thumbnail `id` read by a node: what reads it told as one is kept or let go.
fn pv_frame_track(id : String) -> Unit {
  let s = match pv_frames_told.get(id) {
    Some(s) => s
    None => {
      let s = @signals.signal(0)
      pv_frames_told[id] = s
      s
    }
  }
  s.get() |> ignore
}

///|
/// The frame kept for thumbnail `id` changed: told, where a node reads it.
fn pv_frame_tell(id : String) -> Unit {
  match pv_frames_told.get(id) {
    Some(s) =>
      if s.watched() {
        s.set(s.untracked() + 1)
      } else {
        pv_frames_told.remove(id)
      }
    None => ()
  }
}

///|
/// How many frames have been kept (each one's image a key of its own).
pub let pv_frames_n : Ref[Int] = { val: 0 }

///|
/// A frame kept is this many pixels at most on its longer side (the station's poster's, posters.ts SIDE).
pub let kept_frame_side : Double = 640.0

///|
/// A chat's video the station made no poster of (one from before posters, or with neither QuickLook nor ffmpeg), small
/// enough to read for it, or one waiting in a draft that the host has no picture
/// of: its first frame drawn here. A player of it made out of sight (never placed), its frame at 0 grabbed, then let
/// go; what it read of a chat's kept with the chat by the core, as the viewer's reads are. By the thumbnail's id: the
/// player while it grabs, and the frame's image ("" while it comes, "!" none to be had).
pub(all) struct FirstFrame {
  mut view : @ui.NativeView?
  mut picture : String
}

///|
pub let pv_first : Map[String, FirstFrame] = Map([])

///|
/// When each of pv_first was last asked for, by the thumbnail's id (pv_first_n's count).
// kept across runs: let go with pv_first (viewer's clear)
let pv_first_used : Map[String, Int] = Map([])

///|
// kept across runs: put back with pv_first (viewer's clear)
let pv_first_n : Ref[Int] = { val: 0 }

///|
/// How many nodes of the window's tree that grabbed each first frame (first_frame_by) show it, by the thumbnail's id:
/// never let go of while any does.
// kept across runs: let go with pv_first (viewer's clear)
let pv_first_shown : Map[String, Int] = Map([])

///|
/// First frame `id` asked for now; then those come to what they are (no player of theirs grabbing) beyond
/// pv_frames_max let go of, the least lately asked for first, never `id`: their picture too where nothing else is drawn
/// by it (a draft's file's, a message's sent from here, a thumbnail's, a viewer's), what showed it told (pv_first_told).
/// Asked for again, it is drawn again.
fn pv_first_asked(id : String) -> Unit {
  pv_first_n.val += 1
  pv_first_used[id] = pv_first_n.val
  let mut gone = false
  while pv_first.length() > pv_frames_max {
    let mut oldest = ""
    let mut when = 0
    for k, t in pv_first_used {
      guard k != id && pv_first.get(k) is Some(f) && f.view is None && !pv_first_shown.contains(k) else { continue }
      if oldest == "" || t < when {
        oldest = k
        when = t
      }
    }
    guard oldest != "" else { break }
    let picture = pv_first.get(oldest).map(fn(f) { f.picture }).unwrap_or("")
    pv_first.remove(oldest)
    pv_first_used.remove(oldest)
    gone = true
    if picture != "" &&
      picture != "!" &&
      !writing_pictures.values().any(fn(p) { p == picture }) &&
      !sent_pictures.values().any(fn(p) { p == picture }) &&
      !pv_first.values().any(fn(f) { f.picture == picture }) &&
      !preview_shown(picture) {
      @ui.forget_image(picture)
    }
  }
  if gone {
    first_told()
  }
}

///|
/// A player of chat video `a` (on `station`, kept by session `key`) reading it from the station a part at a time, for
/// its first frame (first_frame_node's).
fn first_player(src : Source, station : String, key : String, a : Attachment) -> @ui.NativeView {
  let (_, mime, _) = preview_kind(a.name)
  let params = fn() -> Map[String, Json] {
    let p : Map[String, Json] = {
      "station": Json::string(station),
      "key": Json::string(key),
      "name": Json::string(base_name(a.path)),
    }
    chat_keep(p, a.size)
    p
  }
  // (its parts read by the host's own reader where it has one, as the viewer's are: through the app, each part's
  // bytes were copied on the thread that draws, a frame held 75 ms on a phone, 2026-11-19)
  let direct = direct_part("station.file.part", params(), a.size)
  @ui.NativeView::video(mime, direct~, fn(offset, length, answer) {
    let p = params()
    p["offset"] = Json::number(offset)
    p["length"] = Json::number(length.to_double())
    stream_part(src, "station.file.part", p, a.size, answer)
  })
}

///|
/// The first frame of chat video `a` as first_frame has it, for a node of the window's tree `v` (a chat's things'
/// tile): what it shows read as it comes (an image's key, "" while it comes or where it is too big to read for it, "!"
/// when it could not be). The same grab as first_frame's (pv_first, by `id`): asked once at its moment, as an old
/// view's is once its frame is built; its answer taken as the host tells it (NativeView::grabs_told), none to be had as
/// the host says it has no player or one that cannot read it, or once its decoder has waited media_decode_wait_ms
/// from when all its bytes came (decode_stalled's): first_frame's rule, followed as it is told, not asked
/// each frame.
pub fn first_frame_node(v : @view.View, src : Source, station : String, key : String, a : Attachment, id : String) -> () -> String {
  first_frame_by(v, id, a.name, a.size, fn() { first_player(src, station, key, a) })
}

///|
/// The first frame of a video waiting in a draft here, by its bytes (bytes_first_frame's, for a node of the window's
/// tree `v`: a composer's tile made as nodes), `id` naming it, `name` its file's: as first_frame_node has a chat's.
pub fn bytes_first_frame_node(v : @view.View, id : String, name : String, bytes : Bytes) -> () -> String {
  let (_, mime, _) = preview_kind(name)
  first_frame_by(v, id, name, bytes.length().to_double(), fn() {
    @ui.NativeView::video(mime, fn(offset, length, answer) {
      let n = bytes.length()
      let from = if offset < 0.0 { 0 } else if offset > n.to_double() { n } else { offset.to_int() }
      let to = if length > n - from { n } else { from + length }
      answer(bytes[from:to].to_owned(), n.to_double(), false)
      fn() {  }
    })
  })
}

///|
/// first_frame_node's grab of the video `open` makes (`id` naming it, `name` its file's, `size` its bytes').
fn first_frame_by(v : @view.View, id : String, name : String, size : Double, open : () -> @ui.NativeView) -> () -> String {
  let picture = fn() {
    pv_first_told.get() |> ignore
    match pv_first.get(id) {
      Some(f) => f.picture
      None => ""
    }
  }
  // (shown by `v` while it is made: never let go of meanwhile, as what shows it would not grab it again)
  pv_first_shown[id] = pv_first_shown.get(id).unwrap_or(0) + 1
  v.owns(fn() {
    let n = pv_first_shown.get(id).unwrap_or(0) - 1
    if n > 0 {
      pv_first_shown[id] = n
    } else {
      pv_first_shown.remove(id)
    }
  })
  |> ignore
  if pv_first.get(id) is Some(f) && f.view is None {
    // (come to what it is before: asked for now, kept the latest)
    pv_first_asked(id)
  }
  if !pv_first.contains(id) {
    if size <= 0.0 || size > big_file {
      return picture
    }
    let f : FirstFrame = { view: None, picture: "" }
    pv_first[id] = f
    let n = open()
    if !n.here() {
      f.picture = "!"
      pv_first_asked(id)
      return picture
    }
    f.view = Some(n)
    v.at_moment(v.cause_at(), fn() { n.grab_frame(0.0) }) |> ignore
  }
  // (its decoder's wait, as it stands: let go as another is set or it is settled)
  let stall : Ref[() -> Unit] = Ref(fn() {  })
  let waiting = fn() {
    match pv_first.get(id) {
      Some(f) => f.view
      None => None
    }
  }
  v.reacts(
    fn() { waiting().map(fn(n) { (n.grabs_told(), n.state()) }) },
    fn(told) {
      guard told is Some(_) && pv_first.get(id) is Some(f) && f.view is Some(n) else { return }
      match n.grabbed() {
        Some(png) => first_settled(f, n, id, name, png)
        None =>
          if n.state() < 0 && !n.grabbing() {
            first_settled(f, n, id, name, b"")
          } else if n.state() == 2 && n.decode_since() >= 0.0 {
            (stall.val)()
            stall.val = v.at_moment(n.decode_since() + @player.media_decode_wait_ms, fn() {
              if f.view is Some(m) && physical_equal(m, n) {
                first_settled(f, n, id, name, b"")
              }
            })
          }
      }
    },
  )
  picture
}

///|
/// What a first frame came to (first_frame_node's): `png` its picture's (an image's key kept by `id`, as grab_first
/// keeps it), none: "!"; its player closed, what shows it told.
fn first_settled(f : FirstFrame, n : @ui.NativeView, id : String, name : String, png : Bytes) -> Unit {
  f.view = None
  if png.length() > 0 {
    let k = first_key(id, name)
    @ui.add_image(k, png)
    f.picture = k
  } else {
    f.picture = "!"
  }
  n.close()
  first_told()
  pv_first_asked(id)
}

///|
/// The key a first frame's picture is kept by (grab_first's).
fn first_key(id : String, name : String) -> String {
  "mem:pv-first/\{@ui.stable_hash(id)}/\{id.length()}/\{name}"
}

///|
/// How many first frames have come to what they are (grab_first's, first_frame_node's): what a node showing one reads,
/// told as any is.
// kept across runs: a count, only what changed is read of it
let pv_first_told : @signals.Signal[Int] = @signals.signal(0)

///|
/// A first frame come to what it is, told (pv_first_told).
fn first_told() -> Unit {
  pv_first_told.set(pv_first_told.untracked() + 1)
}

///|
/// Whether the thumbnail of `id` is a node of the window's tree drawn now (a chat's page made as nodes: its end of the
/// picture's flight that stays, View::shared's `stays`), to be flown back into by the tree.
fn tree_thumb_seen(id : String) -> Bool {
  match @ui.view_tree() {
    Some(tree) => tree.stays_seen(id)
    None => false
  }
}

///|
/// How far a thumbnail at `(y, h)` goes up (less than 0) or down to show whole between the chat's bar and its composer,
/// a little in from them (centred between them when it is taller than what they leave); 0 when nothing hides it.
fn route_lift(y : Double, h : Double, clear : (Double, Double)?) -> Double {
  match clear {
    Some((top, foot)) => {
      let (top, foot) = (top + lift_gap, foot - lift_gap)
      if h > foot - top {
        (top + foot) / 2.0 - (y + h / 2.0)
      } else if y < top {
        top - y
      } else if y + h > foot {
        foot - (y + h)
      } else {
        0.0
      }
    }
    None => 0.0
  }
}

///|
/// How far from the bar and the composer a thumbnail going out from under them stops.
let lift_gap : Double = 12.0

///|
/// The flight's way between thumbnail `from` (with clear band `clear`) and `to` (where the picture is on the stage):
/// the share of it that is the thumbnail's going out from under the bar or composer (none when nothing hides it), and
/// how far it goes in all (points: the going out, then the growing as far as its furthest going edge goes).
fn route_way(
  from : (Double, Double, Double, Double),
  clear : (Double, Double)?,
  to : (Double, Double, Double, Double),
  window : (Double, Double),
) -> (Double, Double) {
  let (x, y0, w, h) = from
  let raw_lift = route_lift(y0, h, clear)
  let lift = raw_lift.abs()
  let lift = if lift < 0.5 { 0.0 } else { lift }
  let y = y0 + (if lift > 0.0 { raw_lift } else { 0.0 })
  let (tx, ty, tw, th) = @motion.hero_seen_of(to, window.0, window.1)
  let grow = dmax(dmax((tx - x).abs(), (tx + tw - x - w).abs()), dmax((ty - y).abs(), (ty + th - y - h).abs()))
  (if lift > 0.0 { lift / (lift + grow) } else { 0.0 }, lift + grow)
}

///|
/// How the viewer's picture flies from a thumbnail of a chat's page made as nodes and back into it (View::shared's
/// `route`, said here, the app's: the user, 2026-11-17, 「应该让使用的地方去控制飞行轨迹和高度（层级）」): out from under
/// the chat's bar or composer at its own size first, as far as route_lift says, what of it is seen meanwhile no more
/// than what they leave clear (mbui's Tree::stays_bounds), then grown to where the viewer shows it, over all of the
/// page; one Move as long as all of it is far, the going out its share by how far it goes, the one handed to the other
/// (route_handed) so that nothing stops or sets off in a step where they meet. What is seen of the thumbnail opened as
/// it grows. `window`: the window's size. With it, how far what goes with the flight it is told of is at each moment
/// (its ground, a film's bars: Viewer::tree_way_told): none of it while the picture is going out from under the bar or
/// composer (still the page's, cut to what they leave clear), then in as it grows, to all of it at the viewer
/// (route_seen).
fn viewer_route(window : () -> (Double, Double)) -> (@view.FlightRoute, (Bool, (Double) -> Double) -> (Double) -> Double) {
  // (the going out's share of the way, as the flight set out last worked it out)
  let share = Ref(0.0)
  let stays_rect = fn(ends : @view.FlightEnds) { if ends.from_stays { ends.from } else { ends.to } }
  let other = fn(ends : @view.FlightEnds) { if ends.from_stays { ends.to } else { ends.from } }
  // (how far from the thumbnail `p` of the way is)
  let from_thumb = fn(ends : @view.FlightEnds, p : Double) { if ends.from_stays { p } else { 1.0 - p } }
  let route : @view.FlightRoute = {
    far: fn(ends) {
      let (s, far) = route_way(stays_rect(ends), ends.clear, other(ends), window())
      share.val = s
      far
    },
    place: fn(ends, p) {
      let (tx, ty, tw, th) = stays_rect(ends)
      let (out, grown) = route_handed(from_thumb(ends, p), share.val)
      let y = ty + route_lift(ty, th, ends.clear) * out
      let (ox, oy, ow, oh) = other(ends)
      (tx + (ox - tx) * grown, y + (oy - y) * grown, tw + (ow - tw) * grown, th + (oh - th) * grown)
    },
    opened: fn(ends, p) { route_handed(from_thumb(ends, p), share.val).1 },
    // (under the bar or the composer over its thumbnail while it slides out from under it, as it lay there, till it
    // is out: its slide not over, though it may have begun to grow)
    in_stays: fn(ends, p) { route_handed(from_thumb(ends, p), share.val).0 < 1.0 },
  }
  (route, fn(back, along) { fn(t) { route_seen(if back { 1.0 - along(t) } else { along(t) }, share.val) } })
}

///|
/// The least and most share of the way the viewer's flight goes out from under the bar or composer over
/// (route_handed): at least `route_out_least` so a short lift does not stop in a frame or two, and at most
/// `route_out_most` so a large lift (`s >= 0.5`) still finishes before the end and leaves room for the layer switch
/// and the viewer's ground and bars to fade in to 1.
let route_out_least : Double = 0.4

///|
let route_out_most : Double = 0.75

///|
/// Where along the flight's way from the thumbnail (0 … 1) the going-out stretch finishes (`out` reaches 1,
/// `in_stays` ends, and the viewer's ground begins to fade in).
fn route_out_end(s : Double) -> Double {
  dmin(route_out_most, dmax(2.0 * s, route_out_least))
}

///|
/// How far what goes with the viewer's flight (its ground, a film's bars) is `q` of the way from the thumbnail, its
/// going out `s` of it (route_handed): none while the picture is still going out from under the bar or composer, cut
/// to what they leave clear (the page not yet seen to go dim under what is still part of it), then at one pace from
/// `route_out_end(s)` to all of it (1.0) at the viewer.
fn route_seen(q : Double, s : Double) -> Double {
  let q = dmin(1.0, dmax(0.0, q))
  if s <= 0.0 {
    return q
  }
  let l = route_out_end(s)
  if q <= l {
    0.0
  } else {
    dmin(1.0, (q - l) / (1.0 - l))
  }
}

///|
/// How far gone out from under the bar or composer and how far grown from the thumbnail (each 0 to 1) the viewer's flight
/// is `q` of its way from the thumbnail, its going out `s` of the whole way by how far it goes (viewer_route). For
/// `2 * s <= route_out_most` its edge going furthest goes at the way's own pace all the way (`q = s * out + (1 - s) * grown`),
/// slowing to rest over `l = route_out_end(s)`. For larger `s` (`s < l`), `out` uses initial slope `l / s` so `s * out <= q`
/// everywhere without clamping `grown` to 0; for `s >= l`, it slides out linearly over `[0, l]` then grows over `[l, 1]`.
/// None to go out from (`s <= 0`): out all along, grown as far as the way.
fn route_handed(q : Double, s : Double) -> (Double, Double) {
  let q = dmin(1.0, dmax(0.0, q))
  if s <= 0.0 {
    return (1.0, q)
  }
  let l = route_out_end(s)
  if q >= l {
    let grown = if s >= l { (q - l) / (1.0 - l) } else { (q - s) / (1.0 - s) }
    return (1.0, dmin(1.0, dmax(0.0, grown)))
  }
  let u = q / l
  if s >= l {
    (u, 0.0)
  } else {
    let a = dmin(2.0, l / s)
    let out = a * u + (1.0 - a) * u * u
    (out, dmin(1.0, dmax(0.0, (q - s * out) / (1.0 - s))))
  }
}

///|
/// The viewer fading in and out where there is no thumbnail to grow from.
pub let pv_fade_ms : Double = 140.0

///|
/// How far a film's flight has come (its ground as opaque) before the player's bars and controls begin to show: what
/// the page under it says is hidden by then (a fill this opaque covers words: @ui's words over words), so that no frame
/// shows the player's words over the page's, both seen.
pub let bars_from : Double = 0.9

///|
/// How much of the player's bars and controls show with its flight `p` of the way in (or still in, going back): none
/// till its ground is whole (bars_from), all once it is in.
fn bars_share(p : Double) -> Double {
  dmax(0.0, (p - bars_from) / (1.0 - bars_from))
}


///|
/// What an image opened in the viewer steps through: the images of the chat it is opened from,
/// of which the core tells those beside the one shown (`imageNear`: by the chat's thread, else its session), not the
/// chat's every image; or a folder's of a drive.
pub(all) enum Stepping {
  NoSteps
  InChat(Double?, String)
  InFolder(Array[DriveFile])
}

///|
// (by the one viewer: it holds signals of its own and what is set on it as its file comes)
pub let viewer : @signals.Signal[Viewer?] = @signals.signal_ref(None)

///|
/// Whether this viewer is still the one open and not closing (what it said in the system's bars still its own).
pub fn Viewer::up_still(self : Viewer) -> Bool {
  match viewer.untracked() {
    Some(v) => physical_equal(v, self) && !self.closing
    None => false
  }
}

///|
/// The viewer closed and still drawn going (its fade or its flight back), no longer the one open: closing takes it
/// out of `viewer` at once, and what is under it is the page's again.
// (by the one viewer, as `viewer`)
pub let pv_leaving : @signals.Signal[Viewer?] = @signals.signal_ref(None)

///|
/// When the preview's way in or out is over (the frames' clock): the latest end told its fade and its flight, the one
/// open's or the one leaving's; once the one leaving is gone, the end of its way out (said to move: Viewer::shut,
/// Tester::rest_of); -1 when none was opened. What a test runs to after it opens or closes one.
pub fn preview_rest() -> Double {
  let mut at = -1.0
  for v in [viewer.get(), pv_leaving.get()] {
    match v {
      Some(v) => {
        if v.fade.ends_at() > at {
          at = v.fade.ends_at()
        }
        if v.tree_way_end.get() > at {
          at = v.tree_way_end.get()
        }
      }
      None => ()
    }
  }
  if viewer.get() is None && pv_leaving.get() is None {
    at = @ui.rest_of("the preview's way out")
  }
  at
}

///|
/// Opens `a` of the chat on `station` (kept by the session `key`); `steps`: what an image steps through; `named`: a
/// file a message names by its path (`a.path`), not one sent with it. Where the shell has a side panel for the page in
/// view (Shell's `beside`), a tab there, whatever it is (a picture stepping through its chat's there, marked there; a
/// film or a song played there at once), over the whole window as that tab (tab_full.mbt) where `full` asks it (a 全屏
/// pressed; by default unless the command key is held: full_asked), a picture, a film or a song pressed so (`full` not
/// said) in the viewer of its own instead, flown from its thumbnail (opens_in_viewer); `beside`: asked beside the page and no more (a
/// menu's 在侧边打开, the preview's 移到侧边), or, false, over everything in the viewer of its own. Anything not put in a tab opens over everything in that
/// viewer, what the tabs beside the page play paused; `start`: where a film or a song starts there (ms), else where it
/// was left.
pub fn open_preview(
  station : String,
  key : String,
  a : Attachment,
  drive? : DriveFile? = None,
  steps? : Stepping = NoSteps,
  named? : Bool = false,
  at? : String = "",
  beside? : Bool,
  full? : Bool,
  start? : Double = -1.0,
) -> Unit {
  // (pressed, the command key not held: a picture, a film or a song in the viewer of its own, flown from its thumbnail
  // and back into it, not its tab over the whole window; asked so by name, full=true, its tab still)
  let pressed_full = full is None && beside is None && full_asked()
  let full = match (full, beside) {
    (Some(f), _) => f
    (None, Some(_)) => false
    (None, None) => pressed_full
  }
  let beside = beside.unwrap_or(true)
  if beside && opens_beside(a.path, a.name) && !(pressed_full && opens_in_viewer(a)) {
    let tab = view_tab_key(station, key, a, drive, named)
    tab_facts_said(tab, a)
    // (what it steps through as it was opened, its picture's size as its message says it, which of its message's it
    // is, for its tab's viewer as it is made: laid out at its size from its first frame, decoded once at it)
    let said = tab_steps_said(tab, steps, a.width, a.height, None, at)
    if beside_open(tab, 0.0, full~) {
      return
    }
    if said {
      tab_moved_dropped(tab)
    }
  }
  close_now()
  tab_players_pause()
  pv_strip.leaving = None
  let v = new_viewer(station, key, a, drive, steps, named~, at~)
  // (from its start too, where that is where it was asked from: a tab's 全屏 at 0:00)
  if start >= 0.0 {
    v.start_at = start
  }
  viewer.set(Some(v))
}

///|
/// A viewer of `a` (what it read before, kept, taken at once).
pub fn new_viewer(
  station : String,
  key : String,
  a : Attachment,
  drive : DriveFile?,
  steps : Stepping,
  named? : Bool = false,
  at? : String = "",
  beside? : Bool = false,
) -> Viewer {
  let (kind, mime, _) = preview_kind(a.name)
  let v : Viewer = {
    station,
    key,
    file: a,
    name: base_name(a.path),
    drive,
    named,
    kind,
    mime,
    sniffed: @signals.signal(None),
    sniffing: @signals.signal(false),
    bytes: @signals.signal(None),
    previewed: @signals.signal(false),
    zoomed_in: @signals.signal(false),
    fetching: @signals.signal(false),
    got: @signals.signal(None),
    error: @signals.signal(None),
    asked: false,
    save_after: false,
    share_after: false,
    copy_after: false,
    marks_after: None,
    download_asked: false,
    install_after: false,
    awake: true,
    awake_told: @signals.signal(0),
    asked_told: @signals.signal(0),
    near_bar: false,
    // (a tab's fitted as the whole window's is, but always as on a narrow stage: tab_picture_node lays it out so)
    zoom: if beside {
      @motion.Zoom::new(margin=fn(_) { tab_picture_margin })
    } else {
      @motion.Zoom::new()
    },
    // (a film edge to edge, enlarged, as the player puts it: what it flies to and from)
    vzoom: video_zoom(),
    source: false,
    source_told: @signals.signal(0),
    flow_told: @signals.signal(0),
    page: None,
    pdf: None,
    pdf_marks: PdfMarks::new(),
    md_marks: MdMarks::new(),
    lines_marks: LinesMarks::new(),
    text: None,
    colored: None,
    colored_dark: false,
    flow: None,
    image: "",
    preview_image: "",
    started: false,
    closing: false,
    fade: @motion.Way::new(0.0),
    held: false,
    last_x: 0.0,
    last_y: 0.0,
    moved: 0.0,
    pinch_d: 0.0,
    pinch_x: 0.0,
    pinch_y: 0.0,
    pinched: false,
    reads: @signals.signal(0),
    pinned: None,
    steps,
    at,
    swiping: false,
    pulling: false,
    wheel_pulling: false,
    pull_x: 0.0,
    pull_y: 0.0,
    down_x: 0.0,
    down_y: 0.0,
    down_lx: 0.0,
    down_ly: 0.0,
    at_left: false,
    at_right: false,
    caught: false,
    strip_down: 0.0,
    start_at: match pv_frames.get(station + "/" + key + "/" + a.path) {
      Some((_, ms)) if drive is None && ms > 0.0 => ms
      _ => -1.0
    },
    leaving_grab: false,
    leaving_pic: "",
    left_at: 0.0,
    grab_told: @signals.signal(0),
    media: None,
    copied: 0,
    head_w: 0.0,
    serial: {
      viewers_opened.val = viewers_opened.val + 1
      viewers_opened.val
    },
    in_tree: false,
    tree_layers: 0,
    tree_back: @signals.signal(false),
    tree_way: @signals.signal(false),
    tree_way_end: @signals.signal(0.0, same=fn(a, b) { a == b }),
    fingers: Map([]),
    speed: @ui.Velocity::new(),
    hold_off: fn() {  },
    tap_off: fn() {  },
    wheel_off: fn() {  },
    lift: @motion.Way::new(0.0),
    beside,
    plays_now: !beside,
    play_how: None,
  }
  // (one named by its path read anew each time: it may have changed since)
  if !named {
    v.bytes.set(kept_read(v.id()))
  }
  v
}

///|
/// A file sent with a chat's message, kept by its name there (not a drive's, not one a message names by its path).
pub fn Viewer::chat_file(self : Viewer) -> Bool {
  self.drive is None && !self.named
}

///|
/// The id of the file a draft holds (its path `draft:<id>`, a file picked here not yet sent): None for any other.
fn Viewer::draft_id(self : Viewer) -> String? {
  let path = self.file.path
  if path.has_prefix("draft:") {
    Some(path.unsafe_substring(start=6, end=path.length()))
  } else {
    None
  }
}

///|
/// The file's own id: its station, the session that keeps it (or the drive's root), its path.
pub fn Viewer::id(self : Viewer) -> String {
  match self.drive {
    Some(d) => self.station + "/drive:" + d.root + "/" + d.path
    None => self.station + "/" + self.key + "/" + self.file.path
  }
}

///|
/// The row in an occurrence's place and the file or quote within it.
fn place_parts(at : String) -> (String, String) {
  match at.rev_find("/") {
    Some(i) => (at.exact_view(end=i).to_owned(), at.exact_view(start=i).to_owned())
    None => (at, "")
  }
}

///|
/// What a chat's page made as nodes calls the core's rows that took over what was sent from here by, by the chat
/// (station + "\u{1}" + session): the core's row's key to the key it was sent as (its list's own, sfpages'
/// chat_body_rows' `sent_as`), read through its rows so what reads it follows a row taken over; given as the page is
/// made, taken as it goes. The old page's is its Reading's (Reading::sent_as).
pub let rows_sent_as : Map[String, () -> Map[String, String]] = Map([])

///|
/// The keys chat (`station`, `session`)'s rows that took over what was sent from here go on by, by the core's row's
/// key: its page's, the page made as nodes' where it is one (rows_sent_as), else the old page's Reading's.
fn sent_as_of(station : String, session : String) -> Map[String, String]? {
  let k = station + "\u{1}" + session
  match rows_sent_as.get(k) {
    Some(f) => Some(f())
    None =>
      match readings.get(k) {
        Some(r) => {
          r.sent_as_told.get() |> ignore
          Some(r.sent_as)
        }
        None => None
      }
  }
}

///|
/// The chat's row keeps the identity it had before the core took it over (sent_as_of).
fn placed_row(station : String, session : String, row : String) -> String {
  match sent_as_of(station, session) {
    Some(sent_as) => sent_as.get(row).unwrap_or(row)
    None => row
  }
}

///|
/// The occurrence as its list knows it, including a row that went from local to the core's outbox.
pub fn thumb_occurrence(station : String, session : String, at : String) -> String {
  if at == "" {
    ""
  } else {
    let (row, part) = place_parts(at)
    placed_row(station, session, row) + part
  }
}

///|
/// A file can be drawn in several messages or quotes. Its thumbnail's place is separate from the file's identity,
/// which still names the shared bytes and video frame. The list's row identity survives the outbox handoff.
pub fn thumb_place(file : String, station : String, session : String, at : String) -> String {
  if at == "" {
    file
  } else {
    let place = thumb_occurrence(station, session, at)
    Json::array([Json::string(file), Json::string(session), Json::string(place)]).stringify()
  }
}

///|
pub fn Viewer::thumb_id(self : Viewer) -> String {
  match self.steps {
    InChat(_, session) => thumb_place(self.id(), self.station, session, self.at)
    _ => self.id()
  }
}

///|
/// What the core now calls an occurrence opened before its local row was handed over.
fn Viewer::gallery_at(self : Viewer) -> String {
  match self.steps {
    InChat(_, session) =>
      match sent_as_of(self.station, session) {
        Some(sent_as) => {
          let (row, part) = place_parts(self.at)
          for source, sent_row in sent_as {
            if sent_row == row {
              return source + part
            }
          }
          self.at
        }
        None => self.at
      }
    _ => self.at
  }
}

///|
/// Whole files the viewer read (the one shown and those beside it, read ahead so a step shows the next at once), the
/// latest few.
pub let pv_read : Array[(String, Bytes)] = []

///|
pub fn kept_read(id : String) -> Bytes? {
  for x in pv_read {
    if x.0 == id {
      return Some(x.1)
    }
  }
  None
}

///|
pub fn keep_read(id : String, b : Bytes) -> Unit {
  pv_read.retain(fn(x) { x.0 != id })
  pv_read.push((id, b))
  if pv_read.length() > 5 {
    pv_read.remove(0) |> ignore
  }
}

///|
/// The images stepped through slide this far apart, on SLIDE (critically damped, 400).
pub let slide_gap : Double = 24.0

///|
/// The one going as the next comes: its picture where it was (x, y, w, h), moving out to the side away from `dir`,
/// `width` (the stage's and the gap) apart.
pub(all) struct Leaving {
  picture : String
  x : Double
  y : Double
  w : Double
  h : Double
  dir : Int
  width : Double
}

///|
/// Phase of a trackpad two-finger horizontal swipe on the picture strip (Viewer::wheel_page).
/// Kept on `pv_strip` rather than on a single `Viewer` because `Viewer::go` replaces the active `Viewer`
/// mid-gesture while momentum wheels from the same swipe are still arriving.
#derive(Eq)
pub(all) enum StripWheelState {
  Idle
  Paging
  Spent
}

///|
pub(all) struct StripWheel {
  mut state : StripWheelState
  mut strip_down : Double
  mut last_at : Double
  mut last_momentum : Bool
  mut spent_dir : Double
  mut spent_min_dx : Double
  speed : @ui.Velocity
}

///|
pub fn StripWheel::new() -> StripWheel {
  {
    state: Idle,
    strip_down: 0.0,
    last_at: -1.0,
    last_momentum: false,
    spent_dir: 0.0,
    spent_min_dx: 0.0,
    speed: @ui.Velocity::new(),
  }
}

///|
pub fn StripWheel::reset(self : StripWheel) -> Unit {
  self.state = Idle
  self.strip_down = 0.0
  self.last_at = -1.0
  self.last_momentum = false
  self.spent_dir = 0.0
  self.spent_min_dx = 0.0
  self.speed.reset()
}

///|
pub(all) struct Strip {
  /// where the strip of pictures is (the one shown's offset across), its way said at each cause's moment
  way : @motion.Way
  mut leaving : Leaving?
  /// where the strip is held for a fixture's shot (a swipe halfway), else None
  mut pinned : Double?
  /// the viewers of the images beside the one shown (by their ids), read ahead
  near : Map[String, Viewer]
  /// horizontal trackpad paging gesture state shared across Viewer::go transitions
  wheel : StripWheel
}

///|
pub let pv_strip : Strip = {
  way: @motion.Way::new(0.0),
  leaving: None,
  pinned: None,
  near: Map([]),
  wheel: StripWheel::new(),
}

///|
/// The images beside one asked of the core (`imageNear`), each by its params: let go with the chat they are of
/// (chat_left), as they hold its thread there.
pub let near_asked : Map[String, Map[String, Json]] = Map([])

///|
/// The images beside those of `station`'s chats let go (a chat of it left).
pub fn near_left(src : Source, station : String) -> Unit {
  let gone = []
  near_asked.each(fn(k, p) {
    if p.get("station") == Some(Json::string(station)) {
      gone.push(k)
      (src.leave)("imageNear", p, TopicLeave::Legacy)
    }
  })
  for k in gone {
    near_asked.remove(k)
  }
}

///|
/// The way out of a viewer closed (Viewer::shut), said to move: at rest at the latest end of its fade's and its
/// flight's.
priv struct PreviewOut {
  v : Viewer
}

///|
/// Who tells the way out of a viewer closed (PreviewOut).
// kept across runs: it only names the way out to the frame's context, which keeps its own list (Ctx::moving_as)
let pv_out_mover : @ui.Mover = @ui.Mover::new()

///|
fn PreviewOut::rest_at(self : PreviewOut, now : Double, frame : Int) -> Double {
  ignore(now)
  ignore(frame)
  let (fade, tree) = (self.v.fade.ends_at(), self.v.tree_way_end.untracked())
  if fade > tree {
    fade
  } else {
    tree
  }
}

///|
/// What moves, as Ctx::moving is told it (Moving).
fn PreviewOut::as_moving(self : PreviewOut) -> @ui.Moving {
  @ui.Moving::new(fn(now, frame) { self.rest_at(now, frame) })
}

///|
/// The viewer gone at once (the one open and the one going), what it holds let go (its player stopped, its page and
/// PDF closed).
pub fn close_now() -> Unit {
  marks_leave()
  // (closed at once: nothing of its strip goes on)
  pv_strip.leaving = None
  pv_strip.way.put(0.0)
  pv_strip.wheel.reset()
  match viewer.get() {
    Some(v) => v.let_go()
    None => ()
  }
  viewer.set(None)
  leaving_done()
}

///|
/// The viewer that was going, gone.
pub fn leaving_done() -> Unit {
  match pv_leaving.get() {
    Some(v) => v.let_go()
    None => ()
  }
  pv_leaving.set(None)
}

///|
/// What a viewer holds of the host's, let go.
pub fn Viewer::let_go(self : Viewer) -> Unit {
  // read in a desktop's reader (@sf.reader): what it read let go with it
  @sf.reader_let_go(self.read_key())
  // (a tab's that marked: marking left with it)
  if marks_tab.val is Some(v) && physical_equal(v, self) {
    marks_leave()
  }
  match self.media {
    Some(m) => {
      m.close()
      @sf.player_view_let_go(m.key())
    }
    None => ()
  }
  match self.page {
    Some(n) => n.close()
    None => ()
  }
  match self.pdf {
    Some(p) => p.close()
    None => ()
  }
  self.let_go_image()
  // (the frames kept for thumbnails replaced while it was open or going, let go of now nothing flies with them)
  pv_frames_sweep(but=self)
}

fn is_preview_image_key(key : String) -> Bool {
  key.has_prefix("mem:preview/") || key.has_prefix("mem:preview-p/")
}

///|
/// Its whole picture, read here, let go of where nothing else shows it (a chat's picture given it, ChatImages::whole,
/// keeps it); where something still does (the strip sliding it out as another is stepped to), once nothing does
/// (pv_previews_gone). Drawn again by it, it is put up again from its bytes (Viewer::picture).
fn Viewer::let_go_image(self : Viewer) -> Unit {
  let drop = fn(key : String) -> Bool {
    if is_preview_image_key(key) && !whole_given_shown(key) {
      if preview_shown(key, but=self) {
        pv_previews_gone.push(key)
        false
      } else {
        @ui.forget_image(key)
        true
      }
    } else {
      false
    }
  }
  let image = self.image
  let preview = self.preview_image
  if drop(image) {
    self.image = ""
  }
  if preview != "" && preview != image {
    drop(preview) |> ignore
  }
  self.preview_image = ""
  pv_previews_sweep(but=self)
}

///|
/// Drop the preview image key once the whole image is ready so both do not stay resident in the host.
fn Viewer::drop_preview_image(self : Viewer) -> Unit {
  let key = self.preview_image
  if key != "" && key != self.image {
    self.preview_image = ""
    if is_preview_image_key(key) && !whole_given_shown(key) {
      if preview_shown(key, but=self) {
        pv_previews_gone.push(key)
      } else {
        @ui.forget_image(key)
      }
    }
    pv_previews_sweep(but=self)
  }
}

///|
/// Whole pictures of viewers let go of while something still showed them (Viewer::let_go_image), let go of once
/// nothing does (pv_previews_sweep).
// kept across runs: emptied by file_viewer_reset
let pv_previews_gone : Array[String] = []

///|
/// The whole pictures waiting to be let go of (pv_previews_gone) let go of where nothing but `but` shows them now:
/// those a chat's picture was given since are its own to let go of.
fn pv_previews_sweep(but? : Viewer) -> Unit {
  let still : Array[String] = []
  for key in pv_previews_gone {
    if whole_given_shown(key) {
      continue
    }
    if preview_shown(key, but?=but) {
      if !still.contains(key) {
        still.push(key)
      }
    } else {
      @ui.forget_image(key)
    }
  }
  pv_previews_gone.clear()
  pv_previews_gone.push_iter(still.iter())
}

///|
/// Whether a viewer is open (the page under it takes no keys).
pub fn preview_open() -> Bool {
  viewer.get() is Some(_)
}

///|
/// The kind it shows as, once known.
pub fn Viewer::shown_kind(self : Viewer) -> PKind? {
  match self.kind {
    Some(k) => Some(k)
    None =>
      match self.sniffed.get() {
        Some(true) => Some(KText)
        _ => None
      }
  }
}

///|
/// Told of (its name, size and kind) rather than shown: of no kind it has a viewer for, or too big to read.
pub fn Viewer::told_of(self : Viewer) -> Bool {
  match self.shown_kind() {
    Some(KVideo) | Some(KAudio) | Some(KPdf) => false
    None => self.kind is None && self.sniffed.get() is Some(_)
    // (shown as it comes, however big)
    Some(_) if self.flows() => false
    Some(_) => self.file.size > big_file
  }
}

///|
pub fn Viewer::dark(self : Viewer) -> Bool {
  // on the page's own canvas whatever it shows; a film and a song in their player, dark as
  // the player is
  self.shown_kind() == Some(KVideo) || self.shown_kind() == Some(KAudio)
}

// ── reading it through the core ────────────────────────────────────────

///|
pub fn file_params(v : Viewer) -> Map[String, Json] {
  {
    "station": Json::string(v.station),
    "key": Json::string(v.key),
    "name": Json::string(v.name),
  }
}

///|
/// One a message names (`file.open` with `params`), read first of what this device kept of it (`kept`, no station
/// asked) and `shown` with it at once where that is all of what is asked, then asked again as it is now (it may have
/// changed since: the core asks by the version it kept), `renewed` with what the station answers where that differs;
/// `otherwise`, none kept, read as it is now alone.
fn Viewer::kept_first(
  self : Viewer,
  src : Source,
  params : Map[String, Json],
  shown : (Json, Bytes) -> Unit,
  renewed : (Json, Bytes) -> Unit,
  otherwise : () -> Unit,
) -> Unit {
  let p = named_params(self)
  for k, v in params {
    p[k] = v
  }
  p["kept"] = Json::boolean(true)
  (src.read_bytes)("file.open", Json::object(p), fn(r) {
    match r {
      Ok((said, bytes)) if number(Some(said), "size") == bytes.length().to_double() => {
        shown(said, bytes)
        (src.read_bytes)("file.open", Json::object(params), fn(again) {
          match again {
            Ok((now, b)) if !(field(Some(now), "same") is Some(True)) && b != bytes => renewed(now, b)
            _ => ()
          }
        })
      }
      _ => otherwise()
    }
  })
}

///|
/// What was shown of one a message names given way to what it is now (Viewer::kept_first): its picture put up anew.
fn Viewer::renewed(self : Viewer, b : Bytes) -> Unit {
  self.image = ""
  self.bytes.set(Some(b))
}

///|
/// What a file a message names is read by (`file.open`): its path as the message has it, in its agent's session.
pub fn named_params(v : Viewer) -> Map[String, Json] {
  {
    "station": Json::string(v.station),
    "key": Json::string(v.key),
    "path": Json::string(v.file.path),
  }
}

///|
/// Where it was opened, as the core keeps it with what it reads of it (its KeptFrom: what is brought after everything
/// else is only what was opened, and is opened again from where it is listed): a drive's where it is; a chat's, the
/// chat and the file as its message has it.
pub fn Viewer::opened_from(self : Viewer) -> Json {
  match self.drive {
    Some(d) => { "root": Json::string(d.root), "path": Json::string(d.path) }
    None => {
      let o : Map[String, Json] = { "file": attachment_json(self.file, self.file.owner) }
      match self.steps {
        InChat(thread, session) => {
          o["session"] = Json::string(session)
          match thread {
            Some(n) => o["thread"] = Json::number(n)
            None => ()
          }
        }
        _ => ()
      }
      Json::object(o)
    }
  }
}

///|
/// The call a part of it is read by: a chat's file `station.file.part`, a drive's `drive.read`, one a message names
/// `file.open`.
pub fn Viewer::part_call(self : Viewer) -> String {
  if self.drive is Some(_) {
    "drive.read"
  } else if self.named {
    "file.open"
  } else {
    "station.file.part"
  }
}

///|
/// `length` bytes of it from `offset` (fewer at its end), and its whole size as the station says (in the answer's
/// `total`). A drive's kept on the device as `keep` (drive_keep: `file` read from its start, `played` a video's or
/// song's ranges), as its folder lists it; a chat's video or song as played, with its chat (chat_keep).
pub fn Viewer::read_part(
  self : Viewer,
  src : Source,
  offset : Double,
  length : Int,
  keep : String,
  done : (Result[(Json, Bytes), Json]) -> Unit,
) -> Unit {
  (src.read_bytes)(self.part_call(), Json::object(self.part_params(offset, length, keep)), done)
}

///|
/// What a part of it is asked by: `length` bytes from `offset`, kept as `keep` (Viewer::read_part).
pub fn Viewer::part_params(self : Viewer, offset : Double, length : Int, keep : String) -> Map[String, Json] {
  let p = match self.drive {
    Some(d) => {
      let p : Map[String, Json] = {
        "station": Json::string(d.station),
        "root": Json::string(d.root),
        "path": Json::string(d.path),
      }
      drive_keep(p, keep, d.mtime, d.size)
      p
    }
    None if self.named => named_params(self)
    None => {
      let p = file_params(self)
      chat_keep(p, self.file.size)
      p
    }
  }
  // (where it was opened, for what is brought after everything else: a video or song, as played)
  if keep == "played" {
    p["from"] = self.opened_from()
  }
  p["offset"] = Json::number(offset)
  p["length"] = Json::number(length.to_double())
  p
}

///|
/// Its size as its message or its folder says it (0: not known).
pub fn Viewer::listed_size(self : Viewer) -> Double {
  match self.drive {
    Some(d) => d.size
    None => self.file.size
  }
}

///|
/// A part read for the player (`call` with `p`), its bytes handed on as they come (the core's part read with
/// `stream`: each piece as it arrives, never the whole part waited for), as a player's read takes them:
/// `answer(bytes, total, more)`, the whole's size as `size` says it (its message's, its folder's; 0 not known) until
/// the core's answer says it. `ended` hears how it ended: the bytes it brought, or why it failed. What it gives back
/// stops it (the core's read let go of: nothing more of it comes over the network).
pub fn stream_part(
  src : Source,
  call : String,
  p : Map[String, Json],
  size : Double,
  answer : (Bytes, Double, Bool) -> Unit,
  ended? : (Result[Int, Json]) -> Unit = fn(_) {  },
) -> () -> Unit {
  p["stream"] = Json::boolean(true)
  let known = if size > 0.0 { size } else { -1.0 }
  let got = Ref(0)
  let id = (src.stream)(
    call,
    Json::object(p),
    None,
    fn(_, bytes) {
      match bytes {
        Some(b) if b.length() > 0 => {
          got.val += b.length()
          answer(b, known, true)
        }
        _ => ()
      }
    },
    fn(r) {
      match r {
        Ok(said) => {
          ended(Ok(got.val))
          answer(
            b"",
            match field(Some(said), "total") {
              Some(Number(t, ..)) => t
              _ => known
            },
            false,
          )
        }
        Err(e) => {
          ended(Err(e))
          answer(b"", -2.0, false)
        }
      }
    },
  )
  fn() { (src.cancel)(id) }
}

///|
/// How a host's own reader reads the parts `stream_part` would (@ui.NativeView::video's `direct`), past the app: the
/// core's `call` with `p` (its `offset` and `length` each part's own), the whole's size as `size` says it (0 not known).
pub fn direct_part(call : String, p : Map[String, Json], size : Double) -> String {
  let q : Map[String, Json] = Map([])
  for k, v in p {
    if k != "offset" && k != "length" {
      q[k] = v
    }
  }
  q["stream"] = Json::boolean(true)
  Json::object({ "call": Json::string(call), "params": Json::object(q), "size": Json::number(size) }).stringify()
}

///|
/// A chat's file read through the core kept on the device with its chat, and answered from there when it is kept (the
/// core's drive-kept.ts `chat`), as Android keeps those its viewers open on the phone's disk (ChatFiles.kt toDisk,
/// onDisk). A missing size is learned from the station.
pub fn chat_keep(p : Map[String, Json], size : Double) -> Unit {
  p["keep"] = Json::boolean(true)
  p["size"] = Json::number(if size > 0.0 { size } else { 0.0 })
}

///|
/// Whether a chat's file read whole is kept with its chat: pictures as well as PDFs, videos, songs and big files.
/// A file named by its path may change and is always read as it is now.
pub fn Viewer::kept_whole(self : Viewer) -> Bool {
  guard !self.named else { return false }
  match self.shown_kind() {
    Some(KImage) | Some(KPdf) | Some(KVideo) | Some(KAudio) => true
    _ => self.file.size > big_file
  }
}

///|
/// An image this small or smaller is read whole at once: its station makes no preview of it (the core's
/// drive-kept.ts `PREVIEW_SMALL`).
pub let preview_small : Double = 300.0 * 1024.0

///|
/// Whether it is read first as its station's preview: a chat's image over preview_small, not zoomed into nor asked
/// for (to save, share or install).
fn Viewer::wants_preview(self : Viewer) -> Bool {
  self.chat_file() &&
  self.shown_kind() == Some(KImage) &&
  self.file.size > preview_small &&
  !self.asked &&
  !self.zoomed_in.untracked()
}

///|
/// Whether the image itself is to be read in place of the preview it shows: zoomed into, or asked for.
pub fn Viewer::whole_due(self : Viewer) -> Bool {
  self.previewed.get() && (self.asked || self.zoomed_in.get())
}

///|
/// Its bytes as they are here to be saved, shared or installed: none while what is here is a preview.
fn Viewer::whole_here(self : Viewer) -> Bytes? {
  if self.previewed.untracked() {
    None
  } else {
    self.bytes.untracked()
  }
}

///|
/// The whole of it: a chat's in one `station.file`; a drive's a part (4 MB) at a time, as its reader reads.
pub fn Viewer::read_whole(self : Viewer, src : Source, done : (Result[Bytes, Json]) -> Unit) -> Unit {
  // (its answer one change, whoever asked (the one shown, or read ahead beside it): what came, or that it failed, told
  // with its no longer being read, never what follows either running between them and asking again)
  let previewed = Ref(false)
  let done = fn(r) {
    @signals.start_batch()
    self.got.set(None)
    self.previewed.set(previewed.val)
    done(r)
    @signals.end_batch()
  }
  match self.drive {
    // one a message names: what this device kept of it shown at once, then as it is now (at most 16 MB)
    None if self.named =>
      self.kept_first(src, named_params(self), fn(_, bytes) { done(Ok(bytes)) }, fn(_, b) { self.renewed(b) }, fn() {
        (src.read_bytes)("file.open", Json::object(named_params(self)), fn(r) {
          match r {
            Ok((_, bytes)) => done(Ok(bytes))
            Err(e) => done(Err(e))
          }
        })
      })
    // what else, an image too (grown from its thumbnail meanwhile): how much has come as it comes, said in its bar
    // as the web's (the core's `{loaded, total}`)
    None => {
      let p = file_params(self)
      p["progress"] = Json::boolean(true)
      chat_keep(p, self.file.size)
      if self.kept_whole() || self.asked {
        p["from"] = self.opened_from()
      }
      let preview = self.wants_preview()
      if preview {
        p["preview"] = Json::boolean(true)
      }
      (src.read_going)(
        "station.file",
        Json::object(p),
        fn(v) {
          match field(Some(v), "loaded") {
            Some(Number(n, ..)) =>
              self.got.set(Some(
                (
                  n,
                  match field(Some(v), "total") {
                    Some(Number(t, ..)) => Some(t)
                    _ => None
                  },
                ),
              ))
            _ => ()
          }
        },
        fn(r) {
          match r {
            Ok((answer, bytes)) => {
              previewed.val = preview && field(Some(answer), "preview") is Some(True)
              done(Ok(bytes))
            }
            Err(e) => done(Err(e))
          }
        },
      )
    }
    Some(_) => {
      let parts : Array[Bytes] = []
      let got : Ref[Int] = { val: 0 }
      fn next() {
        self.read_part(src, got.val.to_double(), drive_part, "file", fn(r) {
          match r {
            Ok((answer, bytes)) => {
              let total = match field(Some(answer), "total") {
                Some(Number(n, ..)) => n.to_int()
                _ => got.val + bytes.length()
              }
              parts.push(bytes)
              got.val += bytes.length()
              self.got.set(Some((got.val.to_double(), Some(total.to_double()))))
              if bytes.length() == 0 || got.val >= total {
                let all = Buffer(capacity=got.val)
                for b in parts {
                  all.write_bytes(b)
                }
                done(Ok(all.to_bytes()))
              } else {
                next()
              }
            }
            Err(e) => done(Err(e))
          }
        })
      }
      next()
    }
  }
}

///|
/// What has to be asked of the core this frame: a file of no known kind's first bytes, the whole of one to show, a
/// video's player.
pub fn Viewer::fetch(self : Viewer, src : Source) -> Unit {
  let v = self
  // (each asked once a viewer, by its file: nothing a build changes)
  if v.kind is None && v.sniffed.get() is None && !v.sniffing.get() {
    v.sniffing.set(true)
    v.read_part(src, 0.0, 8192, "file", fn(r) {
      v.sniffing.set(false)
      v.sniffed.set(Some(
        match r {
          Ok((_, bytes)) => @codec.looks_like_text(bytes)
          // a station from before parts cannot say: told of, as anything else not shown
          Err(_) => false
        },
      ))
    })
    return
  }
  match v.shown_kind() {
    // a film or a song: the one player (@sf.player_node, a tab's embedded), read through the core a part at a time (never the whole file
    // first, a seek far ahead one more ranged read), from the frame it was left at (the thumbnail's)
    // (a tab's its own, by its viewer: its view and what its player's view holds not the whole window's, nor another
    // tab's)
    Some(KVideo) | Some(KAudio) => {
      if v.media is None {
        let m = @sf.new_media(if v.beside { "preview-media/" + v.serial.to_string() } else { "preview-media" })
        let start = if v.start_at > 0.0 { v.start_at } else { 0.0 }
        v.start_at = -1.0
        m.open(
          {
            name: v.file.name,
            mime: v.mime,
            audio: v.shown_kind() == Some(KAudio),
            read: fn(offset, length, answer) {
              // its bytes here already (one waiting in the composer: no station has it yet), played from them
              match v.bytes.get() {
                Some(b) => {
                  let from = offset.to_int()
                  let to = if from + length < b.length() { from + length } else { b.length() }
                  answer(if from < to { b[from:to].to_owned() } else { b"" }, b.length().to_double(), false)
                  return fn() {  }
                }
                None => ()
              }
              // (one a message names: each part in one piece, `file.open` streams none; what this device kept of it as
              // played answered at once, the core asking the station again by its version as its start is read)
              if v.named {
                let gone = Ref(false)
                let p = v.part_params(offset, length, "")
                p["played"] = Json::boolean(true)
                let took = fn(r : Result[(Json, Bytes), Json]) {
                  guard !gone.val else { return }
                  match r {
                    Ok((said, bytes)) => {
                      answer(bytes, number(Some(said), "size"), true)
                      answer(b"", number(Some(said), "size"), false)
                    }
                    Err(_) => answer(b"", -2.0, false)
                  }
                }
                let kept = p.copy()
                kept["kept"] = Json::boolean(true)
                (src.read_bytes)("file.open", Json::object(kept), fn(r) {
                  match r {
                    Ok(_) => took(r)
                    Err(_) => (src.read_bytes)("file.open", Json::object(p), took)
                  }
                })
                return fn() { gone.val = true }
              }
              stream_part(src, v.part_call(), v.part_params(offset, length, "played"), v.listed_size(), answer, ended=fn(r) {
                match r {
                  Ok(bytes) => {
                    if v.reads.get() < 3 {
                      @ui.log("preview: \{v.name} @\{offset.to_int()} \{bytes} bytes through the core (\{v.part_call()})")
                    }
                    v.reads.set(v.reads.get() + 1)
                  }
                  Err(e) => @ui.log("preview: \{v.name} @\{offset.to_int()} failed: \{e.stringify()}")
                }
              })
            },
            // (its bytes here, or one a message names: read by the app alone, as above)
            direct: if v.bytes.get() is None && !v.named && !v.file.path.has_prefix("draft:") {
              direct_part(v.part_call(), v.part_params(0.0, 0, "played"), v.listed_size())
            } else {
              ""
            },
          },
          start~,
          play=v.plays_now,
        )
        v.media = Some(m)
        // (moved beside from the whole window's: as fast and as loud as it played there)
        match v.play_how {
          Some(how) => {
            v.play_how = None
            media_as(m, how)
          }
          None => ()
        }
      }
      // played as it comes: read whole only once asked to be saved (the player's 下载)
      if !v.asked {
        return
      }
    }
    _ => ()
  }
  // code and text: shown as they come, a part at a time (viewer_flow.mbt), its first part asked here
  if v.flows() && !v.asked && v.bytes.get() is None {
    if v.flow is None {
      v.read_on(src)
    }
    return
  }
  let want = !v.told_of() || v.asked
  // (a preview shown: the image itself once it is zoomed into or asked for, the preview shown till it comes)
  if want && !v.file.path.has_prefix("draft:") && (v.bytes.get() is None || v.whole_due()) && !v.fetching.get() &&
    v.error.get() is None &&
    (v.kind is Some(_) || v.sniffed.get() is Some(_)) {
    v.fetching.set(true)
    v.read_whole(src, fn(r) {
      v.fetching.set(false)
      match r {
        Ok(bytes) => {
          @ui.log(
            "preview: \{v.name} read whole through the core (\{if v.drive is Some(_) { "drive.read" } else if v.named { "file.open" } else { "station.file" }}, \{bytes.length()} bytes)",
          )
          v.took_whole(src, bytes)
          v.bytes.set(Some(bytes))
          // (a preview is not what a viewer opened again shows at once: the core answers it from the device)
          if !v.named && !v.previewed.untracked() {
            keep_read(v.id(), bytes)
          }
        }
        Err(e) =>
          v.error.set(Some(
            match text(Some(e), "message") {
              "" => e.stringify()
              m => m
            },
          ))
      }
    })
  }
}

///|
/// ASCII letters in capitals.
pub fn upper(s : String) -> String {
  let sb = StringBuilder()
  for ch in s {
    let k = ch.to_int()
    sb.write_char(if k >= 97 && k <= 122 { (k - 32).unsafe_to_char() } else { ch })
  }
  sb.to_string()
}

// ── the viewer ─────────────────────────────────────────────────────────

///|
/// Viewer `v` set out at the moment `at` (its cause's: where it is a node of the window's tree, as that node is made,
/// viewer_tree.mbt), once: fading in (a tree flight overrides fade via tree_way_told).
pub fn Viewer::set_out(self : Viewer, c : @ui.Ctx, at : Double) -> Unit {
  let v = self
  if !v.started {
    v.started = true
    // it comes up in the keyboard's place: what was being typed into lets go of it first
    c.blur()
    // as web's: fading in, when there is no thumbnail to grow from
    v.fade.go(1.0, @motion.tween(pv_fade_ms, ease=Out), at~)
  }
}

///|
pub fn Viewer::shut(self : Viewer, c : @ui.Ctx) -> Unit {
  if !self.closing {
    self.closing = true
    // closed at once: the one going is only drawn (what was going before it, gone)
    marks_leave()
    leaving_done()
    // (an image's zoom on its way, a double tap's glide or a fling, stops where it is: what it goes back from)
    if self.shown_kind() == Some(KImage) {
      self.zoom.stop_glide(at=viewer_moment(c))
    }
    // a chat's video left where it was played to: opened again, on from there, whether it goes back into its
    // thumbnail (which keeps the frame it shows as well, left_with_picture) or fades out, its thumbnail not on the
    // screen (its frame kept before, if any, kept with it)
    self.keep_left_at()
    // an image or film shrinks back into its thumbnail when the chat shows it as a node of the window's tree
    // (View::shared), else it fades out
    match self.shown_kind() {
      // an image of a chat's page made as nodes, its thumbnail drawn: let go of at once, its picture flown back into
      // it by the window's tree (viewer_tree.mbt's image_layer: View::shared, the thumbnail's end that stays), out of
      // the way of the chat's bar and composer as that end is (Tree::stays_clear)
      Some(KImage) if self.in_tree && tree_thumb_seen(self.thumb_id()) => {
        // (the way in's end forgotten: the way back's told as it sets out)
        self.tree_way_end.set(-1.0)
        self.tree_back.set(true)
        // (its way in over: the way back is told by the tree as it sets out, tree_way_told)
        self.tree_way.set(false)
        self.fade.go(0.0, @motion.tween(pv_fade_ms, ease=Leave), at=viewer_moment(c))
      }
      // a film of a chat's page made as nodes, its thumbnail drawn: the frame it shows grabbed first (its player is the
      // host's, drawn by none of the tree: the thumbnail keeps that frame, Viewer::left_with_frame), then let go of, the
      // thumbnail flown back from where its player drew it by the window's tree (viewer_tree.mbt's film_shared); none
      // to grab, at once with its still
      Some(KVideo) if self.in_tree && self.chat_file() && tree_thumb_seen(self.thumb_id()) =>
        match self.view() {
          // (still flying in: back from where that has got to at once, no frame grabbed of a player not seen whole)
          Some(n) if !(self.tree_way.untracked() && viewer_moment(c) < self.tree_way_end.untracked()) &&
            n.here() && n.shown() && !n.grabbing() => {
            self.grab_set(true)
            self.left_at = left_from(n)
            c.tell("preview-grab", fn() { n.grab_shown(kept_frame_side) })
          }
          _ => self.tree_film_back(viewer_moment(c))
        }
      // the way in played backwards (web's fp: ease-out on the way in, the same curve run back on the way out): the
      // ground and the picture stay nearly whole at first, then go
      _ => self.fade.go(0.0, @motion.tween(pv_fade_ms, ease=Leave), at=viewer_moment(c))
    }
    // (closed: the one going from here, its way said: what follows its going reads where it goes)
    viewer.set(None)
    pv_leaving.set(Some(self))
    // (said to move from its cause on, as what moves is: what waits on it, Tester::moving, and once it is gone a
    // test's preview_rest)
    c.moving(pv_out_mover, ({ v: self } : PreviewOut).as_moving(), what="the preview's way out")
    // the views under the canvas go at once (they cannot fade)
    match self.view() {
      // (once the frame's builds are over: closed as the back is taken or the marks are put, once)
      Some(n) => c.tell("preview-pause", fn() { n.pause() })
      None => ()
    }
  }
}

///|
/// The moment what is told the viewer now happens at: the event's, where a node of the window's tree takes it (its
/// cause's: viewer_tree.mbt), else the frame's.
fn viewer_moment(c : @ui.Ctx) -> Double {
  @ui.tree_cause().unwrap_or(c.moment())
}

///|
/// A video back into its thumbnail from the moment `at`.
pub fn Viewer::fly_home(self : Viewer, at : Double) -> Unit {
  // (its thumbnail a node of the window's tree: flown back into by the tree, viewer_tree.mbt's film_shared)
  if self.in_tree && self.shown_kind() == Some(KVideo) {
    self.tree_film_back(at)
  }
}

///|
/// Its picture's flight by the window's tree set out (View::shared's `told`): from `start` till `end` (the clock's ms),
/// `grown` how far it has grown from its thumbnail at each moment. Its fade, all that is drawn round its picture (its
/// ground over the page, its bars), goes that one way from that moment: in as the picture grows out of its thumbnail,
/// none of it while that goes out from under the chat's bar or composer, out as it shrinks back into it; gone, the
/// viewer let go of, as the flight ends (image_ends).
fn Viewer::tree_way_told(self : Viewer, start : Double, end : Double, grown : (Double) -> Double) -> Unit {
  let ms = end - start
  guard ms > 0.0 else { return }
  self.tree_way_end.set(end)
  self.tree_way.set(true)
  if self.tree_back.untracked() {
    self.fade.go(0.0, @motion.tween_to(duration=ms, ease=fn(x) { 1.0 - grown(start + x * ms) }), at=start)
  } else {
    self.fade.go(1.0, @motion.tween_to(duration=ms, ease=fn(x) { grown(start + x * ms) }), at=start)
  }
}

///|
/// A film whose thumbnail is a node of the window's tree let go of from the moment `at` (its frame grabbed and kept for
/// that thumbnail, or none to grab): flown back into it by the tree (viewer_tree.mbt's film_shared) as the rest fades.
fn Viewer::tree_film_back(self : Viewer, at : Double) -> Unit {
  self.tree_way_end.set(-1.0)
  self.tree_back.set(true)
  // (its way in over: the way back is told by the tree as it sets out, tree_way_told)
  self.tree_way.set(false)
  self.fade.go(0.0, @motion.tween(pv_fade_ms, ease=Leave), at~)
}

///|
/// Where its player draws a film's picture (@sf.player_picture_at: zoomed, moved, as it was last drawn).
fn Viewer::player_place(self : Viewer) -> (Double, Double, Double, Double)? {
  match self.media {
    Some(m) => @sf.player_picture_at(m.key())
    None => None
  }
}

///|
/// A video closing into its thumbnail, its frame grabbed: once here, its picture waited for (leaving_pic: its player
/// shown, paused, where it is meanwhile, its flight standing under it to have that picture decoded,
/// Viewer::left_with_picture); none to be had, back with its still: from the moment `at` (the answer's).
pub fn Viewer::left_with_frame(self : Viewer, at : Double) -> Unit {
  let n = match self.view() {
    Some(n) => n
    None => {
      self.grab_set(false)
      self.fly_home(at)
      return
    }
  }
  match n.grabbed() {
    Some(jpeg) =>
      if jpeg.length() > 0 {
        pv_frames_n.val += 1
        let key = "mem:pv-frame/\{pv_frames_n.val}/\{self.name}"
        @ui.add_image(key, jpeg)
        self.leaving_pic = key
        self.grab_told.set(self.grab_told.untracked() + 1)
      } else {
        self.grab_set(false)
        self.fly_home(at)
      }
    None => ()
  }
}

///|
/// A video closing into its thumbnail, the picture of the frame it showed (leaving_pic) `decoded` or failed: kept
/// for the thumbnail (with where it was) and gone back with; failed, back with its still: its player hidden as its
/// flight is drawn, setting out from the moment `at` (the decode's).
pub fn Viewer::left_with_picture(self : Viewer, decoded : Bool, at : Double) -> Unit {
  let key = self.leaving_pic
  self.leaving_pic = ""
  self.grab_set(false)
  if decoded {
    pv_frame_keep(self.id(), key, self.left_at)
  }
  self.fly_home(at)
}

///|
/// Whether a video closing into its thumbnail waits for the frame it shows to be grabbed (leaving_grab), told
/// (grab_told).
fn Viewer::grab_set(self : Viewer, on : Bool) -> Unit {
  if self.leaving_grab != on {
    self.leaving_grab = on
    self.grab_told.set(self.grab_told.untracked() + 1)
  }
}

///|
/// A tap (a click) on the stage shows or hides the bars: nothing else hides them.
pub fn Viewer::toggle(self : Viewer) -> Unit {
  self.awake = !self.awake
  self.awake_said()
}

///|
pub fn Viewer::wake(self : Viewer) -> Unit {
  if !self.awake {
    self.awake = true
    self.awake_said()
  }
}

///|
fn Viewer::awake_said(self : Viewer) -> Unit {
  self.awake_told.set(self.awake_told.untracked() + 1)
}

///|
/// Whether the bars show: awake, or a mouse's pointer along the top where the bar is, or while the whole of an image
/// comes, or over a page whose taps are its own, or while it marks. As each is told (marking: marks_said).
pub fn Viewer::bars_shown(self : Viewer) -> Bool {
  self.awake_told.get() |> ignore
  self.source_told.get() |> ignore
  marks_said()
  self.awake ||
  self.near_bar ||
  self.image_loading() ||
  ((self.shown_kind() == Some(KHtml) || self.shown_kind() == Some(KMbui)) && !self.source) ||
  marking.on
}

///|
/// The chat session this viewer was opened from (else its own session key).
pub fn Viewer::chat_session(self : Viewer) -> String {
  match self.steps {
    InChat(_, session) if session != "" => session
    _ => self.key
  }
}

///|
/// The chat's draft a marked image of this one goes into (its chat's: the session it was opened from), "" none (a
/// drive's picture).
pub fn Viewer::draft_key(self : Viewer) -> String {
  match self.steps {
    InChat(_, session) if session != "" && self.drive is None => self.station + ":" + session
    _ => ""
  }
}

///|
/// The marked image asked for: drawn by the host at the picture's own size (marks.mbt), then downloaded or put in the
/// chat's draft with a quote per numbered mark.
pub fn Viewer::finish_marks(self : Viewer, to_draft : Bool) -> Unit {
  let bytes = match self.whole_here() {
    Some(b) => b
    None => {
      if self.previewed.untracked() {
        self.error.set(None)
        self.asked = true
        self.marks_after = Some(to_draft)
        marking.busy = true
        marking.error = ""
        marks_changed()
        self.asked_told.set(self.asked_told.untracked() + 1)
      }
      return
    }
  }
  marks_put_down()
  let z = self.zoom
  match @ui.draw_marks(bytes, marks_json(z.nw, z.nh)) {
    Some(j) => {
      marking.job = Some(j)
      marking.busy = true
      marking.error = ""
      marking.to_draft = to_draft
      let base = match self.file.name.rev_find(".") {
        Some(i) if i > 0 => self.file.name.exact_view(end=i).to_owned()
        _ => self.file.name
      }
      let stamp = clock_stamp((src_now.val)())
      marking.job_name = pv_fill("android-chat.file.marked.name", [("name", base), ("stamp", stamp)])
    }
    None => marking.error = pv("android-chat.file.drawFailed")
  }
  marks_changed()
}



///|
/// A marked image drawn by the host, come: kept, or into the chat's draft (the whole window's viewer closes back to it).
pub fn Viewer::marks_frame(self : Viewer, c : @ui.Ctx) -> Unit {
  self.marks_came(fn(name, mime, png) { keep_bytes_now(name, mime, png) }, fn() { self.shut(c) })
}

///|
/// A marked image drawn by the host, come (Viewer::marks_frame's, at a cause: a tab's as the host says it is drawn):
/// kept by `keep`, or into the chat's draft, `shut` then where this viewer is not a tab's.
pub fn Viewer::marks_came(self : Viewer, keep : (String, String, Bytes) -> Unit, shut : () -> Unit) -> Unit {
  match marking.job {
    Some(j) =>
      match j.made() {
        Some(png) => {
          marking.job = None
          marking.busy = false
          if png.length() == 0 {
            marking.error = pv("android-chat.file.drawFailed")
          } else if marking.to_draft {
            let z = self.zoom
            let quotes = marks_quotes(marking.job_name, self.file.name, z.nw, z.nh)
            let key = self.draft_key()
            draft_give(key, Marked(marking.job_name, png, quotes, "image"))
            marks_leave()
            // (closed back to the chat, where the picture and its quotes show in the composer: nothing said of it; a
            // tab's stays beside it, marking left)
            if !self.beside {
              shut()
            }
          } else {
            // (the host's picture of the marks, said once)
            keep(marking.job_name, "image/png", png)
          }
          marks_changed()
        }
        // (drawn on the host's side: its word that it is done brings the frame that takes it)
        None => ()
      }
    None => ()
  }
}

///|
/// An image still coming (its thumbnail in its place meanwhile).
pub fn Viewer::coming(self : Viewer) -> Bool {
  self.shown_kind() == Some(KImage) && !self.file.path.has_prefix("draft:") && self.bytes.get() is None && self.error.get() is None
}

///|
/// A previewed image upgrading to its whole image on demand (zoomed into, or asked for).
pub fn Viewer::upgrading(self : Viewer) -> Bool {
  self.shown_kind() == Some(KImage) &&
  !self.file.path.has_prefix("draft:") &&
  self.previewed.get() &&
  self.fetching.get() &&
  self.whole_due() &&
  self.error.get() is None
}

///|
/// An image loading its initial bytes or upgrading from its preview to its whole image.
pub fn Viewer::image_loading(self : Viewer) -> Bool {
  self.coming() || self.upgrading()
}

///|
pub let file_progress_corner : Double = 14.0

///|
/// Android's C.surface2, dark, what a file's progress is on
pub let surface2_dark : Int64 = 0x2C2D31FFL

///|
/// 安装: an APK handed to the system's installer, which asks the person to confirm, once
/// its bytes are here (fetched first when it was only told of). What the system says of it comes later (app.mbt
/// system_said): the leave to install apps asked for (its page opened), 允许 still.fail 安装应用后，再次点击安装; a
/// failure, 无法安装：…. Asked by a node of the window's tree (its press, its bytes come: viewer_tree.mbt), as that is
/// done, once.
pub fn Viewer::ask_install(self : Viewer) -> Unit {
  self.bytes.get() |> ignore
  match self.whole_here() {
    Some(b) => @ui.install_package(self.file.name, b)
    None => {
      self.error.set(None)
      self.asked = true
      self.install_after = true
      self.asked_told.set(self.asked_told.untracked() + 1)
    }
  }
}

///|
/// 下载: the file into the system's downloads (on a phone a picture or a film into its photo album: keep_way_of), once
/// it is here. A chat's not read yet is downloaded by the core
/// (downloads.mbt): on by itself whatever becomes of this viewer, how far it has come said here and on its message,
/// kept once it is all here; a drive's is fetched first.
pub fn Viewer::ask_save(self : Viewer) -> Unit {
  self.bytes.get() |> ignore
  match self.whole_here() {
    // kept as keep_way_of says, said once the host has answered (keep.mbt)
    Some(b) => keep_bytes_now(self.file.name, self.mime, b)
    None => self.ask_whole()
  }
}

///|
/// Whether a file a preview shows is offered to other apps from it (分享): on a phone (iOS, Android), where the
/// system's share sheet is how a picture or a file goes on to another app (WeChat, Files); beside download, which
/// keeps it on the phone. Asked for 2026-11-11 (「建议图片和文件支持ios分享功能」, then Android's too).
pub fn shares_out() -> Bool {
  @sf.picture_to_album()
}

///|
/// 分享: the file handed to the system's share sheet (@ui.share) once it is here, read whole first where it was only
/// told of (as Viewer::ask_install's, then handed on as it comes: share_after); 本机没有可打开此文件的应用 when
/// nothing takes it.
pub fn Viewer::ask_share(self : Viewer) -> Unit {
  match self.whole_here() {
    Some(b) => if !@ui.share("", self.file.name, self.mime, b) { toast_later(@sf.t("android-misc.drive.noApp")) }
    None => {
      self.error.set(None)
      self.asked = true
      self.share_after = true
      self.asked_told.set(self.asked_told.untracked() + 1)
    }
  }
}

///|
/// What was asked to be shared before it was here, handed on as its whole comes, once (Viewer::ask_share).
pub fn Viewer::share_came(self : Viewer) -> Unit {
  if self.share_after && self.whole_here() is Some(_) {
    self.share_after = false
    self.ask_share()
  }
}

///|
/// Ask for the whole image in place of its preview (e.g. when entering marking).
pub fn Viewer::request_whole(self : Viewer) -> Unit {
  if !self.file.path.has_prefix("draft:") && self.previewed.untracked() && !self.asked {
    self.error.set(None)
    self.asked = true
    self.asked_told.set(self.asked_told.untracked() + 1)
  }
}

///|
/// 复制: put the whole image on the clipboard, or fetch the whole image first while a preview shows.
pub fn Viewer::ask_copy(self : Viewer) -> Bool {
  match self.whole_here() {
    Some(b) => {
      @hostapi.clipboard_set_image(b)
      @ui.haptic(KeyboardTap)
      self.copied += 1
      true
    }
    None => {
      if self.bytes.untracked() is Some(_) {
        self.error.set(None)
        self.asked = true
        self.copy_after = true
        self.asked_told.set(self.asked_told.untracked() + 1)
      }
      false
    }
  }
}

///|
/// What was asked to be copied before its whole was here, copied once the whole arrives (Viewer::ask_copy).
pub fn Viewer::copy_came(self : Viewer) -> Unit {
  if self.copy_after {
    match self.whole_here() {
      Some(b) => {
        self.copy_after = false
        @hostapi.clipboard_set_image(b)
        @ui.haptic(KeyboardTap)
        self.copied += 1
        toast_later(@sf.t("common.copied"))
      }
      None => ()
    }
  }
}

///|
/// What was asked to finish marking before its whole was here, finished once the whole arrives (Viewer::finish_marks).
pub fn Viewer::marks_finish_came(self : Viewer) -> Unit {
  match self.marks_after {
    Some(to_draft) if self.whole_here() is Some(_) => {
      self.marks_after = None
      if marking.on {
        self.finish_marks(to_draft)
      }
    }
    _ => ()
  }
}

///|
/// 下载 pressed on a node of the window's tree (a tab's tools beside a chat: viewer_tab.mbt), outside any build: as
/// Viewer::ask_save, what is here handed to the host at once (keep_now).
pub fn Viewer::save_now(self : Viewer) -> Unit {
  self.bytes.get() |> ignore
  match self.whole_here() {
    Some(b) => keep_now(self.file.name, self.mime, b)
    None => self.ask_whole()
  }
}

///|
/// 下载 of what is not here yet: a chat's file downloaded by the core, anything else read whole first (Viewer::ask_save's).
fn Viewer::ask_whole(self : Viewer) -> Unit {
  if self.chat_file() {
    self.download_asked = true
  } else {
    self.error.set(None)
    self.asked = true
    self.save_after = true
  }
  self.asked_told.set(self.asked_told.untracked() + 1)
}

///|
/// The core's download of this chat's file while it is listed (under way, ready, failed): None for a drive's.
pub fn Viewer::download(self : Viewer, src : Source) -> Json? {
  if !self.chat_file() {
    return None
  }
  download_of(src, self.station, self.key, self.name)
}

///|
/// Whether the core has the download `dl` under way (going, waiting for its station, ready, being saved).
pub fn downloading(dl : Json?) -> Bool {
  flag(dl, "active")
}

///|
/// The core's download of the file this viewer shows called off (✕ under how far it has come: a press on a node of the
/// window's tree, viewer_tree.mbt), as it is pressed.
pub fn Viewer::cancel_download(self : Viewer, src : Source, dl : Json?) -> Unit {
  ignore(self)
  download_cancel(src, text(dl, "id"))
}

// ── an image ───────────────────────────────────────────────────────────

///|
/// The most pixels an image is decoded to on its longer side, on the stage.
pub let stage_px : Int = 4096

///|
/// The decode cap on the stage: 8192 on desktop/web so tall screenshots stay crisp when zoomed, 4096 on phones.
pub fn stage_max_px() -> Int {
  if @sf.picture_to_album() { stage_px } else { 8192 }
}

///|
/// The decode cap for this viewer: station previews are at most 2048 px, whole images use stage_max_px().
fn Viewer::decode_max_px(self : Viewer) -> Int {
  if self.previewed.untracked() {
    2048
  } else {
    stage_max_px()
  }
}

///|
/// What an image shows drawn at `r` (where it is on the stage, or lands): its whole picture once that is decoded (its
/// decode for that size asked for here where it is not), until then what stands in for it: one picture takes
/// another's place only once it can be drawn, never a frame of nothing between them.
pub fn Viewer::shown_picture(self : Viewer, c : @ui.Ctx, src : Source, r : (Double, Double, Double, Double)) -> String {
  let picture = self.picture(src)
  if picture != self.image {
    return picture
  }
  let (_, _, w, h) = r
  if c.image_ready(picture, dmin(dmax(w, h) * c.scale, self.decode_max_px().to_double())) {
    return picture
  }
  match self.stand_in(src) {
    "" => picture
    k => k
  }
}

///|
/// The picture's own menu at (`x`, `y`).
/// (a handler's: what it does is asked of the host as its item is chosen)
fn Viewer::picture_menu_at(self : Viewer, x : Double, y : Double) -> Unit {
  let (label, glyph) = @sf.picture_out_way()
  let out = fn() {
    if @sf.picture_to_album() {
      match self.whole_here() {
        Some(b) => keep_bytes_now(self.name, self.mime, b, way=Photos)
        None => self.save_now()
      }
    } else {
      self.ask_copy() |> ignore
    }
  }
  let items = [Some(@sf.menu_item_of(label, out, icon=glyph))]
  if shares_out() {
    items.push(Some(@sf.menu_item_of(@sf.t("android-misc.drive.share"), fn() { self.ask_share() }, icon="share")))
  }
  @sf.menu(items, from=@sf.at_point(x, y))
}

///|
/// The images beside this one (after): a chat's as the core tells them (`imageNear`, each with
/// the session that keeps it), a folder's by its order; their viewers kept (and read ahead) while they are beside it.
/// `kept`: where they are kept (the whole window's strip's; a tab's own: viewer_tab.mbt).
pub fn Viewer::near(self : Viewer, src : Source, kept? : Map[String, Viewer] = pv_strip.near) -> (Viewer?, Viewer?) {
  self.near_by(src, fn(id, f) {
    match kept.get(id) {
      Some(n) => n
      None => {
        let n = f()
        kept[id] = n
        n
      }
    }
  })
}

///|
/// Which images are beside this one (Viewer::near's, by their ids): what is said of them, no viewer made for them.
pub fn Viewer::near_ids(self : Viewer, src : Source) -> (String?, String?) {
  self.near_by(src, fn(id, _) { id })
}

///|
/// The images beside this one, each as `made` takes it (its id, and how its viewer is made).
fn[T] Viewer::near_by(self : Viewer, src : Source, made : (String, () -> Viewer) -> T) -> (T?, T?) {
  if self.shown_kind() != Some(KImage) {
    return (None, None)
  }
  match self.steps {
    NoSteps => (None, None)
    InChat(thread, session) => {
      let p : Map[String, Json] = { "station": Json::string(self.station), "path": Json::string(self.file.path) }
      let at = self.gallery_at()
      if at != "" {
        p["at"] = Json::string(at)
      }
      match thread {
        Some(th) => p["thread"] = Json::number(th)
        None => p["session"] = Json::string(session)
      }
      near_asked[Json::object(p).stringify()] = p
      let told = src.topic("imageNear", p).get().value
      let side = fn(k : String) -> T? {
        match field(told, k) {
          Some(Object(_) as j) => {
            let a = attachment_of(j)
            let key = if a.owner != "" { a.owner } else { self.key }
            let at = text(told, k + "At")
            let file = self.station + "/" + key + "/" + a.path
            Some(made(thumb_place(file, self.station, session, at), fn() { new_viewer(self.station, key, a, None, self.steps, at~) }))
          }
          _ => None
        }
      }
      (side("before"), side("after"))
    }
    InFolder(files) => {
      let mut at = -1
      for i, f in files {
        if Some(f.path) == self.drive.map(fn(d) { d.path }) {
          at = i
        }
      }
      if at < 0 {
        return (None, None)
      }
      let side = fn(i : Int) -> T? {
        match files.get(i) {
          Some(f) =>
            Some(
              made(f.station + "/drive:" + f.root + "/" + f.path, fn() {
                new_viewer(f.station, "", drive_attachment(f), Some(f), self.steps)
              }),
            )
          None => None
        }
      }
      (if at > 0 { side(at - 1) } else { None }, side(at + 1))
    }
  }
}

///|
/// A drive's file as the viewer takes one (no size of its picture, no likeness).
pub fn drive_attachment(f : DriveFile) -> Attachment {
  { name: f.name, path: f.path, size: f.size, width: 0.0, height: 0.0, thumbhash: "", owner: "", upload: "", duration: 0.0, frames: 0, held: false }
}

///|
/// Whether its whole picture, read, could not be decoded (what draws it then says so alone: no picture, no stand-in,
/// no marks, no flight). As the host says it.
pub fn Viewer::picture_failed(self : Viewer) -> Bool {
  match self.bytes.get() {
    Some(_) => {
      let key = if self.image != "" { self.image } else { self.image_name() }
      @ui.image_state(key) == -1
    }
    None => false
  }
}

///|
/// Whether the size of what it shows (Viewer::picture) is neither sent with it nor known yet, nothing of it decoded:
/// what draws it asks a small decode of it, out of sight, that says it. As the host says it.
fn Viewer::size_unknown(self : Viewer, src : Source) -> Bool {
  let picture = self.picture(src)
  picture != "" && !(self.file.width > 0.0 && self.file.height > 0.0) && @ui.image_natural(picture) is None
}

///|
/// What its whole picture is called once read (Viewer::picture).
fn Viewer::image_name(self : Viewer) -> String {
  "mem:preview/" + self.id()
}

///|
/// What its station preview picture is called once read, kept distinct from the whole image key so upgrading never
/// collides with the host's decoded-image cache and keeps the preview as stand-in while the whole image decodes.
fn Viewer::preview_image_name(self : Viewer) -> String {
  "mem:preview-p/" + self.id()
}

///|
/// Its whole read as `b`: a chat's image put up as its whole picture (Viewer::picture's), and given to the chat's
/// picture of it, which shows it where its own (the station's thumbnail) is not here yet (ChatImages::whole): an image
/// opened and read is never missing where its message shows it.
fn Viewer::took_whole(self : Viewer, src : Source, b : Bytes) -> Unit {
  guard self.chat_file() && self.shown_kind() == Some(KImage) && b.length() > 0 else { return }
  if self.previewed.untracked() {
    let key = self.preview_image_name()
    if self.preview_image != key {
      self.preview_image = key
      @ui.add_image(key, b)
    }
    self.image = key
  } else {
    let key = self.image_name()
    if self.image != key {
      self.image = key
      @ui.add_image(key, b)
    }
  }
  src.images.whole(file_image_id(self.station, self.key, self.name), self.image, size=b.length())
}

///|
/// Whether a viewer's picture `key` (its whole picture: Viewer::image_name) is what any viewer but `but` shows or leaves
/// with (the one open, the one going, one beside a chat, those read ahead beside them, the one the strip slides out).
fn preview_shown(key : String, but? : Viewer) -> Bool {
  let shows = fn(v : Viewer?) {
    match v {
      Some(v) if !(but is Some(b) && physical_equal(b, v)) =>
        v.image == key || v.preview_image == key || v.leaving_pic == key
      _ => false
    }
  }
  shows(viewer.untracked()) ||
  shows(pv_leaving.untracked()) ||
  tab_viewers.values().any(fn(t) { shows(Some(t.viewer)) || t.near.values().any(fn(n) { shows(Some(n)) }) }) ||
  pv_strip.near.values().any(fn(n) { shows(Some(n)) }) ||
  pv_strip.leaving.map(fn(l) { l.picture == key }).unwrap_or(false)
}

///|
/// What shows of an image: its whole picture once read, else what stands in for it; "" while none is here.
pub fn Viewer::picture(self : Viewer, src : Source) -> String {
  match self.bytes.get() {
    Some(b) if self.image == "" => {
      let key = if self.previewed.untracked() {
        let k = self.preview_image_name()
        self.preview_image = k
        k
      } else {
        self.image_name()
      }
      self.image = key
      @ui.add_image(key, b)
    }
    _ => ()
  }
  if self.image != "" {
    return self.image
  }
  self.stand_in(src)
}

///|
/// What stands in for an image until its whole picture is here and decoded: the picture it was picked as here (one
/// sent, one still in a draft: never asked of a station), else the station's thumbnail of it, else its likeness; ""
/// none. Read by a node, told as either comes.
pub fn Viewer::stand_in(self : Viewer, src : Source) -> String {
  if self.preview_image != "" && self.image != self.preview_image {
    return self.preview_image
  }
  if self.chat_file() {
    match sent_picture_told(self.station, self.file) {
      Some(k) if k != "" && k != "!" => return k
      _ => ()
    }
  }
  let thumb = match self.draft_id() {
    Some(id) => writing_picture_told(id).unwrap_or("")
    None => if self.chat_file() { src.file_told(self.station, self.key, self.name) } else { "" }
  }
  if thumb != "" && thumb != "!" {
    thumb
  } else {
    @gallery.thumbhash_image(self.file.thumbhash).unwrap_or("")
  }
}

///|
/// The images beside the one shown read ahead after its bytes came or failed, so they do not compete with it on a slow
/// link. A step can still open either at once; those no longer beside it are let go (of `kept`, where they are kept:
/// Viewer::near's).
pub fn Viewer::read_near(
  self : Viewer,
  src : Source,
  before : Viewer?,
  after : Viewer?,
  kept? : Map[String, Viewer] = pv_strip.near,
) -> Unit {
  let ids = []
  let ready = self.bytes.get() is Some(_) || self.error.get() is Some(_)
  for n in [before, after] {
    match n {
      Some(n) => {
        ids.push(n.thumb_id())
        if ready && n.bytes.get() is None && !n.fetching.get() && n.error.get() is None && n.file.size <= big_file {
          n.fetching.set(true)
          n.read_whole(src, fn(r) {
            n.fetching.set(false)
            match r {
              Ok(b) => {
                n.took_whole(src, b)
                n.bytes.set(Some(b))
                if !n.previewed.untracked() {
                  keep_read(n.id(), b)
                }
              }
              Err(_) => n.error.set(Some(""))
            }
          })
        }
      }
      None => ()
    }
  }
  let gone = []
  kept.each(fn(id, _) { if !ids.contains(id) && id != self.thumb_id() { gone.push(id) } })
  let left : Array[Viewer] = []
  for id in gone {
    match kept.get(id) {
      Some(v) => left.push(v)
      None => ()
    }
    kept.remove(id)
  }
  // (read ahead and no longer beside it: what each read let go of, now none of them is kept)
  for v in left {
    v.let_go()
  }
}

///|
/// Where a picture of (nw, nh) shows fitted on a stage of (bw, bh) (the viewer's fit: a margin round it, never
/// enlarged).
pub fn fitted_rect(
  nw : Double,
  nh : Double,
  bw : Double,
  bh : Double,
  bar? : Double = 0.0,
) -> (Double, Double, Double, Double)? {
  // (a zoom of its own, told once and nothing moving on it: the same at any moment)
  let z = @motion.Zoom::new()
  z.boxed(bw, bh, at=0.0)
  z.under_bars(bar, 0.0, at=0.0)
  z.natural(nw, nh, at=0.0)
  z.rect_at(0.0)
}

///|
/// The size of a viewer's picture: as sent, else as decoded, else (its whole come and not yet decoded) its stand-in's
/// meanwhile: never none while something of it shows.
pub fn Viewer::natural_size(self : Viewer, src : Source) -> (Double, Double) {
  if self.file.width > 0.0 && self.file.height > 0.0 {
    return (self.file.width, self.file.height)
  }
  match @ui.image_natural(self.picture(src)) {
    Some(s) => s
    None => @ui.image_natural(self.stand_in(src)).unwrap_or((0.0, 0.0))
  }
}

///|
/// To the one before (`dir` -1) or after (1): it takes this one's place, coming in from that side
/// as this one goes out to the other (the strip on SLIDE from where the finger left it, at its speed); with none
/// there, back.
pub fn Viewer::go(self : Viewer, c : @ui.Ctx, src : Source, dir : Int, velocity : Double) -> Unit {
  let strip = pv_strip.way
  let at = viewer_moment(c)
  let (before, after) = self.near(src)
  let to = if dir < 0 { before } else { after }
  match to {
    None => strip.go(0.0, @motion.carousel_spring, at~, velocity~)
    Some(n) => {
      let width = self.zoom.bw + slide_gap
      let from = strip.value_at(at)
      // (as it shows: its stand-in while its whole is not decoded)
      pv_strip.leaving = match self.zoom.rect_at(at) {
        Some(r) if self.picture(src) != "" => {
          let (x, y, w, h) = r
          Some({ picture: self.shown_picture(c, src, r), x, y, w, h, dir, width })
        }
        _ => None
      }
      // shown at once: no fade; its bars as they were (only a tap hides or shows them, the user 2026-10-28)
      n.started = true
      n.fade.put(1.0)
      n.awake = self.awake
      n.awake_said()
      viewer.set(Some(n))
      pv_strip.near.remove(n.thumb_id())
      // (its whole picture let go of once the strip no longer slides it out: pv_previews_gone)
      self.let_go_image()
      strip.put(from + dir.to_double() * width)
      strip.go(0.0, @motion.carousel_spring, at~, velocity~)
      @ui.log("preview: stepped to \{n.file.name}")
    }
  }
}

///|
/// The wheel turned (`wx`, `wy`, with `mods` held) at (`px`, `py`) on the stage at `at` (its moment: how big the picture
/// shows then, whether zoomed then, and what it is told from there, by its glide or fling as they have it then, never
/// by what a frame last copied): a desktop's pans (⇧ sideways), with ⌃ or ⌘ held (or a trackpad's pinch) zooms round
/// the pointer; a phone's zooms.
pub fn Viewer::wheeled(
  _self : Viewer,
  z : @motion.Zoom,
  px : Double,
  py : Double,
  wx : Double,
  wy : Double,
  mods : Int,
  at : Double,
) -> Unit {
  let desk = @sf.pointer_rests()
  // (a zoom's wheel over the picture is its own: a browser's page zooms by none of it)
  if (mods & (@ui.wheel_mod_ctrl | @ui.wheel_mod_cmd | @ui.wheel_mod_pinch)) != 0 {
    @ui.keep_zoom_wheel()
  }
  if desk && z.nw > 0.0 && (wx != 0.0 || wy != 0.0) {
    if (mods & (@ui.wheel_mod_ctrl | @ui.wheel_mod_cmd)) != 0 {
      let fine = (mods & @ui.wheel_mod_ctrl) != 0 && wy.abs() < desk_pinch_step
      z.zoom_to(
        z.scale_at(at) * @dmath.exp(-wy * (if fine { desk_pinch_rate } else { desk_wheel_rate })),
        px,
        py,
        false,
        at~,
      )
    } else if !z.zoomed_at(at) {
      // (fitted, it is all in view: nothing to pan, and it stays fitted as the window changes)
      ()
    } else if (mods & @ui.wheel_mod_shift) != 0 && wx == 0.0 {
      z.pan(-wy, 0.0, at~)
    } else {
      z.pan(-wx, -wy, at~)
    }
  } else if !desk && wy != 0.0 && z.nw > 0.0 {
    z.zoom_to(z.scale_at(at) * @dmath.pow(1.0015, -wy), px, py, false, at~)
  }
}

///|
/// One finger moving a zoomed picture by (dx, dy): it goes with the finger; at its edge, what of the way across it
/// cannot go pulls in the one beside it (the strip, as a swipe does it fitted: past the first or the last a third as
/// far), but only from an edge it was at as the finger went down: a press that brings it to its edge stops there, and
/// another from there goes on to the one beside it (the user, 2026-10-28); the finger going back takes the strip back
/// first.
pub fn Viewer::drag_zoomed(
  self : Viewer,
  z : @motion.Zoom,
  strip : @motion.Way,
  dx : Double,
  dy : Double,
  has_before : Bool,
  has_after : Bool,
  at : Double,
) -> Unit {
  // how far the strip goes for a point of the finger's way toward the one before (> 0) or after
  let give = fn(toward : Double) { if (if toward > 0.0 { has_before } else { has_after }) { 1.0 } else { 1.0 / 3.0 } }
  let mut across = dx
  let s = strip.value_at(at)
  if s != 0.0 && across != 0.0 && (across > 0.0) != (s > 0.0) {
    let back = -s / give(s)
    if across.abs() <= back.abs() {
      strip.put(s + across * give(s))
      across = 0.0
    } else {
      strip.put(0.0)
      across = across - back
    }
  }
  let x0 = z.rect_at(at).map(fn(r) { r.0 }).unwrap_or(0.0)
  z.pan(across, dy, at~)
  let left = across - (z.rect_at(at).map(fn(r) { r.0 }).unwrap_or(0.0) - x0)
  let from_edge = if left > 0.0 { self.at_left } else { self.at_right }
  if left.abs() > 0.001 && (has_before || has_after) && from_edge {
    if !self.swiping {
      self.swiping = true
      pv_strip.leaving = None
    }
    strip.put(strip.value_at(at) + left * give(left))
  }
}

// ── a video ────────────────────────────────────────────────────────────

///|
/// The chat's still of a video, as the chat shows it: the frame it was left at when it was
/// closed into its thumbnail, else what its thumbnail shows, else the station's poster (its first frame); an image's
/// key, "" while it comes or where there is none (a drive's file).
pub fn Viewer::still(self : Viewer, src : Source) -> String {
  if !self.chat_file() {
    return ""
  }
  pv_frame_track(self.id())
  match pv_frames.get(self.id()) {
    // (where it was left kept with no frame of it: what shows of it as before)
    Some((k, _)) if k != "" => return k
    _ => ()
  }
  // (one sent from here: the picture it was picked as, where no thumbnail of it was drawn)
  match sent_picture_told(self.station, self.file) {
    Some(k) if k != "" && k != "!" => return k
    _ => ()
  }
  // (one still in a draft: what was picked of it, else the first frame drawn here of its bytes; never a station's)
  match self.draft_id() {
    Some(id) =>
      match writing_picture_told(id) {
        Some(k) if k != "" && k != "!" => return k
        _ => {
          pv_first_told.get() |> ignore
          return match pv_first.get("draft/" + id) {
            Some(f) if f.picture != "!" => f.picture
            _ => ""
          }
        }
      }
    None => ()
  }
  match src.poster_told(self.station, self.key, self.name) {
    // none made by the station: the first frame the chat drew of it, if it did
    "!" => {
      pv_first_told.get() |> ignore
      match pv_first.get(self.id()) {
        Some(f) if f.picture != "!" => f.picture
        _ => ""
      }
    }
    k => k
  }
}

///|
/// Where a film left at player `n` goes on from as it is opened again (ms): where it is, but from its start where it
/// has played to its end (or within left_end_ms of it: a short recording watched through, opened again, plays again,
/// never opened at its end).
fn left_from(n : @ui.NativeView) -> Double {
  let (at, d) = (n.position(), n.duration())
  if n.ended() || (d > 0.0 && at >= d - left_end_ms) {
    0.0
  } else {
    at
  }
}

///|
/// How near its end a film left counts as played through (left_from).
let left_end_ms : Double = 250.0

///|
/// A chat's video closed: where its player has got to (left_from) kept for its thumbnail's id (pv_frames), so that
/// opened again it goes on from there, whether its thumbnail is on the screen or not; no frame with it ("": its still
/// as before) till the one it shows is grabbed (Viewer::left_with_picture), a frame kept from where it was left before
/// not shown for where it is now. Back at its start (taken back there, or played through), nothing kept: from its
/// start, its still.
fn Viewer::keep_left_at(self : Viewer) -> Unit {
  guard self.chat_file() && self.shown_kind() == Some(KVideo) && self.view() is Some(n) else { return }
  let at = left_from(n)
  let id = self.id()
  if at > 0.0 {
    pv_frame_keep(id, "", at)
  } else if pv_frames.get(id) is Some((was, _)) {
    pv_frames.remove(id)
    pv_frames_used.remove(id)
    pv_frame_dropped(was)
    pv_frame_tell(id)
  }
}

///|
/// How many thumbnails' frames are kept (pv_frames, pv_first): those least lately kept let go of beyond it, the
/// thumbnail showing its still as before (the station's poster, its first frame drawn again).
let pv_frames_max : Int = 64

///|
/// When each of pv_frames was last kept, by the thumbnail's id (pv_frames_tick's count).
// kept across runs: let go with pv_frames (viewer's clear)
let pv_frames_used : Map[String, Int] = Map([])

///|
// kept across runs: put back with pv_frames (viewer's clear)
let pv_frames_tick : Ref[Int] = { val: 0 }

///|
/// The frames' pictures no longer kept for any thumbnail (one kept for it in their place, or it let go of), let go of
/// once no viewer shows or flies with them (pv_frames_sweep): a viewer closing flies with the frame it was opened
/// from till its way back is over.
// kept across runs: let go with pv_frames (viewer's clear)
let pv_frames_gone : Array[String] = []

///|
/// The frame of thumbnail `id` kept as `key` ("" none: its still as before), left at `at`: the one kept for it before let
/// go of, and the least lately kept beyond pv_frames_max.
fn pv_frame_keep(id : String, key : String, at : Double) -> Unit {
  match pv_frames.get(id) {
    Some((was, _)) if was != key => pv_frame_dropped(was)
    _ => ()
  }
  pv_frames[id] = (key, at)
  pv_frames_tick.val += 1
  pv_frames_used[id] = pv_frames_tick.val
  pv_frame_tell(id)
  while pv_frames.length() > pv_frames_max {
    let mut oldest = ""
    let mut when = 0
    for k, t in pv_frames_used {
      if k != id && (oldest == "" || t < when) {
        oldest = k
        when = t
      }
    }
    guard oldest != "" && pv_frames.get(oldest) is Some((was, _)) else { break }
    pv_frames.remove(oldest)
    pv_frames_used.remove(oldest)
    pv_frame_dropped(was)
    pv_frame_tell(oldest)
  }
  pv_frames_sweep()
}

///|
/// A frame's picture no longer kept for its thumbnail (pv_frames_gone).
fn pv_frame_dropped(key : String) -> Unit {
  if key != "" && key != "!" {
    pv_frames_gone.push(key)
  }
}

///|
/// The frames' pictures no longer kept (pv_frames_gone) let go of where nothing shows them: no thumbnail's frame, no
/// viewer but `but` (one letting go of what it holds) open, going or beside a chat with it.
fn pv_frames_sweep(but? : Viewer) -> Unit {
  let still : Array[String] = []
  for key in pv_frames_gone {
    if pv_frames.values().any(fn(f) { f.0 == key }) {
      continue
    }
    if preview_shown(key, but?=but) {
      still.push(key)
    } else {
      @ui.forget_image(key)
    }
  }
  pv_frames_gone.clear()
  pv_frames_gone.push_iter(still.iter())
}

///|
/// The same at the moment `at`, its player laid out `width` wide.
fn Viewer::video_rect_in(self : Viewer, width : Double, at : Double) -> (Double, Double, Double, Double)? {
  let top = @sf.player_room(width).0
  self.vzoom.rect_at(at).map(fn(r) { (r.0, r.1 + top, r.2, r.3) })
}

///|
/// How a film's picture is fitted on the stage (Viewer's vzoom, and where it flies to before that is fitted): edge to
/// edge, no margin, made bigger where it is smaller than the stage.
fn video_zoom() -> @motion.Zoom {
  @motion.Zoom::new(margin=fn(_) { 0.0 }, enlarge=true)
}

///|
/// How big a film's picture is (what the player fits it by, Viewer::player_stage, and what its flight goes to before
/// that): as its player says, else as it was sent, else as its still is; none known, (0, 0).
fn Viewer::video_natural(self : Viewer, src : Source) -> (Double, Double) {
  match self.view().map(fn(n) { n.natural() }) {
    Some((nw, nh)) if nw > 0.0 && nh > 0.0 => return (nw, nh)
    _ => ()
  }
  if self.file.width > 0.0 && self.file.height > 0.0 {
    return (self.file.width, self.file.height)
  }
  let still = if self.shown_kind() == Some(KVideo) { self.still(src) } else { "" }
  match @ui.image_natural(still) {
    Some((sw, sh)) if still != "" && sw > 0.0 && sh > 0.0 => (sw, sh)
    _ => (0.0, 0.0)
  }
}

///|
/// Where a film's picture is, its player laid out `width` by `height`: where the player fitted it (Viewer::video_rect_in);
/// before it has (its first frame: the flight in setting out as it opens), where it will, by the same size
/// (Viewer::video_natural), in the room the player leaves it, at the moment `at`. None, its size not known.
fn Viewer::video_target(
  self : Viewer,
  src : Source,
  width : Double,
  height : Double,
  at : Double,
) -> (Double, Double, Double, Double)? {
  match self.video_rect_in(width, at) {
    Some(r) => Some(r)
    None => {
      let (nw, nh) = self.video_natural(src)
      let (top, foot) = @sf.player_room(width)
      // (fitted as the player fits it: its zoom's way, edge to edge, made bigger where it is smaller)
      let z = video_zoom()
      z.boxed(width, height - top - foot, at~)
      z.natural(nw, nh, at~)
      z.rect_at(at).map(fn(r) { (r.0, r.1 + top, r.2, r.3) })
    }
  }
}

///|
/// The player's view of a film or a song (the system's player in a native view), while one is open.
pub fn Viewer::view(self : Viewer) -> @ui.NativeView? {
  match self.media {
    Some(m) => m.native()
    None => None
  }
}

///|
/// Haze's blur of 24 dp and 20 dp as CSS's (glass.mbt: (px - 0.5) / 0.57735 dp).
pub let dark_glass_blur : Double = 24.0 * 0.57735 + 0.5

///|
/// The dark translucent liquid glass over media (`viewer_head_node`, `viewer_marks_node`): iOS 27 calibrated
/// clear-dark glass keeping white foreground ink >= 4.5:1 over bright photo highlights.
pub fn dark_glass() -> @ui.Glass {
  @sf.glass_viewer_dark()
}

///|
/// The same over a document: the surface at 72% (dark, surface2's) over its blur, over the
/// viewer's canvas.
pub fn page_glass() -> @ui.Glass {
  @sf.viewer_page_glass()
}

// ── text ───────────────────────────────────────────────────────────────

///|
/// Past this a file shows as plain text, unhighlighted.
pub let highlight_limit : Int = 256 * 1024

///|
/// Highlighted runs cut at their line ends: a line's runs each (none for an empty line), in the code face.
pub fn runs_by_line(runs : Array[@ui.Run]) -> Array[Array[@ui.Run]] {
  let out : Array[Array[@ui.Run]] = [[]]
  for r in runs {
    let parts = r.text.split("\n").map(fn(p) { p.to_owned() }).to_array()
    for k, part in parts {
      if k > 0 {
        out.push([])
      }
      if part != "" {
        out[out.length() - 1].push({ ..r, text: part, mono: true })
      }
    }
  }
  out
}

// ── the bar ────────────────────────────────────────────────────────────


///|
/// What the viewer keeps put back as the app begins anew (sfbase's reset).
pub fn file_viewer_reset() -> Unit {
  close_now()
  whole_given.clear()
  pv_previews_gone.clear()
  marking.color = 0xE5704AFFL
  marking.next_id = 1
  marking.to_draft = false
  marking.job_name = ""
  marking.write_field.set("")
  marking.note_field.set("")
  marks_changed()
  pv_frames.clear()
  let told = pv_frames_told.keys().to_array()
  for id in told {
    pv_frame_tell(id)
  }
  pv_frames_told.clear()
  pv_frames_n.val = 0
  pv_frames_used.clear()
  pv_frames_tick.val = 0
  pv_frames_gone.clear()
  pv_first.clear()
  pv_first_used.clear()
  pv_first_shown.clear()
  pv_first_n.val = 0
  marks_foot_taken.set(0.0)
  pv_read.clear()
  pv_strip.leaving = None
  pv_strip.way.put(0.0)
  pv_strip.pinned = None
  pv_strip.near.clear()
  pv_strip.wheel.reset()
  near_asked.clear()
  rows_sent_as.clear()
  tab_viewers_reset()
}

///|
/// A video's still as the viewer left it; else, one sent from here, the host's picture of it as it was picked (the
/// composer's tile's: going up and gone up alike, as an image sent from here is drawn: sent_picture); else the
/// station's poster (or its first frame drawn here when the station made none), for a node of the window's tree `v`
/// (a chat's things' tile), read as it comes. `thumb`: its thumbnail's id.
pub fn video_still_node(v : @view.View, src : Source, station : String, owner : String, a : Attachment, thumb : String) -> () -> String {
  let known = fn() { video_still_known(src, station, owner, a, thumb, told=true) }
  // (its first frame's, asked as the station is known to have made none: then, once)
  let first : @signals.Signal[(() -> String)?] = @signals.signal_ref(None)
  v.reacts(fn() { known() == "!" }, fn(none) {
    if none && first.untracked() is None {
      first.set(Some(first_frame_node(v, src, station, owner, a, thumb)))
    }
  })
  fn() {
    match known() {
      "!" =>
        match first.get() {
          Some(f) => f()
          None => ""
        }
      k => k
    }
  }
}

///|
/// The same as far as it is known without drawing a frame of it here (what a node shows: the viewer's still, one sent
/// from here, the station's poster): "!" where the station made none.
/// `told`: read by a node, told as the frame kept or the station's still changes (the tracking reads: pv_frame_track,
/// Source::poster_told).
fn video_still_known(src : Source, station : String, owner : String, a : Attachment, thumb : String, told? : Bool = false) -> String {
  if told {
    pv_frame_track(thumb)
  }
  match pv_frames.get(thumb) {
    // (where it was left kept with no frame of it: its still as before)
    Some((k, _)) if k != "" => k
    _ =>
      match (if told { sent_picture_told(station, a) } else { sent_picture(station, a) }) {
        Some(k) => k
        None => if told { src.poster_told(station, owner, base_name(a.path)) } else { (src.poster)(station, owner, base_name(a.path)) }
      }
  }
}

///|
/// 源码 (`on`) or 预览 shown, told at once to what shows it and what says it (viewer_stage_node, its bars,
/// Viewer::bars_shown): the page under the canvas let go while its source shows (and made again as it comes back).
pub fn Viewer::set_source(self : Viewer, on : Bool) -> Unit {
  if on == self.source {
    return
  }
  self.source = on
  if on {
    match self.page {
      Some(p) => p.close()
      None => ()
    }
    self.page = None
  }
  self.source_told.set(self.source_told.untracked() + 1)
}
