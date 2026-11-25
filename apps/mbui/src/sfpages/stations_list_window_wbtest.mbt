// The stations' list (stations_list.mbt) gives the page a block each station, by its address, so the page's list
// (page_node, View::scrolls_window) makes only the cards in sight and near it as it opens, not every station's at once
// (a phone's Place stations, 2026-11-22: one touch-up 21.5 ms on Android, 28.1 ms on iOS, 690 nodes made in it, the
// workspace's stations all one block).

///|
/// The workspace's station `i` of the made-up core: up, its name and what is said of it its own.
fn sl_window_station(i : Int) -> Json {
  {
    "station": Json::string("ws1/s\{i}"),
    "id": Json::string("s\{i}"),
    "name": Json::string("站点 \{i}"),
    "online": true,
    "summary": Json::string("机器 \{i} 的说明"),
  }
}

///|
/// The list over a made-up core of `n` stations, opened in a phone's window (390 by 844) after it is drawn without
/// it: the tester, and the nodes its opening made.
fn sl_window_open(n : Int) -> (@ui.Tester, Int) {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let stations = Array::makei(n, sl_window_station)
  let src = @sfbase.made_source(topic=fn(name, _) {
    match name {
      "stations" => Some(Json::array(stations))
      "workspace" => Some({ "role": "owner" })
      "rigs" => Some({ "rigs": [] })
      "devices" => Some({ "devices": [] })
      _ => None
    }
  })
  let core = @sfbase.settings_core(src, rig_workspace)
  let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
  let open = @signals.signal(false)
  let t = station_part_tester(
    fn(p) {
      p.show(fn() { open.get() }, at_once=true, fn(x) {
        x.grow(Is(1.0)) |> ignore
        stations_list_node(x, core, here, on_back=fn() {  }, frame=fn() { @sf.no_frame })
      })
    },
    w=390.0,
    h=844.0,
    platform=2,
  )
  t.tree_frames_from_now()
  open.set(true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  let made = t.tree_frames().fold(init=0, fn(s, f) { s + f.made })
  (t, made)
}

///|
test "stations_list: opening makes only the cards in sight, as many nodes for 24 stations as for 60; the rest made as scrolled to" {
  let (_, few) = sl_window_open(3)
  let (t, made) = sl_window_open(24)
  assert_true(t.find("站点 0") is Some(_), msg="the first station shown")
  assert_true(t.find("机器 0 的说明") is Some(_), msg="what is said of the first shown")
  assert_true(t.find("站点 23") is None, msg="the last station, far out of sight, not made as the page opens")
  // (the cards past the window and its margin not made: as many made for 24 as for 60, more than for 3)
  let (_, many) = sl_window_open(60)
  assert_true(made > few, msg="24 stations make more than 3: \{made}, \{few}")
  assert_eq(made, many, msg="24 stations make as many as 60: \{made}, \{many}")
  // (scrolled down by a hand's wheel, a screen at a time, to its foot: the last ones made as they come near, their
  // words as the core says them, the first let go of)
  let (t, _) = sl_window_open(24)
  let mut steps = 0
  while t.find("站点 23") is None && steps < 20 {
    t.wheel(195.0, 422.0, 600.0)
    t.run_for(@ui.move_most_ms)
    steps = steps + 1
  }
  assert_true(t.find("站点 23") is Some(_), msg="the last station shown at the foot")
  assert_true(t.find("机器 23 的说明") is Some(_), msg="what is said of the last shown")
  assert_true(t.find("站点 0") is None, msg="the first, far above, let go of")
}

///|
test "stations_list: compact grouped rows keep fixed order, preserve edge states, and fit 7 stations on a phone screen" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let mk_online = fn(i : Int, name : String, running : Int, cpu_left : Int, cpu_lvl : String) -> Json {
    {
      "station": Json::string("ws1/s\{i}"),
      "id": Json::string("s\{i}"),
      "name": Json::string(name),
      "online": true,
      "summary": Json::string("主机 \{i}"),
      "overview": { "counts": { "running": Json::number(running.to_double()) } },
      "host": {
        "meters": [
          { "short": "CPU", "big": Json::string(cpu_left.to_string()), "unit": "%", "left": Json::number(cpu_left.to_double()), "level": Json::string(cpu_lvl), "remaining": Json::string("空闲 \{cpu_left}%") },
          { "short": "内存", "big": "8.0", "unit": "GB", "left": 50, "level": "ok", "remaining": "剩 8.0 G" },
          { "short": "磁盘", "big": "200", "unit": "GB", "left": 50, "level": "ok", "remaining": "剩 200 G" },
        ],
      },
    }
  }
  // Interleaved offline stations stay in their original workspace order without jumping to the bottom.
  let stations : Array[Json] = [
    mk_online(0, "Office-Host-2", 14, 69, "ok"),
    {
      "station": "ws1/s1",
      "id": "s1",
      "name": "zwg-Macbook-580",
      "online": false,
      "summary": "离线 · 2 天前",
    },
    mk_online(2, "tokyo-mac-studio-0", 7, 62, "ok"),
    mk_online(3, "pvg-office-2", 2, 11, "red"),
    mk_online(4, "pvg-office-1", 0, 36, "ok"),
    mk_online(5, "afkprover", 3, 63, "ok"),
    {
      "station": "ws1/s6",
      "id": "s6",
      "name": "home-mini",
      "online": false,
      "summary": "安全模式未放行",
      "blocked": "此 station 尚未加入安全模式",
    },
  ]
  let src = @sfbase.made_source(topic=fn(name, params) {
    match name {
      "stations" => Some(Json::array(stations))
      "stationNet" =>
        match params.get("station") {
          Some(String("ws1/s0")) => Some({ "path": "直连", "rtt": { "text": "38 ms", "level": "ok" } })
          _ => Some({ "path": "东京中继", "rtt": { "text": "42 ms", "level": "ok" } })
        }
      "workspace" => Some({ "role": "owner" })
      "rigs" => Some({ "rigs": [] })
      "devices" => Some({ "devices": [] })
      _ => None
    }
  })
  let core = @sfbase.settings_core(src, rig_workspace)
  let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
  let t = station_part_tester(
    fn(p) { stations_list_node(p, core, here, on_back=fn() {  }, frame=fn() { @sf.no_frame }) },
    w=390.0,
    h=844.0,
    platform=2,
  )
  // All 7 stations stay in fixed order and fit without scrolling on a 390x844 phone screen.
  let names = ["Office-Host-2", "zwg-Macbook-580", "tokyo-mac-studio-0", "pvg-office-2", "pvg-office-1", "afkprover", "home-mini"]
  let mut prev_y = -1.0
  for name in names {
    let pos = t.find(name)
    assert_true(pos is Some(_), msg="expected \{name} visible on first screen")
    let y = pos.unwrap().1
    assert_true(y > prev_y, msg="expected \{name} below previous row: \{y} <= \{prev_y}")
    assert_true(y < 760.0, msg="expected \{name} above bottom bar, got y=\{y}")
    prev_y = y
  }
  assert_true(t.find("14 个运行中") is Some(_), msg="running count shown on line 1")
  assert_true(t.find("CPU 空闲 69%") is Some(_), msg="compact CPU figure preserves idle/remaining wording")
  assert_true(t.find("直连") is Some(_) && t.find("38 ms") is Some(_), msg="compact network shown on line 2")
  assert_true(t.find("离线 · 2 天前") is Some(_), msg="offline summary shown on line 2")
  assert_true(t.find("此 station 尚未加入安全模式") is Some(_), msg="offline block reason preserved")
}

