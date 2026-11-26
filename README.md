# herdr-haptic-notify

Trackpad **haptic** notifications for [herdr](https://herdr.dev) agents — for people who keep their Mac muted.

When an agent in any pane finishes, or stops to ask you something, the Force Touch trackpad taps out a short pattern you can feel instead of hear.

```
agent working ──► done / blocked ──► herdr plugin event ──► haptic-notify hook
                                                                  │
                                                     rate limits + safety budget
                                                                  ▼
                                                  taptic --sequence 70,70,3,1.3,0.34;…
                                                                  ▼
                                                    MultitouchSupport MTActuator
```

## Why it exists

macOS exposes exactly one public haptic API, `NSHapticFeedbackManager`, and it is useless for notifications:

* it is a **silent no-op for background/accessory processes** — reused by [WhichSpace](https://github.com/gechr/WhichSpace), which had to bypass it for the same reason;
* it needs **a finger resting on the trackpad** to fire at all.

Both make it unusable as an alert. This plugin drives the same private `MultitouchSupport.framework` actuator that [HapticKey](https://github.com/niw/HapticKey), [WhichSpace](https://github.com/gechr/WhichSpace), [MTMR](https://github.com/Toxblh/MTMR) and [mac-taptic-midi](https://github.com/Tsifrokayf/mac-taptic-midi) use, which works while you are typing and never steals focus.

Background on the ABI, the waveforms and the safety numbers: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Requirements

| Need | Why | Painless? |
|---|---|---|
| macOS + Force Touch trackpad | the Taptic Engine is the output device | hardware requirement — nothing to install |
| herdr ≥ 0.9.0 | plugin event hooks (`pane.agent_status_changed`) | you already have it |
| **Node ≥ 18** | runs `hook.js` and the optional lab UI | no `npm install`, **zero npm dependencies** — the hook uses only Node built-ins. herdr's own sample plugins (Heeler, etc.) already assume Node |
| Xcode Command Line Tools | only to compile `bin/taptic` from Swift source | **optional**: the build step downloads the prebuilt release asset first (via `gh` for this private repo, `curl`/`GITHUB_TOKEN` otherwise). Without either, everything still loads, you just get no vibration |

Nothing else. No daemon, no launch agent, no accessibility/Input-Monitoring permission (the private actuator path does not need TCC), no network access.

## Install

From a local checkout (recommended while the repo is private):

```sh
git clone git@github.com:sharkAndshark/herdr-haptic-notify.git
cd herdr-haptic-notify
sh install.sh          # fetch/build bin/taptic, link into herdr, seed config
```

`sh install.sh` needs neither Xcode nor `npm`: it downloads the prebuilt helper from
the [latest release](https://github.com/sharkAndshark/herdr-haptic-notify/releases)
(`gh release download` when the repo is private, plain `curl` otherwise) and only falls
back to `swiftc` when no asset matches your architecture.

Or, straight through herdr (needs git credentials for a private repo):

```sh
herdr plugin install sharkAndshark/herdr-haptic-notify
```

Then feel it:

```sh
herdr plugin action invoke test-done --plugin haptic-notify
```

## Marketplace / letting other people install it

herdr discovery is the [marketplace](https://herdr.dev/plugins/) — an **automatic index of public GitHub repositories**
tagged with the topic `herdr-plugin` whose default branch contains at least one `herdr-plugin.toml` with parseable
metadata (`id`, `name`, `version`, `platforms`, `min_herdr_version`). The index refreshes every ~30 minutes; nothing is
reviewed, so a listing is not an endorsement.

This repository is currently **private**, so:

| | works today | notes |
|---|---|---|
| `herdr plugin install sharkAndshark/herdr-haptic-notify` by someone else | ✗ | needs write/read access to a private repo |
| marketplace listing at herdr.dev/plugins | ✗ | index only covers public repositories |
| clone + `sh install.sh` by someone with access | ✓ | |

To publish it, three things:

1. make the repository public (`gh repo edit --visibility public --accept-visibility-change-consequences`);
2. add the topic: `gh repo edit --add-topic herdr-plugin`;
3. keep `herdr-plugin.toml` at the repo root with `min_herdr_version` and top-level `platforms` (both already set).

Then `herdr plugin install sharkAndshark/herdr-haptic-notify` works for everyone (herdr clones, shows a trust preview,
and runs our `[[build]]` step), and the repo shows up on herdr.dev/plugins within half an hour.

Before going public, consider: the build step downloads a prebuilt binary from this repo's releases — publishing a
`taptic-macos-<arch>.sha256` alongside it and verifying the checksum in `scripts/build-taptic.sh` would let reviewers
check what they run (they can always fall back to compiling the Swift source instead).

## Configure

`~/.config/herdr/plugins/config/haptic-notify/config.json` (seeded from [`config.example.json`](config.example.json)):

```jsonc
{
  "enabled": true,
  "taptic": "",                 // empty → <plugin>/bin/taptic, then `taptic` on PATH
  "debounceMs": 400,            // ignore flapping: re-check the status after this delay
  "statuses": {
    // herdr emits `done` for a completion you have not looked at and `idle`
    // once the pane is in view. Subscribe to both to buzz in every case.
    "done":    { "label": "m1", "sequence": "70,70,3,1.3,0.34;70,80,3,1.3,0.5;130,0,3,1.35,0.66", "suppressAfterMs": 15000 },
    "blocked": { "label": "m1", "sequence": "70,70,3,1.3,0.34;70,80,3,1.3,0.5;130,0,3,1.35,0.66", "suppressAfterMs": 15000 },
    "idle":    { "label": "m1", "sequence": "70,70,3,1.3,0.34;70,80,3,1.3,0.5;130,0,3,1.35,0.66", "suppressAfterMs": 15000 }
  },
  "onlyBackgroundPanes": false, // true → skip the pane you are looking at
  "safety": {
    "enabled": true,
    "maxTotalMs": 800,          // refuse any single alert longer than this
    "maxIntensity": 1.6,        // clamp amplitude (0–2 scale, 2 = firmware max)
    "minGapMs": 2000,           // global cooldown between alerts
    "maxAlertsPerMinute": 12,
    "paneSuppressMs": 15000     // one buzz per pane per 15s, any status
  },
  "log": true
}
```

A **sequence** is `onMs,offMs[,waveform,intensity,frequency]` per note, notes separated by `;`.
`on` is continuous tapping (~21 ms per actuation), `off` is silence.

| field | range | meaning |
|---|---|---|
| `waveform` | 1 back · 2 click · 3 weak buzz · 4 light tap · 5 medium tap · 6 strong tap · 15/16 low thud | firmware preset; anything else is rejected |
| `intensity` | 0–2 | amplitude multiplier; `1.0` ≈ firmware "Medium" |
| `frequency` | 0–2 | tone shift, **not** pitch; perceived peak clarity at `0.4`, duller toward `2.0` |

### Audition patterns

```sh
make lab      # or: node lab/server.mjs --open  →  http://127.0.0.1:8765
```

A local (127.0.0.1 only) page that plays any preset on click, shows each pattern's
timeline/duty cycle/softness score, sorts by gentleness, and lets you tweak notes and
save them back to `lab/presets.json`. Copy the `sequence` string from there into
`config.json`.

## Hardware safety

The Taptic Engine is an LRA: long, loud, continuous drive is what wears it. Apple's own
usage is short discrete taps. This plugin therefore:

* clamps intensity to `maxIntensity` (default **1.6**, not 2.0);
* refuses any alert longer than `maxTotalMs` (**800 ms**) instead of truncating it;
* enforces a **2 s** global cooldown, **12 alerts/minute**, and **one buzz per pane per 15 s**;
* is designed around patterns with ≤ 160 ms notes and gaps between them.

Apple publishes no duty-cycle/MTBF spec for the actuator, so these are conservative
values derived from Apple's own behaviour, not an official rating. If you build your own
patterns, keep notes short, keep gaps, and stay below intensity 2.0 — see
`docs/ARCHITECTURE.md` for the reasoning.

## Troubleshooting

```sh
sh scripts/tail-log.sh                                   # what the hook decided and why
herdr plugin action invoke test-done --plugin haptic-notify
./bin/taptic -w 6 -I 1.5 -c 3                             # raw, bypassing herdr
```

| Symptom | Likely cause |
|---|---|
| nothing happens, log has `fired` | `bin/taptic` missing/broken → `make build`; check System Settings → Trackpad → "Force Click and haptic feedback" |
| log has `skip … status moved on` | the agent changed state again within `debounceMs` — expected, not a bug |
| log has `skip … rate limited` | cooldown/suppression doing its job |
| log has `skip … exceeds budget` | your sequence is longer than `maxTotalMs` |
| no log lines at all | plugin not linked (`herdr plugin list`), or no agent status change yet |
| wants buzz while watching the pane | subscribe `idle` as well as `done` (default config does) |

## Uninstall

```sh
herdr plugin unlink haptic-notify
rm -rf ~/.config/herdr/plugins/config/haptic-notify
```

## Development

```sh
make test     # 21 tests: pure logic + hook integration with fake herdr/taptic
make lint     # node --check, JSON validity, shellcheck if installed
make hooks    # pre-commit: lint + fast tests
make ci       # lint + test + build
```

```
herdr-plugin.toml       herdr manifest (event hook, actions, build step)
hook.js                 event → decisions → fire
lib/sequence.js         pure: parse/serialise sequences, safety budget, rate limits
tools/taptic/taptic.swift   the actuator driver (compiled to bin/taptic)
lab/                    local audition UI (server.mjs + ui.html + presets.json)
scripts/                build-taptic.sh, tail-log.sh, haptic-lab.sh
test/                   node:test suites
docs/ARCHITECTURE.md    ABI research, event statuses, safety rationale
```

## License

MIT — see [`LICENSE`](LICENSE).
