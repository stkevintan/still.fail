// Profiles, the model accounts the agents run on (settings/Profiles.kt ProfilesScreen; the core's `profiles` view and
// each station's overview), made once as nodes of the window's tree in every frame, laid out by its width (page_node):
// every station's in one list, a section a kind of account, an account a row (its vendor's mark, its name and plan, what
// needs a look, its allowance), each station's own logins not used yet after them; from a station's page that station's
// only. And an account on several stations (ProfileAccountScreen): how it is, its allowance, each station's part.

///|
/// The profiles' list (ProfilesScreen) in node `v`, laid out by the `width` its frame gives it (narrow where none is
/// given), in the frame it is given: the workspace's (`only` "") as the core's `profiles` says them now, or station
/// `only`'s as that part of its overview says them; each section's heading and each account's row a block of its own (a
/// row a piece of its section's card), by its key, so one coming or going comes and goes where it is. Adding one (on a
/// station online) at its title's end, where the frame does not hold it itself (a place's notch names the page:
/// `frame().named`), or in a frame's bar (`bar_actions`). `here`: who and where, as that changes. 概览 pressed:
/// `on_show_overview` (a pushed page's own by default; the bottom bar's place says its own).
pub fn profiles_list_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  only : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
  bar_actions? : ((@view.View) -> Unit, (@sf.Look) -> Double) -> Unit,
  bar_add? : Bool = true,
  on_show_overview? : () -> Unit = fn() { @settings.profiles_narrow_overview.set(true) },
  on_show_accounts? : () -> Unit = fn() {  },
  tab_chosen? : () -> Int = fn() { 0 },
  tabs_thumb? : @sf.SegThumb,
  batch? : ProfilesBatch = ProfilesBatch::new(),
) -> Unit {
  let tips = match tips {
    Some(t) => t
    None => @sf.TipLayer::new(fn() { Some(v) })
  }
  let profiles = fn() { (core.topic)("profiles", { "scope": str(here().workspace) }).get() }
  let stations_topic = fn() { @settings.stations_of(core, here()) }
  // the station it is of, where it is one's (none while the stations are read)
  let one_now = @signals.computed(fn(_) {
    match stations_topic().value {
      Some(Array(a)) if only != "" => a.iter().find_first(fn(x) { text(Some(x), "station") == only })
      _ => None
    }
  }, same=json_opt_same)
  let one = fn() { one_now.get() }
  // (its rows by section, each worked out once for each change of what it reads: the workspace's entries, or the
  // station's own profiles)
  let rows_now : @signals.Computed[Array[Json]] = @signals.computed(fn(_) {
    if only == "" {
      items(profiles().value, "items")
    } else {
      match @settings.station_part(core, here(), only, "profiles") {
        Some(Array(a)) => a
        _ => []
      }
    }
  }, same=jsons_same)
  // (its sections' headings and accounts' rows, each a block by its key, kept by key as its rows change: a block reads
  // its own, told only as that one changes, comes or goes, and none of them works its sections out again: View::keyed_by)
  let parts : @signals.KeyedList[String, (String, PlPart)] = v.keyed_by(
    fn() {
      let out : Array[(String, PlPart)] = []
      for g in pl_groups(rows_now.get()) {
        out.push(("g/" + g.0, PlGroup(g.1)))
        for i, e in g.2 {
          out.push(("p/" + g.0 + "/" + pl_key(only, e), PlRow(e, @sf.card_piece_of(i, g.2.length()))))
        }
      }
      out
    },
    fn(e) { e.0 },
    same=pl_entry_same,
  )
  // the machines' own logins not used yet, a block a station up that offers one: the workspace's by station, each
  // block reading its own
  let offers : @signals.KeyedList[String, (Json, Array[Json])] = v.keyed_by(
    fn() { if only == "" { @settings.profiles_offers(profiles().value) } else { [] } },
    fn(o) { text(Some(o.0), "station") },
    same=fn(a, b) { json_same(a.0, b.0) && jsons_same(a.1, b.1) },
  )
  let offers_now = fn() -> Array[String] {
    if only == "" {
      offers.keys()
    } else if flag(one(), "online") {
      [only]
    } else {
      []
    }
  }
  // (多选: a workspace manager's, the accounts' rows as the workspace's list makes them, a station's own profile's
  // that list's row of it on that station; read only while it is on)
  let batch_rows_now : @signals.Computed[Array[Json]] = @signals.computed(fn(_) {
    if only == "" {
      rows_now.get()
    } else {
      // (a station's own: whether it shares, as its overview says it; whether it is up, as its row says it)
      let o = field(@settings.station_of(core, here(), only), "overview")
      rows_now.get().map(fn(p) { profiles_batch_row(only, p, o, one()) })
    }
  }, same=jsons_same)
  // (a workspace come into view: no 多选 begun in another)
  v.reacts(fn() { here().workspace }, fn(_) { batch.stop() }, at_start=false)
  let batch_rows = fn() { batch_rows_now.get() }
  // (a manager's as the workspace's list says it; a station's own page's as the workspace does)
  let batch_offered = fn() {
    profiles_batch_offered(
      fn() { if only == "" { flag(profiles().value, "manages") } else { @settings.manager_of(core, here()) == Some(true) } },
      fn() { rows_now.get() },
    )
  }
  let batch_stations = fn() {
    match stations_topic().value {
      Some(Array(a)) => a
      _ => []
    }
  }
  let add = fn() { @settings.place_action(core, here(), "profiles") is Some(_) }
  let adding = fn(at : @view.View) {
    match @settings.place_action(core, @signals.untracked(here), "profiles") {
      Some(run) => run(Node(at))
      None => ()
    }
  }
  let label = fn() { @sf.t("android-misc.bar.action.profiles") }
  // (the subscriptions' allowances shared as a picture, the workspace's list's: share_quota.mbt)
  let share_avail = profile_share_available(core, here)
  let share_shown = fn() { only == "" && !frame().named && share_avail.get() }
  // (its own 多选 where its frame does not name it; one that does says it in its bar: profiles_page_node's)
  // (its entry stays while 多选 is on, pressed again to end it: what stands beside it never moves)
  let select_shown = fn() { batch_offered() }
  let select_here = fn() { select_shown() && !frame().named }
  let select_label = fn() { @sf.t("web-pages.profiles.batch.select") }
  let actions = fn(l : @view.View) {
    @sf.bar_actions_pill_node(
      l,
      fn() { share_shown() || select_here() || (add() && !frame().named) },
      count=fn() {
        (if share_shown() { 1 } else { 0 }) + (if select_here() { 1 } else { 0 }) + (if add() && !frame().named { 1 } else { 0 })
      },
      fn(g) {
        if only == "" {
          profile_share_node(g, core, here, fn() { !frame().named }, Some(tips))
        }
        g.show(select_here, fn(a) {
          @sf.icon_button_node(a, "check-circle", select_label, fn() {
            on_show_accounts()
            batch.toggle()
          }, tips~, on=fn() { batch.on.get() })
          |> ignore
        })
        g.show(fn() { add() && !frame().named }, fn(a) { @sf.page_add_node(a, label, adding) })
      },
    )
  }
  match bar_actions {
    Some(f) =>
      f(
        fn(l) {
          if only == "" {
            profile_share_node(l, core, here, fn() { true }, Some(tips), bar=true)
          }
          l.show(select_shown, fn(a) {
            @sf.bar_icon_node(a, "check-circle", select_label, fn() {
              on_show_accounts()
              batch.toggle()
            }, tips~)
          })
          if bar_add {
            l.show(add, fn(a) { @sf.page_add_node(a, label, adding) })
          }
        },
        fn(_) { @sf.button_height() },
      )
    None => ()
  }
  let wait = fn() { field(profiles().value, "wait") }
  // (its frame, with the room 多选's bar takes at its foot while it is on: profiles_batch_room)
  let framed = fn() {
    let f = frame()
    if batch.on.get() { { ..f, foot: f.foot + profiles_batch_room() } } else { f }
  }
  @sf.page_node(
    v,
    fn() { @sf.t("android-misc.bar.place.profiles") },
    fn() {
      let out : Array[String] = []
      if only == "" {
        let list = rows_now.get()
        match profiles().value {
          None => return ["waiting"]
          Some(_) if list.length() == 0 && (flag(wait(), "reading") || items(wait(), "failing").length() > 0) => return ["waiting"]
          _ => ()
        }
        // (none: said so; else 账号 | 概览 over them, the overview a page of its own: profiles_overview_node)
        if list.length() == 0 {
          out.push("none")
        } else {
          out.push("tab")
        }
      } else {
        match one() {
          None => return ["waiting"]
          Some(_) => if rows_now.get().length() == 0 { out.push("empty") }
        }
      }
      out.append(parts.keys())
      if only == "" && flag(wait(), "reading") {
        out.push("reading")
      }
      for s in offers_now() {
        out.push("o/" + s)
      }
      out
    },
    fn(b, key) {
      match key {
        "waiting" =>
          @sf.waiting_node(
            b,
            fn(s) {
              @sf.section_heading_node(s, fn() { @sf.sample_words(4) })
              @sf.group_node(s, fn(g) {
                g.each(fn() { profiles_sample }, fn(e) { text(Some(e), "key") }, fn(r, e) {
                  pl_account_row_node(r, core.quiet(), fn() { Some(e.get()) }, tips, width?)
                })
              })
            },
            error=fn() {
              let e = if only == "" { profiles().error } else { stations_topic().error }
              match e {
                Some(x) => error_text(x)
                None => ""
              }
            },
            note=fn() {
              let failing = @settings.failing_of(wait())
              { reading: failing.length() == 0, text: "", failing }
            },
          )
        "none" => {
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(g, fn() { @sf.t("web-pages.settings.profiles.none") }, fn() {  }, goes=false)
          })
          @sf.page_note_node(b, fn() { @sf.t("android-settings.profiles.note") })
        }
        "empty" =>
          @sf.group_node(b, fn(g) {
            g.pick(fn() { (field(one(), "overview") is None || @settings.station_part(core, here(), only, "profiles") is None) && flag(one(), "online") }, fn(
              p,
              reading,
            ) {
              if reading {
                p.box(fn(w) {
                  @sf.style_node(w, fn() { pl_wait_room })
                  @sf.wait_line_node(w, fn() { @sf.t("common.reading") }) |> ignore
                })
                |> ignore
              } else {
                @sf.link_row_node(
                  p,
                  fn() {
                    @sf.t(if field(one(), "overview") is None { "android-settings.profiles.stationOffline" } else { "android-settings.profiles.empty" })
                  },
                  fn() {  },
                  goes=false,
                )
              }
            })
          })
        "tab" =>
          @sf.page_choice_node(
            b,
            fn() { if @sf.language() == "en" { ["Accounts", "Overview"] } else { ["账号", "概览"] } },
            tab_chosen,
            fn(i) {
              if i == 1 {
                on_show_overview()
              } else if i == 0 {
                on_show_accounts()
              }
            },
            thumb?=tabs_thumb,
          )
        "reading" =>
          @sf.group_node(b, fn(g) {
            g.box(fn(w) {
              @sf.style_node(w, fn() { pl_wait_room })
              @sf.wait_line_node(w, fn() {
                match text(wait(), "text") {
                  "" => @sf.t("common.reading")
                  x => x
                }
              })
              |> ignore
            })
            |> ignore
          })
        k if k.has_prefix("g/") => {
          let group = k.exact_view(start=2).to_owned()
          let title = fn() {
            match parts.get(k) {
              Some((_, PlGroup(t))) => t
              _ => ""
            }
          }
          // (a station's: its kind's mark before its title, 6 from it, as its old page had it; the workspace's: its name
          // alone, each account's mark its row's, as the sidebar's rows have it; the user, 2026-11-14)
          if only == "" {
            @sf.section_heading_node(b, title)
          } else {
            @sf.section_heading_node(b, title, lead=fn(l) { vt_group_mark_node(l, group) })
          }
        }
        k if k.has_prefix("p/") => pl_row_block(b, core, only, parts, tips, fn() { k }, batch, batch_rows, width?)
        k if k.has_prefix("o/") => {
          let station = k.exact_view(start=2).to_owned()
          let sv = @signals.computed(fn(_) {
            if only != "" {
              one()
            } else {
              offers.get(station).map(fn(o) { o.0 })
            }
          }, same=json_opt_same)
          let logins = fn() {
            if only != "" {
              @settings.station_part(core, here(), only, "machineLogins")
            } else {
              offers.get(station).map(fn(o) { Json::array(o.1) })
            }
          }
          pl_machine_offers_node(b, core, station, fn() { sv.get() }, logins, fn(_) { (core.push)(NewProfile(station)) }, tips)
        }
        _ => ()
      }
    },
    on_back~,
    frame=framed,
    actions~,
    said?,
    width?,
    tips~,
    // (from a station's page, back to it by its name, as the old page said it)
    back_as=fn() { if only == "" { "" } else { text(one(), "name") } },
    // (an account's row put by as it leaves what shows and taken by the next, reading the key it shows now)
    reused=fn(k) { if k.has_prefix("p/") { Some(0) } else { None } },
    make_reused=fn(b, _, key) { pl_row_block(b, core, only, parts, tips, key, batch, batch_rows, width?) },
  )
  // (多选's bar at the page's foot, over the frame's room there)
  profiles_batch_foot_node(v, core, batch, batch_rows, batch_stations, foot=fn() { frame().foot }, page=true, width?)
}

