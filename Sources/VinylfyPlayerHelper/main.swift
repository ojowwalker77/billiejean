import AppKit
import Dispatch
import Foundation
import MusicKit
import OSLog

let spikeLog = OSLog(subsystem: "com.jow.billiejean.player", category: "VinylfyPlayerHelper")

func emit(_ line: String, type: OSLogType = .info) {
    print(line)
    fflush(stdout)
    os_log("%{public}@", log: spikeLog, type: type, line)
}

func emitError(_ error: any Error) {
    emit("SPIKE-ERROR: \(error.localizedDescription) | raw: \(String(describing: error))", type: .error)
}

func emitSpikeError(_ message: String) {
    emit("SPIKE-ERROR: \(message)", type: .error)
}

@available(macOS 15.0, *)
@MainActor
private final class PlayerHelperAppDelegate: NSObject, NSApplicationDelegate {
    private let core = PlayerCore()
    private lazy var server = BridgeServer(core: core)
    private var startupTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        startupTask = Task { [weak self] in
            await self?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        server.stop()
        core.stop()
        emit("PLAYER: stopped")
    }

    func stopAndTerminate() {
        startupTask?.cancel()
        server.stop()
        core.stop()
        emit("PLAYER: stopped by SIGTERM")
        NSApplication.shared.terminate(nil)
    }

    private func start() async {
        emit("PLAYER: requesting Apple Music authorization")

        let status = await MusicAuthorization.request()
        emit("PLAYER: authorization \(status.description)")

        guard status == .authorized else {
            emitSpikeError("Apple Music authorization status is \(status.description)")
            return
        }

        core.stateDidChange = { [weak server] state in
            server?.broadcast(state: state)
        }
        core.startObservation()

        do {
            try server.start()
            emit("PLAYER: bridge listening at \(server.socketURL.path)")
        } catch {
            emitError(error)
            return
        }

        if ProcessInfo.processInfo.arguments.contains("--demo") {
            await runDemo()
        }
    }

    private func runDemo() async {
        do {
            let song = try await core.searchFirstSong(
                term: "Billie Jean Michael Jackson",
                limit: 1
            ).songs.first

            guard let song else {
                emitSpikeError("No Apple Music song found for demo")
                return
            }

            emit("PLAYER: demo queueing \(song.title) — \(song.artist)")
            try await core.playSearchResult(songId: song.id)
            emit("PLAYER: demo play requested")
        } catch {
            emitError(error)
        }
    }
}

private var signalSource: DispatchSourceSignal?

@available(macOS 15.0, *)
@MainActor
private func installSignalHandler(appDelegate: PlayerHelperAppDelegate) {
    signal(SIGTERM, SIG_IGN)

    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
        Task { @MainActor in
            appDelegate.stopAndTerminate()
        }
    }
    source.resume()
    signalSource = source
}

NSApplication.shared.setActivationPolicy(.accessory)

if #available(macOS 15.0, *) {
    let appDelegate = PlayerHelperAppDelegate()
    installSignalHandler(appDelegate: appDelegate)
    NSApplication.shared.delegate = appDelegate
    NSApplication.shared.run()
} else {
    emitSpikeError("macOS 15.0 or newer is required")
    exit(0)
}
