// taptic — Fire Force Touch trackpad haptics (macOS, Apple Silicon + Intel).
//
// Two back ends:
//   1. private MultitouchSupport.framework (default) — what HapticKey, WhichSpace,
//      mactic, mac-taptic-midi, Subsurface use. Works for background/accessory
//      processes and does NOT need a finger resting on the trackpad.
//   2. NSHapticFeedbackManager (--public) — Apple's public API; only honored for
//      the active app and only while a finger touches the trackpad.
//
// ABI notes (verified against niw/HapticKey, gegr/WhichSpace, Tsifrokayf/mac-taptic-midi):
//   MTActuatorActuate(actuator, Int32 waveform, Float intensity, Float frequency, UInt32 flags) -> IOReturn
//   integer args land in x1/x2, float args in s0/s1 — the field names differ between
//   reverse-engineering write-ups but the register layout is identical.
//   The actuator handle from MTActuatorCreateFromDeviceID is single-use:
//   create -> open -> actuate -> close for every single tap.
//
// Build: swiftc -O -o ~/.local/bin/taptic ~/.local/src/taptic/taptic.swift

import AppKit
import CoreFoundation
import Foundation

// MARK: - private MultitouchSupport actuator

private typealias FnCreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias FnGetDeviceID = @convention(c) (AnyObject, UnsafeMutablePointer<UInt64>) -> Int32
private typealias FnIsBuiltIn = @convention(c) (AnyObject) -> Bool
private typealias FnSupportsActuation = @convention(c) (AnyObject) -> Bool
private typealias FnCreateActuator = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
private typealias FnOpen = @convention(c) (CFTypeRef, UInt32) -> Int32
private typealias FnClose = @convention(c) (CFTypeRef) -> Int32
private typealias FnActuate = @convention(c) (CFTypeRef, Int32, Float, Float, UInt32) -> Int32

private struct MultitouchActuator {
    let createList: FnCreateList
    let getDeviceID: FnGetDeviceID
    let isBuiltIn: FnIsBuiltIn?
    let supportsActuation: FnSupportsActuation?
    let createActuator: FnCreateActuator
    let open: FnOpen
    let close: FnClose
    let actuate: FnActuate

    static func load() -> MultitouchActuator? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        ) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let createList = sym("MTDeviceCreateList", FnCreateList.self),
              let getDeviceID = sym("MTDeviceGetDeviceID", FnGetDeviceID.self),
              let createActuator = sym("MTActuatorCreateFromDeviceID", FnCreateActuator.self),
              let open = sym("MTActuatorOpen", FnOpen.self),
              let close = sym("MTActuatorClose", FnClose.self),
              let actuate = sym("MTActuatorActuate", FnActuate.self)
        else { return nil }
        return MultitouchActuator(
            createList: createList,
            getDeviceID: getDeviceID,
            isBuiltIn: sym("MTDeviceIsBuiltIn", FnIsBuiltIn.self),
            supportsActuation: sym("MTDeviceSupportsActuation", FnSupportsActuation.self),
            createActuator: createActuator,
            open: open,
            close: close,
            actuate: actuate
        )
    }

    /// First built-in trackpad whose actuator opens successfully.
    func findDeviceID() -> UInt64? {
        guard let list = createList()?.takeRetainedValue() else { return nil }
        let count = CFArrayGetCount(list)
        guard count > 0 else { return nil }
        var fallback: UInt64?
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
            var deviceID: UInt64 = 0
            guard getDeviceID(device, &deviceID) == 0 else { continue }
            if let isBuiltIn, !isBuiltIn(device) { continue }
            if let supportsActuation, !supportsActuation(device) { continue }
            if fallback == nil { fallback = deviceID }
            if probe(deviceID) { return deviceID }
        }
        return fallback
    }

    private func probe(_ deviceID: UInt64) -> Bool {
        guard let actuator = createActuator(deviceID)?.takeRetainedValue() else { return false }
        let opened = open(actuator, 0)
        _ = close(actuator)
        return opened == 0
    }

    /// One tap. The handle is single-use, so every tap gets a fresh one.
    func tap(deviceID: UInt64, waveform: Int32, intensity: Float, frequency: Float, flags: UInt32) -> Int32 {
        guard let actuator = createActuator(deviceID)?.takeRetainedValue() else { return -1 }
        defer { _ = close(actuator) }
        let opened = open(actuator, 0)
        guard opened == 0 else { return opened }
        return actuate(actuator, waveform, intensity, frequency, flags)
    }
}

