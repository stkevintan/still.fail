#!/bin/bash
# scripts/download-artifact.sh against a server of its own on 127.0.0.1 (GitHub's API and the blob it redirects to): an
# artifact downloaded whole is unzipped into DEST; one cut midway is taken on by Range (mbui-size 43955196994's idle,
# 2026-11-16: Azure's stream cut at 49%, download-artifact out with 0 and half a zip); one whose bytes are not its digest
# is downloaded again; one never whole, or never listed, leaves no DEST, exits 1, or 0 with --optional.
set -u
d=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
srv=
trap '[ -z "$srv" ] || { kill "$srv"; wait "$srv"; } 2>/dev/null; rm -rf "$t"' EXIT
fail() {
  echo "download-artifact-test: $*" >&2
  [ ! -e "$t/log" ] || sed 's/^/  served: /' "$t/log" >&2
  [ ! -e "$t/err" ] || sed 's/^/  said: /' "$t/err" >&2
  exit 1
}

# A real zip: a line and 64 KiB of bytes, stored, so a cut at half is a cut inside a file
python3 - "$t/art.zip" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_STORED) as z:
    z.writestr("hello.txt", "whole\n")
    z.writestr("sub/data.bin", bytes((i * 7 + 3) % 251 for i in range(65536)))
EOF

# The server. Each run id says how it behaves; what it served is a line of the log.
#   ok: a 302 to the blob, the blob whole
#   resume: the blob cut at half unless asked by Range, then the range asked (206)
#   badsum: the first download bytes as long as the zip and not it, then the zip
#   cut-*: every download cut at half of what was asked
#   list502: the list 502 once, then as ok; list502always: always 502
cat > "$t/server.mjs" <<'EOF'
import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
const [zipPath, logPath] = process.argv.slice(2);
const zip = fs.readFileSync(zipPath);
const digest = "sha256:" + crypto.createHash("sha256").update(zip).digest("hex").toUpperCase();
const counts = new Map();
const count = (k) => { const n = (counts.get(k) ?? 0) + 1; counts.set(k, n); return n; };
const log = (s) => fs.appendFileSync(logPath, s + "\n");
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const base = `http://127.0.0.1:${server.address().port}`;
  let m;
  if ((m = u.pathname.match(/^\/repos\/o\/r\/actions\/runs\/([^/]+)\/artifacts$/))) {
    const run = m[1];
    const n = count("list " + run);
    log(`${run} list ${n} auth=${req.headers.authorization === "Bearer t0ken"}`);
    if (req.headers.authorization !== "Bearer t0ken") { res.writeHead(401).end(); return; }
    if (run === "list502always" || (run === "list502" && n === 1)) { res.writeHead(502).end("bad gateway"); return; }
    const name = u.searchParams.get("name");
    const artifacts = [
      { name, expired: true, size_in_bytes: 1, digest: "sha256:00", archive_download_url: `${base}/gone` },
      { name: name + "-other", expired: false, size_in_bytes: 1, digest: "sha256:00", archive_download_url: `${base}/gone` },
      { name, expired: false, size_in_bytes: zip.length, digest, archive_download_url: `${base}/zip/${run}` },
    ];
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ total_count: 3, artifacts }));
    return;
  }
  if ((m = u.pathname.match(/^\/zip\/([^/]+)$/))) {
    log(`${m[1]} redirect auth=${req.headers.authorization === "Bearer t0ken"}`);
    if (req.headers.authorization !== "Bearer t0ken") { res.writeHead(401).end(); return; }
    res.writeHead(302, { Location: `${base}/blob/${m[1]}?sig=s` }).end();
    return;
  }
  if ((m = u.pathname.match(/^\/blob\/([^/]+)$/))) {
    const run = m[1];
    const n = count("blob " + run);
    const range = req.headers.range ?? "";
    log(`${run} blob ${n} range=${range || "-"} auth=${req.headers.authorization !== undefined}`);
    // (as Azure: a signed URL asked with an Authorization it does not know is refused)
    if (req.headers.authorization !== undefined) { res.writeHead(403).end(); return; }
    let from = 0;
    const r = range.match(/^bytes=(\d+)-$/);
    if (r && run !== "badsum") from = Number(r[1]);
    let body = zip.subarray(from);
    if (run === "badsum" && n === 1) body = Buffer.alloc(zip.length, 0x5a);
    const cut = run.startsWith("cut-") || (run === "resume" && from === 0);
    const head = from > 0
      ? [206, { "content-length": body.length, "content-range": `bytes ${from}-${zip.length - 1}/${zip.length}` }]
      : [200, { "content-length": body.length, "accept-ranges": "bytes" }];
    res.writeHead(...head);
    if (cut) {
      res.write(body.subarray(0, Math.floor(body.length / 2)), () => res.destroy());
    } else {
      res.end(body);
    }
    return;
  }
  res.writeHead(404).end();
});
server.listen(0, "127.0.0.1", () => console.log(server.address().port));
EOF
mkfifo "$t/port"
node "$t/server.mjs" "$t/art.zip" "$t/log" > "$t/port" &
srv=$!
read -r port < "$t/port" || fail "the server said no port"
half=$(( $(wc -c < "$t/art.zip") / 2 ))

