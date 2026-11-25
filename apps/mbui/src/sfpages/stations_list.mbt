// The workspace's stations (settings/Stations.kt StationsScreen) made once as nodes of the window's tree in every frame,
// laid out by its width (page_node): compact grouped cards (stations in stable order—this machine first, then join
// order—task-only rigs under their heading, and devices under their heading), each row a press away from its page; none
// yet, the first to add. Its owners and admins add one (its ＋ at its title's end, or the frame's: a place's notch, the
// tape's bar).

///|
/// The stations' list (StationsScreen) in node `v`, laid out by the `width` its frame gives it (narrow where none is
/// given), in the frame it is given: its blocks as the core's stations, the workspace's rigs and its devices say them
/// now, each row a piece of its group's card by what it is of (a station by its address, one that only runs tasks by
/// its id, a device by its station and id) so one joining or leaving comes and goes where it is. Adding one (an
/// owner's and an admin's, a member's that only runs tasks) at its title's end, where the frame does not hold it itself
/// (a place's notch names the page: `frame().named`), or in a frame's bar (`bar_actions`). `here`: who and where, as
/// that changes. `shown`: whether the page shows now (a stack keeps a page made once while another is over it): how
/// each station is reached is sampled of it, so read only while it does, let go of as it is covered, as the old page's
/// was.
pub fn stations_list_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
  bar_actions? : ((@view.View) -> Unit, (@sf.Look) -> Double) -> Unit,
  shown? : () -> Bool = fn() { true },
) -> Unit {
  let topic = fn() { @settings.stations_of(core, here()) }
  // (each list worked out once for each change of what it reads, read by the blocks and by each row)
  // (this machine's station first, the rest as the workspace lists them, as they joined it: the user, 2026-11-16)
  let stations_now : @signals.Computed[Array[Json]?] = @signals.computed(fn(_) {
    match topic().value {
      Some(Array(a)) => {
        let here = a.filter(fn(st) { @settings.is_this_machine(Some(st)) })
        Some(if here.length() == 0 { a } else { here + a.filter(fn(st) { !@settings.is_this_machine(Some(st)) }) })
      }
      _ => None
    }
  })
  let stations = fn() { stations_now.get() }
  // (station addresses in stable order—this machine first, then workspace join order—compared by value so online/offline
  // flapping and metric/name updates update in place without jumping rows or re-running other rows' card-piece bindings)
  let addresses_now : @signals.Computed[Array[String]] = @signals.computed(
    fn(_) {
      match stations() {
        Some(a) => a.map(fn(st) { text(Some(st), "station") })
        None => []
      }
    },
    same=fn(a, b) { a == b },
  )
  // (the stations' addresses as last shown: a station joining or leaving a list already shown moves its way within the
  // page; the first answer, the last one gone or the first one come settle at once)
  let shown_addresses = @signals.signal(
    @signals.untracked(fn() { addresses_now.get() }),
    same=fn(a, b) { a == b },
  )
  v.reacts(
    fn() { addresses_now.get() },
    fn(next) {
      if !@view.answering_now() {
        @view.transition(within=v, fn() { shown_addresses.set(next) })
      } else {
        shown_addresses.set(next)
      }
    },
    at_start=false,
  )
  let station_keys = @signals.computed(
    fn(_) {
      let shown = shown_addresses.get()
      if shown.is_empty() {
        addresses_now.get()
      } else {
        shown
      }
    },
    same=fn(a, b) { a == b },
  )
  // (the list kept by address once, so a station's row is told only as its own station changes: View::keyed_by)
  let stations_by = v.keyed_by(fn() { stations().unwrap_or([]) }, fn(st) { text(Some(st), "station") })
  let rigs_now = @signals.computed(fn(_) { if stations() is Some(_) { @settings.rigs_listed(core, here()) } else { [] } }, same=jsons_same)
  let devices_now = @signals.computed(fn(_) { if stations() is Some(_) { @settings.devices_listed(core, here()) } else { [] } }, same=jsons_same)
  let rig_ids_now = @signals.computed(fn(_) { rigs_now.get().map(fn(x) { text(Some(x), "id") }) }, same=fn(a, b) { a == b })
  let device_keys_now = @signals.computed(
    fn(_) { devices_now.get().map(fn(x) { "device/" + text(Some(x), "station") + "/" + text(Some(x), "id") }) },
    same=fn(a, b) { a == b },
  )
  // (the rigs and the devices kept by their keys once, so a row is told only as its own one changes: View::keyed_by)
  let rigs_by = v.keyed_by(fn() { rigs_now.get() }, fn(x) { text(Some(x), "id") })
  let devices_by = v.keyed_by(fn() { devices_now.get() }, fn(x) { "device/" + text(Some(x), "station") + "/" + text(Some(x), "id") })
  let add = fn() { @settings.place_action(core, here(), "stations") is Some(_) }
  let adding = fn(at : @view.View) {
    match @settings.place_action(core, @signals.untracked(here), "stations") {
      Some(run) => run(Node(at))
      None => ()
    }
  }
  let label = fn() { @sf.t("android-misc.bar.action.stations") }
  let actions = fn(l : @view.View) {
    l.show(fn() { add() && !frame().named }, fn(a) { @sf.page_add_node(a, label, adding) })
  }
  match bar_actions {
    Some(f) => f(fn(l) { l.show(add, fn(a) { @sf.page_add_node(a, label, adding) }) }, fn(_) { @sf.button_height() })
    None => ()
  }
  @sf.page_node(
    v,
    fn() { @sf.t("android-misc.bar.place.stations") },
    fn() {
      match stations() {
        None => ["waiting"]
        Some(a) => {
          // (a block each station, by its address, so the page's list makes only the rows in sight and near it
          // (View::scrolls_window), not all of them as it opens)
          let out : Array[String] = if a.length() == 0 {
            ["first"]
          } else {
            station_keys.get().map(fn(addr) { "station/" + addr })
          }
          let rigs = rig_ids_now.get()
          if !rigs.is_empty() {
            out.push("rigs")
          }
          for id in rigs {
            out.push("rig/" + id)
          }
          let devices = device_keys_now.get()
          if !devices.is_empty() {
            out.push("devices")
          }
          for k in devices {
            out.push(k)
          }
          out
        }
      }
    },
    fn(b, key) {
      match key {
        "waiting" =>
          @sf.waiting_node(
            b,
            fn(s) {
              let n = stations_sample.length()
              s.each(fn() { Array::makei(n, fn(i) { i }) }, fn(i) { i }, fn(row, i) {
                let idx = i.untracked()
                let st = stations_sample[idx]
                sl_station_row_node(
                  row,
                  core.quiet(),
                  fn() { Some(st) },
                  fn() { @sf.card_piece_of(idx, n) },
                  fn() {  },
                  fn() { false },
                  sample=true,
                )
              })
            },
            error=fn() {
              match topic().error {
                Some(e) => error_text(e)
                None => ""
              }
            },
          )
        "first" => sl_first_node(b, core, here, add, adding)
        "rigs" => @sf.section_heading_node(b, fn() { @sf.t("web-pages.rigs.mode.tasks") })
        "devices" => @sf.section_heading_node(b, fn() { @sf.t("web-pages.devices.title") })
        k if k.has_prefix("station/") => {
          let address = k.exact_view(start=8).to_owned()
          let group_keys = fn() { station_keys.get() }
          // (its own station of the list, read by its address: told only as that one changes; while the block leaves
          // after its address leaves the list, keep the last known station and piece so the leaving row does not
          // blank, flip height or snap its corners mid-transition)
          let in_group = @signals.computed(fn(_) { group_keys().contains(address) })
          let last_station : Ref[Json?] = Ref(None)
          let station = fn() {
            if !in_group.get() && last_station.val is Some(_) {
              return last_station.val
            }
            match stations_by.get(address) {
              Some(v) => {
                last_station.val = Some(v)
                Some(v)
              }
              None => last_station.val
            }
          }
          let piece = sl_piece_of(group_keys, address)
          sl_station_row_node(b, core, station, piece, fn() { (core.push)(Station(address)) }, shown, menu_address=address)
        }
        k if k.has_prefix("rig/") => {
          let id = k.exact_view(start=4).to_owned()
          let in_group = @signals.computed(fn(_) { rig_ids_now.get().contains(id) })
          let last_rig : Ref[Json?] = Ref(None)
          let r = fn() {
            if !in_group.get() && last_rig.val is Some(_) {
              return last_rig.val
            }
            match rigs_by.get(id) {
              Some(v) => {
                last_rig.val = Some(v)
                Some(v)
              }
              None => last_rig.val
            }
          }
          let piece = sl_piece_of(fn() { rig_ids_now.get() }, id)
          sl_rig_row_node(b, r, piece, fn() { (core.push)(Station(here().workspace + "/" + id)) })
        }
        k if k.has_prefix("device/") => {
          let in_group = @signals.computed(fn(_) { device_keys_now.get().contains(k) })
          let last_dev : Ref[Json?] = Ref(None)
          let d = fn() {
            if !in_group.get() && last_dev.val is Some(_) {
              return last_dev.val
            }
            match devices_by.get(k) {
              Some(v) => {
                last_dev.val = Some(v)
                Some(v)
              }
              None => last_dev.val
            }
          }
          let piece = sl_piece_of(fn() { device_keys_now.get() }, k)
          sl_device_row_node(b, d, piece, fn() {
            let dv = @signals.untracked(fn() { d() })
            @settings.open_device(core, @signals.untracked(here), text(dv, "station"), text(dv, "id"), Unanchored)
          })
        }
        _ => ()
      }
    },
    on_back~,
    frame~,
    actions~,
    said?,
    width?,
    tips?,
  )
}

