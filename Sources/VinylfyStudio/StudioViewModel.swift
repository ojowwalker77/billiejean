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

        // Route now-playing snapshots back onto the main actor.
        nowPlaying.snapshotHandler = { [weak self] snap in
            Task { @MainActor in
                self?.ingest(snap)
            }
        }
    }

    // MARK: - Lifecycle

    /// Route the engine to vinylize Apple Music only. Call BEFORE `start()`.
    func setMusicTapTarget() {
        engine.tapTarget = .bundle("com.apple.Music")
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
        let n = Float(noise.clamped01)
        var p = parameters
        p.hissLevel = 2 * n
        p.crackleRate = 8 * n
        p.crackleIntensity = n == 0 ? 0 : 0.4 + 1.2 * n
        parameters = p
    }

    private func applyMain() {
        let m = Float(main.clamped01)
        var p = parameters
        p.drive = 0.5 * m
        p.wowDepth = 1.6 * m
        p.stereoWidth = 1 - 0.3 * m
        parameters = p
    }

    private func applyVolume() {
        let v = Float(volume.clamped01)
        var p = parameters
        p.outputGain = 1.3 * v
        parameters = p
    }

    // MARK: - Now-playing ingest

    private func ingest(_ snap: NowPlayingSnapshot?) {
        snapshot = snap

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

    /// The disc spins only when the engine runs AND playback is active.
    var isSpinning: Bool {
        isRunning && (snapshot?.isPlaying ?? false)
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
}
