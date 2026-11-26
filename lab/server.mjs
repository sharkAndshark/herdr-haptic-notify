#!/usr/bin/env node
// Haptic Lab — local web UI for auditioning trackpad haptic patterns.
//
// A browser cannot drive the Taptic Engine, so this tiny server bridges the
// gap: the page POSTs a preset (or raw notes), the server clamps the numbers,
// serialises them into a `taptic --sequence` string and runs the local helper.
//
// Bound to 127.0.0.1 only. It never runs arbitrary commands: every field is
// parsed as a number, range-checked and re-serialised.
//
//   node lab/server.mjs [--port 8765] [--open] [--idle-timeout SECONDS]
//
// `--idle-timeout` makes the process exit on its own after that many seconds
// without a request, so it can be launched from a herdr action (which expects
// a short-lived child) instead of lingering forever.

import { spawn } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { WAVEFORMS, parseSequence, serialize, summarize } from "../lib/sequence.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(HERE);
const PRESETS = join(HERE, "presets.json");
const UI = join(HERE, "ui.html");

const MAX_NOTES = 16;
const MAX_TOTAL_MS = 3000;

let current = null;
let lastRequestAt = Date.now();

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value));
}

/** Range-check notes coming from the browser; throws on anything unusable. */
function sanitize(raw) {
  if (!Array.isArray(raw) || raw.length === 0) throw new Error("notes must be a non-empty array");
  if (raw.length > MAX_NOTES) throw new Error(`too many notes (max ${MAX_NOTES})`);

  const notes = raw.map((note) => {
    if (!note || typeof note !== "object") throw new Error("each note must be an object");
    const on = Math.round(clamp(Number(note.on ?? 0), 0, 2000));
    const off = Math.round(clamp(Number(note.off ?? 0), 0, 5000));
    const waveform = Math.round(clamp(Number(note.waveform ?? 4), 1, 16));
    if (!WAVEFORMS.has(waveform)) throw new Error(`waveform ${waveform} is not supported`);
    const intensity = Number(clamp(Number(note.intensity ?? 1.4), 0, 2).toFixed(2));
    const frequency = Number(clamp(Number(note.frequency ?? 0.4), 0, 2).toFixed(2));
    if (!Number.isFinite(on) || !Number.isFinite(off) || !Number.isFinite(intensity)) {
      throw new Error("non-numeric note field");
    }
    if (on <= 0 && off <= 0) throw new Error("note has no duration");
    return { on, off, waveform, intensity, frequency };
  });

  const total = notes.reduce((sum, note) => sum + note.on + note.off, 0);
  if (total > MAX_TOTAL_MS) throw new Error(`sequence too long (${total} ms > ${MAX_TOTAL_MS} ms)`);
  return notes;
}

function tapticPath() {
  const candidates = [
    process.env.HAPTIC_TAPTIC,
    join(ROOT, "bin", "taptic"),
    join(homedir(), ".local/bin/taptic"),
    "/opt/homebrew/bin/taptic",
    "/usr/local/bin/taptic",
  ].filter(Boolean);
  return candidates.find((path) => existsSync(path)) ?? null;
}

function loadPresets() {
  return JSON.parse(readFileSync(PRESETS, "utf8"));
}

function savePresets(data) {
  writeFileSync(PRESETS, `${JSON.stringify(data, null, 2)}\n`);
}

function stopCurrent() {
  if (current && current.exitCode === null) {
    try {
      current.kill("SIGTERM");
    } catch {
      // already gone
    }
  }
  current = null;
}

function play(notes) {
  const bin = tapticPath();
  if (!bin) throw new Error("taptic helper not found — run `make build` first");

  const sequence = serialize(notes);
  stopCurrent();

  return new Promise((resolve, reject) => {
    const child = spawn(bin, ["--sequence", sequence], { stdio: ["ignore", "ignore", "pipe"] });
    current = child;
    let stderr = "";
    child.stderr.on("data", (chunk) => (stderr += chunk));
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("taptic timed out"));
    }, 10_000);
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      current = null;
      resolve({ sequence, bin, exit_code: code, stderr: stderr.trim(), ...summarize(notes) });
    });
  });
}