///|
/// What a block of the profiles' list is: a section's heading (its title), or an account's row (its JSON and which
/// piece of its section's card it is).
#derive(Eq)
priv enum PlPart {
  PlGroup(String)
  PlRow(Json, @sf.CardPiece)
}

///|
/// The same block of the profiles' list: its key, and what it is the same (an account's JSON as json_same says).
fn pl_entry_same(a : (String, PlPart), b : (String, PlPart)) -> Bool {
  a.0 == b.0 &&
  (match (a.1, b.1) {
    (PlGroup(x), PlGroup(y)) => x == y
    (PlRow(x, px), PlRow(y, py)) => px == py && json_same(x, y)
    _ => false
  })
}

///|
/// An account's key among the rows of its list: the workspace's entry's own, a station's profile's id.
fn pl_key(only : String, e : Json) -> String {
  if only == "" {
    text(Some(e), "key")
  } else {
    text(Some(e), "id")
  }
}

///|
/// The rows by the kind they are listed under (`group`, `groupTitle`), in order: each kind, its title, its rows.
fn pl_groups(list : Array[Json]) -> Array[(String, String, Array[Json])] {
  let out : Array[(String, String, Array[Json])] = []
  for p in list {
    let g = text(Some(p), "group")
    match out.search_by(fn(x) { x.0 == g }) {
      Some(i) => out[i].2.push(p)
      None => out.push((g, text(Some(p), "groupTitle"), [p]))
    }
  }
  out
}

