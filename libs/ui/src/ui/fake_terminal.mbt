// The Tester's terminals (hostapi/terminal.mbt): an in-memory VT grid speaking the exact binary dirty-row frame
// protocol, mode bitmask, scrollback viewport, word/line/range selection, formatted plain text and SGR mouse encoding
// that libghostty-vt speaks on native and Wasm hosts.

///|
priv struct FakeCell {
  ch : String
  width : Int // 1 narrow, 2 wide head, 0 wide tail spacer
  sflags : Int // GhosttyStyleFlags bits 0..10 + 2048 has_fg + 4096 has_bg + 8192 has_ul
  fg : (Int, Int, Int)
  bg : (Int, Int, Int)
  ul : (Int, Int, Int)
}

///|
// kept across runs: a value (no field of it changes)
let fake_blank_cell : FakeCell = {
  ch: "",
  width: 1,
  sflags: 0,
  fg: (0, 0, 0),
  bg: (0, 0, 0),
  ul: (0, 0, 0),
}

///|
priv struct FakeTerminal {
  mut cols : Int
  mut rows : Int
  // Primary scrollback + active screen rows (at least `rows` lines)
  mut grid : Array[Array[FakeCell]]
  row_wrapped : Array[Bool]
  mut alt_grid : Array[Array[FakeCell]]
  mut cx : Int
  mut cy : Int
  mut saved_cx : Int
  mut saved_cy : Int
  mut cur_vis : Bool
  mut cur_blink : Bool
  mut cur_style : Int
  mut sflags : Int
  mut fg : (Int, Int, Int)
  mut bg : (Int, Int, Int)
  mut ul : (Int, Int, Int)
  mut def_fg : (Int, Int, Int)?
  mut def_bg : (Int, Int, Int)?
  mut cur_rgb : (Int, Int, Int)?
  mut decckm : Bool
  mut paste : Bool
  mut mouse_mode : Int // 0 off, 1000 click, 1002 drag, 1003 any
  mut mouse_sgr : Bool
  mut alt_screen : Bool
  mut alt_scroll : Bool
  mut focus_ev : Bool
  // Viewport offset from top of `grid` (`grid.length() - rows` = active bottom)
  mut vp_top : Int
  // Selection in `grid` (or `alt_grid`) absolute coordinates: ((x0, y0), (x1, y1))
  mut sel : ((Int, Int), (Int, Int))?
  mut drag_anchor : (Int, Int)?
  mut dirty_all : Bool
  dirty_rows : Set[Int]
  mut last_mouse_col : Int
  mut last_mouse_row : Int
  mut buttons_down : Int
}

///|
// kept across runs: a Tester's terminals by their ids, the next id (each run opens its own)
let fake_terminals : Map[Int, FakeTerminal] = Map([])

///|
// kept across runs: see fake_terminals
let fake_terminal_next : Ref[Int] = Ref(0)

///|
fn fake_ansi_rgb(code : Int) -> (Int, Int, Int) {
  match code {
    0 => (0x2e, 0x34, 0x40)
    1 => (0xe0, 0x6c, 0x75)
    2 => (0x98, 0xc3, 0x79)
    3 => (0xe5, 0xc0, 0x7b)
    4 => (0x61, 0xaf, 0xef)
    5 => (0xc6, 0x78, 0xdd)
    6 => (0x56, 0xb6, 0xc2)
    7 => (0xab, 0xb2, 0xbf)
    8 => (0x8a, 0x91, 0x9e)
    9 => (0xf4, 0x70, 0x67)
    10 => (0xb5, 0xce, 0xa8)
    11 => (0xdc, 0xdc, 0xaa)
    12 => (0x79, 0xc0, 0xff)
    13 => (0xd2, 0xa8, 0xff)
    14 => (0x76, 0xe3, 0xea)
    15 => (0xff, 0xff, 0xff)
    16..=231 => {
      let idx = code - 16
      let r = idx / 36
      let g = idx / 6 % 6
      let b = idx % 6
      let lv = fn(v : Int) { if v == 0 { 0 } else { 55 + v * 40 } }
      (lv(r), lv(g), lv(b))
    }
    232..=255 => {
      let g = 8 + (code - 232) * 10
      (g, g, g)
    }
    _ => (0xd8, 0xd9, 0xdb)
  }
}

///|
fn fake_char_width(ch : Char) -> Int {
  let cp = ch.to_int()
  if (cp >= 0x1100 && cp <= 0x115F) ||
    (cp >= 0x2E80 && cp <= 0x303E) ||
    (cp >= 0x3040 && cp <= 0xA4CF) ||
    (cp >= 0xAC00 && cp <= 0xD7A3) ||
    (cp >= 0xF900 && cp <= 0xFAFF) ||
    (cp >= 0xFE10 && cp <= 0xFE6F) ||
    (cp >= 0xFF01 && cp <= 0xFF60) ||
    (cp >= 0xFFE0 && cp <= 0xFFE6) ||
    (cp >= 0x1F300 && cp <= 0x1FAFF) ||
    (cp >= 0x20000 && cp <= 0x3FFFF) {
    2
  } else {
    1
  }
}

