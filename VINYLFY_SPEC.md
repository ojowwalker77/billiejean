# Vinylfy — macOS Vinyl Effect Audio Processor

## Overview

A macOS Swift app that intercepts system audio output (Apple Music, Spotify, browsers, etc.) via Core Audio Process Taps (macOS 14.2+), applies real-time vinyl record DSP effects, and plays the processed audio through the speakers.

**No virtual audio drivers, no Audio MIDI Setup, no sudo, no kernel extensions.** Everything is done programmatically through public Core Audio APIs.

---

## Architecture

```
[Any audio source] ──→ [Core Audio Tap (global)] ──→ [Private Aggregate Device] ──→ [IOProc callback]
                                                                                           │
                                                                                           ▼
                                                                              ┌──────────────────────┐
                                                                              │   Vinyl DSP Pipeline  │
                                                                              │                      │
                                                                              │  Float32 PCM buffers  │
                                                                              │  Sample rate: 48kHz   │
                                                                              │  Channels: stereo     │
                                                                              │                      │
                                                                              │  1. RIAA EQ curve     │
                                                                              │  2. Warmth/saturation │
                                                                              │  3. Wow & flutter     │
                                                                              │  4. Surface noise     │
                                                                              │  5. Crackle & pops    │
                                                                              │  6. Stereo reduction  │
                                                                              │  7. Dry/wet mix       │
                                                                              └──────────┬───────────┘
                                                                                         │
                                                                                         ▼
                                                                              [Default output device]
                                                                              (your speakers/headphones)
```

---

## Core Audio Tap Layer (SystemAudioTap)

Use **MacParakeet's `SystemAudioTap.swift`** as the foundation. It's production-quality, handles lifecycle, output device changes, and delivers `AVAudioPCMBuffer` to a callback.

### What it does:

1. **Creates a `CATapDescription`** — `stereoGlobalTapButExcludeProcesses: []` captures all system audio
2. **Calls `AudioHardwareCreateProcessTap`** — gets an `AudioObjectID` for the tap
3. **Reads the tap format** — reads `kAudioTapPropertyFormat` to get `AudioStreamBasicDescription`
4. **Creates a private aggregate device** — wraps the tap and real output device; `kAudioAggregateDeviceIsPrivateKey: true` keeps it invisible
5. **Installs `AudioDeviceCreateIOProcIDWithBlock`** — receives raw float PCM buffers in real-time
6. **Delivers `AVAudioPCMBuffer`** to a `@Sendable` handler callback
7. **Watchdog** — logs if no buffers arrive within 2s (permission issue detection)
8. **Cleanup** — destroys tap, aggregate device, IOProc on stop/deinit

### Key constraints:
- `muteBehavior = .unmuted` — audio passes through normally AND your tap gets a copy
- **Bypass `AVAudioEngine`** — it cannot be pointed at an arbitrary HAL device; use `AudioDeviceCreateIOProcIDWithBlock` directly
- **Output device changes** — register listener on `kAudioHardwarePropertyDefaultOutputDevice` to recreate the aggregate

### Required files from MacParakeet:
- `SystemAudioTap.swift` — main class
- `MeetingAudioError.swift` — error types (adapt to your project naming)
- `AudioObjectID+Extensions.swift` — helpers for reading device UID, tap format, system output device

---

## Vinyl DSP Pipeline

All DSP runs in the IOProc callback (real-time thread). **No allocations, no locks, no ObjC messaging, no Swift retain/release.**

### 1. RIAA Equalization Curve

Inverse-RIAA boosts highs like vinyl cutting. Apply as a fixed-pole filter:
- Shelf filter: ~75µs (2122 Hz) transition
- Roll off lows below ~50 Hz (rumble filter)
- Roll off highs above ~16 kHz

Implementation: biquad IIR cascade via `vDSP_deq22` (Accelerate framework).

**References:** ToneArm (Python), Vintage (PlugData), vinylfy (Python)

### 2. Warmth / Saturation (Harmonic Distortion)

Soft-clipping waveshaping to simulate analog tube/transistor warmth:
- Apply a tanh or polynomial waveshaper
- Parameter: Drive (0.0–1.0)
- Can be applied per-channel

