// Signed in with a workspace in view, on the tape (laid out Medium with a sidebar to show: sfdesk's tape_holds): the
// shell as nodes of the window's tree (mbui's view package, the way there's 4), made once, its panels
// the tape's nodes (sfdesk's tape_view.mbt), what a page they hold that is not made as nodes yet an old view of its own:
//
//   - under all of it, the window's top dragging it (wide_top_node); what the old frame does in every tier before its
//     pages and under the tape's panels (the sidebar as it was left, the chat landed on) is its own (view_in:
//     signed_in_frame, sfdesk's tape_under);
//   - the tape: its row of panels, moved as its move says;
//   - over it, words picked let go by back first (pick_back_node) and what opens over the panels (sfdesk's
//     overlays_node: the system's bars' mark, a right click's menu, the rail's, 待处理's panel), nodes of the tree's;
//     the presenters told the app is under them by the old frame after its old views (view_in);
//   - over all of it, the chat being shared as a picture, a visualization over the whole screen, a station's screen or
//     terminal or a
//     drive's text read, and an image opened: nodes of the tree's (sfpages' publish_layer_node, sfbase's
//     viz_full_layer_node, wide_page, wide_viewer).

///|
/// The tape's shell (above), in node `v`.
fn taped_shell(v : @view.View, src : Source) -> Unit {
  // (on the tape's ground, the sidebar's, as the old frame's tape was: what no panel covers shows it)
  v.ground(By(fn() { @sf.theme().p.sidebar })) |> ignore
  wide_top_node(v)
  // a page opened in the page's panel shows once the core has given what it shows, the one before staying till then
  // (page_local_ms at most), as a page pushed on a phone slides in then
  @sfdesk.tape_view(v, src, ready=fn(p) { pane_ready(src, p) }, most=page_local_ms)
  pick_back_node(v, src)
  // what opens over the panels (sfdesk's overlays.mbt: a right click's menu, the rail's, 待处理's panel): nodes of the tree's
  @sfdesk.overlays_node(v, src)
  // what the person's devices waiting on this one put up (narrow_shell's signed_in_prompts)
  signed_in_prompts(v, src)
  // the chat being shared as a picture, and a visualization over the whole screen: nodes of the tree's of their own
  // (sfpages' publish.mbt, sfbase's viz_page.mbt)
  @sfpages.publish_layer_node(v, src)
  viz_full_layer_node(v, src)
  // a tab of the side panel over the whole window (sfdesk's tab_full_node.mbt)
  @sfdesk.tab_full_layer_node(v, src)
  // ⌘K's panel over the frame (sfdesk's switcher.mbt), ⌘/'s shortcuts as the shell's keys_open says (shortcuts.mbt)
  @sfdesk.switcher_node(v, src)
  @sfdesk.keys_dialog_node(v, src, @sfdesk.wide.keys_open)
  wide_page(v, src)
  wide_viewer(v, src)
  // a workspace switched shows once all its rail, sidebar and the page its pane lands on open on is answered (sfdesk's
  // frame_opens), the screen as it was till then (sfbase's workspace_switch_node)
  @sfbase.workspace_switch_node(v, src, @sfdesk.frame_opens)
}

///|
/// The wide frame off the tape (laid out Large, or with no sidebar to show), in node `v`: what the frame does in every
/// tier under all of it, the page and the block (sfdesk's pane_view.mbt), what opens over them (as taped_shell's).
fn paned_shell(v : @view.View, src : Source) -> Unit {
  // (on the page's ground, as the old frame's row was: what nothing covers shows it)
  v.ground(By(fn() { @sf.theme().p.bg })) |> ignore
  wide_top_node(v)
  // a page opened in the pane shows once the core has given what it shows (page_local_ms at most: pane_page_wait, pane_pages)
  @sfdesk.pane_view(v, src, ready=fn(p) { pane_ready(src, p) }, most=page_local_ms)
  pick_back_node(v, src)
  // what opens over the panels (sfdesk's overlays.mbt: a right click's menu, the rail's, 待处理's panel): nodes of the tree's
  @sfdesk.overlays_node(v, src)
  // what the person's devices waiting on this one put up (narrow_shell's signed_in_prompts)
  signed_in_prompts(v, src)
  // the chat being shared as a picture, and a visualization over the whole screen: nodes of the tree's of their own
  // (sfpages' publish.mbt, sfbase's viz_page.mbt)
  @sfpages.publish_layer_node(v, src)
  viz_full_layer_node(v, src)
  // a tab of the side panel over the whole window (sfdesk's tab_full_node.mbt)
  @sfdesk.tab_full_layer_node(v, src)
  // ⌘K's panel over the frame (sfdesk's switcher.mbt), ⌘/'s shortcuts as the shell's keys_open says (shortcuts.mbt)
  @sfdesk.switcher_node(v, src)
  @sfdesk.keys_dialog_node(v, src, @sfdesk.wide.keys_open)
  wide_page(v, src)
  wide_viewer(v, src)
  // (a workspace switched: as taped_shell's)
  @sfbase.workspace_switch_node(v, src, @sfdesk.frame_opens)
}

