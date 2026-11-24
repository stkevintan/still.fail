#!/usr/bin/env node
// Real quantitative coverage ledger for `pion/client-core` against the true denominators:
//   - All Topics declared in `client/core-ts/src/protocol.ts` (`TOPICS`)
//   - All Ops declared in `client/core-ts/src/ops.ts` (`PARAMS`)
//   - All real `apps/mbui` `sfreplay` recordings (`e2e/traces/*.trace` + `e2e/tapes/*.trace`)
//
// Zero hardcoded counts: every number is parsed directly from live source files and recordings,
// strictly separating `real` (SQLite/views/state-machine backed), `static-stub` / `stub`
// (`core_runtime.pion` hardcoded/in-memory shims), and `missing`.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import * as protocolTs from "../../../client/core-ts/src/protocol.ts";
import * as opsTs from "../../../client/core-ts/src/ops.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const defaultRepoRoot = path.resolve(__dirname, "../../..");

/**
 * Extract the body of a Pion function starting at `fnSignaturePattern` using brace depth matching.
 */
function extractPionFnBody(src, fnSignaturePattern) {
  const m = fnSignaturePattern.exec(src);
  if (!m) return "";
  const braceStart = src.indexOf("{", m.index + m[0].length - 1);
  if (braceStart < 0) return "";
  let depth = 0;
  let inStr = false;
  let escaped = false;
  for (let i = braceStart; i < src.length; i++) {
    const ch = src[i];
    if (inStr) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === '"') {
        inStr = false;
      }
      continue;
    }
    if (ch === '"') {
      inStr = true;
      continue;
    }
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return src.slice(braceStart, i + 1);
    }
  }
  return src.slice(braceStart);
}

/**
 * Extract all string literals compared to `varName == "..."` inside a code slice.
 */
function extractStringComparisons(code, varName) {
  const out = new Set();
  const re = new RegExp(`\\b${varName}\\s*==\\s*"([^"]+)"`, "g");
  let m;
  while ((m = re.exec(code)) !== null) {
    out.add(m[1]);
  }
  return out;
}

/**
 * Extract the bodies of ALL Pion functions matching `fnSignatureGlobalPattern` in `src`.
 */
function extractAllPionFnBodies(src, fnSignatureGlobalPattern) {
  const bodies = [];
  let m;
  while ((m = fnSignatureGlobalPattern.exec(src)) !== null) {
    const braceStart = src.indexOf("{", m.index + m[0].length - 1);
    if (braceStart < 0) continue;
    let depth = 0;
    let inStr = false;
    let escaped = false;
    let endIdx = src.length;
    for (let i = braceStart; i < src.length; i++) {
      const ch = src[i];
      if (inStr) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === '"') inStr = false;
        continue;
      }
      if (ch === '"') {
        inStr = true;
        continue;
      }
      if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        if (depth === 0) {
          endIdx = i + 1;
          break;
        }
      }
    }
    bodies.push(src.slice(braceStart, endIdx));
  }
  return bodies;
}

/**
 * Extract call-name routing branches (`call_name == "..."`, `op == "..."`, or `"foo.bar" =>`
 * inside `match call_name` / `match op`) from a code slice.
 */
function extractCallDispatchNames(code) {
  const out = new Set();
  for (const v of ["call_name", "op"]) {
    for (const s of extractStringComparisons(code, v)) out.add(s);
    const matchRe = new RegExp(`\\bmatch\\s+${v}\\b`, "g");
    for (const body of extractAllPionFnBodies(code, matchRe)) {
      const armRe = /"([a-zA-Z0-9_.-]+)"\s*=>/g;
      let am;
      while ((am = armRe.exec(body)) !== null) out.add(am[1]);
    }
  }
  return out;
}

/**
 * List non-test `.pion` source files in a package's `src/` directory.
 */
function listPackagePionSources(repoRoot, pkgName) {
  const dir = path.join(repoRoot, "pion/client-core/packages", pkgName, "src");
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".pion") && !f.endsWith("_test.pion"))
    .sort()
    .map((f) => path.join(dir, f));
}

/**
 * Scan `pion/client-core/packages/{protocol,sync,views,core_runtime}/src/*.pion` to classify
 * implemented topics and calls directly from source code.
 */
