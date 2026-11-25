// A table's columns sized by what their cells say (View::tracks): each cell measured as the tree measures the words it
// draws (Tree's `measure_runs`, `measure_runs_least`: their pieces, how they are set, at the node's size of words),
// once as what the cells say or the size of words changes, never as the room does; the room shared out among the
// columns by its caller's rule from those measures, again only as the room or they change. Rows a page's list makes
// a few a block are sized by all of them, made or not.

///|
/// What one cell of a table says, for how wide its column is (View::tracks): words in pieces as the cell draws them
/// (View::words_runs: the pieces, how the words are set, how the pieces are), or a width of its own (pictures in a row).
#derive(Eq, Debug)
pub(all) enum TrackCell {
  Said(Array[@text.Run], WordsLook, RunsLook)
  Wide(Double)
}

///|
/// How wide a cell of a table may be (View::tracks): `least` wrapped (the widest of what lies between two places its
/// lines may break), `whole` on one line; `wide` where it is a width of its own that does not wrap.
#derive(Eq, Debug)
pub(all) struct TrackExtent {
  least : Double
  whole : Double
  wide : Bool
}

///|
/// A table's columns' widths (View::tracks): `widths`, as they change; `of`, another table's cells' (a row each, a
/// cell each) measured and shared out now, in the room as it is now, followed by nothing.
pub(all) struct Tracks {
  widths : () -> (Array[Double], Double)
  of : (Array[Array[TrackCell]]) -> (Array[Double], Double)
}

///|
/// What one table cut in pieces (a few of its rows a block of a page's list, each piece's View::tracks over all of its
/// rows) keeps of its columns, given each piece's View::tracks (`kept`): the cells as last measured, at the size of
/// words and the shaping they were measured at, and what they came to; the room as last shared out and the widths that
/// gave. A piece asking what another asked last is given what that came to, nothing measured or shared out again:
/// each cell measured once for all the pieces, not once a piece. Kept by value, never by what asked it (a piece may be
/// let go of, or its block taken for another key's): what is asked anew of other cells, another room or another size
/// of words is worked out anew.
pub struct TracksKept {
  priv mut measured : ((Array[Array[TrackCell]], Double, Int, Int), Array[Array[TrackExtent]])?
  priv mut shared : (Array[Array[TrackExtent]], Double, (Array[Double], Double))?
}

///|
/// Nothing kept yet.
pub fn TracksKept::new() -> TracksKept {
  { measured: None, shared: None }
}

///|
/// The widths of a table's columns and all of them together, as `share` gives them of each cell's extent (`cells`, as
/// they change: a row each, the head's first, a cell each; measured at the size of words `self` is at, again as that
/// changes) and the room (`room`, as it changes). Each cell is measured once as the cells or the size of words change
/// (each counted as one measure, Tree's work: its words shaped once for both), never as the room does; `share` works again as either changes.
/// `kept`: what the pieces of one table cut in pieces keep of it together (TracksKept), each piece's `share` the same
/// rule as the others'.
pub fn View::tracks(
  self : View,
  cells : () -> Array[Array[TrackCell]],
  room : () -> Double,
  share : (Array[Array[TrackExtent]], Double) -> (Array[Double], Double),
  kept? : TracksKept,
) -> Tracks {
  let tree = self.tree
  let measured = fn(rows : Array[Array[TrackCell]], scale : Double) {
    rows.map(fn(row) {
      row.map(fn(cell) {
        match cell {
          Said(runs, look, set) => {
            tree.work.measured = tree.work.measured + 1
            {
              least: (tree.measure_runs_least)(runs, look, set, scale),
              whole: (tree.measure_runs)(runs, look, set, -1.0, scale).0,
              wide: false,
            }
          }
          Wide(w) => { least: w, whole: w, wide: true }
        }
      })
    })
  }
  // (worked out again only as what the cells say, their size of words or how words are shaped comes to be otherwise:
  // what they read told again the same, or this read anew after what read it let go of it as it was parked, measures
  // nothing again)
  let extents = @signals.memo(fn() {
    let rows = cells()
    let mut mask = 0
    for row in rows {
      for cell in row {
        match cell {
          Said(runs, _, set) => {
            match set.cjk {
              Some(ov) if ov.face >= 7 && ov.face < 32 => mask = mask | (1 << ov.face)
              _ => ()
            }
            match set.code_cjk {
              Some(ov) if ov.face >= 7 && ov.face < 32 => mask = mask | (1 << ov.face)
              _ => ()
            }
            for run in runs {
              match run.face {
                Some(f) if f >= 7 && f < 32 => mask = mask | (1 << f)
                _ => ()
              }
            }
          }
          Wide(_) => ()
        }
      }
    }
    let mut face_rev = 0
    if mask != 0 {
      for f in 7..<32 {
        if (mask & (1 << f)) != 0 {
          face_rev = face_rev * 31 + tree.face_redone[f].get() + 1
        }
      }
    }
    (rows, self.words_scale(), self.tree.words_redone.get(), face_rev)
  }, fn(k) {
    match kept {
      // (the same cells another piece had measured, at the same size and shaping: what they came to)
      Some({ measured: Some((was, e)), .. }) if was == k => e
      Some(kp) => {
        let e = measured(k.0, k.1)
        kp.measured = Some((k, e))
        e
      }
      None => measured(k.0, k.1)
    }
  })
  let widths = @signals.computed(fn(_) {
    let (e, r) = (extents.get(), room())
    match kept {
      // (what another piece shared out of the same measures in the same room)
      Some({ shared: Some((was, at, w)), .. }) if at == r && was == e => w
      Some(kp) => {
        let w = share(e, r)
        kp.shared = Some((e, r, w))
        w
      }
      None => share(e, r)
    }
  })
  {
    widths: fn() { widths.get() },
    of: fn(rows) { @signals.untracked(fn() { share(measured(rows, self.words_scale()), room()) }) },
  }
}
