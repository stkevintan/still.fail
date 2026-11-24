// What the last update brought and what the update wants of the person (changelog.mbt's) as nodes of the window's
// tree, made once at the top of a chats' list: the cards the old frame drew there, laid out as it laid them out, what
// they say bound to the core's `changelog` topic and the update's state as they change.

///|
/// The news card in `parent`, while there is news: the build it is now and its first changes, a
/// press opens the changelog; its × (its tip in `tips`) lets it go at once and tells the core.
pub fn changelog_news_node(parent : @view.View, src : Source, tips : @sf.TipLayer) -> Unit {
  let news = fn() { news_of(src) }
  let lines = fn() {
    let out : Array[String] = []
    for e in items(news(), "entries") {
      for l in items(Some(e), "text") {
        match l {
          String(s) => out.push(s)
          _ => ()
        }
      }
    }
    out
  }
  // PageParts.kt ChangelogNews: clickable, cut to the card's corners, read out as the old frame's box was (all it says)
  @sf.news_card_node(
    parent,
    "sparks",
    fn() { news_title_now(news()) },
    fn() {
      let said = [news_title_now(news())]
      said.append(lines()[:@cmp.minimum(news_lines_most, lines().length())].to_owned())
      if lines().length() > news_lines_most {
        said.push(@sf.t("android-settings.changelog.more", args=[("n", (lines().length() - news_lines_most).to_string())]))
      }
      said.join(" ")
    },
    fn() { open_page(Setting(@settings.Route::Changelog)) },
    fn(words) {
      for i in 0..<news_lines_most {
        words.show(fn() { i < lines().length() }, fn(l) {
          @sf.words_node(l, fn() { lines().get(i).unwrap_or("") }, fn() { @sf.news_card_line }) |> ignore
        })
      }
      words.show(fn() { lines().length() > news_lines_most }, fn(l) {
        @sf.words_node(
          l,
          fn() { @sf.t("android-settings.changelog.more", args=[("n", (lines().length() - news_lines_most).to_string())]) },
          fn() { @sf.news_card_line },
        )
        |> ignore
      })
    },
    // let go: gone at once, the core told
    close=(tips, fn() { @sf.t("android-settings.changelog.dismiss") }, fn() {
      news_gone.set(@signals.untracked(news))
      (src.call)("changelog.seen", Json::object({}), @sfbase.answer_unread)
    }),
  )
  |> ignore
}

///|
/// The news's title: the build it brought, where it says one.
fn news_title_now(news : Json?) -> String {
  match @sfbase.opt_text(news, "build") {
    Some(b) => @sf.t("android-settings.changelog.updatedTo", args=[("build", b)])
    None => @sf.t("android-settings.changelog.updated")
  }
}

///|
/// The update's card in `parent`: 允许安装更新 and why; a press does it (@sfbase.update_go). No ×: it
/// goes once given (what holds it shows it while update_card_shown).
pub fn update_card_node(parent : @view.View, src : Source) -> Unit {
  @sf.news_card_node(
    parent,
    "download",
    fn() { @sf.t("android-misc.updates.allow") },
    fn() { @sf.t("android-misc.updates.allow") },
    fn() { @sfbase.update_go(src) },
    fn(words) {
      @sf.words_node(words, fn() { @sf.t("android-misc.updates.allowWhy", args=[("app", @sf.product())]) }, fn() {
        @sf.news_card_note
      })
      |> ignore
    },
  )
  |> ignore
}

