// Where a new chat runs (station picker, opened from new_chat_node.mbt):
// - Fewer than `station_table_from` stations: lightweight anchored popover (420pt on Medium/Large, bottom sheet on Small)
//   with optional "Auto" row + hairline divider + compact two-line station rows (no search bar so it opens lightly
//   without taking focus or raising an IME).
// - `station_table_from` or more stations: 740pt centered modal on Medium/Large (bottom sheet on Small), adapting via
//   `@sf.in_dialog_node(n)` between a searchable sortable multi-column table and a searchable compact two-line drawer.

///|
/// Station count at which the picker upgrades from a compact anchored popover to a searchable wide table / drawer.
let station_table_from : Int = 6

///|
/// Table column widths (pt) shared strictly between header cells and data cells.
let sp_col_running_w : Double = 56.0

///|
let sp_col_cpu_w : Double = 52.0

///|
let sp_col_mem_w : Double = 70.0

///|
let sp_col_disk_w : Double = 68.0

///|
let sp_col_net_w : Double = 128.0

///|
let sp_mark_size : Double = 16.0

///|
let sp_mark_slot_w : Double = 18.0

///|
let sp_table_body_max_h : Double = 396.0

///|
let sp_table_row_min_h : Double = 36.0

///|
let sp_table_row_pad_y : Double = 14.0

///|
#derive(Eq)
priv enum StationSortCol {
  Name
  Running
  Cpu
  Memory
  Disk
  Network
}

///|
priv struct StationPickEntry {
  index : Int
  key : String
  id : String
  name : String
  station : Json
  net : @signals.Computed[@sfbase.TopicState]
}

///|
/// Open the station picker for a new chat (`new_station_control_node` and `new_auto_empty_node`).
pub fn open_station_picker(src : Source, w : Workspace, v : Json?, from~ : @sf.Anchor) -> Unit {
  let stations = items(v, "stations")
  if stations.length() < station_table_from {
    let side : @ui.Side = match from {
      Node(b) => choice_side(Node(b))
      _ => Bottom
    }
    @sf.panel_nodes(
      @sf.t("android-chat.new.station.pick"),
      fn(n, close) { station_few_picker_node(n, src, w, v, close) },
      from~,
      side~,
      w=420.0,
    )
  } else {
    @sf.panel_nodes(
      @sf.t("android-chat.new.station.pick"),
      fn(n, close) { station_many_picker_node(n, src, w, v, close) },
      from=Unanchored,
      w=740.0,
      wide=true,
      hugs_centred=true,
    )
  }
}

///|
/// Parse a leading non-negative decimal number from a string (e.g. "38 ms" -> 38.0, "5.8" -> 5.8).
fn sp_parse_leading_double(s : String) -> Double? {
  let chars = s.trim().to_owned().to_array()
  let mut i = 0
  let mut whole = 0.0
  let mut frac = 0.0
  let mut scale = 0.1
  let mut seen_dot = false
  let mut seen_digit = false
  while i < chars.length() {
    let c = chars[i]
    if c >= '0' && c <= '9' {
      let d = (c.to_int() - '0'.to_int()).to_double()
      seen_digit = true
      if seen_dot {
        frac = frac + d * scale
        scale = scale * 0.1
      } else {
        whole = whole * 10.0 + d
      }
      i += 1
    } else if c == '.' && !seen_dot {
      seen_dot = true
      i += 1
    } else {
      break
    }
  }
  if seen_digit { Some(whole + frac) } else { None }
}

///|
/// Normalize a memory/disk meter's remaining amount into GB for sorting.
fn sp_meter_gb(m : Json?) -> Double? {
  guard sp_parse_leading_double(text(m, "big")) is Some(v) else { return None }
  let unit = text(m, "unit").to_upper()
  if unit.has_prefix("T") {
    Some(v * 1024.0)
  } else if unit.has_prefix("M") {
    Some(v / 1024.0)
  } else if unit.has_prefix("K") {
    Some(v / (1024.0 * 1024.0))
  } else {
    Some(v)
  }
}

///|
/// Pick the meter for a kind: 0 = CPU, 1 = Memory, 2 = Disk.
fn sp_meter_of(meters : Array[Json], kind : Int) -> Json? {
  let want = fn(m : Json) -> Bool {
    let s = text(Some(m), "short")
    match kind {
      0 => s == "CPU"
      1 => s == "内存" || s == "Mem" || s == "Memory"
      _ => s == "磁盘" || s == "Disk"
    }
  }
  match meters.iter().find_first(want) {
    Some(m) => Some(m)
    None => meters.get(kind)
  }
}

///|
/// Compact meter string for two-line rows: e.g. "CPU 72%", "内存 5.8G", "磁盘 380G".
fn sp_meter_compact(m : Json?) -> String {
  let short = text(m, "short")
  let big = text(m, "big")
  let unit = text(m, "unit")
  let fig = if big != "" {
    big + (if unit == "%" || unit == "" { unit } else { unit.clamped_view(end=1).to_owned() })
  } else {
    text(m, "remaining")
  }
  if short != "" && fig != "" {
    short + " " + fig
  } else if fig != "" {
    fig
  } else {
    short
  }
}

