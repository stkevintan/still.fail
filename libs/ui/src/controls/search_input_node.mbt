// The field a list is looked through by, at its top (the settings' list, the archive's page and its sidebar, the chats'
// search come up from its list) as one part: a round ground as tall as the theme's band, the search mark, the field,
// and while it holds words the clear key at its end, inside the ground, as round as it, its cross as far in as the mark.

///|
priv enum SearchInputKind {
  ListTop(ListAt)
  Panel
}

///|
/// Shared body for list-top (`search_input_node`) and panel (`panel_search_input_node`) search fields.
#callsite(autofill(loc))
fn search_input_body(
  parent : @view.View,
  field : @ui.Field,
  placeholder_by : () -> String,
  kind : SearchInputKind,
  shorter : Array[String],
  edited : ((String) -> Unit)?,
  submitted : ((String) -> Unit)?,
  escape : (() -> Bool)?,
  step : ((Int) -> Bool)?,
  step_can : () -> Bool,
  cleared : () -> Unit,
  end : ((@view.View) -> Unit)?,
  loc~ : SourceLoc,
) -> @view.View {
  let held = fn() { field.text() != "" }
  let made : Ref[@view.View?] = Ref(None)
  parent.box(made_for=loc, fn(g) {
    match escape {
      Some(f) =>
        g.on_key(fn(k) {
          let matched = match kind {
            ListTop(_) => k.code == @ui.key_escape && k.mods == 0
            Panel => k.code == @ui.key_escape
          }
          if matched {
            f()
          } else {
            false
          }
        })
        |> ignore
      None => ()
    }
    match step {
      Some(s) =>
        match kind {
          ListTop(_) =>
            g
            .key_context(@headless.combobox_context)
            .on_action(@headless.combobox_next, fn(_) { s(1) }, can=step_can)
            .on_action(@headless.combobox_prev, fn(_) { s(-1) }, can=step_can)
            |> ignore
          Panel =>
            g
            .key_context("Finder")
            .on_action("finder.down", fn(_) { s(1) }, can=step_can)
            .on_action("finder.up", fn(_) { s(-1) }, can=step_can)
            |> ignore
        }
      None => ()
    }
    // (its ground round the field (the search mark, its ends) the field's to a press: a tap there its tap, a long press
    // its 粘贴)
    @ui.field_backdrop(g, field)
    let icon_sz = match kind {
      ListTop(_) => @signals.untracked(fn() { theme().chat_list.band_icon })
      Panel => 14.0
    }
    icon_node(g, "search", icon_sz, By(fn() { theme().p.muted })) |> ignore
    let (ime_action, leaves) = match kind {
      ListTop(_) => (@hostapi.ime_action_search, [])
      Panel => (0, [@ui.key_escape])
    }
    let typed = @ui.field(
      g,
      field,
      placeholder_by~,
      shorter~,
      max_lines=1,
      enter_sends=true,
      ime_action~,
      leaves~,
      size_by=fn() { theme().t.ui },
      line=@signals.untracked(fn() { theme().t.ui_line }),
      // (its placeholder subtle, as the lists' own fields had it)
      colors_by=fn() {
        let p = theme().p
        (p.text, p.subtle, p.accent)
      },
      submitted?,
      edited?,
    )
    typed.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    made.val = Some(typed)
    match kind {
      ListTop(at) => {
        // (its end's room the clear key's while it holds words, a circle as tall as the ground in its round end: its cross
        // as far in from the end as the search mark from the start, the circle moved in by what that takes (none where the
        // circle's own room already holds it))
        style_node(g, fn() {
          let l = theme().chat_list
          let pad = band_pad_in(at)
          let end_room = if held() { room_of(dmax(0.0, pad - (l.band_h - l.band_icon) / 2.0)) } else { room_of(pad) }
          search_input_ground.then(@ui.style(h=Fixed(l.band_h), pl=room_of(pad), pr=end_room))
        })
        g.show(held, fn(k) {
          // (its sizes the native input's, the same all the run (@sf.native_input): read once, as icon_button_node takes
          // them)
          let l = @signals.untracked(fn() { theme().chat_list })
          icon_button_node(
            k,
            "close",
            fn() { t("android-misc.drive.pick.filterClear") },
            fn() {
              field.set("")
              cleared()
              match edited {
                Some(f) => f("")
                None => ()
              }
              typed.ask_focus() |> ignore
            },
            size=l.band_h,
            icon_size=l.band_icon,
          )
          |> ignore
        })
      }
      Panel => {
        panel_search_at_hand_node(typed)
        style_node(g, fn() {
          (if hovered_node(g) || typed.focused() { panel_search_ground_hot } else { panel_search_ground }).then(
            @ui.style(h=Fixed(menu_row_min)),
          )
        })
        g.show(at_once=true, held, fn(cl) {
          // (concentric with the pill's right end: same inset from the right edge as from top and bottom)
          cl.margin(By(fn() { (0.0, 0.0, (menu_row_min - 20.0) / 2.0 - @ui.Space::px(S3), 0.0) })) |> ignore
          icon_button_node(
            cl,
            "close",
            fn() { t("web-pages.drive.pickClear") },
            fn() {
              field.set("")
              cleared()
              match edited {
                Some(f) => f("")
                None => ()
              }
              // (never force focus on touch: clearing a filter in a sheet/panel should not raise the soft keyboard)
              if !(@ui.pointing() is Finger) && !(native_input() is Finger) {
                typed.ask_focus() |> ignore
              }
            },
            size=20.0,
            icon_size=12.0,
          )
          |> ignore
        })
      }
    }
    match end {
      Some(f) => f(g)
      None => ()
    }
  })
  |> ignore
  made.val.unwrap()
}

