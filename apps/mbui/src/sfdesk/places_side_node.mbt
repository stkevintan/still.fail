// The sidebars of the rail's Station and Profile places (StationsNav, ProfilesNav), made once over the block as nodes of
// the window's tree (side_node's, as the chats' and the settings' are): under the band's top row, 添加 in the band (the
// update at its end where one is offered), then the list scrolling under it, a row each as places.mbt's lists have
// them; the one picked lit, its page beside it in the pane (stations_place_node, profiles_place_node).

///|
/// The stations' sidebar (StationsNav) in node `s` as wide as the sidebar, where `at` says the block has it: 添加
/// station in its band, then a row each of the workspace's stations, then those that only run tasks, then its
/// devices under their heading.
fn stations_side_node(s : @view.View, src : Source, tips : @sf.TipLayer, at : () -> SideAt) -> Unit {
  place_side_node(s, src, tips, at, "stations", fn(q, core, w, here, list_at) {
    // (a station's page in the pane once what it shows is answered, where what opens waits for what it shows: its
    // station, then what its part shown reads, the pane as it was meanwhile; sfbase's route_open_asks, route_open_then)
    let pick = fn(address : String) {
      let route = Route::Station(address)
      let show = fn() {
        place_pick[place_key(w.id, "stations")] = route
        @sfbase.show_chosen()
      }
      if !(src.gates_opens)() || @signals.untracked(fn() { place_route(src, w, "stations") }) == Some(route) {
        show()
        return
      }
      @sfbase.show_answered(
        src,
        @sfbase.route_open_asks(src, w, route),
        @sfpages.station_shown_at(address),
        show,
        then?=@sfbase.route_open_then(src, w, route),
      )
    }
    // (its lines in their order: the stations, those that only run tasks after the whole ones, the devices under
    // their heading)
    let lines = fn() -> Array[PlaceLine] {
      let out = []
      let listed = stations_listed(src, w)
      for i, st in listed {
        out.push({ key: "s/" + text(Some(st), "station"), data: Some(st), more: i + 1 < listed.length() })
      }
      for r in @settings.rigs_listed(core, here()) {
        out.push({ key: "r/" + w.id + "/" + text(Some(r), "id"), data: Some(r), more: false })
      }
      let devices = @settings.devices_listed(core, here())
      if devices.length() > 0 {
        out.push({ key: "dh", data: None, more: false })
      }
      for d in devices {
        out.push({ key: "d/" + text(Some(d), "station") + "/" + text(Some(d), "id"), data: Some(d), more: false })
      }
      out
    }
    // (the one picked, read by member: a choice that moves tells the two rows it concerns)
    // (worked out once as the list changes, told on only as it comes out otherwise)
    let chosen = @signals.computed(fn(_) {
      match place_route(src, w, "stations") {
        Some(Station(a)) => Some(a)
        _ => None
      }
    })
    let lit = q.selected(fn() { chosen.get() })
    place_list_node(q, list_at, lines, stations_line_shape, fn(line, key, now) {
      let data = fn() { now().bind(fn(p) { p.data }) }
      // (told on only as it comes out otherwise: its line changed tells its room under it nothing)
      let more_c = @signals.computed(fn(_) { now().map(fn(p) { p.more }).unwrap_or(false) })
      let more = fn() { more_c.get() }
      // (a station's or a rig's address as its key now says it)
      let address = fn() {
        let k = key()
        k.unsafe_substring(start=2, end=k.length())
      }
      // (its make, which never changes for a block: stations_line_shape's)
      let made_as = stations_line_shape(@signals.untracked(key))
      if made_as == 0 {
        @sf.list_heading_node(line, fn() { @sf.t("web-pages.devices.title") }, list_at)
      } else if made_as == 1 {
        @sf.nav_item_node(
          line,
          list_at,
          fn() { lit(address()) },
          fn() { text(data(), "name") },
          fn(_) { pick(address()) },
          fn(m) {
            m.pick(fn() { (text(data(), "emoji"), text(data(), "icon")) }, fn(k, mk) {
              if @sf.has_station_mark(mk.0, mk.1) {
                @sf.station_mark_node(k, fn() { mk.0 }, fn() { mk.1 }, @sf.nav_mark_side, fn() { @sf.theme().p.text }, fn() {
                  0
                })
              } else {
                @sf.icon_node(k, "server", @sf.nav_mark_side, By(fn() { @sf.theme().p.text })) |> ignore
              }
            })
          },
          fn(t) { @sf.nav_title_node(t, fn() { text(data(), "name") }) },
          end=fn(e) { @sfpages.station_state_node(e, data) },
          lines=fn(ls) { @sfpages.station_figures_node(ls, src, data, apart=true) },
          keep_lines=2,
          more~,
        )
      } else if made_as == 2 {
        // those that only run tasks: whose each is and how it is, in the figures' place
        @sf.nav_item_node(
          line,
          list_at,
          fn() { lit(address()) },
          fn() { text(data(), "name") },
          fn(_) { pick(address()) },
          fn(m) { @sf.icon_node(m, "boxes", @sf.nav_mark_side, By(fn() { @sf.theme().p.text })) |> ignore },
          fn(t) { @sf.nav_title_node(t, fn() { text(data(), "name") }) },
          lines=fn(ls) { @sfpages.rig_figures_node(ls, data) },
          keep_lines=2,
        )
      } else {
        // the workspace's devices (attached to a station, or a person's phone), each opening its panel
        @sf.nav_item_node(
          line,
          list_at,
          fn() { false },
          fn() { text(data(), "name") },
          fn(_) {
            let d = @signals.untracked(data)
            @settings.open_device(core, @signals.untracked(here), text(d, "station"), text(d, "id"), Unanchored)
          },
          fn(m) {
            m.pick(fn() { @settings.device_icon(data()) }, fn(k, icon) {
              @sf.icon_node(k, icon, @sf.nav_mark_side, By(fn() { @sf.theme().p.text })) |> ignore
            })
          },
          fn(t) { @sf.nav_title_node(t, fn() { text(data(), "name") }, away=fn() { field(data(), "online") is Some(False) }) },
          lines=fn(ls) {
            @sf.list_row_line_node(ls, fn(r) { @sf.nav_meta_node(r, fn() { @settings.device_said(data()) }) })
          },
          keep_lines=1,
        )
      }
    })
  })
}