///|
/// The `CardPiece` of `target` in `keys()`, keeping its last known piece while a leaving block exits.
fn sl_piece_of(keys : () -> Array[String], target : String) -> () -> @sf.CardPiece {
  let last : Ref[@sf.CardPiece] = Ref(@sf.CardPiece::CardWhole)
  let c = @signals.computed(fn(_) {
    let arr = keys()
    match arr.search_by(fn(x) { x == target }) {
      Some(idx) => {
        let p = @sf.card_piece_of(idx, arr.length())
        last.val = p
        p
      }
      None => last.val
    }
  })
  fn() { c.get() }
}

///|
/// The stations to come while they are read: three made up, as the list shows them, in their bones.
// kept across runs: a value (no field of it changes)
let stations_sample : Array[Json] = [5, 3, 7].mapi(fn(i, n) {
  Json::object({
    "station": Json::string("sample/" + i.to_string()),
    "name": Json::string(@sf.sample_words(n)),
    "online": true,
    "summary": Json::string(@sf.sample_words(10)),
  })
})

///|
/// None in the workspace (StationsFirst): its scene, what a station is for, then its first added here step by step by
/// those who manage the workspace (the settings' first_station_steps_node), 添加 station for a member who may add one
/// that only runs tasks (`add`, `adding` given the button pressed: the settings' place_action), else that the others
/// wait for one who may; while the workspace is read, a line saying so.
fn sl_first_node(b : @view.View, core : Core, here : () -> Here, add : () -> Bool, adding : (@view.View) -> Unit) -> Unit {
  let ws = fn() { @settings.workspace_view(core, here()) }
  @sf.first_one_node(
    b,
    fn() { @sf.t("android-settings.station.first") },
    lead=fn() { @sf.t("android-settings.station.firstNote") },
    art=fn(a) {
      a.pick(fn() { @sf.theme().dark }, fn(x, dark) {
        @sf.drawable_node(x, if dark { "illus_no_station_dark" } else { "illus_no_station" }, sl_first_art_w) |> ignore
      })
    },
    fn(a0) {
      // (30 in from the screen's sides, as the page's first_station was: its steps' words and field off its edges)
      a0.box(fn(a) {
        @sf.style_node(a, fn() { sl_first_in })
        // (its managers add it here, step by step; a member one that only runs tasks, in 添加 station's panel; else they
        // wait for those who may, said on a warm ground)
        a.pick(fn() { if ws().value is None { None } else { Some((@settings.manages(core, here()) == Some(true), add())) } }, fn(e, can) {
          match can {
            Some((true, _)) => @settings.first_station_steps_node(e, core, @signals.untracked(here))
            Some((false, true)) =>
              @sf.button_opens_node(e, fn() { @sf.t("web-pages.settings.stations.add") }, adding, tone=Primary, icon="plus") |> ignore
            Some((false, false)) =>
              e.box(fn(w) {
                @sf.style_node(w, fn() { sl_wait_box })
                w.ground(By(fn() { @sf.alpha(sl_warn, 0.12) })) |> ignore
                @sf.words_node(w, fn() { @sf.t("android-settings.station.wait") }, fn() { sl_wait_words }) |> ignore
              })
              |> ignore
            None =>
              @sf.wait_line_node(e, fn() {
                match ws().error {
                  Some(x) => error_text(x)
                  None => @sf.t("android-settings.workspace.reading")
                }
              })
              |> ignore
          }
        })
      })
      |> ignore
    },
  )
}

