// Particle dissolve-and-reassemble flight rendering (@view.View::flies_in / View::shared with `particle=true`):
// pure render-layer instance transformation in Ctx::view_paint with zero native/shader changes, deterministic across
// all frame rates (7/24/60/120fps identical at the same timestamp), anchored to immutable origin coordinates so
// untouched glyphs never jitter or rephase before the dissolve wavefront reaches them.

///|
/// Sentinel `inst_owners.mark` value tagging split particle fragments so `Tester::glyphs_seen` does not miscount
/// fine dust sub-cells as extra text glyphs.
let particle_inst_mark : Int = -2

///|
/// Active particle-flight scope during Ctx::view_paint: the lifted node, its flight snapshot, the starting instance
/// index, the 24-double outer clip captured before the lifted node pushes its own clip, and the node's raw drawn
/// `(base_x, base_y, base_s)` used to anchor the subtree to its immutable origin at 1:1 scale.
priv struct ParticleAt {
  id : @view.NodeId
  pf : @view.LiftParticle
  k0 : Int
  outer_clip : FixedArray[Double]
  base_x : Double
  base_y : Double
  base_s : Double
  fast_fade : Array[(Int, Int)]
}

///|
/// Deterministic 32-bit mix returning a value in `[0.0, 1.0]`.
fn particle_hash_u(n : Int, salt : Int) -> Double {
  let mut h = (n ^ salt).reinterpret_as_uint()
  h = h ^ (h >> 16)
  h = h * 0x7FEB352DU
  h = h ^ (h >> 15)
  h = h * 0x846CA68BU
  h = h ^ (h >> 16)
  (h & 0xFFFFFFU).to_double() / 16777215.0
}

///|
/// Deterministic 32-bit mix returning a signed value in `[-1.0, 1.0]`.
fn particle_hash_s(n : Int, salt : Int) -> Double {
  particle_hash_u(n, salt) * 2.0 - 1.0
}

///|
/// Smooth Hermite interpolation over `[edge0, edge1]`.
fn particle_smoothstep(edge0 : Double, edge1 : Double, x : Double) -> Double {
  let t = dclamp((x - edge0) / dmax(edge1 - edge0, 1.0e-6), 0.0, 1.0)
  t * t * (3.0 - 2.0 * t)
}

