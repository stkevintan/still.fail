// The faces a device's pages are set in (src/fonts.ts, sf/faces.mbt): each place's as chosen, whole as it goes out,
// text as ui's until it is chosen, one installed on the device by its family; a face not there refused.
import assert from "node:assert/strict";
import { test } from "node:test";
import { apply as applyOps } from "../src/delta.ts";
import { answers, apply, call, subscribe, v } from "./helpers.ts";
import { started } from "./station-fixture.ts";

test("each place's face is as chosen, whole as it goes out; text is ui's until chosen; one not there is refused", async () => {
  const { host, core } = await started();
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "prefs" });
  await host.settle();
  const values = new Map();
  apply(host, values);
  let faces = v(values, 1).faces;
  // None chosen: the app's own everywhere.
  assert.deepEqual([faces.ui.id, faces.text.id, faces.code.id], ["", "", ""]);
  assert.equal(faces.code.mono, true);
  assert.deepEqual(faces.list.map((f: any) => f.id), ["inter", "noto-sans-sc", "noto-serif-sc", "lxgw-wenkai", "jetbrains-mono", "fira-code", "maple-mono"]);
  assert.deepEqual(faces.list.filter((f: any) => f.mono).map((f: any) => f.id), ["jetbrains-mono", "fira-code", "maple-mono"]);

  call(core, ui, 2, "prefs.set", { fonts: { ui: "noto-sans-sc", code: "local:Berkeley Mono" } });
  await host.settle();
  apply(host, values);
  const prefs = v(values, 1);
  faces = prefs.faces;
  assert.deepEqual(prefs.fonts, { ui: "noto-sans-sc", code: "local:Berkeley Mono" });
  assert.equal(faces.ui.name, "思源黑体");
  assert.equal(faces.ui.family, "SF Noto Sans SC");
  assert.match(faces.ui.css, /\/releases\/fonts\/noto-sans-sc\/2\.004\/font\.css$/);
  assert.equal(faces.ui.files.length, 1);
  assert.match(faces.ui.files[0].url, /\/releases\/fonts\/noto-sans-sc\/2\.004\/var\.ttf\.gz$/);
  assert.equal(faces.ui.bytes, faces.ui.files[0].bytes);
  // Its preview (the fonts page's characters alone), beside its files.
  assert.match(faces.ui.preview, /\/releases\/fonts\/noto-sans-sc\/2\.004\/preview-[0-9a-f]{8}\.ttf$/);
  // Text not chosen: as ui.
  assert.deepEqual(faces.text, faces.ui);
  assert.deepEqual([faces.code.id, faces.code.family, faces.code.files, faces.code.css], ["local:Berkeley Mono", "Berkeley Mono", [], undefined]);

  // One place at a time: the others stay; null goes back to the app's own.
  call(core, ui, 3, "prefs.set", { fonts: { text: "lxgw-wenkai", code: null } });
  await host.settle();
  apply(host, values);
  faces = v(values, 1).faces;
  assert.deepEqual([faces.ui.id, faces.text.id, faces.code.id], ["noto-sans-sc", "lxgw-wenkai", ""]);
  assert.deepEqual(faces.text.files.map((f: any) => f.weight), [400, 500]);

  // A face not there, or a place not there: refused, nothing changed.
  for (const [id, fonts] of [[4, { ui: "comic-sans" }], [5, { title: "inter" }], [6, { code: "local:" }]] as const) {
    call(core, ui, id, "prefs.set", { fonts });
    await host.settle();
    const answer = answers(host.takeEmitted(), id);
    assert.ok(answer && "error" in answer, JSON.stringify(answer));
  }
  call(core, ui, 7, "prefs.set", { fonts: { ui: null, text: null } });
  await host.settle();
  apply(host, values);
  assert.deepEqual(v(values, 1).fonts, {});
  assert.deepEqual(v(values, 1).faces.ui.id, "");
  core.close();
});

