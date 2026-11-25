// A profile's page, one in every frame (the Small stack's, the wide frame's pane, the tape's panel, the profiles'
// place): who the account is and whether it works now (its provider's mark, its name renamed here, the runtimes it
// serves, what it is, its last check, checking again; its ⋯ to delete it, or stop the machine's own), signing it in
// where that comes first, what is left of its allowance, what it spent, the stations it is on, sharing it, the
// workspaces it serves, fast mode, its models, how it runs, who uses it, the account itself (its key, signing in again)
// and its variables. Made once as nodes of the window's tree (page_node, laid out by the width its frame gives it);
// everything said is the core's (its overview's profile, the workspace's profiles, the usage view), followed as it
// changes.

///|
/// A variable's row being written: its name, its value, what it was (its name saved, "" a new one), its value masked
/// as saved ("" not a secret).
priv struct EnvRow {
  key : @ui.Field
  value : @ui.Field
  original : String
  masked : String
}

///|
/// What a profile's page opens of its own while it is made (each its node's, let go with it): the command to sign in
/// by hand shown, its variables opened to be written, a device's code copied.
priv struct ProfileOpen {
  command : @signals.Signal[Bool]
  env : @signals.Signal[Bool]
  copied : @signals.Signal[Bool]
}

///|
/// The fields of a profile's models' panel, by their key (made as first drawn).
// kept across runs: made as a panel first shows one; profile_page_reset empties it
let profile_fields : Map[String, @ui.Field] = Map([])

///|
fn profile_page_reset() -> Unit {
  profile_fields.clear()
}

///|
/// A field of the models' panel, by its key, made once.
pub fn profile_field(key : String) -> @ui.Field {
  match profile_fields.get(key) {
    Some(f) => f
    None => {
      let f = @ui.Field::new()
      profile_fields[key] = f
      f
    }
  }
}

///|
/// A profile's page (AccountPage), by its station and id, made once in node `v` (laid out by the `width` its frame gives
/// it, in the frame it is given): while the station's overview is read the first time, all of it in its bones (a profile
/// made up, through a core that answers nothing: waiting_node); one the station lists no more, that it is not found.
/// `stint`: the page's time on top, a workspace's picture asked for on it.
pub fn profile_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  address : String,
  id : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
  stint? : () -> Int = fn() { 0 },
) -> Unit {
  let s = fn() { @settings.station_of(core, here(), address) }
  let o = fn() { field(s(), "overview") }
  // (shown in a pane by a press that asked what it reads (sfbase's show_answered): what it asked let go once this first
  // build has read it)
  @sfbase.shown_read(@sfbase.profile_shown_at(address, id))
  // (0 read the first time, 1 its profile there, 2 none of that id; the account it is, its own ask, answered too: the
  // page opens whole, its stations' block with it. Opened from a list, it opens once both are answered and never shows
  // this: a link straight to it may)
  let found = fn() {
    // (both read every time, so both are asked at once whichever comes first; its press waits for both before it
    // opens it: sfbase's account_open.mbt)
    let account = @settings.profile_read(core, here(), address, id).value
    if !(o() is Some(Object(_))) || account is None {
      0
    } else if items(o(), "profiles").iter().any(fn(p) { text(Some(p), "id") == id }) {
      1
    } else {
      2
    }
  }
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  v.pick(at_once=true, found, fn(p, what) {
    match what {
      1 => profile_found_node(p, core, here, s, address, id, on_back, frame, said, width, tips, stint)
      2 =>
        @sf.page_node(p, fn() { "Profile" }, on_back~, frame~, said?, width?, tips?, fn() { ["none"] }, fn(b, _) {
          @sf.page_note_node(b, fn() { @sf.t("web-pages.profiles.notFound", args=[("id", id)]) })
        })
      _ =>
        @sf.page_node(p, fn() { "Profile" }, on_back~, frame~, said?, width?, tips?, fn() { ["wait"] }, fn(b, _) {
          @sf.waiting_node(
            b,
            fn(w) {
              let quiet = core.quiet()
              let sp = profile_sample()
              let ss : Json? = Some({ "station": "sample", "name": Json::string(@sf.sample_words(4)) })
              let so : Json? = Some({ "profiles": [sp] })
              let open = profile_open()
              let ps = fn() { Some(sp) }
              let sv = fn() { ss }
              let ov = fn() { so }
              let entry = fn() -> Json? { None }
              profile_head_node(w, quiet, here, "sample", "sample", sv, ps, entry, tips)
              w.each(
                at_once=true,
                fn() { profile_keys(quiet, here, ov, ps, entry) },
                fn(key) { key },
                fn(slot, key) {
                  profile_block_node(slot, quiet, here, "sample", "sample", sv, ov, ps, entry, open, stint, tips, key.untracked())
                },
              )
            },
            note=fn() { { reading: true, text: @sf.t("web-pages.profiles.loading"), failing: [] } },
          )
        })
    }
  })
}

///|
/// What a profile's page opens of its own, none of it yet.
fn profile_open() -> ProfileOpen {
  { command: @signals.signal(false), env: @signals.signal(false), copied: @signals.signal(false) }
}

///|
/// The page of a profile its station lists (AccountView), the same parts in the same order on every screen, by what a
/// person comes to it for: who the account is and whether it works now (its head, checked again there); what to do
/// first where it does not (signing it in, its trouble's next step); how much is left of it and what it spent; who uses
/// it and the stations it is on; which models it may use and how it runs; whom it is shared with; then the account
/// itself (its key, its sign-in) and its variables, what is changed least. Its head says who it is: no title over it
/// (what the frame's bar says of it, what it is of: Profile).
fn profile_found_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  s : () -> Json?,
  address : String,
  id : String,
  on_back : () -> Unit,
  frame : () -> PageFrame,
  said : ((@sf.PageSaid) -> Unit)?,
  width : (() -> Double)?,
  tips : @sf.TipLayer?,
  stint : () -> Int,
) -> Unit {
  let o = fn() { field(s(), "overview") }
  // (looked up once as the station's overview changes, what reads it woken only where this account comes out otherwise)
  let p_now = @signals.computed(
    fn(_) {
      let all = items(o(), "profiles")
      match all.search_by(fn(x) { text(Some(x), "id") == id }) {
        Some(i) => Some(all[i])
        None => None
      }
    },
    same=json_opt_same,
  )
  let p = fn() -> Json? { p_now.get() }
  // the account it is, on whichever stations have it: its own topic (`profile`), never the workspace's list
  let entry = fn() -> Json? { @settings.profile_of(core, here(), address, id) }
  let open = profile_open()
  @sf.page_node(
    v,
    fn() { @sf.t("android-misc.bar.place.profiles") },
    on_back~,
    frame~,
    said?,
    width?,
    tips?,
    head=fn(h) { profile_head_node(h, core, here, address, id, s, p, entry, tips) },
    actions=fn(a) { profile_more_node(a, core, here, address, p) },
    // (every block it may have, in their order, each in a room that opens as profile_keys comes to name it and closes
    // as it stops naming it, on its way, as the old page's `keys` did: none come or gone at once over what is under them)
    fn() {
      ["sign-in", "trouble", "protection", "quota", "station", "settings"]
    },
    fn(b, key) {
      b.show(fn() { profile_keys(core, here, o, p, entry).contains(key) }, fn(r) {
        profile_block_node(r, core, here, address, id, s, o, p, entry, open, stint, tips, key)
      })
    },
  )
}


///|
/// Whether the profile `p` is another station's copy of it (shared to this one).
fn profile_copy(p : Json?) -> Bool {
  text(field(p, "share"), "role") == "user"
}

///|
/// Whether a copy of another station's profile is one its station pauses (`share.pausable`, said since 2026-11-11; a
/// station from before refuses `enabled` on a copy).
fn profile_pausable(p : Json?) -> Bool {
  profile_copy(p) && flag(field(p, "share"), "pausable") && has(p, "enabled")
}

///|
/// Whether a subscription's sign-in is under way (its `login`'s state).
fn signing_in(p : Json?) -> Bool {
  let ls = text(field(p, "login"), "state")
  ["starting", "waiting", "needs_code", "needs_project", "needs_approval", "verifying"].contains(ls) ||
  (ls == "done" && text(field(p, "check"), "state") == "login") ||
  ["starting", "waiting"].contains(text(field(p, "afterSignIn"), "state"))
}

///|
/// Whether it asks to be signed in first: its check says so, it is being signed in, or its last sign-in failed.
fn sign_asked(p : Json?) -> Bool {
  text(field(p, "check"), "state") == "login" || signing_in(p) || text(field(p, "login"), "state") == "failed"
}

///|
/// Whether this profile is a plain API-key / custom-env profile that does not use OAuth sign-in or subscription quota.
fn plain_key(p : Json?) -> Bool {
  let access = field(p, "access")
  let kind = if text(access, "kind") != "" { text(access, "kind") } else { text(p, "kind") }
  let login = flag(access, "login") || flag(p, "login")
  ["anthropic-api", "api-provider", "env"].contains(kind) && !login
}

///|
/// Whether its allowance has anything to show: windows, credits, or resets.
fn has_quota(p : Json?) -> Bool {
  let q = field(p, "quota")
  (text(q, "state") == "ok" && items(q, "windows").length() > 0) || text(q, "creditsText") != "" || items(q, "resets").length() > 0
}

///|
/// Whether the profile page should show the quota card (including unchecked, unavailable, or unsupported states).
fn shows_quota(p : Json?) -> Bool {
  !plain_key(p) ||
  has_quota(p) ||
  (field(p, "quota") is Some(Object(_)) && text(field(p, "quota"), "state") != "unsupported")
}

///|
/// The blocks of the page by what each is, as the profile is now: what to do first (signing it in, else its trouble's
/// next step), its allowance and who uses it, its stations and sharing, and its settings (a copy of another station's:
/// none of those it does not set). One come or gone opens or closes where it is.
fn profile_keys(core : Core, here : () -> Here, o : () -> Json?, p : () -> Json?, entry : () -> Json?) -> Array[String] {
  ignore(core)
  ignore(here)
  ignore(entry)
  let pv = p()
  let access = field(pv, "access")
  let kind = text(access, "kind")
  let copy = profile_copy(pv)
  let machine = flag(pv, "machine")
  let signs_in = kind == "subscription" || kind == "service" || flag(access, "login")
  let asked = sign_asked(pv)
  let out : Array[String] = []
  if !copy && signs_in && !machine && asked {
    out.push("sign-in")
  } else if field(pv, "trouble") is Some(Object(_)) && text(field(pv, "trouble"), "action") != "login" {
    out.push("trouble")
  }
  if profile_in_protection(pv) {
    out.push("protection")
  }
  if shows_quota(pv) || profile_users(o(), pv).length() > 0 {
    out.push("quota")
  }
  let has_sharing = has(o(), "sharing") && !(field(o(), "sharing") is Some(Null))
  if copy && has_sharing {
    out.push("station")
  }
  if !copy {
    out.push("settings")
  }
  out
}

///|
/// Whether it says fast mode by default (FastSection).
fn profile_fast(p : Json?) -> Bool {
  has(p, "fast") && !(field(p, "fast") is Some(Null))
}

///|
/// Whether a Claude profile says whether its agents' work goes to the background when a message comes.
fn profile_background(p : Json?) -> Bool {
  items(p, "runtimes").iter().any(fn(r) { r == "claude" }) && has(p, "backgroundOnMessage")
}

///|
/// Whether this subscription/membership profile supports configuring `maxConcurrentSessions`.
fn profile_max_sessions(p : Json?) -> Bool {
  if profile_copy(p) {
    return false
  }
  let a = field(p, "access")
  let kind = text(a, "kind")
  kind == "subscription" ||
  kind == "opencode-go" ||
  (text(a, "provider") == "kimi-code" && flag(a, "login"))
}

///|
/// Whether this subscription/membership profile is currently in default new-account protection.
fn profile_in_protection(p : Json?) -> Bool {
  !profile_copy(p) &&
  flag(p, "newAccountProtection") &&
  (match field(p, "maxConcurrentSessions") {
    Some(Number(n, ..)) if n >= 1.0 => true
    _ => false
  })
}

///|
/// The connects bound to it, as the station's overview lists them.
fn profile_users(o : Json?, p : Json?) -> Array[Json] {
  strings(p, "usedBy").filter_map(fn(uid) {
    match items(o, "connects").search_by(fn(cn) { text(Some(cn), "id") == uid }) {
      Some(i) => Some(items(o, "connects")[i])
      None => None
    }
  })
}

///|
/// The block `key` of a profile's page (profile_keys') in node `b`, as the profile is now.
fn profile_block_node(
  b : @view.View,
  core : Core,
  here : () -> Here,
  address : String,
  id : String,
  s : () -> Json?,
  o : () -> Json?,
  p : () -> Json?,
  entry : () -> Json?,
  open : ProfileOpen,
  stint : () -> Int,
  tips : @sf.TipLayer?,
  key : String,
) -> Unit {
  match key {
    "sign-in" => profile_sign_in_node(b, core, address, id, s, p, open)
    "trouble" => profile_trouble_node(b, core, address, id, s, p, open)
    "protection" => profile_protection_node(b, core, address, id, p)
    "quota" => profile_quota_node(b, core, address, id, o, p, tips)
    "station" => profile_station_node(b, core, address, id, s, o, p, entry)
    "settings" => profile_settings_node(b, core, here, address, id, s, o, p, entry, open, stint, tips)
    _ => ()
  }
}