///|
test "stations_list: online/offline flapping updates in place without reordering, long offline tail keeps name visible, and protect button disables while joining" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let online = @signals.signal(true)
  let protect = @signals.signal(true)
  let joining = @signals.signal(false)
  let src = @sfbase.made_source(topic=fn(name, _) {
    match name {
      "stations" => {
        let up = online.get()
        Some(
          Json::array([
            {
              "station": "ws1/s0",
              "id": "s0",
              "name": "Alpha-Workstation",
              "online": Json::boolean(up),
              "summary": Json::string(if up { "主机 0" } else { "Blocked by security mode" }),
              "protect": Json::boolean(protect.get()),
              "overview": { "counts": { "running": 2 } },
            },
            {
              "station": "ws1/s1",
              "id": "s1",
              "name": "Beta-Node",
              "online": true,
              "summary": "主机 1",
              "overview": { "counts": { "running": 0 } },
            },
          ]),
        )
      }
      "doing" =>
        Some(
          Json::object({
            "doing": if joining.get() {
              Json::array([
                {
                  "call": "lock.joinStation",
                  "stage": "running",
                  "params": { "workspace": "ws1", "station": "s0" },
                },
              ])
            } else {
              Json::array([])
            },
          }),
        )
      "workspace" => Some({ "role": "owner" })
      "rigs" => Some({ "rigs": [] })
      "devices" => Some({ "devices": [] })
      _ => None
    }
  })
  let core = @sfbase.settings_core(src, rig_workspace)
  let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
  let t = station_part_tester(
    fn(p) { stations_list_node(p, core, here, on_back=fn() {  }, frame=fn() { @sf.no_frame }) },
    w=320.0,
    h=568.0,
    platform=2,
  )
  // Protect action is exposed as a pressable Button in the accessibility tree when idle.
  t.set_a11y(true)
  t.draw()
  let join_label = @sf.t("web-pages.security.joinShort")
  let has_join_btn = fn() {
    t
    .a11y_said()
    .split("\n")
    .any(fn(v) {
      let l = v.to_owned()
      l.contains("\u{1F}Button\u{1F}") && l.contains(join_label)
    })
  }
  assert_true(has_join_btn(), msg="protect button exposed in a11y tree when idle: \{t.a11y_said()}")
  let y0_online = t.find("Alpha-Workstation").unwrap().1
  let y1_online = t.find("Beta-Node").unwrap().1
  assert_true(y0_online < y1_online, msg="Alpha above Beta initially")
  // While joining, protect row stops being a pressable Button in the accessibility tree.
  joining.set(true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(!has_join_btn(), msg="protect button not pressable while joining: \{t.a11y_said()}")
  // Without protect action, flapping online <-> offline keeps Beta-Node at the exact same y coordinate (zero row jump).
  joining.set(false)
  protect.set(false)
  t.draw()
  t.run_for(@ui.move_most_ms)
  let y1_steady = t.find("Beta-Node").unwrap().1
  online.set(false)
  t.draw()
  t.run_for(@ui.move_most_ms)
  let y0_off = t.find("Alpha-Workstation").unwrap().1
  let y1_off = t.find("Beta-Node").unwrap().1
  assert_true(y0_off < y1_off, msg="Alpha stays above Beta when offline: \{y0_off} vs \{y1_off}")
  assert_eq(y1_off, y1_steady, msg="Beta-Node does not shift vertically when Alpha goes offline")
  assert_true(t.find("Blocked by security mode") is Some(_), msg="offline summary shown cleanly on line 2")
  assert_true(t.audit().is_empty(), msg="no layout/contrast/corner faults on 320px long offline summary: " + t.audit().join(" | "))
  // Flapping back online keeps Beta-Node at the exact same y coordinate.
  online.set(true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  let y0_back = t.find("Alpha-Workstation").unwrap().1
  let y1_back = t.find("Beta-Node").unwrap().1
  assert_true(y0_back < y1_back, msg="Alpha stays above Beta after reconnecting")
  assert_eq(y1_back, y1_steady, msg="Beta-Node does not shift vertically when Alpha reconnects")
}

///|
test "stations_list: 390px keeps all three low-headroom warning meters alongside latency by dropping network path first" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let src = @sfbase.made_source(topic=fn(name, _) {
    match name {
      "stations" =>
        Some(
          Json::array([
            {
              "station": "ws1/st1",
              "id": "st1",
              "name": "Willow",
              "online": true,
              "summary": "主机",
              "overview": { "counts": { "running": 1 } },
              "host": {
                "meters": [
                  { "short": "CPU", "big": "8", "unit": "%", "left": 8, "level": "red", "remaining": "空闲 8%" },
                  { "short": "内存", "big": "5.8", "unit": "GB", "left": 18, "level": "amber", "remaining": "剩 5.8 G" },
                  { "short": "磁盘", "big": "19.4", "unit": "GB", "left": 9, "level": "amber", "remaining": "剩 19.4 G" },
                ],
              },
            },
          ]),
        )
      "stationNet" => Some({ "path": "直连", "rtt": { "text": "38 ms", "level": "ok" } })
      "workspace" => Some({ "role": "owner" })
      "rigs" => Some({ "rigs": [] })
      "devices" => Some({ "devices": [] })
      _ => None
    }
  })
  let core = @sfbase.settings_core(src, rig_workspace)
  let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
  let t = station_part_tester(
    fn(p) { stations_list_node(p, core, here, on_back=fn() {  }, frame=fn() { @sf.no_frame }) },
    w=390.0,
    h=844.0,
    platform=2,
  )
  assert_true(t.find("CPU 空闲 8%") is Some(_), msg="red CPU warning visible on 390px")
  assert_true(t.find("内存剩 5.8 G") is Some(_), msg="amber memory warning visible on 390px")
  assert_true(t.find("磁盘剩 19.4 G") is Some(_), msg="amber disk warning preserved over network path on 390px")
  assert_true(t.find("38 ms") is Some(_), msg="latency preserved alongside all three warnings on 390px")
}
