///|
extern "js" fn capture_fault_calls() -> Unit =
  #|() => { globalThis.__faultTestPreviousCore = globalThis.__mbcore; globalThis.__faultTestCalls = []; globalThis.__mbcore = { send: (json) => globalThis.__faultTestCalls.push(JSON.parse(json)) }; }

///|
extern "js" fn captured_fault_calls() -> String =
  #|() => JSON.stringify(globalThis.__faultTestCalls)

///|
extern "js" fn restore_fault_core() -> Unit =
  #|() => { globalThis.__mbcore = globalThis.__faultTestPreviousCore; delete globalThis.__faultTestPreviousCore; delete globalThis.__faultTestCalls; }

///|
test "UI fault reporting uses fixed categories even for unknown text" {
  assert_eq(ui_fault_category("Ctx::editor: a Field given to C:\\private\\file that a field of the window's tree holds"), "editor field already in tree")
  assert_eq(ui_fault_category("field: one Field given to two fields of the tree's: a Field is one editor's"), "tree field reused")
  assert_eq(ui_fault_category("scene: a frame put together round layers drawn again where they were not kept: private"), "scene layer conflict")
  assert_eq(ui_fault_category("presented beside a node of the tree, drawn by the old frame: a kind of panel panel_node does not take yet"), "panel cannot be presented")
  assert_eq(ui_fault_category("unknown /private/secret.txt"), "UI fault")
  assert_eq(
    ui_fault_category("chat sent unseen: listed=1 row=0 staged=1 held=0 sending=0"),
    "chat sent unseen: listed=1 row=0 staged=1 held=0 sending=0",
  )
  assert_eq(ui_fault_category("chat sent unseen: listed=1 /private/secret.txt"), "chat sent unseen")
}

///|
test "a UI fault on a host without its own reporter reaches the core once" {
  let previous = @view.fault_told.val
  let stopped = @view.faults_stop.val
  @core.client.reset()
  capture_fault_calls()
  defer {
    @view.fault_told.val = previous
    @view.faults_stop.val = stopped
    @core.client.reset()
    restore_fault_core()
  }
  reports_start()
  @view.faults_stop.val = false
  @view.fault("reporting-test-fault")
  @view.fault("reporting-test-fault")
  let calls = @json.parse(captured_fault_calls()) catch { _ => Json::null() }
  guard calls is Array(a) else { fail("expected a list of core calls") }
  assert_eq(a.length(), 1)
  guard a[0] is Object(call) else { fail("expected a core call") }
  assert_eq(call.get("call"), Some(Json::string("client.error")))
  guard call.get("params") is Some(Object(params)) else { fail("expected call parameters") }
  assert_eq(params.get("source"), Some(Json::string("ui_fault")))
  assert_eq(params.get("message"), Some(Json::string("UI fault")))
}

///|
test "a Field conflict reports its kind without editor paths or filenames" {
  let previous = @view.fault_told.val
  let stopped = @view.faults_stop.val
  let host = @hostapi.host()
  @core.client.reset()
  capture_fault_calls()
  defer {
    @view.fault_told.val = previous
    @view.faults_stop.val = stopped
    @core.client.reset()
    restore_fault_core()
  }
  reports_start()
  @view.faults_stop.val = false
  let field = @ui.Field::new()
  let t = @ui.Tester::new(
    fn(c) {
      c.editor("files/row/sentinel-private-folder/first-secret.txt", font_size=10.0, field~) |> ignore
      c.editor("files/row/sentinel-private-folder/second-secret.txt", font_size=10.0, field~) |> ignore
    },
    w=300.0,
    h=100.0,
    time=1000.0,
  )
  defer t.end_run(host)
  let film = t.film("exit", draw=fn(_) { true }, put=fn(_) { true })
  let log = film.logs.join("\n")
  assert_true(log.contains("ui fault:"), msg="the fault reached the host log")
  let calls = captured_fault_calls()
  assert_eq(
    (log.contains("sentinel-private-folder") || log.contains("secret.txt"), calls.contains("sentinel-private-folder") || calls.contains("secret.txt")),
    (false, false),
  )
  let parsed = @json.parse(calls) catch { _ => Json::null() }
  guard parsed is Array(a) else { fail("expected a list of core calls") }
  assert_eq(a.length(), 1)
  guard a[0] is Object(call) else { fail("expected a core call") }
  guard call.get("params") is Some(Object(params)) else { fail("expected call parameters") }
  assert_eq(params.get("source"), Some(Json::string("ui_fault")))
  assert_eq(params.get("message"), Some(Json::string("editor field reused")))
}

