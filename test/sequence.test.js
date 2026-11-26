import assert from "node:assert/strict";
import test from "node:test";

import {
  enforceSafety,
  parseSequence,
  rateLimitReason,
  serialize,
  statusClass,
  summarize,
  totalMs,
} from "../lib/sequence.js";

const M1 = "70,70,3,1.3,0.34;70,80,3,1.3,0.5;130,0,3,1.35,0.66";

test("parseSequence reads the m1 preset", () => {
  const notes = parseSequence(M1);
  assert.equal(notes.length, 3);
  assert.deepEqual(notes[0], { on: 70, off: 70, waveform: 3, intensity: 1.3, frequency: 0.34 });
  assert.equal(totalMs(notes), 420);
});

test("parseSequence defaults waveform/intensity/frequency", () => {
  const [note] = parseSequence("50,50");
  assert.deepEqual(note, { on: 50, off: 50, waveform: 4, intensity: 1.4, frequency: 0.4 });
});

test("parseSequence rejects invalid waveform ids", () => {
  for (const waveform of [0, 7, 14, 17, 99]) {
    assert.equal(parseSequence(`50,50,${waveform},1,0.4`), null, `waveform ${waveform}`);
  }
});

test("parseSequence rejects malformed input", () => {
  for (const raw of ["", "   ", "abc", "50", "50,abc", "50,50,4,1,0.4;oops", null, undefined, 42]) {
    assert.equal(parseSequence(raw), null, String(raw));
  }
});

test("serialize round-trips through parseSequence", () => {
  const notes = parseSequence(M1);
  assert.equal(serialize(notes), M1);
  assert.deepEqual(parseSequence(serialize(notes)), notes);
});

test("enforceSafety clamps intensity but keeps the feel", () => {
  const notes = parseSequence("70,70,4,2.0,0.4;100,0,6,1.9,0.6");
  const safe = enforceSafety(notes, { enabled: true, maxIntensity: 1.6, maxTotalMs: 800 });
  assert.equal(safe.notes[0].intensity, 1.6);
  assert.equal(safe.notes[1].intensity, 1.6);
  assert.equal(safe.adjusted.length, 2);
});

test("enforceSafety refuses sequences over the per-alert budget", () => {
  const notes = parseSequence("500,500,4,1.4,0.4;500,0,4,1.4,0.4");
  const safe = enforceSafety(notes, { enabled: true, maxIntensity: 1.6, maxTotalMs: 800 });
  assert.equal(safe.notes, null);
  assert.match(safe.reason, /exceeds budget/);
});

test("enforceSafety is a no-op when disabled", () => {
  const notes = parseSequence("500,500,4,2.0,0.4;500,0,4,2.0,0.4");
  const safe = enforceSafety(notes, { enabled: false });
  assert.equal(safe.notes, notes);
  assert.deepEqual(safe.adjusted, []);
});

test("statusClass treats done and idle as the same completion", () => {
  assert.equal(statusClass("done"), "complete");
  assert.equal(statusClass("idle"), "complete");
  assert.equal(statusClass("working"), "working");
  assert.equal(statusClass("blocked"), "blocked");
});

test("rateLimitReason enforces the cooldown", () => {
  const safety = { enabled: true, minGapMs: 2000, maxAlertsPerMinute: 12 };
  const now = 10_000_000;
  assert.match(rateLimitReason(safety, [now - 45], now), /cooldown 45ms/);
  assert.equal(rateLimitReason(safety, [now - 2500], now), null);
  assert.equal(rateLimitReason(safety, [], now), null);
});

test("rateLimitReason enforces the per-minute cap", () => {
  const safety = { enabled: true, minGapMs: 2000, maxAlertsPerMinute: 3 };
  const now = 10_000_000;
  const history = [now - 5000, now - 4000, now - 3000];
  assert.match(rateLimitReason(safety, history, now), /3 alerts in the last minute/);
});

test("rateLimitReason ignores history outside the 60s window", () => {
  const safety = { enabled: true, minGapMs: 100, maxAlertsPerMinute: 2 };
  const now = 10_000_000;
  assert.equal(rateLimitReason(safety, [now - 120_000, now - 90_000], now), null);
});

test("summarize reports duty cycle and peak intensity", () => {
  const summary = summarize(parseSequence(M1));
  assert.equal(summary.totalMs, 420);
  assert.equal(summary.onMs, 270);
  assert.equal(summary.dutyPercent, 64);
  assert.equal(summary.peakIntensity, 1.35);
  assert.ok(summary.taps >= 10);
});