test("a place's face says where this device keeps each of its files, so the app reads them there as it starts", async () => {
  const kept = new Set<string>();
  const { host, core } = await started(undefined, 0, undefined, (s) => {
    s.host.storagePath = (key) => (kept.has(key) ? `/data/${key}` : null);
  });
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "prefs" });
  call(core, ui, 2, "prefs.set", { fonts: { text: "lxgw-wenkai" } });
  await host.settle();
  const values = new Map();
  apply(host, values);
  // none kept yet: no path
  assert.deepEqual(v(values, 1).faces.text.files.map((f: any) => f.path), [undefined, undefined]);
  // kept (an earlier run's): each file where it is, the faces not chosen saying none
  const [a, b] = v(values, 1).faces.text.files.map((f: any) => f.sha256);
  kept.add(`fonts/file/${a}`);
  kept.add(`fonts/file/${b}`);
  call(core, ui, 3, "prefs.set", { fonts: { text: "lxgw-wenkai", ui: "inter" } });
  await host.settle();
  apply(host, values);
  const faces = v(values, 1).faces;
  assert.deepEqual(faces.text.files.map((f: any) => f.path), [`/data/fonts/file/${a}`, `/data/fonts/file/${b}`]);
  assert.deepEqual(faces.ui.files.map((f: any) => f.path), [undefined]);
  assert.ok(faces.list.every((f: any) => f.files.every((x: any) => x.path === undefined)));
  core.close();
});

/// Sets `fonts` whole (each of the six slots, null where none) and gives back the prefs as they go out.
async function chosenAll(s: Awaited<ReturnType<typeof started>>, values: Map<number, unknown>, id: number, fonts: Record<string, string | null>, typography: Record<string, unknown> | null = null): Promise<any> {
  const ui = 1;
  const whole = { ui: null, text: null, code: null, uiCjk: null, textCjk: null, codeCjk: null, ...fonts };
  call(s.core, ui, id, "prefs.set", typography === null ? { fonts: whole } : { fonts: whole, typography });
  await s.host.settle();
  const emitted = s.host.takeEmitted();
  const answer = answers(emitted, id);
  assert.ok(answer && "ok" in answer, JSON.stringify(answer));
  for (const [, m] of emitted) {
    const msg = m as Record<string, unknown>;
    if ("value" in msg) values.set(msg.id as number, msg.value);
    else if ("delta" in msg) values.set(msg.id as number, applyOps(values.get(msg.id as number), msg.delta as never));
  }
  return v(values, 1);
}

// The thirteen rows of the design's table (design-spec-v3 1.1): each place's own face and the face its CJK characters
// are set in, and whose size and weight those take, with ui's CJK face 115% and a step heavier where it is chosen.
const ROWS: { row: number; fonts: Record<string, string>; ui?: [string, string]; text?: [string, string]; code?: [string, string]; textScale?: [number, number] }[] = [
  { row: 1, fonts: {}, ui: ["", ""] },
  { row: 2, fonts: { ui: "lxgw-wenkai" }, ui: ["lxgw-wenkai", ""] },
  { row: 3, fonts: { uiCjk: "lxgw-wenkai" }, ui: ["", "lxgw-wenkai"] },
  { row: 4, fonts: { ui: "lxgw-wenkai", uiCjk: "noto-serif-sc" }, ui: ["lxgw-wenkai", "noto-serif-sc"] },
  { row: 5, fonts: { uiCjk: "noto-sans-sc" }, text: ["", "noto-sans-sc"], textScale: [115, 100] },
  { row: 6, fonts: { uiCjk: "noto-sans-sc", textCjk: "lxgw-wenkai" }, text: ["", "lxgw-wenkai"], textScale: [100, 0] },
  { row: 7, fonts: { uiCjk: "noto-sans-sc", textCjk: "none" }, text: ["", ""], textScale: [100, 0] },
  { row: 8, fonts: { uiCjk: "noto-sans-sc", text: "local:Georgia" }, text: ["local:Georgia", "noto-sans-sc"], textScale: [115, 100] },
  { row: 8, fonts: { text: "local:Georgia" }, text: ["local:Georgia", ""], textScale: [100, 0] },
  { row: 9, fonts: { text: "lxgw-wenkai" }, text: ["lxgw-wenkai", ""], textScale: [100, 0] },
  { row: 10, fonts: { uiCjk: "noto-sans-sc", text: "lxgw-wenkai", textCjk: "none" }, text: ["lxgw-wenkai", ""], textScale: [100, 0] },
  { row: 11, fonts: {}, code: ["", ""] },
  { row: 12, fonts: { codeCjk: "maple-mono" }, code: ["", "maple-mono"] },
  { row: 13, fonts: { code: "fira-code", codeCjk: "noto-sans-sc" }, code: ["fira-code", "noto-sans-sc"] },
];