function scanPionRouting(repoRoot) {
  const syncFiles = listPackagePionSources(repoRoot, "sync");
  const protocolFiles = listPackagePionSources(repoRoot, "protocol");
  const viewFiles = listPackagePionSources(repoRoot, "views");
  const runtimeFiles = listPackagePionSources(repoRoot, "core_runtime");
  const scannedFiles = [...protocolFiles, ...syncFiles, ...viewFiles, ...runtimeFiles];

  const coreRuntimePath = path.join(repoRoot, "pion/client-core/packages/core_runtime/src/core_runtime.pion");
  const coreRuntimeSrc = fs.existsSync(coreRuntimePath) ? fs.readFileSync(coreRuntimePath, "utf8") : "";

  // 1. Topics:
  //    - Implemented in `ClientCore::evaluate_*` (`packages/sync/src/*.pion`)
  //      or `Slice1Router::evaluate_*` (`packages/protocol/src/*.pion`)
  //    - Static-stub intercepts in `core_runtime.pion` `handle_runtime_subscribe`
  //    Any topic intercepted by `handle_runtime_subscribe` is shadowed at runtime and MUST NOT
  //    count as live `real` (its status is `static-stub`, with `shadowedByRuntimeIntercept: true`).
  const clientCoreTopics = new Set();
  for (const f of syncFiles) {
    const src = fs.readFileSync(f, "utf8");
    for (const body of extractAllPionFnBodies(src, /\bfn\s+ClientCore::evaluate_[a-zA-Z0-9_]*\b/g)) {
      for (const t of extractStringComparisons(body, "topic\\.name")) clientCoreTopics.add(t);
    }
  }

  const routerTopics = new Set();
  for (const f of protocolFiles) {
    const src = fs.readFileSync(f, "utf8");
    for (const body of extractAllPionFnBodies(src, /\bfn\s+Slice1Router::evaluate_[a-zA-Z0-9_]*\b/g)) {
      for (const t of extractStringComparisons(body, "topic\\.name")) routerTopics.add(t);
    }
  }

  const runtimeSubBody = extractPionFnBody(coreRuntimeSrc, /fn\s+handle_runtime_subscribe\b/);
  const runtimeStaticStubTopics = extractStringComparisons(runtimeSubBody, "tname");

  const implementedTopics = new Set([...clientCoreTopics, ...routerTopics]);
  const liveRealTopics = new Set([...implementedTopics].filter((t) => !runtimeStaticStubTopics.has(t)));
  const shadowedTopics = new Set([...implementedTopics].filter((t) => runtimeStaticStubTopics.has(t)));

  // 2. Calls/Ops:
  //    - Real: `call_name == "..."` / `op == "..."` (and `match call_name`/`match op` arms) across
  //      `ClientCore::handle_*` / non-test `packages/sync/src/*.pion` and `Slice1Router::handle*` /
  //      non-test `packages/protocol/src/*.pion`.
  //    - Stub: `core_runtime.pion` `pion_core_runtime_send` shims (including fake startup commands
  //      `cloud.sync` and `station.connect` — NEVER counted as `realCalls`).
  const clientCoreCalls = new Set();
  for (const f of syncFiles) {
    const src = fs.readFileSync(f, "utf8");
    for (const c of extractCallDispatchNames(src)) clientCoreCalls.add(c);
  }

  const routerCalls = new Set();
  for (const f of protocolFiles) {
    const src = fs.readFileSync(f, "utf8");
    for (const c of extractCallDispatchNames(src)) routerCalls.add(c);
  }

  const runtimeSendBody = extractPionFnBody(coreRuntimeSrc, /pub\s+extern\s+"C"\s+fn\s+pion_core_runtime_send\b/);
  const runtimeCalls = extractCallDispatchNames(runtimeSendBody);

  // Internal/test-only helpers are never product calls.
  const internalOnlyCalls = new Set(["echo.bytes"]);

  // Symmetric shadowing rule with `handle_runtime_subscribe`:
  // Any call intercepted by `pion_core_runtime_send` is classified as `stub` (never live `real`),
  // even if `ClientCore` / `Slice1Router` also has an implementation below it.
  const implementedCalls = new Set();
  for (const c of [...clientCoreCalls, ...routerCalls]) {
    if (!internalOnlyCalls.has(c)) implementedCalls.add(c);
  }
  const runtimeStubCalls = new Set();
  for (const c of runtimeCalls) {
    if (!internalOnlyCalls.has(c)) runtimeStubCalls.add(c);
  }
  const liveRealCalls = new Set([...implementedCalls].filter((c) => !runtimeStubCalls.has(c)));
  const shadowedCalls = new Set([...implementedCalls].filter((c) => runtimeStubCalls.has(c)));

  // Also scan `views` for `pub fn project_*` functions for provenance reporting.
  const viewProjectors = [];
  for (const f of viewFiles) {
    const src = fs.readFileSync(f, "utf8");
    const re = /pub\s+fn\s+(project_[a-zA-Z0-9_]+)/g;
    let m;
    while ((m = re.exec(src)) !== null) {
      viewProjectors.push({ fn: m[1], file: path.relative(repoRoot, f) });
    }
  }

  return {
    scannedFiles: scannedFiles.map((f) => path.relative(repoRoot, f)),
    clientCoreTopics,
    routerTopics,
    implementedTopics,
    liveRealTopics,
    shadowedTopics,
    runtimeStaticStubTopics,
    clientCoreCalls,
    routerCalls,
    runtimeCalls,
    implementedCalls,
    runtimeStubCalls,
    liveRealCalls,
    shadowedCalls,
    viewProjectors,
  };
}