// MARK: - arguments

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

// MARK: - note sequences ("ringtone" patterns)

/// One "note": keep tapping for onMs, then stay silent for offMs.
/// A tap costs ~21 ms (driver round-trip), so onMs is quantised to that.
struct Note {
    var waveform: Int32
    var intensity: Float
    var frequency: Float
    var onMs: Int
    var offMs: Int
}

let presets: [String: [Note]] = [
    // rising three-note chime: low -> mid -> high, ends on a held mid
    "chime": [
        Note(waveform: 4, intensity: 2.0, frequency: 0.15, onMs: 80, offMs: 70),
        Note(waveform: 4, intensity: 2.0, frequency: 0.45, onMs: 80, offMs: 70),
        Note(waveform: 4, intensity: 2.0, frequency: 0.80, onMs: 180, offMs: 0),
    ],
    // phone-ring feel: ta-ta-DAA, ta-ta-DAA
    "ring": [
        Note(waveform: 6, intensity: 2.0, frequency: 0.40, onMs: 50, offMs: 60),
        Note(waveform: 6, intensity: 2.0, frequency: 0.40, onMs: 50, offMs: 60),
        Note(waveform: 6, intensity: 2.0, frequency: 0.60, onMs: 150, offMs: 220),
        Note(waveform: 6, intensity: 2.0, frequency: 0.40, onMs: 50, offMs: 60),
        Note(waveform: 6, intensity: 2.0, frequency: 0.40, onMs: 50, offMs: 60),
        Note(waveform: 6, intensity: 2.0, frequency: 0.60, onMs: 150, offMs: 0),
    ],
    // three quick rising blips
    "tri": [
        Note(waveform: 3, intensity: 2.0, frequency: 0.20, onMs: 60, offMs: 60),
        Note(waveform: 3, intensity: 2.0, frequency: 0.45, onMs: 60, offMs: 60),
        Note(waveform: 3, intensity: 2.0, frequency: 0.90, onMs: 120, offMs: 0),
    ],
    // heartbeat: dum-dum ... dum-dum
    "beat": [
        Note(waveform: 15, intensity: 2.0, frequency: 0.30, onMs: 90, offMs: 130),
        Note(waveform: 15, intensity: 2.0, frequency: 0.30, onMs: 140, offMs: 320),
        Note(waveform: 15, intensity: 2.0, frequency: 0.30, onMs: 90, offMs: 130),
        Note(waveform: 15, intensity: 2.0, frequency: 0.30, onMs: 140, offMs: 0),
    ],
    // \(done) pleasing: rising three-step chime, warm timbre, resolved ending
    "done": [
        Note(waveform: 4, intensity: 1.9, frequency: 0.30, onMs: 70, offMs: 60),
        Note(waveform: 4, intensity: 1.9, frequency: 0.50, onMs: 70, offMs: 60),
        Note(waveform: 4, intensity: 1.9, frequency: 0.72, onMs: 190, offMs: 0),
    ],
    // \(blocked) "uh-oh": high blip then a low heavy thud (descending = wrong)
    "blocked": [
        Note(waveform: 6, intensity: 2.0, frequency: 0.80, onMs: 90, offMs: 90),
        Note(waveform: 15, intensity: 2.0, frequency: 0.15, onMs: 170, offMs: 0),
    ],
    // --- tuneful candidates: intensity capped at 1.5, every note <= 160ms ---
    "d1": [   // up-chime: low -> mid -> high, resolved
        Note(waveform: 4, intensity: 1.4, frequency: 0.28, onMs: 60, offMs: 70),
        Note(waveform: 4, intensity: 1.4, frequency: 0.46, onMs: 60, offMs: 70),
        Note(waveform: 4, intensity: 1.5, frequency: 0.70, onMs: 150, offMs: 0),
    ],
    "d2": [   // soft triad: even grains, warm buzz timbre
        Note(waveform: 3, intensity: 1.3, frequency: 0.30, onMs: 55, offMs: 65),
        Note(waveform: 3, intensity: 1.3, frequency: 0.42, onMs: 55, offMs: 65),
        Note(waveform: 3, intensity: 1.4, frequency: 0.58, onMs: 140, offMs: 0),
    ],
    "d3": [   // short lift: two notes only
        Note(waveform: 4, intensity: 1.5, frequency: 0.35, onMs: 70, offMs: 60),
        Note(waveform: 4, intensity: 1.5, frequency: 0.62, onMs: 130, offMs: 0),
    ],
    "b1": [   // question: da-da?-DAA, descending middle keeps it gentle
        Note(waveform: 4, intensity: 1.4, frequency: 0.62, onMs: 70, offMs: 70),
        Note(waveform: 4, intensity: 1.4, frequency: 0.40, onMs: 70, offMs: 90),
        Note(waveform: 4, intensity: 1.45, frequency: 0.62, onMs: 140, offMs: 0),
    ],
    "b2": [   // two-note descent, no harsh thud waveform
        Note(waveform: 4, intensity: 1.35, frequency: 0.58, onMs: 80, offMs: 110),
        Note(waveform: 4, intensity: 1.4, frequency: 0.34, onMs: 150, offMs: 0),
    ],
    "b3": [   // turn: high-low-high, resolves upward but leaves a pregunta
        Note(waveform: 3, intensity: 1.35, frequency: 0.50, onMs: 70, offMs: 70),
        Note(waveform: 3, intensity: 1.35, frequency: 0.34, onMs: 70, offMs: 80),
        Note(waveform: 3, intensity: 1.4, frequency: 0.56, onMs: 130, offMs: 0),
    ],
    // soft single buzz
    "buzz": [
        Note(waveform: 6, intensity: 2.0, frequency: 0.40, onMs: 250, offMs: 0),
    ],
]