export GITHUB_REPOSITORY=o/r GH_TOKEN=t0ken GITHUB_API_URL="http://127.0.0.1:$port/" DOWNLOAD_ARTIFACT_PAUSE=0
unset GITHUB_TOKEN
get() { bash "$d/download-artifact.sh" "$@" 2> "$t/err"; }
whole() {
  [ "$(cat "$1/hello.txt" 2>/dev/null)" = whole ] || fail "$1: hello.txt not unzipped"
  python3 -c 'import sys; sys.exit(open(sys.argv[1], "rb").read() != bytes((i * 7 + 3) % 251 for i in range(65536)))' \
    "$1/sub/data.bin" || fail "$1: sub/data.bin not as zipped"
}
served() { grep -c "^$1 " "$t/log"; }

# 1. 302 then the blob whole; the token given to GitHub's API alone, never to the blob
get ok art "$t/ok/in" || fail "ok: exit $?: $(cat "$t/err")"
whole "$t/ok/in"
! grep -q '^ok blob .* auth=true' "$t/log" || fail "ok: the token was sent to the blob"
# (a DEST already there is replaced, nothing of it left)
mkdir -p "$t/ok/in/stale"
get ok art "$t/ok/in" || fail "ok again: exit $?"
whole "$t/ok/in"
[ ! -e "$t/ok/in/stale" ] || fail "ok: what DEST held before is left in it"

# 2. cut at half, then taken on from there by Range (206): whole
get resume art "$t/resume" || fail "resume: exit $?: $(cat "$t/err")"
whole "$t/resume"
grep -q "^resume blob 2 range=bytes=$half- " "$t/log" || fail "resume: its second try asked no range from $half"
[ "$(served 'resume blob')" = 2 ] || fail "resume: $(served 'resume blob') downloads, not 2"

# 3. bytes not its digest: thrown away and downloaded again
get badsum art "$t/badsum" || fail "badsum: exit $?: $(cat "$t/err")"
whole "$t/badsum"
grep -q 'sha256' "$t/err" || fail "badsum: said nothing of its digest: $(cat "$t/err")"
grep -q '^badsum blob 2 range=- ' "$t/log" || fail "badsum: the second download was no whole one"

# 4. never whole: no DEST, with --optional 0 and a warning, without it 1
get --optional cut-opt art "$t/cut/opt" || fail "cut, optional: exit $?"
[ ! -e "$t/cut/opt" ] || fail "cut, optional: DEST left"
[ ! -e "$t/cut" ] || fail "cut, optional: DEST's directory made"
grep -q '^::warning::' "$t/err" || fail "cut, optional: no warning: $(cat "$t/err")"
[ "$(served 'cut-opt blob')" = 3 ] || fail "cut, optional: $(served 'cut-opt blob') downloads, not 3"
get cut-req art "$t/cut/req"
code=$?
[ $code = 1 ] || fail "cut: exit $code, not 1"
[ ! -e "$t/cut/req" ] || fail "cut: DEST left"

# 5. the list failing once: tried again; failing always: no DEST, 0 with --optional
get list502 art "$t/list" || fail "list502: exit $?: $(cat "$t/err")"
whole "$t/list"
[ "$(served 'list502 list')" = 2 ] || fail "list502: listed $(served 'list502 list') times, not 2"
get --optional list502always art "$t/never" || fail "list502always, optional: exit $?"
[ ! -e "$t/never" ] || fail "list502always: DEST left"
[ "$(served 'list502always list')" = 3 ] || fail "list502always: listed $(served 'list502always list') times, not 3"
get list502always art "$t/never"
[ $? = 1 ] || fail "list502always: not 1 without --optional"

echo "download-artifact-test: ok"
