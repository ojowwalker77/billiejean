import Foundation
import SwiftUI
import AppKit
import VinylEngine
import DSP
import NowPlaying

/// Owns the single ``HearItEngine`` instance plus the ``NowPlayingService`` and
/// mirrors all live state for the SwiftUI vinyl widget.
///
/// All engine access happens on the main actor: start/stop, parameter writes,
/// and the now-playing snapshot handler hops back to the main actor before it
/// touches any published state.
@available(macOS 14.2, *)
@MainActor
@Observable
final class StudioViewModel {
    /// Shared instance so the AppDelegate can reliably reach the model for
    /// launch bootstrap and terminate cleanup.
    static let shared = StudioViewModel()

    private let engine = HearItEngine(debugLogging: false)
    private let nowPlaying = NowPlayingService(pollInterval: 2.0)

    // MARK: - Transport / engine state

    private(set) var isRunning = false

    /// Bypass state. VINYL (processed) = false is the default. When ON the
    /// record visually "goes cold" (desaturated body).
    var bypass = false {
        didSet { engine.bypass = bypass }
    }

    /// Local mirror of the effect parameters, written read-modify-write by the
    /// macro knobs. Initialized from the engine defaults.
    private var parameters = VinylParameters() {
        didSet { engine.parameters = parameters }
    }

    // MARK: - Macros (0…1 knob values)

    /// Grit / surface noise. Default 0.5.
    var noise: Double = 0.5 {
        didSet { applyNoise() }
    }
    /// Character. drive / wow / narrowing. Default 0.6.
    var main: Double = 0.6 {
        didSet { applyMain() }
    }
    /// Output level. Default 0.77.
    var volume: Double = 0.77 {
        didSet { applyVolume() }
    }

    static let noiseDefault = 0.5
    static let mainDefault = 0.6
    static let volumeDefault = 0.77

    // MARK: - Effect mode (vinyl / slowed + reverb)

    private static let effectModeDefaultsKey = "vinylfy.effectMode"

    /// Active effect chain. The macro knobs remap per mode (slowed: MAIN =
    /// speed, NOISE = reverb depth). Switching resets any user output-hold and
    /// re-derives all engine parameters from the current knob positions.
    var effectMode: HearItEngine.EffectMode = HearItEngine.EffectMode(
        rawValue: UserDefaults.standard.string(forKey: StudioViewModel.effectModeDefaultsKey) ?? ""
    ) ?? .vinyl {
        didSet {
            UserDefaults.standard.set(effectMode.rawValue, forKey: Self.effectModeDefaultsKey)
            userHeldOutput = false
            engine.outputPaused = false
            engine.effectMode = effectMode
            applyNoise()
            applyMain()
            applyVolume()
        }
    }

    /// True while flow control has the source paused (slowed lead draining).
    /// The listener still hears audio, so the UI must read this as "playing".
    private(set) var flowHolding = false

    /// User pressed pause while flow-held: the source is already paused, so we
    /// halt OUR output instead of toggling the source (which would blast raw
    /// unslowed audio). Cleared by the next user play.
    private(set) var userHeldOutput = false

    /// Set by MainViewModel: pause/resume the muted source app (AppleScript).
    var flowHoldHandler: ((Bool) -> Void)?

    /// User play/pause while flow-held: freeze/unfreeze our own output.
    func toggleOutputHold() {
        userHeldOutput.toggle()
        engine.outputPaused = userHeldOutput
        if let snap = snapshot {
            snapshot = snap.replacingIsPlaying(with: !userHeldOutput)
        }
    }

    /// Drop queued (stale) slowed audio across a seek or track jump.
    func flushEffectPlayback() {
        guard effectMode == .slowed else { return }
        engine.flushPlayback()
    }

    // MARK: - Now-playing

    private(set) var snapshot: NowPlayingSnapshot?

    /// Circular-croppable artwork, recomputed only when the PNG data changes.
    private(set) var artworkImage: NSImage?
    private var artworkDataFingerprint: Int?

    /// Gradient base color from the artwork, cached per artwork. Fallback amber
    /// is applied at the view layer when this is nil.
    private(set) var dominantColor: Color?

    // MARK: - Skin

    private static let skinDefaultsKey = "vinylfy.skin"

    /// Selected widget skin, persisted across launches.
    var skinKind: SkinKind = SkinKind(
        rawValue: UserDefaults.standard.string(forKey: StudioViewModel.skinDefaultsKey) ?? ""
    ) ?? .paper {
        didSet { UserDefaults.standard.set(skinKind.rawValue, forKey: Self.skinDefaultsKey) }
    }

