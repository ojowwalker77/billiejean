import Foundation

public enum PlayerBridge {
    /// BILLIEJEAN_SOCKET overrides the bridge path (both helper and client
    /// honor it) so a test helper can run beside the production one.
    public static let defaultSocketPath =
        ProcessInfo.processInfo.environment["BILLIEJEAN_SOCKET"]
        ?? NSString(string: "~/Library/Application Support/billiejean/player.sock").expandingTildeInPath

    public static func defaultSocketURL() -> URL {
        URL(fileURLWithPath: defaultSocketPath)
    }
}

public enum PlayerBridgeError: Error, LocalizedError, Sendable {
    case invalidMessage
    case unexpectedResponse(String)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMessage:
            "The player bridge message was invalid."
        case .unexpectedResponse(let message):
            message
        case .serverError(let message):
            message
        }
    }
}

public enum PlayerBridgeMethod: String, Codable, CaseIterable, Sendable {
    case transportPlay = "transport.play"
    case transportPause = "transport.pause"
    case transportPlayPause = "transport.playPause"
    case transportNext = "transport.next"
    case transportPrevious = "transport.previous"
    case transportSeek = "transport.seek"
    case sourceHold = "source.hold"
    case sourceRelease = "source.release"
    case queueEntries = "queue.entries"
    case queueJump = "queue.jump"
    case queuePlayAlbum = "queue.playAlbum"
    case queuePlayPlaylist = "queue.playPlaylist"
    case queuePlaySearchResult = "queue.playSearchResult"
    case libraryAlbums = "library.albums"
    case libraryAlbumTracks = "library.albumTracks"
    case libraryPlaylists = "library.playlists"
    case libraryPlaylistTracks = "library.playlistTracks"
    case catalogSearch = "catalog.search"
    case playerState = "player.state"
}

public struct BridgeRequest: Codable, Equatable, Sendable {
    public var id: Int
    public var method: String
    public var params: JSONValue

    public init(id: Int, method: String, params: JSONValue = .object([:])) {
        self.id = id
        self.method = method
        self.params = params
    }

    public init<Params: Encodable>(id: Int, method: PlayerBridgeMethod, params: Params) throws {
        self.id = id
        self.method = method.rawValue
        self.params = try JSONValue(params)
    }
}

public struct BridgeResponse: Codable, Equatable, Sendable {
    public var id: Int
    public var result: JSONValue?
    public var error: String?

    public init(id: Int, result: JSONValue) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init<Result: Encodable>(id: Int, result: Result) throws {
        self.id = id
        self.result = try JSONValue(result)
        self.error = nil
    }

    public init(id: Int, error: String) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

public struct BridgeEvent: Codable, Equatable, Sendable {
    public var event: String
    public var payload: JSONValue

    public init(event: String, payload: JSONValue) {
        self.event = event
        self.payload = payload
    }

    public init<Payload: Encodable>(event: String, payload: Payload) throws {
        self.event = event
        self.payload = try JSONValue(payload)
    }
}

public enum BridgeMessage: Equatable, Sendable {
    case request(BridgeRequest)
    case response(BridgeResponse)
    case event(BridgeEvent)
}

public extension BridgeMessage {
    init(data: Data, decoder: JSONDecoder = JSONDecoder()) throws {
        let value = try decoder.decode(JSONValue.self, from: data)
        guard case .object(let object) = value else {
            throw PlayerBridgeError.invalidMessage
        }

        let normalized = try JSONEncoder.bridge.encode(value)
        if object["method"] != nil {
            self = .request(try decoder.decode(BridgeRequest.self, from: normalized))
        } else if object["event"] != nil {
            self = .event(try decoder.decode(BridgeEvent.self, from: normalized))
        } else if object["id"] != nil {
            self = .response(try decoder.decode(BridgeResponse.self, from: normalized))
        } else {
            throw PlayerBridgeError.invalidMessage
        }
    }

    func encodedLine(encoder: JSONEncoder = .bridge) throws -> Data {
        let data: Data
        switch self {
        case .request(let request):
            data = try encoder.encode(request)
        case .response(let response):
            data = try encoder.encode(response)
        case .event(let event):
            data = try encoder.encode(event)
        }

        var line = data
        line.append(0x0a)
        return line
    }
}

public extension Encodable {
    func bridgeJSONValue() throws -> JSONValue {
        try JSONValue(self)
    }
}

public extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var bridge: JSONDecoder {
        JSONDecoder()
    }
}
