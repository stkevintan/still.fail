#!/bin/bash
# ui.monoid Live Studio (src/studio) built for the browser into OUT (default out/web):
# mbui's web host (host.js), the minified studio bundle (app.js), and index.html.
# Query parameters: ?MBUI_DARK=1&MBUI_ACCENT=blue&MBUI_STD_SCENE=0
#   sh scripts/web-studio.sh [OUT]
set -e
D="$(cd "$(dirname "$0")" && pwd)"
A=$(cd "$D/.." && pwd)
REPO=$(cd "$A/../.." && pwd)
out=$(mkdir -p "${1:-out/web}" && cd "${1:-out/web}" && pwd)
APP=studio MBUI_APP_MOD="$A" bash "$A/scripts/web.sh" bundle "$out"
mkdir -p "$out/assets"
inter=$(ls "$REPO"/node_modules/.pnpm/@fontsource-variable+inter@*/node_modules/@fontsource-variable/inter/files/inter-latin-wght-normal.woff2 2>/dev/null | tail -1)
[ -n "$inter" ] || inter="$REPO/website/ui/assets/fonts/Inter-Regular.woff2"
[ ! -f "$inter" ] || cp "$inter" "$out/assets/inter.woff2"
cat > "$out/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>ui.monoid — Live Studio</title>
<meta name="description" content="ui.monoid Live Studio: production controls, Liquid Glass optics, OKLCH tokens, and overlays rendered live in WebGL 2.">
<style>
  html, body { margin: 0; height: 100%; overflow: hidden; background: #F6F5F1;
               overscroll-behavior: none; -webkit-tap-highlight-color: transparent; }
  html.dark, html.dark body { background: #191918; }
  #c { position: fixed; inset: 0; width: 100%; height: 100%; touch-action: none; display: block;
       user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
  #ime { position: fixed; left: 0; top: 0; width: 2px; height: 20px; opacity: 0; padding: 0; border: 0;
         resize: none; overflow: hidden; font-size: 16px; caret-color: transparent; color: transparent;
         background: transparent; outline: none; }
</style>
</head>
<body>
<canvas id="c"></canvas>
<textarea id="ime" autocapitalize="off" autocomplete="off" spellcheck="false"></textarea>
<script>
  (() => {
    const q = new URLSearchParams(location.search);
    document.documentElement.classList.toggle("dark", q.get("MBUI_DARK") === "1");
    const assets = (globalThis.__mbassets = globalThis.__mbassets || {});
    const fontDone = fetch("assets/inter.woff2")
      .then((r) => (r.ok ? r.arrayBuffer() : null), () => null)
      .then((b) => { if (b) assets["inter.woff2"] = new Uint8Array(b); });
    const load = (src) => new Promise((ok, no) => {
      const s = document.createElement("script");
      s.src = src; s.onload = ok; s.onerror = no;
      document.body.appendChild(s);
    });
    Promise.all([load("host.js"), fontDone]).then(() => load("app.js"));
  })();
</script>
</body>
</html>
HTML
ls -la "$out"
