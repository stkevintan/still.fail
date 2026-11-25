///|
/// A host that lets the app turn the device as held where `upright` (a phone), and answers as one that does.
struct TurnHost {
  upright : Bool
  told : Array[Bool]
}

///|
fn TurnHost::as_host(self : TurnHost) -> @hostapi.Host {
  {
    ..@hostapi.Host::noop(),
    set_turnable: fn(on) {
      self.told.push(on)
      self.upright
    },
  }
}

///|
test "a phone let turn as held counts as turned by the app (a layout held); upright only again, not; a tablet never" {
  let phone = TurnHost::{ upright: true, told: [] }
  let phone_host = phone.as_host()
  @hostapi.set_host(phone_host)
  assert_true(!@hostapi.sideways())
  @hostapi.set_turnable(true)
  assert_true(@hostapi.sideways())
  @hostapi.set_turnable(false)
  assert_true(!@hostapi.sideways())
  assert_eq(phone.told, [true, false])
  // a tablet turns anyway: nothing the app turned
  let tablet = TurnHost::{ upright: false, told: [] }
  let tablet_host = tablet.as_host()
  @hostapi.set_host(tablet_host)
  @hostapi.set_turnable(true)
  assert_true(!@hostapi.sideways())
  assert_eq(tablet.told, [true])
  // a new host has been handed nothing
  @hostapi.set_host(phone_host)
  @hostapi.set_turnable(true)
  @hostapi.set_host(tablet_host)
  assert_true(!@hostapi.sideways())
}