/**
 * Scan all real `sfreplay` recordings in `apps/mbui/e2e/traces/*.trace` and `apps/mbui/e2e/tapes/*.trace`,
 * plus flow test files in `apps/mbui/src/sfreplay/flows/` and kept fixtures in `apps/mbui/src/sfkept/`.
 */
function scanSfreplayRecordings(repoRoot) {
  const tracesDir = path.join(repoRoot, "apps/mbui/e2e/traces");
  const tapesDir = path.join(repoRoot, "apps/mbui/e2e/tapes");
  const flowsDir = path.join(repoRoot, "apps/mbui/src/sfreplay/flows");
  const sfkeptDir = path.join(repoRoot, "apps/mbui/src/sfkept");

  const traceFiles = fs.existsSync(tracesDir)
    ? fs.readdirSync(tracesDir).filter((f) => f.endsWith(".trace")).sort()
    : [];
  const tapeFiles = fs.existsSync(tapesDir)
    ? fs.readdirSync(tapesDir).filter((f) => f.endsWith(".trace")).sort()
    : [];
  const flowFiles = fs.existsSync(flowsDir)
    ? fs.readdirSync(flowsDir).filter((f) => f.endsWith(".mbt")).sort()
    : [];
  const sfkeptFiles = fs.existsSync(sfkeptDir)
    ? fs.readdirSync(sfkeptDir).filter((f) => f.endsWith(".json") || f.endsWith(".mbt")).sort()
    : [];

  const replays = []; // { id, kind, topics: Set<string>, calls: Set<string>, clientMessages: number }
  const topicReplayCount = new Map();
  const topicMsgCount = new Map();
  const callReplayCount = new Map();
  const callMsgCount = new Map();
  let replayClientMessagesChecked = 0;

  // 1. JSONL full core traces (`apps/mbui/e2e/traces/*.trace`)
  for (const f of traceFiles) {
    const full = path.join(tracesDir, f);
    const lines = fs.readFileSync(full, "utf8").split("\n");
    const tSet = new Set();
    const cSet = new Set();
    let msgCount = 0;
    for (const line of lines) {
      if (!line.trim()) continue;
      let obj;
      try {
        obj = JSON.parse(line);
      } catch {
        continue;
      }
      if (obj && typeof obj === "object" && obj.out && typeof obj.out === "object") {
        msgCount++;
        replayClientMessagesChecked++;
        const parsed = protocolTs.parseClientMessage(obj.out);
        if (!("invalid" in parsed)) {
          if (parsed.kind === "subscribe") {
            const t = parsed.subscribe.topic;
            tSet.add(t);
            topicMsgCount.set(t, (topicMsgCount.get(t) || 0) + 1);
          } else if (parsed.kind === "call") {
            const c = parsed.call;
            cSet.add(c);
            callMsgCount.set(c, (callMsgCount.get(c) || 0) + 1);
          }
        }
      }
    }
    for (const t of tSet) topicReplayCount.set(t, (topicReplayCount.get(t) || 0) + 1);
    for (const c of cSet) callReplayCount.set(c, (callReplayCount.get(c) || 0) + 1);
    replays.push({ id: `traces/${f}`, kind: "trace", topics: tSet, calls: cSet, clientMessages: msgCount });
  }

  // 2. JSON motion tapes (`apps/mbui/e2e/tapes/*.trace`)
  for (const f of tapeFiles) {
    const full = path.join(tapesDir, f);
    let obj;
    try {
      obj = JSON.parse(fs.readFileSync(full, "utf8"));
    } catch {
      continue;
    }
    const tSet = new Set();
    const cSet = new Set();
    let msgCount = 0;
    for (const entry of obj.topics || []) {
      const topicObj = entry?.topic;
      if (topicObj && typeof topicObj.topic === "string") {
        msgCount++;
        replayClientMessagesChecked++;
        tSet.add(topicObj.topic);
        topicMsgCount.set(topicObj.topic, (topicMsgCount.get(topicObj.topic) || 0) + 1);
      }
    }
    for (const ev of obj.events || []) {
      if (ev?.set && typeof ev.set.topic === "string") {
        msgCount++;
        replayClientMessagesChecked++;
        tSet.add(ev.set.topic);
        topicMsgCount.set(ev.set.topic, (topicMsgCount.get(ev.set.topic) || 0) + 1);
      }
      if (typeof ev?.call === "string") {
        msgCount++;
        replayClientMessagesChecked++;
        cSet.add(ev.call);
        callMsgCount.set(ev.call, (callMsgCount.get(ev.call) || 0) + 1);
      }
    }
    for (const t of tSet) topicReplayCount.set(t, (topicReplayCount.get(t) || 0) + 1);
    for (const c of cSet) callReplayCount.set(c, (callReplayCount.get(c) || 0) + 1);
    replays.push({ id: `tapes/${f}`, kind: "tape", topics: tSet, calls: cSet, clientMessages: msgCount });
  }

  return {
    replays,
    replayTracesCount: traceFiles.length,
    replayTapesCount: tapeFiles.length,
    replaysTotal: replays.length,
    replayFlowsCount: flowFiles.length,
    sfkeptFilesCount: sfkeptFiles.length,
    replayClientMessagesChecked,
    topicReplayCount,
    topicMsgCount,
    callReplayCount,
    callMsgCount,
  };
}

