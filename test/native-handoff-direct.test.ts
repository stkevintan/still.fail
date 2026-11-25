import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createSocket } from "node:dgram";
import { once } from "node:events";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

  await t.test("with both addresses down, the usual route is remembered for later requests and falls back to direct if it fails", async () => {
    refuse = 2; connections = 0;
    const { out, stderr } = await child(`
      const usual = [];
      let failUsual = false;
      globalThis.fetch = async (at, init) => {
        usual.push([String(at), init?.redirect ?? null]);
        if (failUsual) throw new Error("proxy down");
        return new Response("usual route");
      };
      const first = await fetchHandoff("${worker}/releases/ci-natives/key1", { redirect: "error" });
      const t1 = await first.text();
      const second = await fetchHandoff("${worker}/releases/ci-natives/key2", { redirect: "error" });
      const t2 = await second.text();
      failUsual = true;
      const third = await fetchHandoff("${worker}/releases/ci-natives/key3", { redirect: "error" });
      const len3 = (await third.arrayBuffer()).byteLength;
      console.log(JSON.stringify({ t1, t2, len3, usual }));`, env);
    assert.deepEqual(out, {
      t1: "usual route",
      t2: "usual route",
      len3: archive.length,
      usual: [
        [`${worker}/releases/ci-natives/key1`, "error"],
        [`${worker}/releases/ci-natives/key2`, "error"],
        [`${worker}/releases/ci-natives/key3`, "error"],
      ],
    });
    // Request 1 tried both direct connections (2 refused); request 2 skipped direct completely (0); request 3 fell back to direct (1).
    assert.equal(connections, 3);
    assert.equal(stderr.match(/trying the next route/g)?.length, 2);
    assert.match(stderr, /by the usual route failed \(proxy down\); trying direct routes/);
    assert.equal(requests.splice(0).length, 1);
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

test("the native handoff posts metadata and sends the archive directly to the signed R2 object", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "native-handoff-r2-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const natives = join(dir, "natives");
  mkdirSync(natives);
  const name = `reader-darwin-arm64-${"0".repeat(24)}.tar.gz`;
  writeFileSync(join(natives, name), "part");
  const sha = "a".repeat(40);
  const receipt = `1700000000-${sha}/4c2b3e5d-e7a3-4c28-b7f1-fa96b9305844`;
  const url = `https://${"b".repeat(32)}.r2.cloudflarestorage.com/stillfail-releases/staged/ci-natives/${receipt}?X-Amz-Signature=private-signature`;
  const mock = `
    import assert from "node:assert/strict";
    let asked = false;
    globalThis.fetch = async (at, init) => {
      const url = new URL(at);
      const scenario = process.env.SCENARIO;
      if (url.origin === "https://oidc.example") {
        const audience = asked ? "https://app.still.fail" : "https://app.monoid.build";
        assert.equal(url.searchParams.get("audience"), audience);
        return Response.json({ value: audience });
      }
      if (scenario === "restore-monoid" || scenario === "restore-stillfail" || scenario === "restore-corrupted") {
        const host = scenario === "restore-stillfail" ? "app.still.fail" : "app.monoid.build";
        assert.equal(url.href, "https://" + host + "/releases/ci-natives/" + ${JSON.stringify(receipt)});
        assert.equal(init?.headers?.authorization, undefined);
        return new Response(scenario === "restore-corrupted" ? "other bytes" : "part");
      }
      if (url.origin === "https://app.monoid.build") {
        assert.equal(init.method, "POST");
        assert.equal(init.headers.authorization, "Bearer https://app.monoid.build");
        asked = true;
        assert.deepEqual(JSON.parse(init.body), { length: 4 });
        if (scenario === "old") return new Response(null, { status: 404 });
        const upload = scenario === "invalid" ? "https://elsewhere.example/?X-Amz-Signature=private-signature" : ${JSON.stringify(url)};
        return Response.json({ receipt: ${JSON.stringify(receipt)}, upload });
      }
      if (url.origin === "https://app.still.fail") {
        assert.equal(init.headers.authorization, "Bearer https://app.still.fail");
        assert.equal(scenario, "old");
        assert.ok(asked);
        assert.equal(init.method, "PUT");
        assert.equal(init.body.toString(), "part");
        return Response.json({ receipt: ${JSON.stringify(receipt)} });
      }
      assert.ok(asked);
      assert.equal(url.href, ${JSON.stringify(url)});
      assert.equal(init.method, "PUT");
      assert.deepEqual(init.headers, { "content-length": "4", "if-none-match": "*" });
      assert.equal(init.body.toString(), "part");
      if (scenario === "denied") return new Response("private-signature", { status: 403 });
      return new Response(null, { status: scenario === "already-written" ? 412 : 200 });
    };`;
  const env = { ...process.env, GITHUB_SHA: sha, STILLFAIL_NATIVE_DIRECT_R2: "1", STILLFAIL_DIRECT_DNS: "",
    ACTIONS_ID_TOKEN_REQUEST_URL: "https://oidc.example/token", ACTIONS_ID_TOKEN_REQUEST_TOKEN: "identity-token" };
  const args = ["--import", "data:text/javascript," + encodeURIComponent(mock), script];
  for (const scenario of ["direct", "already-written", "old", "denied", "invalid"]) {
    const manifest = join(dir, scenario + ".json");
    const run = spawnSync(process.execPath, [...args, "put", natives, manifest], { encoding: "utf8", env: { ...env, SCENARIO: scenario }, timeout: 10_000 });
    if (scenario === "denied" || scenario === "invalid") {
      assert.equal(run.status, 1, run.stderr);
      assert.match(run.stderr, scenario === "denied" ? /R2 upload returned HTTP 403/ : /Invalid R2 upload URL/);
      assert.doesNotMatch(run.stderr, /private-signature/);
      assert.throws(() => readFileSync(manifest), { code: "ENOENT" });
    } else {
      assert.equal(run.status, 0, run.stderr);
      assert.deepEqual(JSON.parse(readFileSync(manifest, "utf8"))[0].chunks, [scenario === "old" ? receipt : "monoid/" + receipt]);
      assert.match(run.stdout, scenario === "old" ? /Staged in R2/ : /Staged directly in R2/);
      assert.doesNotMatch(readFileSync(manifest, "utf8"), /private-signature/);
    }
  }
  for (const [source, scenario] of [["direct", "restore-monoid"], ["old", "restore-stillfail"], ["direct", "restore-corrupted"]] as const) {
    const destination = join(dir, scenario);
    mkdirSync(destination);
    copyFileSync(join(dir, source + ".json"), join(destination, "natives-mac.r2.json"));
    const run = spawnSync(process.execPath, [...args, "get", destination, sha],
      { encoding: "utf8", env: { ...env, SCENARIO: scenario }, timeout: 10_000 });
    if (scenario === "restore-corrupted") {
      assert.equal(run.status, 1, run.stderr);
      assert.match(run.stderr, /Native archive failed SHA-256 verification/);
      assert.throws(() => readFileSync(join(destination, name)), { code: "ENOENT" });
    } else {
      assert.equal(run.status, 0, run.stderr);
      assert.match(run.stdout, /Verified from R2/);
      assert.equal(readFileSync(join(destination, name), "utf8"), "part");
    }
  }
});