///|
/// Its head (AccountView's identity) in node `h`: its provider's mark, its name (renamed here, but for the machine's own
/// and a copy) and the runtimes it serves, what it is (its station's name where it is on several), its last check and
/// when, checking again (its allowance read again with it); its ⋯.
fn profile_head_node(
  h : @view.View,
  core : Core,
  here : () -> Here,
  address : String,
  id : String,
  s : () -> Json?,
  p : () -> Json?,
  entry : () -> Json?,
  tips : @sf.TipLayer?,
) -> Unit {
  let on = [("station", address), ("id", id)]
  // what it is, in a line: its kind, its plan, the address signed in (when not its name), where it is
  let facts = fn() {
    let pv = p()
    let ak = text(field(pv, "access"), "kind")
    let kind_word = if ak == "api-provider" && text(pv, "providerName") != "" {
      "API key · " + text(pv, "providerName")
    } else if ak == "anthropic-api" {
      "API key · Anthropic"
    } else {
      text(pv, "kindText")
    }
    let email = text(pv, "email")
    // of an account on several stations, this station's (each's own part is under Station), not all of them
    let several = items(entry(), "members").filter(fn(m) { text(Some(m), "role") != "user" }).length() > 1
    let place = if several {
      @sf.t("web-pages.profiles.onStation", args=[("station", text(s(), "name"))])
    } else {
      ""
    }
    join([kind_word, text(pv, "planText"), if email != text(pv, "name") { email } else { "" }, place], " · ")
  }
  @sf.own_head_node(
    h,
    fn(m, side) {
      let glyph = if side <= 32.0 { pf_mark_wide_glyph } else { pf_mark_glyph }
      m.pick(at_once=true, fn() { (text(p(), "runtime"), text(field(p(), "access"), "kind"), text(p(), "providerMark")) }, fn(l, k) {
        @sf.provider_logo_node(l, k.0, k.1, glyph, k.2) |> ignore
      })
    },
    fn() { text(p(), "name") },
    rename=fn() { profile_rename(core, address, @signals.untracked(p)) },
    renames=fn() { !flag(p(), "machine") && !profile_copy(p()) },
    rename_label=fn() { @sf.t("web-pages.settings.stations.rename") },
    // its new name shows while it is saved
    busy=fn() { is_doing(core, ["profile.put"], on) },
    tags=fn(t) { runtime_tags_node(t, p) },
    lines=fn() { [facts()] },
    state=fn(st) { profile_state_node(st, core, address, id, p, tips) },
    actions=fn(a) { profile_more_node(a, core, here, address, p) },
  )
}

///|
/// The runtimes and uses this profile serves (runtimeTags) in node `t`: a clear label followed by a tag with its icon
/// for each runtime and automatic decisions.
fn runtime_tags_node(t : @view.View, p : () -> Json?) -> Unit {
  let pairs = fn() -> Array[(String, Bool)] {
    let pv = p()
    let out : Array[(String, Bool)] = []
    for r in items(pv, "runtimes") {
      if r is String(rt) && rt != "" {
        out.push((rt, false))
      }
    }
    if items(pv, "uses").iter().any(fn(u) { u == "decision" }) {
      out.push(("decision", true))
    }
    out
  }
  t.show(fn() { !pairs().is_empty() }, fn(row) {
    @sf.style_node(row, fn() { pf_tags })
    row.wraps(Is(Some(pf_tags_line_gap))) |> ignore
    @sf.words_node(
      row,
      fn() { @sf.t("common.provider.uses", args=[("uses", "")]).trim(chars=" ").to_owned() },
      fn() { pf_tags_lead },
    )
    |> ignore
    row.each(pairs, fn(x) { x.0 }, fn(item, x) {
      let (id, is_decision) = @signals.untracked(fn() { x.get() })
      @sf.tag_node(
        item,
        fn() { if is_decision { @sf.t("common.decision") } else { @settings.runtime_label(id) } },
        lead=fn(m) {
          if is_decision {
            @sf.icon_node(m, "sparks", pf_tag_icon, By(fn() { @sf.theme().p.muted })) |> ignore
          } else {
            @sf.maker_mark_node(m, "", id, pf_tag_icon) |> ignore
          }
        },
      )
    })
  })
}

///|
/// How it stands under its head (profileState) in node `st`: its check's pill where it is not well, what the check said
/// and when, words of one line (short of room, cut from its end: when it was checked first; nothing of it moving under
/// the rest as what the check said changes), checking again (its allowance read again with it), a spinner while it is.
fn profile_state_node(st : @view.View, core : Core, address : String, id : String, p : () -> Json?, tips : @sf.TipLayer?) -> Unit {
  let on = [("station", address), ("id", id)]
  let acting = fn() { is_doing(core, ["profile.check", "profile.quota"], on) }
  let checking = fn() { is_doing(core, ["profile.check"], on) }
  let refreshing_quota = fn() { is_doing(core, ["profile.quota"], on) }
  st.show(at_once=true, fn() { text(p(), "checkTone") != "green" }, fn(x) {
    // (its tone as the check has it now: the pill made again in it)
    x.pick(at_once=true, fn() { pill_tone(text(p(), "checkTone")) }, fn(y, tone) { @sf.pill_node(y, fn() { text(p(), "checkText") }, tone~) |> ignore })
  })
  st.box(fn(b) {
    @sf.style_node(b, fn() { pf_state })
    b.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    @sf.words_node(b, fn() {
      let pv = p()
      let ago = text(field(field(field(pv, "check"), "time"), "checkedAt"), "ago")
      let when = if checking() {
        @sf.t("android-settings.version.checking")
      } else if refreshing_quota() {
        @sf.t("android-settings.quota.checking")
      } else if ago != "" {
        @sf.t("web-pages.profiles.checkedAt", args=[("time", ago)])
      } else {
        ""
      }
      let line = if text(pv, "checkTone") == "green" && !checking() {
        if !shows_quota(pv) {
          let detail = opt_text(field(pv, "quota"), "detail").unwrap_or("")
          if detail != "" { detail } else { text(pv, "checkText") }
        } else {
          let email = text(pv, "email")
          let raw = text(pv, "checkLine")
          if email != "" {
            raw.replace_all(old="，" + email, new="").replace_all(old=", " + email, new="")
          } else {
            raw
          }
        }
      } else {
        ""
      }
      join([line, when], " · ")
    }, fn() { pf_check_words })
    |> ignore
    b.pick(at_once=true, acting, fn(x, busy) {
      if busy {
        @sf.spinner_node(x, size=pf_spin) |> ignore
      } else {
        @sf.icon_action_node(
          x,
          "refresh",
          fn() { @sf.t("web-pages.profiles.recheck") },
          fn() {
            @settings.act(core, @sf.t("web-pages.profiles.recheck"), "profile.check", obj([("station", str(address)), ("id", str(id))]))
            // (its allowance read again with it: how much is left, as of now)
            let pv = @signals.untracked(p)
            let q = field(pv, "quota")
            if shows_quota(pv) && !(q is Some(Object(_)) && text(q, "state") == "unsupported") {
              @settings.act(core, @sf.t("web-pages.profiles.refresh"), "profile.quota", obj([("station", str(address)), ("id", str(id))]))
            }
          },
          disabled=fn() { has(p(), "enabled") && !flag(p(), "enabled") },
          tips?,
        )
        |> ignore
      }
    })
  })
  |> ignore
}

///|
/// The tone of a pill by the core's (red, amber, blue, green).
fn pill_tone(tone : String) -> @sf.PillTone {
  match tone {
    "red" => Red
    "amber" => Amber
    "blue" => Blue
    "green" => Green
    _ => Neutral
  }
}

///|
/// Its ⋯ in node `a` (a copy of another station's: only where its station says it pauses it, `share.pausable`; one from
/// before refuses that): pressed, its menu beside it (profile_menu), lined up at its end.
fn profile_more_node(a : @view.View, core : Core, here : () -> Here, address : String, p : () -> Json?) -> Unit {
  a.show(at_once=true, fn() { !profile_copy(p()) || profile_pausable(p()) }, fn(m) {
    // (beside itself, as it is pressed)
    @sf.icon_action_opens_node(m, "more", fn() { @sf.t("common.more") }, fn(at) {
      let (x, y, w, h) = at.placed_window_now()
      profile_menu(core, here(), address, @signals.untracked(p), At(x, y, w, h))
    })
    |> ignore
  })
}

///|
/// Its menu, beside what opened it (`from`): renaming it (but the machine's own), turning a key's off or on, deleting
/// it (the machine's own login: stopping it, the login stays the machine's), asked first. A copy of another station's
/// is edited there: here only whether this station uses it (停用, 启用: `profile.put` `enabled`, kept by its station as
/// the copy is refreshed).
fn profile_menu(core : Core, here : Here, address : String, p : Json?, from : @sf.Beside) -> Unit {
  let id = text(p, "id")
  let on = [("station", address), ("id", id)]
  let machine = flag(p, "machine")
  let copy = profile_copy(p)
  let access = field(p, "access")
  let keyed = ["api-provider", "anthropic-api", "opencode-go"].contains(text(access, "kind")) && !flag(access, "login")
  let can_disable = (keyed && has(p, "enabled")) || profile_pausable(p)
  let item = if machine { @sf.t("web-pages.profiles.disable") } else { @sf.t("web-pages.profiles.delete") }
  let remove = fn() {
    let (title, words) = if machine {
      (
        @sf.t("web-pages.profiles.disableConfirm", args=[("name", text(p, "name"))]),
        @sf.t("web-pages.profiles.disableBody", args=[("name", @sf.product()), ("runtime", @settings.runtime_label(text(p, "runtime")))]),
      )
    } else {
      (@sf.t("web-pages.archive.deleteConfirm", args=[("title", text(p, "name"))]), @sf.t("web-pages.profiles.deleteBody", args=[("name", @sf.product())]))
    }
    confirm(title, words, item, danger=true, fn() {
      // closed where its page was pushed on the stack; in the profiles' place it stays on the place, which moves on to
      // the first left once the station has dropped it (places.mbt place_route)
      @sfbase.close_page(Setting(@settings.Route::Profile(address, id))) |> ignore
      @settings.act(
        core,
        item,
        "profile.delete",
        obj([("station", str(address)), ("id", str(id))]),
        done=if machine { @sf.t("web-pages.profiles.disabled") } else { @sf.t("web-pages.profiles.deleted") },
        then=fn(_) {
          let key = place_key(here.workspace, "profiles")
          if place_pick.get(key) == Some(@settings.Route::Profile(address, id)) {
            place_pick.remove(key)
          }
        },
      )
    })
  }
  let items : Array[@sf.MenuItem?] = []
  if !machine && !copy {
    items.push(Some(@sf.menu_item_of(@sf.t("web-pages.settings.stations.rename"), icon="edit", fn() { profile_rename(core, address, p) })))
    if !keyed && !sign_asked(p) {
      items.push(
        Some(
          @sf.menu_item_of(
            @sf.t("web-pages.signIn.again"),
            icon="log-in",
            disabled=is_doing(core, ["profile.login"], on),
            fn() { @settings.act(core, @sf.t("web-pages.profiles.signIn"), "profile.login", obj([("station", str(address)), ("id", str(id))])) },
          ),
        ),
      )
      let command = text(p, "loginCommand")
      if command != "" {
        items.push(
          Some(
            @sf.menu_item_of(@sf.t("web-pages.profiles.manual"), icon="terminal", fn() {
              @sf.panel_nodes(
                @sf.t("web-pages.profiles.manual"),
                fn(v, _) { v.box(fn(b) { @sf.code_block_node(b, fn() { command }, fn() { "" }, fn() { None }, command=true) }) |> ignore },
                from=Unanchored,
              )
            }),
          ),
        )
      }
    }
  }
  if can_disable {
    let enabled = flag(p, "enabled")
    let label = if enabled { @sf.t("web-pages.profiles.disable") } else { @sf.t("web-pages.connect.enable") }
    let change = fn() {
      @settings.act(
        core,
        label,
        "profile.put",
        obj([("station", str(address)), ("id", str(id)), ("input", obj([("enabled", Json::boolean(!enabled))]))]),
        done=if enabled { @sf.t("web-pages.profiles.disabled") } else { @sf.t("web-pages.connect.enabled") },
      )
    }
    items.push(Some(@sf.menu_item_of(label, icon="power", disabled=is_doing(core, ["profile.put"], on), fn() {
      if enabled {
        let words = @sf.t(if copy { "web-pages.profiles.disableCopyBody" } else { "web-pages.profiles.disableKeyBody" })
        confirm(@sf.t("web-pages.profiles.disableConfirm", args=[("name", text(p, "name"))]), words, label, danger=true, change)
      } else {
        change()
      }
    })))
  }
  if !copy {
    items.push(Some(@sf.menu_item_of(item, icon="trash", danger=true, disabled=is_doing(core, ["profile.delete"], on), remove)))
  }
  @sf.menu(items, from~, along=End)
}

// ── what to do first ────────────────────────────────────────────────────

///|
/// Opens the dialog to edit `maxConcurrentSessions` (blank or 0 clears to unlimited).
fn ask_max_sessions(core : Core, address : String, id : String, p : () -> Json?) -> Unit {
  let current = match field(@signals.untracked(p), "maxConcurrentSessions") {
    Some(Number(n, ..)) if n >= 1.0 => n.to_int().to_string()
    _ => ""
  }
  @sf.ask(
    @sf.t("web-pages.profiles.maxConcurrentSessions"),
    @sf.t("common.save"),
    fn(raw) {
      let trimmed = raw.trim(chars=" \t\n").to_owned()
      if trimmed == "" || trimmed == "0" {
        @settings.act(
          core,
          @sf.t("web-pages.profiles.maxConcurrentSessions"),
          "profile.put",
          obj([("station", str(address)), ("id", str(id)), ("input", obj([("maxConcurrentSessions", Json::null())]))]),
          done=@sf.t("web-pages.profiles.maxConcurrentSessionsSaved"),
        )
      } else {
        let mut n = 0
        let mut ok = trimmed.length() > 0 && trimmed.length() <= 9
        for c in trimmed {
          if c >= '0' && c <= '9' {
            n = n * 10 + (c.to_int() - '0'.to_int())
          } else {
            ok = false
          }
        }
        if ok && n > 0 {
          @settings.act(
            core,
            @sf.t("web-pages.profiles.maxConcurrentSessions"),
            "profile.put",
            obj([("station", str(address)), ("id", str(id)), ("input", obj([("maxConcurrentSessions", Json::number(n.to_double()))]))]),
            done=@sf.t("web-pages.profiles.maxConcurrentSessionsSaved"),
          )
        } else {
          @sfbase.toast_later(@sf.t("web-pages.profiles.maxConcurrentSessionsInvalid"))
        }
      }
    },
    value=current,
    placeholder=@sf.t("web-pages.profiles.maxConcurrentSessionsUnlimited"),
    hint=@sf.t("web-pages.profiles.maxConcurrentSessionsHint"),
    empty=true,
  )
}