///|
fn fake_make_row(cols : Int) -> Array[FakeCell] {
  Array::make(if cols > 0 { cols } else { 1 }, fake_blank_cell)
}

///|
fn fake_active_grid(t : FakeTerminal) -> Array[Array[FakeCell]] {
  if t.alt_screen { t.alt_grid } else { t.grid }
}

///|
fn fake_active_top(t : FakeTerminal) -> Int {
  let g = fake_active_grid(t)
  if g.length() > t.rows { g.length() - t.rows } else { 0 }
}

///|
fn fake_mark_row_dirty(t : FakeTerminal, abs_y : Int) -> Unit {
  let vy = abs_y - t.vp_top
  if vy >= 0 && vy < t.rows {
    t.dirty_rows.add(vy)
  }
}

///|
fn fake_parse_int(s : StringView) -> Int {
  let mut v = 0
  for c in s {
    if c >= '0' && c <= '9' {
      v = v * 10 + (c.to_int() - '0'.to_int())
    }
  }
  v
}

///|
fn fake_hex_val(c : Char) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    10 + c.to_int() - 'a'.to_int()
  } else if c >= 'A' && c <= 'F' {
    10 + c.to_int() - 'A'.to_int()
  } else {
    -1
  }
}

///|
fn fake_parse_osc_rgb(spec : StringView) -> (Int, Int, Int)? {
  let cs = spec.to_owned().to_array()
  if cs.length() == 7 && cs[0] == '#' {
    let r = (fake_hex_val(cs[1]) << 4) | fake_hex_val(cs[2])
    let g = (fake_hex_val(cs[3]) << 4) | fake_hex_val(cs[4])
    let b = (fake_hex_val(cs[5]) << 4) | fake_hex_val(cs[6])
    if r >= 0 && g >= 0 && b >= 0 {
      return Some((r, g, b))
    }
  } else if spec.has_prefix("rgb:") {
    let parts = spec.to_owned().unsafe_substring(start=4, end=spec.length()).split("/").collect()
    if parts.length() == 3 {
      let mut ok = true
      let rgb = [0, 0, 0]
      for k in 0..<3 {
        let pcs = parts[k].to_owned().to_array()
        if pcs.length() >= 2 {
          let hi = fake_hex_val(pcs[0])
          let lo = fake_hex_val(pcs[1])
          if hi >= 0 && lo >= 0 {
            rgb[k] = (hi << 4) | lo
          } else {
            ok = false
          }
        } else {
          ok = false
        }
      }
      if ok {
        return Some((rgb[0], rgb[1], rgb[2]))
      }
    }
  }
  None
}

///|
fn fake_apply_osc(t : FakeTerminal, osc : String) -> Unit {
  let parts = osc.split(";").collect()
  if parts.length() == 0 {
    return
  }
  let code = fake_parse_int(parts[0])
  match code {
    10 if parts.length() >= 2 =>
      if fake_parse_osc_rgb(parts[1]) is Some(rgb) {
        t.def_fg = Some(rgb)
        t.dirty_all = true
      }
    11 if parts.length() >= 2 =>
      if fake_parse_osc_rgb(parts[1]) is Some(rgb) {
        t.def_bg = Some(rgb)
        t.dirty_all = true
      }
    12 if parts.length() >= 2 =>
      if fake_parse_osc_rgb(parts[1]) is Some(rgb) {
        t.cur_rgb = Some(rgb)
        t.dirty_all = true
      }
    110 => {
      t.def_fg = None
      t.dirty_all = true
    }
    111 => {
      t.def_bg = None
      t.dirty_all = true
    }
    112 => {
      t.cur_rgb = None
      t.dirty_all = true
    }
    _ => ()
  }
}