///|
/// Block `key()` of the profiles' list ("p/<group>/<key>"), the key it shows now: an account's row, a piece of its
/// section's card, as it is now (as it was last, while it goes).
fn pl_row_block(
  b : @view.View,
  core : Core,
  only : String,
  parts : @signals.KeyedList[String, (String, PlPart)],
  tips : @sf.TipLayer,
  key : () -> String,
  batch : ProfilesBatch,
  batch_rows : () -> Array[Json],
  width? : () -> Double,
) -> Unit {
  let last : Ref[(Json, @sf.CardPiece)?] = Ref(None)
  let now = @signals.computed(fn(_) {
    match parts.get(key()) {
      Some((_, PlRow(e, piece))) => last.val = Some((e, piece))
      _ => ()
    }
    last.val
  }, same=fn(a, b) {
    match (a, b) {
      (Some((x, px)), Some((y, py))) => px == py && json_same(x, y)
      (None, None) => true
      _ => false
    }
  })
  let row_now = @signals.computed(fn(_) { now.get().map(fn(n) { n.0 }) }, same=json_opt_same)
  b.grow(Is(1.0)) |> ignore
  // (wide, a piece of its section's list card as wide_group_node's: workspace_page's, a station's screens')
  // (多选's row of it: the list's row as 多选 takes it, by its key; read only while 多选 is on)
  let batch_row = @signals.computed(fn(_) {
    if !batch.on.get() {
      return None
    }
    let k = pl_key(only, row_now.get().unwrap_or(Json::null()))
    batch_rows().iter().find_first(fn(r) { text(Some(r), "key") == k })
  }, same=json_opt_same)
  @sf.card_piece_node(b, fn() { now.get().map(fn(n) { n.1 }).unwrap_or(@sf.CardPiece::CardWhole) }, wide_group=true, fn(card) {
    card.pick(fn() { batch.on.get() }, fn(c, picking) {
      if picking {
        profiles_batch_row_node(c, batch, fn() { batch_row.get() })
      } else if only == "" {
        pl_account_row_node(c, core, fn() { row_now.get() }, tips, width?)
      } else {
        pl_station_row_node(c, core, only, fn() { row_now.get() }, tips)
      }
    })
  })
}

///|
/// The inner width available to `quota_worded_node` inside `pl_account_row_node`, derived from `page_w()` along
/// `page_node` -> `card_piece_node(..., wide_group=true)` -> `link_row_node(..., lines_from_lead=true)` so each row
/// avoids a per-row `View::by_room` second layout pass.
fn pl_account_quota_room_w(w : @view.View, page_w : () -> Double) -> () -> Double {
  let in_pane = w.lent(@sf.pane_lent).unwrap_or(false)
  let wide = @sf.look_node(w) == @sf.look_for(@sf.narrow_most)
  let card_pad = if in_pane { @sf.corner_inset } else { @sf.list_pad }
  fn() {
    let block_w = if wide {
      let lane_side = if in_pane { 0.0 } else { @sf.desk_lane_in }
      let avail = page_w() - 2.0 * lane_side
      let col_w = if avail < @sf.desk_lane_most { avail } else { @sf.desk_lane_most }
      col_w - 2.0 * @sf.desk_column_in
    } else {
      let room_side = if in_pane { @sf.panel_card_in } else { 12.0 }
      page_w() - 2.0 * room_side
    }
    let row_w = block_w - 2.0 * card_pad
    // link_row_node(lines_from_lead=true): r padding_x = text_in*2, words margin_left = corner_inset - text_in
    let avail = row_w - @sf.text_in - @sf.corner_inset
    if avail > 0.0 { avail } else { 0.0 }
  }
}