///|
/// New-account protection notice card in node `b`: explains why the default concurrency limit exists
/// and offers one-click disable (`maxConcurrentSessions: null, newAccountProtection: false`) or limit adjustment.
fn profile_protection_node(
  b : @view.View,
  core : Core,
  address : String,
  id : String,
  p : () -> Json?,
) -> Unit {
  let on = [("station", address), ("id", id)]
  let cap_text = fn() -> String {
    match field(p(), "maxConcurrentSessions") {
      Some(Number(n, ..)) if n >= 1.0 => n.to_int().to_string()
      _ => "8"
    }
  }
  @sf.page_card_node(b, footed=true, fn(k) {
    k.gap(Is(pf_card_gap)) |> ignore
    @sf.card_lines_node(
      k,
      fn() { @sf.t("web-pages.profiles.protectionTitle", args=[("cap", cap_text())]) },
      note=fn() { @sf.t("web-pages.profiles.protectionBody", args=[("cap", cap_text())]) },
    )
    @sf.card_foot_node(k, fn(f) {
      f.lies_along(Is(Between)).wraps(Is(Some(pf_foot_lines)), reverse=true) |> ignore
      @sf.button_node(
        f,
        fn() { @sf.t("web-pages.profiles.protectionTurnOff") },
        fn() {
          @settings.act(
            core,
            @sf.t("web-pages.profiles.protectionTurnOff"),
            "profile.put",
            obj([
              ("station", str(address)),
              ("id", str(id)),
              ("input", obj([("maxConcurrentSessions", Json::null()), ("newAccountProtection", Json::boolean(false))])),
            ]),
            done=@sf.t("web-pages.profiles.protectionTurnedOff"),
          )
        },
        tone=Primary,
        busy=fn() { is_doing(core, ["profile.put"], on) },
      )
      |> ignore
      @sf.button_node(
        f,
        fn() { @sf.t("web-pages.profiles.protectionAdjust") },
        fn() { ask_max_sessions(core, address, id, p) },
        tone=Ghost,
        card_words=true,
      )
      |> ignore
    })
  })
}

///|
/// Signing a subscription in without a terminal (SignIn), on a card in node `b`: still.fail runs the runtime's login on
/// its machine and this relays the browser's steps. Not under way: why (needed, or again), the way to start it, the
/// command to run by hand (shown as its button says). Under way: what the person does in the browser
/// (login_steps_node), there or in the station's own, 取消.
fn profile_sign_in_node(
  b : @view.View,
  core : Core,
  address : String,
  id : String,
  s : () -> Json?,
  p : () -> Json?,
  open : ProfileOpen,
) -> Unit {
  let on = [("station", address), ("id", id)]
  let params = fn() { obj([("station", str(address)), ("id", str(id))]) }
  let job = fn() { field(p(), "login") }
  let state = fn() { text(job(), "state") }
  let provider = fn() { text(p(), "signInProvider") }
  let needed = fn() { text(field(p(), "check"), "state") == "login" || signing_in(p()) }
  let command = fn() { text(p(), "loginCommand") }
  @sf.page_card_node(b, footed=true, fn(k) {
    k.pick(at_once=true, fn() { signing_in(p()) }, fn(q, active) {
      q.gap(Is(pf_card_gap)) |> ignore
      if !active {
        @sf.card_lines_node(
          q,
          fn() {
            if needed() {
              @sf.t("web-pages.profiles.notSignedIn", args=[("provider", provider())])
            } else {
              @sf.t("web-pages.profiles.subscriptionSignIn", args=[("provider", provider())])
            }
          },
          note=fn() {
            match state() {
              "failed" => ""
              "done" => @sf.t("web-pages.profiles.signedInSwitch")
              _ => @sf.t("web-pages.profiles.signInNote", args=[("name", @sf.product())])
            }
          },
          bad=fn() { if state() == "failed" { @sf.t("web-pages.profiles.lastFailed", args=[("error", text(job(), "error"))]) } else { "" } },
        )
        q.show(fn() { open.command.get() && command() != "" }, fn(b) {
          @sf.code_block_node(b, command, fn() { "" }, fn() { None }, command=true)
        })
        @sf.card_foot_node(q, fn(f) {
          // (登录 at the foot's start, the way on the machine at its end; where the two have not the room on one line,
          // words set large, 登录 keeps the foot's line and its corner (the line wrapped up, View::wraps' `reverse`) and
          // the way on the machine goes on the line over it, alone at its start, its words on the card's)
          f.lies_along(Is(Between)).wraps(Is(Some(pf_foot_lines)), reverse=true) |> ignore
          @sf.button_node(
            f,
            fn() { if state() == "done" || !needed() { @sf.t("web-pages.signIn.again") } else { @sf.t("web-pages.profiles.signIn") } },
            fn() { @settings.act(core, @sf.t("web-pages.profiles.signIn"), "profile.login", params()) },
            tone=Primary,
            icon="log-in",
            busy=fn() { is_doing(core, ["profile.login"], on) },
          )
          |> ignore
          f.show(at_once=true, fn() { command() != "" }, fn(x) {
            @sf.button_node(
              x,
              // (the short words, the phone's: beside 登录 on a card's foot they fit a phone, the long ones ran past its
              // edge)
              fn() { if open.command.get() { @sf.t("web-pages.profiles.collapse") } else { @sf.t("android-settings.login.manualShort") } },
              fn() { open.command.set(!open.command.untracked()) },
              tone=Ghost,
              card_words=true,
            )
            |> ignore
          })
        })
      } else {
        @sf.card_lines_node(q, fn() { @sf.t("web-pages.profiles.signingIn", args=[("provider", provider())]) }, note=fn() {
          @sf.t("web-pages.profiles.signingInNote")
        })
        login_steps_node(
          q,
          core,
          job,
          provider,
          fn() { is_doing(core, ["profile.loginCode"], on) },
          fn(code, sent, refused) {
            login_code_sent(core, "profile.loginCode", obj([("station", str(address)), ("id", str(id)), ("code", str(code))]), sent, refused)
          },
          open.copied,
          in_station=(fn() { text(s(), "name") }, fn() { is_doing(core, ["profile.loginBrowser"], on) }, fn(what) {
            @settings.act(core, what, "profile.loginBrowser", params(), then=fn(v) { (core.open_screen)(address, text(Some(v), "screen")) })
          }),
        )
        @sf.card_foot_node(q, fn(f) {
          @sf.button_node(
            f,
            fn() { @sf.t("common.cancel") },
            fn() { @settings.act(core, @sf.t("common.cancel"), "profile.cancelLogin", params()) },
            tone=Ghost,
            busy=fn() { is_doing(core, ["profile.cancelLogin"], on) },
            card_words=true,
          )
          |> ignore
        })
      }
    })
  })
}

///|
/// A code pasted back for a sign-in sent by the call `name`: gone through, `sent` (and what a lock's change waits for
/// said, as `@settings.act` says it); refused, felt so and `refused` given why, which the field shows under it (no
/// notice besides: it is where the code is mended).
fn login_code_sent(core : Core, name : String, params : Json, sent : () -> Unit, refused : (String) -> Unit) -> Unit {
  (core.call)(name, params, fn(r) {
    match r {
      Ok(v) => {
        match @settings.pending_said(v) {
          "" => ()
          waits => (core.say)(waits)
        }
        sent()
      }
      Err(e) => {
        @ui.haptic(Reject)
        refused(@settings.error_text(e))
      }
    }
  })
}

///|
/// What the person does in the browser for a sign-in under way (LoginSteps), in node `v`, as its `job` says it now: the
/// link and the code to paste back (Claude, Devin), the code to enter on the page that opens (DeviceCode: Codex, Grok,
/// OpenCode, Kimi, Cursor's page alone: copied as it is opened, `copied` saying so); while it is checked or added, said
/// so. `send`: a code pasted back sent, then `sent` (its field emptied), or `refused` with why (said under the field, the
/// code kept in it to be mended, till it is edited); `sending` while it is. Where its job says the
/// station has a browser of its own (`browser`), the same page there (`in_station`: the station's name, whether it is
/// being opened, and what opens it given what it is called) is a button beside the page's button; copying the link
/// stays in the ⋯ after them.
pub fn login_steps_node(
  v : @view.View,
  core : Core,
  job : () -> Json?,
  provider : () -> String,
  sending : () -> Bool,
  send : (String, () -> Unit, (String) -> Unit) -> Unit,
  copied : @signals.Signal[Bool],
  in_station? : (() -> String, () -> Bool, (String) -> Unit),
) -> Unit {
  let state = fn() { text(job(), "state") }
  let url = fn() { text(job(), "url") }
  // (1 a code to paste back, 2 a device's code, 6 a Google Cloud project to give (a company's Google account with no
  // licence), else a wait: 3 checked, 4 added, 5 its link made)
  let step = fn() {
    match state() {
      "needs_code" if url() != "" => 1
      "needs_approval" if url() != "" => 2
      "needs_project" => 6
      "verifying" => 3
      "done" => 4
      _ => 5
    }
  }
  // beside the page's button where the station has a browser of its own (回到 … while its tab is open); in the ⋯ after
  // them, its address copied (for a browser elsewhere)
  let station_browser = fn(r : @view.View) {
    match in_station {
      Some((name, busy, go)) =>
        r.show(at_once=true, fn() { flag(job(), "browser") }, fn(x) {
          @sf.button_node(
            x,
            fn() {
              @sf.t(
                if text(job(), "screen") != "" { "common.login.backToStation" } else { "common.login.openInStation" },
                args=[("station", name())],
              )
            },
            fn() {
              let j = @signals.untracked(job)
              let label = @sf.t(
                if text(j, "screen") != "" { "common.login.backToStation" } else { "common.login.openInStation" },
                args=[("station", @signals.untracked(name))],
              )
              let claude = @signals.untracked(provider) == "Claude" && text(j, "screen") == ""
              @settings.confirm_claude_auth(claude, fn() { go(label) })
            },
            tone=Plain,
            busy~,
          )
          |> ignore
        })
      None => ()
    }
  }
  let page_more = fn(r : @view.View) {
    // (beside the box that holds it, as it is pressed)
    r.box(fn(k) {
      @sf.icon_button_node(k, "more", fn() { @sf.t("common.login.otherWays") }, fn() {
        let j = @signals.untracked(job)
        let link = text(j, "url")
        let items = [Some(@sf.menu_item_of(@sf.t("common.link.copy"), fn() { @sfbase.copy_out(link, said=@sf.t("common.link.copied")) }))]
        @sf.menu(items, from=Node(k))
      })
      |> ignore
    })
    |> ignore
  }
  let waiting = fn(q : @view.View, words : () -> String) {
    q.box(fn(l) {
      @sf.style_node(l, fn() { pf_wait_line })
      @sf.spinner_node(l, size=pf_spin) |> ignore
      @sf.words_node(l, words, fn() { pf_muted }) |> ignore
    })
    |> ignore
  }
  // what is typed in and sent by its button (or Enter) under the step's words: a code pasted back, a project's id
  let typed_step = fn(q : @view.View, words : () -> String, placeholder : String) {
    q.box(fn(st) {
      @sf.style_node(st, fn() { pf_step })
      @sf.words_node(st, words, fn() { pf_words }) |> ignore
      let f = @ui.Field::new()
      let typed = fn() { f.text().trim(chars=" \t\n").to_owned() }
      // why what was sent was refused, under the field till what is in it is edited
      let bad : @signals.Signal[String] = @signals.signal("")
      st.reacts(fn() { f.text() }, fn(_) { if bad.untracked() != "" { bad.set("") } })
      let go = fn() {
        let code = @signals.untracked(typed)
        if code != "" && !@signals.untracked(sending) {
          bad.set("")
          send(code, fn() { f.set("") }, fn(why) { bad.set(why) })
        }
      }
      st.box(fn(r) {
        @sf.style_node(r, fn() { pf_input_row })
        // (as wide as the step, its steps standing at their start: the field what the button leaves)
        r.width_share(Is(1.0)) |> ignore
        r.box(fn(g) {
          @sf.style_node(g, fn() { pf_input_grow }, in_row=true)
          g.min_width(Is(Some(0.0))) |> ignore
          @sf.input_node(g, f, placeholder~, submitted=fn(_) { go() }) |> ignore
        })
        |> ignore
        @sf.button_node(r, fn() { @sf.t("web-pages.profiles.finish") }, go, tone=Primary, busy=sending, disabled=fn() { typed().is_empty() })
        |> ignore
      })
      |> ignore
      st.show(fn() { bad.get() != "" }, fn(x) { @sf.words_node(x, fn() { bad.get() }, fn() { ap_note_bad }) |> ignore })
    })
    |> ignore
  }
  v.pick(at_once=true, step, fn(q, k) {
    q.gap(Is(pf_card_gap)) |> ignore
    match k {
      1 => {
        q.box(fn(st) {
          @sf.style_node(st, fn() { pf_step })
          @sf.words_node(st, fn() {
            if provider() == "Devin" {
              @sf.t("web-pages.profiles.step1Devin", args=[("name", @sf.product())])
            } else if provider() == "Google Colab" {
              @sf.t("web-pages.profiles.step1Colab", args=[("name", @sf.product())])
            } else if provider() == "Google" {
              @sf.t("web-pages.profiles.step1Google", args=[("name", @sf.product())])
            } else {
              @sf.t("web-pages.profiles.step1", args=[("name", @sf.product())])
            }
          }, fn() { pf_words })
          |> ignore
          st.box(fn(r) {
            @sf.style_node(r, fn() { pf_step_buttons })
            r.width_share(Is(1.0)).wraps(Is(Some(pf_step_buttons_gap))) |> ignore
            @sf.button_node(r, fn() { @sf.t("web-pages.profiles.openAuth") }, fn() {
              let link = @signals.untracked(url)
              @settings.confirm_claude_auth(@signals.untracked(provider) == "Claude", fn() { (core.open_link)(link) })
            }, tone=Primary, icon="external")
            |> ignore
            station_browser(r)
            page_more(r)
          })
          |> ignore
        })
        |> ignore
        typed_step(
          q,
          fn() {
            if provider() == "Devin" {
              @sf.t("web-pages.profiles.step2Devin")
            } else {
              @sf.t("web-pages.profiles.step2")
            }
          },
          @sf.t("web-pages.profiles.pasteCode"),
        )
      }
      6 => typed_step(q, fn() { @sf.t("web-pages.profiles.projectStep") }, @sf.t("web-pages.profiles.projectPlaceholder"))
      2 => {
        // no code where the page only asks to confirm (Cursor's); OpenCode's and Kimi's carry it in their address
        let code = fn() { text(job(), "userCode") }
        let filled = fn() { provider() == "OpenCode" || provider() == "Kimi" || code() == "" }
        q.box(fn(d) {
          @sf.style_node(d, fn() { pf_device })
          d.show(at_once=true, fn() { code() != "" }, fn(c) {
            @sf.style_node(c, fn() { pf_device_code })
            c.box(fn(w) {
              w
              .words_runs(By(fn() { [@ui.span(code(), mono=true)] }), look=@ui.style_words(pf_device_code_words))
              .ink(By(fn() { @ui.style_ink(pf_device_code_words) }))
              |> ignore
            })
            |> ignore
          })
          d.box(fn(r) {
            @sf.style_node(r, fn() { pf_step_buttons })
            r.width_share(Is(1.0)).wraps(Is(Some(pf_step_buttons_gap))) |> ignore
            @sf.button_node(
              r,
              fn() {
                if filled() {
                  @sf.t("web-pages.profiles.openAuth")
                } else if copied.get() {
                  @sf.t("web-pages.profiles.copiedReopen")
                } else {
                  @sf.t("web-pages.profiles.copyOpen")
                }
              },
              fn() {
                let link = @signals.untracked(url)
                let words = @signals.untracked(code)
                let filled = @signals.untracked(filled)
                @settings.confirm_claude_auth(@signals.untracked(provider) == "Claude", fn() {
                  if !filled {
                    @ui.clipboard_set(words)
                    copied.set(true)
                  }
                  (core.open_link)(link)
                })
              },
              tone=Primary,
              icon="external",
            )
            |> ignore
            station_browser(r)
            page_more(r)
          })
          |> ignore
          @sf.words_node(d, fn() {
            if code() == "" {
              @sf.t("web-pages.profiles.deviceCodeNoteCursor")
            } else {
              match provider() {
                "OpenCode" => @sf.t("web-pages.profiles.deviceCodeNoteOpencode")
                "Kimi" => @sf.t("web-pages.profiles.deviceCodeNoteKimi")
                "Grok" => @sf.t("web-pages.profiles.deviceCodeNoteGrok")
                _ => @sf.t("web-pages.profiles.deviceCodeNote", args=[("name", @sf.product())])
              }
            }
          }, fn() { pf_muted })
          |> ignore
        })
        |> ignore
      }
      3 => waiting(q, fn() { @sf.t("web-pages.profiles.finishing") })
      4 => waiting(q, fn() { @sf.t("web-pages.profiles.adding") })
      _ => waiting(q, fn() { @sf.t("web-pages.profiles.generatingLink", args=[("provider", provider())]) })
    }
  })
}

