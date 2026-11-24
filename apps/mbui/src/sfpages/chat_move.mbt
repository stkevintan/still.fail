// A chat moved to another station of its workspace from its own menu (a row's and its page's "…", chat_menu_items:
// 迁移到另一台 station, for the workspace's owners and admins, the core's `mayMove`): the stations to choose among as
// its station's 迁移 lists them (the core's `stationMove`, station_move_node.mbt: each its room, one it may not go to
// faint with why under it), the one chosen asked of its station (`move.start`, the chat and what it needs), answered
// at once. What it does then is the chat's page's to say: over a composer shut, where it goes, till it is there and
// the page follows it (the core's ChatView `moving`); a refusal said in the station's words.

///|
/// Chat `item`'s 迁移到另一台 station chosen: its station's other stations picked among once the core has them
/// (press_wait: while what it was pressed in stays as it was, its menu held meanwhile), beside where its menu opened
/// (`from`), the one picked moved to.
fn open_chat_move(src : Source, item : ChatItem, from~ : @sf.Beside) -> Unit {
  let scope = "chat-move/" + item.station
  let sub = @sfbase.hold(src, scope, "stationMove", {
    "station": Json::string(item.station),
    "to": Json::string(""),
    "module": Json::string(""),
  })
  @sfbase.press_wait(fn() { @sfbase.opens_answered(sub.get()) }, fn() {
    let read = @signals.untracked(fn() { sub.get() })
    @sfbase.let_go(src, scope)
    match read.error {
      Some(e) => {
        @ui.haptic(Reject)
        toast_later(error_words(e))
        return
      }
      None => ()
    }
    let targets = items(read.value, "targets")
    guard !targets.is_empty() else { toast_later(@sf.t("web-pages.stations.move.none")) }
    let all = targets.map(fn(x) {
      @sf.choice(
        text(Some(x), "station"),
        text(Some(x), "name"),
        note=text(Some(x), "why"),
        value=text(Some(x), "free"),
        disabled=text(Some(x), "why") != "",
      )
    })
    @sf.pick(@sf.t("web-pages.stations.move.to"), all, "", fn(id) {
      let name = match targets.iter().find_first(fn(x) { text(Some(x), "station") == id }) {
        Some(x) => text(Some(x), "name")
        None => id
      }
      chat_move_to(src, item, id, name)
    }, from~, search=false)
  }, let_go=fn() { @sfbase.let_go(src, scope) })
  |> ignore
}

///|
/// Chat `item` moved to station `to` (`name`, as people call it): asked of its station with what it needs
/// (`withNeeds`), said as begun (the station answers as it begins), or why not.
fn chat_move_to(src : Source, item : ChatItem, to : String, name : String) -> Unit {
  act(
    src,
    @sf.t("web-pages.stations.move.menu"),
    "",
    "move.start",
    Json::object({
      "station": Json::string(item.station),
      "to": Json::string(to),
      "module": Json::string("chats"),
      "item": Json::string(item.session),
      "withNeeds": Json::boolean(true),
    }),
    done=@sf.t("web-main.chat.moveStarted", args=[("station", name)]),
  )
}
