// What a person wrote, as nodes of the window's tree, made once (message.mbt's person_words, mine_bubble, mine_message,
// and others_message's body for a person's words; their styles the same): the words in pieces as the core gave them
// (person_runs: a chat's reference its chip, a web address its link), each link pressed where it leads and held for its
// menu; the viewer's own in their bubble at the column's end, its time under it; someone else's under their picture,
// name and time; what each quotes ahead of its words (message_quotes_node). Each read through what it is given, as
// that changes.
// Each link's card while a mouse rests on it (message_link_card: a web link's, a chat's); its files (message_files_node:
// the viewer's between what it quotes and its words, someone else's under their words). The viewer's words sent from
// here fly in from the composer (sent_part_flight), what is under them coming in on that flight's own way.

///|
/// What a person wrote (person_words') in `v`, as `m` says it as it changes: in the face for what people wrote (the
/// theme's `words`), in pieces as the core gave them, links in blue; a link tapped opens where it leads, held (or right
/// clicked) its menu; the words `found` says in bold, marked where `found_at` says (found_marks: the one the find is
/// at of them, -1 none; None not marked), the passage `lit` says lit where they have it (passage_marks: a quote's that
/// led here, as it flashes); each link's card while a mouse rests on it where `cards` says
/// them (drawn in its layer: a chat's link_peeks, message_link_card). The words' node.
fn person_words_node(
  v : @view.View,
  m : () -> Message,
  found? : () -> Array[String] = fn() { [] },
  found_at? : () -> Int? = fn() { None },
  lit? : () -> (String, Int64) = fn() { ("", 0L) },
  cards? : (@sf.TipLayer, (@sf.LinkOf) -> @sf.LinkCard?),
) -> @view.View {
  // (worked out once as what they are worked out of changes, what reads them many times over reading that)
  let runs_now = @signals.computed(fn(_) {
    let now = m()
    @sf.found_weight(@sfbase.person_runs(now.text, now.words, @sf.theme().p.accent, chat_title=chat_title_of(now)), found())
  })
  let runs = fn() { runs_now.get() }
  // (what a find marks of them: found_marks; and the passage lit where they have it: passage_marks)
  let found_now = fn() {
    match found_at() {
      Some(at) => @sf.found_marks(runs(), found(), at)
      None => []
    }
  }
  // (and the passages kept lit on them by what they are in: md_lits, as a Markdown text's are)
  let kept = match v.lent(@sf.md_lits) {
    Some(f) => f
    None => fn() { [] }
  }
  // (no find and no passage lit, as nearly always: none, their words not read for it)
  let marks = fn() {
    let l = lit()
    let ls = kept()
    if found_at() is None && l.0 == "" && ls.is_empty() {
      []
    } else {
      let now = runs()
      found_now() + ls.map(fn(k) { @sf.passage_marks(now, k) }).flatten() + @sf.passage_marks(now, l)
    }
  }
  let words = v.box(fn(w) {
    w
    .words_runs(By(runs))
    .runs_marks(By(marks))
    // (what a go-to brings before the eyes in them, where they have it: sought_part)
    .sought(fn() { @sf.sought_part(runs(), found_now(), lit().0).map(fn(r) { @ui.runs_piece(w, r.0, r.1) }) })
    // (how they are set, all from the theme: one binding for the three)
    .sets_together(
      fn() {
        let t = @sf.theme()
        (@ui.style_words(t.t.words), { ..@view.runs_plain, link: t.p.blue, words: true }, @ui.style_ink(t.t.words))
      },
      fn(s) { w.words_look(Is(s.0)).runs_look(Is(s.1)).ink(Is(s.2)) |> ignore },
    )
    |> ignore
  })
  // (its links pressed, each held for its menu, and their cards where `cards` says them: made once it has a link)
  @sf.words_links_node(v, words, runs, fn(h) { open_link(h) }, hold=Some(fn(href, at) { message_link_held(href, at) }), cards~)
  words
}

///|
/// A link of what a person wrote held (or right clicked: link_held's), its menu by the piece of line under the hand
/// (`at`, in the window): open it (a web address), copy it.
fn message_link_held(href : String, at : (Double, Double, Double, Double)) -> Unit {
  @sf.menu_held_node()
  @sf.link_menu(
    href,
    from=At(at.0, at.1, at.2, at.3),
    fn() { @ui.open_url(href) |> ignore },
    fn() { @sfbase.copy_out(href, said=@sf.t("common.link.copied")) },
  )
}