///|
/// What is wrong with it and its next step (ProfileRecovery), on a card in node `b` where it is in trouble (not signing
/// in: that is its sign-in's): why, what to do, a command to run where that is it, the button that does it (a key asked
/// for, its variables opened to be written, its allowance read again, checked again).
fn profile_trouble_node(
  b : @view.View,
  core : Core,
  address : String,
  id : String,
  s : () -> Json?,
  p : () -> Json?,
  open : ProfileOpen,
) -> Unit {
  let on = [("station", address), ("id", id)]
  let issue = fn() { field(p(), "trouble") }
  let action = fn() { text(issue(), "action") }
  let online = fn() { flag(s(), "online") }
  let link = fn() { trouble_link(text(issue(), "detail")) }
  let next = fn() {
    join([text(issue(), "next"), if online() { "" } else { @sf.t("android-settings.profile.offline", args=[("name", text(s(), "name"))]) }], "\n")
  }
  let bad = fn() { failed_of(core, ["profile.check", "profile.quota"], on).unwrap_or("") }
  let checking = fn() { is_doing(core, ["profile.check"], on) }
  let refreshing = fn() { is_doing(core, ["profile.quota"], on) }
  let check = fn() {
    @settings.act(core, @sf.t("android-settings.profile.checkWhat"), "profile.check", obj([("station", str(address)), ("id", str(id))]), done=@sf.t("android-settings.profile.checked"))
  }
  @sf.page_card_node(b, footed=true, fn(k) {
    @sf.card_lines_node(
      k,
      fn() { text(issue(), "title") },
      words=fn() { trouble_words(text(issue(), "detail")) },
      note=fn() { if link() == "" { next() } else { "" } },
      bad=fn() { if link() == "" { bad() } else { "" } },
    )
    k.show(at_once=true, fn() { action() == "command" }, fn(b) {
      @sf.code_block_node(b, fn() { text(p(), "loginCommand") }, fn() { "" }, fn() { None }, command=true)
    })
    // (the link its words give to open, on its one line with its copy key: the page's words cannot be selected)
    k.show(at_once=true, fn() { link() != "" }, fn(x) {
      @sf.code_block_node(x, link, fn() { "" }, fn() { None }, command=true)
    })
    // (what to do, under the link its words lead to)
    k.show(at_once=true, fn() { link() != "" }, fn(x) { @sf.card_lines_node(x, fn() { "" }, note=next, bad~) })
    @sf.card_foot_node(k, fn(f) {
      @sf.button_node(
        f,
        fn() { text(issue(), "label") },
        fn() {
          match @signals.untracked(action) {
            "key" => ask_key(core, address, @signals.untracked(p))
            "env" => open.env.set(true)
            "quota" =>
              @settings.act(core, @sf.t("android-settings.quota.checkWhat"), "profile.quota", obj([("station", str(address)), ("id", str(id))]), done=@sf.t("android-settings.quota.updated"))
            _ => check()
          }
        },
        tone=Primary,
        busy=fn() { checking() || refreshing() },
        disabled=fn() { !online() },
        card_words=true,
      )
      |> ignore
      f.show(at_once=true, fn() { link() != "" }, fn(x) {
        @sf.button_node(x, fn() { @sf.t("android-settings.profile.openLink") }, fn() { (core.open_link)(@signals.untracked(link)) }, tone=Ghost, icon="external")
        |> ignore
      })
      f.show(at_once=true, fn() { action() == "key" || action() == "env" }, fn(x) {
        @sf.button_node(x, fn() { @sf.t("android-settings.profile.recheck") }, check, tone=Ghost, busy=checking, disabled=fn() { !online() })
        |> ignore
      })
    })
  })
}

///|
/// The link a trouble's words give the person to open, up to the space or line after it (Google's where an Antigravity
/// CLI account is to be verified first: `… Please verify your account in your browser to continue:\nhttps://…`), else
/// "".
fn trouble_link(detail : String) -> String {
  match detail.find("https://") {
    None => ""
    Some(i) => {
      let rest = detail.unsafe_substring(start=i, end=detail.length())
      let ends = [rest.find(" "), rest.find("\n"), rest.find("\t")].filter_map(fn(e) { e })
      let end = ends.fold(init=rest.length(), fn(a, e) { if e < a { e } else { a } })
      rest.unsafe_substring(start=0, end~)
    }
  }
}

///|
/// A trouble's words without the link they give (trouble_link): it is on a line of its own under them, to copy.
fn trouble_words(detail : String) -> String {
  let link = trouble_link(detail)
  match detail.find(link) {
    Some(i) if link != "" =>
      (detail.unsafe_substring(start=0, end=i) + detail.unsafe_substring(start=i + link.length(), end=detail.length()))
      .trim(chars=" \n\r\t")
      .to_owned()
    _ => detail
  }
}

// ── its allowance and who uses it ───────────────────────────────────────

///|
/// What is left of its allowance and who uses it (QuotaSection + UsedBySection) in node `b`: each window as a dial,
/// its credits and its resets (resetting one asked first), and the connects bound to it, in one card.
fn profile_quota_node(
  b : @view.View,
  core : Core,
  address : String,
  id : String,
  o : () -> Json?,
  p : () -> Json?,
  tips : @sf.TipLayer?,
  read_under? : Bool = false,
) -> Unit {
  let on = [("station", address), ("id", id)]
  let params = fn() { obj([("station", str(address)), ("id", str(id))]) }
  // (each worked out once for each change of the account, what reads it woken only where it comes out otherwise)
  let quota_now = @signals.computed(fn(_) { field(p(), "quota") }, same=json_opt_same)
  let quota = fn() { quota_now.get() }
  let windows_now = @signals.computed(fn(_) { items(quota(), "windows") }, same=jsons_same)
  let windows = fn() { windows_now.get() }
  let credits_now = @signals.computed(fn(_) { text(quota(), "creditsText") }, same=fn(a, b) { a == b })
  let credits = fn() { credits_now.get() }
  let credits_note_now = @signals.computed(
    fn(_) { if windows().length() == 0 { opt_text(quota(), "detail").unwrap_or("") } else { "" } },
    same=fn(a, b) { a == b },
  )
  let credits_note = fn() { credits_note_now.get() }
  let refreshing = fn() {
    is_doing(core, ["profile.quota"], on) ||
    (is_doing(core, ["profile.check"], on) && text(quota(), "state") != "unsupported")
  }
  let what = fn() -> Int {
    if !shows_quota(p()) {
      -1
    } else {
      match quota() {
        None | Some(Null) => 0
        Some(q) => {
          let st = text(Some(q), "state")
          if st == "ok" && windows().length() > 0 {
            2
          } else if st == "ok" && (credits() != "" || items(Some(q), "resets").length() > 0) {
            3
          } else {
            1
          }
        }
      }
    }
  }
  @sf.section_node(
    b,
    fn() {
      if shows_quota(p()) {
        @sf.t("web-pages.profiles.quota")
      } else {
        @sf.t("web-pages.profiles.usedBy")
      }
    },
    fn(sec) {
      @sf.group_node(sec, fn(g) {
        // (a show round it, not a pick of nothing: a structure's box that made nothing still takes a list's gap, the
        // card's first row 2 lower than its padding where no allowance is shown)
        g.show(at_once=true, fn() { what() >= 0 }, fn(s) {
          s.pick(at_once=true, what, fn(x, w) {
            if w == 0 {
              @sf.link_row_node(
                x,
                fn() {
                  if refreshing() {
                    @sf.t("android-settings.quota.checking")
                  } else {
                    @sf.t("web-main.quota.unchecked")
                  }
                },
                fn() {  },
                chevron=false,
                goes=false,
                tail=fn(rt) {
                  doing_mark_node(rt, refreshing, fn() { failed_of(core, ["profile.quota", "profile.check"], on) }, tips?)
                },
                tail_shown=fn() { refreshing() || failed_of(core, ["profile.quota", "profile.check"], on) is Some(_) },
              )
            } else if w == 1 {
              @sf.link_row_node(
                x,
                fn() {
                  if refreshing() && opt_text(quota(), "detail").unwrap_or("") == "" {
                    @sf.t("android-settings.quota.checking")
                  } else {
                    let q = quota()
                    let st = text(q, "state")
                    if st == "blocked" {
                      @sf.t("web-main.profile.blocked")
                    } else if st == "unavailable" {
                      @sf.t("android-settings.quota.unavailable")
                    } else if st == "unsupported" || opt_text(q, "detail").unwrap_or("") != "" {
                      @sf.t("android-settings.quota.none")
                    } else {
                      @sf.t("web-main.quota.unknown")
                    }
                  }
                },
                fn() {  },
                note=fn() {
                  let q = quota()
                  let st = text(q, "state")
                  // (without the link it gives: the trouble's card over it has it, to copy and open)
                  let detail = trouble_words(opt_text(q, "detail").unwrap_or(""))
                  join(
                    [
                      detail,
                      if refreshing() && detail != "" {
                        @sf.t("android-settings.quota.checking")
                      } else if !refreshing() && st != "unsupported" {
                        text(field(q, "checkedAt"), "ago")
                      } else {
                        ""
                      },
                    ],
                    " · ",
                  )
                },
                chevron=false,
                goes=false,
                tail=fn(rt) {
                  doing_mark_node(rt, refreshing, fn() { failed_of(core, ["profile.quota", "profile.check"], on) }, tips?)
                },
                tail_shown=fn() { refreshing() || failed_of(core, ["profile.quota", "profile.check"], on) is Some(_) },
              )
            } else if w == 2 {
              @sf.block_node(x, fn(bl) {
                @sf.dials_node(bl, fn() { quota_dials_of(windows()) }, lines=2)
                // (`read_under`: when it was read, 12 under its dials, being read said so; quota_section's, where no head
                // says it, as on an account on several stations' page)
                if read_under {
                  let read = fn() { @settings.stamp(quota(), "checkedAt", "ago") }
                  bl.show(fn() { refreshing() || read() != "" }, fn(r) {
                    @sf.style_node(r, fn() { pq_read_room })
                    @sf.words_node(r, fn() {
                      if refreshing() {
                        @sf.t("android-settings.quota.checking")
                      } else {
                        @sf.t("android-settings.quota.checkedAt", args=[("ago", read())])
                      }
                    }, fn() { pq_read_words })
                    |> ignore
                  })
                }
              })
            }
          })
        })
        g.show(at_once=true, fn() { credits() != "" }, fn(x) {
          @sf.link_row_node(
            x,
            fn() { @sf.t("android-settings.quota.credits") },
            fn() {  },
            note=credits_note,
            value=credits,
            goes=false,
          )
        })
        // Each kind of reset it holds, a row each: how many are left at its end, where they are seen at once (the user,
        // 2026-11-10), what one gives back and till when under its name; the row pressed asks first, then uses one.
        g.each(fn() { items(quota(), "resets") }, fn(r) { text(Some(r), "kind") }, fn(x, rs) {
          // (this reset alone: another's change wakes nothing of it)
          let rv_now = @signals.computed(fn(_) { Some(rs.get()) }, same=json_opt_same)
          let rv = fn() { rv_now.get() }
          let busy = fn() { is_doing(core, ["profile.resetQuota"], on) }
          let usable = fn() { count(rv(), "left") > 0 && flag(rv(), "usable") }
          // (lit only when one can be used now: one usable only at a limit says why under it, unpressed)
          x.pick(at_once=true, fn() { (usable(), usable() && !busy()) }, fn(r, k) {
            let (lit, goes) = k
            @sf.link_row_node(
              r,
              fn() { text(rv(), "title") },
              fn() {
                let one = @signals.untracked(rv)
                let name = text(@signals.untracked(p), "name")
                let body = match opt_text(one, "refills") {
                  Some(refills) =>
                    @sf.t("web-pages.profiles.resetKindBody", args=[("name", name), ("kind", text(one, "title")), ("refills", refills)])
                  None => @sf.t("web-pages.profiles.resetBody", args=[("name", name), ("n", count(one, "left").to_string())])
                }
                let asked = match opt_text(one, "id") {
                  Some(kind) => obj([("station", str(address)), ("id", str(id)), ("reset", str(kind))])
                  None => params()
                }
                confirm(
                  @sf.t("web-pages.profiles.resetConfirm"),
                  body,
                  @sf.t("web-pages.profiles.resetAction"),
                  fn() {
                    @settings.act(core, @sf.t("web-pages.profiles.resetAction"), "profile.resetQuota", asked, done=@sf.t("web-pages.profiles.quotaReset"))
                  },
                )
              },
              note=fn() { reset_note(rv()) },
              value=fn() { text(rv(), "leftText") },
              value_lit=lit,
              chevron=false,
              goes~,
              tail=fn(t) { doing_mark_node(t, busy, fn() { failed_of(core, ["profile.resetQuota"], on) }, tips?) },
              tail_shown=fn() { busy() || failed_of(core, ["profile.resetQuota"], on) is Some(_) },
            )
          })
        })
        g.each(fn() { profile_users(o(), p()) }, fn(cn) { text(Some(cn), "id") }, fn(r, cn) {
          let cv = fn() { Some(cn.get()) }
          let model = fn() {
            match opt_text(cv(), "modelName") {
              Some(m) => m
              None =>
                match opt_text(p(), "model") {
                  Some(m) => match text(field(p(), "names"), m) { "" => m; n => n }
                  None => @sf.t("web-pages.profiles.defaultModel")
                }
            }
          }
          let cid = @signals.untracked(fn() { text(cv(), "id") })
          @sf.link_row_node(
            r,
            fn() { text(cv(), "name") },
            fn() { (core.push)(Connect(address, cid)) },
            value=model,
            title_cut=true,
            value_cut=true,
            lead=LeadMade(fn(l) { @sf.avatar_node(l, fn() { text(cv(), "id") }, fn() { text(cv(), "name") }, fn() { "" }, pf_user_avatar) }),
          )
        })
      })
    },
  )
}

