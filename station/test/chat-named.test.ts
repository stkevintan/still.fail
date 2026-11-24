// How a chat is named in another chat's words (sessions/messages.ts `chatNamed`): Slack's `<link|title>` only in a Slack
// thread; Markdown in still.fail chats and in Feishu, Comma and group threads, where Slack's form shows as text (FB-47).
import assert from "node:assert/strict";
import { test } from "node:test";
import { chatNamed } from "../src/sessions/messages.ts";
import { commaSurface, feishuSurface, groupSurface, slackSurface, STILLFAIL_SURFACE } from "../src/store/rows.ts";

const LINK = "https://app.still.fail/o/ws/st/fs%3Aoc_g%3Aom_a";

test("a chat's link is Slack's mrkdwn in a Slack thread, its title escaped as Slack reads it", () => {
  for (const surface of [slackSurface("cl", "T1"), slackSurface("cl", null)]) {
    assert.equal(chatNamed(surface, "构建 <a> & b|c", LINK), `<${LINK}|构建 &lt;a&gt; &amp; b/c>`, surface);
  }
});

test("a chat's link is Markdown in still.fail chats and Feishu, Comma and group threads, its title's brackets taken out", () => {
  for (const surface of [STILLFAIL_SURFACE, feishuSurface("fs"), commaSurface("cm"), groupSurface("gp")]) {
    assert.equal(chatNamed(surface, "[安卓] 构建 <a> & b|c", LINK), `[安卓 构建 <a> & b|c](${LINK})`, surface);
  }
});

test("a chat without a link is its title alone, wherever it is said", () => {
  for (const surface of [STILLFAIL_SURFACE, slackSurface("cl", "T1"), feishuSurface("fs"), commaSurface("cm"), groupSurface("gp")]) {
    assert.equal(chatNamed(surface, "安卓构建", null), "安卓构建", surface);
  }
});