///|
/// Table cell meter figure: e.g. "72%", "5.8 GB", "380 GB", or "—" when missing.
fn sp_meter_wide(m : Json?) -> String {
  let big = text(m, "big")
  let unit = text(m, "unit")
  if big != "" {
    if unit == "%" || unit == "" {
      big + unit
    } else {
      big + " " + unit
    }
  } else {
    match text(m, "remaining") {
      "" => "—"
      r => r
    }
  }
}

///|
/// Network status string in compact two-line rows (no middle dot): "直连 38ms" / "香港中继 459ms" / "未连接".
fn sp_net_compact(net : Json?) -> String {
  match net {
    Some(Object(_)) =>
      match text(field(net, "rtt"), "text") {
        "" => text(net, "path")
        rtt => text(net, "path") + " " + rtt.replace(old=" ms", new="ms")
      }
    _ => @sf.t("web-pages.stations.netNone")
  }
}

///|
/// Network status string in wide table cells: "直连 38 ms" / "香港中继 459 ms" / "未连接".
fn sp_net_wide(net : Json?) -> String {
  match net {
    Some(Object(_)) =>
      match text(field(net, "rtt"), "text") {
        "" => text(net, "path")
        rtt => text(net, "path") + " " + rtt
      }
    _ => @sf.t("web-pages.stations.netNone")
  }
}

///|
/// Parse network RTT in ms for sorting; disconnected or missing returns None.
fn sp_net_rtt_ms(net : Json?) -> Double? {
  match net {
    Some(Object(_)) => sp_parse_leading_double(text(field(net, "rtt"), "text"))
    _ => None
  }
}

///|
/// Text style for a meter level in compact two-line rows.
fn sp_compact_meter_style(level : String) -> @ui.TextStyle {
  match level {
    "red" => sp_meta_danger
    "amber" => sp_meta_warn
    _ => sp_meta_muted
  }
}

///|
/// Text style for a meter level in wide table cells.
fn sp_table_meter_style(level : String) -> @ui.TextStyle {
  match level {
    "red" => sp_cell_danger
    "amber" => sp_cell_warn
    _ => sp_cell_fg
  }
}

///|
/// Station mark (16pt) or fallback server icon, aligned to the first line's height.
fn sp_station_mark_box(parent : @view.View, st : Json?, single_line? : Bool = false) -> Unit {
  parent.box(fn(m) {
    m
    .width(Is(Some(sp_mark_slot_w)))
    .height(By(fn() { Some(if single_line { sp_mark_slot_w } else { @sf.theme().t.ui_line }) }))
    .shrink(Is(0.0))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    |> ignore
    if @sf.has_station_mark(text(st, "emoji"), text(st, "icon")) {
      @sf.station_mark_node(
        m,
        fn() { text(st, "emoji") },
        fn() { text(st, "icon") },
        sp_mark_size,
        fn() { @sf.theme().p.text },
        fn() { 0 },
      )
    } else {
      @sf.icon_node(m, "server", sp_mark_size, By(fn() { @sf.theme().p.text })) |> ignore
    }
  })
  |> ignore
}

///|
/// Top "Auto" assignment row for compact list and narrow drawer, followed by a hairline divider when stations follow.
fn sp_auto_row_node(
  parent : @view.View,
  src : Source,
  w : Workspace,
  pool : Int,
  is_auto : Bool,
  has_below : () -> Bool,
  close : () -> Unit,
) -> Unit {
  let press = fn() {
    @sfbase.pick_new(src, w.id, { "autoStation": Json::boolean(true) })
    close()
  }
  @sf.action_box_node(
    parent,
    fn() { @sf.t("web-main.newChat.autoStation") },
    fn(_) { press() },
    check=fn() { if is_auto { On } else { Off } },
    fn(row) {
      @sf.style_node(row, fn() { sp_compact_row.then(@sf.panel_row_in_node(row)) })
      @sf.hover_ground_node(row, lit=Some(fn() { @sf.hovered_in_node(row) || row.focus_shown() }))
      @sf.rippled_node(row, press, @sf.row_corner, fn() { @sf.t("web-main.newChat.autoStation") })
      row.box(fn(m) {
        m
        .width(Is(Some(sp_mark_slot_w)))
        .height(By(fn() { Some(@sf.theme().t.ui_line) }))
        .shrink(Is(0.0))
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        |> ignore
        @sf.icon_node(m, "sparks", sp_mark_size, By(fn() { @sf.theme().p.accent_text })) |> ignore
      })
      |> ignore
      row.box(fn(col) {
        @sf.style_node(col, fn() { sp_compact_col }, in_row=true)
        col.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        col.box(fn(head) {
          @sf.style_node(head, fn() { sp_compact_head })
          @sf.words_node(head, fn() { @sf.t("web-main.newChat.autoStation") }, fn() { sp_row_name })
          .grow(Is(1.0))
          .basis(Is(Some(0.0)))
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          .cuts(Is(true))
          .allow_ellipsis(Is(true))
          |> ignore
          if is_auto {
            @sf.icon_node(head, "check", new_mark, By(fn() { @sf.theme().p.accent })) |> ignore
          }
        })
        |> ignore
        @sf.words_node(
          col,
          fn() { @sf.t("web-main.newChat.autoStationHint", args=[("n", pool.to_string())]) },
          fn() { sp_auto_hint },
        )
        |> ignore
      })
      |> ignore
    },
  )
  |> ignore
  parent.show(at_once=true, has_below, fn(d) {
    @sf.style_node(d, fn() { sp_divider_wrap })
    d.box(fn(line) { @sf.style_node(line, fn() { @sf.rule_line }) }) |> ignore
  })
}

