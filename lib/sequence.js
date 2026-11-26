// Pure helpers for haptic-notify: sequence parsing, hardware-safety budgeting
// and rate-limit decisions. Kept free of I/O so it can be unit tested and reused
// by the lab server.

/** Firmware waveform ids exposed by the actuator. Anything else is rejected. */
export const WAVEFORMS = new Set([1, 2, 3, 4, 5, 6, 15, 16]);

/**
 * Parse `"on,off[,waveform,intensity,frequency];..."` into notes.
 * Returns null on malformed input — callers must fail closed.
 */
export function parseSequence(raw) {
  if (typeof raw !== "string" || raw.trim() === "") return null;
  const notes = [];
  for (const chunk of raw.split(";")) {
    if (chunk.trim() === "") continue;
    const parts = chunk.split(",").map((value) => Number(value.trim()));
    if (parts.length < 2 || parts.some(Number.isNaN)) return null;
    const [on, off, waveform = 4, intensity = 1.4, frequency = 0.4] = parts;
    if (!WAVEFORMS.has(waveform)) return null;
    if (on < 0 || off < 0) return null;
    notes.push({ on, off, waveform, intensity, frequency });
  }
  return notes.length > 0 ? notes : null;
}

/** Render notes back into the `--sequence` wire format. */
export function serialize(notes) {
  return notes
    .map((n) => `${n.on},${n.off},${n.waveform},${n.intensity},${n.frequency}`)
    .join(";");
}

/**
 * Clamp/clip a sequence to the hardware-protection budget before it reaches the
 * actuator. Intensity is clamped down to the cap; a sequence longer than the
 * per-alert budget is refused outright rather than silently truncated.
 * @returns {{notes: Array|null, adjusted: string[], reason?: string}}
 */
export function enforceSafety(notes, safety = {}) {
  if (!safety || safety.enabled === false) return { notes, adjusted: [] };
  const maxIntensity = safety.maxIntensity ?? 1.6;
  const maxTotalMs = safety.maxTotalMs ?? 800;

  const adjusted = [];
  const clamped = notes.map((note) => {
    const intensity = Math.min(note.intensity, maxIntensity);
    if (intensity !== note.intensity) adjusted.push(`intensity ${note.intensity}→${intensity}`);
    return { ...note, intensity };
  });

  const total = totalMs(clamped);
  if (total > maxTotalMs) {
    return { notes: null, adjusted, reason: `sequence ${total}ms exceeds budget ${maxTotalMs}ms` };
  }
  return { notes: clamped, adjusted };
}

/**
 * `done` and `idle` are the same underlying event: herdr reports `done` for a
 * completion you have not looked at yet and `idle` once the pane is in view.
 * They can race between the event and the re-check, so compare classes.
 */
export function statusClass(status) {
  return status === "done" || status === "idle" ? "complete" : status;
}

/**
 * Gate on `minGapMs` since the last buzz and `maxAlertsPerMinute`.
 * @returns {string|null} null when allowed, otherwise a human-readable reason.
 */
export function rateLimitReason(safety, history, now = Date.now()) {
  if (!safety || safety.enabled === false) return null;
  const minGapMs = safety.minGapMs ?? 2000;
  const last = history.at(-1);
  if (typeof last === "number" && now - last < minGapMs) {
    return `cooldown ${now - last}ms < ${minGapMs}ms`;
  }
  const lastMinute = history.filter((stamp) => now - stamp < 60_000);
  const cap = safety.maxAlertsPerMinute ?? 12;
  if (lastMinute.length >= cap) return `${lastMinute.length} alerts in the last minute (cap ${cap})`;
  return null;
}

export function totalMs(notes) {
  return notes.reduce((sum, note) => sum + note.on + note.off, 0);
}

export function onMs(notes) {
  return notes.reduce((sum, note) => sum + note.on, 0);
}

/**
 * Rough "how aggressive is this" summary. A tap costs about 21 ms of driver
 * round-trip, so `taps` approximates how many actuations will be emitted.
 */
export function summarize(notes) {
  const total = totalMs(notes);
  const on = onMs(notes);
  return {
    notes: notes.length,
    totalMs: total,
    onMs: on,
    dutyPercent: total ? Math.round((on / total) * 100) : 0,
    peakIntensity: notes.reduce((max, note) => Math.max(max, note.intensity), 0),
    taps: Math.max(1, Math.round(on / 21)),
  };
}
