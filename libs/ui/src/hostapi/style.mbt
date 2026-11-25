// What every host shares, whatever its target.

///|
/// A font's style bits (font_metrics, shape): slanted, the monospaced (code)
/// face, the serif face.
pub let style_italic : Int = 1

///|
pub let style_mono : Int = 2

///|
/// The serif face (a reader's 宋体: Songti on Apple, Noto Serif and its CJK on Android, SimSun on Windows).
pub let style_serif : Int = 4

///|
/// Shaped with no ligatures (asked for words with letter spacing, each cluster then spaced on its own): Core Text's
/// kCTLigatureAttributeName 0, DirectWrite's liga and clig off, Android's font feature settings "'liga' 0, 'clig' 0",
/// canvas text's fontVariantLigatures none. The font is the same.
pub let style_no_ligatures : Int = 8

///|
/// What people and agents wrote (a chat's words, a composer's), set in the face registered for them (face_text) where
/// there is one, else as the app's own words are.
pub let style_words : Int = 16

///|
/// Digits all one width (the font's tabular figures, OpenType tnum), for a number that changes where it stands (a
/// percentage, a time running): Core Text's kNumberSpacingType kMonospacedNumbersSelector, DirectWrite's tnum, Android's
/// font feature settings "'tnum' 1", a canvas's digits each as wide as the widest of them. The font is the same.
pub let style_tabular : Int = 32

///|
/// The narrow (proportional) forms of what a Chinese, Japanese or Korean face draws a whole em wide by default (the
/// marks of East Asian Ambiguous width: ‘ ’ “ ” … · —), asked by ui for words among Latin letters (@text.width_runs):
/// the font's OpenType pwid (Core Text's and DirectWrite's feature, Android's font feature settings "'pwid' 1",
/// Pango's "pwid=1", a web face loaded with it). A face without pwid is the same.
pub let style_proportional : Int = 64

///|
/// The faces a host is given (face_add) for the app's three places: its own words (every font a style says nothing
/// else of), what people wrote (style_words), code (style_mono), and their CJK companions (4 to 6). Faces 4 to 31
/// are drawn where a style names them (style_face). A place with no face registered is in the system's.
pub let face_ui : Int = 1

///|
pub let face_text : Int = 2

///|
pub let face_code : Int = 3

///|
pub let face_ui_cjk : Int = 4

///|
pub let face_text_cjk : Int = 5

///|
pub let face_code_cjk : Int = 6

///|
/// First face slot reserved for local/preview/try faces (7..30). Changes to slots `>= face_try` only invalidate
/// shape/metric cache entries referencing that slot, never triggering a global `words_forgotten()`.
pub let face_try : Int = 7

///|
/// Reserved sentinel face slot that is never registered in the app. Hosts resolve unregistered explicit slots to OS
/// system font `0`, allowing live previews of "System Default" to bypass any custom face registered on `face_ui`.
pub let face_sys_default : Int = 31

///|
/// How many faces a host keeps (1 to faces_most - 1).
pub let faces_most : Int = 32

///|
/// The style bitmask covering the 5-bit face slot (bits 8..12, 0x1F00).
pub let style_face_bits : Int = 31 << 8

///|
/// The style bits that name face `face` (1 to 31) whatever else the style says: what is set in it is in it.
pub fn style_face(face : Int) -> Int {
  (face & 31) << 8
}

///|
/// The face a style names (style_face), 0 none.
pub fn face_of_style(style : Int) -> Int {
  (style >> 8) & 31
}