// ------------------------------------------------------------------ http glue

function send(res, status, body, contentType = "application/json; charset=utf-8") {
  const payload = typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": contentType,
    "Content-Length": Buffer.byteLength(payload),
    "Cache-Control": "no-store",
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (chunk) => {
      data += chunk;
      if (data.length > 64 * 1024) reject(new Error("body too large"));
    });
    req.on("end", () => {
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch (error) {
        reject(new Error(`bad json: ${error.message}`));
      }
    });
    req.on("error", reject);
  });
}

async function handle(req, res) {
  const url = new URL(req.url, "http://127.0.0.1");

  if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
    send(res, 200, readFileSync(UI), "text/html; charset=utf-8");
    return;
  }
  if (req.method === "GET" && url.pathname === "/api/health") {
    const bin = tapticPath();
    send(res, 200, { ok: true, taptic: bin, exists: Boolean(bin) });
    return;
  }
  if (req.method === "GET" && url.pathname === "/api/presets") {
    send(res, 200, loadPresets());
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/play") {
    const body = await readBody(req);
    let notes;
    if (body.id) {
      const presets = loadPresets().presets;
      const preset = presets.find((item) => item.id === body.id);
      if (!preset) throw new Error(`unknown preset id ${JSON.stringify(body.id)}`);
      notes = sanitize(preset.notes);
    } else {
      notes = sanitize(body.notes);
    }
    send(res, 200, await play(notes));
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/stop") {
    stopCurrent();
    send(res, 200, { stopped: true });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/save") {
    const body = await readBody(req);
    const notes = sanitize(body.notes);
    const data = loadPresets();
    const preset = data.presets.find((item) => item.id === body.id);
    if (!preset) throw new Error(`unknown preset id ${JSON.stringify(body.id)}`);
    preset.notes = notes;
    savePresets(data);
    send(res, 200, { saved: preset.id, notes });
    return;
  }

  send(res, 404, { error: "not found" });
}

function flagValue(args, name) {
  const index = args.indexOf(name);
  return index !== -1 ? args[index + 1] : undefined;
}

function openInBrowser(url) {
  if (process.platform !== "darwin") return;
  spawn("open", [url], { stdio: "ignore", detached: true }).unref();
}

function main() {
  const args = process.argv.slice(2);
  const port = Number(flagValue(args, "--port") ?? process.env.HAPTIC_LAB_PORT ?? 8765);
  const open = args.includes("--open");
  const idleTimeout = Number(flagValue(args, "--idle-timeout") ?? 0);

  const server = createServer((req, res) => {
    lastRequestAt = Date.now();
    handle(req, res).catch((error) => send(res, 400, { error: error.message }));
  });

  server.on("error", (error) => {
    if (error.code === "EADDRINUSE") {
      const url = `http://127.0.0.1:${port}/`;
      console.log(`[haptic-lab] already running on ${url} — reusing it`);
      if (open) openInBrowser(url);
      process.exit(0);
    }
    console.error(`[haptic-lab] ${error.message}`);
    process.exit(1);
  });

  server.listen(port, "127.0.0.1", async () => {
    const url = `http://127.0.0.1:${port}/`;
    const bin = tapticPath();
    console.log(`[haptic-lab] listening on ${url}`);
    console.log(`[haptic-lab] taptic: ${bin ?? "NOT FOUND (run `make build`)"}`);
    console.log("[haptic-lab] Ctrl+C to stop");
    if (open) openInBrowser(url);
    if (idleTimeout > 0) {
      console.log(`[haptic-lab] exits after ${idleTimeout}s without a request`);
      setInterval(() => {
        if (Date.now() - lastRequestAt > idleTimeout * 1000) {
          console.log("[haptic-lab] idle — exiting");
          server.close();
          process.exit(0);
        }
      }, 5000).unref();
    }
  });
}

const invokedDirectly =
  process.argv[1] && fileURLToPath(import.meta.url) === (process.argv[1].startsWith("/") ? process.argv[1] : join(process.cwd(), process.argv[1]));

if (invokedDirectly) main();

// Exported for tests that want the clamping rules without booting a server.
export { sanitize, parseSequence };