///|
/// A line of a place's sidebar list (place_side_node's): its key (what it is), what it shows, whether another row of
/// its run is under it.
#derive(Eq)
priv struct PlaceLine {
  key : String
  data : Json?
  more : Bool
}

///|
/// The profiles' sidebar (ProfilesNav) in node `s` as wide as the sidebar, where `at` says the block has it: 添加
/// Profile in its band, then the overview, a section each kind of account, a row an account (its allowance's chips
/// across its foot, the same way for every account of a provider); then each station's own logins not made profiles
/// yet.
fn profiles_side_node(s : @view.View, src : Source, tips : @sf.TipLayer, at : () -> SideAt) -> Unit {
  // (the accounts' 多选: begun at the band's end beside 添加, its bar at the sidebar's foot; over as the workspace in
  // view changes)
  let batch = @sfpages.ProfilesBatch::new()
  let listed_of = fn(w : Workspace) { src.topic("profiles", { "scope": Json::string(w.id) }).get().value }
  let rows_of = fn(w : Workspace) { items(listed_of(w), "items") }
  let offered = fn(w : Workspace) { @sfpages.profiles_batch_offered(fn() { flag(listed_of(w), "manages") }, fn() { rows_of(w) }) }
  let band_end = fn(b : @view.View, _ : @settings.Core, w : Workspace, _ : () -> @settings.Here) {
    // (it stays while 多选 is on, lit, pressed again to end it: the band never changes as it begins)
    b.show(fn() { offered(w) }, fn(k) {
      @sf.icon_button_node(k, "check-circle", fn() { @sf.t("web-pages.profiles.batch.select") }, fn() { batch.toggle() }, tips~, on=fn() {
        batch.on.get()
      })
      |> ignore
    })
  }
  let band_end_shown = fn(_ : @settings.Core, w : Workspace, _ : () -> @settings.Here) { offered(w) }
  let foot = fn(f : @view.View, core : @settings.Core, w : Workspace, here : () -> @settings.Here) {
    let stations = fn() {
      match @settings.stations_of(core, here()).value {
        Some(Array(a)) => a
        _ => []
      }
    }
    @sfpages.profiles_batch_foot_node(f, core, batch, fn() { rows_of(w) }, stations, side=@sf.theme().chat_list.band_in)
  }
  // (a workspace come into view: no 多选 begun in another)
  s.reacts(fn() { @sfbase.workspace_in_view(src).0.map(fn(w) { w.id }) }, fn(_) { batch.stop() }, at_start=false)
  place_side_node(s, src, tips, at, "profiles", band_end=(band_end, band_end_shown), foot~, fn(q, core, w, here, list_at) {
    let topic = fn() { src.topic("profiles", { "scope": Json::string(w.id) }).get().value }
    let list = fn() { items(topic(), "items") }
    // each station's own logins, not profiles yet (under the profiles: each station up that offers one)
    let offered = fn() {
      @settings.profiles_offers(topic()).map(fn(o) {
        (o.0, o.1.filter(fn(l) { flag(Some(l), "offered") && text(field(Some(l), "quota"), "state") != "blocked" }))
      })
    }
    // (the room the allowance of each kind of account that needs the most on one line takes, a vendor's, a profile's or
    // an offered login's, so that every row of a kind takes one way (nav_quota_chips_node); narrowed to only the quota
    // fields that affect chip width so unrelated profile updates (usedCount, checkText, state, name, planText, where,
    // usable) do not re-measure text across all accounts. The user, 2026-11-13: 「按账号类型来搞，不要所有全用同一种」「相同
    // 供应商的账号用同一种就行」)
    let quota_windows_key = fn(quota : Json?) -> Array[(String, String, String, Int, String)] {
      if !@sfbase.has_quota(quota) {
        return []
      }
      items(quota, "windows").map(fn(win) {
        let wv = Some(win)
        let left = match field(wv, "left") {
          Some(Number(x, ..)) => {
            let n = x.to_int()
            if n < 0 { 0 } else if n > 100 { 100 } else { n }
          }
          _ => 0
        }
        (text(wv, "label"), text(wv, "scope"), text(wv, "mark"), left, text(wv, "refillShort"))
      })
    }
    let quota_inputs = @signals.computed(fn(_) {
      let out : Array[(String, Array[(String, String, String, Int, String)])] = []
      for e in list() {
        let ws = quota_windows_key(field(field(Some(e), "profile"), "quota"))
        if !ws.is_empty() {
          out.push((profile_kind(Some(e)), ws))
        }
      }
      for o in offered() {
        for l in o.1 {
          let ws = quota_windows_key(field(Some(l), "quota"))
          if !ws.is_empty() {
            out.push((offer_kind(Some(l)), ws))
          }
        }
      }
      out
    })
    let widths = @signals.computed(fn(_) {
      let by : Map[String, (Double, Array[Double])] = Map([])
      for item in quota_inputs.get() {
        let (k, ws) = item
        let wins = ws.map(fn(win) {
          Json::object({
            "label": Json::string(win.0),
            "scope": Json::string(win.1),
            "mark": Json::string(win.2),
            "left": Json::number(win.3.to_double()),
            "refillShort": Json::string(win.4),
          })
        })
        let qj : Json = Json::object({ "state": Json::string("ok"), "windows": Json::array(wins) })
        let room = @sfbase.nav_quota_room_node(q, Some(qj))
        match by.get(k) {
          Some((most, _)) if most >= room.0 => ()
          _ => by[k] = room
        }
      }
      by
    })
    let widest = fn(kind : String) { fn() { widths.get().get(kind).unwrap_or((0.0, [])) } }
    let quota_room_w = profiles_side_quota_room_w(fn() { at().laid_w }, list_at)
    // (its lines in their order: the overview, the accounts under their kinds' headings, each station's logins under
    // its own)
    let lines = fn() -> Array[PlaceLine] {
      let out = []
      let all = list()
      if all.length() > 0 {
        out.push({ key: "ov", data: None, more: false })
      }
      let mut group = ""
      for i, e in all {
        let g = text(Some(e), "group")
        if g != group {
          group = g
          out.push({ key: "h/" + g, data: Some(Json::string(text(Some(e), "groupTitle"))), more: false })
        }
        let more = i + 1 < all.length() && text(Some(all[i + 1]), "group") == g
        out.push({ key: "p/" + text(Some(e), "key"), data: Some(e), more })
      }
      for o in offered() {
        let station = text(Some(o.0), "station")
        if o.1.length() == 0 {
          continue
        }
        out.push({ key: "mh/" + station, data: Some(Json::string(text(Some(o.0), "name"))), more: false })
        for j, l in o.1 {
          let row : Json = Json::object({ "station": Json::string(station), "login": l })
          out.push({ key: "m/" + station + "/" + text(Some(l), "runtime"), data: Some(row), more: j + 1 < o.1.length() })
        }
      }
      out
    }
    let picked = fn() { place_route(src, w, "profiles") }
    // (the one picked, read by member: a choice that moves tells the two rows it concerns)
    // (worked out once as the list changes, told on only as it comes out otherwise)
    let chosen = @signals.computed(fn(_) {
      match picked() {
        Some(Profiles("")) => Some("ov")
        Some(Profile(a, id)) => Some(a + "/" + id)
        _ => None
      }
    })
    let lit = q.selected(fn() { chosen.get() })
    place_list_node(q, list_at, lines, profiles_line_shape, est=@signals.untracked(fn() { @sf.theme().chat_list.row_h + 24.0 }), fn(line, key, now) {
      let data = fn() { now().bind(fn(p) { p.data }) }
      // (told on only as it comes out otherwise: its line changed tells its room under it nothing)
      let more_c = @signals.computed(fn(_) { now().map(fn(p) { p.more }).unwrap_or(false) })
      let more = fn() { more_c.get() }
      // (its make, which never changes for a block: profiles_line_shape's)
      let made_as = profiles_line_shape(@signals.untracked(key))
      if made_as == 0 {
        // (what it says of all of them, told on only as that comes out otherwise: a quota changed tells it nothing)
        let summed = @signals.computed(fn(_) { @sfpages.profiles_side_summary(list()) })
        let summary = fn() { summed.get() }
        @sf.nav_item_node(
          line,
          list_at,
          fn() { lit("ov") },
          profiles_overview_label,
          fn(_) {
            place_pick[place_key(w.id, "profiles")] = Route::Profiles("")
            @sfbase.show_chosen()
          },
          fn(m) { @sf.icon_node(m, "quota", @sf.nav_mark_side, By(fn() { @sf.theme().p.text })) |> ignore },
          fn(t) { @sf.nav_title_node(t, profiles_overview_label) },
          lines=fn(ls) {
            ls.show(fn() { summary().0 != "" }, fn(k) {
              @sf.list_row_line_node(k, fn(r) {
                @sf.nav_meta_node(r, fn() { summary().0 }, look=fn() { trouble_ink(summary().1) })
              })
            })
          },
        )
      } else if made_as == 1 {
        // (its words alone: a change of the account under it tells it nothing)
        @sf.list_heading_node(line, fn() { heading_words(data()) }, list_at)
      } else if made_as == 2 {
        @sf.list_heading_node(
          line,
          fn() {
            @sf.t("web-pages.profiles.machineSignedIn", args=[("station", heading_words(data()))])
          },
          list_at,
        )
      } else if made_as == 3 {
        // (while 多选 is on, its box to tick in its place: pressed, picked, never its page)
        line.pick(fn() { batch.on.get() }, fn(x, picking) {
          if picking {
            @sfpages.profiles_batch_side_row_node(x, list_at, batch, data, more)
          } else {
            profile_side_row_node(x, src, w, tips, list_at, data, more, lit, widest, quota_room_w)
          }
        })
      } else {
        machine_side_row_node(line, src, core, here, tips, list_at, data, more, widest, quota_room_w)
      }
    })
  })
}

