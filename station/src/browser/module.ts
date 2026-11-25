// The station's browsers (browser/service.ts) as a part of the station (parts.ts): the agents'
// tool for their chat's, each session's way to it on the agents' door (proxy.ts), and a chat's going with its chat.
// Where config.json names Farview (farview.ts), the tool gives each chat's Farview instead of its Chrome context.
import { join } from "node:path";
import { Effect, Layer } from "effect";
import { Helper, Parts, Paths, ScreenRegistry, StationConfig, Store } from "../services.ts";
import { BrowserAgentHold } from "./agent-hold.ts";
import { browserTools } from "./tool.ts";
import { browserDoor } from "./proxy.ts";
import { Browser } from "./service.ts";
import { FarviewTabs, farviewConfig } from "./farview.ts";
import { setFarviewHelper } from "./farview-screen.ts";
import { readOnly } from "../mesh/credential.ts";
import { pipeTcp, reachLocal } from "../mesh/peer-forward.ts";
import { writeLine } from "../mesh/wire.ts";
import { given } from "../read/views.ts";

export const BrowserLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const parts = yield* Parts;
    const browser = yield* Browser;
    const config = yield* StationConfig;
    const { data } = yield* Paths;
    const screens = yield* ScreenRegistry;
    const store = yield* Store;
    const helper = yield* Helper;
    yield* Effect.acquireRelease(
      Effect.sync(() => {
        browser.useHelper(helper);
        setFarviewHelper(helper);
      }),
      () =>
        Effect.sync(() => {
          browser.useHelper(null);
          setFarviewHelper(null);
        }),
    );
    const hold = yield* Effect.acquireRelease(
      Effect.sync(() => {
        const h = new BrowserAgentHold({
          hub: screens,
          name: (session) => {
            const thread = store.sessionHomeThread(session)?.thread ?? store.recentSessionThreads(session, 1).threads[0]?.thread ?? null;
            const title = (thread ? given(thread) : null) ?? store.getSession(session)?.title?.trim() ?? "";
            return `agent: ${title !== "" ? title : session}`;
          },
        });
        const off = store.subscribe((c) => {
          if (c.type === "session" && store.getSession(c.key)?.running !== true) h.releaseSession(c.key);
          else if (c.type === "sessionRemoved") h.releaseSession(c.key);
        });
        return { h, off };
      }),
      ({ h, off }) => Effect.sync(() => { off(); h.close(); }),
    );
    browser.onAgentAct((session, target, method) => hold.h.act(session, target, method));
    browser.onStopped((session) => hold.h.releaseSession(session));
    const farview = yield* Effect.acquireRelease(
      Effect.sync(() => new FarviewTabs({ dir: join(data, "browser", "farview"), config: () => farviewConfig(config.raw()), screens })),
      (f) => Effect.sync(() => f.close()),
    );
    browser.useFarview(farview);
    // (the chats' tabs an earlier station process left running stay among the screens)
    void farview.resume();
    parts.door(browserDoor(browser));
    // An app that draws a Farview tab itself: carried to the tab's host, its bytes both ways as they are (Farview's own
    // protocol: the page's drawing, fonts and pictures to it, a person's taps and words from it). One who only looks
    // is not carried: nothing tells their input from the rest on the way.
    parts.streams("farview", async ({ viewer, head, stream, reader }) => {
      const refuse = async (status: number, error: string) => {
        await writeLine(stream, { status, headers: { "content-type": "application/json" } });
        await stream.write(Buffer.from(JSON.stringify({ error })));
        await stream.finish();
      };
      if (readOnly(viewer)) return refuse(403, "a read-only member does not drive a tab");
      const id = typeof head.farview?.screen === "string" ? head.farview.screen : "";
      const port = farview.clientPort(id);
      if (port === null) return refuse(404, "no such Farview tab: its chat's browser is not running");
      let socket;
      try {
        socket = await reachLocal(port);
      } catch (error) {
        return refuse(503, `the tab's host does not answer: ${(error as Error).message}`);
      }
      await writeLine(stream, { status: 200, headers: { "content-type": "application/x-farview" } });
      await pipeTcp(socket, stream, reader.carry);
    });
    parts.sessionEnded((session) => {
      void browser.closeOf(session);
      void farview.closeOf(session);
    });
    parts.tools(browserTools(browser, () => parts.doorUrl(), farview));
  }),
);