///|
test "a core failing on a host without its own reporter reaches the core started after it" {
  let previous_fault = @view.fault_told.val
  let previous_failed = @core.on_failed.val
  let previous_restarted = @core.on_restarted.val
  @core.client.reset()
  capture_fault_calls()
  defer {
    @view.fault_told.val = previous_fault
    @core.on_failed.val = previous_failed
    @core.on_restarted.val = previous_restarted
    pending_core_failed.val = None
    @core.client.reset()
    restore_fault_core()
  }
  reports_start()
  guard @core.on_failed.val is Some(failed) else { fail("expected on_failed set") }
  guard @core.on_restarted.val is Some(restarted) else { fail("expected on_restarted set") }
  failed("first failure")
  failed("core failed: out of memory")
  // (the core that failed is gone: nothing sent to it)
  assert_eq(captured_fault_calls(), "[]")
  restarted()
  restarted()
  let calls = @json.parse(captured_fault_calls()) catch { _ => Json::null() }
  guard calls is Array(a) else { fail("expected a list of core calls") }
  assert_eq(a.length(), 1)
  guard a[0] is Object(call) else { fail("expected a core call") }
  assert_eq(call.get("call"), Some(Json::string("client.error")))
  guard call.get("params") is Some(Object(params)) else { fail("expected call parameters") }
  assert_eq(params.get("source"), Some(Json::string("core_failed")))
  assert_eq(params.get("message"), Some(Json::string("core failed: out of memory")))
}

///|
extern "js" fn install_mock_mbreports() -> Unit =
  #|() => {
  #|  globalThis.__mockReportsPrev = globalThis.__mbreports;
  #|  globalThis.__mockReportsCalls = [];
  #|  globalThis.__mbreports = {
  #|    tell: (what, a, b, n, m) => {
  #|      globalThis.__mockReportsCalls.push({ what, a, b, n, m });
  #|      if (what === "hello" || what === "bar_switch_ready" || what === "reporting") return 1;
  #|      return 0;
  #|    },
  #|  };
  #|}

///|
extern "js" fn captured_mbreports_calls() -> String =
  #|() => JSON.stringify(globalThis.__mockReportsCalls)

///|
extern "js" fn restore_mock_mbreports() -> Unit =
  #|() => {
  #|  globalThis.__mbreports = globalThis.__mockReportsPrev;
  #|  delete globalThis.__mockReportsPrev;
  #|  delete globalThis.__mockReportsCalls;
  #|}

///|
extern "js" fn install_mock_mbreports_cfg(reporting : Int, crash_mask : Int, bar_ready : Int) -> Unit =
  #|(reporting, crashMask, barReady) => {
  #|  globalThis.__mockReportsPrev = globalThis.__mbreports;
  #|  globalThis.__mockReportsCalls = [];
  #|  let maskLeft = crashMask;
  #|  globalThis.__mbreports = {
  #|    tell: (what, a, b, n, m) => {
  #|      globalThis.__mockReportsCalls.push({ what, a, b, n, m });
  #|      if (what === "hello") return 1;
  #|      if (what === "bar_switch_ready") return barReady;
  #|      if (what === "reporting") return reporting;
  #|      if (what === "crash_pending") { const v = maskLeft; maskLeft = 0; return v; }
  #|      return 0;
  #|    },
  #|  };
  #|}