    var skin: Skin { Skin.skin(for: skinKind) }

    // MARK: - Error state

    private(set) var startError: String?

    // MARK: - Init

    private init() {
        engine.parameters = parameters
        engine.bypass = bypass
        engine.effectMode = effectMode

        // Route now-playing snapshots back onto the main actor.
        nowPlaying.snapshotHandler = { [weak self] snap in
            Task { @MainActor in
                self?.ingest(snap)
            }
        }

        // Flow control: the engine holds/releases the muted source as the
        // slowed buffer lead crosses its watermarks.
        engine.flowControlHandler = { [weak self] holding in
            Task { @MainActor in
                guard let self else { return }
                self.flowHolding = holding
                self.flowHoldHandler?(holding)
            }
        }
    }

    // MARK: - Lifecycle

    /// Route the engine to vinylize Apple Music only. Call BEFORE `start()`.
    /// `vinylfy.tapTargetOverride` (a bundle id) redirects the tap — used to
    /// point at the MusicKit player helper during the standalone transition.
    func setMusicTapTarget() {
        let override = UserDefaults.standard.string(forKey: "vinylfy.tapTargetOverride")
        engine.tapTarget = .bundle(override ?? "com.apple.Music")
    }

    // MARK: - Standalone source (MusicKit helper)

    /// True while snapshots come from the helper's pushed state instead of the
    /// AppleScript poll. Switching retargets the tap (pipeline restart) and
    /// silences/reawakens the poller.
    private(set) var standaloneActive = false

    func activateStandalone(_ active: Bool, helperBundleID: String) {
        guard standaloneActive != active else { return }
        standaloneActive = active
        if active {
            nowPlaying.stop()
            engine.tapTarget = .bundleWithMediaServices(helperBundleID)
            startSilenceWatchdog()
        } else {
            stopSilenceWatchdog()
            engine.tapTarget = .bundle(
                UserDefaults.standard.string(forKey: "vinylfy.tapTargetOverride") ?? "com.apple.Music"
            )
            nowPlaying.start()
        }
    }

    // MARK: - Silence watchdog (tap stream-set recovery)

    /// CoreAudio taps bind the target's streams at creation; MusicKit starting
    /// a NEW stream in the already-tapped helper is invisible to the tap.
    /// Symptom: source says playing, input meters flatline. Cure: rebuild the
    /// pipeline so the tap rebinds against the live streams. Rate-limited so a
    /// genuinely silent passage can't restart-loop the engine.
    private var silenceWatchdog: Task<Void, Never>?
    private var lastWatchdogRestart = Date.distantPast