///|
fn fake_apply_sgr(t : FakeTerminal, params : String) -> Unit {
  if params == "" {
    t.sflags = 0
    t.fg = (0, 0, 0)
    t.bg = (0, 0, 0)
    t.ul = (0, 0, 0)
    return
  }
  let parts = params.split(";").collect()
  let mut i = 0
  while i < parts.length() {
    let raw = parts[i]
    if raw.contains(":") {
      let subs = raw.split(":").collect().map(fake_parse_int)
      if subs.length() >= 2 && subs[0] == 4 {
        let style = subs[1].clamp(min=0, max=5)
        t.sflags = (t.sflags & (0x0700).lnot()) | (style << 8)
      } else if subs.length() >= 5 && (subs[0] == 38 || subs[0] == 48 || subs[0] == 58) && subs[1] == 2 {
        let off = if subs.length() >= 6 { 3 } else { 2 }
        let rgb = (
          subs[off].clamp(min=0, max=255),
          subs[off + 1].clamp(min=0, max=255),
          subs[off + 2].clamp(min=0, max=255),
        )
        if subs[0] == 38 {
          t.fg = rgb
          t.sflags = t.sflags | 2048
        } else if subs[0] == 48 {
          t.bg = rgb
          t.sflags = t.sflags | 4096
        } else {
          t.ul = rgb
          t.sflags = t.sflags | 8192
        }
      }
      i += 1
      continue
    }
    let n = fake_parse_int(raw)
    match n {
      0 => {
        t.sflags = 0
        t.fg = (0, 0, 0)
        t.bg = (0, 0, 0)
        t.ul = (0, 0, 0)
      }
      1 => t.sflags = t.sflags | 1
      2 => t.sflags = t.sflags | 4
      3 => t.sflags = t.sflags | 2
      4 => t.sflags = (t.sflags & (0x0700).lnot()) | (1 << 8)
      5 | 6 => t.sflags = t.sflags | 8
      7 => t.sflags = t.sflags | 16
      8 => t.sflags = t.sflags | 32
      9 => t.sflags = t.sflags | 64
      21 => t.sflags = (t.sflags & (0x0700).lnot()) | (2 << 8)
      22 => t.sflags = t.sflags & (1 | 4).lnot()
      23 => t.sflags = t.sflags & (2).lnot()
      24 => t.sflags = t.sflags & (0x0700).lnot()
      25 => t.sflags = t.sflags & (8).lnot()
      27 => t.sflags = t.sflags & (16).lnot()
      28 => t.sflags = t.sflags & (32).lnot()
      29 => t.sflags = t.sflags & (64).lnot()
      53 => t.sflags = t.sflags | 128
      55 => t.sflags = t.sflags & (128).lnot()
      30..=37 => {
        t.fg = fake_ansi_rgb(n - 30)
        t.sflags = t.sflags | 2048
      }
      39 => t.sflags = t.sflags & (2048).lnot()
      40..=47 => {
        t.bg = fake_ansi_rgb(n - 40)
        t.sflags = t.sflags | 4096
      }
      49 => t.sflags = t.sflags & (4096).lnot()
      59 => t.sflags = t.sflags & (8192).lnot()
      90..=97 => {
        t.fg = fake_ansi_rgb(n - 90 + 8)
        t.sflags = t.sflags | 2048
      }
      100..=107 => {
        t.bg = fake_ansi_rgb(n - 100 + 8)
        t.sflags = t.sflags | 4096
      }
      38 | 48 | 58 =>
        if i + 2 < parts.length() && fake_parse_int(parts[i + 1]) == 5 {
          let rgb = fake_ansi_rgb(fake_parse_int(parts[i + 2]))
          if n == 38 {
            t.fg = rgb
            t.sflags = t.sflags | 2048
          } else if n == 48 {
            t.bg = rgb
            t.sflags = t.sflags | 4096
          } else {
            t.ul = rgb
            t.sflags = t.sflags | 8192
          }
          i += 2
        } else if i + 4 < parts.length() && fake_parse_int(parts[i + 1]) == 2 {
          let rgb = (
            fake_parse_int(parts[i + 2]).clamp(min=0, max=255),
            fake_parse_int(parts[i + 3]).clamp(min=0, max=255),
            fake_parse_int(parts[i + 4]).clamp(min=0, max=255),
          )
          if n == 38 {
            t.fg = rgb
            t.sflags = t.sflags | 2048
          } else if n == 48 {
            t.bg = rgb
            t.sflags = t.sflags | 4096
          } else {
            t.ul = rgb
            t.sflags = t.sflags | 8192
          }
          i += 4
        }
      _ => ()
    }
    i += 1
  }
}

///|
fn fake_newline(t : FakeTerminal, soft_wrap : Bool) -> Unit {
  if t.alt_screen {
    if t.cy + 1 < t.rows {
      t.cy += 1
    } else {
      t.alt_grid.remove(0) |> ignore
      t.alt_grid.push(fake_make_row(t.cols))
      t.dirty_all = true
    }
    return
  }
  let was_bottom = t.vp_top >= fake_active_top(t)
  let abs_y = fake_active_top(t) + t.cy
  if soft_wrap && abs_y < t.row_wrapped.length() {
    t.row_wrapped[abs_y] = true
  }
  if t.cy + 1 < t.rows {
    t.cy += 1
  } else {
    t.grid.push(fake_make_row(t.cols))
    t.row_wrapped.push(false)
    if t.grid.length() > 4000 {
      t.grid.remove(0) |> ignore
      t.row_wrapped.remove(0) |> ignore
      if t.vp_top > 0 {
        t.vp_top -= 1
      }
    }
    if was_bottom {
      t.vp_top = fake_active_top(t)
      t.dirty_all = true
    }
  }
}

///|
fn fake_put_char(t : FakeTerminal, ch : Char) -> Unit {
  let w = fake_char_width(ch)
  let g = fake_active_grid(t)
  if t.cx >= t.cols || (w == 2 && t.cx + 1 >= t.cols) {
    t.cx = 0
    fake_newline(t, true)
  }
  let abs_y = fake_active_top(t) + t.cy
  guard abs_y >= 0 && abs_y < g.length() else { return }
  let row = g[abs_y]
  if t.cx < row.length() {
    // Clear orphaned wide half if overwriting
    if row[t.cx].width == 0 && t.cx > 0 {
      row[t.cx - 1] = fake_blank_cell
    } else if row[t.cx].width == 2 && t.cx + 1 < row.length() {
      row[t.cx + 1] = fake_blank_cell
    }
    row[t.cx] = {
      ch: ch.to_string(),
      width: w,
      sflags: t.sflags,
      fg: t.fg,
      bg: t.bg,
      ul: t.ul,
    }
    if w == 2 && t.cx + 1 < row.length() {
      if row[t.cx + 1].width == 2 && t.cx + 2 < row.length() {
        row[t.cx + 2] = fake_blank_cell
      }
      row[t.cx + 1] = { ..fake_blank_cell, width: 0, sflags: t.sflags & 4096, bg: t.bg }
    }
  }
  fake_mark_row_dirty(t, abs_y)
  t.cx += w
}