func parseSequence(_ raw: String) -> [Note]? {
    var notes: [Note] = []
    for chunk in raw.split(separator: ";") {
        let f = chunk.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count >= 2 else { return nil }
        let onMs = Int(f[0]) ?? 0
        let offMs = Int(f[1]) ?? 0
        guard onMs >= 0, offMs >= 0 else { return nil }
        let waveform = f.count > 2 ? Int32(f[2]) ?? 6 : 6
        let intensity = f.count > 3 ? Float(f[3]) ?? 2.0 : 2.0
        let frequency = f.count > 4 ? Float(f[4]) ?? 0.4 : 0.4
        notes.append(Note(waveform: waveform, intensity: intensity, frequency: frequency, onMs: onMs, offMs: offMs))
    }
    return notes.isEmpty ? nil : notes
}

var playName: String?
var sequence: [Note]?

var waveform: Int32 = 4          // 1 back, 2 click, 3 weak buzz, 4 light tap, 5 medium tap, 6 strong tap, 15/16 low thud
var intensity: Float = 1.0       // 0.0 ... 2.0
var frequency: Float = 0.0       // 0.0 ... 2.0, peak perceived strength near 0.4
var flags: UInt32 = 0
var count = 1
var intervalMs = 120
var burstMs = 0            // > 0 switches to continuous-buzz mode
var burstGapMs = 120
var burstRepeat = 1
var usePublicAPI = false
var doActivate = false
var verbose = false
var listDevices = false

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "-w", "--waveform":
        guard let value = args.first, let parsed = Int32(value) else { fail("--waveform expects an integer", code: 2) }
        args.removeFirst()
        waveform = parsed
    case "-I", "--intensity":
        guard let value = args.first, let parsed = Float(value) else { fail("--intensity expects a number", code: 2) }
        args.removeFirst()
        intensity = parsed
    case "-f", "--frequency":
        guard let value = args.first, let parsed = Float(value) else { fail("--frequency expects a number", code: 2) }
        args.removeFirst()
        frequency = parsed
    case "--flags":
        guard let value = args.first, let parsed = UInt32(value) else { fail("--flags expects an integer", code: 2) }
        args.removeFirst()
        flags = parsed
    case "-c", "--count":
        guard let value = args.first, let parsed = Int(value), parsed > 0, parsed <= 50 else { fail("--count expects 1...50", code: 2) }
        args.removeFirst()
        count = parsed
    case "-i", "--interval-ms":
        guard let value = args.first, let parsed = Int(value), parsed >= 0, parsed <= 10000 else { fail("--interval-ms expects 0...10000", code: 2) }
        args.removeFirst()
        intervalMs = parsed
    case "-b", "--burst":
        guard let value = args.first, let parsed = Int(value), parsed > 0, parsed <= 5000 else { fail("--burst expects 1...5000 ms", code: 2) }
        args.removeFirst()
        burstMs = parsed
    case "-g", "--burst-gap":
        guard let value = args.first, let parsed = Int(value), parsed >= 0, parsed <= 5000 else { fail("--burst-gap expects 0...5000 ms", code: 2) }
        args.removeFirst()
        burstGapMs = parsed
    case "-r", "--repeat":
        guard let value = args.first, let parsed = Int(value), parsed > 0, parsed <= 10 else { fail("--repeat expects 1...10", code: 2) }
        args.removeFirst()
        burstRepeat = parsed
    case "--play", "-P":
        guard let value = args.first else { fail("--play expects a preset name", code: 2) }
        args.removeFirst()
        playName = value
    case "--sequence", "-s":
        guard let value = args.first, let parsed = parseSequence(value) else {
            fail("--sequence expects \"on,off[,waveform,intensity,frequency];...\"", code: 2)
        }
        args.removeFirst()
        sequence = parsed
    case "--public":
        usePublicAPI = true
    case "--activate":
        doActivate = true
    case "--list-devices":
        listDevices = true
    case "-v", "--verbose":
        verbose = true
    case "-h", "--help":
        print("""
        usage: taptic [-w WAVEFORM] [-I INTENSITY] [-f FREQUENCY] [--flags N]
                      [-c COUNT] [-i INTERVAL_MS] [--public] [--activate] [--list-devices] [-v]

          back end
            (default)        private MultitouchSupport MTActuator — works in the
                             background and without a finger on the trackpad
            --public         NSHapticFeedbackManager — needs the app active AND a
                             finger on the trackpad
            --activate       with --public: activate the process first

          waveform  1 back | 2 click | 3 weak buzz | 4 light tap | 5 medium tap
                    | 6 strong tap | 15 low thud | 16 heavy thud        (default 4)
          intensity 0.0 ... 2.0                                        (default 1.0)
          frequency 0.0 ... 2.0, perceived peak near 0.4                (default 0.0)
          count     discrete pulses per run, 1 ... 50                   (default 1)
          interval  ms between discrete pulses                          (default 120)

          --burst MS       continuous-buzz mode: keep tapping for MS ms (a buzz
                           feels far stronger than discrete taps; one tap costs
                           ~21 ms, so MS/21 taps are emitted)
          --burst-gap MS   silence between bursts                       (default 120)
          --repeat N       how many bursts                              (default 1)

          --play NAME      play a preset note sequence:
                           done | blocked | d1 | d2 | d3 | b1 | b2 | b3 | chime | ring | tri | beat | buzz
          --sequence SPEC  custom sequence, e.g. "50,60,6,2.0,0.4;150,0,6,2.0,0.6"
                           fields: onMs,offMs,waveform,intensity,frequency
        """)
        exit(0)
    default:
        fail("unknown argument: \(arg)", code: 2)
    }
}