///|
/// The workspace's account in a row (profile_list_blocks' row), `ev` its entry as it is now: its vendor's mark by its
/// first line, its name (a subscription's account, a key's name) and its plan after it; under them what needs a look,
/// in its tone, or what its allowance lacks; its allowance's windows in words a line of their own. One whose station is
/// away dimmed. Pressed, its page.
fn pl_account_row_node(
  r : @view.View,
  core : Core,
  ev : () -> Json?,
  tips : @sf.TipLayer,
  width? : () -> Double,
) -> Unit {
  let p = fn() { field(ev(), "profile") }
  let usable = fn() { flag(ev(), "usable") }
  let state = fn() { field(ev(), "state") }
  let quota = fn() { field(p(), "quota") }
  let windows = fn() { usable() && text(quota(), "state") == "ok" && items(quota(), "windows").length() > 0 }
  let sub_line = fn() {
    let no_windows = !(text(quota(), "state") == "ok" && items(quota(), "windows").length() > 0)
    if text(state(), "text") != "" {
      text(state(), "text")
    } else if usable() && no_windows && text(quota(), "state") == "ok" && text(quota(), "creditsText") != "" {
      let detail = text(quota(), "detail")
      if detail != "" {
        text(quota(), "creditsText") + " · " + detail
      } else {
        text(quota(), "creditsText")
      }
    } else if usable() && no_windows && text(ev(), "group") != "key" {
      if quota() is (None | Some(Null)) {
        @sf.t("web-main.quota.unchecked")
      } else if text(quota(), "detail") != "" {
        text(quota(), "detail")
      } else if text(quota(), "state") == "unsupported" {
        @sf.t("android-settings.quota.none")
      } else if text(quota(), "state") != "ok" {
        @sf.t("web-main.quota.unknown")
      } else {
        ""
      }
    } else {
      ""
    }
  }
  // (its line's tone: what needs a look in red or amber as the core says it, else quiet; the row made again only as it
  // comes to be amber or no longer, its words what they say now)
  let tone = fn() {
    if text(state(), "text") == "" {
      0
    } else {
      match text(state(), "tone") {
        "red" => 2
        "neutral" | "" => 0
        _ => 1
      }
    }
  }
  r.box(fn(d) {
    d.alpha(By(fn() { if usable() { 1.0 } else { pl_away } })) |> ignore
    // (its menu where the pointer's other button is pressed on it: its page opened, its name copied)
    d.on_menu(fn(m) {
      let e = @signals.untracked(ev)
      let name = match text(field(e, "profile"), "name") {
        "" => text(e, "title")
        n => n
      }
      pl_menu(fn() { (core.push)(Profile(text(e, "station"), text(field(e, "profile"), "id"))) }, name, m)
    })
    |> ignore
    d.pick(fn() { tone() == 1 }, fn(x, amber) {
      @sf.link_row_node(
        x,
        fn() {
          match text(p(), "name") {
            "" => text(ev(), "title")
            n => n
          }
        },
        fn() {
          let e = @signals.untracked(ev)
          (core.push)(Profile(text(e, "station"), text(field(e, "profile"), "id")))
        },
        note=fn() { if tone() == 2 { "" } else { sub_line() } },
        trouble=fn() { if tone() == 2 { sub_line() } else { "" } },
        lacks=amber,
        note_cut=true,
        lead=LeadLine(fn(l) {
          @sfbase.provider_mark_node(l, fn() { (text(p(), "runtime"), text(field(p(), "access"), "kind"), text(p(), "providerMark")) }, pl_logo)
        }),
        title_cut=true,
        title_after=fn(a) {
          a.drops(Is(pl_drop_plan)) |> ignore
          @sf.row_tag_node(a, fn() {
            match text(p(), "planText") {
              "" => if text(field(p(), "access"), "kind") == "service" { text(p(), "kindText") } else { "" }
              s => s
            }
          })
        },
        title_after_shown=fn() {
          text(p(), "planText") != "" || (text(field(p(), "access"), "kind") == "service" && text(p(), "kindText") != "")
        },
        below=fn(q) {
          q.show(windows, fn(w) {
            let room_w = width.map(fn(page_w) { pl_account_quota_room_w(w, page_w) })
            pl_quota_node(w, quota, tips, room_w?)
          })
        },
        below_open=fn() { if windows() { 1.0 } else { 0.0 } },
        // (what is under its name from its vendor's mark: its allowance's chips the room to be each said whole, the
        // same way on every row of the card, in its row's corner concentric round their own; #6417's)
        lines_from_lead=true,
      )
    })
  })
  |> ignore
}

///|
/// Allowance chips at the row's foot, inset so their corner follows the row's.
fn pl_quota_node(
  w : @view.View,
  quota : () -> Json?,
  tips : @sf.TipLayer,
  room_w? : () -> Double,
) -> Unit {
  @sf.style_node(w, fn() { pl_quota_line })
  let (_, _, _, foot) = @sf.row_below_inset(w)
  w.margin(Is((0.0, 0.0, 0.0, foot))) |> ignore
  @sfbase.quota_worded_node(w, quota, tips~, room_w?)
}

