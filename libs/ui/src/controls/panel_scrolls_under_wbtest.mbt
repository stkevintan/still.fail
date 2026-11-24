// A small panel beside what opened it over a list that scrolls (panel_nodes' `scrolls_under`): the wheel over the list
// moves it while the panel stays open, where the panel says so; else its modal layer keeps the wheel from it, as ever.

///|
/// A list 2000 high under a window 800 by 500 and a small panel opened beside a point over it (`scrolls_under` as
/// given). How far the list has scrolled.
fn scrolls_under_rig(scrolls_under : Bool) -> (@ui.Tester, () -> Double) {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=500.0, platform=0)
  t.check_looks(false)
  let scroll = @view.Scroll::new()
  let tree : Ref[@view.Tree?] = Ref(None)
  @ui.set_view_app(fn(root) {
    tree.val = Some(root.tree)
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(l) {
      l.height(Is(Some(500.0))) |> ignore
      l.scrolls(scroll, fn(s) { s.box(fn(c) { c.height(Is(Some(2000.0))) |> ignore }) |> ignore }) |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  panel_nodes(
    "",
    fn(v, _) { v.box(fn(w) { w.words(Is("面板里的话")) |> ignore }) |> ignore },
    from=At(80.0, 80.0, 60.0, 24.0),
    heads_itself=true,
    scrolls_under~,
  )
  t.run_for(@ui.move_most_ms)
  (t, fn() { scroll.at(tree.val.unwrap()) })
}

///|
test "a panel that leaves the page to scroll: the wheel over the page moves it, the panel staying open" {
  let (t, list) = scrolls_under_rig(true)
  assert_true(presented_drawn(), msg="open")
  t.wheel(600.0, 400.0, 120.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(list(), 120.0, msg="the page under it moved")
  assert_true(presented_drawn(), msg="the panel stays open")
  // (a wheel on the panel, nothing in it moving by it: on to the page under it too)
  guard t.words().filter(fn(x) { x.0 == "面板里的话" }).last() is Some(w) else { fail("no words") }
  t.wheel(w.1 + w.3 / 2.0, w.2 + w.4 / 2.0, 120.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(list(), 240.0, msg="on the panel: the page under it moved")
  // (a press outside it closes it, as ever)
  t.tap(600.0, 400.0)
  t.run_for(@ui.move_most_ms)
  assert_false(presented_drawn(), msg="closed by a press outside")
  presenters_reset()
}

///|
test "a panel as ever keeps the wheel from the page under its modal layer" {
  let (t, list) = scrolls_under_rig(false)
  assert_true(presented_drawn(), msg="open")
  t.wheel(600.0, 400.0, 120.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(list(), 0.0, msg="kept from input")
  close_all_presented()
  t.run_for(@ui.move_most_ms)
  presenters_reset()
}
