import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createSocket } from "node:dgram";
import { once } from "node:events";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer as createTcp } from "node:net";
import { createServer } from "node:https";
import type { TLSSocket } from "node:tls";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const script = fileURLToPath(new URL("../scripts/native-handoff.mjs", import.meta.url));

/** A child Node that imports fetchHandoff, trusting `cert`, with these environment variables; its stdout as JSON. */
async function child(code: string, env: Record<string, string>) {
  const run = spawn(process.execPath, ["--input-type=module", "-e",
    `import { fetchHandoff } from ${JSON.stringify(new URL("../scripts/native-handoff.mjs", import.meta.url).href)};\n${code}`],
  { env: { ...process.env, STILLFAIL_DIRECT_DNS: "", ...env } });
  let stdout = "", stderr = "";
  run.stdout.on("data", (chunk) => { stdout += chunk; });
  run.stderr.on("data", (chunk) => { stderr += chunk; });
  const [status] = await once(run, "exit");
  assert.equal(status, 0, stderr);
  return { out: JSON.parse(stdout), stderr };
}

test("the handoff reaches the releases Worker at CI's DNS addresses in turn, then by the usual route", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "native-handoff-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const key = join(dir, "key.pem"), cert = join(dir, "cert.pem");
  const made = spawnSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
    "-days", "1", "-subj", "/CN=app.still.fail", "-addext", "subjectAltName=DNS:app.still.fail"], { encoding: "utf8" });
  assert.equal(made.status, 0, made.stderr);

  // The Worker: a PUT's body is answered back, a GET has bytes of every value, /redirect points elsewhere.
  const archive = Buffer.from(Array.from({ length: 70_000 }, (_, i) => (i * 31 + 7) % 256));
  const requests: { method: string | undefined; url: string | undefined; host: string | undefined; authorization: string | undefined; servername: string | false | null; length: number }[] = [];
  const https = createServer({ key: readFileSync(key), cert: readFileSync(cert) }, (req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => {
      const body = Buffer.concat(chunks);
      requests.push({ method: req.method, url: req.url, host: req.headers.host, authorization: req.headers.authorization,
        servername: (req.socket as TLSSocket).servername, length: body.length });
      if (req.url === "/redirect") res.writeHead(302, { location: "https://elsewhere.example/" }).end();
      else if (req.method === "PUT") res.writeHead(200, { "content-type": "application/octet-stream" }).end(body);
      else res.end(archive);
    });
  });
  // In front of it, on one port: the first `refuse` connections are cut before TLS, as a route that is down.
  let refuse = 0, connections = 0;
  const front = createTcp((socket) => {
    connections++;
    if (refuse > 0) { refuse--; socket.destroy(); return; }
    https.emit("connection", socket);
  });
  front.listen(0, "127.0.0.1");
  await once(front, "listening");
  t.after(() => front.close());
  const port = (front.address() as { port: number }).port;

  // CI's DNS server: every query answered with `answers`, each an A record.
  let answers = ["127.0.0.1", "127.0.0.1"], silent = false;
  const queries: string[] = [];
  const dns = createSocket("udp4");
  dns.on("message", (msg, peer) => {
    if (silent) return;
    const labels: string[] = [];
    for (let at = 12; msg[at];) {
      const size = msg[at]!;
      labels.push(msg.subarray(at + 1, at + 1 + size).toString());
      at += size + 1;
    }
    queries.push(labels.join("."));
    const header = Buffer.from(msg.subarray(0, 12));
    header.writeUInt16BE(0x8180, 2); header.writeUInt16BE(answers.length, 6); header.writeUInt16BE(0, 8); header.writeUInt16BE(0, 10);
    const records = answers.map((ip) => Buffer.from([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, ...ip.split(".").map(Number)]));
    dns.send(Buffer.concat([header, msg.subarray(12), ...records]), peer.port, peer.address);
  });
  dns.bind(0, "127.0.0.1");
  await once(dns, "listening");
  t.after(() => dns.close());
  const env = { NODE_EXTRA_CA_CERTS: cert, STILLFAIL_DIRECT_DNS: `127.0.0.1:${dns.address().port}` };
  const worker = `https://app.still.fail:${port}`;
  // Any request that reaches the machine's own routing says so instead.
  const usual = `const usual = []; globalThis.fetch = async (at, init) => { usual.push([String(at), init?.redirect ?? null]); return new Response("usual route"); };`;

  await t.test("a PUT and a GET go directly, with the Worker's Host and TLS name and every byte", async () => {
    const { out } = await child(`${usual}
      const body = Buffer.from(${JSON.stringify(archive.toString("base64"))}, "base64");
      const put = await fetchHandoff("${worker}/releases/ci-natives", { method: "PUT", headers: { authorization: "Bearer token" }, body, redirect: "error" });
      const echoed = Buffer.from(await put.arrayBuffer());
      const get = await fetchHandoff("${worker}/releases/ci-natives/key?x=1", { redirect: "error" });
      const got = Buffer.from(await get.arrayBuffer());
      console.log(JSON.stringify({ put: put.status, echoed: echoed.toString("base64"), get: get.status, got: got.toString("base64"), usual }));`, env);
    assert.deepEqual(out, { put: 200, echoed: archive.toString("base64"), get: 200, got: archive.toString("base64"), usual: [] });
    assert.deepEqual(requests.splice(0), [
      { method: "PUT", url: "/releases/ci-natives", host: `app.still.fail:${port}`, authorization: "Bearer token", servername: "app.still.fail", length: archive.length },
      { method: "GET", url: "/releases/ci-natives/key?x=1", host: `app.still.fail:${port}`, authorization: undefined, servername: "app.still.fail", length: 0 },
    ]);
    assert.ok(queries.length > 0 && queries.every((query) => query === "app.still.fail"));
  });

  await t.test("a route that is down is said and the next address taken", async () => {
    refuse = 1; connections = 0;
    const { out, stderr } = await child(`${usual}
      const get = await fetchHandoff("${worker}/releases/ci-natives/key", { redirect: "error" });
      console.log(JSON.stringify({ status: get.status, length: (await get.arrayBuffer()).byteLength, usual }));`, env);
    assert.deepEqual(out, { status: 200, length: archive.length, usual: [] });
    assert.equal(connections, 2);
    assert.match(stderr, /native-handoff: GET \/releases\/ci-natives\/key at 127\.0\.0\.1 failed \(.+\); trying the next route/);
    assert.equal(requests.splice(0).length, 1);
  });

  await t.test("with both addresses down, the usual route", async () => {
    refuse = 2; connections = 0;
    const { out, stderr } = await child(`${usual}
      const get = await fetchHandoff("${worker}/releases/ci-natives/key", { redirect: "error" });
      console.log(JSON.stringify({ text: await get.text(), usual }));`, env);
    assert.deepEqual(out, { text: "usual route", usual: [[`${worker}/releases/ci-natives/key`, "error"]] });
    assert.equal(connections, 2);
    assert.equal(stderr.match(/trying the next route/g)?.length, 2);
  });

  await t.test("a DNS server that cannot be used leaves it to the usual route", async () => {
    const { out, stderr } = await child(`${usual}
      const get = await fetchHandoff("${worker}/releases/ci-natives/key", { redirect: "error" });
      console.log(JSON.stringify({ text: await get.text(), usual }));`, { ...env, STILLFAIL_DIRECT_DNS: "invalid" });
    assert.deepEqual(out, { text: "usual route", usual: [[`${worker}/releases/ci-natives/key`, "error"]] });
    assert.match(stderr, /resolving app\.still\.fail at invalid failed .*; by the usual route/);
  });

  await t.test("a DNS server that never answers is given up on, the lookup cancelled, and the usual route taken", async () => {
    silent = true;
    try {
      const { out, stderr } = await child(`${usual}
        const get = await fetchHandoff("${worker}/releases/ci-natives/key", { redirect: "error" }, { dnsMs: 150 });
        console.log(JSON.stringify({ text: await get.text(), usual }));`, env);
      assert.deepEqual(out, { text: "usual route", usual: [[`${worker}/releases/ci-natives/key`, "error"]] });
      assert.match(stderr, /resolving app\.still\.fail at 127\.0\.0\.1:\d+ failed \(no answer from 127\.0\.0\.1:\d+ in 150 ms\); by the usual route/);
      assert.doesNotMatch(stderr, /Unhandled|ECANCELLED/);
    } finally { silent = false; }
  });

  await t.test("a redirect is refused, neither followed nor tried by another route", async () => {
    refuse = 0; connections = 0;
    const { out } = await child(`${usual}
      const error = await fetchHandoff("${worker}/redirect", { redirect: "error" }).then(() => null, (e) => e.message);
      console.log(JSON.stringify({ error, usual }));`, env);
    assert.deepEqual(out, { error: "HTTP 302: redirected to https://elsewhere.example/", usual: [] });
    assert.equal(connections, 1);
    assert.deepEqual(requests.splice(0).map((r) => r.url), ["/redirect"]);
  });

  await t.test("GitHub's OIDC endpoint and any other host keep the machine's routing", async () => {
    const before = queries.length;
    const { out } = await child(`${usual}
      const oidc = await fetchHandoff("https://token.actions.githubusercontent.com/token?audience=x", { headers: { authorization: "Bearer t" } });
      const plain = await fetchHandoff("http://app.still.fail:${port}/releases/ci-natives/key");
      console.log(JSON.stringify({ texts: [await oidc.text(), await plain.text()], usual }));`, env);
    assert.deepEqual(out, { texts: ["usual route", "usual route"], usual: [
      ["https://token.actions.githubusercontent.com/token?audience=x", null], [`http://app.still.fail:${port}/releases/ci-natives/key`, null]] });
    assert.equal(queries.length, before);
  });
});