///|
/// How wide what the viewer sent may be at the column's end in a pane `pane` wide (mine_most's): as wide as the composer
/// sets its words, the bubble's sides round them.
fn mine_most_of(pane : Double) -> Double {
  composer_words_width(pane) + 2.0 * bubble_side
}

///|
/// The viewer's words in their bubble (mine_bubble's, as they rest: none flying in) in `v`: 8 by 14 in, 18 round, on
/// the neutral ground, as wide as the composer sets its words at most (mine_most_of the pane's width, as it changes);
/// its links' cards as `cards` says (person_words_node's: none for what is not in the chat yet, as the old one's).
/// Sent from here a moment ago (`flies_from`: where its words stood in the composer's field), it flies from there with
/// the rest of what was sent (`fly`: SentFly's, its words' part "words").
fn mine_bubble_node(
  v : @view.View,
  here : MessageNodeHere,
  m : () -> Message,
  found : () -> Array[String],
  found_at : () -> Int?,
  lit? : () -> (String, Int64) = fn() { ("", 0L) },
  cards? : (@sf.TipLayer, (@sf.LinkOf) -> @sf.LinkCard?),
  flies_from? : (Double, Double)? = None,
  words_room? : (Double, Double, Double, Double)? = None,
  fly? : SentFly = sent_fly_alone,
) -> Unit {
  v.box(fn(b) {
    @sf.style_node(b, fn() { bubble.then(@ui.style(max_w=Fixed(mine_most_of((here.width)())))) })
    // (sent from here a moment ago: from where its words stood in the composer's field, its words there as they were
    // typed, its ground coming in round them as they go across (the old page's desktop flight, flight_ground: what
    // every composer sends with): a flight, sf/motion.mbt's kind 4; View::flies_in)
    // (words the field had scrolled, some of them out of its room (`words_room`): none of those seen as they set out,
    // what is seen of them opening to the whole bubble on its way; words all in it, all of them seen)
    match flies_from {
      Some((x, y)) => {
        let cut_from = fn(to : (Double, Double, Double, Double)) {
          match words_room {
            Some((_, ry, _, rh)) if y < ry - 1.0 || y + (to.3 - 2.0 * bubble_top) > ry + rh + 1.0 =>
              Some((x - bubble_side, ry - bubble_top, x - bubble_side + to.2, ry + rh + bubble_top))
            _ => None
          }
        }
        fly.flies_in(b, sent_words_part, fn(to) { Some((x - bubble_side, y - bubble_top, to.2, to.3)) }, bare_from=true, cut_from~, particle=true)
      }
      None => ()
    }
    // (on the page's way to a wider column (a side panel sliding out), laid out as wide as where it goes, as long as it
    // is wider than it may be at the width the column is drawn at: drawn in from the column's right by as much, its words'
    // start where a bubble that wide starts at that width, what is past the column's right cut there by the page as
    // the panel's edge goes, never its start cut at the column's left (the user, 2026-11-17, its words cut at their
    // start as the panel closed); none at rest, or drawn as wide as laid out: sfbase's column_laid. Bound only once a
    // chat's column has first set off on such a way, at that cause, as the list's clip is (chat_body_node): a chat's page
    // opened binds nothing for it, chat_nodes_open_budget)
    let chat = here.station + "\u{1}" + here.session
    let bind = fn() {
      b.moved_by(
        fn(w, _, _) {
          // (the room it has as drawn, between the rows' sides: the column as wide as it is drawn (where it is laid out,
          // less as much narrower), less a row's side at each end where it is laid out, less what its right edge and the
          // words at the column's left are each moved in by, across: chat_body_node's offset of a message of one's own,
          // the column's own; so its start never further left than the others' words start)
          let c = @sfbase.column_laid(chat, b)
          if c.by < 0.0 {
            let laid = (here.width)()
            (@sf.dmax(0.0, w - (laid + c.by - 2.0 * row_side(laid) - 2.0 * c.across)), 0.0)
          } else {
            (0.0, 0.0)
          }
        },
        fn(_, _) { 0.0 },
      )
      |> ignore
    }
    if @signals.untracked(fn() { @sfbase.column_set_off_count() > 0 }) {
      bind()
    } else {
      let bound = Ref(false)
      @sfbase.column_set_off_each(b, fn() {
        if !bound.val && b.alive() {
          bound.val = true
          bind()
        }
      })
    }
    person_words_node(b, m, found~, found_at~, lit~, cards?) |> ignore
  })
  |> ignore
}