///|
/// The over-7-day upgrade prompt card in `parent` (Small, Medium, and Large), drawn with the canonical
/// `@sf.news_card_node` (same compact list-top card as `changelog_news_node` and `update_card_node`):
/// action title on the head line, concise platform-specific note underneath flush with the icon, optional
/// progress bar while checking/downloading/installing, and the whole card clickable with zero dead ends.
pub fn stale_build_card_node(parent : @view.View, src : Source) -> Unit {
  let icon = if @sfbase.stale_build_kind() == "web" { "refresh" } else { "download" }
  let body_text = fn() {
    match @sfbase.stale_build_kind() {
      "web" => @sf.t("web-main.staleBuild.web")
      "ios" => @sf.t("web-main.staleBuild.ios")
      "feed" =>
        match @sfbase.update_now() {
          Ready(_, ..) => @sf.t("web-main.staleBuild.ready")
          Allow(_) => @sf.t("web-main.staleBuild.allow")
          Coming(_, _) | Installing(_) => @sf.t("web-main.staleBuild.coming")
          _ => @sf.t("web-main.staleBuild.body")
        }
      _ => @sf.t("web-main.staleBuild.downloadBody")
    }
  }
  let button_label = fn() {
    match @sfbase.stale_build_kind() {
      "web" => @sf.t("web-main.staleBuild.reloadPage")
      "ios" => @sf.t("web-main.staleBuild.openTestFlight")
      "feed" =>
        match @sfbase.update_now() {
          Ready(_, ..) => @sf.t("desktop.update.restart")
          Allow(_) => @sf.t("android-misc.updates.allow")
          Coming(_, _) | Installing(_) => @sf.t("web-main.staleBuild.viewProgress")
          _ => @sf.t("web-main.staleBuild.updateNow")
        }
      _ => @sf.t("web-main.staleBuild.download")
    }
  }
  let progress_part = fn() -> Double? {
    match @sfbase.update_now() {
      Coming(_, part) => part
      _ => None
    }
  }
  @sf.news_card_node(
    parent,
    icon,
    button_label,
    button_label,
    fn() { @sfbase.stale_build_action(src) },
    fn(words) {
      @sf.words_node(words, body_text, fn() { @sf.news_card_note }) |> ignore
      words.show(
        fn() {
          @sfbase.stale_build_kind() == "feed" &&
          (@sfbase.update_now() is (Coming(_, _) | Installing(_)) || @sfbase.update.checking.get())
        },
        fn(p) {
          @sf.style_node(p, fn() { stale_build_progress })
          @sf.progress_node(p, progress_part, fn() { @ui.tree_theme().line }, fn() { @sf.theme().p.accent }) |> ignore
        },
      )
    },
  )
  |> ignore
}

///|
/// Room over the progress bar inside the over-7-day upgrade card while checking or downloading.
// kept across runs: a value (no field of it changes)
let stale_build_progress : @ui.Style = @ui.css("w=Full pt=S1_5")

///|
/// Number of interrupted chats shown inline when a restart banner card is expanded.
let restart_preview_limit : Int = 3

///|
/// List-top banner cards for stations with turns cut off by a non-update restart awaiting manual resume or dismissal.
pub fn restart_interrupted_parts(
  src : Source,
  view : ChatsView?,
  read_view : () -> ChatsView?,
) -> Array[NodePart] {
  let parts : Array[NodePart] = []
  guard view is Some(v) else { return parts }
  for item in v.interrupted {
    if @sfbase.restart_interrupted_gone.contains(item.station) {
      continue
    }
    let current = item
    let station = current.station
    parts.push({
      key: "restart-interrupted:" + station,
      make: fn(p) {
        restart_interrupted_card_node(p, src, station, current, fn() {
          match read_view() {
            Some(v) => v.interrupted.iter().find_first(fn(x) { x.station == station })
            None => None
          }
        })
      },
    })
  }
  parts
}