///|
/// A row menu's item that copies `words` (its name, its address), said copied in the toast; none where there is nothing
/// to copy, so the menu never shows an item that does nothing.
fn copy_item(label : String, words : String) -> @sf.MenuItem? {
  guard words != "" else { return None }
  Some(
    @sf.menu_item_of(
      @sf.t(label),
      fn() { @sfbase.copy_out(words, said=@sf.t("web-pages.rowMenu.copied", args=[("name", words)])) },
      icon="copy",
    ),
  )
}

///|
/// Hairline separator above non-first rows inside a grouped card, aligned with row content edges.
fn sl_card_sep_node(card : @view.View, piece : () -> @sf.CardPiece) -> Unit {
  card.show(at_once=true, fn() { piece() is (CardBetween | CardFoot) }, fn(sep) {
    @sf.style_node(sep, fn() { sl_sep_line })
    sep.height(Is(Some(@sf.rule_w))).ground(By(fn() { @ui.tree_theme().color(@sf.rule_ink) })) |> ignore
  })
}

///|
/// A compact station row inside its group's card (`card_piece_node`):
/// - Line 1: 18pt mark + single-line station name + optional 本机 pill + right-aligned live state (green dot +
///   running count, reconnecting spinner, or grey offline ring), flush right with no trailing chevron.
/// - Line 2 (constant height online & offline so flapping never shifts rows below): compact idle/remaining CPU/RAM/Disk
///   figures on the left (warning items highlighted and kept first under tight widths) and network path + latency flush
///   right; offline rows show their summary full-width on line 2.
/// - Optional extra lines: cross-workspace origin (`joined`), offline block reason (`blocked`), and `加入安全模式`
///   action row (`protect`).
fn sl_station_row_node(
  b : @view.View,
  core : Core,
  s : () -> Json?,
  piece : () -> @sf.CardPiece,
  press : () -> Unit,
  shown : () -> Bool,
  menu_address? : String = "",
  sample? : Bool = false,
) -> Unit {
  let online = fn() { flag(s(), "online") }
  let unreadable = fn() { items(s(), "problems").iter().any(fn(p) { text(Some(p), "key") == "incompatible" }) }
  let busy = @signals.computed(fn(_) { @settings.cpu_busy(core) })
  let host = fn() {
    match field(s(), "host") {
      Some(Object(_)) as h if online() => h
      _ => None
    }
  }
  let meters = @signals.computed(fn(_) { @settings.meters_said(items(host(), "meters"), busy.get()) })
  let has_meters = fn() { !meters.get().is_empty() }
  let net = fn() {
    if sample || !online() || !shown() {
      return None
    }
    match (core.topic)("stationNet", { "station": str(text(s(), "station")) }).get().value {
      Some(Object(_)) as n => n
      _ => None
    }
  }
  b.grow(Is(1.0)) |> ignore
  @sf.card_piece_node(b, piece, wide_group=true, fn(card) {
    sl_card_sep_node(card, piece)
    card.box(fn(row) {
      row.transitions_only() |> ignore
      @sf.style_node(row, fn() { sl_row_multi })
      row.radius(Is(@sf.row_corner)) |> ignore
      if !sample {
        @sf.hover_ground_node(row)
        @sf.rippled_node(row, press, @sf.row_corner, fn() { text(s(), "name") })
      }
      if menu_address != "" {
        row.on_menu(fn(m) {
          let name = text(@signals.untracked(s), "name")
          @sf.menu(
            [
              Some(@sf.menu_item_of(@sf.t("web-pages.rowMenu.open"), press, icon="arrow-up-right")),
              copy_item("web-pages.rowMenu.copyName", name),
              copy_item("web-pages.rowMenu.copyAddress", menu_address),
            ].filter(fn(i) { i is Some(_) }),
            from=@sf.at_point(m.wx, m.wy),
          )
        })
        |> ignore
      }
      // Line 1: mark, name, optional 本机 tag, and right-aligned status
      row.box(fn(head) {
        @sf.style_node(head, fn() { sl_head })
        head.box(fn(m) {
          @sf.style_node(m, fn() { sl_mark_box }, in_row=true)
          let ink = fn() { if online() { @sf.theme().p.text } else { @sf.theme().p.muted } }
          m.pick(fn() { @sf.has_station_mark(text(s(), "emoji"), text(s(), "icon")) }, fn(x, marked) {
            if marked {
              @sf.station_mark_node(x, fn() { text(s(), "emoji") }, fn() { text(s(), "icon") }, sl_mark_side, ink, fn() { 0 })
            } else {
              @sf.icon_node(x, "server", sl_mark_side, By(ink)) |> ignore
            }
          })
        })
        |> ignore
        head.box(fn(n) {
          @sf.style_node(n, fn() { sl_name_row })
          n.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(n, fn() { text(s(), "name") }, fn() {
            if online() { sl_name } else { sl_name_off }
          })
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          |> ignore
          n.show(fn() { @settings.is_this_machine(s()) }, fn(x) {
            @sf.pill_node(x, fn() { @sf.t("web-pages.stations.thisMachine") }) |> ignore
          })
        })
        |> ignore
        if !sample {
          head.pick(
            fn() {
              if !online() {
                0
              } else if flag(s(), "reconnecting") {
                1
              } else {
                2
              }
            },
            at_once=true,
            fn(x, kind) {
              match kind {
                0 => @sf.state_dot_node(x, fn() { "offline" }, size=station_dot_side)
                1 => {
                  @sf.style_node(x, fn() { sl_reconnecting })
                  @sf.spinner_node(x, size=12.0) |> ignore
                  @sf.words_node(x, fn() { @sf.t("common.reconnecting") }, fn() { sl_reconnecting_words }) |> ignore
                }
                _ => station_state_node(x, s)
              }
            },
          )
        }
      })
      |> ignore
      // Line 2 (constant height online & offline so online/offline flapping never shifts rows below):
      // offline shows its full summary; online shows incompatible warning, compact meters + network, or fallback summary.
      row.pick(
        fn() {
          if !online() {
            5
          } else if sample {
            0
          } else if unreadable() {
            1
          } else if has_meters() {
            2
          } else if text(s(), "summary") != "" {
            3
          } else {
            4
          }
        },
        at_once=true,
        fn(sub, mode) {
          match mode {
            0 => @sf.styled_words(sub, fn() { text(s(), "summary") }, fn() { sl_meta_muted_cut }) |> ignore
            1 => @sf.styled_words(sub, fn() { text(s(), "summary") }, fn() { sl_meta_amber_cut }) |> ignore
            2 => {
              sub.alpha(By(fn() { if flag(s(), "reconnecting") { 0.45 } else { 1.0 } })) |> ignore
              sl_metrics_net_line_node(sub, fn() { meters.get() }, net)
            }
            3 => {
              sub.alpha(By(fn() { if flag(s(), "reconnecting") { 0.45 } else { 1.0 } })) |> ignore
              @sf.style_node(sub, fn() { sl_sub_row })
              @sf.words_node(sub, fn() { text(s(), "summary") }, fn() { sl_meta_muted_cut })
              .grow(Is(1.0))
              .shrink(Is(1.0))
              .min_width(Is(Some(0.0)))
              |> ignore
              sl_net_tail_node(sub, net)
            }
            4 =>
              @sf.waiting_node(sub, fn(w) {
                @sf.styled_words(w, fn() { @sf.sample_words(8) }, fn() { sl_meta_muted_cut }) |> ignore
              })
            _ =>
              @sf.styled_words(
                sub,
                fn() {
                  let sum = text(s(), "summary")
                  if sum != "" {
                    sum
                  } else {
                    let blk = text(s(), "blocked")
                    if blk != "" { blk } else { @sf.t("web-pages.stations.offline") }
                  }
                },
                fn() { sl_meta_muted_cut },
              )
              |> ignore
          }
        },
      )
      // Cross-workspace origin (joined station)
      row.show(fn() { sl_joined(s()) != "" }, at_once=true, fn(j) {
        @sf.styled_words(j, fn() { sl_joined(s()) }, fn() { sl_meta_muted_cut }) |> ignore
      })
      // Offline block reason (e.g. safe mode) when distinct from line 2 summary
      row.show(
        fn() {
          if online() {
            return false
          }
          let blk = text(s(), "blocked")
          blk != "" && blk != text(s(), "summary") && text(s(), "summary") != ""
        },
        at_once=true,
        fn(bl) {
          @sf.styled_words(bl, fn() { text(s(), "blocked") }, fn() { sl_blocked_words }) |> ignore
        },
      )
    })
    |> ignore
    // Safe mode join action when station is unprotected and viewer may protect it: a sibling action row below the
    // station row inside card_piece_node, sharing its row_corner (concentric with card_piece_node), content left edge
    // (rule 8), and separated from the station row by 2pt (rule 1).
    card.show(fn() { !sample && flag(s(), "protect") }, fn(p) {
      let address = fn() { text(s(), "station") }
      let ws = fn() {
        match address().find("/") {
          Some(i) => address().unsafe_substring(start=0, end=i)
          None => ""
        }
      }
      let joining = fn() { is_doing(core, ["lock.joinStation"], [("workspace", ws()), ("station", text(s(), "id"))]) }
      p.padding(Is((0.0, 2.0, 0.0, 0.0))).width_share(Is(1.0)) |> ignore
      @sf.button_while_node(
        p,
        fn() { !joining() },
        fn() { @sf.t("web-pages.security.joinShort") },
        fn(_) {
          let sv = @signals.untracked(s)
          @settings.join_dialog(core, @signals.untracked(ws), text(sv, "id"), text(sv, "name"))
        },
        fn(btn, live) {
          btn.transitions_only() |> ignore
          @sf.style_node(btn, fn() { sl_protect_row })
          btn.radius(Is(@sf.row_corner)) |> ignore
          if live {
            @sf.hover_ground_node(btn)
          }
          btn.box(fn(m) {
            @sf.style_node(m, fn() { sl_mark_box }, in_row=true)
            if !live {
              @sf.spinner_node(m, size=14.0) |> ignore
            } else {
              @sf.icon_node(m, "shield-check", 16.0, By(fn() { @sf.theme().p.accent_text })) |> ignore
            }
          })
          |> ignore
          @sf.words_node(btn, fn() { @sf.t("web-pages.security.joinShort") }, fn() { sl_protect_words }) |> ignore
        },
        fills=true,
      )
    })
  })
}

