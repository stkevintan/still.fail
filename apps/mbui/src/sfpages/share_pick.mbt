// Which stations may use a shared account (可用的 station), for one account's page (pick_stations) and for the
// profiles' 多选 (pick_stations_many): every station, the workspace's whitelist (the stations taking automatically
// assigned chats, followed as it changes: the station's `allowAuto`), or those ticked by hand. One dialog for both,
// so the two say the same and choose the same.

///|
/// What a 可用的 station dialog is choosing: the workspace's stations (ShareStation, or a station's row: `id`, `name`,
/// `online`, `acceptAutoChats`, `tasksOnly`), the one that has the account (`own`, ticked and not to be unticked; ""
/// where the accounts are on several stations), which others are ticked, every station as it was said with none
/// other than `own` to tick (`future_all`), and whether it follows the whitelist (`follow`, offered where `auto_ok`).
priv struct SharePick {
  stations : Array[Json]
  own : String
  ticked : @sf.LiveMap[String, Bool]
  future_all : @signals.Signal[Bool]
  follow : @signals.Signal[Bool]
  auto_ok : Bool
}

///|
/// A station on the workspace's whitelist as its item says it: it takes automatically assigned chats and does not
/// only run tasks (the core's `onWhitelist`, the station's `autoAllow`).
fn share_on_whitelist(x : Json) -> Bool {
  flag(Some(x), "acceptAutoChats") && !flag(Some(x), "tasksOnly") && text(Some(x), "mode") != "tasks"
}

///|
fn SharePick::others(self : SharePick) -> Bool {
  self.stations.iter().any(fn(x) { text(Some(x), "id") != self.own })
}

///|
/// Every station ticked (none but `own`: as said), not following the whitelist.
fn SharePick::all(self : SharePick) -> Bool {
  if self.follow.get() {
    return false
  }
  if self.others() {
    self.stations.iter().all(fn(x) {
      let xid = text(Some(x), "id")
      xid == self.own || self.ticked.get(xid).unwrap_or(false)
    })
  } else {
    self.future_all.get()
  }
}

///|
/// Whether anything more than `own` is chosen: every station, the whitelist (a rule, even while it names none), or one
/// ticked.
fn SharePick::any(self : SharePick) -> Bool {
  self.all() ||
  self.follow.get() ||
  self.stations.iter().any(fn(x) {
    let xid = text(Some(x), "id")
    xid != self.own && self.ticked.get(xid).unwrap_or(false)
  })
}

///|
/// How many stations are on the whitelist now (`own` counted where it is on it).
fn SharePick::listed(self : SharePick) -> Int {
  self.stations.iter().filter(share_on_whitelist).count()
}

///|
/// Ticks every station other than `own` as `ticked` says of it.
fn SharePick::tick_all(self : SharePick, ticked : (Json) -> Bool) -> Unit {
  for x in self.stations {
    let xid = text(Some(x), "id")
    if xid != self.own {
      self.ticked.set(xid, ticked(x))
    }
  }
}

///|
/// The stations ticked besides `own`, as ids.
fn SharePick::picked(self : SharePick) -> Array[String] {
  self.stations.filter_map(fn(x) {
    let xid = text(Some(x), "id")
    if xid != self.own && self.ticked.get(xid).unwrap_or(false) {
      Some(xid)
    } else {
      None
    }
  })
}

///|
/// A pick of `stations` for the account on `own`: following the whitelist (`follow`), its rows showing the stations on
/// it; else every station (`allowed` None, not `initial`); else those `allowed` names; a first share only `own`.
fn share_pick_of(stations : Array[Json], own : String, allowed : Array[String]?, initial : Bool, follow : Bool, auto_ok : Bool) -> SharePick {
  let ticked : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  for x in stations {
    let xid = text(Some(x), "id")
    ticked.put(
      xid,
      if follow {
        xid == own || share_on_whitelist(x)
      } else if initial {
        xid == own
      } else {
        match allowed {
          None => true
          Some(a) => a.contains(xid)
        }
      },
    )
  }
  {
    stations,
    own,
    ticked,
    future_all: @signals.signal(!initial && !follow && allowed is None),
    follow: @signals.signal(follow && auto_ok),
    auto_ok,
  }
}

