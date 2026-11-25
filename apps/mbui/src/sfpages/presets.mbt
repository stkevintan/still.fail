// Presets: what a chat starts knowing, chosen on the new chat's page beside where it runs and what it
// runs on (the core's `newChat` view: the person's own presets, the one picked and its name; `newChat.pick {preset}`).
// A person sees their own; the other members' are one press further in (the user, 2026-11-14: 「用户默认只能看到自己的
// 预设，想要查看别人的预设需要额外操作」): looked at, opened a chat with and copied into one's own, never edited or
// deleted here (the lead, 2026-11-14). Its control opens a menu of them (不用预设 and each of one's own, the one picked
// checked, someone else's picked among them with whose it is; 编辑 the one picked or, someone else's, 复制「X」为我的预设;
// 新预设; 其他成员的预设, a level further in, asked of the core at that press). A preset is made or changed in a dialog
// of nodes (what it is read of the core's `preset`): its folders
// first (each a row with its ×; 添加目录 a step further in: the folders the stations found, searched by name, 浏览文件夹
// the folder picker a step further still, 从 Git 克隆 a repository cloned onto a station, its row 正在克隆… till it is
// there), its name (the first folder's till one is typed), what people want of its chats.

///|
/// Whether the preset picked (`v`'s `preset`) is the person's own: none picked, or among their own (`presets`). One
/// that is not is someone else's, picked from 其他成员的预设.
fn preset_picked_own(v : Json?) -> Bool {
  let picked = text(v, "preset")
  picked == "" || items(v, "presets").iter().any(fn(p) { text(Some(p), "id") == picked })
}

///|
/// What the preset `id` of workspace `scope` is asked by, whole (the core's `preset`: whose it is, its folders).
fn preset_asked(scope : String, id : String) -> Map[String, Json] {
  { "scope": Json::string(scope), "id": Json::string(id) }
}

///|
/// The presets' panel opened by a press on the control: at once where the one picked is the person's own or none is;
/// someone else's, once whose it is is answered (its `preset`, asked at the press and let go of as the panel opens:
/// the page holds no topic for it), the screen as it was meanwhile (press_wait). Answered with an error (nothing on
/// the device has it any more), the panel by its name alone.
fn preset_menu_open(src : Source, w : Workspace, address : String, v : Json?, from : @sf.Beside) -> Unit {
  if preset_picked_own(v) {
    preset_panel(src, w, address, v, "", None, from)
    return
  }
  let (answered, leases) = @sfbase.asked_now(src, [("preset", preset_asked(w.id, text(v, "preset")))])
  let let_go = fn() { leases.each(fn(l) { l.cancel() }) }
  @sfbase.press_wait(answered, fn() {
    let one = match @signals.untracked(fn() { leases[0].follow() }) {
      Some(t) => t.value
      None => None
    }
    let_go()
    preset_panel(src, w, address, v, text(one, "whose"), one, from)
  }, let_go~)
  |> ignore
}

///|
/// Whether `fields` match space-separated case-insensitive tokens of `query`.
fn preset_matches(query : String, fields : Array[String]) -> Bool {
  let q = query.trim().to_owned().to_lower()
  if q == "" {
    return true
  }
  let hay = fields.join(" ").to_lower()
  for tok in q.split(" ") {
    let t = tok.to_owned()
    if t != "" && !hay.contains(t) {
      return false
    }
  }
  true
}

///|
/// Join non-empty metadata parts with " · ".
fn preset_join_meta(a : String, b : String) -> String {
  if a != "" && b != "" {
    a + " · " + b
  } else if a != "" {
    a
  } else {
    b
  }
}

///|
/// Leading 22x22 icon mark for a preset row, aligned to the first line's height.
fn preset_picker_mark_node(
  parent : @view.View,
  dir_name : String,
  dir_repo : String,
  maker_id : String,
  runtime : String,
  chosen : Bool,
) -> Unit {
  parent.box(fn(box) {
    box
    .width(Is(Some(22.0)))
    .height(By(fn() { Some(dmax(22.0, @sf.theme().t.ui_line)) }))
    .shrink(Is(0.0))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    |> ignore
    if dir_name != "" {
      let key = if dir_repo != "" { dir_repo } else { dir_name }
      @sf.tile_avatar_node(box, fn() { key }, fn() { dir_name }, fn() { "" }, 22.0, corner=@sf.small_corner)
    } else if maker_id != "" || runtime != "" {
      @sf.maker_mark_node(box, maker_id, runtime, 16.0) |> ignore
    } else {
      @sf.icon_node(box, "sparks", 16.0, By(fn() { if chosen { @sf.theme().p.accent_text } else { @sf.theme().p.muted } })) |> ignore
    }
  })
  |> ignore
}

