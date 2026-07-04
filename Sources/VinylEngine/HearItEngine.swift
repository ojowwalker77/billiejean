@preconcurrency import AVFoundation
import AppKit
import AudioCapture
import CoreAudio
import DSP
import Foundation

@available(macOS 14.2, *)
public final class HearItEngine: @unchecked Sendable {
    public enum TapTarget: Sendable, Equatable {
        case systemWide
        case bundle(String)
    }

    public struct Meters: Sendable {
        public let inputLevels: [Float]
        public let outputLevels: [Float]
        public let binsPerSecond: Double

        public init(inputLevels: [Float], outputLevels: [Float], binsPerSecond: Double) {
            self.inputLevels = inputLevels
            self.outputLevels = outputLevels
            self.binsPerSecond = binsPerSecond
        }
    }

    public struct Stats: Sendable {
        public let processed: Int
        public let queued: Int
        public let dropped: Int
        public let underruns: Int
        public let restarts: Int

        public init(processed: Int, queued: Int, dropped: Int, underruns: Int = 0, restarts: Int = 0) {
            self.processed = processed
            self.queued = queued
            self.dropped = dropped
            self.underruns = underruns
            self.restarts = restarts
        }
    }

    public var isRunning: Bool {
        stateLock.withLock { running }
    }

    public var bypass: Bool {
        get {
            processorLock.withLock { currentBypass }
        }
        set {
            processorLock.withLock {
                currentBypass = newValue
                processor?.isBypassed = newValue
                slowedProcessor?.isBypassed = newValue
            }
        }
    }

    public var parameters: VinylParameters {
        get {
            processorLock.withLock { currentParameters }
        }
        set {
            processorLock.withLock {
                currentParameters = newValue
                processor?.updateParameters(newValue)
            }
        }
    }

    // MARK: - Effect mode (vinyl / slowed)

    public enum EffectMode: String, Sendable, CaseIterable {
        case vinyl
        case slowed
    }

    /// Which effect chain processes the tap. Switching flushes queued playback
    /// (slowed mode banks seconds of lead; vinyl must not inherit it) and drops
    /// both processors so they rebuild with fresh state at the current rate.
    public var effectMode: EffectMode {
        get {
            processorLock.withLock { currentEffectMode }
        }
        set {
            let changed = processorLock.withLock { () -> Bool in
                guard currentEffectMode != newValue else { return false }
                currentEffectMode = newValue
                processor = nil
                slowedProcessor = nil
                return true
            }
            if changed {
                flushPlayback()
            }
        }
    }

    public var slowedParameters: SlowedParameters {
        get {
            processorLock.withLock { currentSlowedParameters }
        }
        set {
            processorLock.withLock {
                currentSlowedParameters = newValue
                slowedProcessor?.updateParameters(newValue)
            }
        }
    }

    /// Fired (on an arbitrary queue) when the slowed buffer lead crosses the
    /// watermarks: `true` = hold the source (pause upstream; it is muted while
    /// tapped so the listener hears only our queued output), `false` = release.
    public var flowControlHandler: (@Sendable (Bool) -> Void)? {
        get { stateLock.withLock { _flowControlHandler } }
        set { stateLock.withLock { _flowControlHandler = newValue } }
    }

    /// Whether flow control is currently holding the source paused. The UI
    /// treats a flow-held source as "playing" — audio is still coming out.
    public var isFlowHolding: Bool {
        stateLock.withLock { flowHolding }
    }

    /// User-facing pause of OUR output while the source is flow-held (the
    /// source is already paused; toggling it would resume audibly). Halting the
    /// player freezes the render head, so queued sample times stay valid.
    public var outputPaused: Bool {
        get { stateLock.withLock { outputPausedFlag } }
        set {
            stateLock.withLock { outputPausedFlag = newValue }
            playbackQueue.async { [weak self] in
                guard let self, self.playerAttached, self.engine.isRunning else { return }
                if newValue {
                    self.player.pause()
                } else if !self.player.isPlaying {
                    self.player.play()
                }
            }
        }
    }

    /// Drop everything queued but not yet rendered (seek/track-jump in slowed
    /// mode: up to ~12s of stale lead would otherwise play out first). The next
    /// processed buffer re-anchors scheduling; slowed DSP state resets so the
    /// reverb tail and resampler ring don't smear across the jump.
    public func flushPlayback() {
        processorLock.withLock {
            slowedProcessor = nil
        }
        playbackQueue.async { [weak self] in
            guard let self else { return }
            if self.playerAttached {
                self.player.stop()
            }
            self.resetPlaybackQueueState()
        }
    }

    public var statsHandler: (@Sendable (Stats) -> Void)? {
        get {
            stateLock.withLock { _statsHandler }
        }
        set {
            stateLock.withLock {
                _statsHandler = newValue
            }
        }
    }