///|
/// The dialog's choice in node `v`: 全部 station and 跟随工作区白名单 (one or the other, the rows following what is
/// chosen), then each station, ticking one by hand choosing by hand (`own` ticked, not to be unticked, 此 station).
fn share_pick_node(v : @view.View, pick : SharePick) -> Unit {
  @sf.group_node(v, fn(g) {
    @sf.switch_row_node(
      g,
      fn() { @sf.t("web-pages.profiles.share.allStations") },
      fn() { pick.all() },
      fn(now) {
        pick.follow.set(false)
        pick.future_all.set(now)
        pick.tick_all(fn(_) { now })
      },
      note=fn() {
        if pick.all() {
          @sf.t("web-pages.profiles.share.futureIn")
        } else {
          @sf.t("web-pages.profiles.share.futureOut")
        }
      },
    )
    @sf.switch_row_node(
      g,
      fn() { @sf.t("web-pages.profiles.share.followAuto") },
      fn() { pick.follow.get() },
      fn(now) {
        pick.follow.set(now)
        if now {
          pick.future_all.set(false)
          pick.tick_all(share_on_whitelist)
        }
      },
      note=fn() {
        if !pick.auto_ok {
          @sf.t("web-pages.profiles.share.followAutoOld")
        } else if pick.listed() == 0 {
          @sf.t("web-pages.profiles.share.followAutoEmpty")
        } else {
          @sf.t("web-pages.profiles.share.followAutoNote", args=[("n", pick.listed().to_string())])
        }
      },
      disabled=fn() { !pick.auto_ok },
    )
  })
  @sf.group_node(v, fn(g) {
    g.each(fn() { pick.stations.mapi(fn(i, x) { (i, x) }) }, fn(x) { x.0 }, fn(row, x) {
      let xv = Some(x.untracked().1)
      let xid = text(xv, "id")
      let self = xid == pick.own
      @sf.switch_row_node(
        row,
        fn() { text(xv, "name") },
        fn() { self || pick.ticked.get(xid).unwrap_or(false) },
        fn(now) {
          if !self {
            // (chosen by hand: no longer every station nor the whitelist, the others as they were)
            pick.follow.set(false)
            pick.ticked.set(xid, now)
          }
        },
        note=fn() {
          if self {
            @sf.t("web-pages.profiles.share.here")
          } else if flag(xv, "online") {
            ""
          } else {
            @sf.t("web-pages.stations.offline")
          }
        },
        disabled=fn() { self },
      )
    })
  })
}

///|
/// What `profile.share` is asked for one account on `own` once the pick is said: on, and following the whitelist,
/// every station (no `allow`), or those ticked with `own`; `among` the stations chosen from where it was shared already
/// (only theirs change: a choice made in another workspace stays), none for a first share (as it is said whole).
fn SharePick::params(self : SharePick, address : String, id : String, own : String, shared : Bool) -> Json {
  let params = [("station", str(address)), ("id", str(id)), ("on", Json::boolean(true))]
  if self.follow.get() {
    params.push(("allowAuto", Json::boolean(true)))
    return obj(params)
  }
  if !self.all() {
    let allow : Array[Json] = [str(own)]
    for s in self.picked() {
      if s != own {
        allow.push(str(s))
      }
    }
    params.push(("allow", Json::array(allow)))
  }
  if shared {
    params.push(("among", Json::array(self.stations.map(fn(x) { str(text(Some(x), "id")) }))))
  }
  obj(params)
}

