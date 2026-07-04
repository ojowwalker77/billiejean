import Darwin
import Foundation
import PlayerBridge
import Testing

@Suite("PlayerBridge protocol")
struct PlayerBridgeProtocolTests {
    @Test("request round-trips for every method")
    func requestRoundTrips() throws {
        let cases: [(PlayerBridgeMethod, JSONValue)] = try [
            (.transportPlay, EmptyParams().bridgeJSONValue()),
            (.transportPause, EmptyParams().bridgeJSONValue()),
            (.transportPlayPause, EmptyParams().bridgeJSONValue()),
            (.transportNext, EmptyParams().bridgeJSONValue()),
            (.transportPrevious, EmptyParams().bridgeJSONValue()),
            (.transportSeek, SeekParams(seconds: 42.5).bridgeJSONValue()),
            (.sourceHold, EmptyParams().bridgeJSONValue()),
            (.sourceRelease, EmptyParams().bridgeJSONValue()),
            (.queueEntries, EmptyParams().bridgeJSONValue()),
            (.queueJump, QueueJumpParams(entryId: "entry-1").bridgeJSONValue()),
            (.queuePlayAlbum, PlayAlbumParams(albumId: "album-1", startIndex: 2).bridgeJSONValue()),
            (.queuePlayPlaylist, PlayPlaylistParams(playlistId: "playlist-1", startIndex: 3).bridgeJSONValue()),
            (.queuePlaySearchResult, PlaySearchResultParams(songId: "song-1").bridgeJSONValue()),
            (.libraryAlbums, EmptyParams().bridgeJSONValue()),
            (.libraryAlbumTracks, AlbumTracksParams(albumId: "album-1").bridgeJSONValue()),
            (.libraryPlaylists, EmptyParams().bridgeJSONValue()),
            (.libraryPlaylistTracks, PlaylistTracksParams(playlistId: "playlist-1").bridgeJSONValue()),
            (.catalogSearch, SearchParams(term: "billie jean", limit: 5).bridgeJSONValue()),
            (.playerState, EmptyParams().bridgeJSONValue()),
        ]

        for (index, item) in cases.enumerated() {
            let request = BridgeRequest(id: index + 1, method: item.0.rawValue, params: item.1)
            let line = try BridgeMessage.request(request).encodedLine()
            let decoded = try BridgeMessage(data: Data(line.dropLast()))
            #expect(decoded == .request(request))
        }
    }

    @Test("responses round-trip")
    func responseRoundTrips() throws {
        let ok = try BridgeResponse(id: 1, result: OKResult())
        let error = BridgeResponse(id: 2, error: "nope")

        #expect(try BridgeMessage(data: Data(BridgeMessage.response(ok).encodedLine().dropLast())) == .response(ok))
        #expect(try BridgeMessage(data: Data(BridgeMessage.response(error).encodedLine().dropLast())) == .response(error))
    }

    @Test("new queue and album results round-trip")
    func queueAndAlbumResultRoundTrips() throws {
        let queueEntries = QueueEntriesResult(entries: [
            PlayerQueueEntry(
                id: "entry-1",
                title: "Billie Jean",
                artist: "Michael Jackson",
                durationSeconds: 294,
                artworkURL: "https://example.com/billie-jean.jpg",
                isCurrent: true
            )
        ])
        let albums = AlbumsResult(albums: [
            PlayerAlbum(
                id: "album-1",
                title: "Thriller",
                artist: "Michael Jackson",
                trackCount: 9,
                artworkURL: "https://example.com/thriller.jpg"
            )
        ])
        let tracks = PlaylistTracksResult(tracks: [
            PlayerTrack(
                id: "track-1",
                title: "Wanna Be Startin' Somethin'",
                artist: "Michael Jackson",
                durationSeconds: 363,
                artworkURL: "https://example.com/startin.jpg",
                index: 0
            )
        ])

        let queueEntriesResponse = try BridgeResponse(id: 10, result: queueEntries)
        let queueJumpResponse = try BridgeResponse(id: 11, result: OKResult())
        let albumsResponse = try BridgeResponse(id: 12, result: albums)
        let albumTracksResponse = try BridgeResponse(id: 13, result: tracks)
        let playAlbumResponse = try BridgeResponse(id: 14, result: OKResult())

        #expect(try roundTripResult(queueEntriesResponse, as: QueueEntriesResult.self) == queueEntries)
        #expect(try roundTripResult(queueJumpResponse, as: OKResult.self) == OKResult())
        #expect(try roundTripResult(albumsResponse, as: AlbumsResult.self) == albums)
        #expect(try roundTripResult(albumTracksResponse, as: PlaylistTracksResult.self) == tracks)
        #expect(try roundTripResult(playAlbumResponse, as: OKResult.self) == OKResult())
    }

