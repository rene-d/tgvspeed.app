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

    enum Endpoint: String {
        case gps = "train/gps"
        case details = "train/details"
        case connectionStatus = "connection/status"
        case connectionStatistics = "connection/statistics"
        // `data_consumption` et `connected_devices` n'existent pas en REST (404) :
        // ce sont uniquement des événements socket.io. Leurs informations sont
        // de toute façon reprises par `connection/status` et `connection/statistics`.

    }

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
