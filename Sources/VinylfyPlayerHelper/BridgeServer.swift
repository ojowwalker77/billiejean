import Darwin
import Foundation
import PlayerBridge

@available(macOS 15.0, *)
final class BridgeServer: @unchecked Sendable {
    let socketURL: URL

    private let core: PlayerCore
    private let acceptQueue = DispatchQueue(label: "com.jow.billiejean.player.bridge.accept")
    private let connectionLock = NSLock()
    private var connections: [Int32: BridgeConnection] = [:]
    private var listenFD: Int32 = -1
    private var isRunning = false

    init(core: PlayerCore, socketURL: URL = PlayerBridge.defaultSocketURL()) {
        self.core = core
        self.socketURL = socketURL
    }

    func start() throws {
        guard !isRunning else {
            return
        }

        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: socketURL)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        do {
            try bindSocket(fd: fd, path: socketURL.path)
            guard listen(fd, SOMAXCONN) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        } catch {
            close(fd)
            throw error
        }

        listenFD = fd
        isRunning = true

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        guard isRunning else {
            return
        }

        isRunning = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(at: socketURL)

        connectionLock.lock()
        let liveConnections = Array(connections.values)
        connections.removeAll()
        connectionLock.unlock()

        liveConnections.forEach { $0.close() }
    }

    func broadcast(state: PlayerState) {
        do {
            let event = try BridgeEvent(event: "state", payload: state)
            let line = try BridgeMessage.event(event).encodedLine()
            connectionLock.lock()
            let liveConnections = Array(connections.values)
            connectionLock.unlock()
            liveConnections.forEach { $0.send(line) }
        } catch {
            emitError(error)
        }
    }

    fileprivate func handle(request: BridgeRequest, from connection: BridgeConnection) {
        Task { @MainActor in
            let response: BridgeResponse
            do {
                response = try await self.route(request)
            } catch {
                emitError(error)
                response = BridgeResponse(id: request.id, error: error.localizedDescription)
            }

            do {
                connection.send(try BridgeMessage.response(response).encodedLine())
            } catch {
                emitError(error)
            }
        }
    }

    fileprivate func remove(connection: BridgeConnection) {
        connectionLock.lock()
        connections[connection.fd] = nil
        connectionLock.unlock()
    }

    @MainActor
    private func route(_ request: BridgeRequest) async throws -> BridgeResponse {
        guard let method = PlayerBridgeMethod(rawValue: request.method) else {
            return BridgeResponse(id: request.id, error: "Unknown method: \(request.method)")
        }

        switch method {
        case .transportPlay:
            _ = try request.params.decoded(as: EmptyParams.self)
            try await core.play()
            return try BridgeResponse(id: request.id, result: OKResult())
        case .transportPause:
            _ = try request.params.decoded(as: EmptyParams.self)
            core.pause()
            return try BridgeResponse(id: request.id, result: OKResult())
        case .transportPlayPause:
            _ = try request.params.decoded(as: EmptyParams.self)
            try await core.playPause()
            return try BridgeResponse(id: request.id, result: OKResult())
        case .transportNext:
            _ = try request.params.decoded(as: EmptyParams.self)
            try await core.next()
            return try BridgeResponse(id: request.id, result: OKResult())
        case .transportPrevious:
            _ = try request.params.decoded(as: EmptyParams.self)
            try await core.previous()
            return try BridgeResponse(id: request.id, result: OKResult())
        case .transportSeek:
            let params = try request.params.decoded(as: SeekParams.self)
            core.seek(seconds: params.seconds)
            return try BridgeResponse(id: request.id, result: OKResult())
        case .sourceHold:
            _ = try request.params.decoded(as: EmptyParams.self)
            core.holdSource()
            return try BridgeResponse(id: request.id, result: OKResult())
        case .sourceRelease:
            _ = try request.params.decoded(as: EmptyParams.self)
            try await core.releaseSource()
            return try BridgeResponse(id: request.id, result: OKResult())
        case .queueEntries:
            _ = try request.params.decoded(as: EmptyParams.self)
            return try BridgeResponse(id: request.id, result: core.queueEntries())
        case .queueJump:
            let params = try request.params.decoded(as: QueueJumpParams.self)
            try await core.jumpToQueueEntry(entryId: params.entryId)
            return try BridgeResponse(id: request.id, result: OKResult())
        case .queuePlayAlbum:
            let params = try request.params.decoded(as: PlayAlbumParams.self)
            try await core.playAlbum(albumId: params.albumId, startIndex: params.startIndex)
            return try BridgeResponse(id: request.id, result: OKResult())
        case .queuePlayPlaylist:
            let params = try request.params.decoded(as: PlayPlaylistParams.self)
            try await core.playPlaylist(playlistId: params.playlistId, startIndex: params.startIndex)
            return try BridgeResponse(id: request.id, result: OKResult())
        case .queuePlaySearchResult:
            let params = try request.params.decoded(as: PlaySearchResultParams.self)
            try await core.playSearchResult(songId: params.songId)
            return try BridgeResponse(id: request.id, result: OKResult())
        case .libraryAlbums:
            _ = try request.params.decoded(as: EmptyParams.self)
            return try BridgeResponse(id: request.id, result: try await core.albums())
        case .libraryAlbumTracks:
            let params = try request.params.decoded(as: AlbumTracksParams.self)
            return try BridgeResponse(id: request.id, result: try await core.albumTracks(albumId: params.albumId))
        case .libraryPlaylists:
            _ = try request.params.decoded(as: EmptyParams.self)
            return try BridgeResponse(id: request.id, result: try await core.playlists())
        case .libraryPlaylistTracks:
            let params = try request.params.decoded(as: PlaylistTracksParams.self)
            return try BridgeResponse(id: request.id, result: try await core.playlistTracks(playlistId: params.playlistId))
        case .catalogSearch:
            let params = try request.params.decoded(as: SearchParams.self)
            return try BridgeResponse(id: request.id, result: try await core.searchFirstSong(term: params.term, limit: params.limit))
        case .playerState:
            _ = try request.params.decoded(as: EmptyParams.self)
            return try BridgeResponse(id: request.id, result: core.currentState())
        }
    }

    private func acceptLoop() {
        while isRunning {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                if isRunning {
                    emitSpikeError("bridge accept failed errno=\(errno)")
                }
                continue
            }

            guard isPeerCurrentUser(fd: clientFD) else {
                emitSpikeError("bridge rejected peer with mismatched uid")
                close(clientFD)
                continue
            }

            let connection = BridgeConnection(fd: clientFD, server: self)
            connectionLock.lock()
            connections[clientFD] = connection
            connectionLock.unlock()
            connection.start()

            Task { @MainActor in
                self.broadcast(state: self.core.currentState())
            }
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

    private func bindSocket(fd: Int32, path: String) throws {
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
                bind(fd, $0, length)
            }
        }

        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}