    public var isExcludingCurrentProcess: Bool {
        stateLock.withLock { excludingCurrentProcess }
    }

    public var tapTarget: TapTarget {
        get {
            stateLock.withLock { currentTapTarget }
        }
        set {
            let shouldRestart = stateLock.withLock { () -> Bool in
                guard currentTapTarget != newValue else {
                    return false
                }
                currentTapTarget = newValue
                return running
            }
            if shouldRestart {
                schedulePipelineRestart(reason: .targetApp)
            }
        }
    }

    private lazy var engine = AVAudioEngine()
    private lazy var player = AVAudioPlayerNode()
    private let processingQueue = DispatchQueue(label: "com.vinylfy.hearit.processing", qos: .userInteractive)
    private let playbackQueue = DispatchQueue(label: "com.vinylfy.hearit.playback", qos: .userInitiated)
    private let restartQueue = DispatchQueue(label: "com.vinylfy.hearit.restart", qos: .userInitiated)
    private let processingQueueKey = DispatchSpecificKey<Void>()
    private let playbackQueueKey = DispatchSpecificKey<Void>()
    private let restartQueueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private let processorLock = NSLock()
    private let meterLock = NSLock()
    private let lifecycleLock = NSLock()
    private let poolLock = NSLock()
    private let debugLogging: Bool

    private var tap: SystemAudioTap?
    private var processor: VinylProcessor?
    private var slowedProcessor: SlowedProcessor?
    private var currentEffectMode: EffectMode = .vinyl
    private var currentSlowedParameters = SlowedParameters()
    private var poolFormat: AVAudioFormat?
    private var poolSlots: [PoolSlot] = []
    private var poolGeneration = 0
    private var debugRecorder: DebugWAVRecorder?
    private var recordingDirectory: URL?
    private var currentSampleRate: Double = 0
    private var currentParameters = VinylParameters()
    private var currentBypass = false
    private var currentTapTarget: TapTarget = .systemWide

    private var running = false
    private var excludingCurrentProcess = false
    private var scheduledBuffers = 0
    private var processedBuffers = 0
    private var droppedBuffers = 0
    private var underrunCount = 0
    private var restartCount = 0
    private var pipelineGeneration = 0
    private var _statsHandler: (@Sendable (Stats) -> Void)?
    private var _flowControlHandler: (@Sendable (Bool) -> Void)?
    private var flowHolding = false
    private var outputPausedFlag = false
    /// playbackQueue-confined: polls the render head while flow-held so the
    /// release fires even though no new input (and thus no schedule()) arrives.
    private var flowDrainTimer: DispatchSourceTimer?
    /// Slowed-mode watermarks, in seconds of scheduled lead beyond the render
    /// head. Hold above high; release below low. Vinyl mode idles near the
    /// ~85ms jitter lead and never crosses either.
    private static let flowHoldHighWaterSeconds: Double = 12
    private static let flowHoldLowWaterSeconds: Double = 3

    private var defaultOutputDeviceListener: AudioObjectPropertyListenerBlock?
    private var engineConfigurationObserver: NSObjectProtocol?
    private var targetLaunchObserver: NSObjectProtocol?
    private var targetTerminateObserver: NSObjectProtocol?
    private var pendingRestartWorkItem: DispatchWorkItem?
    private var suppressEngineConfigurationRestart = false
    private var suppressEngineConfigurationRestartGeneration = 0

    private var playerAttached = false
    private var playbackFormat: AVAudioFormat?
    private var playbackGeneration = 0
    private var nextSampleTime: AVAudioFramePosition = -1
    /// Scheduling lead ahead of the render head (~85ms at 48kHz): the jitter
    /// budget for the tap -> processing -> playback dispatch hops.
    private static let leadFrames: AVAudioFramePosition = 4_096

    private var inputMeterRing = MeterRing(capacity: 4_096)
    private var outputMeterRing = MeterRing(capacity: 4_096)
    private var meterSampleRate: Double = 0

    public init(debugLogging: Bool = false) {
        self.debugLogging = debugLogging
        processingQueue.setSpecific(key: processingQueueKey, value: ())
        playbackQueue.setSpecific(key: playbackQueueKey, value: ())
        restartQueue.setSpecific(key: restartQueueKey, value: ())
    }

    deinit {
        stop()
    }

    public func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        try markStarting()
        resetDSPState()
        resetMeters()
        resetPool()
        prepareDebugRecording()