///|
/// The viewer's own message (mine_message's, its words alone) in its row's room (message_row_frame_node: `key`, its
/// list's Entry::id; `side`, `top`; `over`), as `m` says it as it changes: at the column's end, its words in their
/// bubble; under it, unless their next message soon after says it under that one (`followed`), the runtime it waits
/// for where its station lacks it (blocked_line_node), else that its agents have yet to take it (agent_waiting_node),
/// else its time: one in the other's place as that changes. Where it offers itself (`share`), any of it right clicked
/// (its bubble, or its pictures, files or film where it has no words) offers that (message_menu_node: the old bubble's
/// pickable's; no ⋯, as the old row had none).
///
/// What was sent from here and is not the chat's yet is the same row (`out`: Some while it is on its way, `m` then
/// outgoing_said's), one row to a person as the core's message takes it over: its words' node made once and kept, so
/// what is picked of them, its handles and its menu stay. What differs is bound to which it is now: under it its time
/// from the first (the core says it of when it was sent), so the station taking it changes nothing seen; 正在发送 in
/// its place only once it has been on its way sending_shows_ms from `since` (a moment of the frames' clock: the
/// caller's) with the station not having it, and not while its words fly here (`flying`); or what did not go
/// (outbox_unsent_node); on its way, its files said by no one yet, its links no cards, nothing found in it and no right
/// click's offer.
// the chat's page as nodes: held by its tests, not used by the app yet
#warnings("-unused_value")
fn mine_said_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  key : () -> String,
  side : () -> Double,
  top : () -> Double,
  m : () -> Message,
  found? : () -> Array[String] = fn() { [] },
  found_at? : () -> Int? = fn() { None },
  lit? : () -> (String, Int64) = fn() { ("", 0L) },
  share? : MessageShare? = None,
  out? : () -> Outgoing? = fn() { None },
  since? : () -> Double = fn() { 0.0 },
  flying? : () -> Bool = fn() { false },
  lands? : (Double) -> Unit = fn(_) {  },
) -> MessageRowNode {
  let said = fn() { out() is None }
  // (sent from here a moment ago: its bubble flies from where its words stood in the composer's field (mine_bubble_node),
  // its quotes and files from where they stood (message_quotes_node's, message_files_node's), all of it one send's:
  // SentFly, setting out as long after it was sent as it says (sfbase's sent_delay_take: none but a new chat's first
  // words on 窄排法))
  let flies_from = @sfbase.sent_from_take(@signals.untracked(key))
  // (and the room of the field its words were seen within there)
  let words_room = @sfbase.sent_words_room_take(@signals.untracked(key))
  // (a composer made as nodes: the ids its quotes' cards were shared by, each card here flying from its own as one box)
  let quote_ids = @sfbase.sent_quote_ids_take(@signals.untracked(key))
  let quotes_fly = quote_ids.map(fn(id) { id != "" })
  let parts_flying = @sfbase.sent_parts_flying(@signals.untracked(key))
  let has_parts = !parts_flying.is_empty() || quotes_fly.iter().any(fn(q) { q })
  let made_at = v.cause_at()
  // (the node of what leads it, as it is made: what is under it comes in as that goes across, View::flight_across_now)
  // (a node handle, no value to compare: told once, as its lead is made, for the under's binding to follow)
  let lead_view : @signals.Signal[@view.View?] = @signals.signal_ref(None)
  let flight_ends : @signals.Signal[Double?] = @signals.signal(None)
  let lead_dy = Ref(0.0)
  // (what is under it flown in once: shown again at the same cause (what comes between it and the last let in), there
  // at once, not flying again from where it set out)
  let under_flew = Ref(false)
  let fly : SentFly = {
    flight: sent_flight(@sfbase.sent_delay_take(@signals.untracked(key))),
    lead: sent_lead(
      flies_from is Some(_) && @signals.untracked(fn() { m().text != "" }),
      parts_flying,
      quotes_fly,
    ),
    led: fn(b) {
      lead_view.set(Some(b))
      // (said of its chat while it still stands in the field it set out from, flying from there: words sent after it
      // in that while land it first, sent_in_field_land)
      if flies_from is Some(_) {
        let chat = here.station + "\u{1}" + here.session
        let out_at = made_at + @sfbase.sent_out_away_ms()
        let held = sent_in_field.get(chat).unwrap_or([])
        held.push((out_at, b))
        sent_in_field[chat] = held
        b.owns(fn() { sent_in_field_drop(chat, b) }) |> ignore
      }
      b.reacts(fn() { b.flight_ends_now() }, fn(ends) {
        flight_ends.set(ends)
        match ends {
          Some(e) => lands(e)
          None => ()
        }
      })
    },
    dy_told: fn(dy) { lead_dy.val = dy },
  }
  message_row_frame_node(v, key, side, top, fn(r) {
    r.box(fn(col) {
      @sf.style_node(col, fn() { mine_column })
      // (what it quotes ahead of its files and words, in the order the composer held them: mine_message's; its place
      // the row's as it was made, what was sent from here its key's: the row's own, which the core's row that takes it
      // over is told as too (sfbase's thumb_occurrence, by rows_sent_as), so its thumbnails and a preview opened from
      // the chat's message name one place; the chat's from the first, the message's it is now, taken for another row's:
      // that one's)
      let made_out = if @signals.untracked(said) { None } else { Some(@signals.untracked(key)) }
      let at = fn() {
        match made_out {
          Some(k) => k
          None => message_place(m())
        }
      }
      // (sent from here a moment ago: each of its files flying from where it stood in the composer, as its words do:
      // sfbase's sent_part_take, by its row's key)
      let flies_of = fn(part : String) { @sfbase.sent_part_take(@signals.untracked(key), part) }
      // (a right click on any of it offered once it is the chat's, by the message it is then: its words' bubble, and
      // where it has none, its pictures, files or film alone; what of it offers its own (a file's card) its own)
      match share {
        Some(s) =>
          col.on_menu(fn(e) {
            if said() {
              @sfbase.share_offer(e.wx, e.wy, s.go, @signals.untracked(s.link), @signals.untracked(s.words), (s.key)())
            }
          })
          |> ignore
        None => ()
      }
      message_quotes_node(col, src, here, fn() { m().quotes }, fn() { m().attachments }, true, at, said=fn() { m().said }, shared_ids=quote_ids, flies_of~, fly~)
      message_files_node(
        col,
        src,
        here.tips,
        // (once it is the chat's, by the message it is then)
        message_files_at(here, fn() { m().said }, share=fn() { if said() { share } else { None } }),
        fn() {
          let now = m()
          beside_quotes(now.quotes, now.attachments)
        },
        fn() { true },
        fn() { if said() { Some((@sf.t("web-main.chat.you"), "person", m().ts)) } else { None } },
        fn() { at() + "/f" },
        flies_of~,
        fly~,
      )
      // (on its way, its other files still going up: how far, or why it did not go)
      if !@signals.untracked(said) {
        outbox_uploads_node(col, here, out)
      }
      col.show(fn() { m().text != "" }, fn(b) {
        // (what is read in it starts here, its bubble's words: View::read_from)
        b.read_from() |> ignore
        // (and what is picked of it is of its key, its bubble's words alone: quoted by it, all of them taken by 全选,
        // chat_quote_node)
        picked_of_by(b, key)
        let cards = message_link_card(src, here.station, fn() { "" }, m)
        mine_bubble_node(
          b,
          here,
          m,
          fn() { if said() { found() } else { [] } },
          fn() { if said() { found_at() } else { None } },
          lit=fn() { if said() { lit() } else { ("", 0L) } },
          cards=(here.tips, fn(l) { if said() { cards(l) } else { None } }),
          // (made as it was sent, flying from the field; made later (its words come once a quote alone was sent): in its
          // row, no second flight from where the field was then, as its "under" has it)
          flies_from=if b.cause_at() == made_at { flies_from } else { None },
          words_room=if b.cause_at() == made_at { words_room } else { None },
          fly~,
        )
      })
      // (on its way a while: sending_shows_ms from when it was sent (`since`), the moment its 正在发送 may stand in for
      // its time; due on the frames' clock, never read of the source's as it is drawn. Only while it is still going:
      // sent, failed or said by the core, nothing is due for it, the moment called off)
      let late = if @signals.untracked(said) {
        fn() { false }
      } else {
        @sf.waited_past_node(r, since, sending_shows_ms, going=fn() {
          !said() &&
          (match out() {
            Some(o) => o.state != "sent" && o.state != "failed"
            None => false
          })
        })
      }
      let under = fn() {
        match out() {
          Some(o) => outbox_mine_under(o, late())
          None => mine_under(m())
        }
      }
      // (nothing under it at all while it is followed, but what did not go: no box of nothing in its column, its gap
      // with it. There and gone at once, apart from the pick of what is under it: it goes in the frame the key after it
      // comes, which sets out from as tall as that gives back (the list's), where one of its states in another's place
      // leaves: what it showed fading where it is, what it shows now seen once its place holds it whole, its place
      // making its way between, no words of either cut by it (msg_part_leave_ms))
      let lone = fn() {
        match out() {
          Some(o) => o.state == "failed" || o.held || !o.followed
          None => !m().followed
        }
      }
      col.show(at_once=true, lone, fn(n) {
        // (what is under it, where it flies here from the composer: coming in as what leads it goes across (its words,
        // else its first file or quote: SentFly's `lead`), on their flight's own way from its own cause (the old page's
        // flight_settled, the desktop's: flight_across), whole as they land; at once otherwise. One curve, one length,
        // one clock: never a fade of its own after it)
        if fly.lead != "" && !under_flew.val && n.cause_at() == made_at {
          under_flew.val = true
          let sent_at = n.cause_at()
          if has_parts {
            // (with files or quotes, the composer's ground starts tall and shrinks down as they fly out of it: unseen
            // until the lead lands above the composer, then eased in within move_most_ms, as mine_time_flight's)
            n.alpha(By(fn() {
              if n.drawn_while(fn(now) { now <= sent_at }) <= sent_at {
                return 0.0
              }
              match flight_ends.get() {
                Some(e) => {
                  let finish = @sf.dmin(e + @sf.enter_ms, @sf.dmax(e + 60.0, sent_at + @ui.move_most_ms))
                  let t = n.drawn_while(fn(now) { now < finish })
                  if t <= e {
                    0.0
                  } else if t >= finish {
                    1.0
                  } else {
                    let u = (t - e) / (finish - e)
                    1.0 - (1.0 - u) * (1.0 - u)
                  }
                }
                None =>
                  match lead_view.get() {
                    Some(b) if b.flying_now() => 0.0
                    _ => 1.0
                  }
              }
            }))
            |> ignore
          } else {
            // (the moment it is sent: its lead not on its way yet as that moment's frame is drawn, where its flight is
            // still 0 of the way across, so nothing under it seen then; read by the clock till that moment is gone;
            // lifted strictly vertically under its rising lead (`from.0 == to.0`) so it stays under its bubble uncut by
            // the row's clip and never shifts across)
            // (from within the list to within it: drawn among its rows, under its foot and what flies from that foot)
            fly.flies_in(
              n,
              "under",
              fn(to) {
                let dy = lead_dy.val
                if dy > 0.5 {
                  Some((to.0, to.1 + dy, to.2, to.3))
                } else {
                  None
                }
              },
              in_list=true,
            )
            // (on its way under its lead, said of its chat as its lead is: words sent after them in that while land it
            // with its lead, sent_in_field_land, never its lead landed and this left on its way, seen whole)
            if flies_from is Some(_) {
              let chat = here.station + "\u{1}" + here.session
              let held = sent_in_field.get(chat).unwrap_or([])
              held.push((made_at + @sfbase.sent_out_away_ms(), n))
              sent_in_field[chat] = held
              n.owns(fn() { sent_in_field_drop(chat, n) }) |> ignore
            }
            n.alpha(By(fn() {
              if n.drawn_while(fn(now) { now <= sent_at }) <= sent_at {
                return 0.0
              }
              match lead_view.get() {
                Some(b) => b.flight_across_now()
                None => 1.0
              }
            }))
            |> ignore
          }
        }
        let under_leave = if !@signals.untracked(said) || @signals.untracked(under) != MineTime {
          msg_part_leave_ms
        } else {
          0.0
        }
        if under_leave > 0.0 {
          let was_under = Ref(@signals.untracked(under))
          n.reacts(under, at_start=false, fn(now) {
            let before = was_under.val
            was_under.val = now
            if (now == MineUnsent || before == MineUnsent) &&
              now != before &&
              !@view.answering_now() &&
              @signals.untracked(@ui.app_visible) {
              @view.transition(within=n.transitions_root(), fn() {  })
            }
          })
        }
        n.pick(under, leave=under_leave, fn(u, now) {
          match now {
            MineBlocked =>
              blocked_line_node(u, src, here.tips, fn() { here.station }, fn() {
                // (as it is while it is: what took its place is made once it is not)
                m().blocked.unwrap_or(mine_installed)
              })
              |> ignore
            MineWaiting => agent_waiting_node(u) |> ignore
            MineTime =>
              message_time_node(u, here.tips, fn() {
                match out() {
                  Some(o) => o.time
                  None => m().time
                }
              })
            MineSending =>
              sending_line_node(
                u,
                fn() {
                  match out() {
                    Some(o) if o.waits != "" => o.waits
                    _ => @sf.t("web-main.chat.sending")
                  }
                },
                fn() { out().bind(fn(o) { o.progress }) },
                since,
                flying,
                held=fn() { out().map_or(false, fn(o) { o.held }) },
                take_back=fn(b) { outbox_take_back_node(b, src, here, fn() { out().unwrap_or(chat_body_no_out) }) },
              )
              |> ignore
            // (failed at once, as its words fly here: coming in with all that is under them, no way of its own)
            MineUnsent => outbox_unsent_node(u, src, here, fn() { out().unwrap_or(chat_body_no_out) })
          }
        })
      })
    })
    |> ignore
  })
}

