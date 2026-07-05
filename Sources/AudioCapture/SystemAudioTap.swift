import AudioToolbox
import CoreAudio
import Foundation
import OSLog
@preconcurrency import AVFoundation

@available(macOS 14.2, *)
public final class SystemAudioTap: @unchecked Sendable {
    public enum TapScope: Sendable {
        case globalExcluding([AudioObjectID])
        case processes([AudioObjectID])
    }

    public typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private enum LifecycleState {
        case idle
        case starting
        case running
        case stopping
    }

    private let logger = Logger(subsystem: "com.vinylfy.app", category: "SystemAudioTap")
    private let queue = DispatchQueue(label: "com.vinylfy.systemaudiotap", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "com.vinylfy.systemaudiotap.io", qos: .userInteractive)
    private let watchdogQueue = DispatchQueue(label: "com.vinylfy.systemaudiotap.watchdog", qos: .utility)

    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapStreamDescription: AudioStreamBasicDescription?
    private var tapUUIDString: String?
    private var lastPinnedOutputUID: String?
    private let watchdogLock = NSLock()
    private var firstBufferReceived = false
    private var watchdogWorkItem: DispatchWorkItem?

    private var state: LifecycleState = .idle
    private var bufferHandler: AudioBufferHandler?
    private let scope: TapScope
    private let debugLogging: Bool

    public init(scope: TapScope, debugLogging: Bool = false) {
        self.scope = scope
        self.debugLogging = debugLogging
    }

    public init(excludedProcessObjectIDs: [AudioObjectID] = [], debugLogging: Bool = false) {
        self.scope = .globalExcluding(excludedProcessObjectIDs)
        self.debugLogging = debugLogging
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping AudioBufferHandler) throws {
        var startError: Error?
        var didStart = false

        queue.sync {
            guard state == .idle else {
                startError = AudioError.alreadyRunning
                return
            }

            state = .starting
            bufferHandler = handler

            do {
                debug("creating process tap")
                try createProcessTap()
                debug("created process tap")
                debug("creating aggregate device")
                try createAggregateDevice()
                debug("created aggregate device")
                Thread.sleep(forTimeInterval: 0.25)
                debug("starting device IO")
                try startDeviceIO()
                debug("started device IO")
                state = .running
                didStart = true
            } catch {
                tearDownResources(clearHandler: true)
                startError = error
            }
        }

        if let startError {
            throw startError
        }
        if didStart {
            logger.info(
                "system_audio_tap_started aggregate_device_id=\(self.aggregateDeviceID, privacy: .public) tap_id=\(self.tapID, privacy: .public) pinned_output_uid=\(self.lastPinnedOutputUID ?? "unknown", privacy: .public) sample_rate=\(self.tapStreamDescription?.mSampleRate ?? 0, privacy: .public) channels=\(self.tapStreamDescription?.mChannelsPerFrame ?? 0, privacy: .public)"
            )
        }
    }

    public func stop() {
        var didStop = false
        queue.sync {
            guard state != .idle || aggregateDeviceID != 0 || tapID != 0 else { return }
            state = .stopping
            tearDownResources(clearHandler: true)
            didStop = true
        }
        if didStop {
            logger.info("system_audio_tap_stopped")
        }
    }

