import AppKit

/// Rassemble en un seul document tout ce qui se lit sans effet de bord : ce que
/// l'application a en mémoire, les endpoints REST du routeur, les événements
/// Socket.IO, et les empreintes qui datent la version du portail.
///
/// C'est la trace à joindre quand l'API change — le rendu du menu, lui, est filtré.
/// Rien n'est écrit côté routeur : les routes qui modifient l'état (`connection/logout`
/// et consorts) sont volontairement absentes de `WifiSNCFClient.Endpoint`.
enum DiagnosticExport {
    /// Ce que le contrôleur détient déjà et qu'aucune requête ne redonnerait.
    struct Inputs: Sendable {
        var ssid: String?
        var transport: String
        var maxSpeed: Double
        var averageSpeed: Double
        var traveledDistance: Double
        var duration: TimeInterval
        /// Dernier `/train/gps` reçu, utile quand l'export est demandé hors couverture.
        var lastRawGPS: Data?
        var socketEvents: [String: JSONValue]
    }

    /// Toujours repris : les documents qui décrivent le train et la connexion.
    private static let core: [WifiSNCFClient.Endpoint] = [
        .gps, .details, .graph, .connectionStatus, .connectionStatistics, .barAttendance,
    ]

    /// Contenus du portail — libellés, catalogue vidéo, salons de chat. Volumineux et
    /// sans rapport avec la connexion : seulement sur ⌥.
    private static let extras: [WifiSNCFClient.Endpoint] = [
        .mediaWordings, .mediaVideos, .chatRoom,
    ]

    static func build(client: WifiSNCFClient, inputs: Inputs, full: Bool) async -> Data {
        let endpoints = full ? core + extras : core

        var root: [String: JSONValue] = [
            "exportedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "app": .object(context(inputs, baseURL: client.baseURL)),
            "stats": .object([
                "maxSpeed": .number(inputs.maxSpeed),
                "averageSpeed": .number(inputs.averageSpeed),
                "traveledDistance": .number(inputs.traveledDistance),
                "duration": .number(inputs.duration),
            ]),
            "rest": .object(await fetchAll(endpoints, with: client)),
            "socketEvents": .object(inputs.socketEvents),
            "fingerprints": .object(await fingerprints(client: client)),
        ]

        if let raw = inputs.lastRawGPS,
           let value = try? JSONDecoder().decode(JSONValue.self, from: raw) {
            root["lastKnownGPS"] = value
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(root)) ?? Data("{}".utf8)
    }

    // MARK: - Sections

    private static func context(_ inputs: Inputs, baseURL: URL) -> [String: JSONValue] {
        let info = Bundle.main.infoDictionary ?? [:]
        var context: [String: JSONValue] = [
            "version": .string(info["CFBundleShortVersionString"] as? String ?? "?"),
            "build": .string(info["CFBundleVersion"] as? String ?? "?"),
            "system": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "baseURL": .string(baseURL.absoluteString),
            "transport": .string(inputs.transport),
        ]
        if let ssid = inputs.ssid { context["ssid"] = .string(ssid) }
        return context
    }

