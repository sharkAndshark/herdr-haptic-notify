# Architecture & research notes

Everything here was verified on this machine — Apple Silicon MacBook Pro, macOS 26 —
by calling the private framework directly and reading the event log back.

## Why not `NSHapticFeedbackManager`

Apple's only public haptic API has two disqualifying properties for notifications:

1. **Silent no-op for non-active processes.** [WhichSpace](https://github.com/gechr/WhichSpace)
   documents this in a comment and drives the actuator directly instead:
   *"`NSHapticFeedbackManager` is a silent no-op for menu bar accessory apps (the system
   only honors it for the active app)."* Making the process active means stealing focus
   from whatever you are typing into.
2. **Requires a finger on the trackpad.** [mac-taptic-midi](https://github.com/Tsifrokayf/mac-taptic-midi)
   puts it plainly: the public API *"only knows 3 boring patterns and needs a finger on
   the trackpad"* — which is why it also goes the private route.

The private actuator path needs neither: it fires while your hands are on the keyboard and
never touches window focus.

## The private ABI

`MultitouchSupport.framework` ships only inside the dyld shared cache on modern macOS
(no file on disk), so the driver must use `dlopen` + `dlsym`:

```c
dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
```

Relevant symbols (all present on macOS 26.6.2):

```
MTDeviceCreateList                 MTDeviceGetDeviceID        MTDeviceIsBuiltIn
MTDeviceSupportsActuation          MTActuatorCreateFromDeviceID
MTActuatorOpen                     MTActuatorClose            MTActuatorActuate
```

```c
// as used by niw/HapticKey and gegr/WhichSpace
IOReturn MTActuatorActuate(CFTypeRef actuator,
                           SInt32   waveform,      // 1..6, 15, 16 only
                           UInt32   flags,         // bitfield, 0 = use the floats below
                           Float32  intensity,     // 0..2
                           Float32  frequency);    // 0..2, timbre not pitch
```

### Two traps that cost hours

1. **Argument classes, not names.** Write-ups name the 5 arguments differently
   (`type,intensity,frequency,flags` vs `actuationID,unknown1,unknown2,unknown3`), but on
   arm64 the *register class* decides everything: `x1/x2` carry the integers, `s0/s1` carry
   the floats. Passing four integers compiles fine and then fails at runtime with
   `0xE00002F0` (`kIOReturnNotFound`). Verified working order:
   `(actuator, int32, uint32, float, float)`.
2. **The actuator handle is single-use.** `MTActuatorCreateFromDeviceID` must be followed by
   `open → actuate → close` *per tap*; reusing an opened handle returns
   `0xE00002BC` (`kIOReturnError`). Each tap costs ~**21 ms** of driver round-trip, which
   caps the achievable "buzz" rate around 47 Hz — that is why a continuous-feeling
   vibration is built from repeated taps rather than one long call.

Also: only waveform ids **1–6, 15, 16** are valid (0, 7–14, 17+ return errors). The
`__tpad_act_plist` section of the framework holds the firmware presets.

### Parameter map

| field | range | behaviour |
|---|---|---|
| waveform | 1 back · 2 click · 3 weak buzz · 4 light tap · 5 medium tap · 6 strong tap · 15/16 low thud | selects the firmware waveform; 15/16 are low-frequency rumbles with no sharp pulse |
| intensity | 0.0–2.0 linear | amplitude multiplier; 1.0 ≈ firmware "Medium" (Light ≈ 0.8×, Firm ≈ 1.2×) |
| frequency | 0.0–2.0 non-linear | shifts drive signal toward/away from the LRA resonance (~150–200 Hz). Peak perceived strength/clarity ≈ **0.4**, progressively duller above 0.6 |
| flags | bitfield | bit 0/1/2 select stored intensity presets (Light/Firm), bit 3 negates the waveform lookup; with `flags = 0` the passed floats are used |

Source: [`BluestoneInc/MTActuatorActuate-parameters-report`](https://github.com/BluestoneInc/MTActuatorActuate-parameters-report),
cross-checked against HapticKey's comments ("Give 0 or 0.0 for these arguments should be okay").

## What herdr actually emits

Measured from a day of real events (`pane.agent_status_changed`) with this plugin's log:

| status | count | meaning |
|---|---|---|
| `working` | 18 | agent is running |
| `idle` | 13 | finished, and the pane is **in view** (completion already "seen") |
| `done` | 7 | finished, pane **not** in view — this is the badge you see in the sidebar |
| `blocked` | – | herdr recognised an approval/question prompt |

So `done` and `idle` are the *same* completion seen through the "have you looked at it"
flag. Subscribing only to `done` means no buzz when you are staring at the pane; the plugin
therefore treats `done`/`idle` as one class (`statusClass()`), which also prevents the two
racing between the event and the debounced re-check.

Event shape (lenient parsing — only `pane_id` and `agent_status` are required):

```json
{"event":"pane_agent_status_changed",
 "data":{"type":"pane_agent_status_changed","pane_id":"w1:p1",
         "workspace_id":"w1","agent":"pi","agent_status":"done"}}
```

Hooks are one short-lived process per event, with `HERDR_PLUGIN_EVENT_JSON`,
`HERDR_PLUGIN_ROOT`, `HERDR_PLUGIN_CONFIG_DIR`, `HERDR_PLUGIN_STATE_DIR`,
`HERDR_BIN_PATH` in the environment.

## Safety budget

The trackpad is a linear resonant actuator, not a speaker. The two stressors are coil heat
(a function of sustained drive) and mechanical excursion (thud waveforms move further).

Chosen limits and why:

| limit | value | rationale |
|---|---|---|
| intensity cap | 1.6 (2.0 is firmware max) | halves coil current versus max while staying clearly perceptible |
| per-alert budget | 800 ms total, notes ≤ 160 ms | Apple's own usage is discrete tens-of-ms taps |
| duty cycle | ≤ ~60 % with gaps 60–110 ms | lets the coil cool and the mass recentre |
| waveform | prefer 3/4, avoid 15/16 for alerts | low-thud waveforms have the largest excursion |
| cooldown | 2 s global, 12/min, 15 s per pane | stops bursts of agents from turning into a continuous drive |

Apple publishes no MTBF or duty-cycle spec for the actuator — these are conservative
derivations from Apple's own behaviour. Continuous musical drive (as in `mac-taptic-midi`)
is deliberately out of scope here.