///|
/// Integer clamp to `[lo, hi]`.
fn particle_iclamp(v : Int, lo : Int, hi : Int) -> Int {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// Whether local point `(lx, ly)` lies outside a box `(w, h)`'s rounded corner of radius `rad`.
fn particle_out_of_corner(lx : Double, ly : Double, w : Double, h : Double, rad : Double) -> Bool {
  if rad <= 0.5 {
    return false
  }
  let cdx = dmax(0.0, dmax(rad - lx, lx - (w - rad)))
  let cdy = dmax(0.0, dmax(rad - ly, ly - (h - rad)))
  cdx * cdx + cdy * cdy > rad * rad
}

///|
/// Apply the captured outer clip (24 doubles from clip_stack) onto instance at base `b`.
fn particle_set_outer_clip(a : FixedArray[Double], b : Int, clip : FixedArray[Double]) -> Unit {
  a.unsafe_set(b + 16, clip.unsafe_get(0))
  a.unsafe_set(b + 17, clip.unsafe_get(1))
  a.unsafe_set(b + 18, clip.unsafe_get(2))
  a.unsafe_set(b + 19, clip.unsafe_get(3))
  a.unsafe_set(b + 24, clip.unsafe_get(4))
  a.unsafe_set(b + 25, clip.unsafe_get(5))
  a.unsafe_set(b + 26, clip.unsafe_get(6))
  a.unsafe_set(b + 27, clip.unsafe_get(7))
  a.unsafe_set(b + 28, clip.unsafe_get(8))
  a.unsafe_set(b + 29, clip.unsafe_get(9))
  a.unsafe_set(b + 30, clip.unsafe_get(10))
  a.unsafe_set(b + 31, clip.unsafe_get(11))
  for j in 0..<12 {
    a.unsafe_set(b + 40 + j, clip.unsafe_get(12 + j))
  }
}

///|
/// Translate any internal clip edges (strictly inside `outer`) by `(dx, dy)` and clamp to `outer`, preserving
/// inner clip corner radii `[24..31]` while restoring `outer`'s outer-clip slots `[40..51]`.
fn particle_translate_clip(
  a : FixedArray[Double],
  b : Int,
  outer : FixedArray[Double],
  dx : Double,
  dy : Double,
) -> Unit {
  let c0 = a.unsafe_get(b + 16)
  let c1 = a.unsafe_get(b + 17)
  let c2 = a.unsafe_get(b + 18)
  let c3 = a.unsafe_get(b + 19)
  let o0 = outer.unsafe_get(0)
  let o1 = outer.unsafe_get(1)
  let o2 = outer.unsafe_get(2)
  let o3 = outer.unsafe_get(3)
  let n0 = if c0 > o0 + 0.5 { dmax(o0, c0 + dx) } else { o0 }
  let n1 = if c1 > o1 + 0.5 { dmax(o1, c1 + dy) } else { o1 }
  let n2 = if c2 < o2 - 0.5 { dmin(o2, c2 + dx) } else { o2 }
  let n3 = if c3 < o3 - 0.5 { dmin(o3, c3 + dy) } else { o3 }
  a.unsafe_set(b + 16, n0)
  a.unsafe_set(b + 17, n1)
  a.unsafe_set(b + 18, n2)
  a.unsafe_set(b + 19, n3)
  for j in 0..<12 {
    a.unsafe_set(b + 40 + j, outer.unsafe_get(12 + j))
  }
}

///|
/// Append one 60-double instance (copied from `src[src_off ..< src_off + inst_size]`) and its owner entry, returning
/// the new instance's base index `k * inst_size`.
fn Ctx::particle_emit_copy(
  self : Ctx,
  src : FixedArray[Double],
  src_off : Int,
  keep_owner : Bool,
  ow : Int,
  cel : (Double, Double),
  tre : @view.NodeId?,
  mar : Int,
) -> Int {
  if (self.ninst + 1) * inst_size > self.inst.length() {
    self.grow()
  }
  let k = self.ninst
  self.ninst = k + 1
  let b = k * inst_size
  let a = self.inst
  for j in 0..<inst_size {
    a.unsafe_set(b + j, src.unsafe_get(src_off + j))
  }
  if keep_owner {
    inst_owners.owner.push(ow)
    inst_owners.cell.push(cel)
    inst_owners.tree.push(tre)
    inst_owners.mark.push(mar)
  }
  b
}

///|
/// Transform instances `[from_k .. till_k)` belonging to particle flight `at` into a laminar diagonal wave of fine
/// particles dissolving smoothly at the immutable origin, sweeping along a single clean arc, and reassembling sharply
/// at the destination. Supports text glyphs (`kind == 1/3`), true-color sub-UV image/video sand (`kind == 4`),
/// grounded file/quote cards (`kind == 0` with visible surface dust and smooth `shared_box` handoff), and icons/shapes
/// (`kind == 10/11`).
fn Ctx::particle_apply(self : Ctx, at : ParticleAt, from_k : Int, till_k : Int) -> Unit {
  guard till_k > from_k else { return }
  let pf = at.pf
  let t = pf.t_lin
  let count = till_k - from_k
  let keep_owners = inst_owners_kept()
  // Snapshot original instances and owners so we can safely truncate and grow while splitting glyphs/tiles.
  let snap = FixedArray::makei(count * inst_size, fn(i) { self.inst.unsafe_get(from_k * inst_size + i) })
  let ow_snap : Array[Int] = []
  let cel_snap : Array[(Double, Double)] = []
  let tre_snap : Array[@view.NodeId?] = []
  let mar_snap : Array[Int] = []
  if keep_owners {
    for i in 0..<count {
      let idx = from_k + i
      ow_snap.push(if idx < inst_owners.owner.length() { inst_owners.owner[idx] } else { -1 })
      cel_snap.push(if idx < inst_owners.cell.length() { inst_owners.cell[idx] } else { (0.0, 1.0) })
      tre_snap.push(if idx < inst_owners.tree.length() { inst_owners.tree[idx] } else { None })
      mar_snap.push(if idx < inst_owners.mark.length() { inst_owners.mark[idx] } else { 0 })
    }
    while inst_owners.owner.length() > from_k {
      inst_owners.owner.pop() |> ignore
    }
    while inst_owners.cell.length() > from_k {
      inst_owners.cell.pop() |> ignore
    }
    while inst_owners.tree.length() > from_k {
      inst_owners.tree.pop() |> ignore
    }
    while inst_owners.mark.length() > from_k {
      inst_owners.mark.pop() |> ignore
    }
  }
  self.ninst = from_k
  let vx = pf.to_x - pf.from_x
  let vy = pf.to_y - pf.from_y
  let dist = (vx * vx + vy * vy).sqrt()
  let (dx, dy) = if dist > 1.0 { (vx / dist, vy / dist) } else { (0.0, -1.0) }
  let (px, py) = (-dy, dx)
  let spread = dclamp(dist * 0.13, 12.0, 34.0)
  let stagger = 0.28
  let bw = dmax(dmax(pf.from_w, pf.to_w), 1.0)
  let bh = dmax(dmax(pf.from_h, pf.to_h), 1.0)
  let kx = pf.from_w / dmax(pf.to_w, 1.0)
  let ky = pf.from_h / dmax(pf.to_h, 1.0)
  let pi = 3.141592653589793
  // View::shared(container=true, particle=true) crossfade over t in [0.32, 0.58] is already applied on `l.a` by
  // Tree::flight_at (so `orig_alpha` carries it without double-fading).
  let box_fade = 1.0
  let is_fast_fade = fn(abs_k : Int) -> Bool {
    for r in at.fast_fade {
      if abs_k >= r.0 && abs_k < r.1 {
        return true
      }
    }
    false
  }
  // Adaptive particle cell size (cap total glyph particles at <= 1400 per flight) and active content span for
  // shared_box flights so short quotes do not stall on wide composer cards and wide quotes map into destination bounds.
  let base_cell = 2.2
  let mut est = 0
  let mut content_min_x = 1.0e9
  let mut content_max_x = -1.0e9
  let mut content_min_y = 1.0e9
  let mut content_max_y = -1.0e9
  let mut content_max_rx = 0.0
  let mut content_max_ry = 0.0
  let mut max_gw = 0.0
  let mut max_gh = 0.0
  for i in 0..<count {
    if is_fast_fade(from_k + i) {
      continue
    }
    let o = i * inst_size
    let kind = snap.unsafe_get(o + 5)
    let gx = snap.unsafe_get(o)
    let gy = snap.unsafe_get(o + 1)
    let gw = snap.unsafe_get(o + 2)
    let gh = snap.unsafe_get(o + 3)
    if kind == 1.0 || kind == 3.0 {
      let uw = snap.unsafe_get(o + 14)
      let vh = snap.unsafe_get(o + 15)
      let max_nx = if uw >= 1.5 { (uw / 1.5).floor().to_int() } else { 1 }
      let max_ny = if vh >= 1.5 { (vh / 1.5).floor().to_int() } else { 1 }
      let nx = particle_iclamp((gw / base_cell).round().to_int(), 1, if max_nx > 1 { max_nx } else { 1 })
      let ny = particle_iclamp((gh / base_cell).round().to_int(), 1, if max_ny > 1 { max_ny } else { 1 })
      est = est + nx * ny
      let rx0 = gx - pf.from_x
      let ry0 = gy - pf.from_y
      if rx0 < content_min_x { content_min_x = rx0 }
      if rx0 + gw > content_max_x { content_max_x = rx0 + gw }
      if ry0 < content_min_y { content_min_y = ry0 }
      if ry0 + gh > content_max_y { content_max_y = ry0 + gh }
      if rx0 > content_max_rx { content_max_rx = rx0 }
      if ry0 > content_max_ry { content_max_ry = ry0 }
      if gw > max_gw { max_gw = gw }
      if gh > max_gh { max_gh = gh }
    } else if kind == 10.0 || kind == 11.0 {
      let rx0 = gx - pf.from_x
      let ry0 = gy - pf.from_y
      if rx0 < content_min_x { content_min_x = rx0 }
      if rx0 + gw > content_max_x { content_max_x = rx0 + gw }
      if ry0 < content_min_y { content_min_y = ry0 }
      if ry0 + gh > content_max_y { content_max_y = ry0 + gh }
    }
  }
  let has_content = content_max_x > content_min_x && content_max_y > content_min_y
  let wave_x0 = if pf.shared_box && has_content { content_min_x } else { 0.0 }
  let wave_y0 = if pf.shared_box && has_content { content_min_y } else { 0.0 }
  let wave_w = if pf.shared_box && has_content { dmax(content_max_x - content_min_x, 1.0) } else { bw }
  let wave_h = if pf.shared_box && has_content { dmax(content_max_y - content_min_y, 1.0) } else { bh }
  let icon_wave_w = if pf.shared_box { dmax(dmin(pf.from_w, pf.to_w), 1.0) } else { bw }
  let icon_wave_h = if pf.shared_box { dmax(dmin(pf.from_h, pf.to_h), 1.0) } else { bh }
  let old_dest_sx = if pf.shared_box && pf.old && content_max_x > pf.to_w - 8.0 && content_max_rx > 1.0 {
    dclamp(dmax(pf.to_w - 8.0 - max_gw, 0.0) / content_max_rx, 0.0, 1.0)
  } else {
    1.0
  }
  let old_dest_sy = if pf.shared_box && pf.old && content_max_y > pf.to_h - 6.0 && content_max_ry > 1.0 {
    dclamp(dmax(pf.to_h - 6.0 - max_gh, 0.0) / content_max_ry, 0.0, 1.0)
  } else {
    1.0
  }
  let cell = if est > 1400 { base_cell * (est.to_double() / 1400.0).sqrt() } else { base_cell }
  let mut glyph_idx = 0
  let mut img_idx = 0
  let mut shape_idx = 0
  let mut card_dust_done = false
  for i in 0..<count {
    let o = i * inst_size
    let kind = snap.unsafe_get(o + 5)
    let ow = if keep_owners { ow_snap[i] } else { -1 }
    let cel = if keep_owners { cel_snap[i] } else { (0.0, 1.0) }
    let tre = if keep_owners { tre_snap[i] } else { None }
    let mar = if keep_owners { mar_snap[i] } else { 0 }
    if kind == 12.0 || kind == 13.0 {
      self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar) |> ignore
      continue
    }
    // Fast-fade empty-field placeholder chrome (e.g. composer quote card's empty comment hint) in place on takeoff so
    // it never dissolves into stray flying sand or vanishes mid-air at handoff.
    if is_fast_fade(from_k + i) {
      let fade = 1.0 - particle_smoothstep(0.0, 0.10, t)
      if fade > 0.002 {
        let b = self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
        let a = self.inst
        a.unsafe_set(b + 11, snap.unsafe_get(o + 11) * fade)
        if kind == 0.0 {
          a.unsafe_set(b + 15, snap.unsafe_get(o + 15) * fade)
        }
      }
      continue
    }
    // Every instance in `snap` was emitted in the immutable origin coordinate system `(pf.from_x, pf.from_y)` at 1:1.
    let gx = snap.unsafe_get(o)
    let gy = snap.unsafe_get(o + 1)
    let gw = snap.unsafe_get(o + 2)
    let gh = snap.unsafe_get(o + 3)
    let rx = gx - pf.from_x
    let ry = gy - pf.from_y
    let sx = gx
    let sy = gy
    let is_text = kind == 1.0 || kind == 3.0
    let ex = if is_text { pf.to_x + rx * old_dest_sx } else { pf.to_x + rx }
    let ey = if is_text { pf.to_y + ry * old_dest_sy } else { pf.to_y + ry }
    if is_text {
      let g_id = glyph_idx
      glyph_idx = glyph_idx + 1
      let u0_raw = snap.unsafe_get(o + 12)
      let colour_off = if u0_raw >= 16384.0 { 16384.0 } else { 0.0 }
      let u_base = u0_raw - colour_off
      let v0 = snap.unsafe_get(o + 13)
      let uw = snap.unsafe_get(o + 14)
      let vh = snap.unsafe_get(o + 15)
      let max_nx = if uw >= 1.5 { (uw / 1.5).floor().to_int() } else { 1 }
      let max_ny = if vh >= 1.5 { (vh / 1.5).floor().to_int() } else { 1 }
      let nx = particle_iclamp((gw / cell).round().to_int(), 1, if max_nx > 1 { max_nx } else { 1 })
      let ny = particle_iclamp((gh / cell).round().to_int(), 1, if max_ny > 1 { max_ny } else { 1 })
      let cw = gw / nx.to_double()
      let ch = gh / ny.to_double()
      let sub_uw = uw / nx.to_double()
      let sub_vh = vh / ny.to_double()
      let orig_alpha = snap.unsafe_get(o + 11)
      // Check fast-path: whole glyph before wave start or after wave end.
      let mut all_before = true
      let mut all_after = true
      for iy in 0..<ny {
        for ix in 0..<nx {
          let cell_rx = rx + (ix.to_double() + 0.5) * cw
          let cell_ry = ry + (iy.to_double() + 0.5) * ch
          let nx_pos = dclamp((cell_rx - wave_x0) / wave_w, 0.0, 1.0)
          let ny_pos = dclamp((cell_ry - wave_y0) / wave_h, 0.0, 1.0)
          let wave = 1.0 - (0.72 * nx_pos + 0.28 * (1.0 - ny_pos))
          let cid = g_id * 1024 + iy * 32 + ix
          let h0 = particle_hash_u(cid, pf.seed + 11)
          let delay = dclamp((0.78 * wave + 0.22 * h0) * stagger, 0.0, stagger)
          let lp = dclamp((t - delay) / (1.0 - stagger), 0.0, 1.0)
          if lp > 0.0 {
            all_before = false
          }
          if lp < 1.0 {
            all_after = false
          }
        }
      }
      if all_before {
        let b = self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
        let a = self.inst
        a.unsafe_set(b + 11, orig_alpha * box_fade)
        if pf.shared_box && pf.old {
          a.unsafe_set(b + 18, dmin(a.unsafe_get(b + 18), pf.from_x + pf.from_w))
          a.unsafe_set(b + 19, dmin(a.unsafe_get(b + 19), pf.from_y + pf.from_h))
        }
        continue
      }
      if all_after {
        if pf.old {
          continue
        }
        let b = self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
        let a = self.inst
        a.unsafe_set(b, ex)
        a.unsafe_set(b + 1, ey)
        a.unsafe_set(b + 11, orig_alpha * box_fade)
        particle_translate_clip(a, b, at.outer_clip, vx, vy)
        continue
      }
      for iy in 0..<ny {
        for ix in 0..<nx {
          let cell_rx = rx + (ix.to_double() + 0.5) * cw
          let cell_ry = ry + (iy.to_double() + 0.5) * ch
          let nx_pos = dclamp((cell_rx - wave_x0) / wave_w, 0.0, 1.0)
          let ny_pos = dclamp((cell_ry - wave_y0) / wave_h, 0.0, 1.0)
          let wave = 1.0 - (0.72 * nx_pos + 0.28 * (1.0 - ny_pos))
          let cid = g_id * 1024 + iy * 32 + ix
          let h0 = particle_hash_u(cid, pf.seed + 11)
          let delay = dclamp((0.78 * wave + 0.22 * h0) * stagger, 0.0, stagger)
          let lp = dclamp((t - delay) / (1.0 - stagger), 0.0, 1.0)
          let u = lp * lp * (3.0 - 2.0 * lp)
          let s = @dmath.sin(lp * pi)
          let h1 = particle_hash_s(cid, pf.seed + 37)
          let a_mul = (1.0 - (0.10 + 0.20 * ((h1 + 1.0) * 0.5)) * s) * box_fade
          if a_mul <= 0.002 {
            continue
          }
          let h2 = particle_hash_s(cid, pf.seed + 91)
          let h3 = particle_hash_s(cid, pf.seed + 157)
          let h4 = particle_hash_s(cid, pf.seed + 241)
          let arc = 0.18 * spread * s
          let lat = h1 * spread * s
          let lon = h2 * (spread * 0.40) * s
          let src_cx = sx + (ix.to_double() + 0.5) * cw
          let src_cy = sy + (iy.to_double() + 0.5) * ch
          let dst_cx = ex + (ix.to_double() + 0.5) * cw
          let dst_cy = ey + (iy.to_double() + 0.5) * ch
          let cx = src_cx + (dst_cx - src_cx) * u + px * (arc + lat) + dx * lon
          let cy = src_cy + (dst_cy - src_cy) * u + py * (arc + lat) + dy * lon
          let sc_p = 1.0 - (0.14 + 0.18 * h3.abs()) * s
          let pw = cw * sc_p
          let ph = ch * sc_p
          let dispersed = s > 0.10
          let cell_mark = if nx * ny > 1 || dispersed { particle_inst_mark } else { mar }
          let b = if dispersed {
            self.particle_emit_copy(snap, o, keep_owners, -1, (0.0, 1.0), None, cell_mark)
          } else {
            self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, cell_mark)
          }
          let a = self.inst
          a.unsafe_set(b, cx - pw * 0.5)
          a.unsafe_set(b + 1, cy - ph * 0.5)
          a.unsafe_set(b + 2, pw)
          a.unsafe_set(b + 3, ph)
          a.unsafe_set(b + 11, orig_alpha * a_mul)
          a.unsafe_set(b + 12, colour_off + u_base + sub_uw * ix.to_double())
          a.unsafe_set(b + 13, v0 + sub_vh * iy.to_double())
          a.unsafe_set(b + 14, sub_uw)
          a.unsafe_set(b + 15, sub_vh)
          let rot = h4 * 0.65 * s
          a.unsafe_set(b + 32, rot)
          a.unsafe_set(b + 33, cx)
          a.unsafe_set(b + 34, cy)
          a.unsafe_set(b + 35, 1.0)
          if lp >= 0.999 {
            particle_translate_clip(a, b, at.outer_clip, vx, vy)
          } else if lp > 0.001 {
            particle_set_outer_clip(a, b, at.outer_clip)
          }
        }
      }
    } else if kind == 4.0 {
      // True-color sub-UV sand particles for image and video thumbnail attachments: rounded origin hold on takeoff,
      // fine 2.2-3.4pt sand mid-flight, dual-end rounded contour filtering, and smooth rounded destination settle.
      let im_id = img_idx
      img_idx = img_idx + 1
      let orig_alpha = snap.unsafe_get(o + 11)
      let u0 = snap.unsafe_get(o + 12)
      let v0 = snap.unsafe_get(o + 13)
      let uw = snap.unsafe_get(o + 14)
      let vh = snap.unsafe_get(o + 15)
      let est_tiles = (gw / 3.2) * (gh / 3.2)
      let icell = if est_tiles > 1600.0 { 3.2 * (est_tiles / 1600.0).sqrt() } else { 3.2 }
      let nx = particle_iclamp((gw / icell).round().to_int(), 4, 48)
      let ny = particle_iclamp((gh / icell).round().to_int(), 4, 48)
      let cw = gw / nx.to_double()
      let ch = gh / ny.to_double()
      let sub_uw = uw / nx.to_double()
      let sub_vh = vh / ny.to_double()
      let img_kx = if pf.shared_box { 1.0 } else { kx }
      let img_ky = if pf.shared_box { 1.0 } else { ky }
      let img_r = dmax(
        snap.unsafe_get(o + 4),
        dmax(
          dmax(snap.unsafe_get(o + 24), snap.unsafe_get(o + 25)),
          dmax(snap.unsafe_get(o + 26), snap.unsafe_get(o + 27)),
        ),
      )
      let rad_to = dmin(img_r, dmin(gw, gh) * 0.5)
      let bw0 = gw * img_kx
      let bh0 = gh * img_ky
      let rad_from = dmin(img_r, dmin(bw0, bh0) * 0.22)
      let mut all_before = true
      let mut all_after = true
      for iy in 0..<ny {
        for ix in 0..<nx {
          let cell_rx = rx + (ix.to_double() + 0.5) * cw
          let cell_ry = ry + (iy.to_double() + 0.5) * ch
          let nx_pos = dclamp(cell_rx / bw, 0.0, 1.0)
          let ny_pos = dclamp(cell_ry / bh, 0.0, 1.0)
          let wave = 1.0 - (0.72 * nx_pos + 0.28 * (1.0 - ny_pos))
          let cid = 400000 + im_id * 4096 + iy * 64 + ix
          let h0 = particle_hash_u(cid, pf.seed + 11)
          let delay = dclamp((0.78 * wave + 0.22 * h0) * stagger, 0.0, stagger)
          let lp = dclamp((t - delay) / (1.0 - stagger), 0.0, 1.0)
          if lp > 0.0 {
            all_before = false
          }
          if lp < 1.0 {
            all_after = false
          }
        }
      }
      if all_before {
        let b = self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
        let a = self.inst
        a.unsafe_set(b, pf.from_x + rx * img_kx)
        a.unsafe_set(b + 1, pf.from_y + ry * img_ky)
        a.unsafe_set(b + 2, bw0)
        a.unsafe_set(b + 3, bh0)
        a.unsafe_set(b + 4, rad_from)
        a.unsafe_set(b + 11, orig_alpha * box_fade)
        a.unsafe_set(b + 36, rad_from)
        a.unsafe_set(b + 37, rad_from)
        a.unsafe_set(b + 38, rad_from)
        a.unsafe_set(b + 39, rad_from)
        particle_set_outer_clip(a, b, at.outer_clip)
        continue
      }
      if all_after && !pf.old {
        let b = self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
        let a = self.inst
        a.unsafe_set(b, ex)
        a.unsafe_set(b + 1, ey)
        a.unsafe_set(b + 4, rad_to)
        a.unsafe_set(b + 11, orig_alpha * box_fade)
        a.unsafe_set(b + 36, rad_to)
        a.unsafe_set(b + 37, rad_to)
        a.unsafe_set(b + 38, rad_to)
        a.unsafe_set(b + 39, rad_to)
        particle_set_outer_clip(a, b, at.outer_clip)
        continue
      }
      // Hold one rounded origin thumbnail during takeoff (t < 0.26) so unlaunched tiles show zero grid seams or square corners.
      let origin_hold = if t < 0.26 { 1.0 - particle_smoothstep(0.02, 0.24, t) } else { 0.0 }
      if origin_hold > 0.002 {
        let b = self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
        let a = self.inst
        a.unsafe_set(b, pf.from_x + rx * img_kx)
        a.unsafe_set(b + 1, pf.from_y + ry * img_ky)
        a.unsafe_set(b + 2, bw0)
        a.unsafe_set(b + 3, bh0)
        a.unsafe_set(b + 4, rad_from)
        a.unsafe_set(b + 11, orig_alpha * origin_hold * box_fade)
        a.unsafe_set(b + 36, rad_from)
        a.unsafe_set(b + 37, rad_from)
        a.unsafe_set(b + 38, rad_from)
        a.unsafe_set(b + 39, rad_from)
        particle_set_outer_clip(a, b, at.outer_clip)
      }
      // Smoothly blend the full rounded destination image in over t in [0.74, 0.96] as sand particles reassemble.
      let settle = if !pf.old && t > 0.74 { particle_smoothstep(0.74, 0.96, t) } else { 0.0 }
      if settle > 0.001 {
        let b = self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
        let a = self.inst
        a.unsafe_set(b, ex)
        a.unsafe_set(b + 1, ey)
        a.unsafe_set(b + 4, rad_to)
        a.unsafe_set(b + 11, orig_alpha * settle * box_fade)
        a.unsafe_set(b + 36, rad_to)
        a.unsafe_set(b + 37, rad_to)
        a.unsafe_set(b + 38, rad_to)
        a.unsafe_set(b + 39, rad_to)
        particle_set_outer_clip(a, b, at.outer_clip)
      }
      for iy in 0..<ny {
        for ix in 0..<nx {
          let lx = (ix.to_double() + 0.5) * cw
          let ly = (iy.to_double() + 0.5) * ch
          if particle_out_of_corner(lx, ly, gw, gh, rad_to) {
            continue
          }
          let cell_rx = rx + lx
          let cell_ry = ry + ly
          let nx_pos = dclamp(cell_rx / bw, 0.0, 1.0)
          let ny_pos = dclamp(cell_ry / bh, 0.0, 1.0)
          let wave = 1.0 - (0.72 * nx_pos + 0.28 * (1.0 - ny_pos))
          let cid = 400000 + im_id * 4096 + iy * 64 + ix
          let h0 = particle_hash_u(cid, pf.seed + 11)
          let delay = dclamp((0.78 * wave + 0.22 * h0) * stagger, 0.0, stagger)
          let lp = dclamp((t - delay) / (1.0 - stagger), 0.0, 1.0)
          if origin_hold > 0.01 && lp <= 0.005 {
            continue
          }
          if lp < 0.15 && particle_out_of_corner(lx * img_kx, ly * img_ky, bw0, bh0, rad_from) {
            continue
          }
          let u = lp * lp * (3.0 - 2.0 * lp)
          let s = @dmath.sin(lp * pi)
          let tile_end = 1.0 - settle * particle_smoothstep(0.70, 0.98, lp)
          let h1 = particle_hash_s(cid, pf.seed + 37)
          let a_mul = (1.0 - (0.08 + 0.16 * ((h1 + 1.0) * 0.5)) * s) * box_fade * tile_end
          if a_mul <= 0.002 {
            continue
          }
          let h2 = particle_hash_s(cid, pf.seed + 91)
          let h3 = particle_hash_s(cid, pf.seed + 157)
          let h4 = particle_hash_s(cid, pf.seed + 241)
          let arc = 0.18 * spread * s
          let lat = h1 * spread * s
          let lon = h2 * (spread * 0.40) * s
          let src_cx = pf.from_x + cell_rx * img_kx
          let src_cy = pf.from_y + cell_ry * img_ky
          let dst_cx = pf.to_x + cell_rx
          let dst_cy = pf.to_y + cell_ry
          let cx = src_cx + (dst_cx - src_cx) * u + px * (arc + lat) + dx * lon
          let cy = src_cy + (dst_cy - src_cy) * u + py * (arc + lat) + dy * lon
          let cw_now = cw * img_kx + (cw - cw * img_kx) * u
          let ch_now = ch * img_ky + (ch - ch * img_ky) * u
          let sand_sz = 2.2 + 1.2 * ((h3 + 1.0) * 0.5)
          let sand_k = particle_smoothstep(0.0, 0.30, s)
          let tw = cw_now + (sand_sz - cw_now) * sand_k
          let th = ch_now + (sand_sz - ch_now) * sand_k
          let dispersed = s > 0.10
          let cell_mark = if nx * ny > 1 || dispersed { particle_inst_mark } else { mar }
          let b = if dispersed {
            self.particle_emit_copy(snap, o, keep_owners, -1, (0.0, 1.0), None, cell_mark)
          } else {
            self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, cell_mark)
          }
          let a = self.inst
          a.unsafe_set(b, cx - tw * 0.5)
          a.unsafe_set(b + 1, cy - th * 0.5)
          a.unsafe_set(b + 2, tw)
          a.unsafe_set(b + 3, th)
          let tr = dmin(tw, th) * 0.45 * sand_k
          a.unsafe_set(b + 4, tr)
          a.unsafe_set(b + 11, orig_alpha * a_mul)
          a.unsafe_set(b + 12, u0 + sub_uw * ix.to_double())
          a.unsafe_set(b + 13, v0 + sub_vh * iy.to_double())
          a.unsafe_set(b + 14, sub_uw)
          a.unsafe_set(b + 15, sub_vh)
          // Disable matte border crop on split interior tiles.
          a.unsafe_set(b + 22, 0.0)
          let rot = h4 * 0.65 * s
          a.unsafe_set(b + 32, rot)
          a.unsafe_set(b + 33, cx)
          a.unsafe_set(b + 34, cy)
          a.unsafe_set(b + 35, 1.0)
          a.unsafe_set(b + 36, tr)
          a.unsafe_set(b + 37, tr)
          a.unsafe_set(b + 38, tr)
          a.unsafe_set(b + 39, tr)
          particle_set_outer_clip(a, b, at.outer_clip)
        }
      }
    } else if kind == 0.0 {
      let orig_alpha = snap.unsafe_get(o + 11)
      let orig_edge_alpha = snap.unsafe_get(o + 15)
      if pf.bare {
        let m = particle_smoothstep(0.42, 0.96, t)
        if m <= 0.001 {
          continue
        }
        let scale = 0.97 + 0.03 * m
        let nw = gw * scale
        let nh = gh * scale
        let nx = ex + (gw - nw) * 0.5
        let ny = ey + (gh - nh) * 0.5
        let factor = dmin(m / dmax(pf.p, 0.01), 1.0 / dmax(pf.p, 0.01))
        let b = self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
        let a = self.inst
        a.unsafe_set(b, nx)
        a.unsafe_set(b + 1, ny)
        a.unsafe_set(b + 2, nw)
        a.unsafe_set(b + 3, nh)
        a.unsafe_set(b + 11, dmin(orig_alpha * factor, 1.0))
        a.unsafe_set(b + 15, dmin(orig_edge_alpha * factor, 1.0))
        particle_set_outer_clip(a, b, at.outer_clip)
      } else {
        // Grounded card (file card, quote card, video frame): smooth fade-out at full origin width, fade-in at
        // destination, and a clearly visible 80-140 particle dust stream sweeping along the diagonal wave.
        let orig_r = snap.unsafe_get(o + 4)
        if !pf.shared_box || pf.old || !pf.has_old {
          let fade_out = 1.0 - particle_smoothstep(0.0, 0.32, t)
          if fade_out > 0.001 {
            let b = self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
            let a = self.inst
            if !pf.old && !pf.has_old {
              let r0 = dmin(orig_r, pf.from_h * 0.5)
              a.unsafe_set(b, pf.from_x)
              a.unsafe_set(b + 1, pf.from_y)
              a.unsafe_set(b + 2, pf.from_w)
              a.unsafe_set(b + 3, pf.from_h)
              a.unsafe_set(b + 4, r0)
              a.unsafe_set(b + 36, r0)
              a.unsafe_set(b + 37, r0)
              a.unsafe_set(b + 38, r0)
              a.unsafe_set(b + 39, r0)
            } else if pf.shared_box {
              a.unsafe_set(b, sx)
              a.unsafe_set(b + 1, sy)
            } else {
              a.unsafe_set(b, pf.from_x + rx * kx)
              a.unsafe_set(b + 1, pf.from_y + ry * ky)
              a.unsafe_set(b + 2, gw * kx)
              a.unsafe_set(b + 3, gh * ky)
            }
            a.unsafe_set(b + 11, orig_alpha * fade_out)
            a.unsafe_set(b + 15, orig_edge_alpha * fade_out)
            particle_set_outer_clip(a, b, at.outer_clip)
          }
        }
        if !pf.shared_box || !pf.old {
          let fade_in = particle_smoothstep(0.62, 0.96, t)
          if fade_in > 0.001 {
            let b = self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
            let a = self.inst
            a.unsafe_set(b, ex)
            a.unsafe_set(b + 1, ey)
            a.unsafe_set(b + 11, orig_alpha * fade_in)
            a.unsafe_set(b + 15, orig_edge_alpha * fade_in)
            particle_set_outer_clip(a, b, at.outer_clip)
          }
        }
        // Visible uniform grid card surface dust (80-140 soft 2.0-2.8pt rounded particles filtered to card corners).
        if !card_dust_done && orig_alpha > 0.01 && gw >= 24.0 && gh >= 16.0 && t > 0.02 && t < 0.98 {
          card_dust_done = true
          let dust_span_w = if pf.shared_box { bw } else { dmax(gw, pf.from_w) }
          let dust_span_h = if pf.shared_box { bh } else { dmax(gh, pf.from_h) }
          let raw_cols = particle_iclamp((dust_span_w / 9.0).round().to_int(), 10, 20)
          let raw_rows = particle_iclamp((dust_span_h / 7.5).round().to_int(), 6, 10)
          let (cols, rows) = if raw_cols * raw_rows > 140 {
            let r_sc = (140.0 / (raw_cols * raw_rows).to_double()).sqrt()
            (
              particle_iclamp((raw_cols.to_double() * r_sc).round().to_int(), 8, 18),
              particle_iclamp((raw_rows.to_double() * r_sc).round().to_int(), 5, 10),
            )
          } else {
            (raw_cols, raw_rows)
          }
          let corner_w = if pf.shared_box { pf.to_w } else { gw }
          let corner_h = if pf.shared_box { pf.to_h } else { gh }
          let dust_r = if pf.shared_box && pf.to_r > 0.0 { pf.to_r } else { orig_r }
          let card_r = dmin(dust_r, dmin(corner_w, corner_h) * 0.5)
          let base_dust_a = dclamp(dmax(orig_alpha * 3.4, 0.30), 0.24, 0.58)
          let card_morph = pf.shared_box || (!pf.old && !pf.has_old)
          let dust_kx = if pf.shared_box { 1.0 } else { kx }
          let dust_ky = if pf.shared_box { 1.0 } else { ky }
          for iy in 0..<rows {
            for ix in 0..<cols {
              let cid = 900000 + iy * 32 + ix
              let jx = particle_hash_s(cid, pf.seed + 311) * 0.32
              let jy = particle_hash_s(cid, pf.seed + 389) * 0.32
              let u_x = dclamp((ix.to_double() + 0.5 + jx) / cols.to_double(), 0.02, 0.98)
              let u_y = dclamp((iy.to_double() + 0.5 + jy) / rows.to_double(), 0.02, 0.98)
              if particle_out_of_corner(u_x * corner_w, u_y * corner_h, corner_w, corner_h, card_r) {
                continue
              }
              let wave = 1.0 - (0.72 * u_x + 0.28 * (1.0 - u_y))
              let h0 = particle_hash_u(cid, pf.seed + 11)
              let delay = dclamp((0.78 * wave + 0.22 * h0) * stagger, 0.0, stagger)
              let lp = dclamp((t - delay) / (1.0 - stagger), 0.0, 1.0)
              let s = @dmath.sin(lp * pi)
              let dust_a = base_dust_a * s * box_fade
              if dust_a <= 0.004 {
                continue
              }
              let u = lp * lp * (3.0 - 2.0 * lp)
              let h1 = particle_hash_s(cid, pf.seed + 37)
              let h2 = particle_hash_s(cid, pf.seed + 91)
              let h3 = particle_hash_s(cid, pf.seed + 157)
              let arc = 0.18 * spread * s
              let lat = h1 * spread * s
              let lon = h2 * (spread * 0.40) * s
              let (src_cx, src_cy, dst_cx, dst_cy) = if card_morph {
                (
                  pf.from_x + u_x * pf.from_w,
                  pf.from_y + u_y * pf.from_h,
                  pf.to_x + u_x * pf.to_w,
                  pf.to_y + u_y * pf.to_h,
                )
              } else {
                (
                  pf.from_x + (rx + u_x * gw) * dust_kx,
                  pf.from_y + (ry + u_y * gh) * dust_ky,
                  ex + u_x * gw,
                  ey + u_y * gh,
                )
              }
              let cx = src_cx + (dst_cx - src_cx) * u + px * (arc + lat) + dx * lon
              let cy = src_cy + (dst_cy - src_cy) * u + py * (arc + lat) + dy * lon
              let sz = 2.0 + 0.8 * ((h3 + 1.0) * 0.5)
              let b = self.particle_emit_copy(snap, o, keep_owners, -1, (0.0, 1.0), None, particle_inst_mark)
              let a = self.inst
              a.unsafe_set(b, cx - sz * 0.5)
              a.unsafe_set(b + 1, cy - sz * 0.5)
              a.unsafe_set(b + 2, sz)
              a.unsafe_set(b + 3, sz)
              a.unsafe_set(b + 4, sz * 0.5)
              a.unsafe_set(b + 6, 0.0)
              a.unsafe_set(b + 11, dust_a)
              a.unsafe_set(b + 15, 0.0)
              a.unsafe_set(b + 36, sz * 0.5)
              a.unsafe_set(b + 37, sz * 0.5)
              a.unsafe_set(b + 38, sz * 0.5)
              a.unsafe_set(b + 39, sz * 0.5)
              particle_set_outer_clip(a, b, at.outer_clip)
            }
          }
        }
      }
    } else if kind == 10.0 || kind == 11.0 {
      let s_id = shape_idx
      shape_idx = shape_idx + 1
      let cell_rx = rx + gw * 0.5
      let cell_ry = ry + gh * 0.5
      let nx_pos = dclamp(cell_rx / icon_wave_w, 0.0, 1.0)
      let ny_pos = dclamp(cell_ry / icon_wave_h, 0.0, 1.0)
      let wave = 1.0 - (0.72 * nx_pos + 0.28 * (1.0 - ny_pos))
      let cid = 500000 + s_id
      let h0 = particle_hash_u(cid, pf.seed + 11)
      let delay = dclamp((0.78 * wave + 0.22 * h0) * stagger, 0.0, stagger)
      let lp = dclamp((t - delay) / (1.0 - stagger), 0.0, 1.0)
      let u = lp * lp * (3.0 - 2.0 * lp)
      let s = @dmath.sin(lp * pi)
      let a_mul = (1.0 - 0.55 * s) * box_fade
      let orig_alpha = snap.unsafe_get(o + 11)
      if a_mul > 0.002 {
        let h1 = particle_hash_s(cid, pf.seed + 37)
        let h2 = particle_hash_s(cid, pf.seed + 91)
        let h4 = particle_hash_s(cid, pf.seed + 241)
        let arc = 0.18 * spread * s
        let lat = h1 * (spread * 0.45) * s
        let lon = h2 * (spread * 0.25) * s
        let nx = sx + (ex - sx) * u + px * (arc + lat) + dx * lon
        let ny = sy + (ey - sy) * u + py * (arc + lat) + dy * lon
        let cx = nx + gw * 0.5
        let cy = ny + gh * 0.5
        let dispersed = s > 0.10
        let b = if dispersed {
          self.particle_emit_copy(snap, o, keep_owners, -1, (0.0, 1.0), None, mar)
        } else {
          self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
        }
        let a = self.inst
        a.unsafe_set(b, nx)
        a.unsafe_set(b + 1, ny)
        a.unsafe_set(b + 11, orig_alpha * a_mul)
        a.unsafe_set(b + 32, h4 * 0.40 * s)
        a.unsafe_set(b + 33, cx)
        a.unsafe_set(b + 34, cy)
        a.unsafe_set(b + 35, 1.0)
        if lp >= 0.999 {
          particle_translate_clip(a, b, at.outer_clip, vx, vy)
        } else if lp > 0.001 {
          particle_set_outer_clip(a, b, at.outer_clip)
        }
      }
      // Emit 10 matching-color 2.0pt circular particles alongside icons/shapes while dispersed.
      if s > 0.02 && orig_alpha > 0.01 {
        let icon_dust_a = orig_alpha * 0.70 * s * box_fade
        if icon_dust_a > 0.004 {
          for d in 0..<10 {
            let dcid = 600000 + s_id * 16 + d
            let u_x = particle_hash_u(dcid, pf.seed + 311)
            let u_y = particle_hash_u(dcid, pf.seed + 389)
            let dh1 = particle_hash_s(dcid, pf.seed + 37)
            let dh2 = particle_hash_s(dcid, pf.seed + 91)
            let darc = 0.18 * spread * s
            let dlat = dh1 * spread * s
            let dlon = dh2 * (spread * 0.40) * s
            let src_cx = sx + u_x * gw
            let src_cy = sy + u_y * gh
            let dst_cx = ex + u_x * gw
            let dst_cy = ey + u_y * gh
            let dcx = src_cx + (dst_cx - src_cx) * u + px * (darc + dlat) + dx * dlon
            let dcy = src_cy + (dst_cy - src_cy) * u + py * (darc + dlat) + dy * dlon
            let sz = 2.0
            let b = self.particle_emit_copy(snap, o, keep_owners, -1, (0.0, 1.0), None, particle_inst_mark)
            let a = self.inst
            a.unsafe_set(b, dcx - sz * 0.5)
            a.unsafe_set(b + 1, dcy - sz * 0.5)
            a.unsafe_set(b + 2, sz)
            a.unsafe_set(b + 3, sz)
            a.unsafe_set(b + 4, sz * 0.5)
            a.unsafe_set(b + 5, 0.0)
            a.unsafe_set(b + 6, 0.0)
            a.unsafe_set(b + 11, icon_dust_a)
            a.unsafe_set(b + 15, 0.0)
            a.unsafe_set(b + 32, 0.0)
            a.unsafe_set(b + 35, 0.0)
            a.unsafe_set(b + 36, sz * 0.5)
            a.unsafe_set(b + 37, sz * 0.5)
            a.unsafe_set(b + 38, sz * 0.5)
            a.unsafe_set(b + 39, sz * 0.5)
            particle_set_outer_clip(a, b, at.outer_clip)
          }
        }
      }
    } else {
      let b = self.particle_emit_copy(snap, o, keep_owners, ow, cel, tre, mar)
      self.inst.unsafe_set(b + 11, snap.unsafe_get(o + 11) * box_fade)
    }
  }
}