    private func startSilenceWatchdog() {
        silenceWatchdog?.cancel()
        silenceWatchdog = Task { [weak self] in
            var silentTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.standaloneActive else { return }
                let playing = (self.snapshot?.isPlaying ?? false) && !self.userHeldOutput
                let silent = self.engine.recentInputPeak() < 1e-5
                if playing && silent && self.isRunning {
                    silentTicks += 1
                } else {
                    silentTicks = 0
                }
                if silentTicks >= 2, Date.now.timeIntervalSince(self.lastWatchdogRestart) > 6 {
                    self.lastWatchdogRestart = .now
                    silentTicks = 0
                    self.engine.restartForSilenceRecovery()
                }
            }
        }
    }

    private func stopSilenceWatchdog() {
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
    }

    /// Entry point for helper-pushed snapshots. The seek/play gates still
    /// apply — pushes arrive at 1Hz, so one pre-command push can be in flight;
    /// the gates absorb it and clear on the first agreeing push.
    func ingestStandaloneSnapshot(_ snap: NowPlayingSnapshot) {
        guard standaloneActive else { return }
        ingest(snap)
    }

    /// Push macro defaults into the engine and auto-start (set-and-forget widget).
    func bootstrap() {
        applyNoise()
        applyMain()
        applyVolume()
        nowPlaying.start()
        start()
    }

    func start() {
        guard !isRunning else { return }
        do {
            try engine.start()
            isRunning = engine.isRunning
            startError = nil
        } catch {
            startError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        engine.stop()
        isRunning = engine.isRunning
    }

    func toggleRunning() {
        if isRunning { stop() } else { start() }
    }

    func toggleBypass() {
        bypass.toggle()
    }

    /// Full teardown for terminate.
    func shutdown() {
        nowPlaying.stop()
        engine.stop()
        isRunning = engine.isRunning
    }

    // MARK: - Macro reset (double-click a knob)

    func resetNoise()  { noise = Self.noiseDefault }
    func resetMain()   { main = Self.mainDefault }
    func resetVolume() { volume = Self.volumeDefault }

    // MARK: - Macro mapping (read-modify-write)

    private func applyNoise() {
        switch effectMode {
        case .vinyl:
            let n = Float(noise.clamped01)
            var p = parameters
            p.hissLevel = 2 * n
            p.crackleRate = 8 * n
            p.crackleIntensity = n == 0 ? 0 : 0.4 + 1.2 * n
            parameters = p
        case .slowed:
            // NOISE knob = reverb depth in slowed mode. Floor of 0.2 so the
            // wash never fully disappears; big bright room for the wide tail.
            var p = engine.slowedParameters
            p.reverbMix = Float(0.2 + 0.55 * noise.clamped01)
            p.roomSize = 0.90
            p.damping = 0.32
            engine.slowedParameters = p
        }
    }

    private func applyMain() {
        switch effectMode {
        case .vinyl:
            let m = Float(main.clamped01)
            var p = parameters
            p.drive = 0.5 * m
            p.wowDepth = 1.6 * m
            p.stereoWidth = 1 - 0.3 * m
            parameters = p
        case .slowed:
            // MAIN knob = tape speed in slowed mode: 0.97x (subtle) down to
            // 0.83x (syrup). Default 0.6 lands near the sweet-spot ~0.89x.
            var p = engine.slowedParameters
            p.rate = 0.97 - 0.14 * main.clamped01
            engine.slowedParameters = p
        }
    }

    private func applyVolume() {
        let v = Float(volume.clamped01)
        var p = parameters
        p.outputGain = 1.3 * v
        parameters = p
        var s = engine.slowedParameters
        s.outputGain = 1.3 * v
        engine.slowedParameters = s
    }

    // MARK: - Pending seek (poll-race gate)

    /// A seek is an async AppleScript; the 2s metadata poll runs on its own
    /// queue. A poll landing between "seek dispatched" and "Music applied it"
    /// still carries the PRE-seek position, which would yank the needle back
    /// before the next poll corrects it. These fields arm a gate: while a seek
    /// is in flight, stale polls are overridden with the extrapolated target
    /// until Music confirms — or the gate expires, so a failed seek (Music
    /// quit, stopped state) can't wedge the position.
    private var pendingSeekTarget: Double?
    private var pendingSeekInstant = Date.distantPast
    private var pendingSeekDeadline = Date.distantPast
    private var pendingSeekTrackKey: String?

    /// How close a polled position must be to the extrapolated target to count
    /// as "Music applied the seek". Scrubs shorter than this never glitched
    /// visibly anyway, so accepting them immediately is harmless.
    private static let seekConfirmTolerance: Double = 3.0

    /// Call at the moment a seek command is dispatched. Optimistically moves
    /// the published position to the target so the UI never sees the stale gap.
    func noteSeek(toSeconds seconds: Double) {
        pendingSeekTarget = seconds
        pendingSeekInstant = .now
        pendingSeekDeadline = .now.addingTimeInterval(5.0)
        pendingSeekTrackKey = snapshot.map(Self.trackKey)
        if let snap = snapshot {
            snapshot = snap.replacingPosition(with: seconds)
        }
    }

    /// While the gate is armed, decide whether an incoming poll reflects the
    /// seek (accept it and disarm) or predates it (hold the extrapolated
    /// target instead). Track change or deadline disarms unconditionally.
    private func reconcilingPendingSeek(_ snap: NowPlayingSnapshot?) -> NowPlayingSnapshot? {
        guard let target = pendingSeekTarget else { return snap }
        guard let snap else {
            pendingSeekTarget = nil
            return nil
        }
        let now = Date.now
        if now > pendingSeekDeadline || Self.trackKey(snap) != pendingSeekTrackKey {
            pendingSeekTarget = nil
            return snap
        }
        // Where playback should be if Music already applied the seek.
        var expected = target + (snap.isPlaying ? now.timeIntervalSince(pendingSeekInstant) : 0)
        if let duration = snap.durationSeconds { expected = min(expected, duration) }
        if let pos = snap.positionSeconds, abs(pos - expected) <= Self.seekConfirmTolerance {
            pendingSeekTarget = nil
            return snap
        }
        return snap.replacingPosition(with: expected)
    }

    private static func trackKey(_ snap: NowPlayingSnapshot) -> String {
        "\(snap.title)\u{1f}\(snap.artist)"
    }

    // MARK: - Pending play/pause (same poll race as seek)

    /// Optimistic play/pause: the button must react instantly, but the polled
    /// isPlaying can lag the AppleScript by a poll or two. Same gate shape as
    /// the seek: hold the expected state until a poll agrees or the deadline
    /// passes (a failed command must not wedge the transport UI).
    private var pendingPlayTarget: Bool?
    private var pendingPlayDeadline = Date.distantPast

    /// Call when a play/pause command is dispatched. Flips the published state
    /// immediately (disc spin, needle creep, and button glyph all follow it).
    func notePlayPause() {
        guard let snap = snapshot else { return }
        let target = !snap.isPlaying
        pendingPlayTarget = target
        pendingPlayDeadline = .now.addingTimeInterval(4.0)
        snapshot = snap.replacingIsPlaying(with: target)
    }

    private func reconcilingPendingPlay(_ snap: NowPlayingSnapshot?) -> NowPlayingSnapshot? {
        guard let target = pendingPlayTarget else { return snap }
        guard let snap else {
            pendingPlayTarget = nil
            return nil
        }
        if snap.isPlaying == target || Date.now > pendingPlayDeadline {
            pendingPlayTarget = nil
            return snap
        }
        return snap.replacingIsPlaying(with: target)
    }

    /// One immediate off-schedule metadata poll (post-transport confirmation).
    func refreshNowPlaying() {
        nowPlaying.pollNow()
    }

    // MARK: - Now-playing ingest

    private func ingest(_ snap: NowPlayingSnapshot?) {
        var reconciled = reconcilingPendingPlay(reconcilingPendingSeek(snap))
        // Flow-held source polls as "paused", but the listener is hearing our
        // queued slowed audio — present it as playing (unless the user froze
        // our output too).
        if flowHolding, let held = reconciled {
            reconciled = held.replacingIsPlaying(with: !userHeldOutput)
        }
        snapshot = reconciled

        let data = snap?.artworkPNGData
        let fingerprint = data?.hashValue
        if fingerprint != artworkDataFingerprint {
            artworkDataFingerprint = fingerprint
            if let data {
                artworkImage = NSImage(data: data)
                if let rgb = ArtworkColor.dominant(from: data) {
                    dominantColor = Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
                } else {
                    dominantColor = nil
                }
            } else {
                artworkImage = nil
                dominantColor = nil
            }
        }
    }

    // MARK: - Derived state

    /// The disc spins only when the engine runs AND playback is active. A
    /// flow-held source counts as active — our queued audio is still playing.
    var isSpinning: Bool {
        isRunning && ((snapshot?.isPlaying ?? false) || (flowHolding && !userHeldOutput))
    }

    /// Base gradient color: artwork dominant, or the warm amber fallback.
    var recordColor: Color {
        dominantColor ?? Color(hex: 0xB0642F)
    }

    var trackLine: String? {
        guard let snap = snapshot else { return nil }
        return "\(snap.title) — \(snap.artist)"
    }

    var positionSeconds: Double? { snapshot?.positionSeconds }
    var durationSeconds: Double? { snapshot?.durationSeconds }

    // MARK: - Live output level (VU meter)

    /// The current output level (0…1), the max of the newest few meter bins.
    /// Poll this at ~20Hz (via TimelineView) to drive the turntable's VU needle.
    /// This is the engine's only exposed meter surface for the UI.
    func outputLevel() -> Float {
        let bins = engine.meters(maxBins: 4).outputLevels
        return bins.max() ?? 0
    }
}

private extension NowPlayingSnapshot {
    /// The same snapshot with only the position swapped (pending-seek gate).
    func replacingPosition(with seconds: Double) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title,
            artist: artist,
            genre: genre,
            isPlaying: isPlaying,
            positionSeconds: max(0, seconds),
            durationSeconds: durationSeconds,
            artworkPNGData: artworkPNGData,
            source: source
        )
    }

    /// The same snapshot with only the play state swapped (play/pause gate).
    func replacingIsPlaying(with playing: Bool) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title,
            artist: artist,
            genre: genre,
            isPlaying: playing,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            artworkPNGData: artworkPNGData,
            source: source
        )
    }
}