        do {
            try installPipelineObservers()
            do {
                try startPipelineResources()
            } catch {
                if Self.isTargetProcessNotFound(error) {
                    tearDownPipelineForRestart()
                    if debugLogging {
                        print("pipeline_armed target_process_not_found")
                    }
                    return
                }
                throw error
            }
        } catch {
            stopUnlocked()
            throw error
        }
    }

    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        stopUnlocked()
    }

    private func stopUnlocked() {
        cancelPendingRestart()
        removePipelineObservers()

        let tapToStop: SystemAudioTap? = stateLock.withLock {
            running = false
            suppressEngineConfigurationRestart = false
            suppressEngineConfigurationRestartGeneration &+= 1
            pipelineGeneration &+= 1
            let currentTap = tap
            tap = nil
            return currentTap
        }

        tapToStop?.stop()
        stopPlayback()
        resetDSPState()
        closeDebugRecording()
        resetPool()
    }

    private enum PipelineRestartReason: String, Sendable {
        case deviceChange = "device-change"
        case engineConfig = "engine-config"
        case targetApp = "target-app"
    }

    private func installPipelineObservers() throws {
        try installDefaultOutputDeviceListener()
        installEngineConfigurationObserver()
        installTargetApplicationObservers()
    }

    private func installDefaultOutputDeviceListener() throws {
        guard defaultOutputDeviceListener == nil else {
            return
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.schedulePipelineRestart(reason: .deviceChange)
        }

        var address = Self.defaultOutputDevicePropertyAddress()
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            restartQueue,
            listener
        )

        guard status == noErr else {
            throw NSError(
                domain: "com.vinylfy.hearit",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not observe default output device changes."]
            )
        }

        defaultOutputDeviceListener = listener
    }

    private func installEngineConfigurationObserver() {
        guard engineConfigurationObserver == nil else {
            return
        }

        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.schedulePipelineRestart(reason: .engineConfig)
        }
    }

    private func installTargetApplicationObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        if targetLaunchObserver == nil {
            targetLaunchObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleTargetApplicationNotification(notification)
            }
        }

        if targetTerminateObserver == nil {
            targetTerminateObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleTargetApplicationNotification(notification)
            }
        }
    }

    private func removePipelineObservers() {
        if let listener = defaultOutputDeviceListener {
            var address = Self.defaultOutputDevicePropertyAddress()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                restartQueue,
                listener
            )
            defaultOutputDeviceListener = nil
        }

        if let observer = engineConfigurationObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigurationObserver = nil
        }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let observer = targetLaunchObserver {
            notificationCenter.removeObserver(observer)
            targetLaunchObserver = nil
        }

        if let observer = targetTerminateObserver {
            notificationCenter.removeObserver(observer)
            targetTerminateObserver = nil
        }
    }

    private func handleTargetApplicationNotification(_ notification: Notification) {
        guard let bundleIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .bundleIdentifier else {
            return
        }

        let matchesCurrentTarget = stateLock.withLock { () -> Bool in
            guard case .bundle(let targetBundleIdentifier) = currentTapTarget else {
                return false
            }
            return targetBundleIdentifier == bundleIdentifier
        }

        if matchesCurrentTarget {
            schedulePipelineRestart(reason: .targetApp)
        }
    }

    private static func defaultOutputDevicePropertyAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func schedulePipelineRestart(reason: PipelineRestartReason) {
        let schedule: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            if reason == .engineConfig, self.isEngineConfigurationRestartSuppressed() {
                return
            }
            self.pendingRestartWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                self?.restartPipeline(reason: reason)
            }
            self.pendingRestartWorkItem = workItem
            self.restartQueue.asyncAfter(deadline: .now() + .milliseconds(700), execute: workItem)
        }

        if DispatchQueue.getSpecific(key: restartQueueKey) != nil {
            schedule()
        } else {
            restartQueue.async(execute: schedule)
        }
    }

    private func cancelPendingRestart() {
        let cancel: @Sendable () -> Void = { [weak self] in
            self?.pendingRestartWorkItem?.cancel()
            self?.pendingRestartWorkItem = nil
        }

        if DispatchQueue.getSpecific(key: restartQueueKey) != nil {
            cancel()
        } else {
            restartQueue.async(execute: cancel)
        }
    }

    private func restartPipeline(reason: PipelineRestartReason, attempt: Int = 0) {
        pendingRestartWorkItem = nil

        lifecycleLock.lock()
        let isRunning = stateLock.withLock { running }
        guard isRunning else {
            lifecycleLock.unlock()
            return
        }

        let suppressionGeneration = beginEngineConfigurationRestartSuppression()
        tearDownPipelineForRestart()

        do {
            try startPipelineResources()
            stateLock.withLock {
                restartCount += 1
            }
            lifecycleLock.unlock()
            clearEngineConfigurationRestartSuppressionSoon(generation: suppressionGeneration)

            if debugLogging {
                print("pipeline_restarted reason=\(reason.rawValue)")
            }
        } catch {
            tearDownPipelineForRestart()
            lifecycleLock.unlock()
            clearEngineConfigurationRestartSuppressionSoon(generation: suppressionGeneration)
            scheduleRestartRetry(reason: reason, attempt: attempt, error: error)
        }
    }

    private func isEngineConfigurationRestartSuppressed() -> Bool {
        stateLock.withLock { suppressEngineConfigurationRestart }
    }

    private func beginEngineConfigurationRestartSuppression() -> Int {
        stateLock.withLock {
            suppressEngineConfigurationRestart = true
            suppressEngineConfigurationRestartGeneration &+= 1
            return suppressEngineConfigurationRestartGeneration
        }
    }

    private func clearEngineConfigurationRestartSuppressionSoon(generation: Int) {
        restartQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                guard self.suppressEngineConfigurationRestartGeneration == generation else {
                    return
                }
                self.suppressEngineConfigurationRestart = false
            }
        }
    }

    private func scheduleRestartRetry(reason: PipelineRestartReason, attempt: Int, error: Error) {
        guard attempt < 5 else {
            if debugLogging {
                print("pipeline_restart_gave_up reason=\(reason.rawValue) error=\(error.localizedDescription)")
            }
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.restartPipeline(reason: reason, attempt: attempt + 1)
        }
        pendingRestartWorkItem = workItem
        restartQueue.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func tearDownPipelineForRestart() {
        let tapToStop: SystemAudioTap? = stateLock.withLock {
            let currentTap = tap
            tap = nil
            excludingCurrentProcess = false
            pipelineGeneration &+= 1
            return currentTap
        }

        tapToStop?.stop()
        stopPlayback()
        resetDSPState()
        resetPool()
    }

    public func meters(maxBins: Int) -> Meters {
        meterLock.lock()
        defer { meterLock.unlock() }

        let clampedMaxBins = max(0, maxBins)
        return Meters(
            inputLevels: inputMeterRing.newest(maxBins: clampedMaxBins),
            outputLevels: outputMeterRing.newest(maxBins: clampedMaxBins),
            binsPerSecond: meterSampleRate > 0 ? meterSampleRate / Double(MeterRing.binFrameCount) : 0
        )
    }

    public func stats() -> Stats {
        stateLock.withLock {
            Stats(
                processed: processedBuffers,
                queued: scheduledBuffers,
                dropped: droppedBuffers,
                underruns: underrunCount,
                restarts: restartCount
            )
        }
    }

    private func markStarting() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !running else {
            throw AudioError.alreadyRunning
        }

        running = true
        excludingCurrentProcess = false
        scheduledBuffers = 0
        processedBuffers = 0
        droppedBuffers = 0
        underrunCount = 0
        restartCount = 0
        pipelineGeneration &+= 1
    }

    private func startPipelineResources() throws {
        let scope = try tapScopeForCurrentTarget()
        try preparePlayback()

        let tap = SystemAudioTap(
            scope: scope,
            debugLogging: debugLogging
        )
        stateLock.withLock {
            self.tap = tap
        }

        do {
            try tap.start { [weak self] buffer, _ in
                self?.handle(buffer)
            }
        } catch {
            stateLock.withLock {
                if self.tap === tap {
                    self.tap = nil
                }
            }
            tap.stop()
            throw error
        }
    }

    private func tapScopeForCurrentTarget() throws -> SystemAudioTap.TapScope {
        let target = stateLock.withLock { currentTapTarget }

        switch target {
        case .systemWide:
            let excludedProcesses = Self.currentProcessObjectIDsForExclusionWithRetry()
            stateLock.withLock {
                excludingCurrentProcess = !excludedProcesses.isEmpty
            }
            return .globalExcluding(excludedProcesses)

        case .bundle(let bundleIdentifier):
            let processObjectIDs = Self.processObjectIDs(forBundleIdentifier: bundleIdentifier)
            guard !processObjectIDs.isEmpty else {
                stateLock.withLock {
                    excludingCurrentProcess = false
                }
                throw AudioError.targetProcessNotFound(bundleIdentifier)
            }
            stateLock.withLock {
                excludingCurrentProcess = false
            }
            return .processes(processObjectIDs)
        }
    }

    private static func isTargetProcessNotFound(_ error: Error) -> Bool {
        guard case AudioError.targetProcessNotFound = error else {
            return false
        }
        return true
    }

    private func preparePlayback() throws {
        var startError: Error?
        playbackQueue.sync {
            if !playerAttached {
                engine.attach(player)
                playerAttached = true
            }
            engine.connect(player, to: engine.mainMixerNode, format: nil)
            engine.mainMixerNode.outputVolume = 0.85
            resetPlaybackQueueState()

            do {
                try engine.start()
            } catch {
                startError = error
            }
        }

        if let startError {
            throw startError
        }
    }

    private func stopPlayback() {
        let work = {
            if self.playerAttached {
                self.player.stop()
            }
            self.resetPlaybackQueueState()
        }

        if DispatchQueue.getSpecific(key: playbackQueueKey) != nil {
            work()
        } else {
            playbackQueue.sync(execute: work)
        }
        engine.stop()
    }

    private func resetPlaybackQueueState() {
        playbackFormat = nil
        playbackGeneration &+= 1
        nextSampleTime = -1
        stateLock.withLock {
            scheduledBuffers = 0
        }
        releaseFlowHold()
    }

    private func resetDSPState() {
        processorLock.withLock {
            processor = nil
            slowedProcessor = nil
            currentSampleRate = 0
        }
    }

    private func resetMeters() {
        meterLock.lock()
        inputMeterRing.reset()
        outputMeterRing.reset()
        meterSampleRate = 0
        meterLock.unlock()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let pooled = copyIntoPool(buffer) else {
            processingQueue.async { [weak self] in
                self?.incrementDroppedBuffer()
            }
            return
        }

        processingQueue.async { [weak self, pooled] in
            self?.processPooledBuffer(pooled)
        }
    }

    private func processPooledBuffer(_ pooled: PooledAudioBuffer) {
        defer {
            releasePoolBuffer(pooled)
        }

        guard stateLock.withLock({ running && pipelineGeneration == pooled.pipelineGeneration }) else {
            return
        }

        let buffer = pooled.buffer
        meterLock.lock()
        meterSampleRate = buffer.format.sampleRate
        inputMeterRing.append(buffer)
        meterLock.unlock()

        debugRecorder?.writeInput(buffer)

        let processed = process(buffer)
        guard let processed else {
            incrementDroppedBuffer()
            return
        }

        meterLock.lock()
        outputMeterRing.append(processed)
        meterLock.unlock()

        let processedCount = stateLock.withLock { () -> Int in
            processedBuffers += 1
            return processedBuffers
        }

        debugRecorder?.writeOutput(processed)

        playbackQueue.async { [weak self, processed] in
            self?.schedule(
                processed,
                processedCount: processedCount,
                pipelineGeneration: pooled.pipelineGeneration
            )
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sampleRate = buffer.format.sampleRate
        var didChangeFormat = false

        processorLock.lock()
        if sampleRate != currentSampleRate {
            processor = nil
            slowedProcessor = nil
            currentSampleRate = sampleRate
            didChangeFormat = true
        }
        let processed: AVAudioPCMBuffer?
        switch currentEffectMode {
        case .vinyl:
            if processor == nil {
                let next = VinylProcessor(sampleRate: sampleRate, parameters: currentParameters)
                next.isBypassed = currentBypass
                processor = next
            }
            processed = processor?.process(buffer)
        case .slowed:
            if slowedProcessor == nil {
                let next = SlowedProcessor(sampleRate: sampleRate, parameters: currentSlowedParameters)
                next.isBypassed = currentBypass
                slowedProcessor = next
            }
            processed = slowedProcessor?.process(buffer)
        }
        processorLock.unlock()

        if didChangeFormat, debugLogging {
            print("Tap format: \(Int(sampleRate)) Hz, \(buffer.format.channelCount) channels")
        }

        return processed
    }

    private func schedule(
        _ buffer: AVAudioPCMBuffer,
        processedCount: Int,
        pipelineGeneration scheduledPipelineGeneration: Int
    ) {
        guard stateLock.withLock({ running && pipelineGeneration == scheduledPipelineGeneration }) else {
            return
        }

        if playbackFormat.map({ !buffer.format.isEqual($0) }) ?? true {
            player.stop()
            resetPlaybackQueueState()
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            playbackFormat = buffer.format
        }

        if !player.isPlaying && !stateLock.withLock({ outputPausedFlag }) {
            player.play()
        }

        // Place every buffer on an explicit sample-time grid a fixed lead ahead of
        // the render head. Arrival jitter is absorbed by the lead instead of racing
        // the renderer; a buffer that misses its slot forces a resync (one audible
        // gap) and counts as a real underrun.
        let sampleRate = buffer.format.sampleRate
        var didUnderrun = false
        if let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
           let playerTime = player.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid {
            let renderHead = playerTime.sampleTime
            if nextSampleTime < 0 {
                nextSampleTime = renderHead + Self.leadFrames
            } else if nextSampleTime <= renderHead {
                nextSampleTime = renderHead + Self.leadFrames
                didUnderrun = true
            }
        } else if nextSampleTime < 0 {
            nextSampleTime = Self.leadFrames
        }

        let when = AVAudioTime(sampleTime: nextSampleTime, atRate: sampleRate)
        nextSampleTime += AVAudioFramePosition(buffer.frameLength)

        // Slowed mode emits more output time than input time, so the scheduled
        // lead grows without bound. The source is muted while tapped, so flow-
        // control it: hold (pause) above the high watermark; the drain timer
        // releases below the low one.
        if let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
           let playerTime = player.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid {
            updateFlowControl(leadFrames: nextSampleTime - playerTime.sampleTime, sampleRate: sampleRate)
        }

        let stats = stateLock.withLock { () -> Stats in
            scheduledBuffers += 1
            if didUnderrun {
                underrunCount += 1
            }
            return Stats(
                processed: processedCount,
                queued: scheduledBuffers,
                dropped: droppedBuffers,
                underruns: underrunCount,
                restarts: restartCount
            )
        }

        let generation = playbackGeneration
        player.scheduleBuffer(buffer, at: when, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let engine = self else {
                return
            }
            engine.playbackQueue.async { [engine] in
                engine.scheduledBufferCompleted(generation: generation)
            }
        }

        if let statsHandler = stateLock.withLock({ _statsHandler }) {
            statsHandler(stats)
        }
    }

    /// playbackQueue only. Hold when the lead tops the high watermark; while
    /// held, a 500ms timer polls the render head for the release (no input
    /// arrives while the source is paused, so schedule() can't observe it).
    private func updateFlowControl(leadFrames: AVAudioFramePosition, sampleRate: Double) {
        guard sampleRate > 0 else { return }
        let leadSeconds = Double(leadFrames) / sampleRate

        if leadSeconds >= Self.flowHoldHighWaterSeconds {
            let shouldFire = stateLock.withLock { () -> Bool in
                guard !flowHolding else { return false }
                flowHolding = true
                return true
            }
            if shouldFire {
                startFlowDrainTimer(sampleRate: sampleRate)
                stateLock.withLock { _flowControlHandler }?(true)
            }
        }
    }

    /// playbackQueue only.
    private func startFlowDrainTimer(sampleRate: Double) {
        flowDrainTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: playbackQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // While the user has our output paused the lead isn't draining —
            // and releasing would audibly resume the source. Wait.
            guard !self.stateLock.withLock({ self.outputPausedFlag }) else { return }

            var drained = self.nextSampleTime < 0
            if !drained,
               let nodeTime = self.player.lastRenderTime, nodeTime.isSampleTimeValid,
               let playerTime = self.player.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid {
                let leadSeconds = Double(self.nextSampleTime - playerTime.sampleTime) / sampleRate
                drained = leadSeconds <= Self.flowHoldLowWaterSeconds
            }
            if drained {
                self.releaseFlowHold()
            }
        }
        flowDrainTimer = timer
        timer.resume()
    }

    /// playbackQueue only. Idempotent; also called from resetPlaybackQueueState
    /// so a stop/seek/mode-switch never strands the source paused.
    private func releaseFlowHold() {
        flowDrainTimer?.cancel()
        flowDrainTimer = nil
        let shouldFire = stateLock.withLock { () -> Bool in
            guard flowHolding else { return false }
            flowHolding = false
            return true
        }
        if shouldFire {
            stateLock.withLock { _flowControlHandler }?(false)
        }
    }

    private func scheduledBufferCompleted(generation: Int) {
        guard generation == playbackGeneration else {
            return
        }

        stateLock.withLock {
            if scheduledBuffers > 0 {
                scheduledBuffers -= 1
            }
        }
    }

    private func copyIntoPool(_ source: AVAudioPCMBuffer) -> PooledAudioBuffer? {
        guard source.frameLength <= PoolSlot.frameCapacity else {
            return nil
        }

        let pipelineGeneration = stateLock.withLock { self.pipelineGeneration }

        poolLock.lock()

        if poolFormat.map({ !source.format.isEqual($0) }) ?? true {
            guard rebuildPool(format: source.format) else {
                poolLock.unlock()
                return nil
            }
        }

        guard let index = poolSlots.firstIndex(where: { !$0.isInUse }) else {
            poolLock.unlock()
            return nil
        }

        let slot = poolSlots[index]
        slot.isInUse = true
        let pooled = PooledAudioBuffer(
            buffer: slot.buffer,
            index: index,
            generation: poolGeneration,
            pipelineGeneration: pipelineGeneration
        )
        poolLock.unlock()

        guard copyAudioData(from: source, to: pooled.buffer) else {
            releasePoolBuffer(pooled)
            return nil
        }

        return pooled
    }

    private func rebuildPool(format: AVAudioFormat) -> Bool {
        var nextSlots: [PoolSlot] = []
        nextSlots.reserveCapacity(PoolSlot.count)

        for _ in 0..<PoolSlot.count {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: PoolSlot.frameCapacity
            ) else {
                return false
            }
            nextSlots.append(PoolSlot(buffer: buffer))
        }

        poolSlots = nextSlots
        poolFormat = format
        poolGeneration &+= 1
        return true
    }

    private func releasePoolBuffer(_ pooled: PooledAudioBuffer) {
        poolLock.lock()
        if pooled.generation == poolGeneration, poolSlots.indices.contains(pooled.index) {
            poolSlots[pooled.index].isInUse = false
            poolSlots[pooled.index].buffer.frameLength = 0
        }
        poolLock.unlock()
    }

    private func resetPool() {
        poolLock.lock()
        poolSlots.removeAll(keepingCapacity: false)
        poolFormat = nil
        poolGeneration &+= 1
        poolLock.unlock()
    }

    private func copyAudioData(from source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) -> Bool {
        guard source.format.isEqual(destination.format),
              source.frameLength <= destination.frameCapacity else {
            return false
        }

        destination.frameLength = source.frameLength

        guard let sourceChannels = source.floatChannelData,
              let destinationChannels = destination.floatChannelData else {
            destination.frameLength = 0
            return false
        }

        let frameCount = Int(source.frameLength)
        let channelCount = Int(source.format.channelCount)
        if source.format.isInterleaved {
            memcpy(
                destinationChannels[0],
                sourceChannels[0],
                frameCount * channelCount * MemoryLayout<Float>.size
            )
        } else {
            for channel in 0..<channelCount {
                memcpy(
                    destinationChannels[channel],
                    sourceChannels[channel],
                    frameCount * MemoryLayout<Float>.size
                )
            }
        }

        return true
    }

    private func incrementDroppedBuffer() {
        stateLock.withLock {
            droppedBuffers += 1
        }
    }

    private func prepareDebugRecording() {
        let environment = ProcessInfo.processInfo.environment
        guard let rawDirectory = environment["VINYLFY_RECORD_DIR"], !rawDirectory.isEmpty else {
            recordingDirectory = nil
            debugRecorder = nil
            return
        }

        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue, FileManager.default.isWritableFile(atPath: directory.path) else {
            print("VINYLFY_RECORD_DIR is not a writable directory: \(directory.path)")
            recordingDirectory = nil
            debugRecorder = nil
            return
        }

        recordingDirectory = directory
        debugRecorder = DebugWAVRecorder(directory: directory)
        print("Recording input WAV to \(directory.appendingPathComponent("input.wav").path)")
        print("Recording output WAV to \(directory.appendingPathComponent("output.wav").path)")
    }

    private func closeDebugRecording() {
        let work = {
            self.debugRecorder?.close()
            self.debugRecorder = nil
            self.recordingDirectory = nil
        }

        if DispatchQueue.getSpecific(key: processingQueueKey) != nil {
            work()
        } else {
            processingQueue.sync(execute: work)
        }
    }

    private static func currentProcessObjectIDsForExclusionWithRetry() -> [AudioObjectID] {
        for _ in 0..<20 {
            let ids = SystemAudioTap.currentProcessObjectIDsForExclusion()
            if !ids.isEmpty {
                return ids
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return []
    }

    private static func processObjectIDs(forBundleIdentifier bundleIdentifier: String) -> [AudioObjectID] {
        let pids = NSWorkspace.shared.runningApplications.compactMap { application -> pid_t? in
            guard application.bundleIdentifier == bundleIdentifier, !application.isTerminated else {
                return nil
            }
            return application.processIdentifier
        }

        var processObjectIDs: [AudioObjectID] = []
        for pid in pids {
            processObjectIDs.append(contentsOf: SystemAudioTap.processObjectIDs(forPID: pid))
        }
        return processObjectIDs
    }
}

private struct PooledAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let index: Int
    let generation: Int
    let pipelineGeneration: Int
}