///|
/// Under a kind of reset's name: what one gives back, and when they end or why none can be used now.
fn reset_note(r : Json?) -> String {
  [opt_text(r, "refills").unwrap_or(""), text(r, "text")].filter(fn(w) { w != "" }).join(" · ")
}

// ── where it is and whom it is shared with ──────────────────────────────

///|
/// The station rows for an account (`所在 station`, `分享给其他 station`, `可用的 station`; or for a borrowed copy,
/// whether this station uses it and where its host is), placed in group `g`.
fn profile_station_rows_node(
  g : @view.View,
  core : Core,
  address : String,
  id : String,
  s : () -> Json?,
  o : () -> Json?,
  p : () -> Json?,
  entry : () -> Json?,
) -> Unit {
  let on = [("station", address), ("id", id)]
  let share = fn() { field(p(), "share") }
  let stations = fn() { items(entry(), "stations") }
  let name_of = fn(sid : String) -> String {
    let all = stations()
    match all.search_by(fn(x) { text(Some(x), "id") == sid }) {
      Some(i) => text(Some(all[i]), "name")
      None => sid.clamped_view(end=@cmp.minimum(8, sid.length())).to_owned()
    }
  }
  let subscription = fn() { text(field(p(), "access"), "kind") == "subscription" }
  let user = fn() { text(share(), "role") == "user" }
  let shared = fn() { share() is Some(Object(_)) }
  let sharing = fn() { is_doing(core, ["profile.share"], on) }
  // (its station lets who may use it follow the workspace's whitelist: Overview `shareAllowAuto`; and it does)
  let auto_ok = fn() { flag(o(), "shareAllowAuto") }
  let follows = fn() { flag(share(), "allowAuto") }
  let moving = fn() { is_doing(core, ["profile.move"], on) }
  let busy_put = fn() { is_doing(core, ["profile.put"], on) }
  let sid = fn() { text(s(), "id") }
  let allowed = fn() -> Array[String]? {
    match field(share(), "allow") {
      Some(Array(a)) => Some(a.filter_map(fn(x) { if x is String(v) { Some(v) } else { None } }))
      _ => None
    }
  }
  let has_sharing = fn() { has(o(), "sharing") && !(field(o(), "sharing") is Some(Null)) }
  let lender = fn() -> Json? {
    let host = text(share(), "host")
    let members = items(entry(), "members")
    match members.search_by(fn(m) { text(Some(m), "stationId") == host && text(Some(m), "role") == "host" }) {
      Some(i) => Some(members[i])
      None => None
    }
  }
  let copy_note = fn() -> String {
    let host = name_of(text(share(), "host"))
    if subscription() && field(share(), "reachable") is Some(False) {
      @sf.t("web-pages.profiles.share.hostAway", args=[("station", host)])
    } else {
      @sf.t("web-pages.profiles.share.copy", args=[("station", host)])
    }
  }
  g.show(at_once=true, fn() { has_sharing() && user() && (!profile_pausable(p()) || lender() is Some(_)) }, fn(x) {
    x.pick(at_once=true, fn() { lender() is Some(_) }, fn(r, goes) {
      @sf.link_row_node(
        r,
        fn() { @sf.t("web-pages.profiles.share.copy", args=[("station", name_of(text(share(), "host")))]) },
        fn() {
          match @signals.untracked(lender) {
            Some(m) => (core.push)(Profile(text(Some(m), "station"), text(Some(m), "profileId")))
            None => ()
          }
        },
        note=fn() {
          let host = name_of(text(share(), "host"))
          if subscription() && field(share(), "reachable") is Some(False) {
            @sf.t("web-pages.profiles.share.hostAway", args=[("station", host)])
          } else {
            ""
          }
        },
        value=fn() {
          if goes {
            @sf.t("web-pages.profiles.share.goHost", args=[("station", name_of(text(share(), "host")))])
          } else {
            ""
          }
        },
        goes~,
      )
    })
  })
  g.show(at_once=true, fn() { has_sharing() && profile_pausable(p()) }, fn(x) {
    @sf.switch_row_node(
      x,
      fn() { @sf.t("web-pages.profiles.share.here") },
      fn() { flag(p(), "enabled") },
      fn(next) {
        let label = if next { @sf.t("web-pages.connect.enable") } else { @sf.t("web-pages.profiles.disable") }
        let change = fn() {
          @settings.act(
            core,
            label,
            "profile.put",
            obj([("station", str(address)), ("id", str(id)), ("input", obj([("enabled", Json::boolean(next))]))]),
            done=if next { @sf.t("web-pages.connect.enabled") } else { @sf.t("web-pages.profiles.disabled") },
          )
        }
        if !next {
          confirm(
            @sf.t("web-pages.profiles.disableConfirm", args=[("name", text(@signals.untracked(p), "name"))]),
            @sf.t("web-pages.profiles.disableCopyBody"),
            label,
            danger=true,
            change,
          )
        } else {
          change()
        }
      },
      note=fn() {
        if user() && lender() is None {
          copy_note()
        } else if user() {
          @sf.t("web-pages.profiles.share.hereNote")
        } else {
          ""
        }
      },
      busy=busy_put,
    )
  })
  let targets = fn() { stations().filter(fn(x) { text(Some(x), "id") != sid() }) }
  let movable = fn() {
    has_sharing() && !user() && !flag(p(), "machine") && ((shared() && subscription()) || targets().iter().any(fn(x) { flag(Some(x), "online") }))
  }
  g.show(at_once=true, movable, fn(x) {
    x.pick(at_once=true, fn() { !moving() && targets().length() > 0 }, fn(r, goes) {
      @sf.link_row_node(
        r,
        fn() { @sf.t("web-pages.profiles.share.where") },
        fn() { move_dialog(core, @signals.untracked(s), @signals.untracked(p), @signals.untracked(targets)) },
        note=fn() { if goes { @sf.t("web-pages.profiles.share.whereNote") } else { "" } },
        value=fn() { text(s(), "name") },
        value_cut=true,
        goes~,
        tail=fn(t) { doing_mark_node(t, moving, fn() { failed_of(core, ["profile.move"], on) }) },
        tail_shown=fn() { moving() || failed_of(core, ["profile.move"], on) is Some(_) },
      )
    })
  })
  // A kind of login that cannot be lent yet (the station's `shareable`, absent on one from before) says so in place of
  // the switch, which its station would refuse (the user, 2026-11-15: 「不支持共享的应该有直接提示，而不是依然是一个看起
  // 来能开的开关」); one shared already keeps its switch, to stop sharing it.
  let shareable = fn() { shared() || !(field(p(), "shareable") is Some(False)) }
  g.show(at_once=true, fn() { has_sharing() && !user() && !shareable() }, fn(x) {
    @sf.link_row_node(
      x,
      fn() { @sf.t("web-pages.profiles.share.switch") },
      fn() {  },
      value=fn() { @sf.t("web-pages.profiles.share.unsupported") },
      note=fn() { @sf.t("web-pages.profiles.share.unsupportedNote") },
      goes=false,
    )
  })
  g.show(at_once=true, fn() { has_sharing() && !user() && shareable() }, fn(x) {
    @sf.switch_row_node(
      x,
      fn() { @sf.t("web-pages.profiles.share.switch") },
      shared,
      fn(now) {
        if now {
          let sub = @signals.untracked(subscription)
          let claude = sub && text(@signals.untracked(p), "runtime") == "claude"
          pick_stations(
            core,
            address,
            id,
            @signals.untracked(stations),
            @signals.untracked(sid),
            None,
            initial=true,
            subscription=sub,
            claude~,
            auto_ok=@signals.untracked(auto_ok),
          )
        } else {
          @settings.act(
            core,
            @sf.t("web-pages.profiles.share.switch"),
            "profile.share",
            obj([("station", str(address)), ("id", str(id)), ("on", Json::boolean(false))]),
            done=@sf.t("web-pages.profiles.share.unshared"),
          )
        }
      },
      note=fn() { @sf.t("web-pages.profiles.share.switchNote") },
      busy=sharing,
    )
  })
  g.show(at_once=true, fn() { has_sharing() && !user() && shared() }, fn(x) {
    x.pick(at_once=true, fn() { !sharing() }, fn(r, goes) {
      @sf.link_row_node(
        r,
        fn() { @sf.t("web-pages.profiles.share.stations") },
        fn() {
          pick_stations(
            core,
            address,
            id,
            @signals.untracked(stations),
            @signals.untracked(sid),
            @signals.untracked(allowed),
            follow=@signals.untracked(follows),
            auto_ok=@signals.untracked(auto_ok),
          )
        },
        note=fn() { @sf.t("web-pages.profiles.share.stationsNote") },
        value=fn() {
          if follows() {
            return @sf.t("web-pages.profiles.share.followAuto")
          }
          match allowed() {
            None => @sf.t("web-pages.profiles.share.everyStation")
            Some(a) =>
              stations()
              .filter(fn(x) { a.contains(text(Some(x), "id")) || text(Some(x), "id") == sid() })
              .map(fn(x) { text(Some(x), "name") })
              .join(@sf.t("web-main.list.separator"))
          }
        },
        value_cut=true,
        goes~,
      )
    })
  })
}

///|
/// The Station section in node `b`, when shown as its own section (or for a borrowed copy).
fn profile_station_node(
  b : @view.View,
  core : Core,
  address : String,
  id : String,
  s : () -> Json?,
  o : () -> Json?,
  p : () -> Json?,
  entry : () -> Json?,
) -> Unit {
  let has_sharing = fn() { has(o(), "sharing") && !(field(o(), "sharing") is Some(Null)) }
  b.show(at_once=true, has_sharing, fn(s_view) {
    @sf.section_node(s_view, fn() { @sf.t("android-misc.bar.place.stations") }, fn(sec) {
      @sf.group_node(sec, fn(g) {
        profile_station_rows_node(g, core, address, id, s, o, p, entry)
      })
    })
  })
}

///|
/// The station an account is on, moved to another (`profile.move`): the others, a row each, picked in a panel (one
/// away, said so and not picked). A shared one leaves this station a borrowed copy; one not shared is on the other
/// alone after, its page here gone: back to the list at once, as a deleted one's is, its answer said there.
fn move_dialog(core : Core, s : Json?, p : Json?, targets : Array[Json]) -> Unit {
  let address = text(s, "station")
  let id = text(p, "id")
  let shared = field(p, "share") is Some(Object(_))
  open_dialog_bare_nodes(
    @sf.t("web-pages.profiles.share.moveTo"),
    description=@sf.t(if shared { "web-pages.profiles.share.moveShared" } else { "web-pages.profiles.share.moveOwn" }, args=[("station", text(s, "name"))]),
    fn(v, shut) {
      v.box(fn(block) {
        @sf.style_node(block, fn() { @sf.panel_card_last_node(block) })
        @sf.group_node(block, fn(g) {
          g.each(fn() { targets.mapi(fn(i, x) { (i, x) }) }, fn(x) { x.0 }, fn(row, x) {
            let xv = Some(x.untracked().1)
            let online = flag(xv, "online")
            @sf.link_row_node(
              row,
              fn() { text(xv, "name") },
              fn() {
                shut()
                if !shared {
                  (core.pop)()
                }
                @settings.act(
                  core,
                  @sf.t("web-pages.profiles.share.move"),
                  "profile.move",
                  obj([("station", str(address)), ("id", str(id)), ("to", str(text(xv, "id")))]),
                  done=@sf.t("web-pages.profiles.share.moved", args=[("station", text(xv, "name"))]),
                )
              },
              value=fn() { if online { "" } else { @sf.t("web-pages.stations.offline") } },
              chevron=false,
              goes=online,
              lead=LeadLine(fn(l) { @sf.state_dot_node(l, fn() { if online { "online" } else { "offline" } }) }),
            )
          })
        })
      })
      |> ignore
    },
  )
}

// ── settings (models, how it runs, key, variables) ──────────────────────

