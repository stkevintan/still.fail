// What the browser's host answers as the other hosts do (web/host.js): the keys held (H.modsHeld, @hostapi.mods_held,
// as a key's own modifiers are told: shift 1, control 2, alt 4, command 8), the system's bars round the page said on
// the system's channel as they change (@hostapi.system_said's `bars`), Escape kept from the browser, the page's title,
// colour and history (@webpage.set_title, set_theme_color, location, history_*, history_channel: the app's calls
// `mbui.page.*`), a face's CJK companion (@webpage.set_cjk_face). It holds web/host.js alone, run in Node with as little of a page as it reads: not a real browser's
// order of its events, nor what the app does once told.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

function browser({ deferLoad = false, measureText } = {}) {
  const element = () => ({
    style: {}, listeners: new Map(), attrs: {},
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    dispatch(name, e) { for (const f of this.listeners.get(name) || []) f(e); },
    setAttribute(name, v) { this.attrs[name] = v; },
    appendChild(child) { this.children = [...(this.children || []), child]; },
  });
  const gl = new Proxy({}, { get: (_, name) =>
    name === 'getShaderParameter' || name === 'getProgramParameter' ? () => true : () => ({}) });
  const canvas = { ...element(), width: 0, height: 0, getContext: () => gl,
    getBoundingClientRect: () => ({ width: 800, height: 600, left: 0, top: 0 }) };
  const ime = element();
  const theme = element();
  const body = element();
  // a canvas's 2D context, the fonts it was set to kept (what a style is drawn in: host.js's font)
  const fontsSet = [];
  const ctx2d = { set font(f) { fontsSet.push(f); }, get font() { return fontsSet.at(-1) || ''; },
    measureText: measureText || (() => ({ fontBoundingBoxAscent: 12, fontBoundingBoxDescent: 4, width: 10 })) };
  // the page's fonts and the system's: a FontFace loads where a source of it names one the system has (`installed`)
  const fonts = new Set();
  const installed = new Set();
  const made = [];
  const pending = [];
  class FontFace {
    constructor(family, src, descriptors) {
      Object.assign(this, { family, src, ...descriptors });
      made.push(this);
    }
    load() {
      // (a face's bytes, as the app gives its own: loaded)
      if (typeof this.src !== 'string') {
        if (deferLoad) return new Promise((resolve, reject) => {
          const fn = () => resolve(this);
          fn.reject = () => reject(new Error('load failed'));
          pending.push(fn);
        });
        return Promise.resolve(this);
      }
      const names = [...String(this.src).matchAll(/local\("([^"]+)"\)/g)].map((m) => m[1]);
      if (names.some((n) => installed.has(n))) {
        if (deferLoad) return new Promise((resolve, reject) => {
          const fn = () => resolve(this);
          fn.reject = () => reject(new Error('load failed'));
          pending.push(fn);
        });
        return Promise.resolve(this);
      }
      return Promise.reject(new Error('no such font'));
    }
  }
  const document = { ...element(), title: ' 页面自己的标题 ', body, documentElement: element(), fonts,
    createElement: () => ({ ...element(), getContext: () => ctx2d }),
    getElementById: (id) => id === 'c' ? canvas : ime,
    querySelector: (q) => q === 'meta[name="theme-color"]' ? theme : null };
  // the page's place in its site, and the browser's history over it
  const location = { search: '', pathname: '/', hash: '' };
  const stack = ['/'];
  let at = 0;
  const go = (to) => {
    const u = new URL(to, 'https://page.invalid' + location.pathname);
    location.pathname = u.pathname;
    location.search = u.search;
    location.hash = u.hash;
  };
  const history = {
    pushState(_, __, to) { stack.splice(at + 1); stack.push(to); at++; go(to); },
    replaceState(_, __, to) { stack[at] = to; go(to); },
    back() { if (at > 0) { at--; go(stack[at]); backs++; } },
  };
  let backs = 0;
  // CSS's env(safe-area-inset-*) as the probe's padding reads it
  const insets = { top: 0, right: 0, bottom: 0, left: 0 };
  const visualViewport = { ...element(), scale: 1, height: 600, offsetTop: 0 };
  const timers = [], frames = [];
  const clock = { now: 0 };
  const said = [];
  const win = { ...element(), document, location, history, visualViewport, navigator: { platform: 'MacIntel' }, FontFace,
    URLSearchParams, URL, Intl, queueMicrotask, devicePixelRatio: 1, performance: { now: () => clock.now },
    setTimeout(f, ms) { timers.push([f, ms]); return timers.length; },
    requestAnimationFrame(f) { frames.push(f); return frames.length; },
    getComputedStyle: () => ({ paddingTop: insets.top + 'px', paddingRight: insets.right + 'px',
      paddingBottom: insets.bottom + 'px', paddingLeft: insets.left + 'px' }) };
  win.window = win;
  vm.runInNewContext(source, win, { filename: 'host.js' });
  const H = win.__mbhost;
  H.run('test', (w, h, scale, t) => said.push('frame ' + t), () => {}, () => {}, (code, mods) => said.push(`key ${code} ${mods}`),
    () => {});
  const event = (more) => ({ target: canvas, key: '', code: '', ctrlKey: false, metaKey: false, altKey: false,
    shiftKey: false, isComposing: false, keyCode: 0, defaultPrevented: false,
    preventDefault() { this.defaultPrevented = true; }, ...more });
  const taken = () => {
    const out = [];
    const n = H.postTake();
    for (let i = 0; i < n; i++) out.push([H.postNext(), JSON.parse(H.postJson())]);
    return out;
  };
  return { H, win, document, theme, location, insets, visualViewport, timers, frames, clock, said, event, taken,
    backs: () => backs, fonts, installed, made, pending, fontsSet };
}

const task = () => new Promise((resolve) => setTimeout(resolve, 0));

test('the keys held are what the window\'s last input says, none once it is left', async () => {
  const b = browser();
  await task();
  assert.equal(b.H.modsHeld(), 0);
  b.win.dispatch('pointerdown', b.event({ shiftKey: true }));
  assert.equal(b.H.modsHeld(), 1, 'Shift with a press');
  b.win.dispatch('pointermove', b.event({ shiftKey: true, metaKey: true }));
  assert.equal(b.H.modsHeld(), 1 | 8, 'Command too as the pointer moves');
  b.win.dispatch('keydown', b.event({ key: 'Alt', altKey: true, ctrlKey: true }));
  assert.equal(b.H.modsHeld(), 2 | 4, 'a key down says its own');
  b.win.dispatch('keyup', b.event({ key: 'Alt', ctrlKey: true }));
  assert.equal(b.H.modsHeld(), 2, 'Alt let go');
  b.win.dispatch('wheel', b.event({ ctrlKey: true, shiftKey: true }));
  assert.equal(b.H.modsHeld(), 2 | 1, 'with the wheel');
  b.win.dispatch('pointerup', b.event({}));
  assert.equal(b.H.modsHeld(), 0);
  b.win.dispatch('keydown', b.event({ key: 'Shift', shiftKey: true }));
  b.win.dispatch('blur', {});
  assert.equal(b.H.modsHeld(), 0, 'none once the window is left, its keys going up unseen');
  b.win.dispatch('keydown', b.event({ key: 'Meta', metaKey: true }));
  b.document.dispatch('visibilitychange', {});
  assert.equal(b.H.modsHeld(), 0, 'none once the page is hidden');
});

test('the system\'s bars round the page are said on the system\'s channel as they change, none while none', async () => {
  const b = browser();
  await task();
  // (the page's size measured again for the frame a resize asks for)
  const resized = () => { b.win.dispatch('resize', {}); while (b.frames.length) b.frames.shift()(0); };
  resized();
  assert.deepEqual(b.taken(), [], 'none said while there are none');
  b.insets.top = 47;
  b.insets.bottom = 34;
  resized();
  assert.deepEqual(b.taken(), [['system', { bars: { top: 47, bottom: 34, left: 0, right: 0 } }]]);
  resized();
  assert.deepEqual(b.taken(), [], 'said once, as it changes');
  // turned: the notch at a side
  b.insets.top = 0;
  b.insets.left = 47;
  b.insets.right = 47;
  b.insets.bottom = 21;
  b.win.dispatch('orientationchange', {});
  assert.deepEqual(b.taken(), [['system', { bars: { top: 0, bottom: 21, left: 47, right: 47 } }]]);
  // the soft keyboard up: the app laid out above it, nothing under it the system's
  b.visualViewport.height = 300;
  b.visualViewport.dispatch('resize', {});
  assert.deepEqual(b.taken(), [['system', { bars: { top: 0, bottom: 0, left: 47, right: 47 } }]]);
  b.visualViewport.height = 600;
  b.visualViewport.dispatch('resize', {});
  assert.deepEqual(b.taken(), [['system', { bars: { top: 0, bottom: 21, left: 47, right: 47 } }]]);
});

test('Escape is kept from the browser and told to the app, but not from an input method composing', async () => {
  const b = browser();
  await task();
  b.said.length = 0;
  const e = b.event({ key: 'Escape' });
  b.win.dispatch('keydown', e);
  assert.ok(e.defaultPrevented);
  assert.deepEqual(b.said, ['key 17 0'], 'the app told it');
  b.said.length = 0;
  const composing = b.event({ key: 'Escape', isComposing: true, keyCode: 229 });
  b.win.dispatch('keydown', composing);
  assert.ok(!composing.defaultPrevented, 'the input method\'s, calling its words off');
  assert.deepEqual(b.said, []);
});

test('the page\'s title and colour', async () => {
  const b = browser();
  await task();
  assert.equal(b.document.title, 'test', 'the title it runs with');
  assert.equal(b.H.loadedTitle(), '页面自己的标题', 'the page\'s own, as it loaded');
  b.H.setPageTitle('收件箱 (3)');
  assert.equal(b.document.title, '收件箱 (3)');
  b.H.setThemeColor('#101012');
  assert.equal(b.theme.attrs.content, '#101012');
  assert.equal(b.document.documentElement.style.backgroundColor, '#101012');
  assert.equal(b.document.body.style.backgroundColor, '#101012');
  b.H.setThemeColor('');
  assert.equal(b.theme.attrs.content, '');
});

test('the page\'s history: put on, put in place, and where the browser went by itself said', async () => {
  const b = browser();
  await task();
  assert.equal(b.H.historyLocation(), '/');
  b.H.historyPush('/a?x=1#top');
  assert.equal(b.H.historyLocation(), '/a?x=1#top');
  b.H.historyPush('/b');
  b.H.historyReplace('/c?y=2');
  assert.equal(b.H.historyLocation(), '/c?y=2');
  assert.deepEqual(b.taken(), [], 'what the app put there is not said back');
  b.H.historyBack();
  assert.equal(b.backs(), 1);
  // (the browser tells the page where it came to as it gets there)
  b.win.dispatch('popstate', {});
  assert.deepEqual(b.taken(), [['history', { location: '/a?x=1#top' }]]);
});

// The family a style is drawn in, as the host sets it on its canvas (H.fontMetrics: the font a measure is taken in).
const fontOf = (b, style) => {
  b.H.fontMetrics(16, 400, style, new Float64Array(6));
  return b.fontsSet.at(-1);
};

const CJK_RANGE = 'U+2E80-2FDF, U+3000-303F, U+3040-30FF, U+3100-312F, U+3190-31FF, U+3400-4DBF, U+4E00-9FFF, ' +
  'U+F900-FAFF, U+FE30-FE4F, U+FF00-FFEF, U+20000-2FA1F';

test('a face\'s CJK companion: nine weights, each drawn a step heavier from the system\'s CJK faces, for the CJK marks alone', async () => {
  const b = browser();
  await task();
  b.installed.add('PingFang SC Medium').add('PingFang SC Semibold').add('PingFang SC Regular');
  let asked = 0;
  b.H.requestFrame = () => { asked++; };
  const gen = b.H.atlasGeneration();
  assert.equal(fontOf(b, 0).includes('mbface1'), false, 'no face of its own before');
  assert.equal(b.H.setCjkFace(1, 100, []), true);
  const cjk = b.made.filter((f) => f.family === 'mbface1');
  assert.deepEqual(cjk.map((f) => f.weight), ['100', '200', '300', '400', '500', '600', '700', '800', '900']);
  for (const f of cjk) assert.equal(f.unicodeRange, CJK_RANGE);
  const byWeight = Object.fromEntries(cjk.map((f) => [f.weight, f.src]));
  assert.match(byWeight['400'], /^local\("PingFang SC Medium"\), local\("PingFangSC-Medium"\)/, '400 drawn in 500');
  assert.match(byWeight['500'], /^local\("PingFang SC Semibold"\)/, '500 drawn in 600');
  assert.match(byWeight['300'], /^local\("PingFang SC Regular"\)/, '300 drawn in 400');
  assert.match(byWeight['900'], /^local\("PingFang SC Black"\)/, '900 stays 900');
  assert.match(byWeight['400'], /Noto Sans CJK SC Medium.*Source Han Sans SC Medium/, 'the default families in order');
  assert.equal(asked, 0, 'nothing drawn again till they are loaded');
  await task();
  // (those the system has in the page's fonts, the rest not: 600 drawn in 700, which it has not, in the Semibold beside it)
  assert.deepEqual([...b.fonts].map((f) => f.weight).sort(), ['300', '400', '500', '600']);
  assert.equal(b.H.atlasGeneration(), gen + 1, 'what was shaped forgotten once');
  assert.equal(asked, 1, 'a frame asked for once');
  assert.match(fontOf(b, 0), /^400 16px "mbface1", /, 'the words\' face drawn in it now');
  assert.equal(fontOf(b, 2).includes('mbface1'), false, 'not the code face');
});

test('a face\'s CJK companion by the families given, the step said; none the system has: nothing changes', async () => {
  const b = browser();
  await task();
  let asked = 0;
  b.H.requestFrame = () => { asked++; };
  const gen = b.H.atlasGeneration();
  b.H.setCjkFace(2, 200, ['LXGW WenKai']);
  const cjk = b.made.filter((f) => f.family === 'mbface2');
  assert.match(cjk.find((f) => f.weight === '400').src, /^local\("LXGW WenKai Semibold"\), local\("LXGWWenKai-Semibold"\)/);
  assert.match(cjk.find((f) => f.weight === '800').src, /^local\("LXGW WenKai Black"\)/, 'clamped to 900');
  assert.equal(cjk.find((f) => f.weight === '400').src.includes('PingFang'), false, 'only those given');
  await task();
  assert.equal(b.fonts.size, 0);
  assert.equal(b.H.atlasGeneration(), gen);
  assert.equal(asked, 0);
  assert.equal(b.H.setCjkFace(0, 100, []), false, 'no such face');
  assert.equal(b.H.setCjkFace(32, 100, []), false, 'no such face');
});

test('a face\'s CJK companion asked again takes the place of the one before; cleared with its face', async () => {
  const b = browser();
  await task();
  b.installed.add('PingFang SC Medium');
  b.H.setCjkFace(1, 100, []);
  await task();
  assert.equal(b.fonts.size, 1);
  b.installed.add('PingFang SC Bold');
  b.H.setCjkFace(1, 300, []);
  await task();
  assert.deepEqual([...b.fonts].map((f) => [f.weight, f.src.slice(0, 26)]),
    [['200', 'local("PingFang SC Medium"'], ['300', 'local("PingFang SC Semibol'], ['400', 'local("PingFang SC Bold"),']],
    'the one before gone');
  b.H.faceClear(1);
  assert.equal(b.fonts.size, 0);
  assert.equal(fontOf(b, 0).includes('mbface1'), false);
});

test('a face\'s CJK companion narrow among Latin letters as its face is (pwid), asked before or after', async () => {
  const b = browser();
  await task();
  b.installed.add('PingFang SC Medium');
  b.H.faceAddBytes(1, new Uint8Array(4), 400);
  await task();
  // (narrow asked as a style says so: loaded with pwid, the CJK too)
  b.H.setCjkFace(1, 100, []);
  fontOf(b, 64);
  await task();
  const narrow = [...b.fonts].filter((f) => f.family === 'mbface1n');
  assert.ok(narrow.some((f) => f.unicodeRange === CJK_RANGE && f.weight === '400' && f.featureSettings === '"pwid" 1'),
    'the CJK narrow');
  assert.match(fontOf(b, 64), /"mbface1n", "mbface1"/);
  // asked after narrow was: the CJK narrow loaded with it
  b.installed.add('PingFang SC Regular');
  b.H.setCjkFace(1, 0, ['PingFang SC']);
  await task();
  const now = [...b.fonts].filter((f) => f.family === 'mbface1n' && f.unicodeRange);
  assert.deepEqual(now.map((f) => [f.weight, f.featureSettings, f.src.slice(0, 27)]),
    [['400', '"pwid" 1', 'local("PingFang SC Regular"'], ['500', '"pwid" 1', 'local("PingFang SC Medium")']],
    'the one before gone, the new narrow too');
});

test('faceSetLigatures(3, false) sets calt/liga/clig=0 on mbface3 and mbface3n before/after load without ZWNJ Arabic breakage, and restores on true', async () => {
  const seen = [];
  const recMeasure = (s) => { seen.push(s); return { fontBoundingBoxAscent: 12, fontBoundingBoxDescent: 4, width: s.length * 10 }; };
  // Before load: faceSetLigatures(3, false) then faceAddBytes
  const b1 = browser({ measureText: recMeasure });
  await task();
  b1.H.faceSetLigatures(3, false);
  b1.H.faceAddBytes(3, new Uint8Array(4), 400);
  await task();
  assert.ok([...b1.fonts].some((f) => f.family === 'mbface3' && f.featureSettings === '"calt" 0, "liga" 0, "clig" 0'));
  // Arabic shaping must NOT insert ZWNJ (\u200c) when faceSetLigatures(3, false) is active
  seen.length = 0;
  b1.H.shape('سلام', 16, 400, 3 << 8, new Float64Array(32));
  assert.equal(seen.some((s) => s.includes('\u200C')), false, 'faceSetLigatures(false) must not inject ZWNJ into Arabic shaping');
  // After load: regular + narrow mbface3n reloaded with calt/liga/clig=0, then cleared on true
  const b2 = browser();
  await task();
  b2.H.faceAddBytes(3, new Uint8Array(4), 400);
  await task();
  fontOf(b2, (3 << 8) | 64);
  await task();
  b2.H.faceSetLigatures(3, false);
  await task();
  assert.ok([...b2.fonts].some((f) => f.family === 'mbface3' && f.featureSettings === '"calt" 0, "liga" 0, "clig" 0'));
  assert.ok([...b2.fonts].some((f) => f.family === 'mbface3n' && f.featureSettings === '"calt" 0, "liga" 0, "clig" 0, "pwid" 1'));
  b2.H.faceSetLigatures(3, true);
  await task();
  assert.ok([...b2.fonts].some((f) => f.family === 'mbface3' && f.featureSettings === undefined));
  assert.ok([...b2.fonts].some((f) => f.family === 'mbface3n' && f.featureSettings === '"pwid" 1'));
});

test('style_serif | style_words stays serif even when face_text (slot 2) is loaded', async () => {
  const b = browser();
  await task();
  b.H.faceAddBytes(2, new Uint8Array(4), 400);
  await task();
  assert.match(fontOf(b, 16), /"mbface2"/, 'style_words alone uses face_text');
  assert.equal(fontOf(b, 4 | 16).includes('mbface2'), false, 'style_serif | style_words exempt from face_text');
});

test('slot 8 dual-weight faceAddBytes keeps both 400 and 600 in document.fonts regardless of resolution order', async () => {
  for (const order of [[0, 1], [1, 0]]) {
    const b = browser({ deferLoad: true });
    await task();
    b.H.faceAddBytes(8, new Uint8Array(4), 400);
    b.H.faceAddBytes(8, new Uint8Array(4), 600);
    assert.equal(b.pending.length, 2);
    b.pending[order[0]]();
    await task();
    b.pending[order[1]]();
    await task();
    const weights = [...b.fonts].filter((f) => f.family === 'mbface8').map((f) => f.weight).sort();
    assert.deepEqual(weights, ['400', '600'], `order ${order.join(',')} keeps both weights`);
  }
});

test('slot >= 7 async faceAddBytes completion bumps atlasGeneration so MoonBit reshapes off fallback', async () => {
  const b = browser({ deferLoad: true });
  await task();
  const gen0 = b.H.atlasGeneration();
  b.H.faceAddBytes(10, new Uint8Array(4), 400);
  assert.equal(b.pending.length, 1);
  b.pending[0]();
  await task();
  assert.ok(b.H.atlasGeneration() > gen0, 'atlasGeneration bumped after async preview font load');
});

test('faceSetLigatures preserves document.fonts order and CJK companions, and in-flight narrow CJK completion refreshes', async () => {
  const b = browser();
  await task();
  b.installed.add('PingFang SC Medium');
  b.H.faceAddBytes(3, new Uint8Array(4), 400);
  await task();
  b.H.setCjkFace(3, 100, ['PingFang SC']);
  await task();
  // Trigger narrow load (primary + CJK) and verify it bumps atlasGeneration and requests a frame on completion.
  const genBeforeNarrow = b.H.atlasGeneration();
  let frames = 0;
  const origReq = b.H.requestFrame;
  b.H.requestFrame = () => { frames++; origReq(); };
  fontOf(b, (3 << 8) | 64);
  b.H.faceSetLigatures(3, false);
  await task();
  assert.ok(b.H.atlasGeneration() > genBeforeNarrow, 'in-flight narrow CJK completion bumps atlasGeneration');
  assert.ok(frames >= 1, 'in-flight narrow CJK completion requests a frame');
  const snapshotBefore = [...b.fonts];
  assert.ok(snapshotBefore.filter((f) => f.unicodeRange === CJK_RANGE).length >= 2, 'regular and narrow CJK companion loaded');
  // Toggling ligatures must re-pin CJK companions strictly after same-family primary FontFaces (CSS last-wins).
  b.H.faceSetLigatures(3, true);
  await task();
  b.H.faceSetLigatures(3, false);
  await task();
  const list = [...b.fonts];
  for (const fam of ['mbface3', 'mbface3n']) {
    const lastPrimary = list.reduce((m, f, idx) => (f.family === fam && !f.unicodeRange ? idx : m), -1);
    const firstCjk = list.findIndex((f) => f.family === fam && f.unicodeRange === CJK_RANGE);
    assert.ok(lastPrimary >= 0 && firstCjk > lastPrimary, `${fam}: CJK companion (${firstCjk}) must come after primary (${lastPrimary})`);
  }
});

test('stale multi-weight narrowFace batch cancelled by faceClear does not bump atlasGeneration or pollute narrowFaces', async () => {
  const b = browser({ deferLoad: true });
  await task();
  b.H.faceAddBytes(7, new Uint8Array(4), 400);
  b.H.faceAddBytes(7, new Uint8Array(4), 700);
  b.pending[0]();
  b.pending[1]();
  await task();
  // Trigger narrow load for both weights (400 and 700): pending[2] and pending[3].
  fontOf(b, (7 << 8) | 64);
  assert.equal(b.pending.length, 4);
  // Resolve weight 400 first, then faceClear(7) before weight 700 resolves.
  b.pending[2]();
  await task();
  b.H.faceClear(7);
  const genAfterClear = b.H.atlasGeneration();
  // Now resolve stale weight 700 from the cancelled narrowFace batch.
  b.pending[3]();
  await task();
  await task();
  assert.equal(b.H.atlasGeneration(), genAfterClear, 'cancelled narrowFace batch must not bump atlasGeneration');
  assert.equal([...b.fonts].some((f) => f.family === 'mbface7n'), false, 'no stale narrow FontFace left in document.fonts');
});

test('late narrow CJK completion still bumps atlasGeneration and requests a frame after faceSetLigatures set narrowFaces', async () => {
  const b = browser({ deferLoad: true });
  await task();
  b.installed.add('PingFang SC Medium');
  b.H.faceAddBytes(3, new Uint8Array(4), 400);
  b.pending[0]();
  await task();
  b.H.setCjkFace(3, 100, ['PingFang SC']);
  // pending[1] is regular CJK (400 -> Medium)
  assert.equal(b.pending.length, 2);
  b.pending[1]();
  await task();
  // Trigger narrowFace: pending[2] is primary narrow, pending[3] is narrow CJK
  fontOf(b, (3 << 8) | 64);
  assert.equal(b.pending.length, 4);
  // Toggle ligatures while narrow CJK (pending[3]) is still pending: pending[4] regular + pending[5] narrow primary
  b.H.faceSetLigatures(3, false);
  assert.equal(b.pending.length, 6);
  // Complete faceSetLigatures first (sets narrowFaces(3) = true)
  b.pending[4]();
  b.pending[5]();
  await task();
  await task();
  // Now resolve the late narrowFace batch (stale primary pending[2] + valid narrow CJK pending[3])
  const genBeforeLateCjk = b.H.atlasGeneration();
  let frames = 0;
  const origReq = b.H.requestFrame;
  b.H.requestFrame = () => { frames++; origReq(); };
  b.pending[2]();
  b.pending[3]();
  await task();
  await task();
  assert.ok(b.H.atlasGeneration() > genBeforeLateCjk, 'late narrow CJK completion bumps atlasGeneration');
  assert.ok(frames >= 1, 'late narrow CJK completion requests a frame');
});

test('faceSetLigatures pair-replaces safely: keeps mid-flight added weight 700 and preserves old weight 400 on rejection', async () => {
  // (a) Mid-flight added weight 700 completes before 400 ligature swap commits: both 400 and 700 survive
  const b1 = browser({ deferLoad: true });
  await task();
  b1.H.faceAddBytes(3, new Uint8Array(4), 400);
  b1.pending[0]();
  await task();
  b1.H.faceSetLigatures(3, false); // pending[1] = 400 replacement
  b1.H.faceAddBytes(3, new Uint8Array(4), 700); // pending[2] = new 700
  b1.pending[2]();
  await task();
  b1.pending[1]();
  await task();
  await task();
  const weights = [...b1.fonts].filter((f) => f.family === 'mbface3').map((f) => f.weight).sort();
  assert.deepEqual(weights, ['400', '700'], 'mid-flight weight 700 preserved alongside swapped 400');

  // (b) Replacement load rejects: original 400 stays in document.fonts
  const b2 = browser({ deferLoad: true });
  await task();
  b2.H.faceAddBytes(3, new Uint8Array(4), 400);
  b2.pending[0]();
  await task();
  const orig400 = [...b2.fonts][0];
  b2.H.faceSetLigatures(3, false); // pending[1] = 400 replacement
  b2.pending[1].reject();
  await task();
  await task();
  assert.ok(b2.fonts.has(orig400), 'original 400 FontFace preserved when ligature replacement rejects');
});

test('slot 7 async faceSetLigatures completion bumps atlasGeneration so MoonBit invalidates preview measurement', async () => {
  const b = browser({ deferLoad: true });
  await task();
  b.H.faceAddBytes(7, new Uint8Array(4), 400);
  b.pending[0]();
  await task();
  b.H.faceSetLigatures(7, false);
  const genWhilePending = b.H.atlasGeneration();
  b.pending[1]();
  await task();
  await task();
  assert.ok(b.H.atlasGeneration() > genWhilePending, 'slot 7 faceSetLigatures commit bumps atlasGeneration');
});

test('same-slot same-weight multi-source registration preserves both entries and registration order (Serif -> Sans -> CJK) regardless of replacement completion order', async () => {
  const serifBytes = new Uint8Array([1, 2, 3, 4]);
  const sansBytes = new Uint8Array([5, 6, 7, 8]);
  for (const order of [[0, 1], [1, 0]]) {
    const b = browser({ deferLoad: true });
    await task();
    b.installed.add('PingFang SC Medium');
    b.H.faceAddBytes(3, serifBytes, 400); // pending[0]
    b.H.faceAddBytes(3, sansBytes, 400);  // pending[1]
    b.pending[0]();
    b.pending[1]();
    await task();
    b.H.setCjkFace(3, 100, ['PingFang SC']); // pending[2]
    b.pending[2]();
    await task();
    // Toggle ligatures: pending[3] = serif replacement, pending[4] = sans replacement
    b.H.faceSetLigatures(3, false);
    assert.equal(b.pending.length, 5);
    b.pending[3 + order[0]]();
    await task();
    b.pending[3 + order[1]]();
    await task();
    await task();
    const list = [...b.fonts].filter((f) => f.family === 'mbface3');
    const serifIdx = list.findIndex((f) => f.src === serifBytes);
    const sansIdx = list.findIndex((f) => f.src === sansBytes);
    const cjkIdx = list.findIndex((f) => f.unicodeRange === CJK_RANGE);
    assert.ok(serifIdx >= 0 && sansIdx > serifIdx && cjkIdx > sansIdx,
      `order ${order.join(',')}: expected serif(${serifIdx}) < sans(${sansIdx}) < cjk(${cjkIdx})`);
  }
});

test('initial faceAddBytes resolves as fallback when concurrent faceSetLigatures replacement rejects', async () => {
  const b = browser({ deferLoad: true });
  await task();
  b.H.faceAddBytes(3, new Uint8Array(4), 400); // pending[0] (ligGen=0)
  b.H.faceSetLigatures(3, false);              // pending[1] (ligGen=1)
  assert.equal(b.pending.length, 2);
  b.pending[1].reject();
  await task();
  b.pending[0]();
  await task();
  await task();
  assert.equal([...b.fonts].filter((f) => f.family === 'mbface3').length, 1, 'initial FontFace installed as fallback');
});