test("each place's CJK face is as the design's table says: chosen, text's following ui's, `none` none", async () => {
  const s = await started();
  const ui = s.core.connect();
  assert.equal(ui, 1);
  subscribe(s.core, ui, 1, { topic: "prefs" });
  await s.host.settle();
  const values = new Map<number, unknown>();
  apply(s.host, values);
  let id = 10;
  for (const r of ROWS) {
    const prefs = await chosenAll(s, values, id++, r.fonts, { uiCjkScale: 115, uiCjkWeight: 100 });
    const at = `row ${r.row} ${JSON.stringify(r.fonts)}`;
    const faces = prefs.faces;
    assert.deepEqual(prefs.fonts, r.fonts, at);
    if (r.ui) assert.deepEqual([faces.ui.id, faces.uiCjk], r.ui, at);
    if (r.text) {
      assert.deepEqual([faces.text.id, faces.textCjk], r.text, at);
      // text's own face not chosen: as ui's, whole
      if (!r.fonts.text) assert.deepEqual(faces.text, faces.ui, at);
    }
    if (r.code) assert.deepEqual([faces.code.id, faces.codeCjk], r.code, at);
    if (r.textScale) assert.deepEqual([prefs.typography.textCjkScale, prefs.typography.textCjkWeight], r.textScale, at);
    assert.deepEqual([prefs.typography.uiCjkScale, prefs.typography.uiCjkWeight], [115, 100], at);
  }
  // `none` is text's CJK face's alone.
  for (const slot of ["ui", "uiCjk", "text", "code", "codeCjk"]) {
    call(s.core, ui, id, "prefs.set", { fonts: { [slot]: "none" } });
    await s.host.settle();
    const answer = answers(s.host.takeEmitted(), id++);
    assert.ok(answer && "error" in answer, slot);
  }
  s.core.close();
});

test("fonts kept by an older build read as before: ui's face sets the CJK characters too", async () => {
  const s = await started();
  const ui = s.core.connect();
  subscribe(s.core, ui, 1, { topic: "prefs" });
  call(s.core, ui, 2, "prefs.set", { fonts: { ui: "lxgw-wenkai" } });
  await s.host.settle();
  const values = new Map();
  apply(s.host, values);
  const prefs = v(values, 1);
  assert.deepEqual(prefs.fonts, { ui: "lxgw-wenkai" });
  assert.deepEqual([prefs.faces.ui.id, prefs.faces.text.id, prefs.faces.code.id], ["lxgw-wenkai", "lxgw-wenkai", ""]);
  assert.deepEqual([prefs.faces.uiCjk, prefs.faces.textCjk, prefs.faces.codeCjk, prefs.faces.cjkPaths], ["", "", "", {}]);
  assert.deepEqual(prefs.typography, { textSize: 100, codeScale: 100, lineHeight: "normal", uiCjkScale: 100, textCjkScale: 100, textCjkScaleOwn: false, codeCjkScale: 100, uiCjkWeight: 0, textCjkWeight: 0, textCjkWeightOwn: false, codeCjkWeight: 0, cjkAutoSpace: true, codeLigatures: true });
  assert.ok(prefs.faces.list.every((f: any) => f.hasCjk === ["noto-sans-sc", "noto-serif-sc", "lxgw-wenkai", "maple-mono"].includes(f.id)));
  assert.equal(prefs.faces.ui.hasCjk, true);
  assert.equal(prefs.faces.code.hasCjk, false);
  s.core.close();
});