///|
/// Its settings in node `b`: its models, its key or machine login, how it runs (fast mode, background on message), the
/// other workspaces the station serves, and its environment variables, in one Settings card.
fn profile_settings_node(
  b : @view.View,
  core : Core,
  here : () -> Here,
  address : String,
  id : String,
  s : () -> Json?,
  o : () -> Json?,
  p : () -> Json?,
  entry : () -> Json?,
  open : ProfileOpen,
  stint : () -> Int,
  tips : @sf.TipLayer?,
) -> Unit {
  let on = [("station", address), ("id", id)]
  let access = fn() { field(p(), "access") }
  let kind = fn() { text(access(), "kind") }
  let machine = fn() { flag(p(), "machine") }
  let keyed = fn() { ["opencode-go", "anthropic-api", "api-provider"].contains(kind()) && !flag(access(), "login") }
  let busy = fn() { is_doing(core, ["profile.put"], on) }
  let joined = fn() {
    if profile_copy(p()) {
      []
    } else {
      let m = (core.topic)("memberships", { "station": str(address) }).get().value
      if flag(m, "manages") {
        items(m, "workspaces").filter(fn(w) { !flag(Some(w), "home") })
      } else {
        []
      }
    }
  }
  let put = fn(what : String, key : String, value : Bool, done : String) {
    @settings.act(core, what, "profile.put", obj([("station", str(address)), ("id", str(id)), ("input", obj([(key, Json::boolean(value))]))]), done~)
  }
  b.pick(at_once=true, fn() { flag(p(), "decisionOnly") }, fn(x, only) {
    if only {
      @sf.section_node(x, fn() { @sf.t("web-pages.profiles.decisionModels") }, fn(sec) {
        @sf.loose_node(sec, fn(l) {
          l.show(at_once=true, fn() { strings(p(), "decisionModels").length() > 0 }, fn(chips) {
            @sf.style_node(chips, fn() { pf_chips })
            chips.wraps(Is(Some(0.0))) |> ignore
            chips.each(fn() { strings(p(), "decisionModels") }, fn(m) { m }, fn(chip, m) {
              @sf.style_node(chip, fn() { pf_chip })
              @sf.words_node(chip, fn() { m.get() }, fn() { pf_chip_words }) |> ignore
            })
          })
          l.show(at_once=true, fn() { text(p(), "decisionText") != "" }, fn(w) { @sf.words_node(w, fn() { text(p(), "decisionText") }, fn() { pf_muted }) |> ignore })
        })
      })
    } else {
      let all = fn() { strings(p(), "available") }
      @sf.section_node(
        x,
        fn() { @sf.t("android-misc.settings") },
        fn(sec) {
          @sf.group_node(sec, fn(g) {
            profile_station_rows_node(g, core, address, id, s, o, p, entry)
            g.show(at_once=true, fn() { items(p(), "runtimes").length() > 0 || flag(p(), "canAddModel") }, fn(models_row) {
              @sf.link_row_node(
                models_row,
                fn() { @sf.t("web-pages.profiles.availableModels") },
                fn() {
                  let fusion : @signals.Signal[Json?] = @signals.signal(None)
                  let fusion_lead : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })
                  let p0 = @signals.untracked(p)
                  if text(p0, "runtime") == "devin" && text(field(p0, "share"), "role") != "user" {
                    (core.call)(
                      "profile.fusion",
                      obj([("station", str(address)), ("id", str(id))]),
                      fn(r) {
                        if r is Ok(v) && field(Some(v), "fusion") is (Some(Object(_)) as f) {
                          fusion.set(f)
                        }
                      },
                    )
                  }
                  @sf.panel_nodes(
                    @sf.t("web-pages.profiles.availableModels"),
                    fn(v, _) {
                      // (the profile as the station's overview lists it now, else as its page has it now)
                      let now = fn() {
                        let listed = items(field(@settings.station_of(core, here(), address), "overview"), "profiles")
                        match listed.search_by(fn(y) { text(Some(y), "id") == id }) {
                          Some(i) => Some(listed[i])
                          None => p()
                        }
                      }
                      profile_models_node(v, core, address, id, now, fn() { fusion.get() }, fusion_lead)
                    },
                    from=Unanchored,
                    // (as tall as what it holds up to its share, its models giving way and scrolling in themselves where
                    // that is short of them, what is named by hand staying in view: the old panel's `lists`)
                    tall=pf_models_share,
                    hugs=true,
                  )
                },
                note=fn() {
                  if flag(p(), "canAddModel") {
                    @sf.t("web-pages.profiles.modelsNoteAdd")
                  } else if text(p(), "runtime") == "devin" && text(field(p(), "share"), "role") != "user" {
                    @sf.t("web-pages.profiles.modelsNoteFusion")
                  } else {
                    @sf.t("web-pages.profiles.modelsNote")
                  }
                },
                value=fn() {
                  if !(field(p(), "modelsSaving") is (None | Some(Null))) || is_doing(core, ["profile.addModel"], on) {
                    @sf.t("common.saving")
                  } else if all().length() == 0 {
                    if flag(p(), "modelsReading") || is_doing(core, ["profile.check"], on) {
                      @sf.t("common.reading")
                    } else {
                      @sf.t("web-pages.profiles.noModels")
                    }
                  } else {
                    text(p(), "modelsText")
                  }
                },
              )
            })
            g.show(at_once=true, machine, fn(m_row) {
              let runtime = fn() { @settings.runtime_label(text(p(), "runtime")) }
              said_row_node(
                m_row,
                fn() {
                  if text(s(), "name") != "" {
                    @sf.t("web-pages.profiles.machineLoginOn", args=[("station", text(s(), "name")), ("runtime", runtime())])
                  } else {
                    @sf.t("web-pages.profiles.machineLoginHere", args=[("runtime", runtime())])
                  }
                },
                note=fn() { @sf.t("web-pages.profiles.machineLoginAbout", args=[("runtime", runtime())]) },
              )
            })
            g.show(at_once=true, fn() { !machine() && keyed() }, fn(k_row) {
              k_row.pick(at_once=true, fn() { !busy() }, fn(r, goes) {
                @sf.link_row_node(
                  r,
                  fn() {
                    if kind() == "opencode-go" {
                      "OpenCode Go key"
                    } else if text(p(), "providerName") != "" {
                      text(p(), "providerName") + " key"
                    } else {
                      "API key"
                    }
                  },
                  fn() { ask_key(core, address, @signals.untracked(p)) },
                  note=fn() { if text(access(), "key") != "" { text(access(), "key") } else { @sf.t("web-pages.profiles.notSaved") } },
                  value=fn() { @sf.t("web-pages.profiles.replace") },
                  value_lit=true,
                  chevron=false,
                  goes~,
                  tail=fn(t) { doing_mark_node(t, busy, fn() { failed_of(core, ["profile.put"], on) }) },
                  tail_shown=fn() { busy() || failed_of(core, ["profile.put"], on) is Some(_) },
                )
              })
            })
            g.show(at_once=true, fn() { !machine() && keyed() && has(access(), "endpoint") }, fn(ep_row) {
              ep_row.pick(at_once=true, fn() { !busy() }, fn(r, goes) {
                @sf.link_row_node(
                  r,
                  fn() { @sf.t("common.provider.endpoint") },
                  fn() {
                    let endpoint = text(@signals.untracked(access), "endpoint")
                    let kind = @signals.untracked(kind)
                    ask(@sf.t("common.provider.endpoint"), endpoint, "https://", @sf.t("common.save"), fn(value) {
                      @settings.act(
                        core,
                        @sf.t("web-pages.profiles.replace"),
                        "profile.put",
                        obj([("station", str(address)), ("id", str(id)), ("input", obj([("access", obj([("kind", str(kind)), ("endpoint", str(value.trim(chars=" \t\n").to_owned()))]))]))]),
                        done=@sf.t("web-pages.profiles.savedChecking"),
                      )
                    })
                  },
                  note=fn() { text(access(), "endpoint") },
                  value=fn() { @sf.t("web-pages.profiles.replace") },
                  value_lit=true,
                  chevron=false,
                  goes~,
                )
              })
            })
            g.show(at_once=true, fn() { profile_fast(p()) }, fn(r) {
              @sf.switch_row_node(
                r,
                fn() { @sf.t("web-pages.profiles.fast") },
                fn() { flag(p(), "fast") },
                fn(next) {
                  put(@sf.t("web-pages.profiles.fastSave"), "fast", next, if next { @sf.t("web-pages.profiles.fastOn") } else { @sf.t("web-pages.profiles.fastOff") })
                },
                note=fn() { @sf.t("web-pages.profiles.fastLead") },
                busy~,
              )
            })
            g.show(at_once=true, fn() { profile_background(p()) }, fn(r) {
              @sf.switch_row_node(
                r,
                fn() { @sf.t("web-pages.profiles.background") },
                fn() { flag(p(), "backgroundOnMessage") },
                fn(next) {
                  put(@sf.t("web-pages.profiles.background"), "backgroundOnMessage", next, if next { @sf.t("web-pages.profiles.turnedOn") } else { @sf.t("web-pages.profiles.turnedOff") })
                },
                note=fn() { if flag(p(), "backgroundOnMessage") { @sf.t("android-settings.profile.backgroundOn") } else { @sf.t("android-settings.profile.backgroundOff") } },
                busy~,
              )
            })
            // An Antigravity CLI subscription's quota asked of Google's API beside its CLI (only those say `directQuota`).
            g.show(at_once=true, fn() { has(p(), "directQuota") && !profile_copy(p()) }, fn(r) {
              @sf.switch_row_node(
                r,
                fn() { @sf.t("web-pages.profiles.directQuota") },
                fn() { flag(p(), "directQuota") },
                fn(next) {
                  put(@sf.t("web-pages.profiles.directQuota"), "directQuota", next, if next { @sf.t("web-pages.profiles.turnedOn") } else { @sf.t("web-pages.profiles.turnedOff") })
                },
                note=fn() { if flag(p(), "directQuota") { @sf.t("web-pages.profiles.directQuotaOn") } else { @sf.t("web-pages.profiles.directQuotaOff") } },
                busy~,
              )
            })
            let max_sessions_shown = @signals.computed(fn(_) { profile_max_sessions(p()) })
            let max_sessions_protection = @signals.computed(fn(_) { profile_in_protection(p()) })
            let max_sessions_cap = @signals.computed(fn(_) {
              match field(p(), "maxConcurrentSessions") {
                Some(Number(n, ..)) if n >= 1.0 => n.to_int()
                _ => 0
              }
            })
            g.show(at_once=true, fn() { max_sessions_shown.get() }, fn(cap_row) {
              cap_row.pick(at_once=true, fn() { !busy() }, fn(r, goes) {
                @sf.link_row_node(
                  r,
                  fn() { @sf.t("web-pages.profiles.maxConcurrentSessions") },
                  fn() { ask_max_sessions(core, address, id, p) },
                  note=fn() {
                    if max_sessions_protection.get() {
                      @sf.t("web-pages.profiles.maxConcurrentSessionsProtectionNote")
                    } else {
                      @sf.t("web-pages.profiles.maxConcurrentSessionsNote")
                    }
                  },
                  value=fn() {
                    let cap = max_sessions_cap.get()
                    if cap >= 1 {
                      cap.to_string()
                    } else {
                      @sf.t("web-pages.profiles.maxConcurrentSessionsUnlimited")
                    }
                  },
                  goes~,
                )
              })
            })
            g.show(at_once=true, fn() { joined().length() > 0 }, fn(ws_box) {
              ws_box.each(joined, fn(w) { text(Some(w), "workspace") }, fn(r, w) {
                let wv = fn() { Some(w.get()) }
                let ws = @signals.untracked(fn() { text(wv(), "workspace") })
                let name = fn() { text(wv(), "name") }
                let emoji = fn() { text(wv(), "emoji") }
                let icon = fn() { text(wv(), "icon") }
                let on_ws = fn() { strings(p(), "workspaces").contains(ws) }
                r.pick(at_once=true, fn() { @sf.has_station_mark(emoji(), icon()) }, fn(y, marked) {
                  @sf.switch_row_node(
                    y,
                    name,
                    on_ws,
                    fn(next) {
                      let now = strings(@signals.untracked(p), "workspaces")
                      let list = if next { now.copy() } else { now.filter(fn(x) { x != ws }) }
                      if next {
                        list.push(ws)
                      }
                      let named = @signals.untracked(name)
                      @settings.act(
                        core,
                        @sf.t("web-pages.profiles.workspaces.title"),
                        "profile.put",
                        obj([("station", str(address)), ("id", str(id)), ("input", obj([("workspaces", Json::array(list.map(str)))]))]),
                        done=@sf.t(if next { "web-pages.profiles.workspaces.turnedOn" } else { "web-pages.profiles.workspaces.turnedOff" }, args=[("name", named)]),
                      )
                    },
                    note=fn() { @sf.t(if on_ws() { "web-pages.profiles.workspaces.on" } else { "web-pages.profiles.workspaces.off" }, args=[("name", name())]) },
                    busy~,
                    lead?=if marked {
                      Some(fn(l) { @sf.station_mark_node(l, emoji, icon, profile_ws_mark, fn() { @sf.theme().p.text }, stint) })
                    } else {
                      None
                    },
                  )
                })
              })
            })
            g.show(at_once=true, fn() { kind() == "env" }, fn(env_box) {
              env_box.each(fn() { items(p(), "env") }, fn(e) { text(Some(e), "key") }, fn(r, e) {
                @sf.link_row_node(r, fn() { text(Some(e.get()), "key") }, fn() {  }, note=fn() { text(Some(e.get()), "value") }, goes=false)
              })
              @sf.link_row_node(
                env_box,
                fn() { if open.env.get() { @sf.t("web-pages.profiles.collapse") } else { @sf.t("android-settings.env.edit") } },
                fn() { open.env.set(!open.env.untracked()) },
                chevron=false,
                tail=fn(t) { doing_mark_node(t, busy, fn() { failed_of(core, ["profile.put"], on) }, tips?) },
                tail_shown=fn() { busy() || failed_of(core, ["profile.put"], on) is Some(_) },
              )
            })
          })
          sec.show(fn() { kind() == "env" && open.env.get() }, fn(c) {
            @sf.page_card_node(c, footed=true, fn(k) { env_editor_node(k, core, address, id, p, busy) })
          })
          sec.show(at_once=true, fn() { failed_of(core, ["profile.put"], on) is Some(_) }, fn(n) {
            @sf.page_note_node(n, fn() { failed_of(core, ["profile.put"], on).unwrap_or("") }, bad=fn() { true })
          })
        },
      )
    }
  })
}

