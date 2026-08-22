import Foundation

/// Serveur Engine.IO v4 / Socket.IO v4 en long-polling, calqué sur ce que fait
/// le routeur de bord : mêmes cadences, mêmes noms d'événements, même namespace.
/// Le transport websocket n'est volontairement pas annoncé, puisque la rame le refuse.
final class SocketServer: @unchecked Sendable {
    static let namespace = "/router/api/pepita"

    private let simulator: Simulator
    private let queue = DispatchQueue(label: "tgvsim.socket")
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]

    init(simulator: Simulator) {
        self.simulator = simulator
    }

    private final class Session {
        let sid: String
        var connected = false
        var pending: [String] = []
        var nextGPS = Date()
        var nextDevices = Date()
        var nextDetails = Date()
        var nextPing = Date().addingTimeInterval(25)

        init(sid: String) {
            self.sid = sid
        }
    }

    // MARK: - Routage

    /// Traite une requête `/socket.io/`. La réponse peut être différée : c'est
    /// tout le principe du long-polling.
    func handle(method: String, query: [String: String], body: String,
                completion: @escaping (String) -> Void) {
        guard let sid = query["sid"] else {
            completion(handshake())
            return
        }

        lock.lock()
        let session = sessions[sid]
        lock.unlock()

        guard let session else {
            // Erreur Engine.IO 1 : session inconnue, le client doit refaire un handshake.
            completion(#"{"code":1,"message":"Session ID unknown"}"#)
            return
        }

        if method == "POST" {
            handlePost(body, session: session)
            completion("ok")
            return
        }

        poll(session, completion: completion)
    }

    private func handshake() -> String {
        let sid = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).description
        lock.lock()
        sessions[sid] = Session(sid: sid)
        lock.unlock()

        let payload: [String: Any] = [
            "sid": sid,
            "upgrades": [],
            "pingInterval": 25000,
            "pingTimeout": 20000,
            "maxPayload": 1_000_000,
        ]
        return "0" + json(payload)
    }

    private func handlePost(_ body: String, session: Session) {
        for packet in body.split(separator: "\u{1e}").map(String.init) {
            // `40<namespace>,` : connexion au namespace applicatif.
            guard packet.hasPrefix("40") else { continue }
            let requested = packet.dropFirst(2).dropLast()
            guard requested.isEmpty || requested == Self.namespace else { continue }

            lock.lock()
            session.connected = true
            session.pending.append("40\(Self.namespace)," + json(["sid": session.sid]))
            // Le routeur pousse ces quatre événements dès la connexion.
            session.pending.append(event("train_number", [
                "projectId": 1, "trainId": 2116, "boxId": 2, "externalId": Journey.trainId,
            ]))
            session.pending.append(event("bar_attendance", ["isBarQueueEmpty": false]))
            session.pending.append(event("data_consumption", simulator.connectionStatus()))
            session.pending.append(event("trainDetails", simulator.trainDetails()))
            lock.unlock()
        }
    }

    // MARK: - Long-polling

    private func poll(_ session: Session, completion: @escaping (String) -> Void) {
        lock.lock()
        if !session.pending.isEmpty {
            let packets = session.pending
            session.pending = []
            lock.unlock()
            completion(packets.joined(separator: "\u{1e}"))
            return
        }
        let due = min(session.nextGPS, session.nextDevices, session.nextDetails, session.nextPing)
        lock.unlock()

        // On garde la requête ouverte jusqu'au prochain événement dû.
        queue.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow)) { [weak self] in
            guard let self else { return }
            completion(self.dueEvents(for: session).joined(separator: "\u{1e}"))
        }
    }

    private func dueEvents(for session: Session) -> [String] {
        let now = Date()
        var packets: [String] = []

        lock.lock()
        defer { lock.unlock() }

        if now >= session.nextPing {
            packets.append("2")
            session.nextPing = now.addingTimeInterval(25)
        }
        if now >= session.nextGPS {
            packets.append(event("gps", simulator.gps()))
            session.nextGPS = now.addingTimeInterval(1)
        }
        if now >= session.nextDevices {
            packets.append(event("connected_devices", ["devices": simulator.connectionStatistics()["devices"] ?? 0]))
            session.nextDevices = now.addingTimeInterval(4)
        }
        if now >= session.nextDetails {
            packets.append(event("trainDetails", simulator.trainDetails()))
            // `trainProgress` est bien poussé par la rame, mais avec une charge nulle.
            packets.append("42\(Self.namespace),[\"trainProgress\",null]")
            session.nextDetails = now.addingTimeInterval(30)
        }
        return packets
    }

    // MARK: - Encodage

    private func event(_ name: String, _ payload: [String: Any]) -> String {
        let arguments: [Any] = [name, payload]
        let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data()
        return "42\(Self.namespace)," + (String(data: data, encoding: .utf8) ?? "[]")
    }

    private func json(_ payload: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