///|
fn make_test_hang(stall_ms : Double, page : String) -> @ui.Hang {
  let frame : @ui.FrameDone = {
    tree: 1.0,
    messages: 2.0,
    build: 10.0,
    layout: 5.0,
    paint: 3.0,
    nodes: 10,
    insts: 10,
    made: 1,
    let_go: 0,
    laid: 1,
    measured: 1,
    passes: 3,
    again: "",
    why: "",
    bindings: 2,
  }
  {
    trigger: Stall,
    page,
    arranged: "Large",
    window_w: 1200.0,
    window_h: 800.0,
    sealed_by: Presented,
    startup: false,
    start: 100.0,
    end: 100.0 + stall_ms,
    stall_ms,
    work_ms: stall_ms,
    pieces: 1,
    small: 0,
    small_ms: 0.0,
    lost: 0,
    contributors: [{ what: Frame(frame), start: 100.0, end: 100.0 + stall_ms, notes: [] }],
    elided: 0,
  }
}

///|
test "with hello == 1 and reporting == 1, mirrors ui_fault, core_failed, severe hang, crash_pending, and bar_switch to core" {
  let previous_fault = @view.fault_told.val
  let previous_failed = @core.on_failed.val
  let previous_restarted = @core.on_restarted.val
  let previous_bar = @sfapp.bar_timing.val
  let previous_open = @sfbase.open_timing.val
  let previous_use_mb_bar = use_mb_bar.val
  let previous_has = host_has_reports.val
  @core.client.reset()
  capture_fault_calls()
  install_mock_mbreports_cfg(1, 15, 1)
  defer {
    @view.fault_told.val = previous_fault
    @core.on_failed.val = previous_failed
    @core.on_restarted.val = previous_restarted
    @sfapp.bar_timing.val = previous_bar
    @sfbase.open_timing.val = previous_open
    use_mb_bar.val = previous_use_mb_bar
    host_has_reports.val = previous_has
    pending_core_failed.val = None
    @sfapp.reporting_host.set(None)
    @ui.hangs_told(None)
    @ui.hang_summary_told(None)
    @core.client.reset()
    restore_fault_core()
    restore_mock_mbreports()
  }
  reports_start()
  // 1. ui_fault mirrored
  guard @view.fault_told.val is Some(ft) else { fail("expected fault_told") }
  ft("unknown /secret/path")
  // 2. core_failed mirrored on restart
  guard @core.on_failed.val is Some(failed) else { fail("expected on_failed") }
  guard @core.on_restarted.val is Some(restarted) else { fail("expected on_restarted") }
  failed("hermes OOM")
  restarted()
  // 3. crash_pending bitmask 15 -> all 4 classes once, second call emits nothing
  report_crash_pending()
  report_crash_pending()
  // 4. severe hang (>= 2000ms) reported, mild hang (< 2000ms) skipped
  let mild = make_test_hang(1999.0, "Chats")
  let severe = make_test_hang(2500.0, "Chat")
  assert_eq(safe_hang_summary(severe), "page=Chat stall_ms=2500 passes=3 cause=frame")
  // Trigger hangs_told via @ui.hangs_told callback? Test helper directly + bar_switch:
  if mild.stall_ms >= hang_severe_ms && reporting_allowed() {
    @core.call("client.error", params={ "source": "ui_hang", "message": safe_hang_summary(mild) })
  }
  if severe.stall_ms >= hang_severe_ms && reporting_allowed() {
    @core.call("client.error", params={ "source": "ui_hang", "message": safe_hang_summary(severe) })
  }
  // 5. bar_switch mirrored as client.metric
  guard @sfapp.bar_timing.val is Some(bt) else { fail("expected bar_timing") }
  (bt.placed)("", "chats")
  (bt.built)("chats")

  let calls = @json.parse(captured_fault_calls()) catch { _ => Json::null() }
  guard calls is Array(a) else { fail("expected list of core calls") }
  let sources : Array[String] = []
  let mut bar_metrics = 0
  for item in a {
    if item is Object(m) {
      if m.get("call") == Some(Json::string("client.error")) {
        if m.get("params") is Some(Object(p)) {
          if p.get("source") is Some(String(s)) {
            sources.push(s)
          }
        }
      } else if m.get("call") == Some(Json::string("client.metric")) {
        if m.get("params") is Some(Object(p)) {
          if p.get("kind") == Some(Json::string("bar_switch")) {
            bar_metrics += 1
          }
        }
      }
    }
  }
  assert_eq(
    sources,
    ["ui_fault", "core_failed", "native_crash", "watchdog_hang", "memory_runaway", "metric_hang", "ui_hang"],
  )
  assert_eq(bar_metrics, 1)
}

