// A chat as its page shows it, read from the core's `chat` view (client/core-ts src/shapes/schema.ts: ChatView,
// ChatMessage, Attachment, Quote, MessageCard, MessageDecision, MessageBy, ChatSentElsewhere, Outgoing, ChatAgent)
// into MoonBit, the fields the page draws. A field the view leaves out reads as nothing, as Shapes.kt decodes it.

///|
pub fn opt_number(v : Json?, key : String) -> Double? {
  match field(v, key) {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
/// A moment in words, as the core says it (Stamp): `ago` (3 分钟前), `full` (9/20 14:05:09).
#derive(Eq)
pub(all) struct Stamp {
  ago : String
  full : String
}

///|
pub fn stamp_of(v : Json?, key : String) -> Stamp? {
  match field(field(v, "time"), key) {
    Some(Object(_)) as s => Some({ ago: text(s, "ago"), full: text(s, "full") })
    _ => None
  }
}

///|
/// A file sent with a message (Attachment).
#derive(Eq)
pub(all) struct Attachment {
  name : String
  path : String
  size : Double
  width : Double
  height : Double
  thumbhash : String
  /// the session whose workspace keeps it (its preview and download go through it)
  owner : String
  /// the id of this device's upload it is (`composer.add`), sent before it was up: its picture is still here
  /// (composer.mbt sent_picture); "" for any other
  upload : String
  /// a film's length (ms) and how many frames its picture has, as the station read them from its header (0: not said)
  duration : Double
  frames : Int
  /// its picture (an image's thumbnail, a video's still) kept on this device (the core's `held`): a decode away, so
  /// the app's first page waits for it as for the rest of what it shows
  held : Bool
}

///|
pub fn attachment_of(a : Json) -> Attachment {
  let s = Some(a)
  {
    name: text(s, "name"),
    path: text(s, "path"),
    size: number(s, "size"),
    width: number(s, "width"),
    height: number(s, "height"),
    thumbhash: text(s, "thumbhash"),
    owner: text(s, "owner"),
    upload: text(s, "upload"),
    duration: number(s, "duration"),
    frames: number(s, "frames").to_int(),
    held: field(s, "held") is Some(True),
  }
}

///|
/// A passage quoted with a message (Quote).
#derive(Eq)
pub(all) struct Quote {
  author : String
  text : String
  comment : String
  ts : String
  /// agent | person | page (a mark on a previewed page) | image (a numbered mark on an image)
  role : String
  /// the name of the file among the message's that goes with it (a mark's screenshot, an image of the message
  /// quoted): shown in its card, not with the message's files; "" none
  file : String
}

///|
pub fn quote_of(q : Json) -> Quote {
  let s = Some(q)
  {
    author: text(s, "author"),
    text: text(s, "text"),
    comment: text(s, "comment"),
    ts: text(s, "ts"),
    role: text(s, "role"),
    file: text(s, "file"),
  }
}

///|
/// An answer a card offers (DecisionOption).
#derive(Eq)
pub(all) struct Choice {
  label : String
  detail : String
  recommended : Bool
  /// picked, the card closes and no message of the viewer's comes of it
  closes : Bool
}

///|
pub fn choices_of(v : Json?, key : String) -> Array[Choice]? {
  match field(v, key) {
    Some(Array(a)) =>
      Some(
        a.map(fn(o) {
          {
            label: text(Some(o), "label"),
            detail: text(Some(o), "detail"),
            recommended: flag(Some(o), "recommended"),
            closes: flag(Some(o), "closes"),
          }
        }),
      )
    _ => None
  }
}

///|
/// The card a message carries (MessageCard): options, text or login.
#derive(Eq)
pub(all) struct Card {
  kind : String
  assignee_text : String?
  /// who is to decide (their email), where someone is
  assignee : String
  options : Array[Choice]?
  /// a text card's: the hint its field shows while nothing is written in it, as the agent said it ("" none)
  placeholder : String
  login : String
  station : String
  vault : String
  /// with `vault`: the request as the card says it (MessageCard.vaultAsk), drawn in place of the post's words
  ask : VaultAsk?
  /// an agent's request for its person's phone (MessageCard.phoneAsk), drawn in place of the post's words
  phone : PhoneAsk?
  /// an agent's ask to sign in to a site (MessageCard.signinAsk), drawn in place of the post's words
  signin : SignInAsk?
  /// an agent's request for a rig of the workspace (MessageCard.rigAsk), drawn in place of the post's words
  rig : RigAsk?
}

///|
/// An agent's request for a rig (a station that only runs tasks) as its card says it (RigAsk): its id, the rig and its name, the agent's
/// reason and the time it asked for; the chat as the card named it (what the rig's person's device signs with the
/// grant: `rig.decide`'s `ask`); once decided, how (`status`: granted, denied, ended; `why`; granted, whether the rig
/// took it yet, `delivered`, and for how long it was signed).
#derive(Eq)
pub(all) struct RigAsk {
  request : String
  rig : String
  name : String
  reason : String
  timeout_kind : String
  timeout_seconds : Int
  session : String
  chat : String
  title : String
  by : String
  status : String
  why : String
  delivered : Bool
  granted_kind : String
  granted_seconds : Int
  /// One of the rig's devices alone (设备), its id and name as asked: "" for the rig itself.
  device : String
  device_name : String
}

///|
/// An agent's ask to sign in to a site as its card says it (SignInAsk 登录态): its id, the site,
/// why, the chat's tab it is on (a screen of the chat's station), and how it goes (`status`: "" waiting, filling, code,
/// person, left, done, denied, expired, ended; `why` a person is needed; what the agent `said` is left; whether it is
/// to be kept, `keep`; the vault request keeping it, `save`, and how that went, `kept`).
#derive(Eq)
pub(all) struct SignInAsk {
  id : String
  site : String
  reason : String
  screen : String
  status : String
  why : String
  said : String
  keep : Bool
  save : String
  kept : String
}

///|
/// An agent's request to debug its person's phone as its card says it (PhoneAsk): its id, the
/// agent's reason, and once decided how (`status`: granted, denied, ended; `scope`: hour, chat; `why` it ended).
#derive(Eq)
pub(all) struct PhoneAsk {
  request : String
  reason : String
  status : String
  scope : String
  why : String
  /// granted, how its station's adb holds the phone, as the station said: connected, unpaired, off, unauthorized,
  /// missing, failed, gone ("": not said)
  link : String
  /// the longest its owner lets it be granted for: hour, chat
  lasts : String
}

///|
/// An agent's request about a vault item as its card says it (VaultAsk): the item, how it is given, the command it is
/// for; one to keep a secret (`save_kind` not empty): what kind, the account (a file: its name), whether the person
/// types it in (`typed`); once decided, how (`status`, `scope`).
#derive(Eq)
pub(all) struct VaultAsk {
  name : String
  reason : String
  timeout_kind : String
  timeout_seconds : Int
  approved_timeout_kind : String
  approved_timeout_seconds : Int
  mode : String
  command : String
  /// How it is given, including the allowed hosts, as the core says it.
  how_text : String
  save_kind : String
  save_vault_name : String
  save_shared : Bool
  save_targets : Array[(String, String, Bool)]
  username : String
  /// a file's name, where the agent gave one
  filename : String
  typed : Bool
  /// with `typed`, a service the person signs in to for it instead (slack): a button for its page, no field
  oauth : String
  /// one to rename the item or change its about (secret_describe): its name and about as they would be, its about as
  /// it was
  describe : Bool
  new_name : String
  new_about : String
  was_about : String
  /// one to delete the item (secret_delete)
  remove : Bool
  /// a request to list personal secrets from other workspaces (`secret_list` other_workspaces)
  browse : Bool
  browse_hint : String
  browse_workspaces : Int
  browse_items : Int
  /// source workspace and vault metadata for a cross-workspace personal secret request
  cross_workspace : String
  cross_workspace_name : String
  cross_vault_name : String
  status : String
  scope : String
  /// another station of the workspace its commands run on, by name (empty: the chat's)
  station : String
  /// how it is answered on this device, the core's from the vault it holds: approve, setUp, elsewhere (MessageCard's
  /// vaultAsk.answer)
  answer : String
  /// answered approve, a use: the longest it may be given for
  lasts : String
}

///|
/// Where a card stands (MessageDecision).
#derive(Eq)
pub(all) struct Decision {
  resolved : Bool
  dismissed : Bool
  text : String?
  /// the option picked, once answered
  chosen : String?
}

///|
/// Who said a message (MessageBy).
#derive(Eq)
pub(all) struct By {
  name : String
  agent : String
  maker : String
  runtime : String
  picture : String
  from : String
}

///|
pub fn by_of(v : Json?) -> By {
  let b = field(v, "by")
  {
    name: text(b, "name"),
    agent: text(b, "agent"),
    maker: text(field(b, "maker"), "id"),
    runtime: text(b, "runtime"),
    picture: text(b, "picture"),
    from: text(b, "from"),
  }
}

///|
/// A place a message went to or came from (Place).
#derive(Eq)
pub(all) struct Place {
  name : String
  surface : String
  session : String
  url : String
  app : String
}

///|
/// What an agent said in Slack, or was given from it (ChatSentElsewhere).
#derive(Eq)
pub(all) struct Elsewhere {
  key : String
  after : Double
  text : String
  place : Place?
  failed : Bool
  received : Bool
  /// the files a person's message there came with
  attachments : Array[Attachment]
  by : By
  time : Stamp?
}

///|
pub fn elsewhere_of(e : Json) -> Elsewhere {
  let s = Some(e)
  {
    key: text(s, "key"),
    after: number(s, "after"),
    text: text(s, "text"),
    place: match field(s, "place") {
      Some(Object(_)) as p =>
        Some({
          name: text(p, "name"),
          surface: text(p, "surface"),
          session: text(p, "session"),
          url: text(p, "url"),
          app: text(p, "app"),
        })
      _ => None
    },
    failed: flag(s, "failed"),
    received: flag(s, "received"),
    attachments: items(s, "attachments").map(attachment_of),
    by: by_of(s),
    time: stamp_of(s, "createdAt"),
  }
}

///|
/// A runtime a notice says the station lacks, or a message of the viewer's waits for (RuntimeInstall).
#derive(Eq)
pub(all) struct Install {
  /// the runtime it is (`software.update`'s id)
  runtime : String
  state : String
  title : String
  note : String
  action : String
  percent : Double?
  /// why installing it failed
  detail : String
}

///|
pub fn install_of(v : Json?, key : String) -> Install? {
  match field(v, key) {
    Some(Object(_)) as i =>
      Some({
        runtime: text(i, "runtime"),
        state: text(i, "state"),
        title: text(i, "title"),
        note: text(i, "note"),
        action: text(i, "action"),
        percent: opt_number(i, "percent"),
        detail: text(i, "detail"),
      })
    _ => None
  }
}

///|
/// A chat a message links to, as the core says it (LinkedChat): its link as written, its title (what the link written
/// bare reads as), whether it is archived and its words for where it stands then (已归档).
#derive(Eq)
pub(all) struct LinkedChat {
  href : String
  title : String
  archived : Bool
  note : String
  thread : Double?
}

///|
/// A chat's run changed to another runtime or model, as the core says it (RunSides): what changed as it was and as it
/// is now, each drawn after the mark of who made its model ("": its runtime's maker's, @sf.maker_mark's), and what
/// leads what it is now said alone (换成).
#derive(Eq)
pub(all) struct RunSides {
  was : String
  now : String
  to : String
  was_maker : String
  was_runtime : String
  now_maker : String
  now_runtime : String
}

///|
/// A message of the chat (ChatMessage), with what the core decides of it.
#derive(Eq)
pub(all) struct Message {
  seq : Double
  thread : Double
  ts : String
  /// person | agent | the station (ember, as the station stores it)
  author_kind : String
  author : String
  text : String
  md : Json?
  /// a person's words in runs, as the core reads them (refLinks.ts personWords: message_words.mbt words_runs)
  words : Json?
  attachments : Array[Attachment]
  quotes : Array[Quote]
  created_at : Double
  mine : Bool
  system : Bool
  profile : String
  install : Install?
  blocked : Install?
  by : By
  waiting : Bool
  followed : Bool
  joined : Bool
  time : Stamp?
  options : Array[Choice]?
  card : Card?
  decision : Decision?
  asked : Bool
  ending : String
  elsewhere : Array[Elsewhere]
  placed : Array[String]
  /// said while the chat shows (not caught up on): it comes in rather than being there at once
  said : Bool
  /// the outbox entry it was sent from here as (its row goes on being that one)
  outgoing : String
  /// a failure still.fail says that the viewer may send to the still.fail team (`chat.report`)
  reportable : Bool
  /// still.fail's notice as the core says it is shown (NoticeShown): a failure (red), its words as a line, where its
  /// link to `profile` begins (-1: none), its words' Markdown as the core read them
  notice_failed : Bool
  notice_words : String
  notice_link : Int
  /// one about `profile` the station says what to do of: that, at the pill's end (重新登录, 设置代理), opening the
  /// profile's page; "" otherwise
  notice_profile_action : String
  notice_md : Json?
  /// the agent whose capacity retry this notice can cancel, while that retry waits
  notice_retry_session : String
  /// the agent whose failed turn this notice can try again (重试), while that turn is where it stands
  notice_again_session : String
  /// the agent whose failed turn, its allowance showing a limit, this notice can move to another account (重新分配账号),
  /// while that turn is where it stands
  notice_reassign_session : String
  /// a failure's own words, as what failed said them, shown under its words when the notice is opened
  notice_detail : String
  /// failures said in the same words one after another that the core folded into this one: how many (1: itself alone),
  /// drawn after its words as ×n, and the last of them's seq, what is acted on (重试, 上报…) and read up to (its own
  /// seq where it folds none)
  notice_count : Int
  notice_last_seq : Double
  /// a chat's run changed: what it runs on now, said in place of its words where they have not the room on their line
  /// ("": none), and how it ran and runs, whole, shown in place of its words once it is opened
  notice_short : String
  notice_lines : Array[String]
  /// a chat's run changed to another runtime or model: its words' two sides apart, each drawn after its mark
  notice_sides : RunSides?
  /// the chats its words link to that their lists have (archived ones too)
  chats : Array[LinkedChat]
}

///|
/// How many messages were read as Messages (message_of) in this run, wherever: what a test of the work a change costs
/// counts (chat_opens reads none; a chat's page opened again reads none of those that did not change).
// kept across runs: a count a test reads as the difference over what it does, never its value
pub let messages_decoded : Ref[Int] = Ref(0)

///|
/// Message JSON `m` read as a Message (message_of), or as it was read last where it is the same JSON as one of the last
/// `messages_read_most` read: what reads a chat whole (chat_read) and what reads it by key (ChatMessages), each of its
/// own, read a message come once between them, not once each (the page the app ships reads its newest by key too).
fn message_read(m : Json) -> Message {
  for p in messages_read_last {
    if physical_equal(p.0, m) {
      return p.1
    }
  }
  let made = message_of(m)
  if messages_read_last.length() >= messages_read_most {
    messages_read_last.remove(0) |> ignore
  }
  messages_read_last.push((m, made))
  made
}

///|
/// The last messages read (message_read), with the JSON each was read of.
// kept across runs: made of the JSON each is kept with alone, the same whichever run reads it; emptied as a run begins
// (chat_seeds_reset) so no run holds another's values
let messages_read_last : Array[(Json, Message)] = []

///|
/// How many of the last messages read message_read keeps.
let messages_read_most : Int = 16

///|
pub fn message_of(m : Json) -> Message {
  messages_decoded.val += 1
  let s = Some(m)
  {
    seq: number(s, "seq"),
    thread: number(s, "thread"),
    ts: text(s, "ts"),
    author_kind: text(s, "authorKind"),
    author: text(s, "author"),
    text: text(s, "text"),
    md: field(s, "md"),
    words: field(s, "words"),
    attachments: items(s, "attachments").map(attachment_of),
    quotes: items(s, "quotes").map(quote_of),
    created_at: number(s, "createdAt"),
    mine: flag(s, "mine"),
    system: flag(s, "system"),
    profile: text(s, "profile"),
    install: install_of(s, "install"),
    blocked: install_of(s, "blocked"),
    by: by_of(s),
    waiting: flag(s, "waiting"),
    followed: flag(s, "followed"),
    joined: flag(s, "joined"),
    time: stamp_of(s, "createdAt"),
    options: choices_of(s, "options"),
    card: match field(s, "card") {
      Some(Object(_)) as c =>
        Some({
          kind: text(c, "type"),
          assignee_text: opt_text(c, "assigneeText"),
          assignee: text(c, "assignee"),
          options: choices_of(c, "options"),
          placeholder: text(c, "placeholder"),
          login: text(c, "login"),
          station: text(c, "station"),
          vault: text(c, "vault"),
          ask: match field(c, "vaultAsk") {
            Some(Object(_)) as a =>
              Some({
                name: text(a, "name"),
                reason: text(a, "reason"),
                timeout_kind: text(a, "timeoutKind"),
                timeout_seconds: count(a, "timeoutSeconds"),
                approved_timeout_kind: text(a, "approvedTimeoutKind"),
                approved_timeout_seconds: count(a, "approvedTimeoutSeconds"),
                mode: text(a, "mode"),
                command: text(a, "command"),
                how_text: text(a, "howText"),
                save_kind: text(field(a, "save"), "kind"),
                save_vault_name: text(field(a, "save"), "vaultName"),
                save_shared: flag(field(a, "save"), "shared"),
                save_targets: items(a, "saveTargets").map(fn(t) {
                  (text(Some(t), "id"), text(Some(t), "name"), flag(Some(t), "workspace"))
                }),
                username: text(field(a, "save"), "username"),
                filename: text(field(a, "save"), "filename"),
                typed: flag(field(a, "save"), "typed"),
                oauth: text(field(a, "save"), "oauth"),
                describe: field(a, "describe") is Some(_),
                new_name: text(field(a, "describe"), "name"),
                new_about: text(field(a, "describe"), "about"),
                was_about: text(field(a, "describe"), "wasAbout"),
                remove: flag(a, "remove"),
                browse: field(a, "browse") is Some(_),
                browse_hint: text(field(a, "browse"), "workspace"),
                browse_workspaces: {
                  let decided = count(field(a, "browse"), "workspaces")
                  if decided > 0 { decided } else { count(a, "browseWorkspaces") }
                },
                browse_items: {
                  let decided = count(field(a, "browse"), "items")
                  if decided > 0 { decided } else { count(a, "browseItems") }
                },
                cross_workspace: text(field(a, "cross"), "workspace"),
                cross_workspace_name: text(field(a, "cross"), "workspaceName"),
                cross_vault_name: text(field(a, "cross"), "vaultName"),
                status: text(a, "status"),
                scope: text(a, "scope"),
                station: text(a, "station"),
                answer: text(a, "answer"),
                lasts: text(a, "lasts"),
              })
            _ => None
          },
          signin: match field(c, "signinAsk") {
            Some(Object(_)) as a =>
              Some({
                id: text(a, "id"),
                site: text(a, "site"),
                reason: text(a, "reason"),
                screen: text(a, "screen"),
                status: text(a, "status"),
                why: text(a, "why"),
                said: text(a, "said"),
                keep: match field(a, "keep") {
                  Some(False) => false
                  _ => true
                },
                save: text(a, "save"),
                kept: text(a, "kept"),
              })
            _ => None
          },
          phone: match field(c, "phoneAsk") {
            Some(Object(_)) as a =>
              Some({
                request: text(a, "request"),
                reason: text(a, "reason"),
                status: text(a, "status"),
                scope: text(a, "scope"),
                why: text(a, "why"),
                link: text(a, "link"),
                lasts: text(a, "lasts"),
              })
            _ => None
          },
          rig: match field(c, "rigAsk") {
            Some(Object(_)) as a =>
              Some({
                request: text(a, "request"),
                rig: text(a, "rig"),
                name: text(a, "name"),
                reason: text(a, "reason"),
                timeout_kind: text(a, "timeoutKind"),
                timeout_seconds: count(a, "timeoutSeconds"),
                session: text(a, "session"),
                chat: text(a, "chat"),
                title: text(a, "title"),
                by: text(a, "by"),
                status: text(a, "status"),
                why: text(a, "why"),
                delivered: flag(a, "delivered"),
                granted_kind: text(a, "grantedKind"),
                granted_seconds: count(a, "grantedSeconds"),
                device: text(a, "device"),
                device_name: text(a, "deviceName"),
              })
            _ => None
          },
        })
      _ => None
    },
    decision: match field(s, "decision") {
      Some(Object(_)) as d =>
        Some({
          resolved: flag(d, "resolved"),
          dismissed: flag(d, "dismissed"),
          text: opt_text(d, "text"),
          chosen: opt_text(d, "chosen"),
        })
      _ => None
    },
    asked: flag(s, "asked"),
    ending: text(s, "ending"),
    elsewhere: items(s, "elsewhere").map(elsewhere_of),
    placed: items(s, "placed").map(fn(n) {
      match n {
        String(x) => x
        _ => ""
      }
    }),
    said: flag(s, "said"),
    outgoing: text(s, "outgoing"),
    reportable: flag(s, "reportable"),
    notice_failed: flag(field(s, "notice"), "failed"),
    notice_words: text(field(s, "notice"), "words"),
    notice_link: match opt_number(field(s, "notice"), "linkAt") {
      Some(n) => n.to_int()
      None => -1
    },
    notice_profile_action: text(field(s, "notice"), "profileAction"),
    notice_md: field(field(s, "notice"), "md"),
    notice_retry_session: text(field(s, "notice"), "retrySession"),
    notice_again_session: text(field(s, "notice"), "againSession"),
    notice_reassign_session: text(field(s, "notice"), "reassignSession"),
    notice_detail: text(field(s, "notice"), "detail"),
    notice_count: match opt_number(field(s, "notice"), "count") {
      Some(n) if n >= 2.0 => n.to_int()
      _ => 1
    },
    notice_last_seq: match opt_number(field(s, "notice"), "lastSeq") {
      Some(n) => n
      None => number(s, "seq")
    },
    notice_short: text(field(s, "notice"), "short"),
    notice_lines: items(field(s, "notice"), "lines").filter_map(fn(l) {
      match l {
        String(l) => Some(l)
        _ => None
      }
    }),
    notice_sides: match field(field(s, "notice"), "sides") {
      Some(Object(_)) as d =>
        Some({
          was: text(d, "was"),
          now: text(d, "now"),
          to: text(d, "to"),
          was_maker: text(d, "wasMaker"),
          was_runtime: text(d, "wasRuntime"),
          now_maker: text(d, "nowMaker"),
          now_runtime: text(d, "nowRuntime"),
        })
      _ => None
    },
    chats: items(s, "chats").map(fn(c) -> LinkedChat {
      let c = Some(c)
      { href: text(c, "href"), title: text(c, "title"), archived: flag(c, "archived"), note: text(c, "note"), thread: opt_number(c, "thread") }
    }),
  }
}

///|
/// The chat a message's link `href` names, as the core says it with the message (Message's `chats`).
pub fn Message::linked(self : Message, href : String) -> LinkedChat? {
  self.chats.iter().find_first(fn(c) { c.href == href })
}

///|
/// A message sent from here that the chat does not show yet (Outgoing).
#derive(Eq)
pub(all) struct Outgoing {
  id : String
  text : String
  /// its words in runs, as the core read them (refLinks.ts personWords; one sent from here: draftWords)
  words : Json?
  attachments : Array[Attachment]
  quotes : Array[Quote]
  /// sending | sent (the station has it: `seq`) | failed
  state : String
  error : String
  joined : Bool
  followed : Bool
  /// the message's seq once the station has it (-1 before)
  seq : Double
  /// when it was sent, in words (Time), shown under it once it is sent
  time : Stamp?
  /// why it has not reached the station yet, in place of 正在发送 ("" none)
  waits : String
  /// its files going up (`waits` says so): how much of them all the station has, 0 to 1 (None: not said)
  progress : Double?
  /// its files still going up before it goes but its images, among its `attachments` already (`uploads`): each one's
  /// name, size and how much of it the station has
  uploads : Array[(String, Int, Int)]
  /// when it was sent (the time of day, as Source.now says it: "正在发送" shows a while after), and whether it was
  /// refused as it is (sent again it would be again: its words go back to the composer)
  created_at : Double
  refused : Bool
  /// held here till its station is reached (`waits` says so): nothing of it gone, so it may still be edited or deleted
  held : Bool
  /// failed after it went out with no answer: the station may have it, so it is sent again (重试), never deleted
  unsure : Bool
}

///|
/// An agent of the chat (ChatAgent), as its marks and its activity show it.
#derive(Eq)
pub(all) struct Agent {
  key : String
  runtime : String
  maker : String
  who : String
  model_name : String
  model_short : String
  effort : String
  /// block | run | failed, or "" (done)
  badge : String
  /// running while its turn runs
  status : String
  since : Double?
  wait : (Double, Double?, String)?
  /// seen starting while the chat shows: its activity comes in
  started : Bool
  /// its last turn's id (its session's lastTurn), "" before it has had one
  last_turn : String
  /// the message its last turn's state is about (lastTurn.about), by its seq: its answer, which a station may tell its
  /// turn over before
  about : Double?
}

///|
pub fn agent_of(a : Json) -> Agent {
  let s = Some(a)
  let session = field(s, "session")
  {
    key: text(session, "key"),
    runtime: text(session, "runtime"),
    maker: text(field(session, "maker"), "id"),
    who: text(session, "agentText"),
    model_name: text(session, "modelName"),
    model_short: text(session, "modelShort"),
    effort: text(session, "effort"),
    badge: text(s, "badge"),
    status: text(s, "status"),
    since: opt_number(s, "since"),
    wait: match field(s, "wait") {
      Some(Object(_)) as w => Some((number(w, "since"), opt_number(w, "seconds"), text(w, "text")))
      _ => None
    },
    started: flag(s, "started"),
    last_turn: text(field(session, "lastTurn"), "id"),
    about: opt_number(field(field(session, "lastTurn"), "about"), "seq"),
  }
}

///|
/// A chat's page (ChatView): its chat with the viewer's read position, its agents and people.
#derive(Eq)
pub(all) struct ChatView {
  title : String
  /// its thread's id, and how many wait past a window short of its end
  thread : Double?
  unread : Double
  people : Array[Person]
  agents : Array[Agent]
  messages : Array[Message]
  /// said in Slack before its first message
  elsewhere : Array[Elsewhere]
  more : Bool
  newer : Bool
  /// the first and last entries loaded (letters and edits are not messages): the cursors for loading pages
  first_entry : Double?
  last_entry : Double?
  /// the page before, being read ("reading") or not read ("failed", why in `older_failed`, asked again a while after):
  /// "" neither, when it may be asked for
  older : String
  older_failed : String
  /// how many letters its agents and other chats' wrote each other (not in `messages`: their own sheet)
  letters : Int
  at : Double?
  at_offset : Double?
  unread_line : Double?
  unread_above : Bool
  outbox : Array[Outgoing]
  /// till when (the core's time, its source's `now`) what the viewer sends here goes close under its last row, theirs,
  /// that row's time under the new one (the core's `joinsUntil`); None: it would stand apart
  joins_until : Double?
  offline : Bool
  /// its station down, the line over the composer (why, and that what is sent goes once it is reached)
  offline_note : String?
  /// its station gone for its update: that line marked with the update's mark in place of the unplugged one
  updating : Bool
  /// going to another station now (the core's `moving`): the station it goes to, and what its composer says in its
  /// place, shut till it is there
  moving : (String, String)?
  /// its agent's prompt cache over (the core's `cacheCold`): that agent's session, the status, what rereading costs,
  /// and whether it goes on afresh as it is next started (as its chat chose, or else its station is set)
  cache_cold : (String, String, String, Bool)?
  /// where it stands, as its row's second line says it without a card waiting (the core's `stateText`, `stateLead`,
  /// `stateRest`): said at the end of its messages
  state : (String, String, String)?
  /// what an agent needs a person for, as `state` says it (the core's `stateAsk`): the post that asks it, let go right
  /// under the line rather than under that post
  state_ask : Double?
  /// one of `asks` is not at the end itself (the core's `askClear`): the end keeps clear of the bell that leads to it
  ask_clear : Bool
  archived : Bool
  archivable : Bool
  pending : Bool
  key : String
  /// what waits to be decided in it (the core's `asks`), by the post each is about
  asks : Array[Double]
  /// its station's update, as the bar says it (StationUpdateNotice)
  station_update : Json?
  /// the viewer's email, as the chat knows them (`me`): whose a card is to decide
  me : String
  /// its side panel's tabs, as the core keeps them for it on this device (`tabs`, client/core-ts/src/chat-tabs.ts)
  tabs : ChatTabs
  /// its agents' Slack and Feishu threads, the one said in last first: what is sent from here is copied to those
  /// ticked (`cc`, `chat.cc`); empty when they are in none
  cc : Array[ChatCcTo]
  /// the screens of the station it runs on (the core's `screens`), its own display first: its bar's way to them
  screens : Array[ChatScreen]
  /// the chat an agent opened it from: before its title in its bar, the way back there
  opener : Opener?
  /// the chain of led parent chats (`opener.led == true`), root first, ending with its direct opener
  openers : Array[Opener]
  /// the chats its agent made, the first first, and how many in words (创建了 3 个对话): its info's list of them
  opened : Array[OpenedChat]
  opened_text : String
}

///|
/// One of the screens of a chat's station (the chat view's `screens`): its id, kind, title, what its station says of it,
/// and whether an agent drives it now.
#derive(Eq)
pub(all) struct ChatScreen {
  id : String
  kind : String
  title : String
  line : String
  agent : Bool
}

///|
/// A thread a chat's messages can be copied to (the chat view's `cc`): its id (`chat.cc`'s `to`),
/// where it is (#channel, 私信, the Feishu group), its platform for its mark ("slack" or "feishu"), and whether it is
/// ticked.
#derive(Eq)
pub(all) struct ChatCcTo {
  thread : Double
  place : String
  via : String
  on : Bool
}

///|
/// A chat's side panel's tabs (the chat view's `tabs`): those open, in order (an agent's history by its session's key,
/// `jobs`, `files`, `letters`, the web's `service:<job>` and `file:[…]`), the one in front, and whether they are the
/// ones the chat opens by itself (its agent with no chat yet: its history), not opened by anyone.
#derive(Eq)
pub(all) struct ChatTabs {
  open : Array[String]
  shown : String?
  auto : Bool
  can_reopen : Bool
}

///|
/// A chat's view made here, not read from the core's `chat` topic: a decision's messages as their chat would show
/// them, a test's. A chat's topic is read through view_of_chat, worked out once for each version of it.
pub fn chat_view_made(v : Json) -> ChatView {
  chat_view(v)
}

///|
/// A chat's view as the core gives it, each of its messages read: for view_of_chat alone (chat_read), so no page
/// works it out of the topic again, each frame.
fn chat_view(v : Json) -> ChatView {
  chat_view_of(v, items(Some(v), "messages").map(message_of), None)
}

///|
/// Part `name` of a chat's view `v` read by `make`, or as it was read (`kept`, of `was`'s view) where it is the same
/// JSON as in the value `was` was read from: the core's deltas keep what they do not touch (src/core delta.mbt), so a
/// patched message reads none of the chat's people, agents, outbox and the rest again.
fn[T] chat_part(v : Json, was : (Json, ChatView)?, name : String, kept : (ChatView) -> T, make : () -> T) -> T {
  match was {
    Some((raw, view)) =>
      match (field(Some(v), name), field(Some(raw), name)) {
        (Some(a), Some(b)) if physical_equal(a, b) => kept(view)
        (None, None) => kept(view)
        _ => make()
      }
    None => make()
  }
}

///|
/// What a chat's station lets it open there, by the chat's key (`ChatView::can_browser`, `can_terminal`), as its view
/// was last read: kept apart from `ChatView`, whose shape every unit that reads a chat is compiled by.
// kept across runs: reset in pages' reset
let chat_remote_caps : Map[String, (Bool, Bool)] = Map([])

///|
/// Forget what the chats' stations let them open (a run's core is a new one).
pub fn chat_remote_caps_reset() -> Unit {
  chat_remote_caps.clear()
}

///|
/// Whether the chat's station lets it open a tab of its own browser (the core's `canBrowser`).
pub fn ChatView::can_browser(self : ChatView) -> Bool {
  chat_remote_caps.get(self.key).map_or(false, fn(c) { c.0 })
}

///|
/// Whether the chat's station lets it open a terminal in the chat's workspace (the core's `canTerminal`).
pub fn ChatView::can_terminal(self : ChatView) -> Bool {
  chat_remote_caps.get(self.key).map_or(false, fn(c) { c.1 })
}

///|
/// A chat's view as the core gives it, its messages read already (`messages`: chat_read's, each read again only as it
/// changed), and what else it says read again only where it changed (`was`: the value the view before was read from,
/// and that view; chat_part's).
fn chat_view_of(v : Json, messages : Array[Message], was : (Json, ChatView)?) -> ChatView {
  let s = Some(v)
  chat_remote_caps[text(s, "key")] = (flag(s, "canBrowser"), flag(s, "canTerminal"))
  let thread = field(s, "thread")
  {
    title: text(s, "title"),
    thread: opt_number(thread, "id"),
    unread: number(thread, "unread"),
    people: chat_part(v, was, "people", fn(w) { w.people }, fn() { items(s, "people").map(person_of) }),
    agents: chat_part(v, was, "agents", fn(w) { w.agents }, fn() { items(s, "agents").map(agent_of) }),
    messages,
    elsewhere: chat_part(v, was, "elsewhere", fn(w) { w.elsewhere }, fn() { items(s, "elsewhere").map(elsewhere_of) }),
    more: flag(s, "more"),
    newer: flag(s, "newer"),
    first_entry: opt_number(s, "firstEntry"),
    last_entry: opt_number(s, "lastEntry"),
    older: text(s, "older"),
    older_failed: text(s, "olderFailed"),
    letters: number(s, "letters").to_int(),
    at: opt_number(s, "at"),
    at_offset: opt_number(s, "atOffset"),
    unread_line: opt_number(s, "unreadLine"),
    unread_above: flag(s, "unreadAbove"),
    outbox: chat_part(v, was, "outbox", fn(w) { w.outbox }, fn() { chat_outbox_of(s) }),
    joins_until: opt_number(s, "joinsUntil"),
    offline: flag(s, "offline"),
    offline_note: opt_text(s, "offlineNote"),
    updating: flag(s, "updating"),
    moving: match field(s, "moving") {
      Some(Object(_)) as m => Some((text(m, "to"), text(m, "text")))
      _ => None
    },
    cache_cold: match field(s, "cacheCold") {
      Some(Object(_)) as cold => Some((text(cold, "session"), text(cold, "status"), text(cold, "detail"), flag(cold, "afresh")))
      _ => None
    },
    state: match opt_text(s, "stateText") {
      Some(words) => Some((words, text(s, "stateLead"), text(s, "stateRest")))
      None => None
    },
    state_ask: opt_number(s, "stateAsk"),
    ask_clear: flag(s, "askClear"),
    archived: flag(s, "archived"),
    archivable: flag(s, "archivable"),
    asks: chat_part(v, was, "asks", fn(w) { w.asks }, fn() { items(s, "asks").map(fn(a) { number(Some(a), "seq") }) }),
    station_update: field(s, "stationUpdate"),
    me: text(field(s, "me"), "email"),
    pending: flag(s, "pending"),
    key: text(s, "key"),
    tabs: chat_part(v, was, "tabs", fn(w) { w.tabs }, fn() {
      {
        open: items(field(s, "tabs"), "open").filter_map(fn(t) { if t is String(k) { Some(k) } else { None } }),
        shown: opt_text(field(s, "tabs"), "shown"),
        auto: flag(field(s, "tabs"), "auto"),
        can_reopen: flag(field(s, "tabs"), "canReopen"),
      }
    }),
    cc: chat_part(v, was, "cc", fn(w) { w.cc }, fn() {
      items(s, "cc").map(fn(o) {
        let o = Some(o)
        { thread: number(o, "thread"), place: text(o, "place"), via: text(o, "via"), on: flag(o, "on") }
      })
    }),
    screens: chat_part(v, was, "screens", fn(w) { w.screens }, fn() {
      items(s, "screens").map(fn(o) {
        let o = Some(o)
        { id: text(o, "id"), kind: text(o, "kind"), title: text(o, "title"), line: text(o, "line"), agent: flag(o, "agent") }
      })
    }),
    opener: {
      let o = chat_part(v, was, "opener", fn(w) { w.opener }, fn() { opener_of(s) })
      o
    },
    openers: {
      let o = chat_part(v, was, "opener", fn(w) { w.opener }, fn() { opener_of(s) })
      match field(s, "openers") {
        Some(_) => chat_part(v, was, "openers", fn(w) { w.openers }, fn() { openers_of(s) })
        None =>
          match was {
            Some((_, w)) if physical_equal(w.opener, o) => w.openers
            _ =>
              match o {
                Some(op) if op.led => [op]
                _ => []
              }
          }
      }
    },
    opened: chat_part(v, was, "opened", fn(w) { w.opened }, fn() { opened_of(s) }),
    opened_text: text(s, "openedText"),
  }
}

///|
/// The outbox of a chat's view `s` (ChatView's `outbox`) as the core gives it.
fn chat_outbox_of(s : Json?) -> Array[Outgoing] {
  items(s, "outbox").map(fn(o) {
    let s = Some(o)
    {
      id: text(s, "id"),
      text: text(s, "text"),
      words: field(s, "words"),
      attachments: items(s, "attachments").map(attachment_of),
      quotes: items(s, "quotes").map(quote_of),
      state: text(s, "state"),
      error: text(s, "error"),
      joined: flag(s, "joined"),
      followed: flag(s, "followed"),
      seq: opt_number(s, "seq").unwrap_or(-1.0),
      time: stamp_of(s, "createdAt"),
      waits: text(s, "waits"),
      progress: opt_number(s, "progress"),
      uploads: items(s, "uploads").map(fn(u) {
        (text(Some(u), "name"), number(Some(u), "size").to_int(), number(Some(u), "sent").to_int())
      }),
      created_at: number(s, "createdAt"),
      refused: flag(s, "final"),
      held: flag(s, "held"),
      unsure: flag(s, "unsure"),
    }
  })
}

///|
/// A station of the workspace as its marks show it (StationView): its address, name and mark, how it is reached.
#derive(Eq)
pub(all) struct Station {
  address : String
  name : String
  emoji : String
  icon : String
  /// direct | relay | waiting | offline, or "" (StationViaDot)
  via : String
}

///|
pub fn stations_of(v : Json?) -> Array[Station] {
  match v {
    // (the same rows as the last read, as the core's deltas keep what they do not touch: what was made of them, not
    // made again at every read of a chat's bar or page)
    Some(Array(list)) as j =>
      match stations_made.val {
        Some((was, made)) if physical_equal(was, list) => made
        _ => {
          let made = stations_read(j)
          stations_made.val = Some((list, made))
          made
        }
      }
    _ => []
  }
}

///|
// kept across runs: made of the rows it is kept with alone, the same whichever run reads them
/// What stations_of made last, with the rows it read.
let stations_made : Ref[(Array[Json], Array[Station])?] = Ref(None)

///|
/// The stations' rows as stations_of says them.
fn stations_read(v : Json?) -> Array[Station] {
  match v {
    Some(Array(list)) =>
      list.map(fn(x) {
        let s = Some(x)
        let via = @settings.station_via(s)
        {
          address: text(s, "station"),
          name: text(s, "name"),
          emoji: text(s, "emoji"),
          icon: text(s, "icon"),
          via,
        }
      })
    _ => []
  }
}

///|
/// The workspace's stations as a list's rows (`stations {scope}`: what a row shows, never a station whole), asked one
/// way wherever they are read so the core is asked them once (the settings' stations_of is the same ask).
pub fn stations_asked(scope : String) -> Map[String, Json] {
  { "scope": Json::string(scope) }
}

///|
/// What the workspace's stations' rows are asked of the core by (a topic and its params): what station_rows reads by,
/// and what a press asks ahead of what reads them.
pub fn station_rows_ask(scope : String) -> (String, Map[String, Json]) {
  ("stations", stations_asked(scope))
}

///|
/// The workspace's stations' rows (stations_asked) as they are now.
pub fn station_rows(src : Source, scope : String) -> TopicState {
  let (name, params) = station_rows_ask(scope)
  src.topic(name, params).get()
}

///|
/// The workspace's stations as a page that only names them shows them: each one's mark and how it is reached, from
/// their rows. Never what was last said while nothing read them (`lasting`'s, a place's to show at once): a chat
/// names its station as it is now, or not yet (core_signal_wbtest.mbt).
pub fn station_marks(src : Source, scope : String) -> Array[Station] {
  let t = station_rows(src, scope)
  if t.kept() {
    []
  } else {
    stations_of(t.value)
  }
}

///|
/// A chat's topics' params: its station and session.
pub fn chat_params(r : ChatRef) -> Map[String, Json] {
  { "station": Json::string(r.station), "session": Json::string(r.session) }
}

///|
/// The chat a job is in, as the core names it beside the job (`chat`: its id, the session it opens by, its title; and
/// `station` where it is on another station than the job's, a task run there for it): none where it is in none. A job
/// row opens this, never a chat of the job's own station by the chat's id (2026-11-12: a task Studio ran for a chat on
/// another station opened a chat Studio has not, waiting for good).
pub fn job_chat(job : Json?) -> ChatRef? {
  let chat = field(job, "chat")
  let station = match opt_text(chat, "station") {
    Some(s) if s != "" => s
    _ => text(job, "station")
  }
  let session = text(chat, "id")
  if chat is Some(Object(_)) && station != "" && session != "" {
    Some({ station, session, title: text(chat, "title"), station_name: "" })
  } else {
    None
  }
}

///|
/// What chat `r`'s page opens on, asked of `ask` (opens_answered's): its view, answered once it is, or why it has none,
/// or that its messages wait on a station (none of them on the device: Source.waits), its page showing them to come;
/// and, its view read, what its posts are laid out by besides it: each login's card under a post (its login, and while
/// that is under way its station's logins, which the card's head and steps follow), and each link's card in its posts'
/// words (a screen's, a station's 共享调试's, a web service's: link_card_ask), asked as the view says them, all at once. A card laid out as
/// it came, a lateness after the rows, put every row over it up by its height in one frame (the owner's, 2026-11-14:
/// data arriving late is no cause of motion; src/sfapp/chat_opens_whole_wbtest.mbt, chat_rows_open_whole_wbtest.mbt).
///
/// `whole` (where what opens waits for what it shows: gates_opens, MBUI_OPEN_WHOLE): its draft, its workspace's stations
/// and its jobs' summary too, all its page reads at once as it is first drawn (page_opens), so the composer opens as
/// tall as its draft and its bar with its jobs' mark, never a frame after.
pub fn chat_opens(r : ChatRef, ask : (String, Map[String, Json]) -> TopicState, whole? : Bool = false) -> Bool {
  // (asked with its view, not after it: all of it asked at once)
  let mut all = true
  if whole {
    page_opens(Chat(r), fn(name, params) {
      if name != "chat" {
        all = open_told(ask(name, params)) && all
      }
    })
  }
  let t = ask("chat", chat_params(r))
  if !opens_answered(t) {
    return t.waiting && all
  }
  // (the faces of its people in its bar, sfapp's chat.mbt people_stack, and each person's over their messages:
  // sfpages' message.mbt person_avatar, message_head_node.mbt's; and what its posts are laid out by: chat_opening,
  // read of its value once however often what opens waits on it)
  let o = match t.value {
    Some(v) => chat_opening(r.station, v)
    None => { station: r.station, raw: Json::null(), faces: [], asks: [] }
  }
  all = pictures_in(opening_pictures.val, o.faces) && all
  for a in o.asks {
    match a {
      LinkAsk(to) =>
        match link_card_ask(to) {
          Some((name, params)) => {
            let s = ask(name, params)
            all = (opens_answered(s) || s.waiting) && all
          }
          None => ()
        }
      LoginAsk(station, id) => {
        let (name, params) = machine_login_ask(station, id)
        let l = ask(name, params)
        if !opens_answered(l) {
          if !l.waiting {
            all = false
          }
        } else if flag(l.value, "active") {
          let (name, params) = machine_logins_ask(station)
          let s = ask(name, params)
          all = (opens_answered(s) || s.waiting) && all
        }
      }
    }
  }
  all
}

///|
/// What chat_opens asks of a chat's posts beside its view, in their order: a link's card in a post's words (its link
/// to a station: link_card_ask), a login's card under a post (its station and its login).
priv enum OpeningAsk {
  LinkAsk(@sf.LinkTo)
  LoginAsk(String, String)
}

///|
/// What chat_opens reads of a chat's value `raw` (of a chat on station `station`): the faces it shows (its people's,
/// its posts' authors') and what its posts ask (OpeningAsk).
priv struct Opening {
  station : String
  raw : Json
  faces : Array[String]
  asks : Array[OpeningAsk]
}

///|
/// The last chats' values chat_opens read (chat_opening), `chats_kept` of them: what opens waits on a chat again and
/// again as each other thing it waits on comes (its draft, its jobs, each face decoded), the chat's value the same.
// kept across runs: made of the value each is kept with alone, the same whichever run reads it; emptied as a run begins
// (chat_seeds_reset) so no run holds another's values
let chat_openings : Array[Opening] = []

///|
/// What chat_opens reads of chat value `v` of a chat on `station`: read of its JSON (no post read as a Message), once
/// for each value (chat_openings).
fn chat_opening(station : String, v : Json) -> Opening {
  for o in chat_openings {
    if physical_equal(o.raw, v) && o.station == station {
      return o
    }
  }
  let s = Some(v)
  let faces = items(s, "people").map(fn(p) { person_of(p).picture })
  let messages = items(s, "messages")
  for m in messages {
    if !["agent", "station", "ember", "stillfail"].contains(text(Some(m), "authorKind")) {
      faces.push(text(field(Some(m), "by"), "picture"))
    }
  }
  let asks : Array[OpeningAsk] = []
  for m in messages {
    let p = Some(m)
    // (each link's card in a post's words, as the message tells them, its tree or its runs: a screen's a capsule or,
    // previewed, the screen across its top. None of still.fail's notices, whose words are read as no post's; none
    // read of a post's words here, every post of the chat each time it opens)
    let kind = text(p, "authorKind")
    if field(p, "notice") is None && !["station", "ember", "stillfail"].contains(kind) {
      let links = links_to_of(field(p, "words"), kind, flag(p, "mine"), text(p, "text"), field(p, "md"), told=true)
      for _, to in links {
        if to.station != "" {
          asks.push(LinkAsk(to))
        }
      }
    }
    let card = field(p, "card")
    let id = text(card, "login")
    if text(card, "type") != "login" || id == "" {
      continue
    }
    asks.push(LoginAsk(card_login_station(station, text(card, "station")), id))
  }
  let o = { station, raw: v, faces, asks }
  if chat_openings.length() >= chats_kept {
    chat_openings.remove(0) |> ignore
  }
  chat_openings.push(o)
  o
}

///|
/// What each link of message `m` is to, as the core says (each link's `to`), by its address: of a person's words' runs
/// (the first run of each), or of an agent's Markdown (read as the row is, as its words are); none of a person's words
/// said without runs; `told`: only as the message tells them (its runs, its tree), none read of its words here.
pub fn message_links_to(m : Message, told? : Bool = false) -> Map[String, @sf.LinkTo] {
  links_to_of(m.words, m.author_kind, m.mine, m.text, m.md, told~)
}

///|
/// message_links_to of a message's parts (its `words`, `authorKind`, `mine`, `text` and `md`), so what reads them of its
/// JSON alone (chat_opening) reads them as a Message's are read.
fn links_to_of(
  words : Json?,
  author_kind : String,
  mine : Bool,
  said : String,
  md : Json?,
  told~ : Bool,
) -> Map[String, @sf.LinkTo] {
  match words {
    Some(Array(runs)) => {
      let out : Map[String, @sf.LinkTo] = Map([])
      for r in runs {
        let href = text(Some(r), "link")
        if href != "" && !out.contains(href) {
          out[href] = @sf.link_to_of(field(Some(r), "to").unwrap_or(Json::null()))
        }
      }
      out
    }
    _ if author_kind == "person" || mine => Map([])
    _ if told && !(md is Some(Array(_))) => Map([])
    _ => @sf.md_links_to(said, md)
  }
}

///|
/// The station a login's card under a post of a chat on `chat_station` is of: the chat's, or `other` of its workspace
/// where the card names one.
pub fn card_login_station(chat_station : String, other : String) -> String {
  if other == "" {
    return chat_station
  }
  match chat_station.find("/") {
    Some(i) => chat_station.exact_view(end=i).to_owned() + "/" + other
    None => other
  }
}

///|
/// What the core is asked for login `id` of `station` (its card's, and its chat's as it opens: chat_opens): its
/// `machineLogin`.
pub fn machine_login_ask(station : String, id : String) -> (String, Map[String, Json]) {
  ("machineLogin", { "station": Json::string(station), "id": Json::string(id) })
}

///|
/// What the core is asked for station `station`'s logins (what may be done of them: a login's card's, its page's
/// 登录's): its `machineLogins`.
pub fn machine_logins_ask(station : String) -> (String, Map[String, Json]) {
  ("machineLogins", { "station": Json::string(station) })
}

///|
/// The core's marks of every workspace's chats (`workspaceMarks`: the rail's, 待处理's, the chat each was left on, and in
/// each what the others have waiting), asked one way wherever a workspace opening reads them: one topic whichever
/// workspace is shown, held across a switch. Asked of the one shown, each switch asked another, sent whole (24.6 KB of
/// the real-size two) for what it said of the others alone.
pub fn marks_asked() -> Map[String, Json] {
  {}
}

///|
/// The bar needs only whether there are jobs and whether its button has an alarm; the jobs sheet reads the whole list.
pub fn chat_jobs_summary_params(r : ChatRef) -> Map[String, Json] {
  let params = chat_params(r)
  params["summary"] = Json::boolean(true)
  params
}

///|
/// Whether a chat has current web services, reading `hasServices` from a summary `chatJobs` payload, falling back to
/// checking `service: true` items in a full payload, or `hasJobs` for legacy summary payloads before `hasServices`
/// existed.
pub fn chat_jobs_has_services(j : Json?) -> Bool {
  match field(j, "hasServices") {
    Some(True) => true
    Some(False) => false
    _ => {
      let list = items(j, "jobs")
      if list.length() > 0 {
        list.iter().any(fn(x) { flag(Some(x), "service") })
      } else {
        // Legacy summary payload from an older core / replay trace before `hasServices` existed
        flag(j, "hasJobs")
      }
    }
  }
}

///|
/// Service-only alarm ("fail", "restart", or "") from a summary or full `chatJobs` payload.
pub fn chat_jobs_service_alarm(j : Json?) -> String {
  match field(j, "serviceAlarm") {
    Some(String(s)) => s
    _ => {
      let list = items(j, "jobs")
      if list.length() == 0 {
        // Legacy summary payload (no `hasServices` and no `jobs` list): fall back to `alarm`
        if field(j, "hasServices") is None {
          return text(j, "alarm")
        }
        return ""
      }
      let mut restart = false
      for x in list {
        if !flag(Some(x), "service") {
          continue
        }
        let tn = text(Some(x), "tone")
        if tn == "fail" {
          return "fail"
        }
        if tn == "restart" {
          restart = true
        }
      }
      if restart { "restart" } else { "" }
    }
  }
}

///|
/// Count of current non-service background jobs (including watches and scheduled tasks) from a summary or full
/// `chatJobs` payload.
pub fn chat_jobs_background_count(j : Json?) -> Int {
  match field(j, "backgroundCount") {
    Some(Number(n, ..)) => n.to_int()
    _ => {
      let mut n = 0
      for x in items(j, "jobs") {
        if !flag(Some(x), "service") {
          n += 1
        }
      }
      n
    }
  }
}

///|
/// The last part of a station's path, whether it came from Windows or Unix.
pub fn base_name(path : String) -> String {
  dv_name(path)
}