private final class PoolSlot {
    static let count = 16
    static let frameCapacity: AVAudioFrameCount = 8_192

    let buffer: AVAudioPCMBuffer
    var isInUse = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class DebugWAVRecorder {
    private enum Stream {
        case input
        case output

        var fileDescription: String {
            switch self {
            case .input:
                return "input.wav"
            case .output:
                return "output.wav"
            }
        }
    }

    private let inputURL: URL
    private let outputURL: URL
    private var inputFile: AVAudioFile?
    private var outputFile: AVAudioFile?
    private var inputFileFormat: AVAudioFormat?
    private var outputFileFormat: AVAudioFormat?
    private var inputConverter: AVAudioConverter?
    private var outputConverter: AVAudioConverter?
    private var warnedInputFormatChange = false
    private var warnedOutputFormatChange = false

    init(directory: URL) {
        inputURL = directory.appendingPathComponent("input.wav")
        outputURL = directory.appendingPathComponent("output.wav")
    }

    func writeInput(_ buffer: AVAudioPCMBuffer) {
        write(buffer, stream: .input)
    }

    func writeOutput(_ buffer: AVAudioPCMBuffer) {
        write(buffer, stream: .output)
    }

    func close() {
        inputFile = nil
        outputFile = nil
        inputFileFormat = nil
        outputFileFormat = nil
        inputConverter = nil
        outputConverter = nil
    }

    private func write(_ buffer: AVAudioPCMBuffer, stream: Stream) {
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: buffer.format.sampleRate,
            channels: buffer.format.channelCount
        ) else {
            return
        }

        do {
            let file = try file(for: stream, targetFormat: targetFormat)
            guard let converted = convertedBuffer(buffer, to: targetFormat, stream: stream) else {
                return
            }
            try file.write(from: converted)
        } catch {
            print("Could not record \(stream.fileDescription): \(error.localizedDescription)")
        }
    }