@available(macOS 15.0, *)
private final class BridgeConnection: @unchecked Sendable {
    let fd: Int32

    private weak var server: BridgeServer?
    private let queue: DispatchQueue
    private let writeLock = NSLock()
    private var isClosed = false

    init(fd: Int32, server: BridgeServer) {
        self.fd = fd
        self.server = server
        self.queue = DispatchQueue(label: "com.jow.billiejean.player.bridge.connection.\(fd)")
    }

    func start() {
        queue.async { [weak self] in
            self?.readLoop()
        }
    }

    func send(_ data: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else {
            return
        }

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var written = 0
            while written < data.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
                guard result > 0 else {
                    isClosed = true
                    Darwin.close(fd)
                    return
                }
                written += result
            }
        }
    }

    func close() {
        writeLock.lock()
        if !isClosed {
            isClosed = true
            Darwin.close(fd)
        }
        writeLock.unlock()
    }

    private func readLoop() {
        var buffer = Data()
        var byte: UInt8 = 0

        while !isClosed {
            let count = Darwin.read(fd, &byte, 1)
            guard count > 0 else {
                closeAndRemove()
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
            guard case .request(let request) = try BridgeMessage(data: line) else {
                return
            }
            server?.handle(request: request, from: self)
        } catch {
            emitError(error)
        }
    }

    private func closeAndRemove() {
        close()
        server?.remove(connection: self)
    }
}
