// Profiles, the model accounts the agents run on: what is left here of their old views, a kind of account's mark (its
// list and pages are made once as nodes: sfpages' profiles_list.mbt, accounts.mbt).

///|
/// Whether the bottom bar's `Place("profiles")` shows 概览 (`true`) or the accounts' list (`false`): its own, so a
/// `Setting(Profiles(""))` pushed and popped over it never changes what it shows.
pub let profiles_place_overview : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

///|
/// Whether a pushed `Setting(Profiles(""))` (and 中屏's and 大屏's) shows 概览 (`true`) or the accounts' list (`false`).
pub let profiles_narrow_overview : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

///|
/// How 概览 is switched to from the accounts' list, of workspace `ws` (`go` switches it, `on_cancel` runs if the
/// switch is cancelled before answering; returns a cancel function): as the settings' core of the source in use says
/// it (sfbase's settings_core_of), once the overview's pools are answered, the list shown meanwhile (switch_answered);
/// at once where none said it.
// kept across runs: what the source in use says of it
pub let overview_switch : Ref[(String, () -> Unit, () -> Unit) -> () -> Unit] = Ref(fn(_, go, _) {
  go()
  fn() {  }
})