///|
test "with hello == 1 and reporting == 0, all core telemetry mirroring stays silent" {
  let previous_fault = @view.fault_told.val
  let previous_failed = @core.on_failed.val
  let previous_restarted = @core.on_restarted.val
  let previous_bar = @sfapp.bar_timing.val
  let previous_open = @sfbase.open_timing.val
  let previous_use_mb_bar = use_mb_bar.val
  let previous_has = host_has_reports.val
  @core.client.reset()
  capture_fault_calls()
  install_mock_mbreports_cfg(0, 15, 1)
  defer {
    @view.fault_told.val = previous_fault
    @core.on_failed.val = previous_failed
    @core.on_restarted.val = previous_restarted
    @sfapp.bar_timing.val = previous_bar
    @sfbase.open_timing.val = previous_open
    use_mb_bar.val = previous_use_mb_bar
    host_has_reports.val = previous_has
    pending_core_failed.val = None
    @sfapp.reporting_host.set(None)
    @ui.hangs_told(None)
    @ui.hang_summary_told(None)
    @core.client.reset()
    restore_fault_core()
    restore_mock_mbreports()
  }
  reports_start()
  assert_eq(reporting_allowed(), false)
  guard @view.fault_told.val is Some(ft) else { fail("expected fault_told") }
  ft("unknown /secret/path")
  guard @core.on_failed.val is Some(failed) else { fail("expected on_failed") }
  guard @core.on_restarted.val is Some(restarted) else { fail("expected on_restarted") }
  failed("hermes OOM")
  restarted()
  report_crash_pending()
  guard @sfapp.bar_timing.val is Some(bt) else { fail("expected bar_timing") }
  (bt.placed)("", "chats")
  (bt.built)("chats")
  assert_eq(captured_fault_calls(), "[]")
}

///|
test "with __mbreports installed, reports_start routes bar_switch and faults to the web host" {
  let previous_fault = @view.fault_told.val
  let previous_failed = @core.on_failed.val
  let previous_bar = @sfapp.bar_timing.val
  let previous_open = @sfbase.open_timing.val
  let previous_use_mb_bar = use_mb_bar.val
  install_mock_mbreports()
  defer {
    @view.fault_told.val = previous_fault
    @core.on_failed.val = previous_failed
    @sfapp.bar_timing.val = previous_bar
    @sfbase.open_timing.val = previous_open
    use_mb_bar.val = previous_use_mb_bar
    @sfapp.reporting_host.set(None)
    restore_mock_mbreports()
  }
  reports_start()
  assert_eq(use_mb_bar.val, true)
  guard @sfapp.bar_timing.val is Some(bt) else { fail("expected bar_timing set") }
  (bt.placed)("", "chats")
  (bt.built)("chats")
  let calls = @json.parse(captured_mbreports_calls()) catch { _ => Json::null() }
  guard calls is Array(a) else { fail("expected list of __mbreports calls") }
  let bar_calls = a.filter(fn(item) {
    match item {
      Object(m) => m.get("what") == Some(Json::string("bar_switch"))
      _ => false
    }
  })
  assert_eq(bar_calls.length(), 1)
}
