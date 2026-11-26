# herdr-haptic-notify

[![ci](https://github.com/sharkAndshark/herdr-haptic-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/sharkAndshark/herdr-haptic-notify/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey)

Trackpad **haptic** notifications for [herdr](https://herdr.dev) agents — for people who keep their Mac muted.

When an agent finishes, or stops to ask you something, the Force Touch trackpad taps a short chime you feel instead of
hear. No window, no sound, no daemon.

```sh
herdr plugin install sharkAndshark/herdr-haptic-notify
herdr plugin action invoke test-done --plugin lucas.haptic-notify
```

That is the whole onboarding. **Nothing to configure** — the default `m1` chime and the safety limits are built in.

## What it feels like

| moment | what happens |
|---|---|
| an agent finishes (`done`, or `idle` for the pane you are looking at) | one ~420 ms three-note chime |
| an agent stops for approval (`blocked`) | the same chime |
| you are typing | it still fires — no finger needs to be on the trackpad |
| several agents finish at once | at most one buzz per pane per 15 s, one every 2 s globally |
| herdr is closed | nothing runs |

## Actions

```sh
herdr plugin action invoke test-done     --plugin lucas.haptic-notify   # feel the current pattern
herdr plugin action invoke open-lab      --plugin lucas.haptic-notify   # audition/compare patterns in a browser
herdr plugin action invoke doctor        --plugin lucas.haptic-notify   # diagnose "why nothing vibrates"
herdr plugin action invoke print-config  --plugin lucas.haptic-notify   # effective config + path
herdr plugin action invoke tail-log      --plugin lucas.haptic-notify   # decisions, with the reason for each skip
```

## Requirements

| need | why |
|---|---|
| macOS + Force Touch trackpad | the Taptic Engine is the output device (Magic Trackpad 2 also works) |
| herdr ≥ 0.9.0 | plugin event hooks |
| Node ≥ 18 | runs the hook; **zero npm dependencies** |
| Xcode Command Line Tools | *optional* — only to compile the helper; a checksummed prebuilt binary is downloaded instead |

No `sudo`, no Accessibility/Input-Monitoring prompt, no network access at runtime.

## Tuning

The config file is optional and only exists once you change something:

- `open-lab` → browser page that plays presets, draws each pattern's timeline, sorts by gentleness, lets you edit notes
- [docs/CONFIG.md](docs/CONFIG.md) → full config reference, sequence grammar, common tweaks, safety numbers
- `"statuses": {}` mutes everything while keeping the plugin installed; `"enabled": false` disables it entirely

Default pattern (`m1`): `70,70,3,1.3,0.34; 70,80,3,1.3,0.5; 130,0,3,1.35,0.66` — rising three notes, waveform 3,
intensity 1.35. Notes are ≤ 160 ms with gaps (64 % duty cycle); intensity is clamped to 1.6 and any alert over 800 ms
is refused, because a Taptic Engine dislikes sustained drive. Reasoning: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Troubleshooting

```sh
herdr plugin action invoke doctor --plugin lucas.haptic-notify
```

It checks macOS, haptics settings, the helper binary, the config, and the last decisions. Common causes: haptics
disabled in System Settings → Trackpad, a missing helper (rerun `herdr plugin update`), or a cooldown/pane-suppression
skip that is working as intended. More in [docs/CONFIG.md](docs/CONFIG.md).

## Update / disable / uninstall

```sh
herdr plugin update    lucas.haptic-notify --yes
herdr plugin disable   lucas.haptic-notify
herdr plugin uninstall lucas.haptic-notify
```

## Development

```sh
make test    # 23 tests: pure logic + hook integration with a fake herdr/taptic
make lint    # node --check, JSON validity, shellcheck when installed
make hooks   # pre-commit: lint + fast tests
make ci      # lint + test + build
```

```
herdr-plugin.toml            manifest: build step, event hook, 6 actions
hook.js                      event → decisions → fire
lib/sequence.js              pure: parse/serialise sequences, safety budget, rate limits
tools/taptic/taptic.swift    the actuator driver (built into bin/taptic)
lab/                         local audition UI
scripts/                     build-taptic.sh, doctor.sh, print-config.sh, tail-log.sh
docs/                        ARCHITECTURE.md (ABI research), CONFIG.md, PUBLISHING.md
```

## License

MIT — see [LICENSE](LICENSE).