///|
/// A new key asked for, in a field that shows dots (secret), and saved (`profile.put` with the account's kind and the
/// key); the station checks it again.
fn ask_key(core : Core, station : String, p : Json?) -> Unit {
  let id = text(p, "id")
  let kind = text(field(p, "access"), "kind")
  ask(
    if kind == "opencode-go" { @sf.t("web-pages.profiles.newOpencodeKey") } else { @sf.t("web-pages.profiles.newApiKey") },
    "",
    @sf.t("web-pages.profiles.pasteKey"),
    @sf.t("common.save"),
    secret=true,
    hint=@sf.t("web-pages.profiles.recheckHint"),
    fn(key) {
      @settings.act(
        core,
        @sf.t("web-pages.profiles.replace"),
        "profile.put",
        obj([("station", str(station)), ("id", str(id)), ("input", obj([("access", obj([("kind", str(kind)), ("key", str(key))]))]))]),
        done=@sf.t("web-pages.profiles.savedChecking"),
      )
    },
  )
}

///|
/// Its new name asked for and saved (`profile.put` its name).
fn profile_rename(core : Core, address : String, p : Json?) -> Unit {
  let id = text(p, "id")
  ask(@sf.t("web-pages.profiles.name"), text(p, "name"), @sf.t("web-pages.profiles.name"), @sf.t("common.save"), fn(line) {
    let to = line.trim(chars=" \t\n").to_owned()
    if to != "" && to != text(p, "name") {
      @settings.act(
        core,
        @sf.t("web-pages.settings.stations.rename"),
        "profile.put",
        obj([("station", str(address)), ("id", str(id)), ("input", obj([("name", str(to))]))]),
        done=@sf.t("web-pages.settings.workspace.renamed"),
      )
    }
  })
}

///|
/// Its variables written (EnvSection's table) on the card `k`: a name and a value a row (a secret's kept masked until it
/// is written anew), deleted or added, saved as what changed (a name gone or renamed: null). The rows as the profile has
/// them as the card is made (opened).
fn env_editor_node(k : @view.View, core : Core, address : String, id : String, p : () -> Json?, busy : () -> Bool) -> Unit {
  let env = @signals.untracked(fn() { items(p(), "env") })
  let row_of = fn(key : String, value : String, masked : String) -> EnvRow {
    { key: @ui.Field::new(text=key), value: @ui.Field::new(text=value), original: key, masked }
  }
  // (the rows themselves the list: each its own fields, a row on the page for each, View::each_of)
  let rows : @signals.Signal[Array[EnvRow]] = @signals.signal_by(
    env.map(fn(e) {
      let ev = Some(e)
      let secret = flag(ev, "secret")
      row_of(text(ev, "key"), if secret { "" } else { text(ev, "value") }, if secret { text(ev, "value") } else { "" })
    }),
    same=fn(x, y) { physical_equal(x, y) },
  )
  k.box(fn(t) {
    @sf.style_node(t, fn() { pf_env_table })
    t.each_of(fn() { rows.get() }, fn(r, row) {
      @sf.style_node(r, fn() { pf_env_row })
      r.box(fn(c) {
        @sf.style_node(c, fn() { pf_env_name }, in_row=true)
        @sf.input_node(c, row.key, placeholder="NAME") |> ignore
      })
      |> ignore
      r.box(fn(c) {
        @sf.style_node(c, fn() { pf_input_grow }, in_row=true)
        c.basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        @sf.input_node(
          c,
          row.value,
          placeholder=if row.masked != "" { @sf.t("web-pages.profiles.envSaved", args=[("masked", row.masked)]) } else { @sf.t("web-pages.profiles.envValue") },
          secret=true,
        )
        |> ignore
      })
      |> ignore
      @sf.button_node(r, fn() { @sf.t("common.delete") }, fn() {
        rows.set(rows.untracked().filter(fn(x) { !physical_equal(x, row) }))
      }, tone=Ghost)
      |> ignore
    })
    @sf.button_node(t, fn() { @sf.t("web-pages.profiles.envAdd") }, fn() {
      rows.set(rows.untracked() + [row_of("", "", "")])
    }, tone=Ghost, icon="plus")
    |> ignore
  })
  |> ignore
  @sf.card_foot_node(k, at_end=true, fn(f) {
    @sf.button_node(f, fn() { @sf.t("common.save") }, fn() {
      // what changed: a name gone or renamed null, a secret left blank kept as it is
      let now = rows.untracked()
      let patch : Map[String, Json] = Map([])
      let kept = now.map(fn(r) { r.key.text().trim(chars=" \t\n").to_owned() })
      for e in env {
        if !kept.contains(text(Some(e), "key")) {
          patch[text(Some(e), "key")] = Json::null()
        }
      }
      for r in now {
        let name = r.key.text().trim(chars=" \t\n").to_owned()
        if name == "" {
          continue
        }
        if r.original != "" && r.original != name {
          patch[r.original] = Json::null()
        }
        if r.masked != "" && r.value.text() == "" && r.original == name {
          continue
        }
        patch[name] = str(r.value.text())
      }
      @settings.act(
        core,
        @sf.t("web-pages.profiles.env"),
        "profile.put",
        obj([("station", str(address)), ("id", str(id)), ("input", obj([("env", Json::object(patch))]))]),
        done=@sf.t("web-pages.profiles.saved"),
      )
    }, tone=Primary, busy~)
    |> ignore
  })
}

// ── its models' panel (a presenter's, made as nodes) ─────────────────────────