///|
/// Compact meter words preserving the core's idle/busy/remaining semantics (e.g. "CPU 空闲 72%", "CPU 占用 28%",
/// "内存剩 5.8 G", "磁盘剩 420 G", "CPU 72% idle"), never stripping "空闲/剩" so low-headroom red figures stay clear.
fn sl_meter_words(m : Json?) -> String {
  let short = text(m, "short")
  let rem = text(m, "remaining")
  if short != "" && rem != "" {
    if @sf.chip_joined(short, rem) {
      short + rem
    } else {
      short + " " + rem
    }
  } else if rem != "" {
    rem
  } else {
    sp_meter_compact(m)
  }
}

///|
/// Line 2 of an online station row: compact CPU / memory / disk figures on the left and network path + latency flush
/// right. When width is tight, non-warning meters drop first (disk -> mem -> cpu), then network path drops before any
/// amber/red warning meter so all three warnings fit alongside latency on a 390pt phone screen.
fn sl_metrics_net_line_node(r : @view.View, meters : () -> Array[Json], net : () -> Json?) -> Unit {
  @sf.style_node(r, fn() { sl_sub_row })
  r.fits(Is(true)) |> ignore
  for kind in [0, 1, 2] {
    let m = fn() { sp_meter_of(meters(), kind) }
    r.show(at_once=true, fn() { m() is Some(_) }, fn(mb) {
      let drop_rank = fn() {
        let lvl = text(m(), "level")
        let is_low = lvl == "amber" || lvl == "red"
        match kind {
          2 => if is_low { 5 } else { 1 }
          1 => if is_low { 6 } else { 2 }
          _ => if is_low { 0 } else { 3 }
        }
      }
      mb.shrink(Is(0.0)).fit_whole(Is(true)).drops(By(drop_rank)) |> ignore
      @sf.styled_words(mb, fn() { sl_meter_words(m()) }, fn() {
        match text(m(), "level") {
          "red" => sl_meta_red
          "amber" => sl_meta_amber
          _ => sl_meta_muted
        }
      })
      |> ignore
    })
  }
  r.box(fn(sp) { sp.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore }) |> ignore
  let has_net = fn() { net() is Some(Object(_)) }
  r.show(at_once=true, fn() { has_net() && text(net(), "path") != "" }, fn(pw) {
    let long_path = fn() { text(net(), "path").length() > 6 }
    pw
    .shrink(By(fn() { if long_path() { 1.0 } else { 0.0 } }))
    .min_width(By(fn() { if long_path() { Some(0.0) } else { None } }))
    .fit_whole(Is(true))
    .drops(Is(4))
    |> ignore
    @sf.styled_words(pw, fn() { text(net(), "path") }, fn() {
      if long_path() { sl_meta_muted_cut } else { sl_meta_muted }
    })
    |> ignore
  })
  r.show(at_once=true, fn() { has_net() && field(net(), "loss") is Some(Object(_)) }, fn(x) {
    x.shrink(Is(0.0)).fit_whole(Is(true)) |> ignore
    @sf.styled_words(x, fn() { text(field(net(), "loss"), "text") }, fn() {
      @sfbase.level_figure_style(text(field(net(), "loss"), "level"), sl_meta_fig)
    })
    |> ignore
  })
  r.show(at_once=true, fn() { has_net() && field(net(), "rtt") is Some(Object(_)) }, fn(x) {
    x.shrink(Is(0.0)).fit_whole(Is(true)) |> ignore
    @sf.styled_words(x, fn() { text(field(net(), "rtt"), "text") }, fn() {
      @sfbase.level_figure_style(text(field(net(), "rtt"), "level"), sl_meta_fig)
    })
    |> ignore
  })
  r.show(at_once=true, fn() { !has_net() }, fn(nb) {
    nb.shrink(Is(0.0)).fit_whole(Is(true)) |> ignore
    @sf.waiting_node(nb, fn(w) {
      @sf.style_node(w, fn() { sl_net_tail })
      @sf.words_node(w, fn() { @sf.sample_words(2) }, fn() { sl_meta_muted }) |> ignore
      @sf.words_node(w, fn() { @sf.sample_words(3) }, fn() { sl_meta_fig }) |> ignore
    })
  })
}