/**
 * Compute prioritized missing items needed to reach 80%, 95%, and 100% full coverage of real
 * `sfreplay` recordings. Uses exact greedy unlock-first selection (tie-broken by frequency, then
 * name) so each milestone lists the minimal prioritized set of missing Topic/Call items required.
 */
function computeReplayMilestones(replays, realTopics, realCalls) {
  const total = replays.length;
  if (total === 0) {
    return {
      currentlyCoveredReplays: 0,
      currentlyCoveredPct: 0,
      targets: { p80: null, p95: null, p100: null },
    };
  }

  // Build missing requirement set per replay: `topic:<name>` and `call:<name>`.
  const replayMissing = replays.map((r) => {
    const req = new Set();
    for (const t of r.topics) if (!realTopics.has(t)) req.add(`topic:${t}`);
    for (const c of r.calls) if (!realCalls.has(c)) req.add(`call:${c}`);
    return { id: r.id, missing: req };
  });

  // Frequency of each missing item across replays.
  const freq = new Map();
  for (const r of replayMissing) {
    for (const item of r.missing) freq.set(item, (freq.get(item) || 0) + 1);
  }

  const covered = new Set();
  for (const r of replayMissing) {
    if (r.missing.size === 0) covered.add(r.id);
  }
  const currentlyCoveredReplays = covered.size;

  const picked = [];
  const remainingReplays = replayMissing.filter((r) => r.missing.size > 0);
  const pickedSet = new Set();

  const milestones = {};
  const checkTargets = () => {
    const pct = (covered.size / total) * 100;
    for (const [key, threshold] of [
      ["p80", 80],
      ["p95", 95],
      ["p100", 100],
    ]) {
      if (!milestones[key] && pct >= threshold) {
        const topicsNeeded = picked.filter((x) => x.kind === "topic").map((x) => x.name);
        const callsNeeded = picked.filter((x) => x.kind === "call").map((x) => x.name);
        milestones[key] = {
          thresholdPct: threshold,
          coveredReplays: covered.size,
          totalReplays: total,
          achievedPct: Number(pct.toFixed(2)),
          itemsRequiredCount: picked.length,
          topicsRequiredCount: topicsNeeded.length,
          callsRequiredCount: callsNeeded.length,
          topicsRequired: topicsNeeded,
          callsRequired: callsNeeded,
        };
      }
    }
  };
  checkTargets();

  // Greedy: pick the uncovered replay with the FEWEST remaining missing items (smallest unlock cost),
  // adding its missing items in descending replay-frequency order.
  while (covered.size < total) {
    let bestReplay = null;
    let bestNeedCount = Infinity;
    let bestFreqSum = -1;
    for (const r of remainingReplays) {
      if (covered.has(r.id)) continue;
      let needCount = 0;
      let fSum = 0;
      for (const item of r.missing) {
        if (!pickedSet.has(item)) {
          needCount++;
          fSum += freq.get(item) || 0;
        }
      }
      if (needCount === 0) {
        covered.add(r.id);
        continue;
      }
      if (needCount < bestNeedCount || (needCount === bestNeedCount && fSum > bestFreqSum)) {
        bestNeedCount = needCount;
        bestFreqSum = fSum;
        bestReplay = r;
      }
    }
    if (!bestReplay) break;

    const toAdd = [...bestReplay.missing]
      .filter((item) => !pickedSet.has(item))
      .sort((a, b) => (freq.get(b) || 0) - (freq.get(a) || 0) || a.localeCompare(b));

    for (const item of toAdd) {
      pickedSet.add(item);
      const colon = item.indexOf(":");
      picked.push({
        kind: item.slice(0, colon),
        name: item.slice(colon + 1),
        replayCount: freq.get(item) || 0,
      });
    }
    for (const r of remainingReplays) {
      if (covered.has(r.id)) continue;
      let allDone = true;
      for (const item of r.missing) {
        if (!pickedSet.has(item)) {
          allDone = false;
          break;
        }
      }
      if (allDone) covered.add(r.id);
    }
    checkTargets();
  }

  return {
    currentlyCoveredReplays,
    currentlyCoveredPct: Number(((currentlyCoveredReplays / total) * 100).toFixed(2)),
    targets: {
      p80: milestones.p80 || null,
      p95: milestones.p95 || null,
      p100: milestones.p100 || null,
    },
  };
}

