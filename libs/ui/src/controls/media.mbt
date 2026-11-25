// A picture or a film with media controls floating over it (web/ui viewer/media.css.ts: the app's video viewer, the
// drive's player, player.mbt): the controls' bar that fades (the picture's glass: the raised ground at 72%, solid
// here, as a native view under it cannot be blurred), a timeline, the buttons in its corners, the speed as a figure.

///|
/// The controls' bar (vvBar): as wide as 1080 allows less 16 either side, 16 off the foot, 6 over its timeline and the
/// ladder's inset round the rest, a card of the ladder's (its round buttons in its corners concentric with it); on the
/// raised ground at 72%. It fades out in 320 ms, back in 120.
pub let media_bar_most : Double = 1080.0

///|
pub let media_bar_in : Double = 16.0

///|
/// (its round buttons, 32, in its foot corners concentric with it: capsule_in, 8.87 in a card's 26)
pub let media_bar_pad : Double = @ui.capsule_in(card_corner, media_key_d)

///|
/// Over its timeline, in the bar; its buttons' size (vvBtn: 32 across); so the bar is this tall, its timeline and a row
/// of its buttons between its pads: what a picture fitted clear of it keeps off (player.mbt desk_play_room).
pub let media_bar_top : Double = 6.0

///|
pub let media_key_d : Double = 32.0

///|
pub fn media_bar_h() -> Double {
  media_bar_top + media_timeline_h() + media_row_h() + media_bar_foot()
}

///|
/// The keys' row: as tall as a press's room (@ui.room_least: 36 with keyboard and mouse, 44 with touch), its keys (32)
/// in its middle, so the timeline over it never takes the room they are pressed in.
pub fn media_row_h() -> Double {
  media_key_d
}

///|
/// Under the keys' row: as much less than media_bar_pad as the row is taller than its keys, the keys in the bar's foot
/// corners concentric with them where they were.
pub fn media_bar_foot() -> Double {
  media_bar_pad - (media_row_h() - media_key_d) / 2.0
}

///|
pub let media_glass_share : Double = 0.72

///|
/// The speed's ground (vvRate): the words at 10%; the timeline's track (vvTrack) the words at 20%, what has come at
/// 22% over it.
pub let media_rate_share : Double = 0.1

///|
pub let media_track_share : Double = 0.2

///|
pub let media_came_share : Double = 0.22

///|
/// The timeline (vvTimeline): 22 high (web/ui viewer/media.css.ts), with a thumb-free fluid scrubber track in its middle.
pub fn media_timeline_h() -> Double {
  22.0
}

///|
/// The bar's ground over `canvas` (the picture's glass, solid).
fn media_ground() -> Int64 {
  let p = theme().p
  over(p.canvas, alpha(p.raised, media_glass_share))
}

///|
/// The colours of what floats over a film or a song: its words, what is quieter, the controls' ground, and the stage
/// under it all.
pub(all) struct MediaInk {
  text : Int64
  muted : Int64
  ground : Int64
  stage : Int64
}

///|
/// Over a picture, whatever the theme: black under it (a film is watched on the dark, its frame no white round it), the
/// words near white on a deep tint (the picture's glass; a native view under it cannot be blurred: solid). A song has
/// no picture: the page's own colours (`picture` false).
pub fn media_ink(picture : Bool) -> MediaInk {
  if picture {
    { text: media_dark_text, muted: media_dark_muted, ground: media_dark_ground, stage: media_dark_stage }
  } else {
    let p = theme().p
    { text: p.text, muted: p.muted, ground: media_ground(), stage: p.canvas }
  }
}

///|
/// Over a picture: the words, the quieter ones, the tint (darkGlass's 0x121214, deeper with no blur), the stage.
pub let media_dark_text : Int64 = 0xF4F4F5FFL

///|
pub let media_dark_muted : Int64 = 0xFFFFFF99L

///|
pub let media_dark_ground : Int64 = 0x121214D9L

///|
pub let media_dark_stage : Int64 = 0x000000FFL

///|
/// A button's ground under the pointer (the words at 10%) and while what it turns on is on (16%).
let media_hot_share : Double = 0.1

///|
let media_lit_share : Double = 0.16

///|
/// What is said in the code face in the bar (vvInfo, vvNow): the time where it is in 600.
pub let media_strong : Int = 600

///|
let media_rate_w : Double = 46.0

///|
/// The speed's height (28: S7).
let media_rate_h : Double = 28.0
