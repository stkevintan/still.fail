;(function () {
  var t0 = Date.now();
  globalThis.__stillfail.start("http://127.0.0.1:1", false);
  var c = globalThis.__stillfail.connect();
  globalThis.__stillfail.receive(c, JSON.stringify({ id: 1, subscribe: { topic: "accounts" } }));
  globalThis.__stillfail.receive(c, JSON.stringify({ id: 2, subscribe: { topic: "prefs" }, keyed: true }));
  globalThis.__stillfail.receive(c, JSON.stringify({ id: 3, call: "prefs.set", params: { appearance: "dark" } }));
  globalThis.__stillfail.receive(c, JSON.stringify({ id: 4, call: "draft.put", params: { station: "w/s", chat: "new", text: "你好 hermes 😀", quotes: [], files: [] } }));
  globalThis.__stillfail.receive(c, JSON.stringify({ id: 5, subscribe: { topic: "chats", scope: "w" }, keyed: true }));
  globalThis.__stillfail.receive(c, JSON.stringify({ id: 7, subscribe: { topic: "status" } }));
  // The faces and how text is set, each slot and setting put and taken back (fonts.ts, prefs.ts typographyOf).
  globalThis.__stillfail.receive(c, JSON.stringify({ id: 8, call: "prefs.set", params: { fonts: { ui: "lxgw-wenkai", uiCjk: "noto-serif-sc", textCjk: "none", codeCjk: "maple-mono" }, typography: { uiCjkScale: 115, textCjkScale: 100, uiCjkWeight: 100, lineHeight: "relaxed", codeLigatures: false } } }));
  globalThis.__stillfail.receive(c, JSON.stringify({ id: 9, call: "prefs.set", params: { fonts: { textCjk: null }, typography: { textCjkScale: null } } }));
  globalThis.__stillfail.receive(c, JSON.stringify({ id: 10, call: "prefs.set", params: { typography: { textSize: 102 } } }));
  // The CLI runs timers at once, in order (no clock): later is after so many turns.
  var after = function (turns, fn) { if (turns === 0) fn(); else setTimeout(function () { after(turns - 1, fn); }, 0); };
  after(300, function () {
    globalThis.__stillfail.receive(c, JSON.stringify({ id: 6, call: "draft.get", params: { station: "w/s", chat: "new" } }));
  });
  after(1000, function () {
    globalThis.__stillfail.receive(c, JSON.stringify({ id: 11, subscribe: { topic: "prefs" } }));
  });
  after(1500, function () {
    print("started and answered in " + (Date.now() - t0) + " ms");
    emitted.forEach(function (m) { print(m.slice(0, 220)); });
    print("storage: " + Object.keys(store).join(","));
    // The prefs as they went out last: text's CJK face ui's again, its size and weight ui's; 102 refused (off its step).
    var prefs = null, refused = false;
    emitted.forEach(function (m) { var j = JSON.parse(m); if (j.id === 11 && j.value) prefs = j.value; if (j.id === 10 && j.error) refused = true; });
    var f = prefs && prefs.faces, ty = prefs && prefs.typography;
    print("fonts: " + JSON.stringify(prefs && prefs.fonts) + " cjk: " + (f && [f.uiCjk, f.textCjk, f.codeCjk].join(",")) + " typography: " + JSON.stringify(ty) + " refused: " + refused);
    if (!f || f.textCjk !== "noto-serif-sc" || f.codeCjk !== "maple-mono" || ty.textCjkScale !== 115 || ty.textCjkWeight !== 100 || ty.lineHeight !== "relaxed" || ty.codeLigatures !== false || !refused) print("FATAL fonts/typography round trip");
  });
})();