/**
 * Build the complete structured coverage ledger.
 */
export function buildCoverageLedger(repoRoot = defaultRepoRoot) {
  const allProtocolTopics = Object.keys(protocolTs.TOPICS);
  const allOpsParams = Object.keys(opsTs.PARAMS);
  const protocolTopicSet = new Set(allProtocolTopics);
  const opsParamsSet = new Set(allOpsParams);

  const pion = scanPionRouting(repoRoot);
  const replay = scanSfreplayRecordings(repoRoot);

  // Classify all 121 protocol TOPICS:
  // If intercepted by `core_runtime.pion` `handle_runtime_subscribe`, live clients receive the
  // static stub regardless of `ClientCore`/`Slice1Router`, so `status` MUST be `"static-stub"`.
  const topics = allProtocolTopics.map((name) => {
    const inImplemented = pion.implementedTopics.has(name);
    const inRuntimeStub = pion.runtimeStaticStubTopics.has(name);
    let status;
    if (inRuntimeStub) status = "static-stub";
    else if (inImplemented) status = "real";
    else status = "missing";

    const sources = [];
    if (pion.clientCoreTopics.has(name)) sources.push("sync/client_core.pion");
    if (pion.routerTopics.has(name)) sources.push("protocol/protocol.pion");
    if (inRuntimeStub) sources.push("core_runtime/core_runtime.pion#handle_runtime_subscribe");

    return {
      name,
      status,
      shadowedByRuntimeIntercept: inImplemented && inRuntimeStub,
      replayCount: replay.topicReplayCount.get(name) || 0,
      messageCount: replay.topicMsgCount.get(name) || 0,
      sources,
    };
  });

  const extraPionTopicsNotInProtocol = [...new Set([...pion.implementedTopics, ...pion.runtimeStaticStubTopics])]
    .filter((t) => !protocolTopicSet.has(t))
    .sort()
    .map((name) => ({
      name,
      status: pion.runtimeStaticStubTopics.has(name) ? "static-stub" : "real",
      shadowedByRuntimeIntercept: pion.implementedTopics.has(name) && pion.runtimeStaticStubTopics.has(name),
    }));

  // Classify all 207 ops.ts PARAMS (runtime-shadowed calls are `stub`, never live `real`)
  const ops = allOpsParams.map((name) => {
    const inImplemented = pion.implementedCalls.has(name);
    const inRuntimeStub = pion.runtimeStubCalls.has(name);
    let status = "missing";
    if (inRuntimeStub) status = "stub";
    else if (inImplemented) status = "real";

    const sources = [];
    if (pion.clientCoreCalls.has(name)) sources.push("sync/client_core.pion");
    if (pion.routerCalls.has(name)) sources.push("protocol/protocol.pion");
    if (inRuntimeStub) sources.push("core_runtime/core_runtime.pion#pion_core_runtime_send");

    return {
      name,
      status,
      shadowedByRuntimeIntercept: inImplemented && inRuntimeStub,
      replayCount: replay.callReplayCount.get(name) || 0,
      messageCount: replay.callMsgCount.get(name) || 0,
      sources,
    };
  });

  // Replay-referenced Topics sorted by replayCount desc (runtime-shadowed topics are `static-stub`)
  const replayTopics = [...replay.topicReplayCount.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([name, replayCount]) => {
      const inRuntimeStub = pion.runtimeStaticStubTopics.has(name);
      const inImplemented = pion.implementedTopics.has(name);
      const status = inRuntimeStub
        ? "static-stub"
        : inImplemented
          ? "real"
          : "missing";
      return {
        name,
        status,
        shadowedByRuntimeIntercept: inImplemented && inRuntimeStub,
        inProtocol: protocolTopicSet.has(name),
        replayCount,
        messageCount: replay.topicMsgCount.get(name) || 0,
      };
    });

  // Replay-referenced Calls sorted by replayCount desc (runtime-shadowed calls are `stub`)
  const replayCalls = [...replay.callReplayCount.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([name, replayCount]) => {
      const inRuntimeStub = pion.runtimeStubCalls.has(name);
      const inImplemented = pion.implementedCalls.has(name);
      const status = inRuntimeStub
        ? "stub"
        : inImplemented
          ? "real"
          : "missing";
      return {
        name,
        status,
        shadowedByRuntimeIntercept: inImplemented && inRuntimeStub,
        inOpsParams: opsParamsSet.has(name),
        replayCount,
        messageCount: replay.callMsgCount.get(name) || 0,
      };
    });

  // Separate Pion-routed calls that are neither in `ops.PARAMS` nor seen in any `sfreplay` recording
  const allPionRoutedCalls = [...new Set([...pion.implementedCalls, ...pion.runtimeStubCalls])].sort();
  const extraPionCallsNotInOpsOrReplays = allPionRoutedCalls
    .filter((name) => !opsParamsSet.has(name) && (replay.callReplayCount.get(name) || 0) === 0)
    .map((name) => ({
      name,
      status: pion.runtimeStubCalls.has(name) ? "stub" : "real",
      shadowedByRuntimeIntercept: pion.implementedCalls.has(name) && pion.runtimeStubCalls.has(name),
    }));
  const productReachablePionCalls = allPionRoutedCalls.filter(
    (name) => opsParamsSet.has(name) || (replay.callReplayCount.get(name) || 0) > 0,
  );
  const pionProductRealCalls = productReachablePionCalls.filter((c) => pion.liveRealCalls.has(c));
  const pionProductStubCalls = productReachablePionCalls.filter((c) => pion.runtimeStubCalls.has(c));
  const callsShadowedByRuntimeStub = [...pion.shadowedCalls].sort();

  const topicsReal = topics.filter((t) => t.status === "real").length;
  const topicsStaticStub = topics.filter((t) => t.status === "static-stub").length;
  const topicsShadowedByRuntimeStub = topics.filter((t) => t.shadowedByRuntimeIntercept).map((t) => t.name);
  const topicsMissing = topics.filter((t) => t.status === "missing").length;

  const opsReal = ops.filter((o) => o.status === "real").length;
  const opsStub = ops.filter((o) => o.status === "stub").length;
  const opsMissing = ops.filter((o) => o.status === "missing").length;

  const replayTopicsReal = replayTopics.filter((t) => t.status === "real").length;
  const replayTopicsStaticStub = replayTopics.filter((t) => t.status === "static-stub").length;
  const replayTopicsMissing = replayTopics.filter((t) => t.status === "missing").length;

  const replayCallsReal = replayCalls.filter((c) => c.status === "real").length;
  const replayCallsStub = replayCalls.filter((c) => c.status === "stub").length;
  const replayCallsMissing = replayCalls.filter((c) => c.status === "missing").length;

  const missingTopicsByReplayFreq = replayTopics.filter((t) => t.status !== "real");
  const missingCallsByReplayFreq = replayCalls.filter((c) => c.status !== "real");
  const missingCombinedTop30 = [
    ...missingTopicsByReplayFreq.map((t) => ({
      kind: "topic",
      name: t.name,
      status: t.status,
      shadowedByRuntimeIntercept: t.shadowedByRuntimeIntercept,
      sourceSet: t.inProtocol ? "protocol.TOPICS" : "non-protocol",
      replayCount: t.replayCount,
      messageCount: t.messageCount,
    })),
    ...missingCallsByReplayFreq.map((c) => ({
      kind: "call",
      name: c.name,
      status: c.status,
      shadowedByRuntimeIntercept: c.shadowedByRuntimeIntercept,
      sourceSet: c.inOpsParams ? "ops.PARAMS" : "core-local",
      replayCount: c.replayCount,
      messageCount: c.messageCount,
    })),
  ]
    .sort((a, b) => b.replayCount - a.replayCount || b.messageCount - a.messageCount || a.name.localeCompare(b.name))
    .slice(0, 30);

  const milestones = computeReplayMilestones(replay.replays, pion.liveRealTopics, pion.liveRealCalls);
  const topicOnlyMilestones = computeReplayMilestones(
    replay.replays.map((r) => ({ ...r, calls: new Set() })),
    pion.liveRealTopics,
    pion.liveRealCalls,
  );

  return {
    topicsTotal: topics.length,
    topicsReal,
    topicsStaticStub,
    topicsShadowedByRuntimeStub,
    topicsMissing,
    topicsRealPct: Number(((topicsReal / topics.length) * 100).toFixed(2)),
    opsTotal: ops.length,
    opsReal,
    opsStub,
    opsMissing,
    opsRealPct: Number(((opsReal / ops.length) * 100).toFixed(2)),
    replaysTotal: replay.replaysTotal,
    replayTracesCount: replay.replayTracesCount,
    replayTapesCount: replay.replayTapesCount,
    replayFlowsCount: replay.replayFlowsCount,
    sfkeptFilesCount: replay.sfkeptFilesCount,
    replayClientMessagesChecked: replay.replayClientMessagesChecked,
    replayTopicsUnique: replayTopics.length,
    replayTopicsReal,
    replayTopicsStaticStub,
    replayTopicsMissing,
    replayCallsUnique: replayCalls.length,
    replayCallsReal,
    replayCallsStub,
    replayCallsMissing,
    pionProductRealCallsCount: pionProductRealCalls.length,
    pionProductStubCallsCount: pionProductStubCalls.length,
    pionProductRealCalls,
    pionProductStubCalls,
    callsShadowedByRuntimeStub,
    extraPionCallsNotInOpsOrReplays,
    pionViewProjectorsCount: pion.viewProjectors.length,
    extraPionTopicsNotInProtocol,
    scannedPionFiles: pion.scannedFiles,
    topics,
    ops,
    replayTopics,
    replayCalls,
    missingTopicsTop30: missingTopicsByReplayFreq.slice(0, 30),
    missingCallsTop30: missingCallsByReplayFreq.slice(0, 30),
    missingCombinedTop30,
    milestones,
    topicOnlyMilestones,
  };
}