///|
/// What is under the viewer's message while anything is (mine_message's; nothing while it is followed, which its row
/// says apart: mine_said_node's `lone`): the runtime it waits for, that its agents have yet to take it, its time; on
/// its way (outbox_row's), 正在发送, or what did not go.
#derive(Eq)
priv enum MineUnder {
  MineBlocked
  MineWaiting
  MineTime
  MineSending
  MineUnsent
}

///|
/// What is under the viewer's message `m` now, where anything is (mine_message's order).
fn mine_under(m : Message) -> MineUnder {
  match m.blocked {
    Some(b) if b.state != "installed" => MineBlocked
    _ => if m.waiting { MineWaiting } else { MineTime }
  }
}

///|
/// A runtime as it is once installed: what blocked_line_node reads where its message's has just gone, nothing drawn
/// by it then.
// kept across runs: a value (no field of it changes)
let mine_installed : Install = {
  runtime: "",
  state: "installed",
  title: "",
  note: "",
  action: "",
  percent: None,
  detail: "",
}

///|
/// What someone else wrote as a person (others_message's with person_words: no Markdown) in its row's room
/// (message_row_frame_node: `key`, its list's Entry::id; `side`, `top`; `over`), as `m` says it as it changes: their
/// picture out in the margin (inline: over the head's start), their name (one of the chat's agents' opens its history,
/// another chat's that chat), its time, their words under them; where it offers itself (`share`: in a chat's list), its
/// ⋯ and a right click's offer (message_others_node's), the row saying whether its ⋯'s menu is open.
// the chat's page as nodes: held by its tests, not used by the app yet
#warnings("-unused_value")
fn person_said_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  key : () -> String,
  side : () -> Double,
  top : () -> Double,
  m : () -> Message,
  found? : () -> Array[String] = fn() { [] },
  found_at? : () -> Int? = fn() { None },
  lit? : () -> (String, Int64) = fn() { ("", 0L) },
  share? : MessageShare? = None,
  stick_top? : () -> Double,
) -> MessageRowNode {
  let menu_on : Ref[() -> Bool] = Ref(fn() { false })
  let row = message_row_frame_node(v, key, side, top, fn(r) {
    let (_, on) = message_others_node(
      r,
      here,
      fn() { m().time },
      fn(av) {
        person_avatar_node(av, src, here, fn() { m().author }, fn() { m().by.name }, fn() { m().by.picture })
      },
      fn(h) {
        // (a person's row, never one of the chat's agents': were it to come to be one, its row is another kind, made
        // again as an agent's: chat_body_node's pick by its kind)
        message_name_node(h, src, here, fn() { m().by.name }, fn() { "" }, fn() { m().by.from }, may_be_agent=false)
      },
      None,
      fn(b) {
        // (what it quotes ahead of its words, its other files under them, as the old body's)
        let at = fn() { message_place(m()) }
        message_quotes_node(b, src, here, fn() { m().quotes }, fn() { m().attachments }, false, at, said=fn() { m().said })
        b.show(fn() { m().text != "" }, fn(w) {
          // (what is read in it starts here, its words under its head line: View::read_from)
          w.read_from() |> ignore
          // (and what is picked of it is of its key, its words alone, not its head line: quoted by it, all of them
          // taken by 全选, chat_quote_node)
          picked_of_by(w, key)
          person_words_node(w, m, found~, found_at~, lit~, cards=(here.tips, message_link_card(src, here.station, fn() { "" }, m))) |> ignore
        })
        message_files_node(
          b,
          src,
          here.tips,
          message_files_at(here, fn() { m().said }, share=fn() { share }),
          fn() {
            let now = m()
            beside_quotes(now.quotes, now.attachments)
          },
          fn() { false },
          fn() { Some((m().by.name, "person", m().ts)) },
          fn() { at() + "/f" },
          over=fn() { if m().text != "" { files_under_words - msg_gap } else { 0.0 } },
        )
      },
      share~,
      stick_top?,
    )
    menu_on.val = on
  })
  { ..row, menu_on: menu_on.val }
}