// MARK: - run

if usePublicAPI {
    let app = NSApplication.shared
    app.setActivationPolicy(doActivate ? .regular : .accessory)
    if doActivate { app.activate(ignoringOtherApps: true) }
    let performer = NSHapticFeedbackManager.defaultPerformer
    for index in 0..<count {
        performer.perform(.alignment, performanceTime: .now)
        if verbose {
            FileHandle.standardError.write("taptic: public pulse \(index + 1)/\(count)\n".data(using: .utf8)!)
        }
        if index < count - 1, intervalMs > 0 { usleep(useconds_t(intervalMs * 1000)) }
    }
    usleep(120_000)
    exit(0)
}

guard let api = MultitouchActuator.load() else {
    fail("taptic: MultitouchSupport.framework unavailable (no Force Touch trackpad?)", code: 3)
}
guard let deviceID = api.findDeviceID() else {
    fail("taptic: no actuation-capable multitouch device found", code: 3)
}
if listDevices || verbose {
    FileHandle.standardError.write("taptic: device 0x\(String(deviceID, radix: 16))\n".data(using: .utf8)!)
}

var lastStatus: Int32 = 0

let notes: [Note]? = {
    if let sequence { return sequence }
    if let playName {
        guard let preset = presets[playName] else {
            fail("taptic: unknown preset '\(playName)' (done, blocked, chime, ring, tri, beat, buzz)", code: 2)
        }
        return preset
    }
    return nil
}()