///|
fn fake_modes_bits(t : FakeTerminal) -> Int {
  let mut m = 0
  if t.decckm {
    m = m | @hostapi.term_mode_decckm
  }
  if t.paste {
    m = m | @hostapi.term_mode_bracketed_paste
  }
  if t.mouse_mode != 0 {
    m = m | @hostapi.term_mode_mouse_tracking
  }
  if t.alt_screen {
    m = m | @hostapi.term_mode_alt_screen
  }
  if t.alt_scroll {
    m = m | @hostapi.term_mode_alt_scroll
  }
  if t.focus_ev {
    m = m | @hostapi.term_mode_focus_event
  }
  if t.sel is Some(_) {
    m = m | @hostapi.term_mode_has_selection
  }
  if t.alt_screen || t.vp_top >= fake_active_top(t) {
    m = m | @hostapi.term_mode_viewport_active
  }
  m
}

///|
fn fake_norm_sel(sel : ((Int, Int), (Int, Int))) -> ((Int, Int), (Int, Int)) {
  let ((x0, y0), (x1, y1)) = sel
  if y0 < y1 || (y0 == y1 && x0 <= x1) {
    ((x0, y0), (x1, y1))
  } else {
    ((x1, y1), (x0, y0))
  }
}

///|
fn fake_push_u8(out : Array[Byte], v : Int) -> Unit {
  out.push((v & 0xff).to_byte())
}

///|
fn fake_push_u16(out : Array[Byte], v : Int) -> Unit {
  out.push((v & 0xff).to_byte())
  out.push(((v >> 8) & 0xff).to_byte())
}

///|
fn fake_push_u32(out : Array[Byte], v : Int) -> Unit {
  out.push((v & 0xff).to_byte())
  out.push(((v >> 8) & 0xff).to_byte())
  out.push(((v >> 16) & 0xff).to_byte())
  out.push(((v >> 24) & 0xff).to_byte())
}

///|
fn FakeHost::tm_open(_ : FakeHost, cols : Int, rows : Int) -> Int {
  let cols = if cols > 0 { cols } else { 80 }
  let rows = if rows > 0 { rows } else { 24 }
  fake_terminal_next.val += 1
  fake_terminals[fake_terminal_next.val] = {
    cols,
    rows,
    grid: Array::makei(rows, fn(_) { fake_make_row(cols) }),
    row_wrapped: Array::make(rows, false),
    alt_grid: Array::makei(rows, fn(_) { fake_make_row(cols) }),
    cx: 0,
    cy: 0,
    saved_cx: 0,
    saved_cy: 0,
    cur_vis: true,
    cur_blink: true,
    cur_style: 1,
    sflags: 0,
    fg: (0, 0, 0),
    bg: (0, 0, 0),
    ul: (0, 0, 0),
    def_fg: None,
    def_bg: None,
    cur_rgb: None,
    decckm: false,
    paste: false,
    mouse_mode: 0,
    mouse_sgr: false,
    alt_screen: false,
    alt_scroll: true,
    focus_ev: false,
    vp_top: 0,
    sel: None,
    drag_anchor: None,
    dirty_all: true,
    dirty_rows: Set([]),
    last_mouse_col: -1,
    last_mouse_row: -1,
    buttons_down: 0,
  }
  fake_terminal_next.val
}