    /// Un endpoint qui échoue reste dans le document, avec son erreur : savoir ce qui
    /// n'a pas répondu vaut autant que le reste.
    /// Séquentiel à dessein.
    ///
    /// Un `TaskGroup` ne rendait rien ici : l'export tourne sous une boucle
    /// d'exécution pompée à la main (`--export`, et le menu d'un agent sans
    /// fenêtre), où les enfants du groupe n'étaient jamais servis — quand le
    /// processus ne s'effondrait pas. Six requêtes de 2 s au pire, pour un export
    /// déclenché à la main : la concurrence n'apportait rien.
    ///
    /// Un endpoint qui échoue reste dans le document, avec son erreur : savoir ce
    /// qui n'a pas répondu vaut autant que le reste.
    private static func fetchAll(_ endpoints: [WifiSNCFClient.Endpoint],
                                 with client: WifiSNCFClient) async -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for endpoint in endpoints {
            do {
                result[endpoint.rawValue] = try await client.json(endpoint)
            } catch {
                result[endpoint.rawValue] = .object(["error": .string(error.localizedDescription)])
            }
        }
        return result
    }

    /// De quoi dire, six mois plus tard, contre quelle version du portail l'export a
    /// été pris — voir « Savoir si l'API a changé » dans le README.
    private static func fingerprints(client: WifiSNCFClient) async -> [String: JSONValue] {
        var marks: [String: JSONValue] = [:]
        if let handshake = await engineIOHandshake(client: client) {
            marks["engineIO"] = handshake
        }
        for (key, value) in await portalBundles(client: client) { marks[key] = value }
        return marks
    }

    private static func engineIOHandshake(client: WifiSNCFClient) async -> JSONValue? {
        guard let body = try? await client
            .fetchFromRoot("socket.io/?EIO=4&transport=polling").body else { return nil }
        // La réponse est un paquet Engine.IO : le type `0` précède le JSON.
        guard let text = String(data: body, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              case .object(var fields)? = try? JSONDecoder().decode(
                  JSONValue.self, from: Data(text[start...].utf8))
        else { return nil }
        // Le `sid` est une session jetable : il date l'export sans rien dire du portail.
        fields["sid"] = nil
        return .object(fields)
    }

    /// Les noms des bundles du portail sont des hachages de contenu : ils changent à
    /// chaque redéploiement, et c'est le témoin le plus fiable dont on dispose.
    private static func portalBundles(client: WifiSNCFClient) async -> [String: JSONValue] {
        guard let (body, headers) = try? await client.fetchFromRoot("/"),
              let html = String(data: body, encoding: .utf8) else { return [:] }

        var marks: [String: JSONValue] = [:]
        let pattern = "/assets/(?:js|styles)/[0-9a-f]{6}\\.[a-z.]+"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(html.startIndex..., in: html)
            let names = regex.matches(in: html, range: range)
                .compactMap { Range($0.range, in: html).map { String(html[$0]) } }
            if !names.isEmpty {
                marks["portalBundles"] = .array(Array(Set(names)).sorted().map(JSONValue.string))
            }
        }
        if let modified = headers["Last-Modified"] {
            marks["portalLastModified"] = .string(modified)
        }
        return marks
    }
}

// MARK: - Mode non interactif

extension DiagnosticExport {
    /// Mode `--export` : assemble le même document que l'entrée de menu, sans interface.
    ///
    /// C'est ce qui rend l'export vérifiable — `make check` le joue contre le
    /// simulateur, et à bord il évite d'avoir à décrire un clic dans un rapport.
    static func run(socketSeconds: Double, path: String?, full: Bool) {
        var finished = false
        let client = WifiSNCFClient()

        Task { @MainActor in
            defer { finished = true }
            let stats = TripStats()
            var raw: Data?
            if let (fix, data) = try? await client.gps() {
                stats.record(fix)
                raw = data
            }
            let events = await MenuDump.collectSocketEvents(client: client, seconds: socketSeconds)

            let data = await build(client: client, inputs: Inputs(
                ssid: nil,
                transport: events.isEmpty ? "REST (repli)" : "Socket.IO (long-polling)",
                maxSpeed: stats.maxSpeed,
                averageSpeed: stats.averageSpeed,
                traveledDistance: stats.traveledDistance,
                duration: stats.duration,
                lastRawGPS: raw,
                socketEvents: events
            ), full: full)

            guard let path else {
                FileHandle.standardOutput.write(data)
                print("")
                return
            }
            do {
                try data.write(to: URL(fileURLWithPath: path))
                print("\(path) — \(data.count) octets")
            } catch {
                print("écriture impossible : \(error.localizedDescription)")
            }
        }

        let deadline = Date().addingTimeInterval(20 + socketSeconds)
        while !finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