///|
/// What a message in a chat's list offers of itself (others_message's `share` as message_row gives it): its key
/// (`m:<ts>`), its link, its words, its turn's picture shared from the chat's thread.
// the chat's page as nodes: held by its tests, not used by the app yet
#warnings("-unused_value")
fn message_share_of(src : Source, here : MessageNodeHere, m : () -> Message) -> MessageShare? {
  match (here.view)().thread {
    Some(thread) =>
      Some({
        key: fn() { "m:" + m().ts },
        link: fn() { @sfbase.message_link(here.station, here.session, m().seq) },
        words: fn() { m().text },
        go: fn() { open_publish(src, message_node_ref(here), thread, picked=Some(@signals.untracked(m).seq)) },
      })
    None => None
  }
}

///|
/// Where a message's files are (MessageFilesAt) in the chat `here` is: its station, its session, its view as it
/// changes; whether the message was said while the chat shows (`said`); what it offers of itself as it is now (`share`).
fn message_files_at(here : MessageNodeHere, said : () -> Bool, share? : () -> MessageShare? = fn() { None }) -> MessageFilesAt {
  { station: fn() { here.station }, session: fn() { here.session }, view: here.view, said, picture: here.picture, share }
}

///|
/// How much of their flight words sent rise after setting out across (sfbase's flight_up: 12% late).
let sent_up_late : Double = 0.12