///|
fn FakeHost::tm_write(_ : FakeHost, id : Int, data : Bytes) -> Unit {
  guard fake_terminals.get(id) is Some(t) else { return }
  let text = @utf8.decode_lossy(data)
  let cs = text.to_array()
  let mut i = 0
  while i < cs.length() {
    let c = cs[i]
    match c {
      '\u{1b}' => {
        i += 1
        if i < cs.length() && cs[i] == '[' {
          i += 1
          let start = i
          while i < cs.length() && !(cs[i] >= '@' && cs[i] <= '~') {
            i += 1
          }
          if i < cs.length() {
            let final_ch = cs[i]
            let raw = String::from_array(cs[start:i].to_owned())
            match final_ch {
              'm' => fake_apply_sgr(t, raw)
              'h' | 'l' => {
                let on = final_ch == 'h'
                if raw.has_prefix("?") {
                  for p in raw.unsafe_substring(start=1, end=raw.length()).split(";") {
                    match fake_parse_int(p) {
                      1 => t.decckm = on
                      25 => t.cur_vis = on
                      47 | 1047 | 1049 => {
                        if on && !t.alt_screen {
                          t.saved_cx = t.cx
                          t.saved_cy = t.cy
                          t.alt_grid = Array::makei(t.rows, fn(_) { fake_make_row(t.cols) })
                          t.alt_screen = true
                          t.cx = 0
                          t.cy = 0
                          t.dirty_all = true
                        } else if !on && t.alt_screen {
                          t.alt_screen = false
                          t.cx = t.saved_cx.clamp(min=0, max=t.cols - 1)
                          t.cy = t.saved_cy.clamp(min=0, max=t.rows - 1)
                          t.dirty_all = true
                        }
                      }
                      1000 => t.mouse_mode = if on { 1000 } else { 0 }
                      1002 => t.mouse_mode = if on { 1002 } else { 0 }
                      1003 => t.mouse_mode = if on { 1003 } else { 0 }
                      1004 => t.focus_ev = on
                      1006 => t.mouse_sgr = on
                      1007 => t.alt_scroll = on
                      2004 => t.paste = on
                      _ => ()
                    }
                  }
                }
              }
              'H' | 'f' => {
                let ps = raw.split(";").collect()
                let r = if ps.length() >= 1 && ps[0].length() > 0 { fake_parse_int(ps[0]) - 1 } else { 0 }
                let col = if ps.length() >= 2 && ps[1].length() > 0 { fake_parse_int(ps[1]) - 1 } else { 0 }
                t.cy = r.clamp(min=0, max=t.rows - 1)
                t.cx = col.clamp(min=0, max=t.cols - 1)
              }
              'A' => {
                let n = if raw == "" { 1 } else { dmax(1.0, fake_parse_int(raw[:]).to_double()).to_int() }
                t.cy = (t.cy - n).clamp(min=0, max=t.rows - 1)
              }
              'B' => {
                let n = if raw == "" { 1 } else { dmax(1.0, fake_parse_int(raw[:]).to_double()).to_int() }
                t.cy = (t.cy + n).clamp(min=0, max=t.rows - 1)
              }
              'C' => {
                let n = if raw == "" { 1 } else { dmax(1.0, fake_parse_int(raw[:]).to_double()).to_int() }
                t.cx = (t.cx + n).clamp(min=0, max=t.cols - 1)
              }
              'D' => {
                let n = if raw == "" { 1 } else { dmax(1.0, fake_parse_int(raw[:]).to_double()).to_int() }
                t.cx = (t.cx - n).clamp(min=0, max=t.cols - 1)
              }
              'G' => {
                let n = if raw == "" { 1 } else { fake_parse_int(raw[:]) }
                t.cx = (n - 1).clamp(min=0, max=t.cols - 1)
              }
              'J' => {
                let mode = if raw == "" { 0 } else { fake_parse_int(raw[:]) }
                let g = fake_active_grid(t)
                let top = fake_active_top(t)
                if mode == 2 || mode == 3 {
                  for r in 0..<t.rows {
                    if top + r < g.length() {
                      g[top + r] = fake_make_row(t.cols)
                    }
                  }
                  t.dirty_all = true
                } else if mode == 0 {
                  let y0 = top + t.cy
                  if y0 < g.length() {
                    for x in t.cx..<g[y0].length() {
                      g[y0][x] = fake_blank_cell
                    }
                    fake_mark_row_dirty(t, y0)
                  }
                  for r in (t.cy + 1)..<t.rows {
                    if top + r < g.length() {
                      g[top + r] = fake_make_row(t.cols)
                      fake_mark_row_dirty(t, top + r)
                    }
                  }
                }
              }
              'K' => {
                let mode = if raw == "" { 0 } else { fake_parse_int(raw[:]) }
                let g = fake_active_grid(t)
                let abs_y = fake_active_top(t) + t.cy
                if abs_y < g.length() {
                  let (a, b) = match mode {
                    1 => (0, (t.cx + 1).clamp(min=0, max=g[abs_y].length()))
                    2 => (0, g[abs_y].length())
                    _ => (t.cx.clamp(min=0, max=g[abs_y].length()), g[abs_y].length())
                  }
                  for x in a..<b {
                    g[abs_y][x] = fake_blank_cell
                  }
                  fake_mark_row_dirty(t, abs_y)
                }
              }
              'q' if raw.has_suffix(" ") => {
                let n = fake_parse_int(raw.unsafe_substring(start=0, end=raw.length() - 1)[:])
                match n {
                  0 | 1 => { t.cur_style = 1; t.cur_blink = true }
                  2 => { t.cur_style = 1; t.cur_blink = false }
                  3 => { t.cur_style = 2; t.cur_blink = true }
                  4 => { t.cur_style = 2; t.cur_blink = false }
                  5 => { t.cur_style = 0; t.cur_blink = true }
                  6 => { t.cur_style = 0; t.cur_blink = false }
                  _ => ()
                }
              }
              _ => ()
            }
          }
        } else if i < cs.length() && cs[i] == ']' {
          i += 1
          let osc_buf = StringBuilder()
          while i < cs.length() && cs[i] != '\u{07}' && !(cs[i] == '\\' && cs[i - 1] == '\u{1b}') {
            osc_buf.write_char(cs[i])
            i += 1
          }
          let mut osc = osc_buf.to_string()
          if osc.has_suffix("\u{1b}") {
            osc = osc.unsafe_substring(start=0, end=osc.length() - 1)
          }
          fake_apply_osc(t, osc)
        }
      }
      '\r' => t.cx = 0
      '\n' => fake_newline(t, false)
      '\u{08}' => if t.cx > 0 { t.cx -= 1 }
      '\t' => {
        let next = ((t.cx / 8) + 1) * 8
        t.cx = if next >= t.cols { t.cols - 1 } else { next }
      }
      _ if c.to_int() < 0x20 => ()
      _ => fake_put_char(t, c)
    }
    i += 1
  }
}

