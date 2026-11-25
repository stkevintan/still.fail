// How text is set on a device (`prefs.typography`, src/prefs.ts typographyOf): kept only as chosen, whole as it goes
// out; text's CJK size and weight follow ui's while text's CJK face does, until chosen; what is not a setting's refused.
import assert from "node:assert/strict";
import { test } from "node:test";
import { answers, apply, call, subscribe, v } from "./helpers.ts";
import { started } from "./station-fixture.ts";
import { typographyOf } from "../src/prefs.ts";

const DEFAULTS = { textSize: 100, codeScale: 100, lineHeight: "normal", uiCjkScale: 100, textCjkScale: 100, textCjkScaleOwn: false, codeCjkScale: 100, uiCjkWeight: 0, textCjkWeight: 0, textCjkWeightOwn: false, codeCjkWeight: 0, cjkAutoSpace: true, codeLigatures: true };

async function opened() {
  const s = await started();
  const ui = s.core.connect();
  subscribe(s.core, ui, 1, { topic: "prefs" });
  await s.host.settle();
  const values = new Map();
  apply(s.host, values);
  let id = 10;
  /// `prefs.set` with `params`: its answer (and the prefs as they go out after it, in `values`).
  const set = async (params: unknown) => {
    const at = id++;
    call(s.core, ui, at, "prefs.set", params);
    await s.host.settle();
    const emitted = s.host.takeEmitted();
    const answer = answers(emitted, at);
    s.host.emitted.push(...emitted);
    apply(s.host, values);
    return answer;
  };
  return { s, set, prefs: () => v(values, 1), kept: () => s.core.inner.data.get({ topic: "prefs" }) as Record<string, any> };
}

test("typography goes out whole, its defaults where nothing is kept, and is kept only as chosen", async () => {
  const { s, set, prefs, kept } = await opened();
  assert.deepEqual(prefs().typography, DEFAULTS);
  assert.equal(kept()?.typography, undefined);

  assert.ok("ok" in (await set({ typography: { textSize: 115, lineHeight: "relaxed", codeLigatures: false } }))!);
  assert.deepEqual(prefs().typography, { ...DEFAULTS, textSize: 115, lineHeight: "relaxed", codeLigatures: false });
  assert.deepEqual(kept().typography, { codeLigatures: false, lineHeight: "relaxed", textSize: 115 });

  // One setting at a time; null takes it back to its default, never a null kept.
  assert.ok("ok" in (await set({ typography: { textSize: null, codeScale: 90 } }))!);
  assert.deepEqual(kept().typography, { codeLigatures: false, lineHeight: "relaxed", codeScale: 90 });
  assert.ok(Object.values(kept().typography).every((x) => x !== null));
  // A default chosen is kept as chosen.
  assert.ok("ok" in (await set({ typography: { codeLigatures: true } }))!);
  assert.equal(kept().typography.codeLigatures, true);

  // Each back to its default: nothing kept.
  assert.ok("ok" in (await set({ typography: { codeLigatures: null, lineHeight: null, codeScale: null } }))!);
  assert.equal("typography" in kept(), false);
  assert.deepEqual(prefs().typography, DEFAULTS);
  // null for the whole of it: the same.
  await set({ typography: { textSize: 85 } });
  assert.ok("ok" in (await set({ typography: null }))!);
  assert.equal("typography" in kept(), false);
  s.core.close();
});