///|
/// A field to look through a list by in `parent`, standing where its list stands (`at`): its round ground (search_ground,
/// a capsule as tall as the theme's band), the search mark and its words as far in from its ends as `at` has them
/// (band_pad_in), and while it holds words the clear key at its end in the ground's end room, a circle as tall as the
/// ground, its cross as far in from the end as the mark from the start: pressed, `field` emptied (`cleared` told) and
/// the focus back in it.
/// `placeholder_by`: what it says while empty (`shorter` ways where it has less room); `edited`: its words as the
/// person changes them; `submitted`: its words at Enter or the keyboard's search key, once (none: Enter as the layer
/// it is in has it); `escape`: Escape pressed in it, true where that was taken (none: Escape left to what holds it);
/// `step`: ↓ (1) and ↑ (-1) in it, as a combobox's keys come from its field (the keymap's actions), taken while
/// `step_can` says so and where `step` says it took them (none: the arrows left to what holds it).
/// `end`: what stands at its end after the clear key (a count, a filter). The field's node (what the focus is given
/// to).
#callsite(autofill(loc))
pub fn search_input_node(
  parent : @view.View,
  field : @ui.Field,
  placeholder_by : () -> String,
  at? : ListAt = Whole,
  shorter? : Array[String] = [],
  edited? : (String) -> Unit,
  submitted? : (String) -> Unit,
  escape? : () -> Bool,
  step? : (Int) -> Bool,
  step_can? : () -> Bool = fn() { true },
  cleared? : () -> Unit = fn() {  },
  end? : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  search_input_body(
    loc~,
    parent,
    field,
    placeholder_by,
    ListTop(at),
    shorter,
    edited,
    submitted,
    escape,
    step,
    step_can,
    cleared,
    end,
  )
}

///|
/// Compact search field inside a panel or sheet (`menu_row_min` tall capsule on `Tint`/`TintStrong`, 14pt search mark,
/// reactive `placeholder_by`, concentric 20pt clear key, `panel_search_at_hand_node` auto-focus). Uses the `"Finder"`
/// key context (`"finder.down"` / `"finder.up"`) gated by `step_can`; Escape clears non-empty text (calling `edited("")`)
/// and consumes the key, or bubbles to close the panel when already empty.
#callsite(autofill(loc))
pub fn panel_search_input_node(
  parent : @view.View,
  field : @ui.Field,
  placeholder_by : () -> String,
  edited? : (String) -> Unit,
  submitted? : (String) -> Unit,
  step? : (Int) -> Bool,
  step_can? : () -> Bool = fn() { true },
  loc~ : SourceLoc,
) -> @view.View {
  search_input_body(
    loc~,
    parent,
    field,
    placeholder_by,
    Panel,
    [],
    edited,
    submitted,
    Some(fn() {
      if field.text() != "" {
        field.set("")
        match edited {
          Some(f) => f("")
          None => ()
        }
        true
      } else {
        false
      }
    }),
    step,
    step_can,
    fn() {  },
    None,
  )
}

///|
/// search_input_node's ground: a row across, its parts 8 apart in its middle, round as a capsule, the search's grey.
// kept across runs: a value (no field of it changes)
let search_input_ground : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter radius=Full").then(@ui.style(bg=search_ground))

///|
/// panel_search_input_node's ground at rest: a capsule on the words' tint.
// kept across runs: a value (no field of it changes)
let panel_search_ground : @ui.Style = @ui.css("row w=Full px=S3 gap=S2 align=ACenter radius=Full bg=Tint")

///|
/// panel_search_input_node's ground when pointed at or focused.
// kept across runs: a value (no field of it changes)
let panel_search_ground_hot : @ui.Style = @ui.css("row w=Full px=S3 gap=S2 align=ACenter radius=Full bg=TintStrong")