///|
fn FakeHost::tm_resize(_ : FakeHost, id : Int, cols : Int, rows : Int, _cw : Int, _ch : Int) -> Unit {
  guard fake_terminals.get(id) is Some(t) else { return }
  let cols = if cols > 0 { cols } else { 1 }
  let rows = if rows > 0 { rows } else { 1 }
  let was_bottom = t.vp_top >= fake_active_top(t)
  let resize_row = fn(r : Array[FakeCell]) -> Array[FakeCell] {
    if r.length() == cols {
      r
    } else if r.length() > cols {
      r[:cols].to_owned()
    } else {
      let next = fake_make_row(cols)
      for k in 0..<r.length() {
        next[k] = r[k]
      }
      next
    }
  }
  t.grid = t.grid.map(resize_row)
  while t.grid.length() < rows {
    t.grid.push(fake_make_row(cols))
    t.row_wrapped.push(false)
  }
  t.alt_grid = Array::makei(rows, fn(i) {
    if i < t.alt_grid.length() { resize_row(t.alt_grid[i]) } else { fake_make_row(cols) }
  })
  t.cols = cols
  t.rows = rows
  t.cx = t.cx.clamp(min=0, max=cols - 1)
  t.cy = t.cy.clamp(min=0, max=rows - 1)
  if was_bottom {
    t.vp_top = fake_active_top(t)
  } else {
    t.vp_top = t.vp_top.clamp(min=0, max=fake_active_top(t))
  }
  t.dirty_all = true
}

///|
fn FakeHost::tm_modes(_ : FakeHost, id : Int) -> Int {
  match fake_terminals.get(id) {
    Some(t) => fake_modes_bits(t)
    None => 0
  }
}

///|
fn FakeHost::tm_scroll(_ : FakeHost, id : Int, kind : Int, value : Int) -> Unit {
  guard fake_terminals.get(id) is Some(t) && !t.alt_screen else { return }
  let max_top = fake_active_top(t)
  let next = match kind {
    0 => (t.vp_top + value).clamp(min=0, max=max_top)
    1 => 0
    2 => max_top
    3 => value.clamp(min=0, max=max_top)
    _ => t.vp_top
  }
  if next != t.vp_top {
    t.vp_top = next
    t.dirty_all = true
  }
}

///|
fn fake_is_word_char(s : String) -> Bool {
  if s == "" || s == " " {
    return false
  }
  let c = s.to_array()[0]
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '-' ||
  c == '.' ||
  c == '/' ||
  c.to_int() >= 0x80
}

///|
fn FakeHost::tm_select(_ : FakeHost, id : Int, kind : Int, x0 : Int, y0 : Int, x1 : Int, y1 : Int) -> Int {
  guard fake_terminals.get(id) is Some(t) else { return 0 }
  let g = fake_active_grid(t)
  let top = if t.alt_screen { 0 } else { t.vp_top }
  match kind {
    0 => {
      if t.sel is Some(_) {
        t.sel = None
        t.drag_anchor = None
        t.dirty_all = true
      }
      0
    }
    4 => {
      t.drag_anchor = None
      if g.is_empty() {
        0
      } else {
        t.sel = Some(((0, 0), (t.cols - 1, g.length() - 1)))
        t.dirty_all = true
        1
      }
    }
    2 => {
      t.drag_anchor = None
      let cy = (top + y0.clamp(min=0, max=t.rows - 1)).clamp(min=0, max=g.length() - 1)
      let mut cx = x0.clamp(min=0, max=t.cols - 1)
      let row = g[cy]
      if row[cx].width == 0 && cx > 0 {
        cx -= 1
      }
      if !fake_is_word_char(row[cx].ch) {
        let end_x = if row[cx].width == 2 && cx + 1 < t.cols { cx + 1 } else { cx }
        t.sel = Some(((cx, cy), (end_x, cy)))
      } else {
        let mut a = cx
        while a > 0 {
          let prev = if row[a - 1].width == 0 && a >= 2 { a - 2 } else { a - 1 }
          if fake_is_word_char(row[prev].ch) { a = prev } else { break }
        }
        let mut b = cx
        while b < row.length() {
          let w = if row[b].width == 2 { 2 } else { 1 }
          if b + w < row.length() && fake_is_word_char(row[b + w].ch) {
            b += w
          } else {
            b = (b + w - 1).clamp(min=0, max=t.cols - 1)
            break
          }
        }
        t.sel = Some(((a, cy), (b, cy)))
      }
      t.dirty_all = true
      1
    }
    3 => {
      t.drag_anchor = None
      let cy = (top + y0.clamp(min=0, max=t.rows - 1)).clamp(min=0, max=g.length() - 1)
      t.sel = Some(((0, cy), (t.cols - 1, cy)))
      t.dirty_all = true
      1
    }
    1 => {
      let cx0 = x0.clamp(min=0, max=t.cols - 1)
      let cy0 = (top + y0.clamp(min=0, max=t.rows - 1)).clamp(min=0, max=g.length() - 1)
      let anchor = match t.drag_anchor {
        Some(a) => a
        None => {
          t.drag_anchor = Some((cx0, cy0))
          (cx0, cy0)
        }
      }
      let cx1 = x1.clamp(min=0, max=t.cols - 1)
      let cy1 = (top + y1.clamp(min=0, max=t.rows - 1)).clamp(min=0, max=g.length() - 1)
      t.sel = Some((anchor, (cx1, cy1)))
      t.dirty_all = true
      1
    }
    _ => 0
  }
}