///|
/// A station's profile in a row (profile_row's), with its state, name and tier above its check and models.
/// Scoped allowance windows go below the row's text. Pressing the row opens the profile's page.
fn pl_station_row_node(r : @view.View, core : Core, station : String, pv : () -> Json?, tips : @sf.TipLayer) -> Unit {
  let id = fn() { text(pv(), "id") }
  let on = fn() { [("station", station), ("id", id())] }
  let calls = ["profile.check", "profile.quota"]
  let quota = fn() { field(pv(), "quota") }
  let grouped = fn() {
    @sfbase.has_quota(quota()) && items(quota(), "windows").iter().any(fn(w) { text(Some(w), "scope") != "" })
  }
  let trouble = fn() { pl_trouble_of(pv()) }
  // (its menu where the pointer's other button is pressed on it: its page opened, its name copied)
  r.on_menu(fn(m) { pl_menu(fn() { (core.push)(Profile(station, @signals.untracked(id))) }, text(@signals.untracked(pv), "name"), m) })
  |> ignore
  @sf.link_row_node(
    r,
    fn() { text(pv(), "name") },
    fn() { (core.push)(Profile(station, @signals.untracked(id))) },
    // (its tier first on the line under its name, not after the name: beside the title its allowance's chips already
    // stand, and a tier there too cut a phone's name short, ChatGPT 团队 to ChatGPT…)
    note=fn() {
      join(
        [
          match text(pv(), "planText") {
            "" => if text(field(pv(), "access"), "kind") == "service" { text(pv(), "kindText") } else { "" }
            s => s
          },
          text(pv(), "checkText"),
          if flag(pv(), "machine") {
            text(pv(), "kindText")
          } else {
            match text(pv(), "usesText") {
              "" => text(pv(), "kindText")
              u => u
            }
          },
          text(pv(), "modelsText"),
        ],
        " · ",
      )
    },
    lead=LeadLine(fn(l) { @sf.state_dot_node(l, fn() { pl_tone_dot(text(pv(), "checkTone")) }) }),
    title_cut=true,
    // (why its provider refuses it, quiet as the line over it, and where that is the station's trouble, how to mend it
    // in the link's ink: profile_row's)
    below=fn(q) {
      q.show(fn() { trouble() != "" }, fn(c) {
        @sf.style_node(c, fn() { pl_trouble })
        // (the next lines of the row's words, as close under its note as its note is under its title: not below's 6)
        c.grow(Is(1.0)).min_width(Is(Some(0.0))).margin(Is((0.0, -6.0, 0.0, 0.0))) |> ignore
        @sf.words_node(c, trouble, fn() { pl_offer_note }) |> ignore
        c.show(fn() { field(pv(), "trouble") is Some(Object(_)) }, fn(f) {
          @sf.words_node(f, fn() { @sf.t("android-settings.profile.seeFix") }, fn() { pl_see_fix }) |> ignore
        })
      })
      q.show(grouped, fn(w) { pl_quota_node(w, quota, tips) })
    },
    below_open=fn() { if trouble() != "" || grouped() { 1.0 } else { 0.0 } },
    tail=fn(t) {
      t.box(fn(e) {
        @sf.style_node(e, fn() { pl_tail }, in_row=true)
        doing_mark_node(e, fn() { is_doing(core, calls, on()) }, fn() { failed_of(core, calls, on()) }, tips~)
        @sfbase.quota_chips_node(e, fn() { if grouped() { None } else { quota() } }, small=true, tips~)
      })
      |> ignore
    },
    // (its tail's room only while it holds something: what is under way, or its allowance's chips)
    tail_shown=fn() { is_doing(core, calls, on()) || failed_of(core, calls, on()) is Some(_) || (!grouped() && @sfbase.has_quota(quota())) },
  )
}

///|
/// An account's row menu at the pointer's other button's press `m`: its page opened (`open`), its `name` copied.
fn pl_menu(open : () -> Unit, name : String, m : @view.Menu) -> Unit {
  @sf.menu(
    [
      Some(@sf.menu_item_of(@sf.t("web-pages.rowMenu.open"), open, icon="arrow-up-right")),
      copy_item("web-pages.rowMenu.copyName", name),
    ].filter(fn(i) { i is Some(_) }),
    from=@sf.at_point(m.wx, m.wy),
  )
}

///|
/// Why a station's profile cannot be used, as profile_row says it: the station's trouble with it (its title and what it
/// says), else why its allowance could not be read.
fn pl_trouble_of(pv : Json?) -> String {
  match field(pv, "trouble") {
    Some(Object(_)) as t => text(t, "title") + " · " + text(t, "detail")
    _ =>
      match text(field(pv, "quota"), "state") {
        "blocked" | "unavailable" | "unsupported" => text(field(pv, "quota"), "detail")
        _ => ""
      }
  }
}