    private func file(for stream: Stream, targetFormat: AVAudioFormat) throws -> AVAudioFile {
        switch stream {
        case .input:
            if let inputFile {
                if inputFileFormat?.isEqual(targetFormat) == true {
                    return inputFile
                }
                if !warnedInputFormatChange {
                    print("Input recording skipped after tap format changed.")
                    warnedInputFormatChange = true
                }
                throw AudioError.invalidTapFormat
            }

            let file = try AVAudioFile(
                forWriting: inputURL,
                settings: targetFormat.settings,
                commonFormat: targetFormat.commonFormat,
                interleaved: targetFormat.isInterleaved
            )
            inputFile = file
            inputFileFormat = targetFormat
            return file

        case .output:
            if let outputFile {
                if outputFileFormat?.isEqual(targetFormat) == true {
                    return outputFile
                }
                if !warnedOutputFormatChange {
                    print("Output recording skipped after processed format changed.")
                    warnedOutputFormatChange = true
                }
                throw AudioError.invalidTapFormat
            }

            let file = try AVAudioFile(
                forWriting: outputURL,
                settings: targetFormat.settings,
                commonFormat: targetFormat.commonFormat,
                interleaved: targetFormat.isInterleaved
            )
            outputFile = file
            outputFileFormat = targetFormat
            return file
        }
    }

