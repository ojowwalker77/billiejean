import AppKit
import Darwin
import Foundation
import PlayerBridge

public final class PlayerHelperClient: @unchecked Sendable {
    public var stateHandler: (@Sendable (PlayerState) -> Void)?
    public var connectionStateHandler: (@Sendable (Bool) -> Void)?

    private let socketURL: URL
    private let callbackQueue: DispatchQueue
    private let ioQueue = DispatchQueue(label: "com.vinylfy.playerhelper.client.io")
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var isConnected = false
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]

    public init(
        socketURL: URL = PlayerBridge.defaultSocketURL(),
        callbackQueue: DispatchQueue = .main
    ) {
        self.socketURL = socketURL
        self.callbackQueue = callbackQueue
        ioQueue.async { [weak self] in
            self?.connectionLoop()
        }
    }

    deinit {
        disconnect()
    }

    public static func launchHelperIfNeeded(bundleURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in }
    }

    @discardableResult
    public func play() async throws -> OKResult {
        try await request(.transportPlay, params: EmptyParams(), as: OKResult.self)
    }

    @discardableResult
    public func pause() async throws -> OKResult {
        try await request(.transportPause, params: EmptyParams(), as: OKResult.self)
    }

    @discardableResult
    public func playPause() async throws -> OKResult {
        try await request(.transportPlayPause, params: EmptyParams(), as: OKResult.self)
    }

    @discardableResult
    public func next() async throws -> OKResult {
        try await request(.transportNext, params: EmptyParams(), as: OKResult.self)
    }

    @discardableResult
    public func previous() async throws -> OKResult {
        try await request(.transportPrevious, params: EmptyParams(), as: OKResult.self)
    }

    @discardableResult
    public func seek(seconds: Double) async throws -> OKResult {
        try await request(.transportSeek, params: SeekParams(seconds: seconds), as: OKResult.self)
    }

    @discardableResult
    public func holdSource() async throws -> OKResult {
        try await request(.sourceHold, params: EmptyParams(), as: OKResult.self)
    }

    @discardableResult
    public func releaseSource() async throws -> OKResult {
        try await request(.sourceRelease, params: EmptyParams(), as: OKResult.self)
    }

    public func queueEntries() async throws -> QueueEntriesResult {
        try await request(.queueEntries, params: EmptyParams(), as: QueueEntriesResult.self)
    }

    @discardableResult
    public func jumpToQueueEntry(entryId: String) async throws -> OKResult {
        try await request(
            .queueJump,
            params: QueueJumpParams(entryId: entryId),
            as: OKResult.self
        )
    }

    @discardableResult
    public func playAlbum(albumId: String, startIndex: Int? = nil) async throws -> OKResult {
        try await request(
            .queuePlayAlbum,
            params: PlayAlbumParams(albumId: albumId, startIndex: startIndex),
            as: OKResult.self
        )
    }

    @discardableResult
    public func playPlaylist(playlistId: String, startIndex: Int? = nil) async throws -> OKResult {
        try await request(
            .queuePlayPlaylist,
            params: PlayPlaylistParams(playlistId: playlistId, startIndex: startIndex),
            as: OKResult.self
        )
    }

    @discardableResult
    public func playSearchResult(songId: String) async throws -> OKResult {
        try await request(
            .queuePlaySearchResult,
            params: PlaySearchResultParams(songId: songId),
            as: OKResult.self
        )
    }

    public func albums() async throws -> AlbumsResult {
        try await request(.libraryAlbums, params: EmptyParams(), as: AlbumsResult.self)
    }

    public func albumTracks(albumId: String) async throws -> PlaylistTracksResult {
        try await request(
            .libraryAlbumTracks,
            params: AlbumTracksParams(albumId: albumId),
            as: PlaylistTracksResult.self
        )
    }

    public func playlists() async throws -> PlaylistsResult {
        try await request(.libraryPlaylists, params: EmptyParams(), as: PlaylistsResult.self)
    }

    public func playlistTracks(playlistId: String) async throws -> PlaylistTracksResult {
        try await request(
            .libraryPlaylistTracks,
            params: PlaylistTracksParams(playlistId: playlistId),
            as: PlaylistTracksResult.self
        )
    }

    public func search(term: String, limit: Int) async throws -> CatalogSearchResult {
        try await request(.catalogSearch, params: SearchParams(term: term, limit: limit), as: CatalogSearchResult.self)
    }

    public func state() async throws -> PlayerState {
        try await request(.playerState, params: EmptyParams(), as: PlayerState.self)
    }

    private func request<Params: Encodable, Result: Decodable>(
        _ method: PlayerBridgeMethod,
        params: Params,
        as resultType: Result.Type
    ) async throws -> Result {
        let id = lock.withLock {
            let value = nextID
            nextID += 1
            return value
        }
        let request = try BridgeRequest(id: id, method: method, params: params)
        let line = try BridgeMessage.request(request).encodedLine()

        let payload = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
            lock.lock()
            pending[id] = continuation
            lock.unlock()

            Task {
                do {
                    try await writeWhenConnected(line)
                } catch {
                    let continuation = takePending(id: id)
                    continuation?.resume(throwing: error)
                }
            }
        }

        return try payload.decoded(as: resultType)
    }

    private func writeWhenConnected(_ line: Data) async throws {
        while true {
            if let activeFD = connectedFD() {
                try writeAll(line, fd: activeFD)
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func connectionLoop() {
        while true {
            if connectedFD() == nil {
                do {
                    let newFD = try connectSocket(path: socketURL.path)
                    setConnected(fd: newFD)
                    readLoop(fd: newFD)
                } catch {
                    Thread.sleep(forTimeInterval: 1.0)
                }
            } else {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private func readLoop(fd activeFD: Int32) {
        var buffer = Data()
        var byte: UInt8 = 0

        while true {
            let count = Darwin.read(activeFD, &byte, 1)
            guard count > 0 else {
                handleDisconnect(fd: activeFD)
                return
            }

            if byte == 0x0a {
                handleLine(buffer)
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }
    }

    private func handleLine(_ line: Data) {
        do {
            switch try BridgeMessage(data: line) {
            case .response(let response):
                guard let continuation = takePending(id: response.id) else {
                    return
                }
                if let error = response.error {
                    continuation.resume(throwing: PlayerBridgeError.serverError(error))
                } else if let result = response.result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: PlayerBridgeError.invalidMessage)
                }
            case .event(let event):
                handle(event: event)
            case .request:
                break
            }
        } catch {
            // Event and response parse failures are intentionally local to the client.
        }
    }

    private func handle(event: BridgeEvent) {
        guard event.event == "state",
              let state = try? event.payload.decoded(as: PlayerState.self) else {
            return
        }

        callbackQueue.async { [stateHandler] in
            stateHandler?(state)
        }
    }

    private func setConnected(fd newFD: Int32) {
        lock.lock()
        fd = newFD
        isConnected = true
        lock.unlock()

        callbackQueue.async { [connectionStateHandler] in
            connectionStateHandler?(true)
        }
    }

    private func handleDisconnect(fd disconnectedFD: Int32) {
        lock.lock()
        if fd == disconnectedFD {
            fd = -1
            isConnected = false
        }
        let continuations = Array(pending.values)
        pending.removeAll()
        lock.unlock()

        Darwin.close(disconnectedFD)
        continuations.forEach {
            $0.resume(throwing: PlayerBridgeError.unexpectedResponse("Player helper disconnected."))
        }

        callbackQueue.async { [connectionStateHandler] in
            connectionStateHandler?(false)
        }
    }

    private func disconnect() {
        lock.lock()
        let oldFD = fd
        fd = -1
        isConnected = false
        let continuations = Array(pending.values)
        pending.removeAll()
        lock.unlock()

        if oldFD >= 0 {
            Darwin.close(oldFD)
        }
        continuations.forEach {
            $0.resume(throwing: PlayerBridgeError.unexpectedResponse("Player helper client closed."))
        }
    }

    private func takePending(id: Int) -> CheckedContinuation<JSONValue, any Error>? {
        lock.withLock {
            pending.removeValue(forKey: id)
        }
    }

    private func connectedFD() -> Int32? {
        lock.withLock {
            isConnected && fd >= 0 ? fd : nil
        }
    }

    private func connectSocket(path: String) throws -> Int32 {
        let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        do {
            try connect(fd: newFD, path: path)
            guard isPeerCurrentUser(fd: newFD) else {
                throw PlayerBridgeError.unexpectedResponse("Player helper peer uid mismatch.")
            }
            return newFD
        } catch {
            Darwin.close(newFD)
            throw error
        }
    }

    private func connect(fd: Int32, path: String) throws {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { buffer in
                path.withCString { source in
                    strncpy(buffer, source, sunPathSize - 1)
                }
            }
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }

        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func isPeerCurrentUser(fd: Int32) -> Bool {
        var euid = uid_t()
        var egid = gid_t()
        guard getpeereid(fd, &euid, &egid) == 0 else {
            return false
        }
        return euid == getuid()
    }

    private func writeAll(_ data: Data, fd activeFD: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var written = 0
            while written < data.count {
                let result = Darwin.write(activeFD, baseAddress.advanced(by: written), data.count - written)
                guard result > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}