///|
/// The accounts a station machine's own Claude Code and Codex are signed in with that no profile uses yet
/// (machine_login_offers' MachineLoginOffers), `s` the station, `logins` those it has: a section titled by the station
/// they are on, a list card's row each. Its vendor's mark, what it is, its plan and what is done with it on its first
/// line (the mark and the action on that line, never across the row's lines: the user, 2026-11-14); how it is signed in,
/// what is wrong and its allowance under them, from the mark. One the station reads used as it is
/// (`profile.useMachineLogin`, its page opened over the list), one it cannot signed in again for still.fail (`go_new`),
/// a refused one only said so.
fn pl_machine_offers_node(
  b : @view.View,
  core : Core,
  station : String,
  s : () -> Json?,
  logins : () -> Json?,
  go_new : (String) -> Unit,
  tips : @sf.TipLayer,
) -> Unit {
  let offers = fn() {
    match logins() {
      Some(Array(a)) => a.filter(fn(l) { flag(Some(l), "offered") })
      _ => []
    }
  }
  b.show(fn() { offers().length() > 0 }, fn(x) {
    @sf.style_node(x, fn() { pl_offers })
    @sf.section_heading_node(x, fn() { @sf.t("web-mobile.profiles.machineLogins", args=[("station", text(s(), "name"))]) })
    @sf.group_node(x, fn(g) {
      g.each(offers, fn(l) { text(Some(l), "runtime") }, fn(row, l) {
        let lv = fn() { Some(l.get()) }
        let rt = @signals.untracked(fn() { text(lv(), "runtime") })
        let quota = fn() { field(lv(), "quota") }
        let blocked = fn() { text(quota(), "state") == "blocked" }
        let trouble = fn() {
          match text(quota(), "state") {
            "blocked" | "unavailable" | "unsupported" => text(quota(), "detail")
            _ => ""
          }
        }
        @sf.link_row_node(
          row,
          fn() { @settings.runtime_label(rt) },
          fn() {  },
          goes=false,
          lead=LeadLine(fn(m) { @sf.provider_logo_node(m, rt, "subscription", pl_logo, "") |> ignore }),
          lines_from_lead=true,
          title_cut=true,
          title_after=fn(a) {
            a.drops(Is(pl_drop_plan)) |> ignore
            @sf.row_tag_node(a, fn() { text(lv(), "planText") })
          },
          title_after_shown=fn() { text(lv(), "planText") != "" },
          // (a refused one has nothing to do with it here)
          control=fn(e) {
            e.show(fn() { !blocked() }, fn(y) {
              // (the card's first row's in its top end corner, concentric with it; another's at its row's end)
              let first = fn() { offers().get(0).map(fn(o) { text(Some(o), "runtime") }) == Some(rt) }
              y.pick(fn() { (flag(lv(), "usable"), first()) }, fn(z, k) {
                let (usable, first) = k
                let end = fn(label : () -> String, press : () -> Unit, busy : () -> Bool) {
                  if first {
                    @sf.row_corner_button_node(z, label, press, busy~)
                  } else {
                    @sf.row_end_button_node(z, label, press, busy~)
                  }
                }
                let button = if usable {
                  end(
                    fn() { @sf.t("android-settings.machine.use") },
                    fn() {
                      (core.call)("profile.useMachineLogin", obj([("station", str(station)), ("runtime", str(rt))]), fn(r) {
                        match r {
                          Ok(v) => {
                            (core.say)(@sf.t("android-settings.machine.added"))
                            (core.push)(Profile(station, text(Some(v), "id")))
                          }
                          Err(e) => (core.say)(@settings.error_text(e))
                        }
                      })
                    },
                    fn() { is_doing(core, ["profile.useMachineLogin"], [("station", station), ("runtime", rt)]) },
                  )
                } else {
                  end(fn() { @sf.t("android-settings.login.signIn") }, fn() { go_new(rt) }, fn() { false })
                }
                @sf.tip_node(tips, button, fn() {
                  if usable {
                    @sf.t("web-pages.profiles.useMachineTip")
                  } else {
                    @sf.t("web-pages.profiles.keychainTip", args=[("name", @sf.product())])
                  }
                })
                |> ignore
              })
            })
          },
          below=fn(q) {
            q.box(fn(c) {
              @sf.style_node(c, fn() { pl_offer_under })
              c.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              // (how it is signed in: a dot in its tone, then whose)
              c.box(fn(line) {
                @sf.style_node(line, fn() { pl_offer_signed })
                @sf.state_dot_node(line, fn() { if blocked() { "error" } else { "online" } }, size=pl_offer_dot)
                @sf.words_node(line, fn() {
                  let how = @sf.t(if blocked() { "android-settings.quota.blocked" } else { "android-settings.machine.signedIn" })
                  how +
                  " · " +
                  (match text(lv(), "email") {
                    "" => @sf.t("android-settings.machine.someone")
                    e => e
                  })
                }, fn() { if blocked() { pl_offer_bad_line } else { pl_offer_line } })
                |> ignore
              })
              |> ignore
              c.show(fn() { trouble() != "" }, fn(y) {
                @sf.words_node(y, trouble, fn() { if blocked() { pl_offer_bad_note } else { pl_offer_note } }) |> ignore
              })
              @sfbase.quota_chips_node(c, quota, tips~)
            })
            |> ignore
          },
          below_open=fn() { 1.0 },
        )
      })
    })
  })
}

///|
/// A check's tone as a dot's state.
fn pl_tone_dot(tone : String) -> String {
  match tone {
    "green" => "online"
    "red" => "error"
    "neutral" => "offline"
    _ => "busy"
  }
}

///|
/// The workspace's profiles made up, for what is shown while they are read (in their bones): three of one kind.
// kept across runs: a value (no field of it changes)
let profiles_sample : Array[Json] = [(8, 14), (6, 18), (9, 12)].mapi(fn(i, n) {
  Json::object({
    "key": Json::string("sample" + i.to_string()),
    "usable": true,
    "group": "",
    "groupTitle": Json::string(@sf.sample_words(4)),
    "where": Json::string(@sf.sample_words(n.1)),
    "profile": {
      "id": Json::string("sample" + i.to_string()),
      "name": Json::string(@sf.sample_words(n.0)),
      "group": "",
      "kindText": Json::string(@sf.sample_words(n.1)),
    },
  })
})