///|
/// Which block of the stations' sidebar a line takes as it comes to show (place_list_node's `shape`, by its key): the
/// devices' heading, a station, a rig, a device, each its own make.
fn stations_line_shape(key : String) -> Int {
  if key == "dh" {
    0
  } else if key.has_prefix("s/") {
    1
  } else if key.has_prefix("r/") {
    2
  } else {
    3
  }
}

///|
/// Which block of the accounts' sidebar a line takes as it comes to show (place_list_node's `shape`, by its key): the
/// overview, a heading, a machine's heading, an account, a machine's sign-in, each its own make.
fn profiles_line_shape(key : String) -> Int {
  if key == "ov" {
    0
  } else if key.has_prefix("h/") {
    1
  } else if key.has_prefix("mh/") {
    2
  } else if key.has_prefix("p/") {
    3
  } else {
    4
  }
}

///|
/// 概览's words.
fn profiles_overview_label() -> String {
  if @sf.language() == "en" {
    "Overview"
  } else {
    "概览"
  }
}

///|
/// Which kind of account a profile's entry `e` is, for the room its allowance takes (nav_quota_chips_node): its group,
/// a key's its provider (else its kind).
fn profile_kind(e : Json?) -> String {
  let g = text(e, "group")
  if g != "key" {
    g
  } else {
    let a = field(field(e, "profile"), "access")
    let pv = text(a, "provider")
    if pv != "" {
      pv
    } else {
      text(a, "kind")
    }
  }
}