**References:** viator-rust (C++ JUCE), vinylfy

### 3. Wow & Flutter

Slow pitch modulation (0.5–4 Hz = wow, 5–10 Hz = flutter):
- Variable delay line with LFO-driven read pointer
- LFO waveform: sine or triangle
- Parameters: Rate (Hz), Depth (percentage)
- Depth of 0.1–0.5% for subtle, up to 2% for extreme warped effect

**References:** corrupter (C), Vintage, DAW LP, Lowfi Dojo

### 4. Surface Noise (Hiss)

Filtered white noise as analog noise floor:
- Generate white noise via `rand`/`drand48` seeded PRNG
- Shape with an EQ shelf (emphasize highs, cut lows)
- Parameters: Level (0.0–1.0)

**References:** viator-rust, ToneArm, vinylfy

### 5. Crackle & Pops

Synthesized transient noise:
- Based on Andy Farnell's "Designing Sound" fire crackling model
- Poisson-distributed impulse train with filtered decay
- Parameters: Rate (crackles/second), Intensity (0.0–1.0)

**References:** viator-rust (best open-source implementation), ToneArm (physical model approach)

### 6. Stereo Reduction

Reduce stereo width to simulate vinyl's limited channel separation:
- Mid/Side decode → reduce Side gain → Mid/Side encode
- Parameter: Width (0.0 = mono, 1.0 = original)

**References:** SignalKit (StereoWidener), vinylfy

### 7. Dry/Wet Mix

Mix original signal with processed signal:
- Parameter: Mix (0.0 = dry, 1.0 = full wet)

---

## File Structure

```
Vinylfy/
├── Package.swift                     # Swift Package Manager (or Xcode project)
├── Sources/
│   ├── VinylfyApp/
│   │   ├── VinylfyApp.swift          # @main SwiftUI app entry
│   │   └── ContentView.swift         # UI: controls, toggle, sliders
│   ├── AudioCapture/
│   │   ├── SystemAudioTap.swift      # Core Audio tap (from MacParakeet)
│   │   ├── AudioError.swift          # Error types
│   │   ├── AudioObjectID+Read.swift  # Extensions for reading device properties
│   │   └── AudioCaptureManager.swift # High-level start/stop, manages lifecycle
│   ├── DSP/
│   │   ├── VinylProcessor.swift      # Main processor: chains all effects
│   │   ├── BiquadFilter.swift        # IIR biquad (for EQ, RIAA)
│   │   ├── RIAAEQ.swift              # RIAA curve filter
│   │   ├── Saturation.swift          # Waveshaping / soft-clip
│   │   ├── WowFlutter.swift          # LFO-modulated delay line
│   │   ├── NoiseGenerator.swift      # Hiss + crackle/pop synthesis
│   │   ├── StereoWidth.swift         # Mid/Side processor
│   │   └── RingBuffer.swift          # Lock-free SPSC ring buffer
│   └── UI/
│       ├── ControlsView.swift        # Sliders and toggles
│       └── VisualizerView.swift      # Optional waveform display
├── Resources/
│   ├── Info.plist                    # NSAudioCaptureUsageDescription
│   └── Assets.xcassets/
└── README.md
```

---