///|
/// An account on several stations (ProfileAccountScreen) in node `v`, by its key in the workspace's profiles, laid out by
/// the `width` its frame gives it, in the frame it is given: its name, under it its account, kind and plan; how it is
/// (its check), its allowance (profile_quota_node, its page's), then each station it is signed in on, a row each leading
/// to its page there. While it is read, a made-up one's in its bones; gone from the workspace, said so.
pub fn profile_account_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  key : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let tips = match tips {
    Some(t) => t
    None => @sf.TipLayer::new(fn() { Some(v) })
  }
  // (that account alone, whole: its own topic, by its key; null where the workspace has it no more)
  let topic = fn() { @settings.profile_by_key_read(core, here(), key) }
  let entry_now = @signals.computed(fn(_) {
    match topic().value {
      Some(Object(_)) as x => x
      _ => None
    }
  }, same=json_opt_same)
  let ev = fn() { entry_now.get() }
  let p = fn() { field(ev(), "profile") }
  let members_now = @signals.computed(fn(_) { items(ev(), "members").filter(fn(m) { text(Some(m), "role") != "user" }) }, same=jsons_same)
  @sf.page_node(
    v,
    fn() {
      match text(p(), "name") {
        "" => "Profile"
        n => n
      }
    },
    fn() {
      match ev() {
        None => if topic().value is Some(_) { ["none"] } else { ["waiting"] }
        // (each station it is on a block of its own, a piece of their card: only those that show made)
        Some(_) => ["check", "quota", "each"] + members_now.get().map(fn(m) { "m/" + pa_member_key(m) })
      }
    },
    fn(b, k) {
      match k {
        "none" => @sf.page_note_node(b, fn() { @sf.t("android-settings.profile.none") })
        "waiting" =>
          @sf.waiting_node(
            b,
            fn(s) {
              @sf.group_node(s, fn(g) {
                g.each(fn() { account_members_sample }, fn(m) { text(Some(m), "station") }, fn(r, m) {
                  pa_member_row_node(r, core.quiet(), fn() { Some(m.get()) })
                })
              })
            },
            error=fn() {
              match topic().error {
                Some(x) => error_text(x)
                None => ""
              }
            },
          )
        "check" =>
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(
              g,
              fn() { text(p(), "checkText") },
              fn() {  },
              goes=false,
              // (what its check says; when its allowance was read is said under the allowance: account_blocks')
              note=fn() {
                match opt_text(field(p(), "check"), "detail") {
                  Some(x) => x
                  None => @sf.t("android-settings.profile.notChecked")
                }
              },
              lead=LeadLine(fn(l) { @sf.state_dot_node(l, fn() { pl_tone_dot(text(p(), "checkTone")) }) }),
            )
          })
        // (by the station and the profile it is asked of as they are now: an account on several stations may come to be
        // read of another, the block kept)
        "quota" =>
          b.pick(fn() { (text(ev(), "station"), text(p(), "id")) }, fn(q, at) {
            profile_quota_node(q, core, at.0, at.1, fn() { None }, p, Some(tips), read_under=true)
          })
        "each" => @sf.section_heading_node(b, fn() { @sf.t("web-pages.profiles.account.each") })
        k if k.has_prefix("m/") => {
          let key = k.exact_view(start=2).to_owned()
          // (as it is now, as it was last while it goes; its piece of the card by where it is among them)
          let last : Ref[(Json, @sf.CardPiece)?] = Ref(None)
          let now = fn() {
            let all = members_now.get()
            for i, m in all {
              if pa_member_key(m) == key {
                last.val = Some((m, @sf.card_piece_of(i, all.length())))
              }
            }
            last.val
          }
          let mv = @signals.computed(fn(_) { now().map(fn(n) { n.0 }) }, same=json_opt_same)
          guard @signals.untracked(fn() { mv.get() }) is Some(_) else { return }
          @sf.card_piece_node(b, fn() { now().map(fn(n) { n.1 }).unwrap_or(@sf.CardPiece::CardWhole) }, wide_group=true, fn(card) {
            pa_member_row_node(card, core, fn() { mv.get() })
          })
        }
        _ => ()
      }
    },
    on_back~,
    frame~,
    lead=fn() { join([text(p(), "email"), text(p(), "kindText"), text(p(), "planText")], " · ") },
    said?,
    width?,
    tips~,
  )
}

///|
/// A station an account is signed in on, by its key among them: the station and its profile there.
fn pa_member_key(m : Json) -> String {
  text(Some(m), "station") + "/" + text(Some(m), "profileId")
}

///|
/// A station an account is signed in on (account_blocks' row), `mv` as it is now: how it is there by its first line, the
/// station's name; under it what it is there, or that the station is away. Pressed, its page there.
fn pa_member_row_node(r : @view.View, core : Core, mv : () -> Json?) -> Unit {
  @sf.link_row_node(
    r,
    fn() { text(mv(), "title") },
    fn() {
      let m = @signals.untracked(mv)
      (core.push)(Profile(text(m, "station"), text(m, "profileId")))
    },
    note=fn() { if flag(mv(), "online") { text(mv(), "about") } else { @sf.t("android-settings.profiles.stationOffline") } },
    lead=LeadLine(fn(l) {
      @sf.state_dot_node(l, fn() {
        if !flag(mv(), "online") {
          "offline"
        } else if !flag(mv(), "usable") {
          "error"
        } else {
          pl_tone_dot(text(mv(), "checkTone"))
        }
      })
    }),
    title_cut=true,
  )
}

///|
/// The stations an account is on made up, for what its page shows while it is read (in their bones).
// kept across runs: a value (no field of it changes)
let account_members_sample : Array[Json] = [6, 9].mapi(fn(i, n) {
  Json::object({
    "station": Json::string("sample/" + i.to_string()),
    "profileId": "sample",
    "title": Json::string(@sf.sample_words(n)),
    "about": Json::string(@sf.sample_words(n + 6)),
    "online": true,
    "usable": true,
    "checkTone": "green",
  })
})

// ── styles ─────────────────────────────────────────

///|
/// A dimmed account's (its station away) opacity.
let pl_away : Double = 0.55

///|
/// An account's vendor's mark by its name.
let pl_logo : Double = 18.0

///|
/// Its plan after its name leaves its line before the name is cut short under four of its size.
let pl_drop_plan : Int = 1

///|
/// Its allowance's windows, a line of their own 6 under its words.
// kept across runs: a value (no field of it changes)
let pl_quota_line : @ui.Style = @ui.css("w=Full pt=S1_5")

///|
/// What is under way with a station's profile and its unscoped allowance at its row's end, 8 apart.
// kept across runs: a value (no field of it changes)
let pl_tail : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
/// The machine's own logins' section: its title and card.
// kept across runs: a value (no field of it changes)
let pl_offers : @ui.Style = @ui.css("w=Full")

///|
/// What is under a machine's login's first line: how it is signed in, what is wrong, its allowance, 2 apart.
// kept across runs: a value (no field of it changes)
let pl_offer_under : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
/// How a machine's login is signed in: its dot and its words, 5 apart across their middle.
// kept across runs: a value (no field of it changes)
let pl_offer_signed : @ui.Style = @ui.css("row w=Full gap=S1_25 align=ACenter")

///|
/// How a machine's login is signed in, its dot across.
let pl_offer_dot : Double = 6.0

///|
// kept across runs: a value (no field of it changes)
let pl_offer_line : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let pl_offer_bad_line : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Danger, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let pl_offer_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let pl_offer_bad_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Danger, w=Full)

///|
/// Why a station's profile cannot be used, and how to mend it: 2 apart.
// kept across runs: a value (no field of it changes)
let pl_trouble : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
/// How to mend it, in the link's ink.
// kept across runs: a value (no field of it changes)
let pl_see_fix : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=AccentText, wrap=false)