///|
/// Compact list-top card for one station whose turns were cut off by a non-update restart:
/// sidebar-proportioned padding (`px=16, pt=14`), single-line station header with amber dot,
/// concise summary row with expand chevron aligned to `Meta` first line, expandable recent chat preview,
/// and concentric capsule footer buttons for batch resume or dismiss.
fn restart_interrupted_card_node(
  parent : @view.View,
  src : Source,
  station : String,
  first : @sfbase.InterruptedStation,
  read_item : () -> @sfbase.InterruptedStation?,
) -> Unit {
  let expanded : @signals.Signal[Bool] = @signals.signal(false)
  let kept : Ref[@sfbase.InterruptedStation] = Ref(first)
  let latest = fn() {
    match read_item() {
      Some(cur) => {
        kept.val = cur
        cur
      }
      None => kept.val
    }
  }
  let station_name = fn() {
    let cur = latest()
    if cur.station_name != "" { cur.station_name } else { station }
  }
  let summary = fn() {
    let cur = latest()
    @sf.t("web-main.restartInterrupted.title", args=[("count", cur.count.to_string())])
  }
  let shown_chats = fn() {
    let cur = latest()
    if cur.chats.length() > restart_preview_limit {
      cur.chats[:restart_preview_limit].to_owned()
    } else {
      cur.chats
    }
  }
  let more_count = fn() {
    let cur = latest()
    let shown = shown_chats().length()
    if cur.count > shown { cur.count - shown } else { 0 }
  }
  // (taken away by its part's key leaving the list (restart_interrupted_parts), drawn as it goes: emptied here at
  // once, its key would go with nothing left to draw and the rows under it jump up)
  parent.box(fn(room) {
    @sf.style_node(room, fn() { restart_card_room.then(@ui.style(px=@sf.room_of(@sf.theme().chat_list.band_in))) })
    room.box(fn(k) {
      @sf.style_node(k, fn() { restart_card_surface })
      k
      .radius(Is(@sf.card_corner))
      .ground(By(fn() { @sf.theme().p.card }))
      .clips(Is(true))
      |> ignore
      k.box(fn(body) {
        @sf.style_node(body, fn() { restart_card_body })
        // Row 1: amber dot + station name (2 elements only, single line with ellipsis)
        body.box(fn(top) {
          @sf.style_node(top, fn() { restart_card_top })
          top.box(fn(m) {
            @sf.style_node(m, fn() { restart_card_dot_box }, in_row=true)
            m.height(By(fn() { Some(@sf.node_sp(m, @ui.tree_theme().text_size(Ui).1)) })) |> ignore
            m.box(fn(dot) {
              @sf.style_node(dot, fn() { restart_card_dot.then(@ui.style(bg=Warn)) })
            })
            |> ignore
          })
          |> ignore
          @sf.words_node(top, station_name, fn() { restart_card_station })
          .allow_ellipsis(Is(true))
          |> ignore
        })
        |> ignore
        // Row 2: summary + chevron (interactive only when preview chats exist)
        body.switch_by(fn() { shown_chats().length() > 0 }, fn(slot, expandable) {
          if expandable {
            @sf.action_box_node(slot, summary, fn(_) { expanded.set(!expanded.untracked()) }, fn(btn) {
              @sf.style_node(btn, fn() { restart_card_summary_row })
              @sf.words_node(btn, summary, fn() {
                if @sf.lit_node(btn) { restart_card_summary_lit } else { restart_card_summary }
              })
              |> ignore
              btn.box(fn(cm) {
                @sf.style_node(cm, fn() { restart_card_chev }, in_row=true)
                cm.height(By(fn() { Some(@sf.node_sp(cm, @ui.tree_theme().text_size(Meta).1)) })) |> ignore
                @sf.icon_node(cm, "chevron-right", 12.0, By(fn() { @sf.theme().p.muted }), name_now=fn() {
                  if expanded.get() { "chevron-down" } else { "chevron-right" }
                })
                |> ignore
              })
              |> ignore
            })
            |> ignore
          } else {
            @sf.words_node(slot, summary, fn() { restart_card_summary_static }) |> ignore
          }
        })
        // Expanded interrupted chat preview list (aligned to body left padding)
        body.show(at_once=true, fn() { expanded.get() && shown_chats().length() > 0 }, fn(col) {
          @sf.style_node(col, fn() { restart_card_list })
          col.box(fn(items_col) {
            @sf.style_node(items_col, fn() { restart_card_list })
            items_col.each(
              shown_chats,
              fn(c) { c.key },
              at_once=true,
              fn(item_view, sig) {
                @sf.style_node(item_view, fn() { restart_card_full })
                let label = fn() {
                  let c = sig.get()
                  if c.title != "" { c.title } else { @sf.t("web-main.attention.untitled") }
                }
                @sf.action_box_node(item_view, label, fn(_) {
                  let c = sig.untracked()
                  @sfbase.open_chat({ station, session: c.key, title: label(), station_name: station_name() })
                }, fn(row) {
                  @sf.style_node(row, fn() { restart_card_item_row })
                  @sf.words_node(row, label, fn() {
                    if @sf.lit_node(row) { restart_card_item_lit } else { restart_card_item }
                  })
                  .allow_ellipsis(Is(true))
                  |> ignore
                })
                |> ignore
              },
            )
          })
          |> ignore
          col.show(at_once=true, fn() { more_count() > 0 }, fn(more_box) {
            @sf.style_node(more_box, fn() { restart_card_full })
            @sf.words_node(more_box, fn() {
              @sf.t("web-main.restartInterrupted.more", args=[("count", more_count().to_string())])
            }, fn() { restart_card_more })
            |> ignore
          })
        })
      })
      |> ignore
      // Concentric footer buttons
      k.box(fn(foot) {
        @sf.style_node(foot, fn() {
          let inset = @sf.room_of(@sf.card_foot_in(@sf.button_height()))
          restart_card_foot.then(@ui.style(px=inset, pb=inset))
        })
        foot.wraps(By(fn() { Some(@sf.ask_foot_lines()) }), reverse=true) |> ignore
        @sf.button_node(foot, fn() { @sf.t("web-main.restartInterrupted.resumeAll") }, fn() {
          // (a person's act: the card leaves by its way, the rows under it closing up after it)
          @view.transition(fn() { @sfbase.restart_interrupted_gone[station] = true })
          @sfbase.act(
            src,
            @sf.t("web-main.restartInterrupted.resumeAll"),
            "",
            "station.resumeInterrupted",
            { "station": Json::string(station) },
            failed=fn() { @sfbase.restart_interrupted_gone.remove(station) },
          )
        }, tone=Primary)
        |> ignore
        @sf.button_node(foot, fn() { @sf.t("web-main.restartInterrupted.dismiss") }, fn() {
          @view.transition(fn() { @sfbase.restart_interrupted_gone[station] = true })
          @sfbase.act(
            src,
            @sf.t("web-main.restartInterrupted.dismiss"),
            "",
            "station.dismissInterrupted",
            { "station": Json::string(station) },
            failed=fn() { @sfbase.restart_interrupted_gone.remove(station) },
          )
        }, tone=Plain)
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let restart_card_room : @ui.Style = @ui.css("w=Full pt=S1 pb=S2_5")

///|
// kept across runs: a value (no field of it changes)
let restart_card_surface : @ui.Style = @ui.css("w=Full gap=S2_5")

///|
// kept across runs: a value (no field of it changes)
let restart_card_body : @ui.Style = @ui.css("w=Full px=S4 pt=S3_5 gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let restart_card_full : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let restart_card_top : @ui.Style = @ui.css("row w=Full gap=S1_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let restart_card_dot_box : @ui.Style = @ui.css("align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let restart_card_dot : @ui.Style = @ui.style(w=@sf.attention_dot, h=@sf.attention_dot, radius=Full)

///|
// kept across runs: a value (no field of it changes)
let restart_card_station : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, leading=L5, wrap=false, max_lines=1, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let restart_card_summary_row : @ui.Style = @ui.css("row w=Full gap=S1_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let restart_card_summary : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L5, w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let restart_card_summary_lit : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, leading=L5, w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let restart_card_summary_static : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L5, w=Full)

///|
// kept across runs: a value (no field of it changes)
let restart_card_chev : @ui.Style = @ui.css("align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let restart_card_list : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let restart_card_item_row : @ui.Style = @ui.css("row w=Full py=S0_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let restart_card_item : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L5, wrap=false, max_lines=1, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let restart_card_item_lit : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, leading=L5, wrap=false, max_lines=1, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let restart_card_more : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, leading=L4_75, w=Full)

///|
// kept across runs: a value (no field of it changes)
let restart_card_foot : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")
