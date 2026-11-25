// The profiles' 多选 (profiles_list_node's, sfdesk's profiles_side_node's): a workspace manager picks several accounts
// and shares them, sets which stations may use them (every station, the workspace's whitelist, or those ticked) or
// stops sharing them, all at once. One state and one bar for both lists, so the two say and do the same.

///|
/// A list's 多选: whether it is on, which accounts are picked (by their row's key), and whether what was asked of them
/// is under way.
pub struct ProfilesBatch {
  on : @signals.Signal[Bool]
  chosen : @sf.LiveMap[String, Bool]
  busy : @signals.Signal[Bool]
}

///|
pub fn ProfilesBatch::new() -> ProfilesBatch {
  { on: @signals.signal(false), chosen: @sf.LiveMap::new(), busy: @signals.signal(false) }
}

///|
/// 多选 begun, nothing picked.
pub fn ProfilesBatch::start(self : ProfilesBatch) -> Unit {
  self.chosen.clear()
  self.on.set(true)
}

///|
/// 多选 over (取消, or all asked of them done), nothing picked.
pub fn ProfilesBatch::stop(self : ProfilesBatch) -> Unit {
  self.chosen.clear()
  self.on.set(false)
}

///|
/// 多选 begun, or over where it is on (its entry pressed again).
pub fn ProfilesBatch::toggle(self : ProfilesBatch) -> Unit {
  if self.on.get() {
    self.stop()
  } else {
    self.start()
  }
}

///|
/// Whether the account of key `key` is picked.
pub fn ProfilesBatch::picked(self : ProfilesBatch, key : String) -> Bool {
  self.chosen.get(key).unwrap_or(false)
}

///|
/// Of the list's rows (`rows`, ProfileRows or rows made as one: profiles_batch_row), those picked that it can take.
fn ProfilesBatch::rows(self : ProfilesBatch, rows : Array[Json]) -> Array[Json] {
  rows.filter(fn(r) { flag(Some(r), "canBatchShare") && self.picked(text(Some(r), "key")) })
}

///|
/// Whether 多选 is offered: to a workspace's owners and admins (`manages`: as the workspace's list says it, the
/// `profiles` topic's, so the place reads nothing more for it), where it lists an account.
pub fn profiles_batch_offered(manages : () -> Bool, rows : () -> Array[Json]) -> Bool {
  manages() && rows().length() > 0
}

///|
/// A station's own profile `p` (station `address`'s, its overview `o`, the station's row `s`) as the 多选 takes a row
/// of the workspace's list (ProfileRow's `key`, `station`, `profile`, `shared`, `shareAuto`, `canBatchShare`,
/// `batchShareAllowAuto`, `batchShareWhy`): a station's page lists its profiles, not the workspace's rows. A copy of
/// another station's is not this station's to share; one signed in on several is this station's here.
pub fn profiles_batch_row(address : String, p : Json, o : Json?, s : Json?) -> Json {
  let pv = Some(p)
  let share = field(pv, "share")
  let why = if text(share, "role") == "user" {
    "borrowed"
  } else if !flag(o, "sharing") {
    "unsupported"
  } else if !flag(s, "online") {
    "offline"
  } else if !(share is Some(Object(_))) && field(pv, "shareable") is Some(False) {
    "unshareable"
  } else {
    ""
  }
  let out : Map[String, Json] = {
    "key": str(text(pv, "id")),
    "station": str(address),
    "profile": p,
    "title": str(text(pv, "name")),
    "shared": Json::boolean(share is Some(Object(_))),
    "shareAuto": Json::boolean(flag(share, "allowAuto")),
    "canBatchShare": Json::boolean(why == ""),
    "batchShareAllowAuto": Json::boolean(flag(o, "shareAllowAuto")),
  }
  if why != "" {
    out["batchShareWhy"] = str(why)
  }
  Json::object(out)
}

///|
/// An account's name as its row says it out of 多选 (pl_account_row_node's, profile_side_row_node's): its profile's
/// name, else the account's title, so that its name stays as 多选 begins.
fn profiles_batch_name(e : Json?) -> String {
  match text(field(e, "profile"), "name") {
    "" => text(e, "title")
    n => n
  }
}