///|
/// What was sent from here flying in, all of it as one (mine_said_node's; the old page's flight, one clock for a send:
/// flight.mbt's flight_target_key): on one flight (`flight`, sent_flight's, its delay and all), each part's way as long
/// as its place is far from where it rests (sent_far: never by how its size changes), the part keyed `lead` leading:
/// its way, as long as it goes, the way of every part and of its list's rise (View::flies_in's `lead`), its node told
/// `led` as it is made, for what is under it to come in on (sent_lead says which; "" none: nothing flies).
priv struct SentFly {
  flight : @view.Flight
  lead : String
  led : (@view.View) -> Unit
  dy_told : (Double) -> Unit
}

///|
/// What is sent from here flying alone, at once as it is sent, leading nothing (sent_part_flight's): what is no part of
/// a send said whole.
// kept across runs: a value, no field of it changes
let sent_fly_alone : SentFly = { flight: sent_part_flight, lead: "", led: fn(_) {  }, dy_told: fn(_) {  } }

///|
/// Words sent's part of what flies (SentFly's keys: else a quote's card, sent_quote_part; a file or a quote's own
/// picture, by its key in the row, as sfbase's sent_part_take has it).
let sent_words_part : String = "words"

///|
/// Quote `i`'s card's part of what flies (SentFly's keys).
fn sent_quote_part(i : Int) -> String {
  "q:" + i.to_string()
}