///|
/// Compact two-line station row (used by `< 6` popover/sheet and `>= 6` narrow drawer).
fn sp_compact_station_row_node(
  parent : @view.View,
  src : Source,
  w : Workspace,
  st : Json?,
  net : @signals.Computed[@sfbase.TopicState],
  busy : @signals.Computed[Bool],
  here : Bool,
  highlighted : () -> Bool,
  close : () -> Unit,
) -> Unit {
  let tips = parent.lent(@sf.panel_tips_lent)
  let name = text(st, "name")
  let id = text(st, "id")
  let online = flag(st, "online")
  let press = fn() {
    @sfbase.pick_new(src, w.id, { "station": Json::string(id) })
    close()
  }
  let meters = @signals.computed(fn(_) { @settings.meters_said(items(field(st, "host"), "meters"), busy.get()) })
  @sf.action_box_node(
    parent,
    fn() { name },
    fn(_) { press() },
    check=fn() { if here { On } else { Off } },
    fn(row) {
      @sf.style_node(row, fn() { sp_compact_row.then(@sf.panel_row_in_node(row)) })
      @sf.hover_ground_node(
        row,
        lit=Some(fn() { @sf.hovered_in_node(row) || row.focus_shown() }),
        extra=highlighted,
      )
      @sf.rippled_node(row, press, @sf.row_corner, fn() { name })
      sp_station_mark_box(row, st)
      row.box(fn(col) {
        @sf.style_node(col, fn() { sp_compact_col }, in_row=true)
        col.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        col.box(fn(head) {
          @sf.style_node(head, fn() { sp_compact_head })
          let name_v = @sf.words_node(head, fn() { name }, fn() { sp_row_name })
            .grow(Is(1.0))
            .basis(Is(Some(0.0)))
            .shrink(Is(1.0))
            .min_width(Is(Some(0.0)))
            .cuts(Is(true))
            .allow_ellipsis(Is(true))
          if tips is Some(tl) {
            @sf.tip_node(tl, name_v, fn() { name }, within=true, repeats=true, pressed=fn() { row.pressed() }) |> ignore
          }
          station_state_node(head, fn() { st })
          if here {
            @sf.icon_node(head, "check", new_mark, By(fn() { @sf.theme().p.accent })) |> ignore
          }
        })
        |> ignore
        if online {
          col.box(fn(sub) {
            @sf.style_node(sub, fn() { sp_compact_sub })
            sub.fits(Is(true)) |> ignore
            for kind in [0, 1, 2] {
              let m = fn() { sp_meter_of(meters.get(), kind) }
              sub.show(at_once=true, fn() { m() is Some(_) }, fn(mb) {
                let drop_rank = fn() {
                  let lvl = text(m(), "level")
                  let is_low = lvl == "amber" || lvl == "red"
                  match kind {
                    2 => if is_low { 4 } else { 1 }
                    1 => if is_low { 5 } else { 2 }
                    _ => if is_low { 0 } else { 3 }
                  }
                }
                mb.shrink(Is(0.0)).fit_whole(Is(true)).drops(By(drop_rank)) |> ignore
                @sf.words_node(
                  mb,
                  fn() { sp_meter_compact(m()) },
                  fn() { sp_compact_meter_style(text(m(), "level")) },
                )
                |> ignore
              })
            }
            sub.box(fn(sp) { sp.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore }) |> ignore
            sub.box(fn(nb) {
              nb.shrink(Is(0.0)).fit_whole(Is(true)) |> ignore
              @sf.words_node(nb, fn() { sp_net_compact(net.get().value) }, fn() { sp_meta_muted }) |> ignore
            })
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    },
  )
  |> ignore
}

///|
/// `< 6` stations: lightweight anchored popover (or bottom sheet on Small), no search bar.
fn station_few_picker_node(n : @view.View, src : Source, w : Workspace, v : Json?, close : () -> Unit) -> Unit {
  let current = text(field(v, "station"), "station")
  let is_auto = flag(v, "autoStation")
  let pool = count(v, "autoPoolCount")
  let stations = items(v, "stations")
  let busy = @signals.computed(fn(_) { cpu_busy(src) })
  if pool > 0 && !flag(v, "presetStations") {
    sp_auto_row_node(n, src, w, pool, is_auto, fn() { stations.length() > 0 }, close)
  }
  for s in stations {
    let st = Some(s)
    let addr = text(st, "station")
    let net = src.topic("stationNet", { "station": Json::string(addr) })
    let here = !is_auto && addr == current
    sp_compact_station_row_node(n, src, w, st, net, busy, here, fn() { false }, close)
  }
}

///|
/// Whether an entry matches the current search query (matches station name, network path/rtt, or summary).
fn sp_entry_matches(q : String, entry : StationPickEntry) -> Bool {
  let needle = q.trim().to_owned().to_lower()
  if needle == "" {
    return true
  }
  if entry.name.to_lower().contains(needle) {
    return true
  }
  if sp_net_wide(entry.net.get().value).to_lower().contains(needle) {
    return true
  }
  text(Some(entry.station), "summary").to_lower().contains(needle)
}

///|
/// Default sort direction on first click of a column header.
fn sp_default_asc(col : StationSortCol) -> Bool {
  match col {
    Name | Running | Cpu | Network => true
    Memory | Disk => false
  }
}

///|
/// Compare two optional numbers, always keeping None at the bottom regardless of `asc`.
fn sp_cmp_opt_double(a : Double?, b : Double?, asc : Bool) -> Int {
  match (a, b) {
    (None, None) => 0
    (None, Some(_)) => 1
    (Some(_), None) => -1
    (Some(x), Some(y)) =>
      if (x - y).abs() < 1.0e-9 {
        0
      } else if x < y {
        if asc { -1 } else { 1 }
      } else if asc {
        1
      } else {
        -1
      }
  }
}

///|
/// Compare two entries by the chosen sort column and direction (offline/missing always sink to the bottom).
fn sp_compare_entries(
  a : StationPickEntry,
  b : StationPickEntry,
  col : StationSortCol,
  asc : Bool,
  busy : Bool,
) -> Int {
  let sa = Some(a.station)
  let sb = Some(b.station)
  let oa = flag(sa, "online")
  let ob = flag(sb, "online")
  let primary = match col {
    Name => {
      let na = a.name.to_lower()
      let nb = b.name.to_lower()
      let c = na.compare(nb)
      if asc { c } else { -c }
    }
    Running => {
      let va = if oa { Some(number(field(field(sa, "overview"), "counts"), "running")) } else { None }
      let vb = if ob { Some(number(field(field(sb, "overview"), "counts"), "running")) } else { None }
      sp_cmp_opt_double(va, vb, asc)
    }
    Cpu => {
      let cpu_used = fn(st : Json?, on : Bool) -> Double? {
        if !on { return None }
        let ms = @settings.meters_said(items(field(st, "host"), "meters"), busy)
        match sp_meter_of(ms, 0) {
          Some(m) => Some(100.0 - number(Some(m), "left"))
          None => None
        }
      }
      sp_cmp_opt_double(cpu_used(sa, oa), cpu_used(sb, ob), asc)
    }
    Memory => {
      let mem_gb = fn(st : Json?, on : Bool) -> Double? {
        if !on { return None }
        sp_meter_gb(sp_meter_of(items(field(st, "host"), "meters"), 1))
      }
      sp_cmp_opt_double(mem_gb(sa, oa), mem_gb(sb, ob), asc)
    }
    Disk => {
      let disk_gb = fn(st : Json?, on : Bool) -> Double? {
        if !on { return None }
        sp_meter_gb(sp_meter_of(items(field(st, "host"), "meters"), 2))
      }
      sp_cmp_opt_double(disk_gb(sa, oa), disk_gb(sb, ob), asc)
    }
    Network => {
      let va = if oa { sp_net_rtt_ms(a.net.get().value) } else { None }
      let vb = if ob { sp_net_rtt_ms(b.net.get().value) } else { None }
      sp_cmp_opt_double(va, vb, asc)
    }
  }
  if primary != 0 {
    primary
  } else {
    a.index - b.index
  }
}

///|
/// `>= 6` stations: 740pt centered modal on Medium/Large (bottom sheet on Small), adapting by `View::by_room`.
fn station_many_picker_node(n : @view.View, src : Source, w : Workspace, v : Json?, close : () -> Unit) -> Unit {
  let current = text(field(v, "station"), "station")
  let is_auto = flag(v, "autoStation")
  let pool = count(v, "autoPoolCount")
  let show_auto = pool > 0 && !flag(v, "presetStations")
  let stations = items(v, "stations")
  let entries : Array[StationPickEntry] = []
  for i, s in stations {
    let st = Some(s)
    let addr = text(st, "station")
    let id = text(st, "id")
    let name = text(st, "name")
    let net = src.topic("stationNet", { "station": Json::string(addr) })
    entries.push({ index: i, key: if addr != "" { addr } else { id + "#" + i.to_string() }, id, name, station: s, net })
  }
  let busy = @signals.computed(fn(_) { cpu_busy(src) })
  let query_field = @ui.Field::new()
  let search_at : @signals.Signal[Int] = @signals.signal(0)
  let navigated : @signals.Signal[Bool] = @signals.signal(false)
  let sort_col : @signals.Signal[StationSortCol?] = @signals.signal(None)
  let sort_asc : @signals.Signal[Bool] = @signals.signal(true)
  let visible_indices = @signals.computed(fn(_) {
    let q = query_field.text()
    let matched : Array[StationPickEntry] = []
    for e in entries {
      if sp_entry_matches(q, e) {
        matched.push(e)
      }
    }
    match sort_col.get() {
      Some(col) => {
        let asc = sort_asc.get()
        let b = busy.get()
        matched.sort_by(fn(a, c) { sp_compare_entries(a, c, col, asc, b) })
      }
      None => ()
    }
    matched.map(fn(e) { e.index })
  })
  let on_step = fn(delta : Int) {
    let list = visible_indices.get()
    let count_n = list.length()
    if count_n > 0 {
      let cur = search_at.untracked()
      let next = (cur + delta + count_n) % count_n
      navigated.set(true)
      search_at.set(next)
    }
  }
  let on_enter = fn() {
    let list = visible_indices.get()
    if list.length() > 0 {
      let idx = search_at.untracked()
      let safe = if idx >= 0 && idx < list.length() { idx } else { 0 }
      let chosen = entries[list[safe]]
      @sfbase.pick_new(src, w.id, { "station": Json::string(chosen.id) })
      close()
    }
  }
  let toggle_sort = fn(col : StationSortCol) {
    match sort_col.untracked() {
      Some(cur) if cur == col => sort_asc.set(!sort_asc.untracked())
      _ => {
        sort_col.set(Some(col))
        sort_asc.set(sp_default_asc(col))
      }
    }
    search_at.set(0)
  }
  let is_highlighted = fn(entry_idx : Int) -> Bool {
    let q_nonempty = query_field.text().trim().to_owned() != ""
    if !q_nonempty && !navigated.get() {
      return false
    }
    let list = visible_indices.get()
    let at = search_at.get()
    at >= 0 && at < list.length() && list[at] == entry_idx
  }
  if @sf.in_dialog_node(n) {
    sp_wide_table_node(
      n,
      src,
      w,
      entries,
      visible_indices,
      busy,
      current,
      is_auto,
      show_auto,
      pool,
      query_field,
      search_at,
      navigated,
      sort_col,
      sort_asc,
      toggle_sort,
      is_highlighted,
      on_enter,
      on_step,
      close,
    )
  } else {
    sp_narrow_drawer_node(
      n,
      src,
      w,
      entries,
      visible_indices,
      busy,
      current,
      is_auto,
      show_auto,
      pool,
      query_field,
      search_at,
      navigated,
      is_highlighted,
      on_enter,
      on_step,
      close,
    )
  }
}

///|
/// Wide layout (`room.width() >= 560pt`): search bar + auto-assign toggle, sortable header row, scrollable table.
fn sp_wide_table_node(
  body : @view.View,
  src : Source,
  w : Workspace,
  entries : Array[StationPickEntry],
  visible_indices : @signals.Computed[Array[Int]],
  busy : @signals.Computed[Bool],
  current : String,
  is_auto : Bool,
  show_auto : Bool,
  pool : Int,
  query_field : @ui.Field,
  search_at : @signals.Signal[Int],
  navigated : @signals.Signal[Bool],
  sort_col : @signals.Signal[StationSortCol?],
  sort_asc : @signals.Signal[Bool],
  toggle_sort : (StationSortCol) -> Unit,
  is_highlighted : (Int) -> Bool,
  on_enter : () -> Unit,
  on_step : (Int) -> Unit,
  close : () -> Unit,
) -> Unit {
  let tips = body.lent(@sf.panel_tips_lent)
  // Top bar: full-width search + optional "Auto (N)" pill
  body.box(fn(top) {
    @sf.style_node(top, fn() { sp_wide_top })
    top.box(fn(sw) {
      sw.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      @sf.panel_search_input_node(
        sw,
        query_field,
        fn() { @sf.t("web-main.newChat.stationSearchWide") },
        edited=fn(_) {
          search_at.set(0)
          navigated.set(false)
        },
        submitted=fn(_) { on_enter() },
        step=fn(d) {
          on_step(d)
          true
        },
      )
      |> ignore
    })
    |> ignore
    if show_auto {
      let auto_label = fn() { @sf.t("web-main.newChat.stationAutoCount", args=[("n", pool.to_string())]) }
      let auto_press = fn() {
        @sfbase.pick_new(src, w.id, { "autoStation": Json::boolean(true) })
        close()
      }
      @sf.action_box_node(
        top,
        auto_label,
        fn(_) { auto_press() },
        check=fn() { if is_auto { On } else { Off } },
        fn(btn) {
          @sf.style_node(btn, fn() {
            (if is_auto { sp_auto_pill_on } else { sp_auto_pill }).then(@ui.style(h=Fixed(@sf.menu_row_min)))
          }, in_row=true)
          btn.shrink(Is(0.0)) |> ignore
          if !is_auto {
            @sf.hover_ground_node(btn, lit=Some(fn() { @sf.hovered_in_node(btn) || btn.focus_shown() }))
          }
          @sf.rippled_node(btn, auto_press, @sf.menu_row_min / 2.0, auto_label)
          @sf.icon_node(btn, "sparks", 14.0, By(fn() { @sf.theme().p.accent_text })) |> ignore
          @sf.words_node(btn, auto_label, fn() { if is_auto { sp_auto_pill_words_on } else { sp_auto_pill_words } })
          |> ignore
          if is_auto {
            @sf.icon_node(btn, "check", 13.0, By(fn() { @sf.theme().p.accent })) |> ignore
          }
        },
      )
      |> ignore
    }
  })
  |> ignore
  // Sortable table header + hairline divider + scrollable body grouped tightly (no excess dialog column gap)
  body.box(fn(tbl) {
    @sf.style_node(tbl, fn() { sp_table_wrap })
    tbl.box(fn(hdr) {
      @sf.style_node(hdr, fn() { sp_table_header })
      sp_sort_head_cell(hdr, Name, fn() { @sf.t("web-main.newChat.stationColStation") }, None, true, sort_col, sort_asc, toggle_sort)
      sp_sort_head_cell(hdr, Running, fn() { @sf.t("web-main.newChat.stationColRunning") }, Some(sp_col_running_w), false, sort_col, sort_asc, toggle_sort)
      sp_sort_head_cell(hdr, Cpu, fn() { @sf.t("web-main.newChat.stationColCpu") }, Some(sp_col_cpu_w), false, sort_col, sort_asc, toggle_sort)
      sp_sort_head_cell(hdr, Memory, fn() { @sf.t("web-main.newChat.stationColMemory") }, Some(sp_col_mem_w), false, sort_col, sort_asc, toggle_sort)
      sp_sort_head_cell(hdr, Disk, fn() { @sf.t("web-main.newChat.stationColDisk") }, Some(sp_col_disk_w), false, sort_col, sort_asc, toggle_sort)
      sp_sort_head_cell(hdr, Network, fn() { @sf.t("web-main.newChat.stationColNetwork") }, Some(sp_col_net_w), false, sort_col, sort_asc, toggle_sort)
    })
    |> ignore
    tbl.box(fn(d) {
      @sf.style_node(d, fn() { sp_header_rule_wrap })
      d.box(fn(line) { @sf.style_node(line, fn() { @sf.rule_line }) }) |> ignore
    })
    |> ignore
    // Scrollable table body
    @sf.capped_node(tbl, fn() { sp_table_body_max_h }, fn(list) {
      list.show(at_once=true, fn() { visible_indices.get().is_empty() }, fn(empty) {
        @sf.style_node(empty, fn() { sp_empty_box })
        @sf.words_node(empty, fn() { @sf.t("common.noMatch") }, fn() { sp_empty_words }) |> ignore
      })
      list.each(fn() { visible_indices.get() }, fn(i) { i }, fn(row_host, i_sig) {
        let idx = i_sig.untracked()
        let entry = entries[idx]
        let st = Some(entry.station)
        let online = flag(st, "online")
        let running = number(field(field(st, "overview"), "counts"), "running")
        let here = !is_auto && entry.key == current
        let press = fn() {
          @sfbase.pick_new(src, w.id, { "station": Json::string(entry.id) })
          close()
        }
        let meters = @signals.computed(fn(_) { @settings.meters_said(items(field(st, "host"), "meters"), busy.get()) })
        @sf.action_box_node(
          row_host,
          fn() { entry.name },
          fn(_) { press() },
          check=fn() { if here { On } else { Off } },
          fn(row) {
            @sf.style_node(row, fn() { sp_table_row.then(@ui.style(radius=@sf.panel_in)) })
            row.min_height(By(fn() { Some(dmax(sp_table_row_min_h, @sf.theme().t.ui_line + sp_table_row_pad_y)) }))
            |> ignore
            @sf.hover_ground_node(
              row,
              lit=Some(fn() { @sf.hovered_in_node(row) || row.focus_shown() }),
              extra=fn() { is_highlighted(idx) },
            )
            @sf.rippled_node(row, press, @sf.row_corner, fn() { entry.name })
            // Column 1: Station mark + name (with repeats=true tooltip on name node) + check
            row.box(fn(c1) {
              @sf.style_node(c1, fn() { sp_cell_station }, in_row=true)
              c1.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              sp_station_mark_box(c1, st, single_line=true)
              let name_v = @sf.words_node(c1, fn() { entry.name }, fn() { sp_row_name })
                .grow(Is(1.0))
                .basis(Is(Some(0.0)))
                .shrink(Is(1.0))
                .min_width(Is(Some(0.0)))
                .cuts(Is(true))
                .allow_ellipsis(Is(true))
              if tips is Some(tl) {
                @sf.tip_node(tl, name_v, fn() { entry.name }, within=true, repeats=true, pressed=fn() { row.pressed() })
                |> ignore
              }
              if here {
                @sf.icon_node(c1, "check", new_mark, By(fn() { @sf.theme().p.accent })) |> ignore
              }
            })
            |> ignore
            // Column 2: Running
            row.box(fn(c2) {
              @sf.style_node(c2, fn() { sp_cell_num }, in_row=true)
              c2.width(Is(Some(sp_col_running_w))).shrink(Is(0.0)) |> ignore
              if online && running > 0.0 {
                @sf.state_dot_node(c2, fn() { "up" }, size=station_dot_side)
                @sf.words_node(c2, fn() { running.to_int().to_string() }, fn() { sp_cell_accent }) |> ignore
              } else if online {
                @sf.words_node(c2, fn() { @sf.t("web-main.newChat.stationIdle") }, fn() { sp_cell_muted }) |> ignore
              } else {
                @sf.state_dot_node(c2, fn() { "offline" }, size=station_dot_side)
                @sf.words_node(c2, fn() { text(st, "summary") }, fn() { sp_cell_muted })
                .shrink(Is(1.0))
                .min_width(Is(Some(0.0)))
                .cuts(Is(true))
                .allow_ellipsis(Is(true))
                |> ignore
              }
            })
            |> ignore
            // Column 3: CPU
            row.box(fn(c3) {
              @sf.style_node(c3, fn() { sp_cell_num }, in_row=true)
              c3.width(Is(Some(sp_col_cpu_w))).shrink(Is(0.0)) |> ignore
              if online {
                let m = fn() { sp_meter_of(meters.get(), 0) }
                @sf.words_node(c3, fn() { sp_meter_wide(m()) }, fn() { sp_table_meter_style(text(m(), "level")) })
                |> ignore
              } else {
                @sf.words_node(c3, fn() { "—" }, fn() { sp_cell_muted }) |> ignore
              }
            })
            |> ignore
            // Column 4: Memory
            row.box(fn(c4) {
              @sf.style_node(c4, fn() { sp_cell_num }, in_row=true)
              c4.width(Is(Some(sp_col_mem_w))).shrink(Is(0.0)) |> ignore
              if online {
                let m = fn() { sp_meter_of(meters.get(), 1) }
                @sf.words_node(c4, fn() { sp_meter_wide(m()) }, fn() { sp_table_meter_style(text(m(), "level")) })
                |> ignore
              } else {
                @sf.words_node(c4, fn() { "—" }, fn() { sp_cell_muted }) |> ignore
              }
            })
            |> ignore
            // Column 5: Disk
            row.box(fn(c5) {
              @sf.style_node(c5, fn() { sp_cell_num }, in_row=true)
              c5.width(Is(Some(sp_col_disk_w))).shrink(Is(0.0)) |> ignore
              if online {
                let m = fn() { sp_meter_of(meters.get(), 2) }
                @sf.words_node(c5, fn() { sp_meter_wide(m()) }, fn() { sp_table_meter_style(text(m(), "level")) })
                |> ignore
              } else {
                @sf.words_node(c5, fn() { "—" }, fn() { sp_cell_muted }) |> ignore
              }
            })
            |> ignore
            // Column 6: Network
            row.box(fn(c6) {
              @sf.style_node(c6, fn() { sp_cell_num }, in_row=true)
              c6.width(Is(Some(sp_col_net_w))).shrink(Is(0.0)) |> ignore
              if online {
                @sf.words_node(c6, fn() { sp_net_wide(entry.net.get().value) }, fn() { sp_cell_muted })
                .shrink(Is(1.0))
                .min_width(Is(Some(0.0)))
                .cuts(Is(true))
                .allow_ellipsis(Is(true))
                |> ignore
              } else {
                @sf.words_node(c6, fn() { "—" }, fn() { sp_cell_muted }) |> ignore
              }
            })
            |> ignore
          },
        )
        |> ignore
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// Clickable sortable column header cell.
fn sp_sort_head_cell(
  parent : @view.View,
  col : StationSortCol,
  label : () -> String,
  fixed_w : Double?,
  left_align : Bool,
  sort_col : @signals.Signal[StationSortCol?],
  sort_asc : @signals.Signal[Bool],
  toggle_sort : (StationSortCol) -> Unit,
) -> Unit {
  let active = fn() { sort_col.get() == Some(col) }
  let words = fn() {
    let base = label()
    if active() {
      base + (if sort_asc.get() { " ↑" } else { " ↓" })
    } else {
      base
    }
  }
  @sf.action_box_node(parent, label, fn(_) { toggle_sort(col) }, fn(cell) {
    @sf.style_node(cell, fn() { if left_align { sp_head_left } else { sp_head_right } }, in_row=true)
    match fixed_w {
      Some(w) => cell.width(Is(Some(w))).shrink(Is(0.0)) |> ignore
      None => cell.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    }
    @sf.hover_ground_node(cell, lit=Some(fn() { @sf.hovered_in_node(cell) || cell.focus_shown() }))
    @sf.words_node(cell, words, fn() { if active() { sp_head_words_on } else { sp_head_words } }) |> ignore
  })
  |> ignore
}

///|
/// Narrow layout (`room.width() < 560pt`): top search bar + auto row + compact two-line station list.
fn sp_narrow_drawer_node(
  body : @view.View,
  src : Source,
  w : Workspace,
  entries : Array[StationPickEntry],
  visible_indices : @signals.Computed[Array[Int]],
  busy : @signals.Computed[Bool],
  current : String,
  is_auto : Bool,
  show_auto : Bool,
  pool : Int,
  query_field : @ui.Field,
  search_at : @signals.Signal[Int],
  navigated : @signals.Signal[Bool],
  is_highlighted : (Int) -> Bool,
  on_enter : () -> Unit,
  on_step : (Int) -> Unit,
  close : () -> Unit,
) -> Unit {
  body.box(fn(sb) {
    @sf.style_node(sb, fn() { sp_narrow_search_wrap.then(@sf.panel_field_in_node(sb)) })
    @sf.panel_search_input_node(
      sb,
      query_field,
      fn() { @sf.t("web-main.newChat.stationSearch") },
      edited=fn(_) {
        search_at.set(0)
        navigated.set(false)
      },
      submitted=fn(_) { on_enter() },
      step=fn(d) {
        on_step(d)
        true
      },
    )
    |> ignore
  })
  |> ignore
  @sf.capped_node(body, fn() { sp_table_body_max_h }, fn(list) {
    if show_auto {
      list.show(at_once=true, fn() { query_field.text().trim().to_owned() == "" }, fn(a) {
        sp_auto_row_node(a, src, w, pool, is_auto, fn() { visible_indices.get().length() > 0 }, close)
      })
    }
    list.show(at_once=true, fn() { visible_indices.get().is_empty() }, fn(empty) {
      @sf.style_node(empty, fn() { sp_empty_box })
      @sf.words_node(empty, fn() { @sf.t("common.noMatch") }, fn() { sp_empty_words }) |> ignore
    })
    list.each(fn() { visible_indices.get() }, fn(i) { i }, fn(row_host, i_sig) {
      let idx = i_sig.untracked()
      let entry = entries[idx]
      let here = !is_auto && entry.key == current
      sp_compact_station_row_node(
        row_host,
        src,
        w,
        Some(entry.station),
        entry.net,
        busy,
        here,
        fn() { is_highlighted(idx) },
        close,
      )
    })
  })
  |> ignore
}

// ── styles (constant top-level styles use @ui.css per apps/mbui/AGENTS.md) ──

///|
// kept across runs: a value (no field of it changes)
let sp_compact_row : @ui.Style = @ui.css("row w=Full px=S2 py=S2_5 gap=S2_5 align=AStart radius=Lg")

///|
// kept across runs: a value (no field of it changes)
let sp_compact_col : @ui.Style = @ui.css("gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let sp_compact_head : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sp_compact_sub : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sp_divider_wrap : @ui.Style = @ui.css("w=Full py=S1")

///|
// kept across runs: a value (no field of it changes)
let sp_wide_top : @ui.Style = @ui.css("row w=Full gap=S2 pb=S2_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sp_narrow_search_wrap : @ui.Style = @ui.css("w=Full pb=S2")

///|
// kept across runs: a value (no field of it changes)
let sp_auto_pill : @ui.Style = @ui.css("row px=S3 gap=S1_5 align=ACenter radius=Full bg=Tint")

///|
// kept across runs: a value (no field of it changes)
let sp_auto_pill_on : @ui.Style = @ui.css("row px=S3 gap=S1_5 align=ACenter radius=Full bg=A(Accent,O10)")

///|
// kept across runs: a value (no field of it changes)
let sp_table_wrap : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let sp_table_header : @ui.Style = @ui.css("row w=Full pl=S0_5 pr=S2 py=S1 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sp_header_rule_wrap : @ui.Style = @ui.css("w=Full pb=S1_5")

///|
// kept across runs: a value (no field of it changes)
let sp_table_row : @ui.Style = @ui.css("row w=Full px=S2 py=S1_5 gap=S2 align=ACenter radius=Lg")

///|
// kept across runs: a value (no field of it changes)
let sp_cell_station : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sp_cell_num : @ui.Style = @ui.css("row pr=S1_5 gap=S1_25 align=ACenter justify=JEnd")

///|
// kept across runs: a value (no field of it changes)
let sp_head_left : @ui.Style = @ui.css("row px=S1_5 py=S0_5 align=ACenter justify=JStart radius=Md")

///|
// kept across runs: a value (no field of it changes)
let sp_head_right : @ui.Style = @ui.css("row px=S1_5 py=S0_5 align=ACenter justify=JEnd radius=Md")

///|
// kept across runs: a value (no field of it changes)
let sp_empty_box : @ui.Style = @ui.css("w=Full py=S6 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let sp_row_name : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let sp_auto_hint : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let sp_meta_muted : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_meta_warn : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=WarnInk, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_meta_danger : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Danger, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_cell_fg : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Fg, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_cell_muted : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_cell_accent : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=AccentText, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_cell_warn : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=WarnInk, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_cell_danger : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Danger, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_head_words : @ui.TextStyle = @ui.text_style(size=Caption, leading=L4, color=Muted, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_head_words_on : @ui.TextStyle = @ui.text_style(size=Caption, leading=L4, weight=Medium, color=AccentText, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_auto_pill_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Fg, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_auto_pill_words_on : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=AccentText, wrap=false, w=Hug)

///|
// kept across runs: a value (no field of it changes)
let sp_empty_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, center=true, w=Full)