///|
/// All of a profile's models in node `v` (the panel profile_settings_node opens), by the core's series, each under its
/// name where there are more than one, each with a box before it, ticked while it is starred (`pick.like`, as the
/// model control's are: 2026-11-02 用户「这里改成也能点勾」), its id beside it under the pointer; one named by hand that
/// its provider does not list taken off by its ×; one more named by hand over them, where it can be; Devin's Fusion
/// combinations after them where the station said them (`fusion`). The profile `p` as it is now, all of it following
/// it; where the panel has not the room for all of them, the models scroll by themselves, what is named by hand
/// staying over them.
fn profile_models_node(
  v : @view.View,
  core : Core,
  address : String,
  id : String,
  p : () -> Json?,
  fusion : () -> Json?,
  fusion_lead : @signals.Signal[String],
) -> Unit {
  let named = fn() { strings(p(), "named") }
  let name = fn(m : String) {
    match text(field(p(), "names"), m) {
      "" => m
      n => n
    }
  }
  let busy = fn() { has(p(), "modelsSaving") && !(field(p(), "modelsSaving") is Some(Null)) }
  // what is starred, as the new chat's model control of this station has it (its options, each `liked`, by spelling)
  let liked = fn(m : String) {
    let options = items((core.topic)("pick", { "station": Json::string(address), "of": Json::string("new") }).get().value, "options")
    options.iter().any(fn(o) { flag(Some(o), "liked") && (text(Some(o), "model") == m || strings(Some(o), "ids").contains(m)) })
  }
  // (each series with its models, the Fusion pairs listed in their own section left out of them)
  let shown_series = fn() -> Array[(String, Array[String])] {
    let f = fusion()
    let fusion_uids : Map[String, Bool] = Map([])
    if f is Some(Object(_)) {
      let sides = items(f, "sides")
      for lead in items(f, "leads") {
        let lv = Some(lead)
        let lead_id = text(lv, "id")
        for idx_json in items(lv, "sides") {
          if idx_json is Number(idx, ..) && sides.get(idx.to_int()) is Some(side) {
            fusion_uids["fusion-" + lead_id + "-sidekick-" + text(Some(side), "id")] = true
          }
        }
      }
    }
    let shown : Array[(String, Array[String])] = []
    for s in items(p(), "series") {
      let sv = Some(s)
      let models = strings(sv, "models").filter(fn(m) { !fusion_uids.contains(m) })
      if !models.is_empty() {
        shown.push((text(sv, "name"), models))
      }
    }
    shown
  }
  // (one more named by hand over them, where it can be: under them it stood in the panel's corner)
  // (what is named by hand and the models as far apart as the panel's body's parts are, on its words' line; giving
  // way, as tall as the panel leaves them, the models scrolling in that)
  v.box(fn(body) {
    @sf.style_node(body, fn() { pf_models_body.then(@sf.panel_words_in_node(body)) })
    body.gap(Is(@sf.panel_parts_gap_node(body))).shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    body.show(at_once=true, fn() { flag(p(), "canAddModel") }, fn(b) {
      @sf.style_node(b, fn() { pf_models_add })
      add_model_node(b, core, address, id)
    })
    @sf.capped_node(body, fn() { pf_models_most }, fn(col) {
      @sf.style_node(col, fn() { pf_model_rows.then(pf_models_foot()) })
      col.each(shown_series, fn(s) { s.0 }, fn(sb, s) {
        // (each row as wide as what it holds, cut short where the panel has not the room: its id's tip just past it)
        @sf.style_node(sb, fn() { pf_model_series })
        sb.show(at_once=true, fn() { shown_series().length() > 1 }, fn(r) {
          @sf.style_node(r, fn() { pf_series_room })
          @sf.words_node(r, fn() { s.get().0 }, fn() { pf_series_words }) |> ignore
        })
        sb.each(fn() { s.get().1 }, fn(m) { m }, fn(row, m) {
          let m = m.untracked()
          profile_model_row_node(row, core, address, id, p, m, name, liked, named, busy)
        })
      })
      col.show(at_once=true, fn() { fusion() is Some(Object(_)) }, fn(f) {
        profile_fusion_node(f, core, address, id, p, fusion, fusion_lead, named, liked, busy)
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// A model's row in its panel in node `row`: its box (starred), its maker's mark, its name, cut short where it has not
/// the room, and its × where it was named by hand; its id beside it under the pointer (where it says more than its
/// name, or its name shows cut short).
fn profile_model_row_node(
  row : @view.View,
  core : Core,
  address : String,
  id : String,
  p : () -> Json?,
  m : String,
  name : (String) -> String,
  liked : (String) -> Bool,
  named : () -> Array[String],
  busy : () -> Bool,
) -> Unit {
  let tips = @sf.panel_tips_of(row)
  let item = row.box(fn(r) {
    @sf.style_node(r, fn() { pf_model_row.then(@sf.row_least_h()) })
    @sf.check_node(
      r,
      fn() { liked(m) },
      fn(on) {
        (core.call)(
          "pick.like",
          obj([("station", str(address)), ("of", str("new")), ("model", str(m)), ("liked", Json::boolean(on))]),
          @sfbase.answer_unread,
        )
      },
      fn() { @sf.t("web-main.model.likeModel", args=[("model", name(m))]) },
    )
    let maker = @signals.untracked(fn() { text(field(field(p(), "makers"), m), "id") })
    let runtime = @signals.untracked(fn() { text(p(), "runtime") })
    @sf.maker_mark_node(r, maker, runtime, pf_chip_glyph) |> ignore
    @sf.words_node(r, fn() { name(m) }, fn() { pf_model_words }) |> ignore
    r.show(at_once=true, fn() { strings(p(), "added").contains(m) }, fn(x) {
      @sf.icon_button_node(
        x,
        "close",
        fn() { @sf.t("web-pages.profiles.removeModel", args=[("model", name(m))]) },
        fn() {
          let label = @signals.untracked(fn() { @sf.t("web-pages.profiles.removeModel", args=[("model", name(m))]) })
          let rest = @signals.untracked(named).filter(fn(y) { y != m })
          @settings.act(
            core,
            label,
            "profile.put",
            obj([("station", str(address)), ("id", str(id)), ("input", obj([("models", Json::array(rest.map(str)))]))]),
          )
        },
        tips?,
        size=pf_chip_off,
        icon_size=pf_chip_glyph,
        disabled=busy,
      )
      |> ignore
    })
  })
  match tips {
    Some(layer) =>
      @sf.tip_node(layer, item, fn() { m }, side=Right, within=true, repeats=@signals.untracked(fn() { name(m) == m }))
      |> ignore
    None => ()
  }
}

///|
/// Devin's Fusion combinations (`lead + sidekick`) in node `v`, organized by lead model chip and sidekick checklist so
/// pairs can be pinned to the main model list without scrolling through hundreds of flat variants: the pairs pinned
/// (each unticked to take it off), the leads to choose among (`fusion_lead`: the first where none is chosen or the one
/// chosen is gone), the chosen lead's sidekicks, each ticked while pinned.
fn profile_fusion_node(
  v : @view.View,
  core : Core,
  address : String,
  id : String,
  p : () -> Json?,
  fusion : () -> Json?,
  fusion_lead : @signals.Signal[String],
  named : () -> Array[String],
  liked : (String) -> Bool,
  busy : () -> Bool,
) -> Unit {
  let sides = fn() { items(fusion(), "sides") }
  let leads = fn() { items(fusion(), "leads") }
  let runtime = fn() { text(p(), "runtime") }
  let tips = @sf.panel_tips_of(v)
  let toggle_pair = fn(uid : String, want_on : Bool) {
    let now = @signals.untracked(named)
    let next_named = if want_on {
      if now.contains(uid) { now } else { now + [uid] }
    } else {
      now.filter(fn(x) { x != uid })
    }
    @settings.act(
      core,
      @sf.t("web-pages.profiles.fusionModels"),
      "profile.put",
      obj([("station", str(address)), ("id", str(id)), ("input", obj([("models", Json::array(next_named.map(str)))]))]),
    )
    if want_on || @signals.untracked(fn() { liked(uid) }) {
      (core.call)(
        "pick.like",
        obj([("station", str(address)), ("of", str("new")), ("model", str(uid)), ("liked", Json::boolean(want_on))]),
        @sfbase.answer_unread,
      )
    }
  }
  let picked_lead = fn() -> Json? {
    let ls = leads()
    match ls.search_by(fn(l) { fusion_lead.get() != "" && text(Some(l), "id") == fusion_lead.get() }) {
      Some(i) => Some(ls[i])
      None => ls.get(0)
    }
  }
  // (the pairs pinned: uid, what it is called, its lead's maker)
  let ticked = fn() -> Array[(String, String, String)] {
    let all = sides()
    let now = named()
    let out = []
    for lead in leads() {
      let lv = Some(lead)
      for idx_json in items(lv, "sides") {
        if idx_json is Number(idx, ..) && all.get(idx.to_int()) is Some(side) {
          let sv = Some(side)
          let uid = "fusion-" + text(lv, "id") + "-sidekick-" + text(sv, "id")
          if now.contains(uid) {
            out.push((uid, text(lv, "name") + " + " + text(sv, "name"), text(field(lv, "maker"), "id")))
          }
        }
      }
    }
    out
  }
  // (the chosen lead's sidekicks: uid, its name, its maker)
  let sidekicks = fn() -> Array[(String, String, String)] {
    let all = sides()
    let lead = picked_lead()
    let out = []
    for idx_json in items(lead, "sides") {
      if idx_json is Number(idx, ..) && all.get(idx.to_int()) is Some(side) {
        let sv = Some(side)
        out.push(("fusion-" + text(lead, "id") + "-sidekick-" + text(sv, "id"), text(sv, "name"), text(field(sv, "maker"), "id")))
      }
    }
    out
  }
  // (`within`: by a row that is no control, the pointer anywhere in it; else by the control itself)
  let tip = fn(anchor : @view.View, uid : String, within : Bool) {
    match tips {
      Some(layer) => @sf.tip_node(layer, anchor, fn() { uid }, side=Right, within~) |> ignore
      None => ()
    }
  }
  let heading = fn(parent : @view.View, words : String) {
    parent.box(fn(h) {
      @sf.style_node(h, fn() { pf_series_room })
      @sf.words_node(h, fn() { @sf.t(words) }, fn() { pf_series_words }) |> ignore
    })
    |> ignore
  }
  v.show(at_once=true, fn() { !sides().is_empty() && !leads().is_empty() }, fn(sec) {
    @sf.style_node(sec, fn() { pf_model_series })
    sec.box(fn(h) {
      @sf.style_node(h, fn() { pf_fusion_head })
      @sf.words_node(h, fn() { @sf.t("web-pages.profiles.fusionModels") }, fn() { pf_series_words }) |> ignore
      @sf.words_node(h, fn() { @sf.t("web-pages.profiles.fusionHint") }, fn() { pf_muted }) |> ignore
    })
    |> ignore
    sec.each(ticked, fn(t) { t.0 }, fn(row, t) {
      let (uid, display, maker_id) = t.untracked()
      let item = row.box(fn(r) {
        @sf.style_node(r, fn() { pf_model_row.then(@sf.row_least_h()) })
        @sf.check_node(r, fn() { true }, fn(on) { if !on && !@signals.untracked(busy) { toggle_pair(uid, false) } }, fn() {
          display
        }, disabled=busy)
        @sf.maker_mark_node(r, maker_id, @signals.untracked(runtime), pf_chip_glyph) |> ignore
        @sf.words_node(r, fn() { display }, fn() { pf_model_words }) |> ignore
      })
      tip(item, uid, true)
    })
    heading(sec, "web-pages.profiles.fusionLead")
    @sf.radio_chip_group(
      sec,
      fn() { @sf.t("web-pages.profiles.fusionLead") },
      fn() { text(picked_lead(), "id") },
      fn(id) { fusion_lead.set(id) },
      fn(chips, rg) {
        @sf.style_node(chips, fn() { pf_fusion_leads })
        chips.wraps(Is(Some(pf_fusion_line_gap))) |> ignore
        chips.each(leads, fn(l) { text(Some(l), "id") }, fn(chip, l) {
          let lv = @signals.untracked(fn() { Some(l.get()) })
          let lead_id = text(lv, "id")
          let lead_name = text(lv, "name")
          let maker_id = text(field(lv, "maker"), "id")
          let rt = @signals.untracked(runtime)
          let active = fn() { text(picked_lead(), "id") == lead_id }
          @sf.radio_chip_item(rg, chip, fn() { lead_id }, fn() { lead_name }, fn(b) {
            profile_fusion_chip_content(b, maker_id, rt, lead_name, "", active)
          })
          |> ignore
        })
      },
    )
    |> ignore
    heading(sec, "web-pages.profiles.fusionSidekick")
    sec.box(fn(chips) {
      @sf.style_node(chips, fn() { pf_fusion_leads })
      chips.wraps(Is(Some(pf_fusion_line_gap))) |> ignore
      chips.each(sidekicks, fn(k) { k.0 }, fn(chip, k) {
        let (uid, side_name, maker_id) = k.untracked()
        let (name_part, eff_part) = match side_name.find(" · ") {
          Some(at) => (side_name.exact_view(start=0, end=at).to_owned(), side_name.exact_view(start=at + 3).to_owned())
          None => (side_name, "")
        }
        let rt = @signals.untracked(runtime)
        let on = fn() { named().contains(uid) }
        let b = @sf.check_chip_node(
          chip,
          fn() { side_name },
          on,
          fn(want) {
            if !@signals.untracked(busy) {
              toggle_pair(uid, want)
            }
          },
          fn(v) { profile_fusion_chip_content(v, maker_id, rt, name_part, eff_part, on) },
          disabled=busy,
        )
        tip(b, uid, false)
      })
    })
    |> ignore
  })
}

///|
/// Content slot for a Fusion selectable chip (`radio_chip_item` / `check_chip_node`): its maker mark,
/// its name (semibold while `on`), and optional quieter `more` (effort label).
fn profile_fusion_chip_content(
  b : @view.View,
  maker : String,
  runtime : String,
  name : String,
  more : String,
  on : () -> Bool,
) -> Unit {
  @sf.maker_mark_node(b, maker, runtime, pf_fusion_mark) |> ignore
  @sf.words_node(b, fn() { name }, fn() { if on() { pf_fusion_lead_words_on } else { pf_fusion_lead_words } }) |> ignore
  if more != "" {
    @sf.words_node(b, fn() { more }, fn() { pf_series_words }) |> ignore
  }
}

///|
/// The Fusion chips' lines apart (wrapped), and their marks (a maker's, the tick).
let pf_fusion_line_gap : Double = 6.0

///|
let pf_fusion_mark : Double = 12.0

///|
/// A model named by hand (AddModel) in node `b`, for a provider that does not list them all: its name typed, added
/// by Enter or 添加 (`profile.addModel`), the field emptied.
fn add_model_node(b : @view.View, core : Core, address : String, id : String) -> Unit {
  let f = profile_field("add-model/" + address + "/" + id)
  let adding = fn() { is_doing(core, ["profile.addModel"], [("station", address), ("id", id)]) }
  let typed = fn() { f.text().trim(chars=" \t\n").to_owned() }
  let add = fn() {
    let m = @signals.untracked(typed)
    if m != "" && !@signals.untracked(adding) {
      @settings.act(core, @sf.t("web-pages.profiles.addModelWhat"), "profile.addModel", obj([("station", str(address)), ("id", str(id)), ("model", str(m))]))
      f.set("")
    }
  }
  b.box(fn(r) {
    @sf.style_node(r, fn() { pf_input_row })
    r.box(fn(g) {
      @sf.style_node(g, fn() { pf_input_grow }, in_row=true)
      g.min_width(Is(Some(0.0))) |> ignore
      @sf.input_node(
        g,
        f,
        placeholder=@sf.t("web-pages.profiles.addModelPlaceholder"),
        shorter=[@sf.t("web-mobile.profiles.addModelPlaceholder")],
        submitted=fn(_) { add() },
      )
      |> ignore
    })
    |> ignore
    @sf.button_node(r, fn() { @sf.t("web-pages.profiles.addModel") }, add, busy=adding, disabled=fn() { typed().is_empty() }) |> ignore
  })
  |> ignore
}

// ── styles (pages.css.ts identity) ─────────────────────

///|
/// Words on its cards, and the quieter ones (the ui's 13 on 24; muted).
// kept across runs: a value (no field of it changes)
let pf_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let pf_muted : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, w=Full)

///|
let pf_mark_glyph : Double = 26.0

///|
let pf_mark_wide_glyph : Double = 18.0

///|
let pf_chip_glyph : Double = 14.0

///|
let pf_user_avatar : Double = 24.0

///|
/// What its last check said, cut short where its line has less.
// kept across runs: a value (no field of it changes)
let pf_check_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false, w=Cut)

///|
/// Its state under its name (profileState: 8 apart).
// kept across runs: a value (no field of it changes)
let pf_state : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
/// The runtimes and uses this profile serves, under its first line.
// kept across runs: a value (no field of it changes)
let pf_tags : @ui.Style = @ui.css("row w=Full gap=S1_5 align=ACenter")

///|
let pf_tags_line_gap : Double = 6.0

///|
let pf_tag_icon : Double = 12.0

///|
// kept across runs: a value (no field of it changes)
let pf_tags_lead : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pf_wait_line : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
/// A card's parts apart, what a part of it shows in its own room too (desk_card's gap=S3_5).
let pf_card_gap : Double = 14.0

///|
/// A footed card's lines of buttons apart where they go on to another (card_foot's gap between them, 8).
let pf_foot_lines : Double = 8.0

///|
/// A sign-in's step (steps: its words over what is done in it).
// kept across runs: a value (no field of it changes)
let pf_step : @ui.Style = @ui.css("w=Full gap=S2 align=AStart")

///|
/// A step's page buttons (its own and, where the station has a browser, the station's) and the ⋯ after them (copying
/// the link for a browser elsewhere): wrapped across lines on a narrow card or large words.
let pf_step_buttons_gap : Double = 8.0

///|
// kept across runs: a value (no field of it changes)
let pf_step_buttons : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let pf_input_row : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let pf_input_grow : @ui.Style = @ui.style(w=@sf.grow)

///|
/// A device's code (deviceCode: the code large, then its one button, 10 apart).
// kept across runs: a value (no field of it changes)
let pf_device : @ui.Style = @ui.css("w=Full gap=S2_5 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let pf_device_code : @ui.Style = @ui.css("px=S3 py=S1_5 radius=Lg bg=Hover")

///|
// kept across runs: a value (no field of it changes)
let pf_device_code_words : @ui.TextStyle = @ui.text_style(size=Heading, weight=Semibold, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pf_chips : @ui.Style = @ui.css("row w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let pf_chip : @ui.Style = @ui.css("row px=S2_5 py=S1 gap=S1_5 align=ACenter radius=Full bg=Hover")

///|
/// A profile's models in their panel: a row each (a box, its maker's mark, its name, its ×), 1 apart, scrolling where
/// the panel leaves them less (no most of their own); a series' name over its models; one more named by hand over them.
let pf_models_most : Double = 1.0e6

///|
/// What is named by hand over the models and the models (as far apart as the panel's body's parts: panel_parts_gap_node).
// kept across runs: a value (no field of it changes)
let pf_models_body : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let pf_model_rows : @ui.Style = @ui.css("w=Full gap=SPx")

///|
/// Under the models, as much room as keeps the last one's box out of the panel's foot corner: a box there, its row's
/// words on the panel's words' line (34 in from a corner 42 round), would have to be concentric with the corner (8
/// round, a box's 6: the corner rule), so it stands clear of it, its rows' spacing as it was (a card row's control the
/// same: @sf.card_control_end).
fn pf_models_foot() -> @ui.Style {
  @ui.style(pb=@sf.panel_foot_clear(@sf.theme().items.least, pf_like_box))
}

///|
/// How big a model's box is (@kit.checkbox's).
let pf_like_box : Double = 18.0

///|
/// The share of the window its models' panel is at most (as tall as what it holds up to it): all the dialog or the
/// sheet leaves it, as the old panel's lists had.
let pf_models_share : Double = 1.0

///|
// kept across runs: a value (no field of it changes)
let pf_model_series : @ui.Style = @ui.css("w=Full gap=SPx align=AStart")

///|
// kept across runs: a value (no field of it changes)
let pf_model_row : @ui.Style = @ui.css("row w=Cut px=S2_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let pf_model_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let pf_series_room : @ui.Style = @ui.css("w=Full px=S2_5 pt=S2 pb=S1")

///|
// kept across runs: a value (no field of it changes)
let pf_series_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pf_models_add : @ui.Style = @ui.css("w=Full pb=S2")

///|
// kept across runs: a value (no field of it changes)
let pf_fusion_head : @ui.Style = @ui.css("w=Full px=S2_5 pt=S3 pb=S1 gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let pf_fusion_leads : @ui.Style = @ui.css("row w=Full px=S2_5 pb=S1 gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let pf_fusion_lead_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pf_fusion_lead_words_on : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, color=Fg, wrap=false)

///|
/// The × of a model named by hand on its chip (a round button as high as its words' line).
let pf_chip_off : Double = 18.0

///|
// kept across runs: a value (no field of it changes)
let pf_chip_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, wrap=false)

///|
/// The variables' rows (envTable: 8 apart; a row its name, its value wider, deleting it).
// kept across runs: a value (no field of it changes)
let pf_env_table : @ui.Style = @ui.css("w=Full gap=S2")

///|
// kept across runs: a value (no field of it changes)
let pf_env_row : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let pf_env_name : @ui.Style = @ui.css("w=S48")

///|
/// A profile made up, for what its page shows while it is read (profile_node's, in its bones): its name, how it stands,
/// its allowance, the models it may use.
fn profile_sample() -> Json {
  let models = [7, 9, 6, 8, 5].mapi(fn(i, n) { ("sample" + i.to_string(), @sf.sample_words(n)) })
  let w = fn(n : Int) { Json::string(@sf.sample_words(n)) }
  let window = fn(left : Int) -> Json { { "left": Json::number(left.to_double()), "level": "ok", "label": w(3), "refills": w(5) } }
  {
    "id": "sample",
    "name": Json::string(@sf.sample_words(8)),
    "kindText": w(4),
    "checkTone": "green",
    "checkLine": w(4),
    "check": { "time": { "checkedAt": { "ago": w(5) } } },
    "quota": { "state": "ok", "windows": [window(60), window(20)], "time": { "checkedAt": { "ago": w(5) } } },
    "available": Json::array(models.map(fn(m) { Json::string(m.0) })),
    "models": Json::array(models.map(fn(m) { Json::string(m.0) })),
    "names": Json::object(Map::from_array(models.map(fn(m) { (m.0, Json::string(m.1)) }))),
  }
}

///|
/// A workspace's mark before its switch's title.
let profile_ws_mark : Double = 16.0

///|
/// When an allowance was read, 12 under its dials (quota_read_room's).
// kept across runs: a value (no field of it changes)
let pq_read_room : @ui.Style = @ui.css("w=Full pt=S3")

///|
// kept across runs: a value (no field of it changes)
let pq_read_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, w=Full)
