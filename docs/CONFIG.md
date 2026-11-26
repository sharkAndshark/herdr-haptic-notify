# Configuration reference

Everything here is **optional**: without a config file the built-in defaults apply (one `m1` chime for `done`,
`blocked` and `idle`, with the safety limits below). A file is only needed when you want to change something.

```sh
CFG="$(herdr plugin config-dir lucas.haptic-notify)/config.json"
# the installed plugin ships the example next to hook.js
cp "$(herdr plugin list --plugin lucas.haptic-notify --json \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).result.plugins[0].plugin_root))')/config.example.json" "$CFG"
```

(No network needed. `herdr plugin action invoke print-config --plugin lucas.haptic-notify` also prints the file when
none exists, e.g. to copy from.)

Edits take effect on the next event — no reload.

## Full file

```jsonc
{
  "enabled": true,
  "taptic": "",                 // empty → <plugin>/bin/taptic, then `taptic` on PATH
  "debounceMs": 400,            // re-check the agent status after this delay
  "statuses": {
    // herdr emits `done` for a completion you have not looked at and `idle`
    // once the pane is in view — subscribe to both to buzz either way.
    "done":    { "label": "m1", "sequence": "70,70,3,1.3,0.34;70,80,3,1.3,0.5;130,0,3,1.35,0.66", "suppressAfterMs": 15000 },
    "blocked": { "label": "m1", "sequence": "70,70,3,1.3,0.34;70,80,3,1.3,0.5;130,0,3,1.35,0.66", "suppressAfterMs": 15000 },
    "idle":    { "label": "m1", "sequence": "70,70,3,1.3,0.34;70,80,3,1.3,0.5;130,0,3,1.35,0.66", "suppressAfterMs": 15000 }
  },
  "onlyBackgroundPanes": false, // true → skip the pane you are looking at
  "safety": {
    "enabled": true,
    "maxTotalMs": 800,          // refuse any single alert longer than this
    "maxIntensity": 1.6,        // clamp amplitude (0–2, 2 = firmware max)
    "minGapMs": 2000,           // global cooldown between alerts
    "maxAlertsPerMinute": 12,
    "paneSuppressMs": 15000     // one buzz per pane per 15 s, any status
  },
  "log": true
}
```

`"statuses": {}` (explicitly empty) means **never fire** — that is how you mute everything while keeping the plugin
installed.

## Sequence grammar

```
onMs,offMs[,waveform,intensity,frequency] → notes joined with ";"
```

`on` keeps tapping for that long (each actuation costs ~21 ms of driver round-trip), `off` is silence. Example,
the default `m1`, a rising three-note chime of 420 ms:

```
70,70,3,1.3,0.34; 70,80,3,1.3,0.5; 130,0,3,1.35,0.66
```

| field | range | meaning |
|---|---|---|
| `waveform` | 1 back · 2 click · 3 weak buzz · 4 light tap · 5 medium tap · 6 strong tap · 15/16 low thud | firmware preset; anything else is rejected |
| `intensity` | 0–2 | amplitude multiplier, `1.0` ≈ firmware "Medium" |
| `frequency` | 0–2 | tone shift, **not** pitch; clarity peaks at `0.4`, gets duller toward `2.0` |

## Common tweaks

| goal | change |
|---|---|
| quieter / gentler | lower `intensity` (`1.35` → `0.9`), or switch waveform to `1` / `3` |
| more presence | raise `intensity` toward `1.6`, lengthen the last note (`130` → `180`) |
| shorter | drop the middle note |
| only unseen panes | delete `"idle"` from `statuses` |
| only background panes | `"onlyBackgroundPanes": true` |
| mute for a while | `"enabled": false` |
| longer patterns | raise `safety.maxTotalMs` deliberately (see below) |

To explore patterns instead of editing by hand: `herdr plugin action invoke open-lab --plugin lucas.haptic-notify`,
then copy the sequence it shows into the config.

## Decision pipeline

The hook runs once per `pane.agent_status_changed` event:

1. status configured? (`done` / `blocked` / `idle` by default; anything else is only logged)
2. dedupe — same pane + same status already fired
3. per-pane suppression — one buzz per pane per 15 s, any status
4. global rate limit — 2 s cooldown, 12 alerts/minute
5. debounce `debounceMs`, then live re-check via `herdr agent get`; `done` and `idle` are treated as one "complete"
   class so the two cannot race
6. safety budget — intensity clamped, over-long sequences refused
7. fire `taptic --sequence …` and wait for it to exit

`herdr plugin action invoke doctor --plugin lucas.haptic-notify` prints the last 8 decisions with the reason for each
skip, which is usually faster than reasoning about the list above.

## Hardware safety

The Taptic Engine is a linear resonant actuator: sustained loud drive is what wears it, so the defaults keep notes
≤ 160 ms with gaps (64 % duty cycle), clamp intensity to 1.6, and refuse any alert over 800 ms instead of truncating
it. Apple publishes no duty-cycle or MTBF figure for the actuator; these are conservative derivations, not an official
rating. See [ARCHITECTURE.md](ARCHITECTURE.md) for the ABI and the reasoning.