if let notes {
    for (index, note) in notes.enumerated() {
        let deadline = Date().addingTimeInterval(Double(note.onMs) / 1000.0)
        var taps = 0
        repeat {
            lastStatus = api.tap(
                deviceID: deviceID,
                waveform: note.waveform,
                intensity: note.intensity,
                frequency: note.frequency,
                flags: flags
            )
            taps += 1
        } while lastStatus == 0 && Date() < deadline
        if verbose {
            let line = "taptic: note \(index + 1)/\(notes.count) on=\(note.onMs)ms taps=\(taps) f=\(note.frequency) rc=\(lastStatus)\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        if note.offMs > 0 { usleep(useconds_t(note.offMs * 1000)) }
        if lastStatus != 0 { break }
    }
} else if burstMs > 0 {
    var totalTaps = 0
    for repeatIndex in 0..<burstRepeat {
        let deadline = Date().addingTimeInterval(Double(burstMs) / 1000.0)
        var tapsThisBurst = 0
        repeat {
            lastStatus = api.tap(deviceID: deviceID, waveform: waveform, intensity: intensity, frequency: frequency, flags: flags)
            tapsThisBurst += 1
            totalTaps += 1
        } while lastStatus == 0 && Date() < deadline
        if verbose {
            let line = "taptic: burst \(repeatIndex + 1)/\(burstRepeat) \(burstMs)ms -> \(tapsThisBurst) taps waveform=\(waveform) intensity=\(intensity) rc=\(lastStatus)\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        if repeatIndex < burstRepeat - 1, burstGapMs > 0 {
            usleep(useconds_t(burstGapMs * 1000))
        }
    }
    if verbose {
        FileHandle.standardError.write("taptic: total taps \(totalTaps)\n".data(using: .utf8)!)
    }
} else {
    for index in 0..<count {
        lastStatus = api.tap(deviceID: deviceID, waveform: waveform, intensity: intensity, frequency: frequency, flags: flags)
        if verbose {
            let line = "taptic: tap \(index + 1)/\(count) waveform=\(waveform) intensity=\(intensity) rc=\(lastStatus)\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        if index < count - 1, intervalMs > 0 { usleep(useconds_t(intervalMs * 1000)) }
    }
}
usleep(50_000)
exit(lastStatus == 0 ? 0 : 2)