test("text's CJK size and weight follow ui's while text's CJK face is ui's, until chosen (100 too); null follows again", async () => {
  const { s, set, prefs, kept } = await opened();
  const text = () => [prefs().typography.textCjkScale, prefs().typography.textCjkWeight];
  await set({ fonts: { uiCjk: "lxgw-wenkai" }, typography: { uiCjkScale: 115, uiCjkWeight: -100 } });
  assert.deepEqual(text(), [115, -100]);
  assert.deepEqual(kept().typography, { uiCjkScale: 115, uiCjkWeight: -100 });

  // 100 chosen for text's over ui's 115: kept, and so it goes out; textCjkScaleOwn/WeightOwn stay true even if ui later matches 100/0.
  await set({ typography: { textCjkScale: 100, textCjkWeight: 0 } });
  assert.deepEqual(text(), [100, 0]);
  assert.equal(prefs().typography.textCjkScaleOwn, true);
  assert.equal(prefs().typography.textCjkWeightOwn, true);
  assert.deepEqual(kept().typography, { textCjkScale: 100, textCjkWeight: 0, uiCjkScale: 115, uiCjkWeight: -100 });
  // ui's changed to 100/0 (matching text's explicit 100/0): textCjkScaleOwn/WeightOwn remain true.
  await set({ typography: { uiCjkScale: 100, uiCjkWeight: 0 } });
  assert.equal(prefs().typography.textCjkScaleOwn, true);
  assert.equal(prefs().typography.textCjkWeightOwn, true);
  // ui's changed again: text's stays as explicitly chosen.
  await set({ typography: { uiCjkScale: 85, uiCjkWeight: -100 } });
  assert.deepEqual(text(), [100, 0]);
  // Taken back: ui's again, and Own flags return to false.
  await set({ typography: { textCjkScale: null, textCjkWeight: null } });
  assert.deepEqual(text(), [85, -100]);
  assert.equal(prefs().typography.textCjkScaleOwn, false);
  assert.equal(prefs().typography.textCjkWeightOwn, false);

  // Text's own CJK face, or `none`, or no CJK face of ui's: its own, the defaults where none chosen.
  for (const fonts of [{ textCjk: "noto-serif-sc" }, { textCjk: "none" }, { textCjk: null, uiCjk: null }]) {
    await set({ fonts });
    assert.deepEqual(text(), [100, 0], JSON.stringify(fonts));
  }
  // ui's CJK face chosen again: followed again.
  await set({ fonts: { uiCjk: "local:PingFang SC" } });
  assert.deepEqual(text(), [85, -100]);
  s.core.close();
});

test("a setting not there, out of its range, off its step, or not one of its words is refused, nothing changed", async () => {
  const { s, set, prefs, kept } = await opened();
  await set({ typography: { textSize: 110 } });
  const bad: Record<string, unknown>[] = [
    { textSize: 80 }, { textSize: 135 }, { textSize: 102 }, { textSize: 102.5 }, { textSize: "110" },
    { codeScale: 115 }, { codeScale: 84 }, { uiCjkScale: 120 }, { textCjkScale: 87 }, { codeCjkScale: 80 },
    { uiCjkWeight: 50 }, { textCjkWeight: 200 }, { codeCjkWeight: "100" },
    { lineHeight: "loose" }, { lineHeight: 1.5 },
    { cjkAutoSpace: "on" }, { codeLigatures: 1 },
    { fontSize: 100 }, { fontSize: null },
    { constructor: 1 }, { toString: "x" }, { constructor: null }, { toString: null },
  ];
  for (const typography of bad) {
    const answer = await set({ typography });
    assert.ok(answer && "error" in answer, JSON.stringify(typography));
    assert.match(JSON.stringify(answer), /typography\./, JSON.stringify(typography));
  }
  for (const typography of ["compact", 100, true, [1]]) {
    const answer = await set({ typography });
    assert.ok(answer && "error" in answer, JSON.stringify(typography));
  }
  assert.deepEqual(kept().typography, { textSize: 110 });
  assert.deepEqual(prefs().typography, { ...DEFAULTS, textSize: 110 });
  // Stored prefs containing prototype property names must not throw and are ignored.
  assert.deepEqual(typographyOf({ constructor: 1, toString: "x", textSize: 110 }, undefined), { ...DEFAULTS, textSize: 110 });

  // Every value each can be: kept.
  const good: Record<string, unknown[]> = {
    textSize: [85, 90, 95, 100, 105, 110, 115, 120, 125, 130], codeScale: [85, 90, 95, 100, 105, 110],
    uiCjkScale: [85, 115], textCjkScale: [85, 115], codeCjkScale: [85, 115],
    uiCjkWeight: [-100, 0, 100], textCjkWeight: [-100, 0, 100], codeCjkWeight: [-100, 0, 100],
    lineHeight: ["compact", "normal", "relaxed"], cjkAutoSpace: [true, false], codeLigatures: [true, false],
  };
  for (const [key, values] of Object.entries(good)) {
    for (const x of values) {
      const answer = await set({ typography: { [key]: x } });
      assert.ok(answer && "ok" in answer, `${key} ${x}`);
      assert.equal(prefs().typography[key], x);
    }
  }
  s.core.close();
});
