# herdr-haptic-notify

[![ci](https://github.com/sharkAndshark/herdr-haptic-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/sharkAndshark/herdr-haptic-notify/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey)

Trackpad **haptic** notifications for [herdr](https://herdr.dev) agents — for people who keep their Mac muted.

When an agent in any pane finishes, or stops to ask you something, the Force Touch trackpad taps out a short,
tuneful pattern you feel instead of hear.

```
     agent finishes / asks                herdr                      plugin                  trackpad
   ───────────────────────►  pane.agent_status_changed  ──►  dedupe → cooldown →  ──►  Taptic Engine
            done | blocked                                    re-check → budget         (~420 ms pattern)
```

## Feel it in 30 seconds

```sh
herdr plugin install sharkAndshark/herdr-haptic-notify
herdr plugin action invoke test-done --plugin lucas.haptic-notify
```

That is the whole onboarding: install, then feel the pattern. From then on it is silent and hands-off — every pane's
completion buzzes the trackpad, no window, no daemon, no notification tray.

## What using it actually feels like

| moment | what you experience |
|---|---|
| an agent you are **not** looking at finishes | one short "叮-咚-叮~" on the trackpad (`done`) |
| an agent in the pane **you are looking at** finishes | the same buzz (`idle` — same event, seen) |
| an agent stops to ask for approval | the same buzz (`blocked`) |
| you are typing, the pattern fires | it still fires — no finger needs to be on the trackpad |
| three agents finish at once | at most one buzz per pane per 15 s, one every 2 s globally |
| you close herdr | nothing runs; no daemon, no launch agent |

Nothing appears on screen. If you want a visible log of decisions:

```sh
herdr plugin action invoke tail-log --plugin lucas.haptic-notify
```

## Tuning (no JSON editing required to start)

Three built-in actions:

```sh
herdr plugin action invoke open-lab      --plugin lucas.haptic-notify   # audition + compare patterns in a browser
herdr plugin action invoke print-config  --plugin lucas.haptic-notify   # effective config + where it lives
herdr plugin action invoke doctor        --plugin lucas.haptic-notify   # diagnose "why nothing vibrates"
herdr plugin action invoke test-done     --plugin lucas.haptic-notify   # feel the current pattern
```

The lab (local, `127.0.0.1` only) plays any preset on click, draws each pattern's timeline with duty cycle / peak
intensity / a "softness" score, sorts by gentleness, and lets you tweak notes and save them. Copy the `sequence` string
into the config — no reload needed, the next event uses it.

### Common tweaks

| goal | change in `~/.config/herdr/plugins/config/lucas.haptic-notify/config.json` |
|---|---|
| quieter / gentler | lower `intensity` (e.g. `1.35` → `0.9`) and/or use waveform `1` or `3` |
| more presence | raise `intensity` toward `1.6` and lengthen the last note (`130` → `180`) |
| shorter, less chatty | drop the middle note, or delete `"idle"` from `statuses` so only unseen panes buzz |
| only background panes | `"onlyBackgroundPanes": true` |
| pause everything | `"enabled": false` |
| longer patterns | raise `safety.maxTotalMs` deliberately — see [Hardware safety](#hardware-safety) |

A **sequence** is `onMs,offMs[,waveform,intensity,frequency]` per note, notes separated by `;`.
`on` is continuous tapping (~21 ms per actuation), `off` is silence.
Default (`m1`): `70,70,3,1.3,0.34; 70,80,3,1.3,0.5; 130,0,3,1.35,0.66` — a rising three-note chime, 420 ms total.

| field | range | meaning |
|---|---|---|
| `waveform` | 1 back · 2 click · 3 weak buzz · 4 light tap · 5 medium tap · 6 strong tap · 15/16 low thud | firmware preset; anything else is rejected |
| `intensity` | 0–2 | amplitude multiplier; `1.0` ≈ firmware "Medium" |
| `frequency` | 0–2 | tone shift, **not** pitch; clarity peaks at `0.4`, duller toward `2.0` |

## Requirements

| need | why | cost |
|---|---|---|
| macOS + Force Touch trackpad | the Taptic Engine is the output device | hardware (Magic Trackpad 2 also works) |
| herdr ≥ 0.9.0 | plugin event hooks | you already have it |
| **Node ≥ 18** | runs the hook; **zero npm dependencies** | herdr's own sample plugins assume Node too |
| Xcode Command Line Tools | only to compile the helper from source | **optional** — a checksummed prebuilt binary is downloaded instead |

No daemon, no `sudo`, no Accessibility/Input-Monitoring prompt, no network access at runtime.

## Install options

**Through herdr** (normal path):

```sh
herdr plugin install sharkAndshark/herdr-haptic-notify     # --ref <tag> to pin, --yes for scripts
```

herdr clones the repo, shows a trust preview of every command it will run, then runs the `[[build]]` step.

**From a clone** (development):

```sh
git clone git@github.com:sharkAndshark/herdr-haptic-notify.git
cd herdr-haptic-notify
sh install.sh        # build/fetch bin/taptic, link into herdr, seed config
```

Both ways end with the same config at `~/.config/herdr/plugins/config/lucas.haptic-notify/config.json`
(`herdr plugin config-dir lucas.haptic-notify` prints the path).

## How the decision is made

The hook runs once per `pane.agent_status_changed` event and applies, in order:

1. **is the status configured?** — `done`, `blocked`, `idle` by default (anything else is only logged)
2. **dedupe** — same pane + same status already fired
3. **per-pane suppression** — one buzz per pane per 15 s, any status
4. **global rate limit** — 2 s cooldown, 12 alerts/minute
5. **debounce (400 ms)** then **live re-check** via `herdr agent get` — herdr's detection is heuristic; a status that
   changed again is dropped, and `done`/`idle` are treated as the same "complete" class so the two cannot race
6. **safety budget** — intensity clamped, over-long sequences refused
7. **fire** `taptic --sequence …` and wait for it (herdr requires plugins to stop child processes before exiting)

Why the private `MultitouchSupport` actuator instead of `NSHapticFeedbackManager`, and what that ABI costs:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Hardware safety

The Taptic Engine is an LRA: sustained loud drive is what wears it. Apple's own usage is short discrete taps, so this
plugin clamps intensity to **1.6** (firmware max is 2.0), refuses any alert longer than **800 ms** instead of truncating
it, and enforces the cooldowns above. Its default pattern keeps notes ≤ 160 ms with gaps (64 % duty cycle).

Apple publishes no duty-cycle or MTBF figure for the actuator, so these are conservative derivations rather than an
official rating. `docs/ARCHITECTURE.md` explains the reasoning.

## Troubleshooting

Start with the doctor — it checks host, haptics settings, helper binary, config, and the last decisions:

```sh
herdr plugin action invoke doctor --plugin lucas.haptic-notify
```

| symptom | likely cause |
|---|---|
| doctor says `missing helper` | build step failed → `herdr plugin update lucas.haptic-notify`, or from a clone `sh scripts/build-taptic.sh` |
| doctor says haptics disabled | System Settings → Trackpad → enable "Force Click and haptic feedback" |
| log shows `fired` but nothing is felt | pattern too gentle for your perception → try `test-done`, then raise `intensity` |
| log shows `skip … status moved on` | the agent changed state within `debounceMs` — expected |
| log shows `skip … rate limited` / `pane buzzed …` | cooldowns doing their job |
| log shows `skip … exceeds budget` | sequence longer than `maxTotalMs` |
| no log lines at all | plugin not installed (`herdr plugin list`), or no agent status change yet |
| `herdr plugin update` fails with `git … Empty reply from server` | private-repo HTTPS auth hiccup. Point just this repo at SSH: `git config --global url."git@github.com:sharkAndshark/herdr-haptic-notify.git".insteadOf "https://github.com/sharkAndshark/herdr-haptic-notify.git"` (irrelevant once the repo is public) |

## Update, disable, uninstall

```sh
herdr plugin update lucas.haptic-notify --yes     # pick up a new release
herdr plugin disable lucas.haptic-notify          # keep it installed, stop the buzz
herdr plugin uninstall lucas.haptic-notify        # remove the plugin
rm -rf ~/.config/herdr/plugins/config/lucas.haptic-notify   # optional: drop the config too
```

## Development

```sh
make test     # 21 tests — pure logic + hook integration with fake herdr/taptic
make lint     # node --check, JSON validity, shellcheck when installed
make hooks    # pre-commit: lint + fast tests
make ci       # lint + test + build
make lab      # audition UI from the working tree
make release-assets   # dist/taptic-macos-{arm64,x86_64} + .sha256
```

```
herdr-plugin.toml            herdr manifest (build step, event hook, 6 actions)
hook.js                      event → decisions → fire
lib/sequence.js              pure: parse/serialise sequences, safety budget, rate limits
tools/taptic/taptic.swift    the actuator driver (built into bin/taptic)
lab/                         local audition UI (server.mjs + ui.html + presets.json)
scripts/                     build-taptic.sh, doctor.sh, print-config.sh, tail-log.sh
test/                        node:test suites
docs/ARCHITECTURE.md         ABI research, herdr status semantics, safety rationale
docs/PUBLISHING.md           marketplace listing, releases, history hygiene
```

## License

MIT — see [LICENSE](LICENSE).