///|
/// A wait said on a card: its words a row's room in.
// kept across runs: a value (no field of it changes)
let pl_wait_room : @ui.Style = @ui.css("w=Full px=S4 py=S3")

///|
/// The workspace's Profile page in node `v`: its accounts' list or 概览 (`overview`, which of the two: the bottom bar's
/// place keeps its own, a pushed page and 中屏's and 大屏's theirs), one page whichever it shows, so switching between
/// them keeps the page, its frame's top bar and what it reads: the accounts and the stations held by the page itself
/// (`src.owned_by`, let go with it), so neither is let go as one is made in the other's place; 概览 switched to once
/// its pools are answered too (`@settings.overview_switch`), the list shown meanwhile.
pub fn profiles_page_node(
  v : @view.View,
  src : Source,
  core : Core,
  here : () -> Here,
  overview : @signals.Signal[Bool],
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
  bar_actions? : ((@view.View) -> Unit, (@sf.Look) -> Double) -> Unit,
  bar_add? : Bool = true,
) -> Unit {
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  let held = src.owned_by(v)
  let ws = @signals.untracked(here).workspace
  let scope = { "scope": Json::string(ws) }
  held.prefetch("profiles", scope) |> ignore
  held.prefetch("stations", scope) |> ignore
  let tab_pending : @signals.Signal[Int?] = @signals.signal(None)
  let tab_chosen = fn() { tab_pending.get().unwrap_or(if overview.get() { 1 } else { 0 }) }
  let switch_seq : Ref[Int] = Ref(0)
  let pending_cancel : Ref[(() -> Unit)?] = Ref(None)
  let cancel_switch = fn() {
    switch_seq.val += 1
    match pending_cancel.val {
      Some(cancel) => {
        pending_cancel.val = None
        cancel()
      }
      None => ()
    }
    tab_pending.set(None)
  }
  v.on_leaving(cancel_switch) |> ignore
  let tabs_thumb = @sf.SegThumb::new(v, tab_chosen)
  // (the list's 多选, its bar's to begin: over as 概览 is shown)
  let batch = ProfilesBatch::new()
  v.reacts(fn() { overview.get() }, fn(shown) { if shown { batch.stop() } }, at_start=false)
  // (hoisted to the page container so kept panes update the top bar reactively when waking without re-calling bar_actions;
  // overview.get() short-circuits profilesOverview while on 账号)
  match bar_actions {
    Some(f) => {
      let has_pools = @signals.computed(fn(_) {
        overview.get() &&
        !items((core.topic)("profilesOverview", { "scope": Json::string(here().workspace) }).get().value, "pools").is_empty()
      })
      let add = fn() { @settings.place_action(core, here(), "profiles") is Some(_) }
      let adding = fn(at : @view.View) {
        match @settings.place_action(core, @signals.untracked(here), "profiles") {
          Some(run) => run(Node(at))
          None => ()
        }
      }
      let label = fn() { @sf.t("android-misc.bar.action.profiles") }
      // (多选 of the list's: on 概览 too, so the bar keeps its parts as the tabs switch, pressed there it shows the list
      // with 多选 begun)
      let select_shown = fn() {
        let listed = fn() { (core.topic)("profiles", { "scope": Json::string(here().workspace) }).get().value }
        profiles_batch_offered(fn() { flag(listed(), "manages") }, fn() { items(listed(), "items") })
      }
      let select = fn() {
        cancel_switch()
        if @signals.untracked(fn() { overview.get() }) {
          overview.set(false)
          batch.start()
        } else {
          batch.toggle()
        }
      }
      f(
        fn(l) {
          profile_share_node(l, core, here, fn() { true }, tips, bar=true, has_pools=fn() { has_pools.get() })
          l.show(select_shown, fn(a) {
            @sf.bar_icon_node(a, "check-circle", fn() { @sf.t("web-pages.profiles.batch.select") }, select, tips?)
          })
          if bar_add {
            l.show(add, fn(a) { @sf.page_add_node(a, label, adding) })
          }
        },
        fn(_) { @sf.button_height() },
      )
    }
    None => ()
  }
  let show_overview = fn() {
    if @signals.untracked(fn() { overview.get() }) {
      cancel_switch()
      return
    }
    cancel_switch()
    let seq = switch_seq.val
    tab_pending.set(Some(1))
    let cancel = (@settings.overview_switch.val)(
      ws,
      fn() {
        if switch_seq.val == seq {
          pending_cancel.val = None
          tab_pending.set(None)
          overview.set(true)
          @ui.after_drawn_frame(fn() { @sfbase.shown_read("profiles-list\u{1}" + ws) })
        }
      },
      fn() {
        if switch_seq.val == seq {
          pending_cancel.val = None
          tab_pending.set(None)
        }
      },
    )
    if switch_seq.val == seq && @signals.untracked(fn() { tab_pending.get() }) is Some(_) {
      pending_cancel.val = Some(cancel)
    }
  }
  v.each(fn() { [overview.get()] }, fn(x) { x }, keeps=fn() { [true, false] }, at_once=true, fn(p, shown_sig) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    if @signals.untracked(fn() { shown_sig.get() }) {
      profiles_overview_node(
        p,
        core,
        here,
        on_back~,
        frame~,
        said?,
        width?,
        tips?,
        bar_add~,
        tab_chosen~,
        tabs_thumb~,
        on_show_accounts=fn() {
          cancel_switch()
          overview.set(false)
        },
      )
      // (what the switch asked ahead, its pools, read anew by the overview just made: overview_switch)
      @sfbase.shown_read("profiles-list\u{1}" + ws)
    } else {
      // (概览 once what it shows is answered, the list meanwhile: overview_switch; release the ahead read after the
      // overview frame draws so both initial build and subsequent wake-ups hand over cleanly without leaking)
      profiles_list_node(
        p,
        core,
        here,
        "",
        on_back~,
        frame~,
        said?,
        width?,
        tips?,
        bar_add~,
        tab_chosen~,
        tabs_thumb~,
        batch~,
        on_show_overview=show_overview,
        on_show_accounts=cancel_switch,
      )
    }
  })
}
