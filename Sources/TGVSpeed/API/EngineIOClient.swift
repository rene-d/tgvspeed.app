import Foundation

/// Client Engine.IO v4 / Socket.IO v4 en long-polling.
///
/// Le routeur de bord annonce `upgrades:["websocket"]` mais refuse l'upgrade
/// (HTTP 400, `{"code":3}`) : le portail lui-même reste en polling. On implémente
/// donc directement ce transport. Voir `docs/socketio.md`.
final class EngineIOClient: @unchecked Sendable {
    /// Racine du serveur, sans `/socket.io/`.
    let root: URL
    /// Namespace applicatif, ex. `/router/api/pepita`.
    let namespace: String

    enum Event: Sendable {
        /// Le namespace a accepté la connexion.
        case connected
        /// Un événement applicatif et sa charge utile JSON brute.
        case message(name: String, payload: Data)
    }

    enum ClientError: LocalizedError {
        case badHandshake
        case closedByServer
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .badHandshake: "Handshake Engine.IO illisible"
            case .closedByServer: "Session fermée par le serveur"
            case .httpStatus(let code): "Réponse HTTP \(code)"
            }
        }
    }

    private let session: URLSession
    /// Compteur du paramètre `t`, que le protocole impose unique par requête.
    private let counter = Counter()

    init(root: URL, namespace: String) {
        self.root = root
        self.namespace = namespace

        let config = URLSessionConfiguration.ephemeral
        // Une lecture reste ouverte jusqu'au prochain événement : il faut donc
        // laisser passer `pingInterval` + `pingTimeout` avant de renoncer.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.allowsCellularAccess = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: config)
    }

    /// Ouvre une session et diffuse ses événements jusqu'à rupture ou annulation.
    func stream() -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Boucle de session

    private func run(_ continuation: AsyncThrowingStream<Event, Error>.Continuation) async throws {
        let handshake = try await handshake()
        try await post("40\(namespace),", sid: handshake.sid)

        while !Task.isCancelled {
            let body = try await poll(sid: handshake.sid)
            for packet in Self.split(body) {
                try await handle(packet, sid: handshake.sid, continuation: continuation)
            }
        }
    }

    private func handle(_ packet: String,
                        sid: String,
                        continuation: AsyncThrowingStream<Event, Error>.Continuation) async throws {
        switch packet.first {
        case "1":
            // CLOSE : le serveur met fin à la session, il faut refaire un handshake.
            throw ClientError.closedByServer
        case "2":
            // PING : sans PONG, la session tombe au bout de `pingTimeout`.
            try await post("3", sid: sid)
        case "4":
            try handleMessage(packet, continuation: continuation)
        default:
            // OPEN (0), PONG (3), NOOP (6) : rien à faire ici.
            break
        }
    }

    private func handleMessage(_ packet: String,
                               continuation: AsyncThrowingStream<Event, Error>.Continuation) throws {
        // `4` = MESSAGE Engine.IO, puis le type Socket.IO.
        let socketType = packet.dropFirst().first
        var rest = packet.dropFirst(2)

        // Namespace explicite, terminé par une virgule.
        if rest.first == "/" {
            guard let comma = rest.firstIndex(of: ",") else { return }
            let received = String(rest[rest.startIndex..<comma])
            guard received == namespace else { return }
            rest = rest[rest.index(after: comma)...]
        }

        switch socketType {
        case "0":
            continuation.yield(.connected)
        case "4":
            throw ClientError.closedByServer
        case "2":
            // Un éventuel identifiant d'acquittement précède le tableau JSON.
            rest = rest.drop(while: \.isNumber)
            guard let (name, payload) = Self.parseEventArguments(String(rest)) else { return }
            continuation.yield(.message(name: name, payload: payload))
        default:
            break
        }
    }

    /// `["gps",{…}]` → nom de l'événement et charge utile réencodée.
    private static func parseEventArguments(_ json: String) -> (String, Data)? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [Any],
              let name = array.first as? String
        else { return nil }

        let argument = array.count > 1 ? array[1] : NSNull()
        guard let payload = try? JSONSerialization.data(withJSONObject: argument,
                                                        options: [.fragmentsAllowed])
        else { return nil }
        return (name, payload)
    }

    // MARK: - Transport

    private struct Handshake: Decodable {
        let sid: String
        let pingInterval: Double
        let pingTimeout: Double
    }

    private func url(sid: String?) -> URL {
        var components = URLComponents(url: root.appendingPathComponent("socket.io/"),
                                       resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "polling"),
            URLQueryItem(name: "t", value: counter.next()),
        ]
        if let sid { items.append(URLQueryItem(name: "sid", value: sid)) }
        components.queryItems = items
        return components.url!
    }

    private func handshake() async throws -> Handshake {
        let body = try await get(sid: nil)
        // La réponse est le paquet OPEN : `0` suivi du JSON de session.
        guard body.hasPrefix("0"),
              let data = String(body.dropFirst()).data(using: .utf8),
              let handshake = try? JSONDecoder().decode(Handshake.self, from: data)
        else { throw ClientError.badHandshake }
        return handshake
    }

    private func poll(sid: String) async throws -> String {
        try await get(sid: sid)
    }

    private func get(sid: String?) async throws -> String {
        let (data, response) = try await session.data(from: url(sid: sid))
        try Self.check(response)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func post(_ packet: String, sid: String) async throws {
        var request = URLRequest(url: url(sid: sid))
        request.httpMethod = "POST"
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(packet.utf8)
        let (_, response) = try await session.data(for: request)
        try Self.check(response)
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpStatus(http.statusCode)
        }
    }

    /// Une réponse peut contenir plusieurs paquets, séparés par le caractère 0x1E.
    static func split(_ body: String) -> [String] {
        body.split(separator: "\u{1e}").map(String.init).filter { !$0.isEmpty }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return String(Int(Date().timeIntervalSince1970), radix: 36) + String(value, radix: 36)
        }
    }
}
