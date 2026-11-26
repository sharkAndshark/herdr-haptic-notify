#!/usr/bin/env node
// herdr plugin: haptic-notify — trackpad haptic notifications on macOS.
//
// herdr runs this once per `pane.agent_status_changed` event and hands us the
// event JSON in HERDR_PLUGIN_EVENT_JSON:
//
//   {"event":"pane_agent_status_changed",
//    "data":{"type":"pane_agent_status_changed","pane_id":"w1:p1",
//            "workspace_id":"w1","agent":"pi","agent_status":"done"}}
//
// Only `data.pane_id` and `data.agent_status` are required; everything else is
// treated as optional so a wire-format change degrades instead of throwing.
//
// Decision order (cheap checks first):
//   enabled → status configured → per-pane+status dedupe → per-pane suppression
//   → global rate limit → debounce → live re-check via `herdr agent get`
//   → hardware-safety budget → fire `taptic --sequence`.
//
// Everything else lives in ./lib/sequence.js so it can be unit tested.

import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, renameSync, statSync, truncateSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import {
  enforceSafety,
  parseSequence,
  rateLimitReason,
  serialize,
  statusClass,
  summarize,
} from "./lib/sequence.js";

const DEFAULT_CONFIG = {
  enabled: true,
  taptic: "", // empty → <plugin>/bin/taptic, then `taptic` on PATH
  debounceMs: 400,
  statuses: {},
  onlyBackgroundPanes: false,
  safety: {
    enabled: true,
    maxTotalMs: 800,
    maxIntensity: 1.6,
    minGapMs: 2000,
    maxAlertsPerMinute: 12,
    paneSuppressMs: 15000,
  },
  log: true,
};

const LOG_LIMIT_BYTES = 256 * 1024;

const env = (name) => (process.env[name]?.length ? process.env[name] : undefined);
const pluginRoot = () => env("HERDR_PLUGIN_ROOT") ?? join(homedir(), ".config/herdr/plugins/haptic-notify");
const configDir = () =>
  env("HERDR_PLUGIN_CONFIG_DIR") ?? join(homedir(), ".config/herdr/plugins/config/haptic-notify");
const stateDir = () =>
  env("HERDR_PLUGIN_STATE_DIR") ?? join(homedir(), ".local/state/herdr/plugins/haptic-notify");
const expandHome = (path) => (path.startsWith("~/") ? join(homedir(), path.slice(2)) : path);
const tapticBin = (config) =>
  config.taptic ? expandHome(config.taptic) : join(pluginRoot(), "bin", "taptic");

function readConfig() {
  const config = structuredClone(DEFAULT_CONFIG);
  try {
    const raw = JSON.parse(readFileSync(join(configDir(), "config.json"), "utf8"));
    if (raw && typeof raw === "object") {
      Object.assign(config, raw);
      config.safety = { ...DEFAULT_CONFIG.safety, ...(raw.safety ?? {}) };
    }
  } catch {
    // missing or malformed config keeps the defaults
  }
  return config;
}

function log(entry) {
  try {
    mkdirSync(stateDir(), { recursive: true });
    const path = join(stateDir(), "haptic-notify.log");
    try {
      if (statSync(path).size > LOG_LIMIT_BYTES) truncateSync(path, 0);
    } catch {
      // first write
    }
    writeFileSync(path, `${new Date().toISOString()} ${JSON.stringify(entry)}\n`, { flag: "a" });
  } catch {
    // logging is best effort — never fail the notification because of it
  }
}

// --------------------------------------------------------------- small state

const encode = (value) => Buffer.from(value, "utf8").toString("base64url").replace(/=+$/, "");

function readJson(path, fallback) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJson(path, value) {
  const dir = path.slice(0, path.lastIndexOf("/"));
  mkdirSync(dir, { recursive: true });
  const temp = `${path}.tmp-${process.pid}`;
  writeFileSync(temp, JSON.stringify(value));
  renameSync(temp, path);
}

const dedupePath = (paneId, status) => join(stateDir(), "seen", `${encode(`${paneId}|${status}`)}.json`);
const recentPath = (paneId) => join(stateDir(), "recent", `${encode(paneId)}.json`);
const ratePath = () => join(stateDir(), "rate.json");

const alreadyFired = (paneId, status) => readJson(dedupePath(paneId, status), null)?.fired === true;
const markFired = (paneId, status) =>
  writeJson(dedupePath(paneId, status), { pane: paneId, status, fired: true, at: Date.now() });

function clearFired(paneId) {
  for (const status of ["done", "idle", "blocked"]) {
    try {
      writeJson(dedupePath(paneId, status), { fired: false });
    } catch {
      // ignore
    }
  }
}

function msSincePaneFired(paneId) {
  const stamp = readJson(recentPath(paneId), null)?.at;
  return typeof stamp === "number" ? Date.now() - stamp : Infinity;
}

function markPaneFired(paneId) {
  try {
    writeJson(recentPath(paneId), { pane: paneId, at: Date.now() });
  } catch {
    // best effort
  }
}

function readRate() {
  const fired = readJson(ratePath(), null)?.fired_at;
  return Array.isArray(fired) ? fired.filter((stamp) => Date.now() - stamp < 120_000) : [];
}

function writeRate(times) {
  try {
    writeJson(ratePath(), { fired_at: times });
  } catch {
    // best effort
  }
}

// ----------------------------------------------------------------- firing

function fire(config, notes) {
  const sequence = serialize(notes);
  const bin = tapticBin(config);
  const child = spawn(bin, ["--sequence", sequence], { stdio: "ignore", detached: true });
  child.on("error", (error) => log({ kind: "taptic-error", bin, error: error.message }));
  child.unref();
  return { sequence, bin };
}