///|
/// Which kind of account a station's own login `l` is (profile_kind's): Codex's ChatGPT's, else its runtime's.
fn offer_kind(l : Json?) -> String {
  let rt = text(l, "runtime")
  if rt == "codex" {
    "chatgpt"
  } else {
    rt
  }
}

///|
/// The inner width available to `nav_quota_chips_node` inside a row of `profiles_side_node`, derived from the sidebar's
/// `laid_w()` without reading `at()` during tree construction: `from` (+side_into_rail) and `back` (-side_into_rail)
/// cancel out, leaving `side_list` (`band_in` per side) and `list_row_in(list_at)` (`band_pad_in(list_at)` per side).
fn profiles_side_quota_room_w(laid_w : () -> Double, list_at : @sf.ListAt) -> () -> Double {
  fn() {
    let w = laid_w() - 2.0 * @sf.theme().chat_list.band_in - 2.0 * @sf.band_pad_in(list_at)
    if w > 0.0 { w } else { 0.0 }
  }
}

///|
/// An account's row in the profiles' sidebar (profiles_side_node's), as `e()` says it now: its provider's logo, its
/// name (faint where it cannot be used); what is wrong in its tone, else a balance or why its allowance is not said; its
/// allowance's chips across its foot where it has windows. Pressed, its page in the pane once what it shows is answered,
/// the pane as it was meanwhile, what it asked handed to that page (sfbase's account_open.mbt).
fn profile_side_row_node(
  line : @view.View,
  src : Source,
  w : Workspace,
  tips : @sf.TipLayer,
  list_at : @sf.ListAt,
  e : () -> Json?,
  more : () -> Bool,
  lit : (String) -> Bool,
  widest : (String) -> () -> (Double, Array[Double]),
  room_w : () -> Double,
) -> Unit {
  // (each part of it it shows worked out once as the row's account changes, told on only as it comes out otherwise:
  // an account's state changed runs only what shows it)
  let held = fn(f : () -> String) {
    let c = @signals.computed(fn(_) { f() })
    fn() { c.get() }
  }
  let p = fn() { field(e(), "profile") }
  let route_c = @signals.computed(fn(_) { profile_route(e()) })
  let route = fn() { route_c.get() }
  let usable_c = @signals.computed(fn(_) { flag(e(), "usable") })
  let usable = fn() { usable_c.get() }
  // how it is where that is not simply fine, as the core says it, in its tone: what needs a look in colour
  let trouble = held(fn() { text(field(e(), "state"), "text") })
  let tone = held(fn() { text(field(e(), "state"), "tone") })
  // its name, its plan and its allowance: where it can be used and which connects use it are its page's (the user,
  // 2026-11-14: 「额度的第二行感觉现在就一个有效信息」); the line under the name only for what is wrong, and a balance
  // where it has no windows
  let quota_c = @signals.computed(fn(_) { field(p(), "quota") })
  let quota = fn() { quota_c.get() }
  let ok = fn() { text(quota(), "state") == "ok" }
  let windows_c = @signals.computed(fn(_) { ok() && items(quota(), "windows").length() > 0 })
  let windows = fn() { windows_c.get() }
  let credits = fn() { ok() && !windows() && text(quota(), "creditsText") != "" }
  let sub_line = held(fn() {
    if credits() {
      text(quota(), "creditsText")
    } else if usable() && trouble() == "" && !windows() && text(e(), "group") != "key" {
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
  })
  // (its plan right after its name, leaving the line before the name is cut short for it: the user, 2026-11-17)
  let plan = held(fn() { text(p(), "planText") })
  // (a subscription by its account, a key by its name: the core's)
  let name = held(fn() { if text(p(), "name") != "" { text(p(), "name") } else { text(e(), "title") } })
  let picked_as = held(fn() {
    match route() {
      Route::Profile(a, id) => a + "/" + id
      _ => ""
    }
  })
  let kind = held(fn() { profile_kind(e()) })
  // (the room its kind's widest allowance takes, told on only as that comes out otherwise: another kind's changing
  // runs nothing of this row's)
  let widest_c = @signals.computed(fn(_) { widest(kind())() })
  let logo_c = @signals.computed(fn(_) {
    (text(p(), "runtime"), text(field(p(), "access"), "kind"), text(p(), "providerMark"))
  })
  let press = fn(_ : @view.View) {
    let route = @signals.untracked(route)
    // (the one shown already: nothing to ask, nothing made anew to take it)
    if @signals.untracked(fn() { place_route(src, w, "profiles") }) == Some(route) {
      @sfbase.show_chosen()
      return
    }
    let at = match route {
      Route::Profile(station, id) => @sfbase.profile_shown_at(station, id)
      _ => ""
    }
    @sfbase.show_answered(src, @sfbase.route_asks(w.id, route), at, fn() {
      place_pick[place_key(w.id, "profiles")] = route
      @sfbase.show_chosen()
    })
  }
  // (its allowance's chips across its foot while it has windows)
  @sf.nav_item_node(
      line,
      list_at,
      fn() { lit(picked_as()) },
      name,
      press,
      fn(m) { @sfbase.provider_mark_node(m, fn() { logo_c.get() }, @sf.nav_mark_side) },
      fn(t) {
        @sf.nav_title_node(t, name, away=fn() { !usable() }, after=fn(a) { @sf.row_tag_node(a, plan) }, after_shown=fn() {
          plan() != ""
        })
      },
      lines=fn(ls) {
        ls.show(fn() { trouble() != "" }, fn(k) {
          @sf.list_row_line_node(k, fn(r) { @sf.nav_meta_node(r, trouble, look=fn() { trouble_ink(tone()) }) })
        })
        ls.show(fn() { sub_line() != "" }, fn(k) {
          @sf.list_row_line_node(k, fn(r) { @sf.nav_meta_node(r, sub_line) })
        })
      },
      more~,
      foot=fn(f) { @sfbase.nav_quota_chips_node(f, quota, list_at, fn() { widest_c.get() }, tips~, room_w~) },
      foot_on=windows,
      foot_capsule=@sf.fill_chip_small_h,
    )
}

///|
/// A station's own login not made a profile yet in the profiles' sidebar (profiles_side_node's), as `row()` says it now
/// (the station's address, the login): its maker's mark, its runtime, its email and 使用此账号; its allowance under it
/// as a profile's row has it (the same chips), so an account not added yet shows what is left of its week as well.
/// Pressed, a new profile of it once what that shows is answered, the screen as it was meanwhile, as the page's own
/// choice of a station opens it (sfpages' open_new_profile).
fn machine_side_row_node(
  line : @view.View,
  src : Source,
  core : @settings.Core,
  here : () -> @settings.Here,
  tips : @sf.TipLayer,
  list_at : @sf.ListAt,
  row : () -> Json?,
  more : () -> Bool,
  widest : (String) -> () -> (Double, Array[Double]),
  room_w : () -> Double,
) -> Unit {
  let l = fn() { field(row(), "login") }
  let station = fn() { text(row(), "station") }
  // (what it shows worked out once as its login changes, told on only as each comes out otherwise)
  let quota_c = @signals.computed(fn(_) { field(l(), "quota") })
  let quota = fn() { quota_c.get() }
  let windows_c = @signals.computed(fn(_) { text(quota(), "state") == "ok" && items(quota(), "windows").length() > 0 })
  let windows = fn() { windows_c.get() }
  let kind_c = @signals.computed(fn(_) { offer_kind(l()) })
  let kind = fn() { kind_c.get() }
  // (the room its kind's widest allowance takes, told on only as that comes out otherwise)
  let widest_c = @signals.computed(fn(_) { widest(kind())() })
  let label = fn() { @settings.runtime_label(text(l(), "runtime")) }
  let plan_c = @signals.computed(fn(_) { text(l(), "planText") })
  let plan = fn() { plan_c.get() }
  @sf.nav_item_node(
      line,
      list_at,
      fn() { false },
      label,
      fn(_) {
        let station = @signals.untracked(station)
        @sfpages.open_new_profile(src, core, @signals.untracked(here), station, fn() {
          @sfbase.history_push()
          app.nav.push(Setting(Route::NewProfile(station)))
          @sfbase.show_chosen()
        })
      },
      fn(m) {
        m.pick(fn() { text(l(), "runtime") }, fn(k, rt) { @sf.maker_mark_node(k, "", rt, @sf.nav_mark_side) |> ignore })
      },
      // (its plan after its runtime as an account's is after its name: the core's planText)
      fn(t) {
        @sf.nav_title_node(t, label, after=fn(a) { @sf.row_tag_node(a, plan) }, after_shown=fn() { plan() != "" })
      },
      lines=fn(ls) {
        @sf.list_row_line_node(ls, fn(r) {
          r.box(fn(g) {
            g.grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            @sf.nav_meta_node(g, fn() { text(l(), "email") })
          })
          |> ignore
          @sf.words_node(r, fn() { @sf.t("android-settings.machine.use") }, fn() {
            @sf.theme().chat_list.last.then(place_use)
          })
          |> ignore
        })
      },
      more~,
      foot=fn(f) { @sfbase.nav_quota_chips_node(f, quota, list_at, fn() { widest_c.get() }, tips~, room_w~) },
      foot_on=windows,
      foot_capsule=@sf.fill_chip_small_h,
    )
}

///|
/// A place's sidebar (stations_side_node's, profiles_side_node's) in `s` as wide as the sidebar, where `at` says the
/// block has it, of the workspace in view (made again as that changes): its top row, the band (添加 where the viewer
/// may add one to `place`, the update at its end where one is offered), the list `rows` makes under it, scrolling
/// under the band, the room under its last.
fn place_side_node(
  s : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  at : () -> SideAt,
  place : String,
  rows : (@view.View, @settings.Core, Workspace, () -> @settings.Here, @sf.ListAt) -> Unit,
  band_end? : (
    (@view.View, @settings.Core, Workspace, () -> @settings.Here) -> Unit,
    (@settings.Core, Workspace, () -> @settings.Here) -> Bool,
  ),
  foot? : (@view.View, @settings.Core, Workspace, () -> @settings.Here) -> Unit,
) -> Unit {
  let workspace = fn() { @sfbase.workspace_in_view(src).0 }
  let list_at = side_list_at(@signals.untracked(at))
  let band_at = fn() {
    let a = at()
    ({ brand: a.brand, band: a.band, tape: a.tape, in_bar: a.bar, roots: @ui.tree_corner_roots_now() } : BandAt)
  }
  // (while the app's first page waits for what it shows: drawn at none, the splash in its place, as the old views are)
  s
  .grow(Is(1.0))
  .min_height(Is(Some(0.0)))
  .alpha(By(fn() { if @sfbase.first_page_waits.get() { 0.0 } else { 1.0 } }))
  .takes_unseen(Is(true))
  |> ignore
  s.pick(fn() { workspace().map(fn(w) { w.id }) }, fn(q, _id) {
    q.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    guard @signals.untracked(workspace) is Some(w) else { return }
    let core = settings_core(src, w)
    let here = fn() { @settings.here_of(core, w.id, w.name) }
    let action = fn() { @settings.place_action(core, here(), place) }
    let label = fn() {
      @sf.t(if place == "stations" { "web-pages.settings.stations.add" } else { "web-pages.settings.profiles.add" })
    }
    side_top_node(q, fn() { at().brand })
    // the band (NavAction): 添加 where the viewer may add one, the update at its end where one is offered; none where
    // neither is
    let band_end_shown = fn() {
      match band_end {
        Some((_, shown)) => shown(core, w, here)
        None => false
      }
    }
    q.show(fn() { action() is Some(_) || update_shown() || band_end_shown() }, fn(band) {
      // (on the tape, as the settings' band: in the panel's top corner, its row kept off that corner by the update's
      // room, which the update's round key, where one is offered, is concentric with)
      let tape = list_at is Tape
      @sf.style_node(band, fn() { if tape { band_new_tape(at=band_at()) } else { update_band(at=band_at()) } })
      band.box(fn(main) {
        @sf.style_node(main, fn() { side_full }, in_row=true)
        // (what the band ends with beside 添加, at its end on the same line: the profiles' 多选)
        if band_end is Some(_) {
          main.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
        }
        if tape {
          main.margin(By(fn() { (0.0, 0.0, if update_shown() { 0.0 } else { update_key_side }, 0.0) })) |> ignore
        }
        main.show(fn() { action() is Some(_) }, fn(o) {
          // (what it puts up beside the row pressed: the row's box)
          o.row(Is(true)).grow(Is(1.0)) |> ignore
          @sf.band_row_node(o, fn() { false }, label, fn() {
            match @signals.untracked(action) {
              Some(go) => go(Node(o))
              None => ()
            }
          }, list_at, fn(b) {
            @sf.icon_node(b, "plus", @sf.theme().chat_list.band_icon, By(fn() { @sf.theme().p.muted })) |> ignore
            @sf.nav_words_node(b, label)
          })
        })
        match band_end {
          Some((make, _)) => make(main, core, w, here)
          None => ()
        }
      })
      |> ignore
      band.show(update_shown, fn(u) {
        @sf.update_key_node(
          u,
          tips,
          update_key_side,
          update_key_mark,
          fn() { update_said().0 },
          fn() { update_said().1 },
          fn() { update_said().2 },
          fn() {
            match update_now() {
              Coming(_, part) => Some(part)
              _ => None
            }
          },
          fn() { update_pressed(src) },
          offered=fn() { update_now() is Offered(_, ..) },
        )
      })
    })
    // the list under the band (side_scroll's): what scrolls, and takes the hand, starts at the rail's edge: the
    // sidebar's first 8 reach over the rail's empty side, which its places' keys take; its rows where they were, in from
    // the sidebar's edge, a row made only while it shows (place_list_node)
    q.box(fn(from) {
      from.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))).margin(Is((side_into_rail, 0.0, 0.0, 0.0))) |> ignore
      from.box(fn(l) {
        @sf.style_node(l, fn() { @sf.side_list().then(@ui.style(px=S0)) })
        l.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        rows(l, core, w, here, list_at)
      })
      |> ignore
    })
    |> ignore
    match foot {
      Some(f) => f(q, core, w, here)
      None => ()
    }
  })
}