///|
/// Which part of what was sent leads its flight (SentFly's `lead`), the old page's flight_target_key: its words where
/// they fly (`words`); else the first of its files that flies (`parts`, as the composer held them: sfbase's
/// sent_parts_flying); else its first quote's card that does (`quotes`, whether each flies); else a quote's own picture;
/// "" where none flies.
fn sent_lead(words : Bool, parts : Array[String], quotes : Array[Bool]) -> String {
  if words {
    return sent_words_part
  }
  match parts.search_by(fn(p) { !@sfbase.is_quote_picture_key(p) }) {
    Some(i) => return parts[i]
    None => ()
  }
  match quotes.search_by(fn(q) { q }) {
    Some(i) => return sent_quote_part(i)
    None => ()
  }
  parts.get(0).unwrap_or("")
}

///|
/// Part `part` of what was sent (SentFly's keys) flying into `v` from where `from` says, given where it rests
/// (View::flies_in), with the rest of the send: on its flight, as long as its place is far (sent_far), led by its lead,
/// its rise `up_late` late (sent_up_late); `bare_from` as View::flies_in's.
fn SentFly::flies_in(
  self : SentFly,
  v : @view.View,
  part : String,
  from : ((Double, Double, Double, Double)) -> (Double, Double, Double, Double)?,
  up_late? : Double = sent_up_late,
  bare_from? : Bool = false,
  in_list? : Bool = false,
  cut_from? : ((Double, Double, Double, Double)) -> (Double, Double, Double, Double)?,
  container? : Bool = false,
  particle? : Bool = false,
) -> Unit {
  let lead = part == self.lead
  let from_fn = if lead {
    fn(to : (Double, Double, Double, Double)) {
      let r = from(to)
      match r {
        Some(f) => (self.dy_told)(f.1 - to.1)
        None => (self.dy_told)(0.0)
      }
      r
    }
  } else {
    from
  }
  v.flies_in(self.flight, from_fn, up_late~, bare_from~, far_of=sent_far, lead~, in_list~, cut_from?=cut_from, container~, particle~) |> ignore
  if lead {
    (self.led)(v)
  }
}