// ------------------------------------------------------------- herdr re-ask

function agentState(binPath, paneId) {
  return new Promise((resolve) => {
    const child = spawn(binPath, ["agent", "get", paneId], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", (error) => resolve({ ok: false, error: error.message }));
    child.on("close", (code) => {
      if (code !== 0) {
        resolve({ ok: false, error: stderr.trim() || `exit ${code}` });
        return;
      }
      try {
        const agent = JSON.parse(stdout)?.result?.agent;
        resolve({
          ok: true,
          status: typeof agent?.agent_status === "string" ? agent.agent_status.toLowerCase() : null,
          focused: agent?.focused === true,
          title: agent?.terminal_title_stripped ?? agent?.terminal_title,
        });
      } catch {
        resolve({ ok: false, error: "unparsable `herdr agent get` output" });
      }
    });
  });
}

// ------------------------------------------------------------------- events

function parseEvent(raw) {
  const data = JSON.parse(raw)?.data;
  if (typeof data?.pane_id !== "string" || !data.pane_id) return { error: "data.pane_id missing" };
  if (typeof data?.agent_status !== "string" || !data.agent_status) {
    return { error: "data.agent_status missing" };
  }
  return {
    paneId: data.pane_id,
    status: data.agent_status.toLowerCase(),
    agent: typeof data.agent === "string" ? data.agent : undefined,
    workspaceId: typeof data.workspace_id === "string" ? data.workspace_id : undefined,
  };
}

async function main() {
  const config = readConfig();
  const herdrBin = env("HERDR_BIN_PATH") ?? "herdr";
  const argv = process.argv.slice(2);

  // `node hook.js --test done` — fire a configured pattern without an event.
  const testIndex = argv.indexOf("--test");
  if (testIndex !== -1) {
    const status = argv[testIndex + 1] ?? "done";
    const notes = parseSequence(config.statuses?.[status]?.sequence);
    if (!notes) {
      console.error(`haptic-notify: no usable sequence configured for '${status}'`);
      process.exit(2);
    }
    const safe = enforceSafety(notes, config.safety);
    if (!safe.notes) {
      console.error(`haptic-notify: ${safe.reason}`);
      process.exit(2);
    }
    const { sequence, bin } = fire(config, safe.notes);
    log({ kind: "self-test", status, sequence, bin });
    console.log(`haptic-notify: fired ${status} via ${bin} (${sequence})`);
    return;
  }

  if (config.enabled === false) return;

  const raw = env("HERDR_PLUGIN_EVENT_JSON");
  if (!raw) return;

  let event;
  try {
    event = parseEvent(raw);
  } catch (error) {
    log({ kind: "parse-error", error: error.message });
    return;
  }
  if (event.error) {
    log({ kind: "parse-error", error: event.error, raw: raw.slice(0, 400) });
    return;
  }

  const entry = config.statuses?.[event.status];
  if (config.log !== false) log({ kind: "event", ...event, notify: Boolean(entry) });

  if (!entry) {
    clearFired(event.paneId); // leaving a notify-worthy state re-arms the pane
    return;
  }

  const notes = parseSequence(entry.sequence);
  if (!notes) {
    log({ kind: "bad-sequence", status: event.status, sequence: entry.sequence });
    return;
  }

  if (alreadyFired(event.paneId, event.status)) {
    log({ kind: "skip", reason: "already fired for this pane+status", pane: event.paneId });
    return;
  }

  const suppressMs = entry.suppressAfterMs ?? config.safety?.paneSuppressMs ?? 0;
  if (suppressMs > 0) {
    const since = msSincePaneFired(event.paneId);
    if (since < suppressMs) {
      log({ kind: "skip", reason: `pane buzzed ${Math.round(since / 1000)}s ago (< ${suppressMs / 1000}s)`, pane: event.paneId });
      return;
    }
  }

  const history = readRate();
  const throttled = rateLimitReason(config.safety, history);
  if (throttled) {
    log({ kind: "skip", reason: `rate limited: ${throttled}`, pane: event.paneId });
    return;
  }

  // herdr's status detection is heuristic and can flap; act only on a status
  // that still holds after the debounce window.
  if (config.debounceMs > 0) await sleep(config.debounceMs);

  const current = await agentState(herdrBin, event.paneId);
  if (!current.ok) {
    log({ kind: "recheck-failed", pane: event.paneId, error: current.error });
    return;
  }
  if (current.status === null) {
    clearFired(event.paneId);
    return;
  }
  if (statusClass(current.status) !== statusClass(event.status)) {
    log({ kind: "skip", reason: `status moved on (${event.status} -> ${current.status})`, pane: event.paneId });
    return;
  }
  if (config.onlyBackgroundPanes && current.focused) {
    log({ kind: "skip", reason: "pane is focused", pane: event.paneId });
    return;
  }

  const safe = enforceSafety(notes, config.safety);
  if (!safe.notes) {
    log({ kind: "skip", reason: safe.reason, pane: event.paneId });
    return;
  }

  const { sequence, bin } = fire(config, safe.notes);
  markFired(event.paneId, event.status);
  markPaneFired(event.paneId);
  writeRate([...history, Date.now()]);
  log({
    kind: "fired",
    pane: event.paneId,
    status: event.status,
    label: entry.label,
    sequence,
    bin,
    summary: summarize(safe.notes),
    adjusted: safe.adjusted,
    title: current.title,
  });
}

main().catch((error) => {
  log({ kind: "crash", error: String(error?.message ?? error) });
  process.exit(1);
});