///|
/// An account's row of the profiles' sidebar while 多选 is on, in `line` (profiles_side_node's, as its rows are:
/// nav_item_node's, `list_at`, `more`): its vendor's mark, its box and its name, its plan after it, and where it
/// cannot be taken why, faint; pressed, picked or not (never its page).
pub fn profiles_batch_side_row_node(line : @view.View, list_at : @sf.ListAt, batch : ProfilesBatch, ev : () -> Json?, more : () -> Bool) -> Unit {
  let key = fn() { text(ev(), "key") }
  let can = fn() { flag(ev(), "canBatchShare") }
  let name = fn() { profiles_batch_name(ev()) }
  let plan = fn() { text(field(ev(), "profile"), "planText") }
  let why = fn() { if can() { "" } else { profiles_batch_why(ev()) } }
  let p = fn() { field(ev(), "profile") }
  @sf.nav_item_node(
    line,
    list_at,
    fn() { false },
    name,
    fn(_) {
      let k = @signals.untracked(key)
      if @signals.untracked(can) && !batch.busy.get() {
        batch.chosen.set(k, !batch.picked(k))
      }
    },
    fn(m) {
      @sfbase.provider_mark_node(m, fn() { (text(p(), "runtime"), text(field(p(), "access"), "kind"), text(p(), "providerMark")) }, @sf.nav_mark_side)
    },
    // (its box before its name on its first line, past the row's round corner: a box where its mark stands would sit
    // in that corner, off its curve)
    fn(t) {
      t.box(fn(c) {
        c.margin(Is((0.0, 0.0, pb_box_gap, 0.0))) |> ignore
        @sf.check_mark_node(c, fn() { can() && batch.picked(key()) }, dimmed=fn() { !can() })
      })
      |> ignore
      @sf.nav_title_node(t, name, away=fn() { !can() }, after=fn(a) { @sf.row_tag_node(a, plan) }, after_shown=fn() { plan() != "" })
    },
    lines=fn(ls) { ls.show(fn() { why() != "" }, fn(k) { @sf.list_row_line_node(k, fn(r) { @sf.nav_meta_node(r, why) }) }) },
    more~,
  )
}

///|
/// An account's row while 多选 is on, in `r`: its box ticked as it is picked, its vendor's mark, its name, and where it
/// cannot be taken why, dimmed and not to be ticked; pressed anywhere, picked or not (never its page).
pub fn profiles_batch_row_node(r : @view.View, batch : ProfilesBatch, ev : () -> Json?) -> Unit {
  let key = fn() { text(ev(), "key") }
  let can = fn() { flag(ev(), "canBatchShare") }
  let p = fn() { field(ev(), "profile") }
  r.box(fn(d) {
    d.alpha(By(fn() { if can() { 1.0 } else { pl_away } })) |> ignore
    // (the whole row its press, its box the mark at its start: a choice's row, as a list's picks are)
    @sf.choice_row_node(
      d,
      fn() { profiles_batch_name(ev()) },
      fn() { false },
      lead=fn(l) { @sf.check_mark_node(l, fn() { can() && batch.picked(key()) }, dimmed=fn() { !can() }) },
      press=fn() {
        let k = @signals.untracked(key)
        if @signals.untracked(can) && !batch.busy.get() {
          batch.chosen.set(k, !batch.picked(k))
        }
      },
      note=fn() { if can() { text(p(), "planText") } else { profiles_batch_why(ev()) } },
      disabled=fn() { !can() || batch.busy.get() },
    )
  })
  |> ignore
}

