import Foundation

/// Un arrêt du trajet simulé : celui du screenshot, Arcachon → Paris-Montparnasse.
struct SimStop {
    let code: String
    let label: String
    let latitude: Double
    let longitude: Double
    /// Heure théorique, en minutes depuis le départ.
    let offsetMinutes: Double
    let delayMinutes: Int
    let delayReason: String?

    var coordinate: (lat: Double, lon: Double) { (latitude, longitude) }
}

enum Journey {
    static let carrier = "INOUI"
    static let number = "8476"
    static let trainId = "883"

    /// Heure de départ affichée : 18:54, comme sur la capture d'origine.
    static let departureHour = 18
    static let departureMinute = 54

    static let stops: [SimStop] = [
        SimStop(code: "FRARC", label: "Arcachon", latitude: 44.6586, longitude: -1.1683,
                offsetMinutes: 0, delayMinutes: 0, delayReason: nil),
        SimStop(code: "FRLTE", label: "La Teste", latitude: 44.6320, longitude: -1.1450,
                offsetMinutes: 4, delayMinutes: 0, delayReason: nil),
        SimStop(code: "FRBIG", label: "Biganos Facture", latitude: 44.6413, longitude: -0.9720,
                offsetMinutes: 24, delayMinutes: 0, delayReason: nil),
        SimStop(code: "FRBOJ", label: "Bordeaux Saint-Jean", latitude: 44.8259, longitude: -0.5563,
                offsetMinutes: 50, delayMinutes: 0, delayReason: nil),
        SimStop(code: "FRANG", label: "Angoulême", latitude: 45.6489, longitude: 0.1626,
                offsetMinutes: 90, delayMinutes: 0, delayReason: nil),
        SimStop(code: "FRSPC", label: "Saint-Pierre-des-Corps", latitude: 47.3856, longitude: 0.7217,
                offsetMinutes: 156, delayMinutes: 12,
                delayReason: "Difficultés d'exploitation en gare de Saint-Pierre-des-Corps"),
        SimStop(code: "FRPMO", label: "Paris - Montparnasse - Hall 1 & 2", latitude: 48.8407, longitude: 2.3200,
                offsetMinutes: 220, delayMinutes: 12,
                delayReason: "Difficultés d'exploitation en gare de Saint-Pierre-des-Corps"),
    ]

    static var totalMinutes: Double { stops.last!.offsetMinutes }

    /// Distance orthodromique en mètres.
    static func distance(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let R = 6_371_000.0
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dp = (b.lat - a.lat) * .pi / 180, dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * R * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Cap initial de a vers b, en degrés.
    static func bearing(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dl = (b.lon - a.lon) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Interpolation linéaire entre deux points (suffisant à l'échelle d'un tronçon).
    static func interpolate(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double),
                            _ t: Double) -> (lat: Double, lon: Double) {
        (a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t)
    }
}