///|
fn fake_row_slice_trimmed(row : Array[FakeCell], a : Int, b : Int) -> String {
  let buf = StringBuilder()
  let end = b.clamp(min=0, max=row.length() - 1)
  for x in a.clamp(min=0, max=row.length() - 1)..<=end {
    let cell = row[x]
    if cell.width == 0 {
      continue
    }
    buf.write_string(if cell.ch == "" { " " } else { cell.ch })
  }
  let s = buf.to_string()
  let cs = s.to_array()
  let mut n = cs.length()
  while n > 0 && cs[n - 1] == ' ' {
    n -= 1
  }
  String::from_array(cs[:n].to_owned())
}

///|
fn FakeHost::tm_text(_ : FakeHost, id : Int, sel_only : Int) -> String {
  guard fake_terminals.get(id) is Some(t) else { return "" }
  let g = fake_active_grid(t)
  if sel_only != 0 {
    guard t.sel is Some(raw_sel) else { return "" }
    let ((x0, y0), (x1, y1)) = fake_norm_sel(raw_sel)
    let out = StringBuilder()
    for y in y0..<=y1 {
      if y < 0 || y >= g.length() {
        continue
      }
      let a = if y == y0 { x0 } else { 0 }
      let b = if y == y1 { x1 } else { t.cols - 1 }
      out.write_string(fake_row_slice_trimmed(g[y], a, b))
      if y < y1 {
        let wrapped = !t.alt_screen && y < t.row_wrapped.length() && t.row_wrapped[y] && b == t.cols - 1
        if !wrapped {
          out.write_char('\n')
        }
      }
    }
    return out.to_string()
  }
  let top = if t.alt_screen { 0 } else { t.vp_top }
  let lines : Array[String] = []
  for r in 0..<t.rows {
    if top + r < g.length() {
      lines.push(fake_row_slice_trimmed(g[top + r], 0, t.cols - 1))
    }
  }
  while !lines.is_empty() && lines[lines.length() - 1] == "" {
    lines.pop() |> ignore
  }
  lines.join("\n")
}

///|
fn FakeHost::tm_mouse(_ : FakeHost, id : Int, action : Int, button : Int, mods : Int, x : Int, y : Int, _w : Int, _h : Int, cw : Int, ch : Int) -> Bytes {
  guard fake_terminals.get(id) is Some(t) && t.mouse_mode != 0 else { return Bytes::make(0, b'\x00') }
  let cw = if cw > 0 { cw } else { 8 }
  let ch = if ch > 0 { ch } else { 16 }
  let col = (x / cw).clamp(min=0, max=t.cols - 1) + 1
  let row = (y / ch).clamp(min=0, max=t.rows - 1) + 1
  if action == 2 {
    if t.mouse_mode == 1000 || (t.mouse_mode == 1002 && t.buttons_down == 0) {
      return Bytes::make(0, b'\x00')
    }
    if col == t.last_mouse_col && row == t.last_mouse_row {
      return Bytes::make(0, b'\x00')
    }
  }
  t.last_mouse_col = col
  t.last_mouse_row = row
  if action == 0 && button >= 1 && button <= 3 {
    t.buttons_down = t.buttons_down | (1 << button)
  } else if action == 1 && button >= 1 && button <= 3 {
    t.buttons_down = t.buttons_down & (1 << button).lnot()
  }
  let mut code = match button {
    1 => 0
    3 => 1
    2 => 2
    4 => 64
    5 => 65
    6 => 66
    7 => 67
    _ => 3
  }
  if action == 2 {
    code += 32
  }
  if (mods & 1) != 0 {
    code += 4
  }
  if (mods & 4) != 0 {
    code += 8
  }
  if (mods & 2) != 0 {
    code += 16
  }
  if t.mouse_sgr {
    let suffix = if action == 1 && button < 4 { "m" } else { "M" }
    @utf8.encode("\u{1b}[<\{code};\{col};\{row}\{suffix}")
  } else if col <= 223 && row <= 223 {
    let cb = if action == 1 && button < 4 { 3 + (code & 28) } else { code }
    Bytes::from_array([0x1b, '['.to_int().to_byte(), 'M'.to_int().to_byte(), (cb + 32).to_byte(), (col + 32).to_byte(), (row + 32).to_byte()])
  } else {
    Bytes::make(0, b'\x00')
  }
}