///|
/// Right-aligned compact network status (`path`, optional packet `loss`, and `rtt`) when `net()` is known,
/// or a compact skeleton placeholder while `stationNet` is still being sampled for an online station.
fn sl_net_tail_node(r : @view.View, net : () -> Json?, waiting? : Bool = false) -> Unit {
  r.pick(
    fn() {
      match net() {
        Some(Object(_)) => 1
        _ => if waiting { 2 } else { 0 }
      }
    },
    at_once=true,
    fn(nb, kind) {
      match kind {
        1 => {
          nb.shrink(Is(1.0)).min_width(Is(Some(0.0))).fit_whole(Is(true)) |> ignore
          @sf.style_node(nb, fn() { sl_net_tail })
          nb.box(fn(pw) {
            let long_path = fn() { text(net(), "path").length() > 6 }
            pw
            .shrink(By(fn() { if long_path() { 1.0 } else { 0.0 } }))
            .min_width(By(fn() { if long_path() { Some(0.0) } else { None } }))
            |> ignore
            @sf.styled_words(pw, fn() { text(net(), "path") }, fn() {
              if long_path() { sl_meta_muted_cut } else { sl_meta_muted }
            })
            |> ignore
          })
          |> ignore
          nb.show(fn() { field(net(), "loss") is Some(Object(_)) }, at_once=true, fn(x) {
            @sf.styled_words(x, fn() { text(field(net(), "loss"), "text") }, fn() {
              @sfbase.level_figure_style(text(field(net(), "loss"), "level"), sl_meta_fig)
            })
            |> ignore
          })
          nb.show(fn() { field(net(), "rtt") is Some(Object(_)) }, at_once=true, fn(x) {
            @sf.styled_words(x, fn() { text(field(net(), "rtt"), "text") }, fn() {
              @sfbase.level_figure_style(text(field(net(), "rtt"), "level"), sl_meta_fig)
            })
            |> ignore
          })
        }
        2 => {
          nb.shrink(Is(0.0)).fit_whole(Is(true)) |> ignore
          @sf.waiting_node(nb, fn(w) {
            @sf.style_node(w, fn() { sl_net_tail })
            @sf.words_node(w, fn() { @sf.sample_words(2) }, fn() { sl_meta_muted }) |> ignore
            @sf.words_node(w, fn() { @sf.sample_words(3) }, fn() { sl_meta_fig }) |> ignore
          })
        }
        _ => ()
      }
    },
  )
}