test("the handoff runs copied out alone, as next-mac-cache.yml runs it, and imports without running", () => {
  const dir = mkdtempSync(join(tmpdir(), "native-handoff-alone-"));
  try {
    const copy = join(dir, "native-handoff.mjs");
    copyFileSync(script, copy);
    mkdirSync(join(dir, "natives"));
    const env = { ...process.env, STILLFAIL_DIRECT_DNS: "" };
    // No manifest in the directory: nothing to fetch, and every import it has resolved.
    const get = spawnSync(process.execPath, [copy, "get", join(dir, "natives"), "a".repeat(40)], { encoding: "utf8", env });
    assert.equal(get.status, 0, get.stderr);
    const usage = spawnSync(process.execPath, [copy], { encoding: "utf8", env });
    assert.notEqual(usage.status, 0);
    assert.match(usage.stderr, /Usage: native-handoff\.mjs put DIR MANIFEST \| get DIR COMMIT/);
    // (an argument after -e is process.argv[1]: no such file is not this one)
    const imported = spawnSync(process.execPath, ["--input-type=module", "-e",
      `const m = await import(${JSON.stringify(pathToFileURL(copy).href)}); console.log(typeof m.fetchHandoff);`, "not-a-file"], { encoding: "utf8", env });
    assert.equal(imported.status, 0, imported.stderr);
    assert.equal(imported.stdout.trim(), "function");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