    private func convertedBuffer(
        _ buffer: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat,
        stream: Stream
    ) -> AVAudioPCMBuffer? {
        if buffer.format.isEqual(targetFormat) {
            return buffer
        }

        let converter: AVAudioConverter
        switch stream {
        case .input:
            if let inputConverter {
                converter = inputConverter
            } else {
                guard let nextConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                    return nil
                }
                inputConverter = nextConverter
                converter = nextConverter
            }
        case .output:
            if let outputConverter {
                converter = outputConverter
            } else {
                guard let nextConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                    return nil
                }
                outputConverter = nextConverter
                converter = nextConverter
            }
        }

        let outputCapacity = max(
            1,
            AVAudioFrameCount(ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)) + 16
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        let inputProvider = ConverterInputProvider(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if inputProvider.didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputProvider.didProvideInput = true
            inputStatus.pointee = .haveData
            return inputProvider.buffer
        }

        if status == .error {
            if let conversionError {
                print("Could not convert \(stream.fileDescription) for recording: \(conversionError.localizedDescription)")
            }
            return nil
        }

        return output.frameLength > 0 ? output : nil
    }
}

private final class ConverterInputProvider: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private struct MeterRing {
    static let binFrameCount = 256

    private var bins: [Float]
    private var writeIndex = 0
    private var count = 0
    private var partialPeak: Float = 0
    private var partialFrameCount = 0

