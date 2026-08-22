import Foundation

/// Statistiques calculées localement à partir du flux GPS : le routeur ne les fournit pas.
@MainActor
final class TripStats {
    private(set) var maxSpeed: Double = 0          // m·s⁻¹
    private(set) var traveledDistance: Double = 0  // mètres, intégrés entre deux fixes
    private(set) var startedAt: Date?
    private(set) var last: GPSFix?

    private var speedIntegral: Double = 0          // ∫ v dt, pour une moyenne pondérée par le temps
    private var elapsed: TimeInterval = 0
    private var lastSampleDate: Date?

    /// Moyenne pondérée par le temps, plus juste qu'une moyenne des échantillons
    /// quand le polling saute (tunnel, perte de Wi-Fi).
    var averageSpeed: Double { elapsed > 0 ? speedIntegral / elapsed : 0 }

    var duration: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    func record(_ fix: GPSFix) {
        let now = fix.date ?? Date()
        defer {
            last = fix
            lastSampleDate = now
        }

        maxSpeed = max(maxSpeed, fix.speed)
        if startedAt == nil { startedAt = now }

        guard let previous = last, let previousDate = lastSampleDate else { return }
        let dt = now.timeIntervalSince(previousDate)
        // Un écart aberrant (rame redémarrée, horloge du routeur qui saute) ne doit pas
        // polluer l'intégration.
        guard dt > 0, dt < 120 else { return }

        elapsed += dt
        speedIntegral += (fix.speed + previous.speed) / 2 * dt
        traveledDistance += Self.haversine(previous, fix)
    }

    func reset() {
        maxSpeed = 0
        traveledDistance = 0
        speedIntegral = 0
        elapsed = 0
        startedAt = nil
        lastSampleDate = nil
        last = nil
    }

    /// Distance orthodromique entre deux fixes, en mètres.
    private static func haversine(_ a: GPSFix, _ b: GPSFix) -> Double {
        let earthRadius = 6_371_000.0
        let phi1 = a.latitude * .pi / 180
        let phi2 = b.latitude * .pi / 180
        let dPhi = (b.latitude - a.latitude) * .pi / 180
        let dLambda = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * earthRadius * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Heure d'arrivée estimée pour une distance restante donnée, à la vitesse courante.
    /// `nil` si le train est à l'arrêt ou si la distance est inconnue.
    func eta(inMeters distance: Double?) -> Date? {
        guard let distance, distance > 0, let speed = last?.speed, speed > 5 else { return nil }
        return Date().addingTimeInterval(distance / speed)
    }
}