///|
/// 可用的 station of the account `id` on station `address` (whose id is `own`): every station, the whitelist
/// (`follow`, where the station can, `auto_ok`), or those ticked; a first share's (`initial`) with its confirmation's
/// words, a Claude subscription's warning with them.
fn pick_stations(
  core : Core,
  address : String,
  id : String,
  stations : Array[Json],
  own : String,
  allowed : Array[String]?,
  initial? : Bool = false,
  subscription? : Bool = false,
  claude? : Bool = false,
  follow? : Bool = false,
  auto_ok? : Bool = false,
) -> Unit {
  let pick = share_pick_of(stations, own, allowed, initial, follow, auto_ok)
  let title = if initial {
    if claude {
      @sf.t("web-pages.profiles.share.confirmClaudeTitle")
    } else {
      @sf.t("web-pages.profiles.share.confirmTitle")
    }
  } else {
    @sf.t("web-pages.profiles.share.stations")
  }
  let description = if initial {
    if claude {
      @sf.t("web-pages.profiles.share.confirmClaudeBody")
    } else if subscription {
      @sf.t("web-pages.profiles.share.confirmSubscriptionBody")
    } else {
      @sf.t("web-pages.profiles.share.confirmCopyBody")
    }
  } else {
    ""
  }
  open_dialog_nodes(
    title,
    description~,
    fn(v, _) {
      if initial && claude {
        @sf.page_note_node(v, fn() { @sf.t("web-pages.profiles.share.confirmClaudeWarning") }, bad=fn() { true })
      }
      share_pick_node(v, pick)
    },
    fn(v, shut) {
      if initial {
        @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      }
      @sf.button_node(
        v,
        fn() {
          if initial {
            if claude {
              @sf.t("web-pages.profiles.share.confirmUnderstood")
            } else {
              @sf.t("web-pages.profiles.share.confirmAction")
            }
          } else {
            @sf.t("web-pages.profiles.share.done")
          }
        },
        fn() {
          shut()
          let params = pick.params(address, id, own, !initial)
          if initial {
            @settings.act(
              core,
              @sf.t("web-pages.profiles.share.switch"),
              "profile.share",
              params,
              done=@sf.t("web-pages.profiles.share.shared"),
            )
          } else {
            @settings.act(core, @sf.t("web-pages.profiles.share.stations"), "profile.share", params)
          }
        },
        tone=Primary,
        disabled=fn() { initial && !pick.any() },
      )
      |> ignore
    },
  )
}

// ── several accounts at once: the profiles' 多选 ─────────────────────────

///|
/// The station id of a station's address (`<workspace>/<id>`).
fn share_station_id(address : String) -> String {
  match address.find("/") {
    Some(i) => address.exact_view(start=i + 1).to_owned()
    None => address
  }
}

///|
/// What the 多选's main button says of the accounts `rows` (the list's ProfileRows): 开启分享 where none is shared,
/// 可用 station where all are, 分享与 station where some are.
pub fn profiles_batch_label(rows : Array[Json]) -> String {
  let shared = rows.iter().filter(fn(r) { flag(Some(r), "shared") }).count()
  if shared == 0 {
    @sf.t("web-pages.profiles.batch.share")
  } else if shared == rows.length() {
    @sf.t("web-pages.profiles.batch.stations")
  } else {
    @sf.t("web-pages.profiles.batch.mixed")
  }
}

///|
/// Why the 多选 cannot take an account, in words (its row's `batchShareWhy`); "" where it can.
pub fn profiles_batch_why(row : Json?) -> String {
  match text(row, "batchShareWhy") {
    "" => ""
    why => @sf.t("web-pages.profiles.batch.why." + why)
  }
}

///|
/// `profile.share` asked of each of `asks` (its station's address, the account's id, what is asked) one after another,
/// then `done` told which failed (each account's key, with its error in words); none waits on another's answer to be
/// asked, the summary once all are in.
fn share_each(core : Core, asks : Array[(String, Json)], done : (Array[(String, String)]) -> Unit) -> Unit {
  let failed : Array[(String, String)] = []
  let left = Ref(asks.length())
  if asks.length() == 0 {
    done(failed)
    return
  }
  for ask in asks {
    let (key, params) = ask
    (core.call)("profile.share", params, fn(r) {
      match r {
        Ok(_) => ()
        Err(e) => failed.push((key, error_text(e)))
      }
      left.val -= 1
      if left.val == 0 {
        done(failed)
      }
    })
  }
}

///|
/// Says how the 多选's change went: all done (`n`), or how many and which failed, once.
fn share_said(core : Core, n : Int, failed : Array[(String, String)]) -> Unit {
  if failed.length() == 0 {
    (core.say)(@sf.t("web-pages.profiles.batch.done", args=[("n", n.to_string())]))
    @ui.haptic(Confirm)
  } else {
    @ui.haptic(Reject)
    (core.say)(
      @sf.t(
        "web-pages.profiles.batch.partial",
        args=[("ok", (n - failed.length()).to_string()), ("failed", failed.length().to_string()), ("why", failed[0].1)],
      ),
    )
  }
}