## Permission (Info.plist)

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>Vinylfy needs to capture system audio to apply vinyl effects in real-time.</string>
```

First launch triggers a one-click system permission dialog. No microphone or screen recording permission needed.

---

## Output Routing

**Option A — IOProc playthrough (simpler):**
- The aggregate device tap with `muteBehavior = .unmuted` allows original audio to pass through normally
- Your IOProc receives a copy; the vinyl-processed audio can be written to a separate output
- This means the user hears the ORIGINAL audio + you can route processed audio elsewhere (headphones, file, AirPlay)

**Option B — Mute + output via IOProc (harder, full control):**
- Use `muteBehavior = .mutedWhenTapped` to stop original audio from reaching speakers
- In the IOProc, write processed audio to `outOutputData` buffer
- This replaces system audio with your vinyl-processed version — user hears only the effected audio
- Requires more careful buffer management and latency handling

**Recommendation:** Start with Option A (unmuted, write processed audio to a separate AudioUnit or file for testing), then graduate to Option B once the DSP is verified.

---

## Real-Time Safety Rules

In the IOProc callback:
- ❌ No `malloc` / `free` / `Array.append` / string formatting
- ❌ No locks (`os_unfair_lock`, `DispatchSemaphore`, `@synchronized`)
- ❌ No ObjC messaging (`objc_msgSend`)
- ❌ No Swift ARC retain/release on hot path (use `final class`, pre-allocated buffers)
- ❌ No file I/O
- ✅ Pre-allocate all buffers at init
- ✅ Use `vDSP_deq22` for biquad filters (SIMD-optimized)
- ✅ Use lock-free ring buffers for cross-thread communication

---

## Dependencies

- **macOS 14.2+** (required for `CATapDescription` / `AudioHardwareCreateProcessTap`)
- **Apple Accelerate framework** (vDSP, included with macOS)
- No third-party dependencies required

---

## Implementation Order

### Phase 1: Capture (get audio into your process)
1. Create Xcode project targeting macOS 14.2+ with SwiftUI
2. Add `NSAudioCaptureUsageDescription` to Info.plist
3. Implement `SystemAudioTap.swift` from MacParakeet
4. Implement missing helpers (`AudioObjectID` extensions for reading device UID, tap format)
5. Verify: dump buffer to WAV file, confirm it captures system audio

### Phase 2: Play through (hear yourself)
1. Add `AudioDeviceCreateIOProcIDWithBlock` for output to real device
2. Test: pass through unmodified audio, verify no crackle/glitches

### Phase 3: DSP (vinyl effects)
1. Implement `BiquadFilter.swift` (biquad cascade)
2. Implement `RIAAEQ.swift`
3. Implement `Saturation.swift` (waveshaper)
4. Implement `WowFlutter.swift` (LFO delay)
5. Implement `NoiseGenerator.swift` (hiss + crackle/pop)
6. Implement `StereoWidth.swift`
7. Chain all in `VinylProcessor.swift`

### Phase 4: UI
1. On/off toggle
2. Sliders for each parameter
3. Preset system (Subtle, Old Radio, Worn Vinyl, Extreme)

### Phase 5: Polish
1. Handle output device changes
2. Preserve settings across launches
3. Menu bar icon with quick controls
4. Accessibility support

---

## Reference Projects (read first)

| Project | What to steal |
|---|---|
| **MacParakeet `SystemAudioTap.swift`** | Core Audio tap lifecycle, aggregate device creation, IOProc setup, watchdog, error handling |
| **thalesbmc Mimir** | Process tap with `mutedWhenTapped`, per-app audio control, output device change handling, gain ramping in IOProc |
| **AudioTee** | Minimal working example of the full tap→aggregate→IOProc flow |
| **AudioCap** | TCC permission probing via SPI (`TCCAccessPreflight`) |
| **viator-rust** | Best open-source vinyl DSP — crackle/pop synthesis from Farnell's fire model, waveshaping saturation |
| **corrupter** (thorinside) | C library with Vinyl Sim algorithm — rumble/hiss/crackle/pops, zero-alloc, real-time safe |
| **SignalKit** (CastorLogic) | Pure Swift real-time DSP patterns — `vDSP_deq22`, pre-allocated buffers, `public final class` for devirtualization |
| **vinylfy** (121gigawatz) | Complete vinyl effect in Python — reference for parameter ranges and algorithm order |

---

## Known Gotchas

- **Aggregate device readiness** — after `AudioHardwareCreateAggregateDevice`, the device may not be ready immediately. Poll or wait before starting IOProc.
- **`isExclusive` flag** — the `init(stereoGlobalTapButExcludeProcesses: [])` sets `isExclusive = true`. Don't flip it manually.
- **`muteBehavior`** — `.unmuted` = passthrough + copy; `.mutedWhenTapped` = only you get the audio
- **Output device changes** — user plugs headphones → aggregate invalidates → must recreate
- **Private aggregate devices** — flagged with `kAudioAggregateDeviceIsPrivateKey: true`, invisible to user, destroyed when your process exits
- **Permission** — only prompts reliably from an app bundle; raw CLI binaries may get silent failure
- **Stereo global tap** — `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` captures ALL processes including the system output; pass your own PID if you want to exclude yourself