test("the CJK faces' files kept say where they are once, none a place's face says already, within a topic's bytes", async () => {
  const at = "/data/user/0/fail.still.android/files/stillfail/accounts/7f3c9a2e5b1d4c6e8a0f2b4d6c8e0a1b/storage/";
  const s = await started(undefined, 0, undefined, (st) => {
    st.host.storagePath = (key) => (key.startsWith("fonts/file/") ? `${at}${key}` : null);
  });
  const ui = s.core.connect();
  subscribe(s.core, ui, 1, { topic: "prefs" });
  await s.host.settle();
  const values = new Map<number, unknown>();
  apply(s.host, values);
  const files = (id: string) => (v(values, 1).faces.list.find((f: any) => f.id === id).files as any[]).map((f) => f.sha256 as string);
  const bytes = (m: unknown) => new TextEncoder().encode(JSON.stringify(m)).length;

  // All six slots WenKai: every file a place's face says; none again.
  let prefs = await chosenAll(s, values, 2, { ui: "lxgw-wenkai", text: "lxgw-wenkai", code: "lxgw-wenkai", uiCjk: "lxgw-wenkai", textCjk: "lxgw-wenkai", codeCjk: "lxgw-wenkai" });
  assert.deepEqual([prefs.faces.uiCjk, prefs.faces.textCjk, prefs.faces.codeCjk], ["lxgw-wenkai", "lxgw-wenkai", "lxgw-wenkai"]);
  assert.deepEqual(prefs.faces.ui.files.map((f: any) => f.path), files("lxgw-wenkai").map((h) => `${at}fonts/file/${h}`));
  assert.deepEqual(prefs.faces.cjkPaths, {});
  assert.ok(bytes(prefs) <= 32 * 1024, `${bytes(prefs)} B`);

  // Each place's CJK face its own: each of their files once, by hash.
  prefs = await chosenAll(s, values, 3, { ui: "inter", code: "fira-code", uiCjk: "lxgw-wenkai", textCjk: "noto-serif-sc", codeCjk: "maple-mono" });
  const want = [...files("lxgw-wenkai"), ...files("noto-serif-sc"), ...files("maple-mono")];
  assert.deepEqual(Object.keys(prefs.faces.cjkPaths).sort(), want.slice().sort());
  for (const h of want) assert.equal(prefs.faces.cjkPaths[h], `${at}fonts/file/${h}`);
  assert.ok(bytes(prefs) <= 32 * 1024, `${bytes(prefs)} B`);

  // Text's CJK face the same as ui's own: said by ui's files, not again.
  prefs = await chosenAll(s, values, 4, { ui: "lxgw-wenkai", uiCjk: "lxgw-wenkai", textCjk: "noto-serif-sc" });
  assert.deepEqual(Object.keys(prefs.faces.cjkPaths), files("noto-serif-sc"));

  // A change of one setting goes out as a delta within its bar (4 KB).
  call(s.core, ui, 5, "prefs.set", { typography: { textCjkScale: 110 } });
  await s.host.settle();
  const said = s.host.takeEmitted().map(([, m]) => m as Record<string, unknown>).filter((m) => m.id === 1);
  assert.ok(said.length > 0 && said.every((m) => bytes(m) <= 4 * 1024), said.map(bytes).join(","));
  s.core.close();
});