///|
/// Part `part` of what was sent (SentFly's keys) made as `v`, flying from the composer's that was shared by `id` as one
/// box (mbui's View::shared, `container`: a quote's card from the composer's), with the rest of the send: on its flight,
/// as long as its place is far (sent_far), led by its lead, its rise sent_up_late late.
fn SentFly::shares(self : SentFly, v : @view.View, part : String, id : String, particle? : Bool = false) -> Unit {
  let lead = part == self.lead
  v.shared(Is(id), self.flight, container=true, up_late=sent_up_late, far_of=sent_far, lead~, particle~) |> ignore
  if lead {
    (self.led)(v)
  }
}

///|
/// How a picture sent from here flies in as part `part` of what was sent (`fly`), from where it stood (`from`; None
/// where it was not made in the change it was sent in: there as it is): image_reveal_node's `flies`.
fn sent_flies(fly : SentFly, part : String, from : (Double, Double, Double, Double)?) -> ((@view.View) -> Unit)? {
  from.map(fn(r) { fn(v : @view.View) { fly.flies_in(v, part, fn(_) { Some(r) }, particle=true) } })
}

///|
/// How far what is sent from here goes, from where it stood (`from`) to where it rests (`to`), both in the window: the
/// farther of across and down between their places, its size changing nothing of it (the old page's flight_start's).
fn sent_far(from : (Double, Double, Double, Double), to : (Double, Double, Double, Double)) -> Double {
  @sf.dmax((from.0 - to.0).abs(), (from.1 - to.1).abs())
}

///|
/// The way what is sent from here flies from where it stood in the composer to its place in its message (its words, and
/// each of its files and quotes): the old page's, the desktop's flight every composer sends with (composer.mbt's
/// flight_start, `desk`), as long as it is far up to `flight_desk_ms`, across first on the flight's ease, up
/// sent_up_late late (flight_across, flight_up), setting out `delay` after it was sent; sf/motion.mbt kind 4.
fn sent_flight(delay : Double) -> @view.Flight {
  // det-ok(motion-length): words sent's own, the old page's flight by how far (sfbase's flight_way_ms), kind 4
  @motion.flight_scaled(sent_far_ms, ease=Flight, delay~)
}

///|
/// What is sent from here flying at once as it is sent (sent_flight's): what has no delay of its own to say.
// kept across runs: a function of how far it goes, nothing of its own
let sent_part_flight : @view.Flight = sent_flight(0.0)

///|
/// How long what is sent from here takes over a way `far` points long (sent_flight's): none where it goes nowhere,
/// capped at `flight_desk_ms` so every send lands within the desktop flight's budget.
fn sent_far_ms(far : Double) -> Double {
  if far <= 0.5 {
    0.0
  } else {
    @sf.dmin(@sfbase.flight_way_ms(true, far), @sfbase.flight_desk_ms)
  }
}

///|
/// The leads of words sent from each chat's composer (by its station and session) on their flight, each with when it
/// is out of the field it set out from (sfbase's sent_out_away_ms after it was sent): mine_said_node's.
// kept across runs: put back by sent_in_field_reset
let sent_in_field : Map[String, Array[(Double, @view.View)]] = Map([])

///|
fn sent_in_field_reset() -> Unit {
  sent_in_field.clear()
}

///|
/// Lead `b` of chat `chat`'s words gone: none of them any more.
fn sent_in_field_drop(chat : String, b : @view.View) -> Unit {
  guard sent_in_field.get(chat) is Some(held) else { return }
  let kept = held.filter(fn(e) { !physical_equal(e.1, b) && e.1.alive() })
  if kept.is_empty() {
    sent_in_field.remove(chat)
  } else {
    sent_in_field[chat] = kept
  }
}

///|
/// Words sent from chat `chat`'s composer now (the moment of the cause that sends them): those sent before them still
/// in the field they set out from (out of it after now) landed in their row first, never left there under these
/// (words_over); those out of it already go on on their way.
fn sent_in_field_land(chat : String) -> Unit {
  guard sent_in_field.get(chat) is Some(held) else { return }
  let kept = []
  for e in held {
    let (out_at, b) = e
    guard b.alive() else { continue }
    if out_at > b.cause_at() {
      b.flight_land()
    } else {
      kept.push(e)
    }
  }
  if kept.is_empty() {
    sent_in_field.remove(chat)
  } else {
    sent_in_field[chat] = kept
  }
}