    private func tearDownResources(clearHandler: Bool) {
        if aggregateDeviceID != 0, let procID = deviceProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceProcID = nil
        }

        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }

        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }

        if clearHandler {
            bufferHandler = nil
        }
        state = .idle
        tapUUIDString = nil
        lastPinnedOutputUID = nil
        resetDiagnosticsState()
    }

    private func createProcessTap() throws {
        let tapDescription: CATapDescription
        switch scope {
        case .globalExcluding(let excludedProcessObjectIDs):
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcessObjectIDs)
        case .processes(let processObjectIDs):
            tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        }

        let tapUUID = UUID()
        tapDescription.uuid = tapUUID
        tapDescription.muteBehavior = .mutedWhenTapped
        tapUUIDString = tapUUID.uuidString

        var newTapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)

        guard status == noErr else {
            throw AudioError.tapCreationFailed(status)
        }

        tapID = newTapID
        tapStreamDescription = try readTapStreamFormat(from: newTapID)
    }

    private func debug(_ message: String) {
        guard debugLogging else { return }
        print("[SystemAudioTap] \(message)")
    }

    public static func currentProcessObjectIDsForExclusion() -> [AudioObjectID] {
        processObjectIDs(forPID: getpid())
    }

    /// All CoreAudio process objects whose bundle id contains `substring`.
    /// Needed for out-of-process renderers: MusicKit's ApplicationMusicPlayer
    /// renders in MediaPlayer's RemotePlayerService XPC — the host process
    /// itself never owns the audio.
    public static func processObjectIDs(matchingBundleSubstring substring: String) -> [AudioObjectID] {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &objects
        ) == noErr else { return [] }

        var bundleAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return objects.filter { object in
            guard object != kAudioObjectUnknown else { return false }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr,
                  let value = bundle?.takeRetainedValue() else { return false }
            return (value as String).localizedCaseInsensitiveContains(substring)
        }
    }

    public static func processObjectIDs(forPID pid: pid_t) -> [AudioObjectID] {
        var pid = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            qualifierSize,
            &pid,
            &size,
            &processObjectID
        )
        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            return []
        }
        return [processObjectID]
    }

    private func readTapStreamFormat(from tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw AudioError.tapCreationFailed(status)
        }
        return asbd
    }

    private func currentDefaultOutputDeviceUID() throws -> String {
        var deviceID: AudioDeviceID = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            throw AudioError.noOutputDevice
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &size, &uid)
        guard status == noErr, let retained = uid else {
            throw AudioError.noOutputDevice
        }
        return retained.takeRetainedValue() as String
    }

    private func createAggregateDevice() throws {
        guard let tapUUIDString else {
            throw AudioError.invalidTapFormat
        }

        let outputUID = try currentDefaultOutputDeviceUID()
        let aggregateUID = "com.vinylfy.tap.\(UUID().uuidString)"
        lastPinnedOutputUID = outputUID

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Vinylfy Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUIDString,
                ]
            ]
        ]

        var newDeviceID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)

        guard status == noErr else {
            throw AudioError.aggregateDeviceCreationFailed(status)
        }

        aggregateDeviceID = newDeviceID
    }

    private func startDeviceIO() throws {
        guard var streamDesc = tapStreamDescription else {
            throw AudioError.invalidTapFormat
        }

        // The IOProc delivers frames at the aggregate device's rate (pinned to the
        // physical output device), which can differ from the rate the tap claims
        // (e.g. 44.1kHz Bluetooth device vs 48kHz tap format). Mislabeling the
        // buffers pitch-shifts and time-stretches everything downstream.
        if let deviceRate = aggregateNominalSampleRate(), deviceRate != streamDesc.mSampleRate {
            debug("overriding tap rate \(streamDesc.mSampleRate) with device rate \(deviceRate)")
            streamDesc.mSampleRate = deviceRate
        }

        guard let format = AVAudioFormat(streamDescription: &streamDesc) else {
            throw AudioError.invalidTapFormat
        }

        let ioBlock: AudioDeviceIOBlock = { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self,
                  let callback = self.bufferHandler,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: inInputData,
                    deallocator: nil
                  ) else {
                return
            }

            self.markFirstBufferReceived()
            let time = AVAudioTime(hostTime: inInputTime.pointee.mHostTime)
            callback(buffer, time)
        }

        var procID: AudioDeviceIOProcID?
        debug("creating IOProc")
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil, ioBlock)
        debug("created IOProc status=\(status)")

        guard status == noErr else {
            throw AudioError.aggregateDeviceCreationFailed(status)
        }

        deviceProcID = procID
        scheduleSilentBufferWatchdog()
        debug("calling AudioDeviceStart")
        status = AudioDeviceStart(aggregateDeviceID, procID)
        debug("AudioDeviceStart returned status=\(status)")

        guard status == noErr else {
            throw AudioError.aggregateDeviceCreationFailed(status)
        }
    }

    private func aggregateNominalSampleRate() -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(aggregateDeviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else {
            return nil
        }
        return rate
    }

    private func scheduleSilentBufferWatchdog() {
        let workItem = watchdogLock.withLock { () -> DispatchWorkItem in
            firstBufferReceived = false
            watchdogWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldLog = self.watchdogLock.withLock { !self.firstBufferReceived }
                guard shouldLog else { return }
                self.logger.warning(
                    "system_audio_tap_no_buffers_within_timeout pinned_output_uid=\(self.lastPinnedOutputUID ?? "unknown", privacy: .public) aggregate_device_id=\(self.aggregateDeviceID, privacy: .public)"
                )
            }
            watchdogWorkItem = item
            return item
        }
        watchdogQueue.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func markFirstBufferReceived() {
        let shouldLog = watchdogLock.withLock {
            guard !firstBufferReceived else { return false }
            firstBufferReceived = true
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
            return true
        }
        if shouldLog {
            logger.info(
                "system_audio_tap_first_buffer_received pinned_output_uid=\(self.lastPinnedOutputUID ?? "unknown", privacy: .public)"
            )
        }
    }

    private func resetDiagnosticsState() {
        watchdogLock.withLock {
            firstBufferReceived = false
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
        }
    }
}
