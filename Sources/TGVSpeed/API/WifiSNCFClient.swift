import Foundation

/// Client des API du routeur de bord. Toutes les requêtes échouent vite :
/// hors du train, `wifi.sncf` ne résout pas et on ne veut pas bloquer le polling.
struct WifiSNCFClient: Sendable {
    let baseURL: URL

    /// `TGVSPEED_BASE_URL` permet de pointer le simulateur local.
    static let productionBaseURL = URL(string: "https://wifi.sncf/router/api")!

    init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else if let override = ProcessInfo.processInfo.environment["TGVSPEED_BASE_URL"],
                  let url = URL(string: override) {
            self.baseURL = url
        } else {
            self.baseURL = Self.productionBaseURL
        }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 4.0
        config.waitsForConnectivity = false
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    /// Les routes lues par le portail, relevées dans son bundle et vérifiées à bord.
    ///
    /// Le bundle en expose d'autres — `connection/logout`, `connection/activate/*`,
    /// `connection/modify`, les jetons — qui écrivent : `logout` coupe la session
    /// Wi-Fi. Elles n'ont rien à faire ici.
    ///
    /// `data_consumption` et `connected_devices` n'existent pas en REST (404) : ce
    /// sont uniquement des événements Socket.IO. `bar_attendance`, lui, a bien son
    /// équivalent REST. Répondent 404 également : `connection/registry`,
    /// `bar/meta.json`, `connections/`.
    enum Endpoint: String {
        case gps = "train/gps"
        case details = "train/details"
        case graph = "train/graph"
        case connectionStatus = "connection/status"
        case connectionStatistics = "connection/statistics"
        case barAttendance = "bar/attendance"
        // Contenus du portail, sans intérêt pour l'application : repris seulement
        // par l'export intégral (⌥ sur « Exporter en JSON… »).
        case mediaWordings = "media/wordings"
        case mediaVideos = "media/videos"
        case chatRoom = "chat/room"
    }

    /// Racine du serveur, d'où part `/socket.io/` : l'API REST est sous `/router/api`,
    /// le flux Socket.IO est un cran plus haut.
    var socketRoot: URL {
        var url = baseURL
        while ["api", "router"].contains(url.lastPathComponent) {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    static let socketNamespace = "/router/api/pepita"

    private func url(for endpoint: Endpoint) -> URL {
        baseURL.appendingPathComponent(endpoint.rawValue)
    }

    func fetchRaw(_ endpoint: Endpoint) async throws -> Data {
        let (data, response) = try await session.data(from: url(for: endpoint))
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpStatus(http.statusCode)
        }
        return data
    }

    func fetch<T: Decodable>(_ type: T.Type, from endpoint: Endpoint) async throws -> T {
        let data = try await fetchRaw(endpoint)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.decoding(endpoint: endpoint.rawValue, underlying: error)
        }
    }

    /// Renvoie aussi le document brut : le menu « Statut » l'affiche tel quel,
    /// ce qui reste le moyen le plus sûr de diagnostiquer une rame qui répond autrement.
    func gps() async throws -> (fix: GPSFix, raw: Data) {
        let data = try await fetchRaw(.gps)
        let fix: GPSFix
        do {
            fix = try JSONDecoder().decode(GPSFix.self, from: data)
        } catch {
            throw ClientError.decoding(endpoint: Endpoint.gps.rawValue, underlying: error)
        }
        guard fix.success else { throw ClientError.noFix }
        return (fix, data)
    }

    func details() async throws -> TrainDetails {
        try await fetch(TrainDetails.self, from: .details)
    }

    func json(_ endpoint: Endpoint) async throws -> JSONValue {
        try await fetch(JSONValue.self, from: endpoint)
    }

    /// Lit une ressource sous la racine du serveur, hors de `/router/api` : le
    /// portail et son handshake Socket.IO vivent un cran plus haut. Renvoie le corps
    /// et les en-têtes, dont on tire les empreintes de version.
    func fetchFromRoot(_ path: String) async throws -> (body: Data, headers: [String: String]) {
        guard let url = URL(string: path, relativeTo: socketRoot) else {
            throw ClientError.httpStatus(400)
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { return (data, [:]) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpStatus(http.statusCode)
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                result[key] = value
            }
        }
        return (data, headers)
    }

    enum ClientError: LocalizedError {
        case httpStatus(Int)
        case noFix
        case decoding(endpoint: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                "Réponse HTTP \(code)"
            case .noFix:
                "Pas de position GPS (success = false)"
            case .decoding(let endpoint, let underlying):
                "Réponse illisible sur \(endpoint) : \(underlying)"
            }
        }
    }
}