    @Test("state event round-trips")
    func stateEventRoundTrips() throws {
        let state = PlayerState(
            isPlaying: true,
            isSourceHeld: false,
            title: "Billie Jean",
            artist: "Michael Jackson",
            durationSeconds: 294,
            positionSeconds: 12.5,
            positionTimestamp: 1_783_000_000,
            artworkURL: "https://example.com/art.jpg",
            queueIndex: 1,
            queueCount: 9
        )
        let event = try BridgeEvent(event: "state", payload: state)
        let decoded = try BridgeMessage(data: Data(BridgeMessage.event(event).encodedLine().dropLast()))
        #expect(decoded == .event(event))
    }
}

private func roundTripResult<Result: Codable & Equatable>(
    _ response: BridgeResponse,
    as resultType: Result.Type
) throws -> Result? {
    guard case .response(let decoded) = try BridgeMessage(data: Data(BridgeMessage.response(response).encodedLine().dropLast())) else {
        Issue.record("Expected response")
        return nil
    }
    return try decoded.result?.decoded(as: resultType)
}

@Suite("PlayerBridge socket")
struct PlayerBridgeSocketTests {
    @Test("echo listener handles response and event push")
    func echoSocket() throws {
        let path = "\(FileManager.default.currentDirectoryPath)/.build/pb-\(UUID().uuidString.prefix(8)).sock"
        let clientFD: Int32
        var listener: EchoListener?

        do {
            let pathListener = try EchoListener(path: path)
            pathListener.start()
            listener = pathListener
            clientFD = try connectSocket(path: path)
        } catch let error as POSIXError where error.code == .EPERM {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            listener = nil
            clientFD = fds[0]
            startEchoServer(fd: fds[1])
        }
        defer {
            close(clientFD)
            listener?.stop()
        }

        let request = try BridgeRequest(
            id: 10,
            method: .transportSeek,
            params: SeekParams(seconds: 7.25)
        )
        try writeAll(BridgeMessage.request(request).encodedLine(), fd: clientFD)

        let responseLine = try readLine(fd: clientFD)
        let eventLine = try readLine(fd: clientFD)

        guard case .response(let response) = try BridgeMessage(data: responseLine) else {
            Issue.record("Expected response")
            return
        }
        guard case .event(let event) = try BridgeMessage(data: eventLine) else {
            Issue.record("Expected event")
            return
        }

        #expect(response.id == request.id)
        #expect(try response.result?.decoded(as: OKResult.self) == OKResult())
        #expect(event.event == "state")
        #expect(try event.payload.decoded(as: PlayerState.self).title == "Echo")
    }
}

private final class EchoListener: @unchecked Sendable {
    private let path: String
    private let fd: Int32
    private let queue = DispatchQueue(label: "PlayerBridgeTests.EchoListener")

    init(path: String) throws {
        self.path = path
        try? FileManager.default.removeItem(atPath: path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        try bindSocket(fd: fd, path: path)
        guard listen(fd, 1) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    func start() {
        queue.async {
            let clientFD = accept(self.fd, nil, nil)
            guard clientFD >= 0 else {
                return
            }
            handleEchoConnection(fd: clientFD)
        }
    }

    func stop() {
        close(fd)
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func startEchoServer(fd: Int32) {
    DispatchQueue(label: "PlayerBridgeTests.SocketPairEcho").async {
        handleEchoConnection(fd: fd)
    }
}

private func handleEchoConnection(fd: Int32) {
    defer { close(fd) }

    do {
        let line = try readLine(fd: fd)
        guard case .request(let request) = try BridgeMessage(data: line) else {
            return
        }

        let response = try BridgeResponse(id: request.id, result: OKResult())
        try writeAll(BridgeMessage.response(response).encodedLine(), fd: fd)

        let state = PlayerState(
            isPlaying: true,
            isSourceHeld: false,
            title: "Echo",
            artist: "Tester",
            durationSeconds: 100,
            positionSeconds: 1,
            positionTimestamp: Date().timeIntervalSince1970,
            artworkURL: nil,
            queueIndex: 0,
            queueCount: 1
        )
        try writeAll(BridgeMessage.event(try BridgeEvent(event: "state", payload: state)).encodedLine(), fd: fd)
    } catch {}
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
            Darwin.bind(fd, $0, length)
        }
    }

    guard result == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

private func connectSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    do {
        try connect(fd: fd, path: path)
        return fd
    } catch {
        close(fd)
        throw error
    }
}

private func connect(fd: Int32, path: String) throws {
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

private func readLine(fd: Int32) throws -> Data {
    var data = Data()
    var byte: UInt8 = 0

    while true {
        let count = Darwin.read(fd, &byte, 1)
        guard count > 0 else {
            throw POSIXError(.EPIPE)
        }
        if byte == 0x0a {
            return data
        }
        data.append(byte)
    }
}

private func writeAll(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return
        }

        var written = 0
        while written < data.count {
            let result = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
            guard result > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            written += result
        }
    }
}
