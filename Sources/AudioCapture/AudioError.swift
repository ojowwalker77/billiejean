import CoreAudio
import Foundation

public enum AudioError: Error, LocalizedError, Sendable {
    case microphonePermissionDenied
    case screenRecordingPermissionDenied
    case noMicrophoneAvailable
    case noOutputDevice
    case audioEngineStartFailed(String)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case invalidTapFormat
    case unsupportedPlatform
    case alreadyRunning
    case notRunning
    case noAudioCaptured
    case storageFailed(String)
    case mixFailed(String)
    case captureRuntimeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied. Enable it in System Settings > Privacy & Security > Microphone."
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission denied."
        case .noMicrophoneAvailable:
            return "No microphone available."
        case .noOutputDevice:
            return "No output device available."
        case .audioEngineStartFailed(let message):
            return "Audio engine failed to start: \(message)"
        case .tapCreationFailed(let status):
            return "Failed to create system audio tap (error \(status))."
        case .aggregateDeviceCreationFailed(let status):
            return "Failed to create aggregate audio device (error \(status))."
        case .invalidTapFormat:
            return "Invalid audio tap format."
        case .unsupportedPlatform:
            return "Vinylfy requires macOS 14.2 or later."
        case .alreadyRunning:
            return "Audio capture is already running."
        case .notRunning:
            return "Audio capture is not running."
        case .noAudioCaptured:
            return "No audio was captured."
        case .storageFailed(let message):
            return "Failed to store audio: \(message)"
        case .mixFailed(let message):
            return "Failed to mix audio: \(message)"
        case .captureRuntimeFailure(let message):
            return "Capture failed while running: \(message)"
        }
    }
}