///|
/// Compact grouped row for a task-only station (rig).
fn sl_rig_row_node(
  b : @view.View,
  r : () -> Json?,
  piece : () -> @sf.CardPiece,
  press : () -> Unit,
) -> Unit {
  b.grow(Is(1.0)) |> ignore
  @sf.card_piece_node(b, piece, wide_group=true, fn(card) {
    sl_card_sep_node(card, piece)
    card.box(fn(row) {
      row.transitions_only() |> ignore
      @sf.style_node(row, fn() { sl_row_multi })
      row.radius(Is(@sf.row_corner)) |> ignore
      @sf.hover_ground_node(row)
      @sf.rippled_node(row, press, @sf.row_corner, fn() { text(r(), "name") })
      row.box(fn(head) {
        @sf.style_node(head, fn() { sl_head })
        head.box(fn(m) {
          @sf.style_node(m, fn() { sl_mark_box }, in_row=true)
          @sf.icon_node(m, "boxes", sl_mark_side, By(fn() { @sf.theme().p.text })) |> ignore
        })
        |> ignore
        @sf.words_node(head, fn() { text(r(), "name") }, fn() { sl_name })
        .grow(Is(1.0))
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        |> ignore
        @sf.state_dot_node(
          head,
          fn() {
            match field(r(), "reached") {
              Some(True) if flag(r(), "vouched") => "up"
              _ => "offline"
            }
          },
          size=station_dot_side,
        )
      })
      |> ignore
      @sf.words_node(row, fn() { @settings.rig_said(r()) }, fn() { sl_meta_muted_cut }) |> ignore
    })
    |> ignore
  })
}