function formatTextReport(ledger) {
  const lines = [];
  const pct = (n, d) => (d === 0 ? "0.0%" : `${((n / d) * 100).toFixed(1)}%`);

  lines.push("=== Pion client-core Real Quantitative Coverage Ledger ===");
  lines.push("");
  lines.push("1. Protocol Topics (`client/core-ts/src/protocol.ts` TOPICS):");
  lines.push(
    `   Total: ${ledger.topicsTotal} | real: ${ledger.topicsReal} (${pct(ledger.topicsReal, ledger.topicsTotal)}) | static-stub: ${ledger.topicsStaticStub} (${pct(ledger.topicsStaticStub, ledger.topicsTotal)}) | missing: ${ledger.topicsMissing} (${pct(ledger.topicsMissing, ledger.topicsTotal)})`,
  );
  const realTopicNames = ledger.topics.filter((t) => t.status === "real").map((t) => t.name);
  const stubTopicNames = ledger.topics.filter((t) => t.status === "static-stub").map((t) => t.name);
  lines.push(`   real (${realTopicNames.length}): ${realTopicNames.join(", ")}`);
  lines.push(`   static-stub (${stubTopicNames.length}): ${stubTopicNames.join(", ")}`);
  if (ledger.topicsShadowedByRuntimeStub.length > 0) {
    lines.push(
      `   shadowed-by-runtime-stub (${ledger.topicsShadowedByRuntimeStub.length}, counted as static-stub until handle_runtime_subscribe removes intercept): ${ledger.topicsShadowedByRuntimeStub.join(", ")}`,
    );
  }
  if (ledger.extraPionTopicsNotInProtocol.length > 0) {
    lines.push(
      `   non-protocol topics in Pion (${ledger.extraPionTopicsNotInProtocol.length}): ${ledger.extraPionTopicsNotInProtocol.map((x) => `${x.name}[${x.status}]`).join(", ")}`,
    );
  }
  lines.push("");

  lines.push("2. Protocol Ops (`client/core-ts/src/ops.ts` PARAMS):");
  lines.push(
    `   Total: ${ledger.opsTotal} | real: ${ledger.opsReal} (${pct(ledger.opsReal, ledger.opsTotal)}) | stub: ${ledger.opsStub} (${pct(ledger.opsStub, ledger.opsTotal)}) | missing: ${ledger.opsMissing} (${pct(ledger.opsMissing, ledger.opsTotal)})`,
  );
  const realOpNames = ledger.ops.filter((o) => o.status === "real").map((o) => o.name);
  lines.push(`   real in PARAMS (${realOpNames.length}): ${realOpNames.join(", ") || "(none)"}`);
  lines.push(
    `   product-reachable Pion calls (in ops.PARAMS or sfreplay): real=${ledger.pionProductRealCallsCount} (${ledger.pionProductRealCalls.join(", ") || "none"}), stub=${ledger.pionProductStubCallsCount} (${ledger.pionProductStubCalls.join(", ") || "none"})`,
  );
  if (ledger.callsShadowedByRuntimeStub.length > 0) {
    lines.push(
      `   shadowed-by-runtime-stub calls (${ledger.callsShadowedByRuntimeStub.length}, counted as stub): ${ledger.callsShadowedByRuntimeStub.join(", ")}`,
    );
  }
  if (ledger.extraPionCallsNotInOpsOrReplays.length > 0) {
    lines.push(
      `   non-replay / extra calls in Pion (${ledger.extraPionCallsNotInOpsOrReplays.length}, neither in ops.PARAMS nor in ${ledger.replaysTotal} sfreplays): ${ledger.extraPionCallsNotInOpsOrReplays.map((x) => `${x.name}[${x.status}]`).join(", ")}`,
    );
  }
  lines.push("");

  lines.push("3. Real `apps/mbui` `sfreplay` Recordings:");
  lines.push(
    `   Recordings: ${ledger.replaysTotal} total (${ledger.replayTracesCount} e2e/traces/*.trace + ${ledger.replayTapesCount} e2e/tapes/*.trace) | flow tests: ${ledger.replayFlowsCount} | sfkept files: ${ledger.sfkeptFilesCount} | ClientMessages: ${ledger.replayClientMessagesChecked}`,
  );
  lines.push(
    `   Replay Topics (${ledger.replayTopicsUnique} unique): real=${ledger.replayTopicsReal} (${pct(ledger.replayTopicsReal, ledger.replayTopicsUnique)}), static-stub=${ledger.replayTopicsStaticStub}, missing=${ledger.replayTopicsMissing}`,
  );
  lines.push(
    `   Replay Calls  (${ledger.replayCallsUnique} unique): real=${ledger.replayCallsReal} (${pct(ledger.replayCallsReal, ledger.replayCallsUnique)}), stub=${ledger.replayCallsStub}, missing=${ledger.replayCallsMissing}`,
  );
  lines.push("");

  lines.push("4. Missing Top-30 (Topics + Calls ranked by `sfreplay` frequency, excluding `real`):");
  ledger.missingCombinedTop30.forEach((item, idx) => {
    lines.push(
      `   ${String(idx + 1).padStart(2, " ")}. [${item.kind.padEnd(5, " ")}] ${item.name.padEnd(28, " ")} status=${item.status.padEnd(11, " ")} replays=${String(item.replayCount).padStart(3, " ")}/${ledger.replaysTotal} msgs=${String(item.messageCount).padStart(4, " ")} (${item.sourceSet})`,
    );
  });
  lines.push("");

  lines.push("5. Missing Topics Top-30 (ranked by `sfreplay` frequency):");
  ledger.missingTopicsTop30.forEach((t, idx) => {
    lines.push(
      `   ${String(idx + 1).padStart(2, " ")}. ${t.name.padEnd(24, " ")} status=${t.status.padEnd(11, " ")} replays=${String(t.replayCount).padStart(3, " ")}/${ledger.replaysTotal} msgs=${String(t.messageCount).padStart(4, " ")}`,
    );
  });
  lines.push("");

  lines.push("6. Missing Calls/Ops Top-30 (ranked by `sfreplay` frequency):");
  ledger.missingCallsTop30.forEach((c, idx) => {
    const tag = c.inOpsParams ? "ops.PARAMS" : "core-local";
    lines.push(
      `   ${String(idx + 1).padStart(2, " ")}. ${c.name.padEnd(30, " ")} status=${c.status.padEnd(7, " ")} replays=${String(c.replayCount).padStart(3, " ")}/${ledger.replaysTotal} msgs=${String(c.messageCount).padStart(4, " ")} (${tag})`,
    );
  });
  lines.push("");

  lines.push("7. `sfreplay` Full-Coverage Milestones (Topics + Calls, real-only):");
  lines.push(
    `   Currently 100%-covered replays: ${ledger.milestones.currentlyCoveredReplays}/${ledger.replaysTotal} (${ledger.milestones.currentlyCoveredPct}%)`,
  );
  for (const [label, key] of [
    ["80%", "p80"],
    ["95%", "p95"],
    ["100%", "p100"],
  ]) {
    const m = ledger.milestones.targets[key];
    if (!m) continue;
    lines.push(
      `   -> ${label} (${m.coveredReplays}/${m.totalReplays} = ${m.achievedPct}%): needs +${m.itemsRequiredCount} items (${m.topicsRequiredCount} topics, ${m.callsRequiredCount} calls)`,
    );
    lines.push(`      topics: ${m.topicsRequired.join(", ") || "(none)"}`);
    lines.push(`      calls:  ${m.callsRequired.join(", ") || "(none)"}`);
  }
  lines.push("");

  lines.push("8. `sfreplay` Topic-Only Milestones (real-only):");
  lines.push(
    `   Currently topic-covered replays: ${ledger.topicOnlyMilestones.currentlyCoveredReplays}/${ledger.replaysTotal} (${ledger.topicOnlyMilestones.currentlyCoveredPct}%)`,
  );
  for (const [label, key] of [
    ["80%", "p80"],
    ["95%", "p95"],
    ["100%", "p100"],
  ]) {
    const m = ledger.topicOnlyMilestones.targets[key];
    if (!m) continue;
    lines.push(
      `   -> ${label} (${m.coveredReplays}/${m.totalReplays} = ${m.achievedPct}%): needs +${m.topicsRequiredCount} topics: ${m.topicsRequired.join(", ") || "(none)"}`,
    );
  }

  return lines.join("\n");
}

// CLI entrypoint
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const asJson = process.argv.includes("--json");
  const ledger = buildCoverageLedger(defaultRepoRoot);
  if (asJson) {
    process.stdout.write(`${JSON.stringify(ledger, null, 2)}\n`);
  } else {
    process.stdout.write(`${formatTextReport(ledger)}\n`);
  }
}
