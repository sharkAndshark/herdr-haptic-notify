import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";

const HOOK = join(dirname(dirname(fileURLToPath(import.meta.url))), "hook.js");
const M1 = "70,70,3,1.3,0.34;70,80,3,1.3,0.5;130,0,3,1.35,0.66";

/** The helper is spawned detached, so give the OS a moment to actually run it. */
async function waitForPlays(box, expected, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (box.plays().length >= expected) return box.plays();
    await sleep(40);
  }
  return box.plays();
}

/** For "nothing should fire" assertions: wait long enough to be meaningful. */
const settle = () => sleep(700);

/**
 * Spin up a throwaway environment: fake `herdr` (answers `agent get`) and fake
 * `taptic` (records what it was asked to play) so the hook can be exercised
 * end to end without herdr or real hardware.
 */
function sandbox({ status = "done", statuses = ["done", "blocked", "idle"], sequence = M1, safety, writeConfig = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), "haptic-test-"));
  const bin = join(root, "bin");
  const config = join(root, "config");
  const state = join(root, "state");
  mkdirSync(bin, { recursive: true });
  mkdirSync(config, { recursive: true });

  const played = join(root, "played.log");
  writeFileSync(
    join(bin, "taptic"),
    `#!/bin/sh\nprintf '%s\\n' "$*" >> "${played}"\nexit 0\n`,
  );
  chmodSync(join(bin, "taptic"), 0o755);

  writeFileSync(
    join(bin, "herdr"),
    `#!/bin/sh
case "$1 $2" in
  "agent get") printf '{"result":{"agent":{"agent_status":"%s","focused":false,"terminal_title_stripped":"fake"}}}' "${status}" ;;
  *) printf '{}' ;;
esac
`,
  );
  chmodSync(join(bin, "herdr"), 0o755);

  if (writeConfig) writeFileSync(
    join(config, "config.json"),
    JSON.stringify(
      {
        enabled: true,
        taptic: join(bin, "taptic"),
        debounceMs: 0,
        statuses: Object.fromEntries(
          statuses.map((name) => [name, { label: "test", sequence, suppressAfterMs: 0 }]),
        ),
        safety: safety ?? {
          enabled: true,
          maxTotalMs: 800,
          maxIntensity: 1.6,
          minGapMs: 0,
          maxAlertsPerMinute: 99,
          paneSuppressMs: 0,
        },
        log: true,
      },
      null,
      2,
    ),
  );

  const fire = (eventStatus, paneId = "w1:p1") =>
    execFileSync(process.execPath, [HOOK], {
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        HERDR_PLUGIN_ROOT: root,           // so <plugin>/bin/taptic resolves to the fake
        HERDR_PLUGIN_CONFIG_DIR: config,
        HERDR_PLUGIN_STATE_DIR: state,
        HERDR_BIN_PATH: join(bin, "herdr"),
        HERDR_PLUGIN_EVENT_JSON: JSON.stringify({
          event: "pane_agent_status_changed",
          data: { type: "pane_agent_status_changed", pane_id: paneId, agent_status: eventStatus },
        }),
      },
      stdio: "pipe",
    });

  const plays = () => (existsSync(played) ? readFileSync(played, "utf8").trim().split("\n").filter(Boolean) : []);
  const log = () =>
    existsSync(join(state, "haptic-notify.log"))
      ? readFileSync(join(state, "haptic-notify.log"), "utf8")
          .trim()
          .split("\n")
          .map((line) => JSON.parse(line.slice(line.indexOf(" ") + 1)))
      : [];

  return { root, fire, plays, log };
}

test("fires once on a done event", async () => {
  const box = sandbox();
  box.fire("done");
  const plays = await waitForPlays(box, 1);
  assert.equal(plays.length, 1);
  assert.match(plays[0], /--sequence/);
  assert.ok(box.plays()[0].includes(M1));
  assert.ok(box.log().some((entry) => entry.kind === "fired"));
});

test("dedupes repeated events for the same pane and status", async () => {
  const box = sandbox();
  box.fire("done");
  box.fire("done");
  const plays = await waitForPlays(box, 2);
  await settle();
  assert.equal(plays.length, 1);
  assert.ok(box.log().some((entry) => entry.reason === "already fired for this pane+status"));
});

test("treats idle as the same completion as done", async () => {
  const box = sandbox({ status: "idle" });
  box.fire("done");
  const plays = await waitForPlays(box, 1);
  assert.equal(plays.length, 1, "idle must satisfy the done re-check");
});

test("skips when the status moved on before the re-check", async () => {
  const box = sandbox({ status: "working" });
  box.fire("done");
  await settle();
  assert.equal(box.plays().length, 0);
  assert.ok(box.log().some((entry) => entry.reason?.includes("status moved on")));
});

test("ignores statuses that are not configured", async () => {
  const box = sandbox({ statuses: ["blocked"], status: "working" });
  box.fire("working");
  await settle();
  assert.equal(box.plays().length, 0);
});

test("refuses a sequence over the safety budget", async () => {
  const box = sandbox({ sequence: "500,500,4,1.4,0.4;500,0,4,1.4,0.4" });
  box.fire("done");
  await settle();
  assert.equal(box.plays().length, 0);
  assert.ok(box.log().some((entry) => entry.reason?.includes("exceeds budget")));
});

test("rate limits bursts across panes", async () => {
  const box = sandbox({
    safety: { enabled: true, maxTotalMs: 800, maxIntensity: 1.6, minGapMs: 60_000, maxAlertsPerMinute: 99, paneSuppressMs: 0 },
  });
  box.fire("done", "w1:p1");
  box.fire("done", "w2:p1");
  const plays = await waitForPlays(box, 2);
  await settle();
  assert.equal(plays.length, 1);
  assert.ok(box.log().some((entry) => entry.reason?.includes("rate limited")));
});

test("works with no config file at all (fresh install)", async () => {
  const box = sandbox({ writeConfig: false });
  box.fire("done");
  const plays = await waitForPlays(box, 1);
  assert.equal(plays.length, 1, "a fresh install must buzz without any config");
  assert.ok(plays[0].includes(M1), "built-in default pattern should be the m1 chime");
});

test("an explicitly empty statuses object disables everything", async () => {
  const box = sandbox({ statuses: [] });
  box.fire("done");
  await settle();
  assert.equal(box.plays().length, 0, "empty statuses must mean 'never fire'");
});

test("--test fires the configured pattern without an event", async () => {
  const box = sandbox();
  execFileSync(process.execPath, [HOOK, "--test", "done"], {
    env: {
      ...process.env,
      HERDR_PLUGIN_ROOT: box.root,
      HERDR_PLUGIN_CONFIG_DIR: join(box.root, "config"),
      HERDR_PLUGIN_STATE_DIR: join(box.root, "state"),
    },
    stdio: "pipe",
  });
  const plays = await waitForPlays(box, 1);
  assert.equal(plays.length, 1);
});