///|
/// Compact grouped row for a workspace device.
fn sl_device_row_node(
  b : @view.View,
  d : () -> Json?,
  piece : () -> @sf.CardPiece,
  press : () -> Unit,
) -> Unit {
  let online = fn() { !(field(d(), "online") is Some(False)) }
  b.grow(Is(1.0)) |> ignore
  @sf.card_piece_node(b, piece, wide_group=true, fn(card) {
    sl_card_sep_node(card, piece)
    card.box(fn(row) {
      row.transitions_only() |> ignore
      @sf.style_node(row, fn() { sl_row_multi })
      row.radius(Is(@sf.row_corner)) |> ignore
      @sf.hover_ground_node(row)
      @sf.rippled_node(row, press, @sf.row_corner, fn() { text(d(), "name") })
      row.box(fn(head) {
        @sf.style_node(head, fn() { sl_head })
        head.box(fn(m) {
          @sf.style_node(m, fn() { sl_mark_box }, in_row=true)
          let ink = fn() { if online() { @sf.theme().p.text } else { @sf.theme().p.muted } }
          @sf.icon_node(m, "", sl_mark_side, By(ink), name_now=fn() { @settings.device_icon(d()) }) |> ignore
        })
        |> ignore
        @sf.words_node(head, fn() { text(d(), "name") }, fn() {
          if online() { sl_name } else { sl_name_off }
        })
        .grow(Is(1.0))
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        |> ignore
      })
      |> ignore
      @sf.words_node(row, fn() { @settings.device_said(d()) }, fn() { sl_meta_muted_cut }) |> ignore
    })
    |> ignore
  })
}

