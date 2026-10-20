import Foundation

/// Source des données à bord des avions Air France équipés Starlink (`AirFranceWIFI`).
///
/// Le routeur n'expose qu'un diagnostic de l'antenne, sans vitesse ni cap : on les
/// déduit de deux positions successives. Le document ne porte pas d'horodatage
/// absolu ; `lastUpdateRelativeNs` donne l'âge de la mesure, d'où sa date.
///
/// Les informations de vol (numéro, origine, destination) sont sur un autre service,
/// `freewifi.airfrance.com/ach/api/flightdata`, pas encore exploité.
@MainActor
final class PlaneFeed {
    static let ssid = "AirFranceWIFI"

    /// `TGVSPEED_PLANE_URL` permet de pointer le simulateur local.
    let url: URL = {
        if let override = ProcessInfo.processInfo.environment["TGVSPEED_PLANE_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://wifi.airfrance.com/starlinkrouter/diagnostics")!
    }()

    var onFix: ((GPSFix, Data) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Garde-fou optionnel : renvoyer `false` suspend toute requête réseau.
    var shouldConnect: (() -> Bool)?

    private let onlineInterval: Duration = .seconds(2)
    private let offlineInterval: Duration = .seconds(20)
    /// Fenêtre sur laquelle la vitesse est calculée : la position n'est pas
    /// rafraîchie à chaque requête, et un intervalle trop court amplifie le bruit.
    private let speedWindow: TimeInterval = 30

    private struct Sample {
        let date: Date
        let latitude: Double
        let longitude: Double
    }

    private var samples: [Sample] = []
    private var lastSpeed: Double = 0
    private var lastHeading: Double?
    private var isOnline = false
    private var task: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 5.0
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    func start() {
        task = Task { [weak self] in await self?.loop() }
    }

    deinit {
        task?.cancel()
    }

    private func loop() async {
        while !Task.isCancelled {
            if shouldConnect?() ?? true {
                do {
                    let (fix, raw) = try await fetch()
                    isOnline = true
                    onFix?(fix, raw)
                } catch {
                    isOnline = false
                    samples.removeAll()
                    onFailure?(error.localizedDescription)
                }
            } else {
                isOnline = false
            }
            try? await Task.sleep(for: isOnline ? onlineInterval : offlineInterval)
        }
    }

    private func fetch() async throws -> (GPSFix, Data) {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WifiSNCFClient.ClientError.httpStatus(http.statusCode)
        }
        let document = try JSONDecoder().decode(JSONValue.self, from: data)
        // Le portail lit aussi `locationReponse` (sic) : on suit sa tolérance.
        let dish = document["dish"]
        guard let location = dish?["locationReponse"] ?? dish?["location"],
              let latitude = location["latitude"]?.doubleValue,
              let longitude = location["longitude"]?.doubleValue
        else { throw WifiSNCFClient.ClientError.noFix }

        let age = (dish?["lastUpdateRelativeNs"]?.doubleValue).map { $0 / 1e9 } ?? 0
        let date = Date().addingTimeInterval(-min(max(age, 0), 60))
        record(Sample(date: date, latitude: latitude, longitude: longitude))

        let fix = GPSFix(success: true, fix: nil,
                         timestamp: date.timeIntervalSince1970,
                         latitude: latitude, longitude: longitude,
                         altitude: location["altitudeMeters"]?.doubleValue,
                         speed: lastSpeed, heading: lastHeading)
        return (fix, data)
    }

    /// Retient les positions distinctes et recalcule vitesse et cap sur la fenêtre.
    private func record(_ sample: Sample) {
        if let last = samples.last,
           last.latitude == sample.latitude, last.longitude == sample.longitude {
            return  // position pas encore rafraîchie : on garde la vitesse connue
        }
        samples.append(sample)
        samples.removeAll { sample.date.timeIntervalSince($0.date) > speedWindow }

        guard let first = samples.first, samples.count >= 2 else { return }
        let dt = sample.date.timeIntervalSince(first.date)
        guard dt > 0.5 else { return }
        lastSpeed = Self.distance(first, sample) / dt
        lastHeading = Self.bearing(first, sample)
    }

    private static func distance(_ a: Sample, _ b: Sample) -> Double {
        let earthRadius = 6_371_000.0
        let phi1 = a.latitude * .pi / 180, phi2 = b.latitude * .pi / 180
        let dPhi = (b.latitude - a.latitude) * .pi / 180
        let dLambda = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * earthRadius * atan2(sqrt(h), sqrt(1 - h))
    }

    private static func bearing(_ a: Sample, _ b: Sample) -> Double {
        let phi1 = a.latitude * .pi / 180, phi2 = b.latitude * .pi / 180
        let dLambda = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