///|
/// The 多选's 可用的 station for the accounts `rows` (ProfileRows it can take, `canBatchShare`) of the workspace's
/// `stations` (its stations' rows): one pick for all of them, those not shared shared with it (a Claude subscription
/// among them warned of first), each account's own station keeping it. `busy` while asked; `done` told the keys of
/// those that failed (none: all done).
pub fn pick_stations_many(
  core : Core,
  rows : Array[Json],
  stations : Array[Json],
  busy : @signals.Signal[Bool],
  done : (Array[String]) -> Unit,
) -> Unit {
  let hosts : Array[String] = []
  for r in rows {
    let h = share_station_id(text(Some(r), "station"))
    if !hosts.contains(h) {
      hosts.push(h)
    }
  }
  let own = if hosts.length() == 1 { hosts[0] } else { "" }
  let unshared = rows.filter(fn(r) { !flag(Some(r), "shared") })
  let claude = unshared.iter().any(fn(r) {
    let p = field(Some(r), "profile")
    text(p, "runtime") == "claude" && text(field(p, "access"), "kind") == "subscription"
  })
  let auto_ok = rows.iter().all(fn(r) { flag(Some(r), "batchShareAllowAuto") })
  let follow = auto_ok && rows.iter().all(fn(r) { flag(Some(r), "shareAuto") })
  let pick = share_pick_of(stations, own, None, true, follow, auto_ok)
  let title = if unshared.length() > 0 && claude {
    @sf.t("web-pages.profiles.share.confirmClaudeTitle")
  } else {
    profiles_batch_label(rows)
  }
  let description = @sf.t("web-pages.profiles.batch.applies", args=[("n", rows.length().to_string())])
  open_dialog_nodes(
    title,
    description~,
    fn(v, _) {
      if claude {
        @sf.page_note_node(v, fn() { @sf.t("web-pages.profiles.share.confirmClaudeWarning") }, bad=fn() { true })
      }
      if unshared.length() > 0 {
        @sf.page_note_node(v, fn() { @sf.t("web-pages.profiles.batch.sharesToo") })
      }
      if own == "" {
        @sf.page_note_node(v, fn() { @sf.t("web-pages.profiles.batch.ownKept") })
      }
      if !auto_ok {
        @sf.page_note_node(v, fn() { @sf.t("web-pages.profiles.batch.autoOld") })
      }
      share_pick_node(v, pick)
    },
    fn(v, shut) {
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      @sf.button_node(
        v,
        fn() {
          if claude {
            @sf.t("web-pages.profiles.share.confirmUnderstood")
          } else {
            @sf.t("web-pages.profiles.share.done")
          }
        },
        fn() {
          shut()
          let asks = rows.map(fn(r) {
            let rv = Some(r)
            let address = text(rv, "station")
            (
              text(rv, "key"),
              pick.params(address, text(field(rv, "profile"), "id"), share_station_id(address), flag(rv, "shared")),
            )
          })
          busy.set(true)
          share_each(core, asks, fn(failed) {
            busy.set(false)
            share_said(core, asks.length(), failed)
            done(failed.map(fn(f) { f.0 }))
          })
        },
        tone=Primary,
        disabled=fn() { !pick.any() },
      )
      |> ignore
    },
  )
}

///|
/// The 多选's 停止分享 for the accounts `rows`: asked once, then each of those shared no longer shared (those not shared
/// left as they are). `busy` while asked; `done` told the keys of those that failed.
pub fn stop_sharing_many(core : Core, rows : Array[Json], busy : @signals.Signal[Bool], done : (Array[String]) -> Unit) -> Unit {
  let shared = rows.filter(fn(r) { flag(Some(r), "shared") })
  if shared.length() == 0 {
    return
  }
  @sf.confirm(
    @sf.t("web-pages.profiles.batch.stopTitle", args=[("n", shared.length().to_string())]),
    @sf.t("web-pages.profiles.batch.stopBody"),
    @sf.t("web-pages.profiles.batch.stop"),
    fn() {
      let asks = shared.map(fn(r) {
        let rv = Some(r)
        (
          text(rv, "key"),
          obj([("station", str(text(rv, "station"))), ("id", str(text(field(rv, "profile"), "id"))), ("on", Json::boolean(false))]),
        )
      })
      busy.set(true)
      share_each(core, asks, fn(failed) {
        busy.set(false)
        share_said(core, asks.length(), failed)
        done(failed.map(fn(f) { f.0 }))
      })
    },
    danger=true,
  )
}