///|
/// A structured preset row in the picker: left selectable main button (icon + name + check + optional summary),
/// paired with an independent beside action button (one's own: ⋯, its menu beside it; another's: copy) aligned to the
/// first line, given the node it stands in to open beside.
fn preset_picker_row_node(
  parent : @view.View,
  name : String,
  summary : String,
  dir_name : String,
  dir_repo : String,
  maker_id : String,
  runtime : String,
  chosen : Bool,
  highlighted : () -> Bool,
  press : () -> Unit,
  action? : (String, () -> String, (@view.View) -> Unit),
) -> Unit {
  parent.box(fn(line) {
    @sf.style_node(line, fn() { preset_picker_line })
    line.box(fn(btn) {
      @sf.style_node(btn, fn() {
        let base = if action is Some(_) {
          preset_picker_main_split.then(@ui.style(radius=@sf.panel_in))
        } else {
          preset_picker_main.then(@sf.panel_row_in_node(btn))
        }
        base.then(@ui.style(min_h=Fixed(@sf.theme().items.least)))
      }, in_row=true)
      btn.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      @sf.hover_ground_node(btn, extra=highlighted)
      @sf.rippled_node(btn, press, @sf.row_corner, fn() { name })
      preset_picker_mark_node(btn, dir_name, dir_repo, maker_id, runtime, chosen)
      btn.box(fn(col) {
        col.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(2.0)) |> ignore
        col.box(fn(top) {
          @sf.style_node(top, fn() { preset_picker_title_row })
          @sf.words_node(top, fn() { name }, fn() { if chosen { preset_picker_name_chosen } else { preset_picker_name } })
          .grow(Is(1.0))
          .basis(Is(Some(0.0)))
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          .cuts(Is(true))
          .allow_ellipsis(Is(true))
          |> ignore
          if chosen {
            @sf.icon_node(top, "check", 14.0, By(fn() { @sf.theme().p.accent })) |> ignore
          }
        })
        |> ignore
        if summary != "" {
          @sf.words_node(col, fn() { summary }, fn() { preset_picker_summary })
          .min_width(Is(Some(0.0)))
          .cuts(Is(true))
          .allow_ellipsis(Is(true))
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
    match action {
      Some((icon, label, act)) =>
        line.box(fn(slot) {
          slot
          .shrink(Is(0.0))
          .padding(Is((0.0, 2.0, 0.0, 0.0)))
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          |> ignore
          @sf.icon_button_node(slot, icon, label, fn() { act(slot) }, ink=fn() { @sf.theme().p.muted }) |> ignore
        })
        |> ignore
      None => ()
    }
  })
  |> ignore
}

///|
/// A row in the new-chat preset picker's list (`View::each` key and payload).
#derive(Eq)
priv enum PresetPickRow {
  TheirRow
  OwnRow(String, Json)
}

///|
fn PresetPickRow::key(self : PresetPickRow) -> String {
  match self {
    TheirRow => "__theirs__"
    OwnRow(k, _) => k
  }
}

///|
/// The person's presets as a structured `@sf.panel_nodes` panel: compact header (with a quiet text-only "No preset"
/// button when a preset is active on popover; on a sheet the same button at the end of its title's line), optional
/// full-width search bar (>= 5 presets), picked other-member preset (with copy button), own presets with icons,
/// one-line summaries and independent edit buttons (editing without changing the active preset; clicking the active
/// row toggles it off), and a footer with "+ New preset" and "Other members' presets ›" stepping in-panel.
fn preset_panel(
  src : Source,
  w : Workspace,
  address : String,
  v : Json?,
  whose : String,
  one : Json?,
  from : @sf.Beside,
) -> Unit {
  let picked = text(v, "preset")
  let picked_station = text(v, "presetStation")
  let picked_name = text(v, "presetName")
  let all = items(v, "presets")
  let stations = items(v, "stations")
  let own = preset_picked_own(v)
  let query_field = @ui.Field::new()
  let search_at : @signals.Signal[Int] = @signals.signal(0)
  let in_small : Ref[Bool] = Ref(false)
  // (what closes it, for 不用预设 at the end of a sheet's title line, made outside what it holds)
  let closes : Ref[() -> Unit] = Ref(fn() {  })
  let has_search = all.length() >= 5
  let one_summary = if !own && picked != "" { text(one, "summary") } else { "" }
  let one_maker_id = if !own && picked != "" { text(field(one, "maker"), "id") } else { "" }
  let one_dirs = if !own && picked != "" { items(one, "dirs") } else { [] }
  let one_dir_name = if one_dirs.length() > 0 { dir_label(text(Some(one_dirs[0]), "path")) } else { "" }
  let one_dir_repo = if one_dirs.length() > 0 { text(Some(one_dirs[0]), "repo") } else { "" }
  let one_runtime = if !own && picked != "" { text(field(one, "model"), "runtime") } else { "" }
  let their_sub = preset_join_meta(whose, one_summary)
  @sf.panel_nodes(
    @sf.t("web-main.preset.label"),
    fn(body, close) {
      let small = @sf.in_small_panel_node(body)
      in_small.val = small
      closes.val = close
      let searching = fn() { query_field.text().trim().to_owned() != "" }
      let visible_entries = fn() -> Array[(String, String, () -> Unit)] {
        let q = query_field.text()
        let entries : Array[(String, String, () -> Unit)] = []
        if !own && picked != "" && preset_matches(q, [picked_name, whose, one_summary]) {
          entries.push(("__theirs__", picked_station, fn() {
            preset_pick(src, w, "", "")()
            close()
          }))
        }
        for p in all {
          let po = Some(p)
          let id = text(po, "id")
          let at = text(po, "station")
          let nm = text(po, "name")
          let sum = text(po, "summary")
          let sn = text(po, "stationName")
          let chosen = id == picked && at == picked_station
          if preset_matches(q, [nm, sum, sn]) {
            entries.push((id, at, fn() {
              if chosen {
                preset_pick(src, w, "", "")()
              } else {
                preset_pick(src, w, id, at)()
              }
              close()
            }))
          }
        }
        entries
      }
      let on_step = fn(delta : Int) {
        let list = visible_entries()
        let n = list.length()
        if n > 0 {
          let cur = search_at.untracked()
          let next = (cur + delta + n) % n
          search_at.set(next)
        }
      }
      let on_enter = fn() {
        let list = visible_entries()
        if list.length() > 0 {
          let idx = search_at.untracked()
          let safe = if idx >= 0 && idx < list.length() { idx } else { 0 }
          (list[safe].2)()
        }
      }
      if small {
        if picked == "" {
          @sf.panel_head_node(body, fn() { @sf.t("web-main.preset.label") }) |> ignore
        } else {
          body.box(fn(h) {
            @sf.style_node(h, fn() { preset_panel_head_row }, in_row=true)
            @sf.words_node(h, fn() { @sf.t("web-main.preset.label") }, fn() { preset_panel_head_title })
            .grow(Is(1.0))
            .basis(Is(Some(0.0)))
            .shrink(Is(1.0))
            .min_width(Is(Some(0.0)))
            .cuts(Is(true))
            .allow_ellipsis(Is(true))
            |> ignore
            @sf.action_box_node(h, fn() { @sf.t("web-main.preset.none") }, fn(_) {
              preset_pick(src, w, "", "")()
              close()
            }, fn(btn) {
              @sf.style_node(btn, fn() { preset_panel_clear_btn }, in_row=true)
              btn.shrink(Is(0.0)) |> ignore
              @sf.hover_ground_node(btn)
              @sf.words_node(btn, fn() { @sf.t("web-main.preset.none") }, fn() { preset_panel_clear_words }) |> ignore
            })
            |> ignore
          })
          |> ignore
        }
        if has_search {
          body.box(fn(sb) {
            @sf.style_node(sb, fn() { preset_panel_search_wrap.then(@sf.panel_field_in_node(sb)) })
            @sf.panel_search_input_node(
              sb,
              query_field,
              fn() { @sf.t("web-main.preset.searchPresets") },
              edited=fn(_) { search_at.set(0) },
              submitted=fn(_) { on_enter() },
              step=fn(d) {
                on_step(d)
                true
              },
            )
            |> ignore
          })
          |> ignore
        }
      } else if has_search {
        body.box(fn(sb) {
          @sf.style_node(sb, fn() { preset_panel_search_wrap.then(@sf.panel_field_in_node(sb)) })
          @sf.panel_search_input_node(
            sb,
            query_field,
            fn() { @sf.t("web-main.preset.searchPresets") },
            edited=fn(_) { search_at.set(0) },
            submitted=fn(_) { on_enter() },
            step=fn(d) {
              on_step(d)
              true
            },
          )
          |> ignore
        })
        |> ignore
      }
      if picked == "" && all.length() == 0 {
        body.box(fn(e) {
          @sf.style_node(e, fn() { preset_empty_box })
          @sf.words_node(e, fn() { @sf.t("web-main.preset.empty") }, fn() { preset_empty_title }) |> ignore
          @sf.words_node(e, fn() { @sf.t("web-main.preset.emptyHint") }, fn() { preset_empty_hint }) |> ignore
        })
        |> ignore
        return
      }
      @sf.capped_node(body, fn() { if small { 360.0 } else { dmin(440.0, dmax(220.0, @sf.over_room(body).1 * 0.55)) } }, fn(list) {
        let rows = fn() -> Array[PresetPickRow] {
          let q = query_field.text().trim().to_owned()
          let out : Array[PresetPickRow] = []
          if !own && picked != "" && preset_matches(q, [picked_name, whose, one_summary]) {
            out.push(TheirRow)
          }
          for p in all {
            let po = Some(p)
            if preset_matches(q, [text(po, "name"), text(po, "summary"), text(po, "stationName")]) {
              out.push(OwnRow(text(po, "station") + "\n" + text(po, "id"), p))
            }
          }
          out
        }
        let lit = list.selected(fn() {
          if !searching() {
            None
          } else {
            let r = rows()
            let idx = search_at.get()
            if idx >= 0 && idx < r.length() { Some(r[idx].key()) } else { None }
          }
        })
        list.each(rows, PresetPickRow::key, fn(row_box, item) {
          match item.untracked() {
            TheirRow =>
              preset_picker_row_node(
                row_box,
                picked_name,
                their_sub,
                one_dir_name,
                one_dir_repo,
                one_maker_id,
                one_runtime,
                true,
                fn() { lit("__theirs__") },
                fn() {
                  preset_pick(src, w, "", "")()
                  close()
                },
                action=(
                  "copy",
                  fn() { @sf.t("web-main.preset.copyItem", args=[("name", picked_name)]) },
                  fn(_) { preset_copy_run(src, w, address, picked, stations, close) },
                ),
              )
            OwnRow(my_key, p) => {
              let po = Some(p)
              let id = text(po, "id")
              let at = text(po, "station")
              let display_name = preset_menu_label(all, p)
              let sum = text(po, "summary")
              let dir_name = text(po, "dirName")
              let dir_repo = text(po, "dirRepo")
              let maker_id = text(field(po, "maker"), "id")
              let rt = text(po, "runtime")
              let chosen = id == picked && at == picked_station
              preset_picker_row_node(
                row_box,
                display_name,
                sum,
                dir_name,
                dir_repo,
                maker_id,
                rt,
                chosen,
                fn() { lit(my_key) },
                fn() {
                  if chosen {
                    preset_pick(src, w, "", "")()
                  } else {
                    preset_pick(src, w, id, at)()
                  }
                  close()
                },
                action=(
                  "more",
                  fn() { @sf.t("web-main.preset.moreItem", args=[("name", display_name)]) },
                  fn(slot) {
                    // (deleted here as in its dialog, without going in first; the panel closed as either is
                    // picked, its list read as it opened)
                    let up = stations.iter().any(fn(s) { text(Some(s), "station") == at })
                    let on = if up { at } else { address }
                    @sf.menu(
                      [
                        Some(@sf.menu_item_of(@sf.t("common.edit"), fn() {
                          close()
                          preset_dialog(src, w, on, id, stations, browse_station=address)
                        }, icon="edit")),
                        Some(@sf.menu_item_of(@sf.t("common.delete"), fn() {
                          close()
                          preset_delete_ask(src, on, id, text(po, "name"))
                        }, icon="trash", danger=true)),
                      ],
                      from=Node(slot),
                      side=Right,
                    )
                  },
                ),
              )
            }
          }
        })
        list.show(at_once=true, fn() { searching() && rows().is_empty() }, fn(eb) {
          @sf.style_node(eb, fn() { preset_empty_box })
          @sf.words_node(eb, fn() { @sf.t("web-main.preset.noMatch") }, fn() { preset_empty_hint }) |> ignore
        })
      })
      |> ignore
    },
    from=from.anchor(),
    side=choice_side(from),
    w=340.0,
    foot=fn(f, close) {
      f.box(fn(row) {
        @sf.style_node(row, fn() { preset_panel_foot_row }, in_row=true)
        row.wraps(Is(Some(6.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.action_box_node(row, fn() { @sf.t("web-main.preset.newRow") }, fn(_) {
          close()
          preset_dialog(src, w, address, "", stations)
        }, fn(btn) {
          @sf.style_node(btn, fn() { preset_foot_btn.then(@ui.style(min_h=Fixed(@sf.button_height()))) }, in_row=true)
          btn.shrink(Is(1.0)).max_width(Is(None), within=true) |> ignore
          @sf.hover_ground_node(btn)
          @sf.icon_node(btn, "plus", 15.0, By(fn() { @sf.theme().p.muted })) |> ignore
          @sf.words_node(btn, fn() { @sf.t("web-main.preset.newRow") }, fn() { preset_foot_words })
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          .cuts(Is(true))
          .allow_ellipsis(Is(true))
          |> ignore
        })
        |> ignore
        @sf.foot_spacer_node(row)
        @sf.action_box_node(row, fn() { @sf.t("web-main.preset.others") }, fn(_) {
          if in_small.val {
            preset_others_open(src, w, v, from, close_first=close)
          } else {
            preset_others_open(src, w, v, from, in_panel=true)
          }
        }, fn(btn) {
          @sf.style_node(btn, fn() { preset_foot_btn.then(@ui.style(min_h=Fixed(@sf.button_height()))) }, in_row=true)
          btn.shrink(Is(1.0)).max_width(Is(None), within=true) |> ignore
          @sf.hover_ground_node(btn)
          @sf.icon_node(btn, "users", 15.0, By(fn() { @sf.theme().p.muted })) |> ignore
          @sf.words_node(btn, fn() { @sf.t("web-main.preset.others") }, fn() { preset_foot_words })
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          .cuts(Is(true))
          .allow_ellipsis(Is(true))
          |> ignore
          @sf.icon_node(btn, "chevron-right", 14.0, By(fn() { @sf.theme().p.subtle })) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    heads_itself=true,
    steps=true,
    focus=false,
    // (on a sheet, 不用预设 at the end of its title's line, as a small panel has it at its own head's end: never a
    // third button in the foot, which went to two lines on a phone)
    head_end?=if picked == "" {
      None
    } else {
      Some(fn(h) {
        @sf.action_box_node(h, fn() { @sf.t("web-main.preset.none") }, fn(_) {
          preset_pick(src, w, "", "")()
          (closes.val)()
        }, fn(btn) {
          @sf.style_node(btn, fn() { preset_sheet_clear_btn.then(@ui.style(min_h=Fixed(@sf.theme().items.least))) }, in_row=true)
          @sf.hover_ground_node(btn)
          @sf.words_node(btn, fn() { @sf.t("web-main.preset.none") }, fn() { preset_sheet_clear_words }) |> ignore
        })
        |> ignore
      })
    },
  )
}

///|
/// Body content for "Other members' presets" (shared by popover step, sheet step, and standalone panel).
fn preset_others_content(
  b : @view.View,
  src : Source,
  w : Workspace,
  address : String,
  stations : Array[Json],
  picked : String,
  said : @sfbase.TopicState?,
  let_go : () -> Unit,
  close : () -> Unit,
  small : Bool,
  draw_head : Bool,
) -> Unit {
  let others = match said {
    Some({ value, .. }) => items(value, "presets")
    _ => []
  }
  let has_search = others.length() >= 5
  let query_field = @ui.Field::new()
  let search_at : @signals.Signal[Int] = @signals.signal(0)
  let searching = fn() { query_field.text().trim().to_owned() != "" }
  let visible = fn() -> Array[Json] {
    let q = query_field.text()
    let out : Array[Json] = []
    for p in others {
      let po = Some(p)
      if preset_matches(q, [text(po, "name"), text(po, "whose"), text(po, "summary"), text(po, "stationName")]) {
        out.push(p)
      }
    }
    out
  }
  let on_step = fn(delta : Int) {
    let n = visible().length()
    if n > 0 {
      let cur = search_at.untracked()
      search_at.set((cur + delta + n) % n)
    }
  }
  let on_enter = fn() {
    let list = visible()
    if list.length() > 0 {
      let idx = search_at.untracked()
      let safe = if idx >= 0 && idx < list.length() { idx } else { 0 }
      let po = Some(list[safe])
      let_go()
      preset_pick(src, w, text(po, "id"), text(po, "station"))()
      close()
    }
  }
  if draw_head && small {
    if has_search {
      @sf.panel_head_node(b, fn() { @sf.t("web-main.preset.others") }, end=fn(e) {
        @sf.panel_search_input_node(
          e,
          query_field,
          fn() { @sf.t("web-main.preset.searchPresets") },
          edited=fn(_) { search_at.set(0) },
          submitted=fn(_) { on_enter() },
          step=fn(d) {
            on_step(d)
            true
          },
        )
        |> ignore
      })
      |> ignore
    } else {
      @sf.panel_head_node(b, fn() { @sf.t("web-main.preset.others") }) |> ignore
    }
  } else if has_search {
    b.box(fn(sb) {
      @sf.style_node(sb, fn() { preset_panel_search_wrap })
      @sf.panel_search_input_node(
        sb,
        query_field,
        fn() { @sf.t("web-main.preset.searchPresets") },
        edited=fn(_) { search_at.set(0) },
        submitted=fn(_) { on_enter() },
        step=fn(d) {
          on_step(d)
          true
        },
      )
      |> ignore
    })
    |> ignore
  }
  match said {
    Some({ error: Some(e), .. }) =>
      b.box(fn(eb) {
        @sf.style_node(eb, fn() { preset_empty_box })
        @sf.words_node(eb, fn() { error_words(e) }, fn() { preset_empty_hint }) |> ignore
      })
      |> ignore
    Some({ value: _, .. }) =>
      if others.length() == 0 {
        b.box(fn(eb) {
          @sf.style_node(eb, fn() { preset_empty_box })
          @sf.words_node(eb, fn() { @sf.t("web-main.preset.othersNone") }, fn() { preset_empty_hint }) |> ignore
        })
        |> ignore
      } else {
        @sf.capped_node(b, fn() { if small { 360.0 } else { dmin(440.0, dmax(220.0, @sf.over_room(b).1 * 0.55)) } }, fn(list) {
          let other_key = fn(p : Json) -> String {
            let po = Some(p)
            text(po, "station") + "\n" + text(po, "id")
          }
          let matched_rows = fn() -> Array[Json] {
            let q = query_field.text().trim().to_owned()
            let out : Array[Json] = []
            for p in others {
              let po = Some(p)
              if preset_matches(q, [text(po, "name"), text(po, "whose"), text(po, "summary"), text(po, "stationName")]) {
                out.push(p)
              }
            }
            out
          }
          let lit = list.selected(fn() {
            if !searching() {
              None
            } else {
              let r = matched_rows()
              let idx = search_at.get()
              if idx >= 0 && idx < r.length() { Some(other_key(r[idx])) } else { None }
            }
          })
          list.each(matched_rows, other_key, fn(row_box, item) {
            let p = item.untracked()
            let po = Some(p)
            let id = text(po, "id")
            let at = text(po, "station")
            let my_key = at + "\n" + id
            let name = text(po, "name")
            let sub = preset_join_meta(text(po, "whose"), text(po, "summary"))
            let dir_name = text(po, "dirName")
            let dir_repo = text(po, "dirRepo")
            let maker_id = text(field(po, "maker"), "id")
            let rt = text(po, "runtime")
            preset_picker_row_node(
              row_box,
              name,
              sub,
              dir_name,
              dir_repo,
              maker_id,
              rt,
              id == picked,
              fn() { lit(my_key) },
              fn() {
                let_go()
                preset_pick(src, w, id, at)()
                close()
              },
              action=(
                "copy",
                fn() { @sf.t("web-main.preset.copyItem", args=[("name", name)]) },
                fn(_) { preset_copy_run(src, w, address, id, stations, close) },
              ),
            )
          })
          list.show(at_once=true, fn() { searching() && matched_rows().is_empty() }, fn(eb) {
            @sf.style_node(eb, fn() { preset_empty_box })
            @sf.words_node(eb, fn() { @sf.t("web-main.preset.noMatch") }, fn() { preset_empty_hint }) |> ignore
          })
        })
        |> ignore
      }
    None => ()
  }
}

///|
/// Preset `id` of station `at` picked for the workspace's new chats ("" none).
fn preset_pick(src : Source, w : Workspace, id : String, at : String) -> () -> Unit {
  fn() { @sfbase.pick_new(src, w.id, { "preset": Json::string(id), "presetStation": Json::string(at) }) }
}

///|
/// Copy another member's preset `id` into one's own on `address`, pick the copy, and open its edit dialog once ready.
fn preset_copy_run(
  src : Source,
  w : Workspace,
  address : String,
  id : String,
  stations : Array[Json],
  close : () -> Unit,
) -> Unit {
  let copied : @signals.Signal[Result[String, String]?] = @signals.signal(None)
  let asked : Ref[(() -> Bool, Array[@sfbase.TopicLease])] = Ref((fn() { true }, []))
  let let_go = fn() { asked.val.1.each(fn(l) { l.cancel() }) }
  (src.call)("preset.copy", Json::object({ "station": Json::string(address), "id": Json::string(id) }), fn(r) {
    match r {
      Ok(made) => {
        let made_id = text(Some(made), "id")
        asked.val = @sfbase.asked_now(src, [("preset", preset_asked(w.id, made_id))])
        copied.set(Some(Ok(made_id)))
      }
      Err(e) => copied.set(Some(Err(error_words(e))))
    }
  })
  @sfbase.press_wait(
    fn() {
      match copied.get() {
        Some(Ok(_)) => (asked.val.0)()
        Some(Err(_)) => true
        None => false
      }
    },
    fn() {
      match copied.untracked() {
        Some(Ok(made_id)) => {
          close()
          @sfbase.pick_new(src, w.id, { "preset": Json::string(made_id), "presetStation": Json::string(address) })
          preset_dialog(src, w, address, made_id, stations, held=asked.val.1)
        }
        Some(Err(e)) => toast_later(@sf.t("web-main.preset.copyFailed", args=[("error", e)]))
        None => ()
      }
    },
    let_go~,
  )
  |> ignore
}

///|
/// 其他成员的预设, a step further in from the presets' panel (`in_panel=true`: `@sf.panel_go_nodes`, back returns to
/// one's own), or a panel of its own where nothing was chosen in one (a fixture's screen: `@sf.panel_nodes`): asked
/// of the core at the press (`otherPresets`, read of the stations reached then) and opened once all of them have
/// answered (`reading` over), whole, the screen as it was meanwhile (`press_wait`).
fn preset_others_open(
  src : Source,
  w : Workspace,
  v : Json?,
  from : @sf.Beside,
  in_panel? : Bool = false,
  close_first? : () -> Unit,
) -> Unit {
  let lease = src.lease_topic("otherPresets", { "scope": Json::string(w.id) })
  let let_go = fn() { lease.cancel() }
  let ready = fn() {
    match lease.follow() {
      Some(t) => t.error is Some(_) || (t.value is Some(_) && !flag(t.value, "reading"))
      // (let go of: nothing to wait for)
      None => true
    }
  }
  let address = text(field(v, "station"), "station")
  let stations = items(v, "stations")
  let picked = text(v, "preset")
  @sfbase.press_wait(ready, fn() {
    let said = @signals.untracked(fn() { lease.follow() })
    let stepped = close_first is Some(_)
    match close_first {
      Some(c) => c()
      None => ()
    }
    let body = fn(b : @view.View, close : () -> Unit) {
      preset_others_content(b, src, w, address, stations, picked, said, let_go, close, @sf.in_small_panel_node(b), !in_panel && !stepped)
    }
    if in_panel {
      @sf.panel_go_nodes(@sf.t("web-main.preset.others"), body, left=let_go)
    } else {
      @sf.panel_nodes(
        @sf.t("web-main.preset.others"),
        body,
        from=from.anchor(),
        side=Top,
        w=340.0,
        heads_itself=!stepped,
        focus=false,
        gone=let_go,
      )
    }
  }, let_go~)
  |> ignore
}

///|
/// 复制「X」为我的预设, in place of 编辑 for someone else's preset picked in `preset_fixed_menu`.
fn preset_copy_item(src : Source, w : Workspace, address : String, v : Json?) -> @sf.MenuItem {
  let picked = text(v, "preset")
  let stations = items(v, "stations")
  @sf.menu_item_of(@sf.t("web-main.preset.copyNamed", args=[("name", text(v, "presetName"))]), fn() {
    preset_copy_run(src, w, address, picked, stations, fn() {  })
  }, icon="copy")
}

///|
/// Preset `p` as the menu of `all` (the page's `presets`) names it: by its name alone, where it is kept no concern of
/// who picks it (the user, 2026-11-14: 「用户大部分时候不需要知道这个」); its station's name after it only to tell it
/// from another of the same name on another station.
fn preset_menu_label(all : Array[Json], p : Json) -> String {
  let name = text(Some(p), "name")
  let at = text(Some(p), "station")
  let twin = all.iter().any(fn(o) { text(Some(o), "name") == name && text(Some(o), "station") != at })
  if twin {
    name + " · " + text(Some(p), "stationName")
  } else {
    name
  }
}

///|
/// 编辑「X」 of the preset picked (`picked`, of the station the page says, `presetStation`): its dialog, browsing on
/// the composer's station. On the composer's station where the preset's is not up (gone, as a station retired, or
/// off): its model is picked of a station's own models, and one not up has none to offer, the panel empty.
fn preset_edit_item(src : Source, w : Workspace, address : String, v : Json?, picked : String) -> @sf.MenuItem {
  let at = text(v, "presetStation")
  let up = items(v, "stations").iter().any(fn(s) { text(Some(s), "station") == at })
  @sf.menu_item_of(@sf.t("web-main.preset.editNamed", args=[("name", text(v, "presetName"))]), fn() {
    preset_dialog(src, w, if up { at } else { address }, picked, items(v, "stations"), browse_station=address)
  }, icon="edit")
}

///|
/// What a control the picked preset holds fixed (its model, its station) opens as it is pressed: a menu saying so in
/// its title (`title`), and the two ways to change it, 编辑 the preset (复制「X」为我的预设 for someone else's, never edited
/// here) and 不用预设 (the user, 2026-11-14: a press that did nothing looked broken).
fn preset_fixed_menu(src : Source, w : Workspace, address : String, v : Json?, title : String, from : @sf.Beside) -> Unit {
  let picked = text(v, "preset")
  @sf.menu(
    [
      Some(if preset_picked_own(v) { preset_edit_item(src, w, address, v, picked) } else { preset_copy_item(src, w, address, v) }),
      Some(@sf.menu_item_of(@sf.t("web-main.preset.none"), fn() {
        @sfbase.pick_new(src, w.id, { "preset": Json::string(""), "presetStation": Json::string("") })
      }, icon="close")),
    ],
    from~,
    title~,
    side=choice_side(from),
  )
}

///|
/// The folders a station offers for a preset and the clones under way there (the `presets` topic's `candidates` and
/// `clones`), read as they are shown. Not the presets: a person's own are the core's `newChat.presets` and `preset`.
fn presets_of(src : Source, address : String) -> Json? {
  src.topic("presets", { "station": Json::string(address) }).get().value
}

///|
/// A folder as a row says it: its own name.
fn dir_label(path : String) -> String {
  match path.rev_find("/") {
    Some(i) if i + 1 < path.length() => path.unsafe_substring(start=i + 1, end=path.length())
    _ => path
  }
}

///|
/// A repository being cloned for a preset (`preset.clone`'s answer, kept by the dialog that asked): the station it is
/// cloned onto, its id there, its repository and its name.
#derive(Eq)
priv struct PresetClone {
  station : String
  id : String
  repo : String
  name : String
}

///|
/// A preset being made or changed: its folders (each its path, its repository, the station it is on where that is not
/// the preset's: `station`, `stationName`; what it shows as: `name`, `where`, `icon`), the repositories cloned for it
/// still to come, its name and what people want of its chats, what its name was filled with (the first folder's, until
/// another is typed), whether what it was is in it yet (one changed: once the station's presets are read), being saved,
/// why it was not; the station browsed and cloned onto (the composer's at first), 添加目录's search, the clone's address,
/// why it was not cloned, its call on its way; which step to go on to as it opens (a fixture's: `add`, `browse`,
/// `browse:<folder>`, `clone`: a step further in from the dialog, the others' from 添加目录 in their place). One object, held by the closures of its dialog and its steps.
priv struct PresetEditing {
  dirs : @signals.Signal[Array[Json]]
  clones : @signals.Signal[Array[PresetClone]]
  auto_station : @signals.Signal[Bool]
  station : @signals.Signal[String]
  stations : @signals.Signal[Array[String]]
  initial_model : @signals.Signal[Json?]
  model_state : @signals.Signal[Int]
  name : @ui.Field
  instructions : @ui.Field
  mut auto : String
  filled : @signals.Signal[Bool]
  saving : @signals.Signal[Bool]
  error : @signals.Signal[String]
  browse_station : @signals.Signal[String]
  q : @ui.Field
  url : @ui.Field
  clone_station : @signals.Signal[String]
  clone_error : @signals.Signal[String]
  clone_busy : @signals.Signal[Bool]
  then : @signals.Signal[String]
  mut depth : Int
}

///|
/// A preset made (`id` "") or changed (the station's of that id) in a dialog: its folders (a row each: its mark, its
/// name over where it is, its ×; a clone under way as one, 正在克隆…; 添加目录 under them), its name (the first
/// folder's until one is typed), what people want of its chats; at its foot 删除 for one there, 取消, 创建 or 保存
/// (not while a clone of it is under way: its folder is not there yet). Made, it is the one picked for the station's
/// new chats. `stations`: the workspace's up now (the `newChat` view's), whose folders are offered too;
/// `browse_station`: the one its folders are browsed and cloned on at first (the composer's). `then`: the step gone on
/// to as it opens (a fixture's screen of each); `clones`: those under way as it opens (one); `held`: what was asked of it
/// before it opened (its copy's whole), held while it shows.
fn preset_dialog(
  src : Source,
  w : Workspace,
  address : String,
  id : String,
  stations : Array[Json],
  then? : String = "",
  browse_station? : String = "",
  clones? : Array[PresetClone] = [],
  held? : Array[@sfbase.TopicLease] = [],
) -> Unit {
  let e : PresetEditing = {
    dirs: @signals.signal([]),
    clones: @signals.signal(clones),
    auto_station: @signals.signal(false, same=fn(a, b) { a == b }),
    station: @signals.signal("", same=fn(a, b) { a == b }),
    stations: @signals.signal([]),
    initial_model: @signals.signal(None),
    model_state: @signals.signal(0, same=fn(a, b) { a == b }),
    name: @ui.Field::new(),
    instructions: @ui.Field::new(),
    auto: "",
    filled: @signals.signal(id == "", same=fn(a, b) { a == b }),
    saving: @signals.signal(false, same=fn(a, b) { a == b }),
    error: @signals.signal("", same=fn(a, b) { a == b }),
    browse_station: @signals.signal(if browse_station == "" { address } else { browse_station }, same=fn(a, b) { a == b }),
    q: @ui.Field::new(),
    url: @ui.Field::new(),
    clone_station: @signals.signal("", same=fn(a, b) { a == b }),
    clone_error: @signals.signal("", same=fn(a, b) { a == b }),
    clone_busy: @signals.signal(false, same=fn(a, b) { a == b }),
    then: @signals.signal(then, same=fn(a, b) { a == b }),
    depth: 1,
  }
  let title = if id == "" { @sf.t("web-main.preset.new") } else { @sf.t("web-main.preset.edit") }
  @sf.panel_nodes(
    title,
    fn(v, close) {
      held.each(fn(l) { l.bind_to(v) })
      preset_fields(v, src, w.id, address, id, stations, e, close)
    },
    from=Unanchored,
    foot=fn(v, close) { preset_foot(v, src, w, address, id, e, close) },
  )
  let d = @sf.panel_depth()
  if d > 0 {
    e.depth = d
  }
}

///|
/// The preset `id` of workspace `scope` whole, as the core has it (`preset`: the person's own as the device holds it,
/// wherever it was made; None while it is read, where nothing has it, or for a new one).
fn preset_was(src : Source, scope : String, id : String) -> Json? {
  if id == "" {
    return None
  }
  src.topic("preset", preset_asked(scope, id)).get().value
}

///|
/// A folder of a preset as the core says it (`preset`'s `dirs`: each with its station) as the dialog holds it (dir_key):
/// one of `address`'s by its path and repository alone, another station's with its station and that station's name.
fn preset_dir_held(d : Json, address : String) -> Json {
  let one = Some(d)
  let repo = if text(one, "repo") == "" { Json::null() } else { Json::string(text(one, "repo")) }
  if text(one, "station") == "" || text(one, "station") == address {
    Json::object({ "path": Json::string(text(one, "path")), "repo": repo })
  } else {
    Json::object({
      "path": Json::string(text(one, "path")),
      "repo": repo,
      "station": Json::string(text(one, "station")),
      "stationName": Json::string(text(one, "stationName")),
    })
  }
}

///|
/// The step asked as the dialog opened (a fixture's screen: `then`), gone on to from it: it closes, the step a step
/// further in from it.
fn preset_then(src : Source, address : String, stations : Array[Json], e : PresetEditing, close : () -> Unit) -> Unit {
  let then = e.then.untracked()
  guard then != "" else { return }
  e.then.set("")
  close()
  if then == "browse" {
    preset_browse(src, address, stations, e, None)
  } else if then.has_prefix("browse:") {
    preset_browse(src, address, stations, e, Some(then.exact_view(start=7).to_owned()))
  } else if then == "clone" {
    preset_clone_open(src, address, stations, e)
  } else {
    preset_add_open(src, address, stations, e)
  }
}

///|
/// What the dialog holds, in node `v` (its body's): 目录, 名字, 指令.
fn preset_fields(
  v : @view.View,
  src : Source,
  scope : String,
  address : String,
  id : String,
  stations : Array[Json],
  e : PresetEditing,
  close : () -> Unit,
) -> Unit {
  // (one changed: what it is, once the core has said it)
  v.reacts(fn() { !e.filled.get() && preset_was(src, scope, id) is Some(_) }, fn(ready) {
    guard ready else { return }
    guard @signals.untracked(fn() { preset_was(src, scope, id) }) is Some(p) else { return }
    e.filled.set(true)
    e.name.set(text(Some(p), "name"))
    e.instructions.set(text(Some(p), "instructions"))
    e.dirs.set(items(Some(p), "dirs").map(fn(d) { preset_dir_held(d, address) }))
    e.auto_station.set(flag(Some(p), "autoStation"))
    e.station.set(text(Some(p), "station"))
    e.stations.set(items(Some(p), "stations").filter_map(fn(s) { if s is String(str) && str != "" { Some(str) } else { None } }))
    e.initial_model.set(field(Some(p), "model"))
  })
  // its name: the first folder's until one is typed
  v.reacts(
    fn() {
      match e.dirs.get().get(0) {
        Some(d) => dir_label(text(Some(d), "path"))
        None => ""
      }
    },
    fn(auto) {
      if id == "" && @signals.untracked(fn() { e.name.text() }) == e.auto && auto != e.auto {
        e.name.set(auto)
        e.auto = auto
      }
    },
  )
  // a clone done: its folder among the preset's, as the station offers it, once it has left the clones it tells and
  // is among its folders by its repository
  v.reacts(fn() { e.clones.get().filter(fn(k) { clone_done(src, address, stations, k) is Some(_) }).map(fn(k) { k.id }) }, fn(
    done,
  ) {
    guard done.length() > 0 else { return }
    let all = @signals.untracked(fn() { e.clones.get() })
    let dirs = @signals.untracked(fn() { e.dirs.get() }).copy()
    for k in all {
      if done.contains(k.id) {
        match @signals.untracked(fn() { clone_done(src, address, stations, k) }) {
          Some(d) => if !dirs.iter().any(fn(x) { dir_key(Some(x)) == dir_key(Some(d)) }) { dirs.push(d) }
          None => ()
        }
      }
    }
    @signals.start_batch()
    e.dirs.set(dirs)
    e.clones.set(all.filter(fn(k) { !done.contains(k.id) }))
    @signals.end_batch()
  })
  // (a step asked as it opens, a fixture's: gone on to once what it is is in it)
  // (once it has come in, as a person goes on from it: at rest first, its step after, the presenters' own way in from
  // there)
  v.reacts(fn() { e.then.get() != "" && e.filled.get() }, fn(go) {
    guard go else { return }
    v.at_moment(v.cause_at() + @ui.move_most_ms, fn() { preset_then(src, address, stations, e, close) }) |> ignore
  })
  v.box(fn(col) {
    @sf.style_node(col, fn() { preset_form })
    @sf.field_node(col, fn() { @sf.t("web-main.preset.name") }, fn(b) {
      let f = @sf.input_node(b, e.name, placeholder=@sf.t("web-main.preset.namePlaceholder"))
      if id == "" {
        @sf.panel_search_at_hand_node(f)
      }
    })
    preset_capsules_node(col, src, address, stations, e)
    // (why it was not saved under it: a folder the station has not, say)
    @sf.field_node(col, fn() { @sf.t("web-main.preset.instructionsTitle") }, hint=fn() { @sf.t("web-main.preset.instructionsHint") }, error=fn() {
      e.error.get()
    }, fn(b) {
      @sf.textarea_node(b, e.instructions, rows=4, most=10, placeholder=@sf.t("web-main.preset.instructionsPlaceholder")) |> ignore
    })
    @sf.field_node(col, fn() { @sf.t("web-main.preset.dirs") }, hint=fn() {
      if e.dirs.get().length() == 0 && e.clones.get().length() == 0 {
        @sf.t("web-main.preset.dirsHint")
      } else {
        ""
      }
    }, fn(b) { preset_dirs_node(b, src, address, stations, e, close) })
  })
  |> ignore
}

///|
/// The preset's folders in node `v`, by station (its name over them only where they are of more than one, or of
/// another than the preset's), the clones under way among them, then 添加目录 (a step further in).
fn preset_dirs_node(
  v : @view.View,
  src : Source,
  address : String,
  stations : Array[Json],
  e : PresetEditing,
  close : () -> Unit,
) -> Unit {
  // (its rows, each with what it is made of as it is made: by station, a station's head where it is said, its folders,
  // its clones under way; 添加目录 last)
  let rows = fn() {
    let dirs = e.dirs.get()
    let clones = e.clones.get()
    let order : Array[String] = []
    for d in dirs {
      let s = dir_station(Some(d), address)
      if !order.contains(s) {
        order.push(s)
      }
    }
    for k in clones {
      if !order.contains(k.station) {
        order.push(k.station)
      }
    }
    let headed = order.length() > 1 || order.iter().any(fn(s) { s != address })
    let out : Array[PresetDirsRow] = []
    for s in order {
      if headed {
        // (the station's name as its first folder kept it, for a station the app no longer lists)
        let mut saved = ""
        for d in dirs {
          if dir_station(Some(d), address) == s {
            saved = text(Some(d), "stationName")
            break
          }
        }
        out.push(DirsHead(s, saved))
      }
      for d in dirs {
        if dir_station(Some(d), address) == s {
          out.push(DirsDir(dir_key(Some(d)), d))
        }
      }
      for k in clones {
        if k.station == s {
          out.push(DirsClone(k))
        }
      }
    }
    out.push(DirsAdd)
    out
  }
  v.box(fn(list) {
    // (what the stations offer by folder once, while it has any: each folder's row reads its own, told only as that one
    // changes)
    let offered_by = list.keyed_by(
      fn() { if e.dirs.get().is_empty() { [] } else { offered_dirs(src, address, stations) } },
      fn(o) { dir_key(Some(o)) },
    )
    list.each(rows, PresetDirsRow::key, fn(row, item) {
      match item.untracked() {
        DirsAdd =>
          preset_action_row(
            row,
            "plus",
            fn() { @sf.t("web-main.preset.add") },
            fn() {
              close()
              preset_add_open(src, address, stations, e)
            },
          )
        DirsHead(s, saved) => @sf.panel_heading_node(row, fn() { preset_station_name(s, saved, stations) })
        DirsDir(at, was) => {
          // (what it shows as: as its station offers it, where it does)
          let one = fn() {
            match offered_by.get(at) {
              Some(x) => Some(x)
              None => Some(was)
            }
          }
          let path = text(Some(was), "path")
          preset_dir_row(
            row,
            fn() { if text(one(), "name") != "" { text(one(), "name") } else { dir_label(path) } },
            fn() { text(one(), "repo") },
            fn() { text(one(), "icon") },
            fn() { dir_note(one(), false) },
            end=fn(x) {
              preset_drop_node(x, fn() {
                e.dirs.set(e.dirs.untracked().filter(fn(d) { dir_key(Some(d)) != at }))
              })
            },
          )
        }
        DirsClone(c) => preset_clone_row(row, src, c, e)
      }
    })
  })
  |> ignore
}

///|
/// A row of a preset's folders (preset_dirs_node's), with what it is made of as it is made: a station's head (its
/// address, its name as its first folder kept it), a folder (its key, as it was given), a clone under way, 添加目录.
#derive(Eq)
priv enum PresetDirsRow {
  DirsHead(String, String)
  DirsDir(String, Json)
  DirsClone(PresetClone)
  DirsAdd
}

///|
/// A row's key, as the list's were: a head by its station, a folder by its key, a clone by its id.
fn PresetDirsRow::key(self : PresetDirsRow) -> String {
  match self {
    DirsHead(s, _) => "h\n" + s
    DirsDir(at, _) => "d\n" + at
    DirsClone(k) => "c\n" + k.id
    DirsAdd => "a"
  }
}

///|
/// How a clone stands as its station tells it (the `presets` topic's `clones`): failed (and why), or under way (also
/// while it is no more told and not among its folders yet).
fn clone_failed(src : Source, k : PresetClone) -> String? {
  match items(presets_of(src, k.station), "clones").iter().find_first(fn(x) { text(Some(x), "id") == k.id }) {
    Some(x) if text(Some(x), "state") == "failed" => Some(clone_why(text(Some(x), "error")))
    _ => None
  }
}

///|
/// Why a clone failed, for a row's one line: the last line of git's words the station kept, its conclusion (`fatal: …`;
/// the lines before it lead up to it and would be all the row shows, cut short).
fn clone_why(error : String) -> String {
  let mut last = ""
  for line in error.split("\n") {
    let l = line.trim(chars=" \t\r").to_owned()
    if l != "" {
      last = l
    }
  }
  last
}

///|
/// A clone done: no more among the clones its station tells, and among its folders by its repository; that folder as
/// a preset's folder takes it (another station's marked with it).
fn clone_done(src : Source, address : String, stations : Array[Json], k : PresetClone) -> Json? {
  let v = presets_of(src, k.station)
  guard v is Some(_) else { return None }
  if items(v, "clones").iter().any(fn(x) { text(Some(x), "id") == k.id }) {
    return None
  }
  match items(v, "candidates").iter().find_first(fn(o) { text(Some(o), "repo") == k.repo }) {
    Some(o) => Some(dir_of_station(o, k.station, address, stations))
    None => None
  }
}

///|
/// A folder `o` a station `at` offers, as a preset of `address` takes it: as it is there, marked with its station where
/// that is another.
fn dir_of_station(o : Json, at : String, address : String, stations : Array[Json]) -> Json {
  match o {
    Object(m) if at != address => {
      let marked = m.copy()
      marked["station"] = Json::string(at)
      marked["stationName"] = Json::string(preset_station_name(at, "", stations))
      Json::object(marked)
    }
    _ => o
  }
}

///|
/// A clone of the preset's in node `v` as a folder's row: its tile, its name, under it 正在克隆… (the library's small
/// spinner at its end) or why it failed in red; its × lets go of it there (`preset.cloneDrop`) and here.
fn preset_clone_row(v : @view.View, src : Source, k : PresetClone, e : PresetEditing) -> Unit {
  let failed = fn() { clone_failed(src, k) }
  preset_row(
    v,
    fn(l) { @sf.tile_avatar_node(l, fn() { k.repo }, fn() { k.name }, fn() { "" }, preset_dir_mark, corner=@sf.small_corner) },
    fn() { k.name },
    fn() {
      match failed() {
        Some(why) => @sf.t("web-main.preset.cloneFailed", args=[("why", why)])
        None => @sf.t("web-main.preset.cloning")
      }
    },
    bad=fn() { failed() is Some(_) },
    tail=fn(t) {
      t.show(fn() { failed() is None }, at_once=true, fn(w) { @sf.spinner_node(w) |> ignore })
      preset_drop_node(t, fn() {
        (src.call)("preset.cloneDrop", { "station": Json::string(k.station), "id": Json::string(k.id) }, @sfbase.answer_unread)
        e.clones.set(e.clones.untracked().filter(fn(c) { c.id != k.id }))
      })
    },
  )
}

///|
/// A folder's row in node `v`: its tile (its picture, else its letter on its repository's colour), its name over where
/// it is (`note`), `end` at its end where given (its ×); pressed, `press` where given.
fn preset_dir_row(
  v : @view.View,
  name : () -> String,
  repo : () -> String,
  icon : () -> String,
  note : () -> String,
  press? : () -> Unit,
  end? : (@view.View) -> Unit,
) -> Unit {
  preset_row(
    v,
    fn(l) { @sf.tile_avatar_node(l, fn() { if repo() != "" { repo() } else { name() } }, name, icon, preset_dir_mark, corner=@sf.small_corner) },
    name,
    note,
    press?,
    tail?=end,
  )
}

///|
/// A row of the preset's, in node `v`: what `lead` makes (a tile) where a folder's mark stands, its `title` over its
/// `note` (red where `bad`; none where ""), each one line cut short, what `tail` makes at its end; as high as a press
/// at least, its words on the panel's words' line (panel_row_in_node), its ground out to the panel's sides as the
/// panel's rows' are. Pressed whole where `press` is given (a button named by its title, its ground under the hand);
/// `opens`: what a dialog in the window's middle opens on (@sf.panel_opens_on_node).
fn preset_row(
  v : @view.View,
  lead : (@view.View) -> Unit,
  title : () -> String,
  note : () -> String,
  bad? : () -> Bool = fn() { false },
  press? : () -> Unit,
  tail? : (@view.View) -> Unit,
  opens? : Bool = false,
) -> Unit {
  let look = fn(r : @view.View) {
    @sf.style_node(r, fn() { preset_row_at.then(@sf.panel_row_in_node(r)) })
    if press is Some(_) {
      @sf.hover_ground_node(r)
      if opens {
        @sf.panel_opens_on_node(r)
      }
    }
    r.box(fn(l) {
      l.shrink(Is(0.0)) |> ignore
      lead(l)
    })
    |> ignore
    r.box(fn(w) {
      w.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      @sf.words_node(w, title, fn() { preset_dir_name }) |> ignore
      w.show(fn() { note() != "" }, fn(n) {
        @sf.words_node(n, note, fn() { if bad() { preset_dir_bad } else { preset_dir_note } }) |> ignore
      })
    })
    |> ignore
    match tail {
      Some(t) =>
        r.box(fn(e) {
          e.shrink(Is(0.0)).row(Is(true)).gap(Is(preset_tail_gap)).lines_up(Is(Some(Middle))) |> ignore
          t(e)
        })
        |> ignore
      None => ()
    }
  }
  match press {
    Some(p) => @sf.action_box_node(v, title, fn(_) { p() }, look) |> ignore
    None => v.box(look) |> ignore
  }
}

///|
/// A row that does something in node `v`, as a folder's row stands: a neutral tile with `icon` in it where a folder's
/// mark stands, its `words` on one line, a chevron at its end (each asks more first: a step further in, a picker; the
/// user, 2026-11-17: an icon, not words ending in …); pressed whole, `press`.
fn preset_action_row(v : @view.View, icon : String, words : () -> String, press : () -> Unit, opens? : Bool = false) -> Unit {
  preset_row(v, fn(l) { preset_action_tile(l, icon) }, words, fn() { "" }, press~, opens~, tail=fn(e) {
    @sf.icon_node(e, "chevron-right", @sf.panel_end_icon, By(fn() { @sf.theme().p.subtle })) |> ignore
  })
}

///|
/// A neutral tile as large as a folder's mark, `icon` in its middle, in node `v`.
fn preset_action_tile(v : @view.View, icon : String) -> Unit {
  v.box(fn(t) {
    t
    .width(Is(Some(preset_dir_mark)))
    .height(Is(Some(preset_dir_mark)))
    .radius(Is(@sf.small_corner))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() { @sf.theme().p.neutral_bg }))
    |> ignore
    @sf.icon_node(t, icon, preset_action_icon, By(fn() { @sf.theme().p.muted })) |> ignore
  })
  |> ignore
}

///|
/// A row's ×, in node `v`: named 移除.
fn preset_drop_node(v : @view.View, press : () -> Unit) -> Unit {
  @sf.icon_button_node(v, "close", fn() { @sf.t("web-main.preset.remove") }, press, size=preset_dir_x) |> ignore
}

///|
/// 删除预设「X」？ asked, preset `id` of station `address` deleted as it is said yes to, `then` before.
fn preset_delete_ask(src : Source, address : String, id : String, name : String, then? : () -> Unit = fn() {  }) -> Unit {
  @sf.confirm(
    @sf.t("web-main.preset.deleteTitle", args=[("name", name)]),
    @sf.t("web-main.preset.deleteBody"),
    @sf.t("common.delete"),
    danger=true,
    fn() {
      then()
      (src.call)("preset.delete", Json::object({ "station": Json::string(address), "id": Json::string(id) }), @sfbase.answer_unread)
    },
  )
}

///|
/// The dialog's foot in node `v`: 删除 for one there (asked first), 取消, 创建 or 保存 (busy as it is saved; not while it
/// has no folder or no name, or a clone of it is under way).
fn preset_foot(
  v : @view.View,
  src : Source,
  w : Workspace,
  address : String,
  id : String,
  e : PresetEditing,
  close : () -> Unit,
) -> Unit {
  if id != "" {
    @sf.button_node(v, fn() { @sf.t("common.delete") }, fn() {
      preset_delete_ask(src, address, id, e.name.text(), then=close)
    }, tone=GhostDanger)
    |> ignore
  }
  @sf.foot_spacer_node(v)
  @sf.button_node(v, fn() { @sf.t("common.cancel") }, close, tone=Ghost) |> ignore
  let named = fn() { e.name.text().trim(chars=" \n").to_owned() }
  let ready = fn() { named() != "" && !e.clones.get().iter().any(fn(k) { clone_failed(src, k) is None }) }
  @sf.button_node(
    v,
    fn() { if id == "" { @sf.t("web-main.preset.create") } else { @sf.t("common.save") } },
    fn() {
      e.saving.set(true)
      e.error.set("")
      let params : Map[String, Json] = {
        "station": Json::string(address),
        "name": Json::string(@signals.untracked(named)),
        // (this station's by their paths; another's as it was read there, with its station)
        "dirs": Json::array(
          e.dirs.untracked().map(fn(d) {
            let one = Some(d)
            if text(one, "station") == "" {
              Json::string(text(one, "path"))
            } else {
              Json::object({
                "path": Json::string(text(one, "path")),
                "repo": if text(one, "repo") == "" { Json::null() } else { Json::string(text(one, "repo")) },
                "station": Json::string(text(one, "station")),
                "stationName": Json::string(text(one, "stationName")),
              })
            }
          }),
        ),
        "instructions": Json::string(@signals.untracked(fn() { e.instructions.text() })),
      }
      if e.auto_station.untracked() {
        params["autoStation"] = Json::boolean(true)
      } else if e.station.untracked() != "" {
        params["stations"] = Json::array([Json::string(e.station.untracked())])
      } else if e.stations.untracked().length() > 0 {
        params["stations"] = Json::array(e.stations.untracked().map(fn(s) { Json::string(s) }))
      }
      let pick_val = match e.model_state.untracked() {
        2 => {
          let pick_v = @signals.untracked(fn() {
            src.topic("pick", { "station": Json::string(address), "of": Json::string("connect-new:preset") }).get().value
          })
          field(pick_v, "value")
        }
        0 => e.initial_model.untracked()
        _ => None
      }
      if text(pick_val, "model") != "" {
        let pm : Map[String, Json] = { "model": Json::string(text(pick_val, "model")) }
        if text(pick_val, "runtime") != "" {
          pm["runtime"] = Json::string(text(pick_val, "runtime"))
        }
        if text(pick_val, "effort") != "" {
          pm["effort"] = Json::string(text(pick_val, "effort"))
        }
        if text(pick_val, "speed") != "" {
          pm["speed"] = Json::string(text(pick_val, "speed"))
        }
        match field(pick_val, "fast") {
          Some(True) => pm["fast"] = Json::boolean(true)
          Some(False) => pm["fast"] = Json::boolean(false)
          _ => ()
        }
        match field(pick_val, "tui") {
          Some(True) => pm["tui"] = Json::boolean(true)
          Some(False) => pm["tui"] = Json::boolean(false)
          _ => ()
        }
        let ctx_n = preset_context_num(pick_val)
        if ctx_n > 0 {
          pm["context"] = Json::number(ctx_n.to_double())
        }
        if text(pick_val, "profile") != "" {
          pm["profile"] = Json::string(text(pick_val, "profile"))
        }
        let p_list = items(pick_val, "profiles")
        if p_list.length() > 0 {
          pm["profiles"] = Json::array(p_list)
        }
        params["model"] = Json::object(pm)
      }
      if id != "" {
        params["id"] = Json::string(id)
      }
      (src.call)(if id == "" { "preset.add" } else { "preset.put" }, Json::object(params), fn(r) {
        e.saving.set(false)
        match r {
          Ok(made) => {
            // made: the one the station's new chats are opened with
            if id == "" {
              @sfbase.pick_new(src, w.id, { "preset": Json::string(text(Some(made), "id")), "presetStation": Json::string(address) })
            }
            close()
          }
          Err(err) => e.error.set(text(Some(err), "message"))
        }
      })
    },
    tone=Primary,
    busy=fn() { e.saving.get() },
    disabled=fn() { !ready() },
  )
  |> ignore
}

///|
/// 添加目录, a step further in from the dialog: a line to find one by name, then 浏览文件夹 and 从 Git 克隆 first
/// whatever is typed, then the folders the workspace's stations found and not in the preset yet, as they come (each
/// station's said as it is; those read before shown meanwhile), by station, those their chats worked in first, each
/// where it is and how many chats used it. One picked, back to the dialog with it among the folders.
fn preset_add_open(src : Source, address : String, stations : Array[Json], e : PresetEditing) -> Unit {
  e.q.set("")
  @sf.panel_nodes(
    @sf.t("web-main.preset.add"),
    fn(v, close) { preset_add_node(v, src, address, stations, e, close) },
    from=Unanchored,
    // (as tall as the folder picker a step further on, its share of the window whatever it lists: as tall as the
    // dialog it comes from or taller, which stays as it was laid out as it slides off, its foot where it stood)
    tall=preset_steps_tall,
  )
}

///|
/// 添加目录's rows' keys: its two ways first, then each station's name over the folders it offers that are not the
/// preset's yet and have what is typed in their name, repository, place or station.
fn preset_add_keys(src : Source, address : String, stations : Array[Json], e : PresetEditing) -> Array[String] {
  let q = e.q.text().trim(chars=" ").to_owned().to_lower()
  let dirs = e.dirs.get()
  let out = ["a\nbrowse", "a\nclone"]
  let mut shown = ""
  for o in offered_dirs(src, address, stations) {
    let one = Some(o)
    let k = dir_key(one)
    let station = dir_station(one, address)
    let station_name = preset_station_name(station, text(one, "stationName"), stations)
    let (name, repo) = (text(one, "name"), text(one, "repo"))
    if dirs.iter().any(fn(d) { dir_key(Some(d)) == k }) ||
      (q != "" && !name.to_lower().contains(q) && !repo.to_lower().contains(q) && !text(one, "where").to_lower().contains(q) && !station_name.to_lower().contains(q)) {
      continue
    }
    if shown != station {
      out.push("h\n" + station)
      shown = station
    }
    out.push("o\n" + k)
  }
  // (room after the last, clear of a dialog's foot corners)
  out.push("z")
  out
}

///|
/// What 添加目录 holds in node `v`: the line to find by, standing still, and its rows scrolling under it.
fn preset_add_node(
  v : @view.View,
  src : Source,
  address : String,
  stations : Array[Json],
  e : PresetEditing,
  close : () -> Unit,
) -> Unit {
  let browse = fn(at : String?) {
    close()
    preset_browse(src, address, stations, e, at)
  }
  let clone = fn() {
    close()
    preset_clone_open(src, address, stations, e)
  }
  v.box(fn(fb) {
    @sf.style_node(fb, fn() { preset_search_at.then(@sf.panel_field_in_node(fb)) })
    @sf.input_node(
      fb,
      e.q,
      placeholder=@sf.t("web-main.preset.search"),
      small=true,
      lead=fn(l) { @sf.icon_node(l, "search", preset_search_icon, By(fn() { @sf.theme().p.muted })) |> ignore },
    )
    // (a search over what the panel lists: the keys as it opens with keys and a mouse, never an input method raised
    // over the folders)
    |> @sf.panel_search_at_hand_node
  })
  |> ignore
  @sf.panel_list_node(
    v,
    fn() { preset_add_keys(src, address, stations, e) },
    fills=true,
    fn(r, k) {
      if k == "z" {
        r.box(fn(z) { @sf.style_node(z, fn() { preset_list_end }) }) |> ignore
      } else if k == "a\nbrowse" {
        preset_action_row(r, "folder", fn() { @sf.t("web-main.preset.browse") }, fn() { browse(None) })
      } else if k == "a\nclone" {
        preset_action_row(r, "download", fn() { @sf.t("web-main.preset.clone") }, clone)
      } else if k.has_prefix("h\n") {
        let s = k.exact_view(start=2).to_owned()
        let saved = @signals.untracked(fn() {
          match offered_dirs(src, address, stations).iter().find_first(fn(o) { dir_station(Some(o), address) == s }) {
            Some(o) => text(Some(o), "stationName")
            None => ""
          }
        })
        @sf.panel_heading_node(r, fn() { preset_station_name(s, saved, stations) })
      } else {
        let at = k.exact_view(start=2).to_owned()
        let find = fn() { offered_dirs(src, address, stations).iter().find_first(fn(o) { dir_key(Some(o)) == at }) }
        guard @signals.untracked(find) is Some(was) else { return }
        let one = fn() { Some(find().unwrap_or(was)) }
        preset_dir_row(
          r,
          fn() { text(one(), "name") },
          fn() { text(one(), "repo") },
          fn() { text(one(), "icon") },
          fn() { dir_note(one(), true) },
          press=fn() {
            e.dirs.set([..e.dirs.untracked(), was])
            @sf.panel_back() |> ignore
          },
        )
      }
    },
    est=preset_row_est,
  )
  |> ignore
}

///|
/// The stations a folder is browsed or cloned on (the workspace's up now), as the library's station control has them.
fn preset_station_choices(stations : Array[Json]) -> Array[@sfbase.StationChoice] {
  stations.map(fn(s) {
    let one = Some(s)
    { station: text(one, "station"), name: preset_station_name(text(one, "station"), "", stations), emoji: text(one, "emoji"), icon: text(one, "icon") }
  })
}

///|
/// 浏览文件夹, a step further in from 添加目录: the folder picker on the station browsed (the composer's at first), at
/// `at` (its home where None), its stations the workspace's up now; switching starts at that station's home. The folder
/// chosen goes among the preset's (on another station than the preset's, with it: its repository where that station
/// offers it so), back in the dialog.
fn preset_browse(src : Source, address : String, stations : Array[Json], e : PresetEditing, at : String?) -> Unit {
  (@sfbase.folder_pick_asked.val)(src, {
    title: @sf.t("web-main.preset.pickFolder"),
    note: "",
    stations: preset_station_choices(stations),
    station: e.browse_station.untracked(),
    at: at.unwrap_or(""),
    action: fn(name) { @sf.t("web-main.preset.choose", args=[("name", name)]) },
    taken: fn(_, _) { false },
    taken_words: "",
    pick: fn(station, here, _, _) {
      e.browse_station.set(station)
      let d = if station == address {
        Json::object({ "path": Json::string(here) })
      } else {
        // (the station offering this folder as a repository: that kept too)
        let repo = match items(presets_of(src, station), "candidates").iter().find_first(fn(o) { text(Some(o), "path") == here }) {
          Some(o) => field(Some(o), "repo").unwrap_or(Json::null())
          None => Json::null()
        }
        Json::object({
          "path": Json::string(here),
          "repo": repo,
          "station": Json::string(station),
          "stationName": Json::string(preset_station_name(station, "", stations)),
        })
      }
      if !e.dirs.untracked().iter().any(fn(x) { dir_key(Some(x)) == dir_key(Some(d)) }) {
        e.dirs.set([..e.dirs.untracked(), d])
      }
      @sf.panel_back(to=e.depth) |> ignore
    },
  })
}

///|
/// 从 Git 克隆, a step further in from 添加目录: under its title where it goes, then the repository's address (its field
/// the keys' as it opens); at its foot the station it is cloned onto (the one browsed; another where there are others)
/// and 克隆, which asks it of that station (`preset.clone`): one it has already among the preset's folders, one under way
/// remembered by the dialog, back in the dialog either way; why not under the field.
fn preset_clone_open(src : Source, address : String, stations : Array[Json], e : PresetEditing) -> Unit {
  e.url.set("")
  e.clone_error.set("")
  e.clone_busy.set(false)
  e.clone_station.set(e.browse_station.untracked())
  let go = fn() {
    let url = @signals.untracked(fn() { e.url.text() }).trim(chars=" \t\n").to_owned()
    guard url != "" && !e.clone_busy.untracked() else { return }
    let station = e.clone_station.untracked()
    e.clone_busy.set(true)
    e.clone_error.set("")
    (src.call)("preset.clone", { "station": Json::string(station), "url": Json::string(url) }, fn(r) {
      e.clone_busy.set(false)
      match r {
        Ok(a) => {
          let one = Some(a)
          if text(one, "state") == "there" {
            let d = dir_of_station(
              Json::object({ "path": Json::string(text(one, "path")), "repo": Json::string(text(one, "repo")), "name": Json::string(text(one, "name")) }),
              station,
              address,
              stations,
            )
            if !e.dirs.untracked().iter().any(fn(x) { dir_key(Some(x)) == dir_key(Some(d)) }) {
              e.dirs.set([..e.dirs.untracked(), d])
            }
          } else {
            e.clones.set([..e.clones.untracked(), { station, id: text(one, "id"), repo: text(one, "repo"), name: text(one, "name") }])
          }
          e.browse_station.set(station)
          @sf.panel_back(to=e.depth) |> ignore
        }
        Err(err) => e.clone_error.set(text(Some(err), "message"))
      }
    })
  }
  @sf.panel_nodes(
    @sf.t("web-main.preset.cloneTitle"),
    fn(v, _) {
      v.box(fn(col) {
        @sf.style_node(col, fn() { preset_form })
        @sf.field_node(
          col,
          fn() { @sf.t("web-main.preset.cloneUrl") },
          error=fn() { e.clone_error.get() },
          fn(b) {
            let f = @sf.input_node(b, e.url, placeholder=@sf.t("web-main.preset.clonePlaceholder"), submitted=fn(_) { go() })
            @sf.panel_opens_in_node(f)
          },
        )
      })
      |> ignore
    },
    from=Unanchored,
    // (where it goes said under its title, as the station it goes onto is now)
    live=fn() {
      (
        @sf.t("web-main.preset.cloneTitle"),
        "",
        @sf.t("web-main.preset.cloneWhere", args=[("station", preset_station_name(e.clone_station.get(), "", stations))]),
      )
    },
    foot=fn(v, _) {
      // (the station it is cloned onto at its start: another where there are others; round as the buttons beside it)
      @sfbase.station_choice_node(
        v,
        fn() { preset_station_choices(stations) },
        fn() { e.clone_station.get() },
        fn(at) { e.clone_station.set(at) },
        title=@sf.t("android-misc.files.lendOn"),
        label=fn(name) { @sf.t("android-misc.files.lendOn") + ": " + name },
        round=true,
      )
      |> ignore
      @sf.foot_spacer_node(v)
      @sf.button_node(v, fn() { @sf.t("web-main.preset.cloneGo") }, go, tone=Primary, busy=fn() { e.clone_busy.get() }, disabled=fn() {
        e.url.text().trim(chars=" \t\n").to_owned() == ""
      })
      |> ignore
    },
  )
}

///|
/// A folder by where it is: its station ("" the preset's own) and its path.
fn dir_key(d : Json?) -> String {
  text(d, "station") + "\n" + text(d, "path")
}

///|
/// The station a folder is on (an absent station means the preset's own).
fn dir_station(d : Json?, address : String) -> String {
  let at = text(d, "station")
  if at == "" { address } else { at }
}

///|
/// The workspace's current name for a station, or its saved name when it is offline.
fn preset_station_name(address : String, saved : String, stations : Array[Json]) -> String {
  match stations.iter().find_first(fn(s) { text(Some(s), "station") == address }) {
    Some(s) if text(Some(s), "name") != "" => text(Some(s), "name")
    _ => if saved != "" { saved } else { address }
  }
}

///|
/// The folders the workspace's stations offer (each one's `presets` topic, read as it is shown): the preset's
/// station's first, then the others', each marked with its station. The same repository on two stations is offered
/// on both: their paths and the instructions in them can differ.
fn offered_dirs(src : Source, address : String, stations : Array[Json]) -> Array[Json] {
  let out : Array[Json] = []
  let take = fn(at : String, station_name : String) {
    for o in items(presets_of(src, at), "candidates") {
      match o {
        Object(m) if at != address => {
          let marked = m.copy()
          marked["station"] = Json::string(at)
          marked["stationName"] = Json::string(station_name)
          out.push(Json::object(marked))
        }
        _ => out.push(o)
      }
    }
  }
  take(address, "")
  for s in stations {
    let at = text(Some(s), "station")
    if at != "" && at != address {
      take(at, text(Some(s), "name"))
    }
  }
  out
}

///|
/// What a folder says under its name: where it is, and how many chats worked in it (`chats`: where it is offered).
fn dir_note(o : Json?, chats : Bool) -> String {
  let n = count(o, "chats")
  let at = if text(o, "where") != "" { text(o, "where") } else if text(o, "repo") != "" { text(o, "repo") } else { text(o, "path") }
  let parts = [
    at,
    if chats && n > 0 { @sf.t("web-main.preset.chats", args=[("n", n.to_string())]) } else { "" },
  ]
  join(parts.filter(fn(x) { x != "" }), " · ")
}

///|
/// A folder's mark in the preset's dialog: as high as its two lines, its corner the small block's (the ladder's 10), so
/// with a row's 8 over and under it stands a corner's inset (8) in from the row's round ground on every side, concentric
/// with its 18 (@sf.panel_row_in_node) whether the row has one line or two.
let preset_dir_mark : Double = 34.0

///|
/// The icon in a neutral tile of a row that does something (浏览文件夹, 从 Git 克隆, 添加目录).
let preset_action_icon : Double = 18.0

///|
/// A folder's ×: as high as its name's line and a half.
let preset_dir_x : Double = 28.0

///|
/// The search's mark before what is typed.
let preset_search_icon : Double = 16.0

///|
/// A row's height before it is laid out (a name, a note under it, its tile's room).
let preset_row_est : Double = 50.0

///|
/// 添加目录's share of the window, the folder picker's (sfdesk station_pick_tall's).
let preset_steps_tall : Double = 0.86

///|
/// 添加目录's room after its last row: what is there clear of a dialog's foot corners (no foot of its own).
// kept across runs: a value (no field of it changes)
let preset_list_end : @ui.Style = @ui.css("w=Full h=S4")

///|
/// Between what stands at a row's end (a spinner, its ×).
let preset_tail_gap : Double = 8.0

///|
/// A row of the preset's (preset_row): 44 high at least, 8 over and under, 12 between its tile, its words, its end.
// kept across runs: a value (no field of it changes)
let preset_row_at : @ui.Style = @ui.css("row w=Full min_h=S11 py=S2 gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let preset_dir_name : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let preset_dir_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L4, color=Muted, wrap=false, w=Cut)

///|
/// Why a clone failed, in red.
// kept across runs: a value (no field of it changes)
let preset_dir_bad : @ui.TextStyle = @ui.text_style(size=Meta, leading=L4, color=Danger, wrap=false, w=Cut)

///|
/// The dialog's fields, and the clone step's: one under another, 16 apart.
// kept across runs: a value (no field of it changes)
let preset_form : @ui.Style = @ui.css("w=Full gap=S4")

///|
/// 添加目录's search over its rows: across the panel (where panel_field_in_node stands it), a row's room under it.
// kept across runs: a value (no field of it changes)
let preset_search_at : @ui.Style = @ui.css("w=Full pb=S1_5")

///|
/// The picked preset's folders' marks, side by side in its control.
// kept across runs: a value (no field of it changes)
let preset_marks_row : @ui.Style = @ui.css("row gap=S0_5 align=ACenter")

///|
/// Short of room, the preset's words go with the first of the model's parts (model_triple.mbt triple_drop_name: who
/// runs it by name, later in the row, goes before them), before the station's name.
let preset_drop_words : Int = 1

///|
/// The last it gives up, after the station's name: its chevron.
let preset_drop_chevron : Int = new_drop_station_name + 1

///|
fn preset_context_num(v : Json?) -> Int {
  match field(v, "context") {
    Some(Number(n, ..)) if n > 0.0 => n.to_int()
    Some(String(s)) if s != "" => {
      let mut acc = 0
      for ch in s {
        let code = ch.to_int()
        if code >= 48 && code <= 57 {
          acc = acc * 10 + (code - 48)
        } else {
          return 0
        }
      }
      acc
    }
    _ => 0
  }
}

///|
fn preset_context_text(v : Json?) -> String {
  let n = preset_context_num(v)
  if n <= 0 {
    ""
  } else if n >= 1_000_000 {
    let whole = n / 1_000_000
    let tenths = (n % 1_000_000) / 100_000
    if tenths == 0 {
      "\{whole}M"
    } else {
      "\{whole}.\{tenths}M"
    }
  } else if n >= 1_000 {
    let whole = n / 1_000
    "\{whole}K"
  } else {
    n.to_string()
  }
}

///|
fn preset_speed_text(v : Json?) -> String {
  match text(v, "speed") {
    "ultrafast" => "Ultrafast"
    "fast" => "Fast"
    _ => if flag(v, "fast") { "Fast" } else { "" }
  }
}

///|
fn preset_station_mark_node(
  parent : @view.View,
  emoji : String,
  icon : String,
  size : Double,
  tint : () -> Int64,
) -> Unit {
  if emoji != "" || icon != "" {
    @sf.station_mark_node(parent, fn() { emoji }, fn() { icon }, size, tint, fn() { 0 })
  } else {
    @sf.icon_node(parent, "server", size, By(tint)) |> ignore
  }
}

///|
/// Station 与模型：一行双胶囊，支持不限（不选）或指定 Station（单选/多选自动分配）与模型。
fn preset_capsules_node(
  col : @view.View,
  src : Source,
  address : String,
  stations : Array[Json],
  e : PresetEditing,
) -> Unit {
  let has_station = fn() {
    e.auto_station.get() || e.station.get() != "" || e.stations.get().length() > 0
  }
  let pinned_station = fn() -> Json? {
    if e.auto_station.get() || e.station.get() == "" {
      None
    } else {
      let sid = e.station.get()
      stations.iter().find_first(fn(s) { text(Some(s), "id") == sid || text(Some(s), "station") == sid })
    }
  }
  let station_words = fn() {
    if e.auto_station.get() {
      @sf.t("web-main.preset.autoStation")
    } else if e.station.get() != "" {
      let sid = e.station.get()
      match pinned_station() {
        Some(s) if text(Some(s), "name") != "" => text(Some(s), "name")
        _ => sid
      }
    } else if e.stations.get().length() > 0 {
      @sf.t("web-main.preset.stationsCount", args=[("n", e.stations.get().length().to_string())])
    } else {
      @sf.t("web-main.preset.anyStation")
    }
  }
  let pick_v = fn() {
    src.topic("pick", { "station": Json::string(address), "of": Json::string("connect-new:preset") }).get().value
  }
  let pick_val = fn() {
    match e.model_state.get() {
      2 => field(pick_v(), "value")
      0 => e.initial_model.get()
      _ => None
    }
  }
  let pick_vo = fn() {
    match e.model_state.get() {
      2 => field(pick_v(), "valueOption")
      0 => {
        let mid = text(e.initial_model.get(), "model")
        if mid == "" {
          None
        } else {
          items(pick_v(), "options").iter().find_first(fn(o) { text(Some(o), "model") == mid })
        }
      }
      _ => None
    }
  }
  let has_model = fn() { text(pick_val(), "model") != "" }
  let model_words = fn() {
    if !has_model() {
      @sf.t("web-main.preset.anyModel")
    } else {
      let mname = if text(pick_vo(), "name") != "" { text(pick_vo(), "name") } else { text(pick_val(), "model") }
      let parts = [mname]
      let rt = text(pick_val(), "runtime")
      if !flag(pick_v(), "runtimeFixed") && (flag(pick_v(), "showRuntime") || items(pick_vo(), "runtimes").length() > 1) && rt != "" {
        parts.push(@settings.runtime_short(rt))
      }
      let eff = effort_text(text(pick_val(), "effort"))
      if eff != "" {
        parts.push(eff)
      }
      let speed = if e.model_state.get() == 2 {
        let ft = text(pick_v(), "fastText")
        if ft != "" { ft } else { preset_speed_text(pick_val()) }
      } else {
        preset_speed_text(pick_val())
      }
      if speed != "" {
        parts.push(speed)
      }
      let ctx = preset_context_text(pick_val())
      if ctx != "" {
        parts.push(ctx)
      }
      if e.model_state.get() == 2 {
        let acc = text(field(pick_v(), "account"), "text")
        if acc != "" {
          parts.push(acc)
        }
      } else {
        let p_list = items(pick_val(), "profiles")
        let pid = if p_list.length() == 1 {
          match p_list[0] {
            String(s) => s
            _ => ""
          }
        } else if p_list.length() == 0 {
          text(pick_val(), "profile")
        } else {
          ""
        }
        if pid != "" {
          let acc = items(pick_v(), "accounts").iter().find_first(fn(a) { text(Some(a), "id") == pid })
          let name = text(acc, "name")
          parts.push(if name != "" { name } else { pid })
          let plan = text(acc, "planText")
          if plan != "" {
            parts.push(plan)
          }
        }
      }
      join(parts, " · ")
    }
  }
  @sf.field_node(col, fn() { @sf.t("web-main.preset.runtimeSection") }, fn(b) {
    b.box(fn(bar) {
      @sf.style_node(bar, fn() { preset_simple_capsules })
      bar.wraps(Is(Some(8.0))) |> ignore
      preset_capsule_pill(
        bar,
        fn(l) {
          l.pick(
            fn() {
              if !e.auto_station.get() && e.station.get() != "" {
                let st = pinned_station()
                Some((text(st, "emoji"), text(st, "icon")))
              } else {
                None
              }
            },
            fn(m, pinned) {
              match pinned {
                Some((emoji, icon)) => preset_station_mark_node(m, emoji, icon, 15.0, fn() { @sf.theme().p.text })
                None =>
                  @sf.icon_node(
                    m,
                    "sliders",
                    15.0,
                    By(fn() { if has_station() { @sf.theme().p.text } else { @sf.theme().p.muted } }),
                  )
                  |> ignore
              }
            },
          )
        },
        station_words,
        has_station,
        fn(btn) { preset_station_open(src, address, stations, e, Node(btn)) },
        fn() { @sf.t("web-main.preset.clearStation") },
        fn() {
          e.auto_station.set(false)
          e.station.set("")
          e.stations.set([])
        },
      )
      preset_capsule_pill(
        bar,
        fn(l) {
          l.pick(
            fn() {
              if has_model() {
                Some((text(field(pick_vo(), "maker"), "id"), text(pick_val(), "runtime")))
              } else {
                None
              }
            },
            fn(m, picked_maker) {
              match picked_maker {
                Some((maker_id, rt)) => @sf.maker_mark_node(m, maker_id, rt, 14.0) |> ignore
                None => @sf.icon_node(m, "sparks", 15.0, By(fn() { @sf.theme().p.muted })) |> ignore
              }
            },
          )
        },
        model_words,
        has_model,
        fn(btn) {
          let state_was = e.model_state.untracked()
          if state_was != 2 {
            match (state_was, e.initial_model.untracked()) {
              (0, Some(Object(m))) if text(Some(Json::object(m)), "model") != "" => {
                let save_p : Map[String, Json] = {
                  "station": Json::string(address),
                  "of": Json::string("connect-new:preset"),
                  "model": Json::string(text(Some(Json::object(m)), "model")),
                }
                for k in ["runtime", "effort", "fast", "speed", "context", "tui", "profile", "profiles"] {
                  match m.get(k) {
                    Some(v) => save_p[k] = v
                    None => ()
                  }
                }
                (src.call)("pick.save", Json::object(save_p), @sfbase.answer_unread)
              }
              _ =>
                (src.call)(
                  "pick.set",
                  { "station": Json::string(address), "of": Json::string("connect-new:preset"), "clear": Json::boolean(true) },
                  @sfbase.answer_unread,
                )
            }
            e.model_state.set(2)
          }
          let (x, y, w, h) = btn.placed_window_now()
          open_triple_panel(
            src,
            address,
            "connect-new:preset",
            At(x, y, w, h),
            asks=fn(borrow) { borrow_ask(src, address, "connect-new:preset", borrow) },
          )
        },
        fn() { @sf.t("web-main.preset.clearModel") },
        fn() {
          e.model_state.set(1)
          (src.call)(
            "pick.set",
            { "station": Json::string(address), "of": Json::string("connect-new:preset"), "clear": Json::boolean(true) },
            @sfbase.answer_unread,
          )
        },
      )
    })
    |> ignore
  })
}

///|
fn preset_capsule_pill(
  parent : @view.View,
  lead : (@view.View) -> Unit,
  words : () -> String,
  has_value : () -> Bool,
  on_open : (@view.View) -> Unit,
  clear_label : () -> String,
  on_clear : () -> Unit,
) -> Unit {
  @sf.filter_pill_node(parent, words, on_open, picked=has_value, lead~, clear=on_clear, clear_label~)
  |> ignore
}

///|
fn preset_station_id(s : Json) -> String {
  let id = text(Some(s), "id")
  if id != "" { id } else { text(Some(s), "station") }
}

///|
fn preset_station_open(
  _src : Source,
  _address : String,
  stations : Array[Json],
  e : PresetEditing,
  from : @sf.Anchor,
) -> Unit {
  let all_ids = stations.map(preset_station_id).filter(fn(id) { id != "" })
  let current_selected = fn() -> Array[String] {
    if e.auto_station.get() {
      all_ids
    } else if e.station.get() != "" {
      [e.station.get()]
    } else {
      e.stations.get()
    }
  }
  let apply_selected = fn(next : Array[String]) {
    if next.length() == 0 {
      e.auto_station.set(false)
      e.station.set("")
      e.stations.set([])
    } else if next.length() == 1 {
      e.auto_station.set(false)
      e.station.set(next[0])
      e.stations.set([])
    } else if all_ids.length() > 1 && next.length() >= all_ids.length() {
      e.auto_station.set(true)
      e.station.set("")
      e.stations.set([])
    } else {
      e.auto_station.set(false)
      e.station.set("")
      e.stations.set(next)
    }
  }
  let unrestricted = fn() {
    !e.auto_station.get() && e.station.get() == "" && e.stations.get().length() == 0
  }
  let all_checked = fn() {
    e.auto_station.get() || (all_ids.length() > 1 && e.stations.get().length() >= all_ids.length())
  }
  let some_checked = fn() {
    !unrestricted() && !all_checked()
  }
  @sf.panel_nodes(
    @sf.t("android-chat.new.station.pick"),
    fn(n, close) {
      @sf.choice_row_node(
        n,
        fn() { @sf.t("web-main.preset.anyStation") },
        unrestricted,
        compact=true,
        note=fn() { @sf.t("web-main.preset.anyStationHint") },
        press=fn() {
          apply_selected([])
          close()
        },
      )
      let allowlisted_count = stations.filter(fn(s) { flag(Some(s), "acceptAutoChats") }).length()
      @sf.choice_row_node(
        n,
        fn() { @sf.t("web-main.preset.autoStation") },
        fn() { false },
        compact=true,
        lead=fn(l) { @sf.check_mark_node(l, all_checked, mixed=some_checked) },
        note=fn() {
          if allowlisted_count > 0 {
            @sf.t("web-main.preset.autoStationAllowlistHint", args=[("n", allowlisted_count.to_string())])
          } else {
            @sf.t("web-main.preset.autoStationEmptyHint")
          }
        },
        press=fn() {
          if all_checked() {
            apply_selected([])
          } else {
            e.auto_station.set(true)
            e.station.set("")
            e.stations.set([])
          }
        },
      )
      for s in stations {
        let sid = preset_station_id(s)
        let sname = preset_station_name(text(Some(s), "station"), text(Some(s), "name"), stations)
        let emoji = text(Some(s), "emoji")
        let icon = text(Some(s), "icon")
        let checked = fn() {
          e.auto_station.get() || e.station.get() == sid || e.stations.get().contains(sid)
        }
        @sf.choice_row_node(
          n,
          fn() { sname },
          fn() { false },
          compact=true,
          lead=fn(l) {
            l.gap(Is(8.0)) |> ignore
            @sf.check_mark_node(l, checked)
            preset_station_mark_node(l, emoji, icon, 15.0, fn() { @sf.theme().p.muted })
          },
          note=fn() { text(Some(s), "summary") },
          press=fn() {
            let cur = @signals.untracked(current_selected)
            if cur.contains(sid) {
              apply_selected(cur.filter(fn(x) { x != sid }))
            } else {
              apply_selected([..cur, sid])
            }
          },
        )
      }
    },
    from~,
  )
}

///|
// kept across runs: a value (no field of it changes)
let preset_simple_capsules : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
/// The control's words while no preset is picked: as quiet as what says what is not chosen.
// kept across runs: a value (no field of it changes)
let preset_capsule_quiet : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let preset_panel_search_wrap : @ui.Style = @ui.css("w=Full pb=S2")

///|
// kept across runs: a value (no field of it changes)
let preset_panel_head_row : @ui.Style = @ui.css("row w=Full pl=S2_5 pr=S1 pt=S1 pb=S1_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let preset_panel_head_title : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Semibold, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let preset_panel_clear_btn : @ui.Style = @ui.css("row min_h=S7 align=ACenter px=S2 radius=Full")

///|
// kept across runs: a value (no field of it changes)
let preset_panel_clear_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let preset_sheet_clear_btn : @ui.Style = @ui.css("row align=ACenter px=S2 radius=Full")

///|
// kept across runs: a value (no field of it changes)
let preset_sheet_clear_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let preset_picker_line : @ui.Style = @ui.css("row w=Full align=AStart gap=S1")

///|
// kept across runs: a value (no field of it changes)
let preset_picker_main : @ui.Style = @ui.css("row w=Full align=AStart gap=S2_5 py=S2")

///|
// kept across runs: a value (no field of it changes)
let preset_picker_main_split : @ui.Style = @ui.css("row align=AStart gap=S2_5 p=S2")

///|
// kept across runs: a value (no field of it changes)
let preset_picker_title_row : @ui.Style = @ui.css("row w=Full align=ACenter gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let preset_picker_name : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let preset_picker_name_chosen : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let preset_picker_summary : @ui.TextStyle = @ui.text_style(size=Meta, leading=L4, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let preset_empty_box : @ui.Style = @ui.css("w=Full py=S5 px=S2 align=ACenter gap=S1")

///|
// kept across runs: a value (no field of it changes)
let preset_empty_title : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, weight=Medium, color=Fg)

///|
// kept across runs: a value (no field of it changes)
let preset_empty_hint : @ui.TextStyle = @ui.text_style(size=Meta, leading=L4, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let preset_panel_foot_row : @ui.Style = @ui.css("row w=Full align=ACenter gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let preset_foot_btn : @ui.Style = @ui.css("row align=ACenter gap=S1_5 px=S2_5 radius=Full")

///|
// kept across runs: a value (no field of it changes)
let preset_foot_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, wrap=false, w=Cut)