    init(capacity: Int) {
        bins = Array(repeating: 0, count: capacity)
    }

    mutating func reset() {
        for index in bins.indices {
            bins[index] = 0
        }
        writeIndex = 0
        count = 0
        partialPeak = 0
        partialFrameCount = 0
    }

    mutating func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return
        }

        let isInterleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        for frame in 0..<frameCount {
            var peak: Float = 0
            for channel in 0..<channelCount {
                peak = max(
                    peak,
                    abs(Self.sample(
                        from: channels,
                        channel: channel,
                        frame: frame,
                        stride: stride,
                        isInterleaved: isInterleaved
                    ))
                )
            }
            appendSamplePeak(min(1, peak))
        }
    }

    func newest(maxBins: Int) -> [Float] {
        guard maxBins > 0, count > 0 else {
            return []
        }

        let resultCount = min(maxBins, count)
        let start = (writeIndex - resultCount + bins.count) % bins.count
        var result: [Float] = []
        result.reserveCapacity(resultCount)

        for offset in 0..<resultCount {
            result.append(bins[(start + offset) % bins.count])
        }
        return result
    }

    private mutating func appendSamplePeak(_ peak: Float) {
        partialPeak = max(partialPeak, peak)
        partialFrameCount += 1

        if partialFrameCount == Self.binFrameCount {
            appendBin(partialPeak)
            partialPeak = 0
            partialFrameCount = 0
        }
    }

    private mutating func appendBin(_ peak: Float) {
        bins[writeIndex] = peak
        writeIndex = (writeIndex + 1) % bins.count
        count = min(count + 1, bins.count)
    }

    private static func sample(
        from channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channel: Int,
        frame: Int,
        stride: Int,
        isInterleaved: Bool
    ) -> Float {
        if isInterleaved {
            return channels[0][frame * stride + channel]
        }
        return channels[channel][frame]
    }
}