///|
fn FakeHost::tm_frame(_ : FakeHost, id : Int, flags : Int) -> Bytes {
  guard fake_terminals.get(id) is Some(t) else { return Bytes::make(0, b'\x00') }
  let g = fake_active_grid(t)
  let top = if t.alt_screen { 0 } else { t.vp_top }
  let force_full = (flags & 1) != 0 || t.dirty_all
  let dirty = if force_full { 2 } else if !t.dirty_rows.is_empty() { 1 } else { 0 }

  let act_top = fake_active_top(t)
  let cur_vy = act_top + t.cy - top
  let cur_in_vp = t.cur_vis && cur_vy >= 0 && cur_vy < t.rows
  let mut cur_flags = 0
  if cur_in_vp {
    cur_flags = cur_flags | 1
  }
  if t.cur_blink {
    cur_flags = cur_flags | 2
  }
  if t.cur_rgb is Some(_) {
    cur_flags = cur_flags | 8
  }
  if t.def_fg is Some(_) {
    cur_flags = cur_flags | 16
  }
  if t.def_bg is Some(_) {
    cur_flags = cur_flags | 32
  }
  let (fg_r, fg_g, fg_b) = t.def_fg.unwrap_or((0, 0, 0))
  let (bg_r, bg_g, bg_b) = t.def_bg.unwrap_or((0, 0, 0))
  let (cr_r, cr_g, cr_b) = t.cur_rgb.unwrap_or((0, 0, 0))
  let modes = fake_modes_bits(t)

  let out : Array[Byte] = Array(capacity=256)
  fake_push_u8(out, 1)
  fake_push_u8(out, dirty)
  fake_push_u16(out, t.cols)
  fake_push_u16(out, t.rows)
  fake_push_u16(out, if cur_in_vp { t.cx } else { 0 })
  fake_push_u16(out, if cur_in_vp { cur_vy } else { 0 })
  fake_push_u8(out, t.cur_style)
  fake_push_u8(out, cur_flags)
  fake_push_u16(out, modes)
  fake_push_u8(out, fg_r)
  fake_push_u8(out, fg_g)
  fake_push_u8(out, fg_b)
  fake_push_u8(out, bg_r)
  fake_push_u8(out, bg_g)
  fake_push_u8(out, bg_b)
  fake_push_u8(out, cr_r)
  fake_push_u8(out, cr_g)
  fake_push_u8(out, cr_b)
  fake_push_u8(out, 0)
  fake_push_u32(out, g.length())
  fake_push_u32(out, top)
  fake_push_u32(out, t.rows)
  let row_count_at = out.length()
  fake_push_u16(out, 0)
  fake_push_u32(out, 0)

  let norm_sel = t.sel.map(fake_norm_sel)
  let mut row_count = 0
  if dirty != 0 {
    for vy in 0..<t.rows {
      if !force_full && !t.dirty_rows.contains(vy) {
        continue
      }
      let abs_y = top + vy
      let (sel_start, sel_end) = match norm_sel {
        Some(((sx0, sy0), (sx1, sy1))) if abs_y >= sy0 && abs_y <= sy1 => {
          let a = if abs_y == sy0 { sx0 } else { 0 }
          let b = if abs_y == sy1 { sx1 } else { t.cols - 1 }
          (a, b)
        }
        _ => (0xffff, 0xffff)
      }
      fake_push_u16(out, vy)
      fake_push_u16(out, sel_start)
      fake_push_u16(out, sel_end)
      let cell_count_at = out.length()
      fake_push_u16(out, 0)
      let mut cell_count = 0
      if abs_y >= 0 && abs_y < g.length() {
        let row = g[abs_y]
        for col in 0..<row.length() {
          let cell = row[col]
          if cell.width == 0 {
            continue
          }
          let utf8 = if cell.ch == "" || cell.ch == " " { Bytes::make(0, b'\x00') } else { @utf8.encode(cell.ch) }
          let cell_bg = (cell.sflags & 4096) != 0
          if utf8.length() == 0 && !cell_bg && (cell.sflags & (16 | 64 | 128 | 0x0700)) == 0 {
            continue
          }
          fake_push_u16(out, col)
          fake_push_u8(out, if cell.width == 2 { 2 } else { 1 })
          fake_push_u8(out, utf8.length())
          fake_push_u16(out, cell.sflags)
          if (cell.sflags & 2048) != 0 {
            fake_push_u8(out, cell.fg.0)
            fake_push_u8(out, cell.fg.1)
            fake_push_u8(out, cell.fg.2)
          }
          if cell_bg {
            fake_push_u8(out, cell.bg.0)
            fake_push_u8(out, cell.bg.1)
            fake_push_u8(out, cell.bg.2)
          }
          if (cell.sflags & 8192) != 0 {
            fake_push_u8(out, cell.ul.0)
            fake_push_u8(out, cell.ul.1)
            fake_push_u8(out, cell.ul.2)
          }
          for b in utf8 {
            out.push(b)
          }
          cell_count += 1
        }
      }
      out[cell_count_at] = (cell_count & 0xff).to_byte()
      out[cell_count_at + 1] = ((cell_count >> 8) & 0xff).to_byte()
      row_count += 1
    }
  }
  out[row_count_at] = (row_count & 0xff).to_byte()
  out[row_count_at + 1] = ((row_count >> 8) & 0xff).to_byte()
  t.dirty_all = false
  t.dirty_rows.clear()
  Bytes::from_array(out)
}

///|
fn FakeHost::tm_close(_ : FakeHost, id : Int) -> Unit {
  fake_terminals.remove(id)
}