///|
/// What a wide frame shows over all of it while it is on top: a station's screen (screen_node), its terminal
/// (terminal_node), a drive's text read (sfpages' reader_page_node) or its video or song played (sfpages'
/// play_page_node).
#derive(Eq)
priv enum WideTop {
  Scr(ScreenAt)
  Term(@sfbase.TerminalAt)
  Read(DriveAt)
  Play(DriveAt)
}

///|
/// Register a wide fullscreen sub-page (`Scr`/`Term`/`Read`/`Play`) on the unified overlay stack via
/// `@sf.fullscreen_overlay_node` without binding Escape (so Escape inside Terminal or Screen stays
/// theirs), wiring system Back (`takes_back`) separately to `close`.
fn wide_page_overlay(n : @view.View, close : () -> Unit) -> Unit {
  @sf.fullscreen_overlay_node(n, close, dismiss_on_escape=false) |> ignore
  n.takes_back(close) |> ignore
}

///|
/// A station's screen (sfpages' screen_node), its terminal, a drive's text read or its film played on top over the wide
/// frame, over all of it: nodes of the tree's of its own, one structure for them, a modal layer while it is on top, back
/// closing it; made again for another.
fn wide_page(v : @view.View, src : Source) -> Unit {
  v.pick(
    at_once=true,
    fn() {
      match app.nav.top() {
        Screen(at) => Some(Scr(at))
        Terminal(at) => Some(Term(at))
        DriveRead(at) => Some(Read(at))
        DrivePlay(at) => Some(Play(at))
        _ => None
      }
    },
    fn(n, top) {
      match top {
        Some(Scr(at)) => {
          // (back as the page has it: in 全屏 out of it first, its own back key's; else closed, as the stack's)
          wide_page_overlay(n, fn() { @sfbase.close_page(Screen(at)) |> ignore })
          @sfpages.screen_node(n, src, at, fn() { system_frame_at(n.window_w()) })
        }
        Some(Term(at)) => {
          wide_page_overlay(n, fn() { @sfbase.close_page(Terminal(at)) |> ignore })
          let back = fn() {
            let pages = app.nav.pages()
            if pages.length() >= 2 { @sfbase.back_label(pages[pages.length() - 2]) } else { @sf.t("common.back") }
          }
          @sfpages.terminal_pane_node(
            n,
            src,
            at,
            back~,
            on_back=fn() { @sfbase.close_page(Terminal(at)) |> ignore },
            top=fn() { 0.0 },
            width=fn() { n.window_w() },
            on_switch_page=fn(next) { app.nav.replace(next) },
          )
        }
        Some(Read(at)) => {
          wide_page_overlay(n, fn() { @sfbase.close_page(DriveRead(at)) |> ignore })
          @sfpages.reader_page_node(n, src, at)
        }
        Some(Play(at)) => {
          wide_page_overlay(n, fn() { @sfbase.close_page(DrivePlay(at)) |> ignore })
          @sfpages.play_page_node(n, src, at)
        }
        None => ()
      }
    },
  )
}

///|
/// An image opened over the wide frame, over all of it (as narrow_shell's over its pages and bar): nodes of the
/// tree's of its own (sfbase's viewer_tree.mbt), its stage the whole window but for the column of the system's bars
/// down its trailing edge (an iPhone Duo's on its side: @sf.native_clear), followed; what is opened otherwise the old
/// view's over the panels (sfdesk's overlays.mbt).
fn wide_viewer(v : @view.View, src : Source) -> Unit {
  @sfbase.viewer_node(v, src, fn() {
    let (w, h) = v.window()
    (dmax(0.0, w - @sf.native_clear()), h)
  })
}

///|
/// The window's top in the wide frame, under all of it in node `v` (taped_shell's, paned_shell's), where the desktop app
/// has no title bar of the system's: a press on it that nothing over it takes drags the window, a double click does what
/// the system's title bar does; as tall as the window's band (entry_tree's) or the row the window's buttons are in
/// (sfdesk's closed_bar_top, title_row's), whichever is taller.
fn wide_top_node(v : @view.View) -> Unit {
  v.show(fn() { @ui.window_inset_now() }, fn(o) {
    o.over(Is(true)) |> ignore
    o.box(fn(b) {
      b.height(By(fn() { Some(dmax(window_band_now(), @sfdesk.closed_bar_top)) })).moves_window(Is(true)) |> ignore
    })
    |> ignore
  })
}

///|
/// Back lets go of words picked before it goes back a page (pick.mbt's pick_back), in node `v` (a wide shell's, over its
/// panels, under what opens over them): while words are picked, with a workspace in view.
fn pick_back_node(v : @view.View, src : Source) -> Unit {
  v.show(at_once=true, fn() { workspace_in_view(src).0 is Some(_) && @sfbase.picked.get().ts != "" }, fn(b) {
    b.over(Is(true)).takes_back(fn() { pick_clear() }) |> ignore
  })
}