///|
/// Where a station this workspace joined is at home, as grey words.
fn sl_joined(s : Json?) -> String {
  if !flag(s, "joined") {
    return ""
  }
  match opt_text(s, "home") {
    Some(h) => @sf.t("web-pages.stations.joinedFrom", args=[("name", h)])
    None => @sf.t("web-pages.stations.joinedElsewhere")
  }
}

// ── styles ─────────────────────────────────────────

///|
/// The scene over the first to add.
let sl_first_art_w : Double = 240.0

///|
/// Station, rig and device mark size on a compact row.
let sl_mark_side : Double = 18.0

///|
/// Hairline separator inset matching the row's 12pt horizontal padding inside card_piece_node.
// kept across runs: a value (no field of it changes)
let sl_sep_line : @ui.Style = @ui.css("mx=S3")

///|
/// Compact two-line row: symmetric 12pt horizontal and 10pt vertical padding, 4pt line gap.
// kept across runs: a value (no field of it changes)
let sl_row_multi : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S1")

///|
/// Line 1 of a row: mark, name/tag, and right-aligned status.
// kept across runs: a value (no field of it changes)
let sl_head : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sl_mark_box : @ui.Style = @ui.css("w=S5 h=S5 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let sl_name_row : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sl_name : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let sl_name_off : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Muted, wrap=false, w=Cut)

///|
/// Line 2 of an online row: compact metrics on the left and network on the right.
// kept across runs: a value (no field of it changes)
let sl_sub_row : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sl_net_tail : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
/// Reconnecting status at the right end of line 1: spinner and words, 4pt apart.
// kept across runs: a value (no field of it changes)
let sl_reconnecting : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sl_reconnecting_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sl_meta_muted : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sl_meta_muted_cut : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let sl_meta_fig : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sl_meta_amber : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=WarnInk, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sl_meta_amber_cut : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=WarnInk, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let sl_meta_red : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=Danger, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sl_blocked_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, max_lines=2, w=Full)

///|
/// Action row below an unprotected station row inside card_piece_node.
// kept across runs: a value (no field of it changes)
let sl_protect_row : @ui.Style = @ui.css("row w=Full px=S3 py=S2 min_h=S11 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sl_protect_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=AccentText, wrap=false)

///|
/// What adds the first, 30 in from the screen's sides as first_station's was (the page's own 12 and 18 more).
// kept across runs: a value (no field of it changes)
let sl_first_in : @ui.Style = @ui.css("w=Full px=S4_5")

///|
/// Where the viewer may not add one: that they wait, on a warm ground 12 round, its words 12 and 10 in.
// kept across runs: a value (no field of it changes)
let sl_wait_box : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 radius=Xl")

///|
/// The warm ground's ink (settings' warn).
let sl_warn : Int64 = 0xD9962BFFL

///|
// kept across runs: a value (no field of it changes)
let sl_wait_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L4_75, color=Fg, w=Full)