///|
/// The 多选's bar in `f` at the list's foot: how many are picked, 全选 (those it can take) or 取消全选, 取消; then what to
/// do with them, the main one first, at its start (wrapping back from its end where the room is short): share them or
/// set their stations (pick_stations_many), stop sharing those shared (stop_sharing_many). Both wait while one is
/// under way; done, 多选 is over, or those that failed stay picked to be asked again.
pub fn profiles_batch_bar_node(f : @view.View, core : Core, batch : ProfilesBatch, rows : () -> Array[Json], stations : () -> Array[Json]) -> Unit {
  let picked = fn() { batch.rows(rows()) }
  let can = fn() { rows().filter(fn(r) { flag(Some(r), "canBatchShare") }) }
  let all = fn() {
    let c = can()
    c.length() > 0 && c.iter().all(fn(r) { batch.picked(text(Some(r), "key")) })
  }
  let finished = fn(failed : Array[String]) {
    if failed.length() == 0 {
      batch.stop()
    } else {
      batch.chosen.clear()
      for k in failed {
        batch.chosen.set(k, true)
      }
    }
  }
  f.box(fn(col) {
    col.gap(Is(pb_gap)) |> ignore
    col.box(fn(head) {
      @sf.style_node(head, fn() { pb_head })
      head.height(By(fn() { Some(@sf.button_height()) })) |> ignore
      @sf.words_node(head, fn() { @sf.t("web-pages.profiles.batch.selected", args=[("n", picked().length().to_string())]) }, fn() {
        @sf.theme().rows.title
      })
      .grow(Is(1.0))
      |> ignore
      @sf.button_node(
        head,
        fn() { if all() { @sf.t("web-pages.profiles.batch.none") } else { @sf.t("web-pages.profiles.batch.all") } },
        fn() {
          let to = !@signals.untracked(all)
          for r in @signals.untracked(can) {
            batch.chosen.set(text(Some(r), "key"), to)
          }
        },
        tone=Ghost,
        disabled=fn() { batch.busy.get() || can().length() == 0 },
      )
      |> ignore
      @sf.button_node(head, fn() { @sf.t("common.cancel") }, fn() { batch.stop() }, tone=Ghost, disabled=fn() {
        batch.busy.get()
      })
      |> ignore
    })
    |> ignore
    // (at the card's foot, the main one in its corner, wrapping back from the end where the room is short: card_foot's)
    @sf.card_foot_node(col, fn(acts) {
      @sf.button_node(
        acts,
        // (one label whatever is picked, so that what stands beside it never moves as picks change: the dialog's title
        // says which, profiles_batch_label)
        fn() {
          @sf.t("web-pages.profiles.batch.mixed")
        },
        fn() {
          let now = @signals.untracked(picked)
          pick_stations_many(core, now, @signals.untracked(stations), batch.busy, finished)
        },
        tone=Primary,
        busy=fn() { batch.busy.get() },
        disabled=fn() { picked().length() == 0 || batch.busy.get() },
      )
      |> ignore
      @sf.button_node(
        acts,
        fn() { @sf.t("web-pages.profiles.batch.stop") },
        fn() { stop_sharing_many(core, @signals.untracked(picked), batch.busy, finished) },
        tone=GhostDanger,
        disabled=fn() { batch.busy.get() || !picked().iter().any(fn(r) { flag(Some(r), "shared") }) },
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// How tall the 多选's bar stands over a page's foot (profiles_batch_foot_node's, a page's): its card's room over and
/// under it, the card's top and footed foot, its head and its buttons a button's height each, the room between them.
/// What the page keeps under its list while 多选 is on (its frame's `foot`), so that its last row can come over it.
pub fn profiles_batch_room() -> Double {
  let bh = @sf.button_height()
  pb_gap + @sf.card_pad + bh + pb_gap + bh + @sf.card_foot_in(bh) + pb_gap
}

///|
/// The 多选's bar (profiles_batch_bar_node) in a card of its own at the foot of `v` while 多选 is on, `foot` the room
/// under it the frame keeps (a bar floating over the page's foot): a `page`'s in from its sides as its cards are, as wide
/// as `width` (page_lane_node's); else (a sidebar's) `side` in, as its rows are.
pub fn profiles_batch_foot_node(
  v : @view.View,
  core : Core,
  batch : ProfilesBatch,
  rows : () -> Array[Json],
  stations : () -> Array[Json],
  foot? : () -> Double = fn() { 0.0 },
  page? : Bool = false,
  width? : () -> Double,
  side? : Double = 0.0,
) -> Unit {
  // (a page's card, its buttons at its foot concentric with its corners: page_card's footed)
  let card = fn(c : @view.View, glass : Bool) {
    @sf.page_card_node(c, footed=true, layered=true, glass~, fn(k) { profiles_batch_bar_node(k, core, batch, rows, stations) })
  }
  v.show(fn() { batch.on.get() }, fn(w) {
    w.padding(By(fn() { (0.0, pb_gap, 0.0, pb_gap + foot()) })) |> ignore
    match page {
      // (a page's: over its foot, its list kept clear of it by the room it keeps there, profiles_batch_room)
      true => {
        w.over(Is(true), edges=(Some(0.0), None, Some(0.0), Some(0.0))) |> ignore
        @sf.page_lane_node(w, width, fn(c) { card(c, true) })
      }
      false =>
        w.box(fn(x) {
          x.padding(Is((side, 0.0, side, 0.0))) |> ignore
          card(x, false)
        })
        |> ignore
    }
  })
}

///|
// kept across runs: a value (no field of it changes)
let pb_head : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
/// The room above and below the bar's card (card_foot_gap's).
let pb_gap : Double = 8.0

///|
/// The room between a sidebar row's box and its name (a list row's mark's gap to its words, list_row_marked's S2).
let pb_box_gap : Double = 8.0