///|
/// A place's sidebar's list in `l` (place_side_node's): a block a line of `lines()` by its key, made only while it
/// shows (View::scrolls_window), each in from the sidebar's edge as its rows are (the theme's side_list) and back over
/// the rail's empty side the list reaches into; `make` makes the line of a key in its block, given what says its key
/// and what that line is now (told on only as it comes out otherwise: a line changed tells the others nothing), a block
/// taken by the next line of its make (`shape`, by its key) to show as it no more does, its key that one's
/// (View::scrolls_reused); the room under its last.
fn place_list_node(
  l : @view.View,
  list_at : @sf.ListAt,
  lines : () -> Array[PlaceLine],
  shape : (String) -> Int,
  est? : Double,
  make : (@view.View, () -> String, () -> PlaceLine?) -> Unit,
) -> Unit {
  let est = est.unwrap_or_else(fn() { @signals.untracked(fn() { @sf.theme().chat_list.row_h }) })
  let held = l.keyed_by(lines, fn(p) { p.key })
  let keys = @signals.computed(fn(_) { held.keys().copy() })
  l.scrolls_reused(
    @view.Scroll::list(),
    fn() { keys.get() },
    shape~,
    est~,
    slop=@ui.touch_slop(),
    bar=@ui.tree_scroll_bar(),
    // (the room under its last: the list's end_room, no block of it, so lines told after it shows come in under its
    // top, never over a block of room alone in it)
    end_room=fn() { @sf.list_foot_in(list_at) },
    fn(b, k) {
      b.box(fn(back) {
        back.margin(Is((-side_into_rail, 0.0, 0.0, 0.0))) |> ignore
        @sf.style_node(back, fn() { @sf.theme().chat_list.side_list.then(@ui.style(h=Hug)) })
        make(back, k, fn() { held.get(k()) })
      })
      |> ignore
    },
  )
  |> ignore
}

///|
/// A heading line's words, as its line holds them (place_list_node's `data`: its words alone).
fn heading_words(d : Json?) -> String {
  match d {
    Some(String(s)) => s
    _ => ""
  }
}
