import Foundation

/// Rejoue un trajet complet : position, vitesse et progression évoluent dans le temps,
/// de sorte que toute l'interface (arrêts desservis, ETA, stats) puisse être testée au bureau.
final class Simulator: @unchecked Sendable {
    /// Instant de départ simulé du train (t = 0 du trajet).
    private let departure: Date
    /// Accélération du temps : 1 = temps réel, 30 = un trajet en 7 minutes.
    private let timeScale: Double
    private let startedAt = Date()
    /// Part de la durée d'un tronçon consacrée à l'accélération, puis au freinage.
    private let rampFraction = 0.15
    private let lock = NSLock()
    private var consumedData: Double = 215_087

    init(startMinutes: Double, timeScale: Double) {
        self.timeScale = timeScale
        // On recule l'heure de départ pour démarrer directement en cours de trajet.
        self.departure = Date().addingTimeInterval(-startMinutes * 60)
    }

    /// Minutes écoulées depuis le départ, dans l'échelle de temps simulée.
    private var elapsedMinutes: Double {
        let real = Date().timeIntervalSince(startedAt)
        let base = startedAt.timeIntervalSince(departure)
        return (base + real * timeScale) / 60
    }

    /// Date simulée correspondant à un décalage en minutes depuis le départ.
    private func date(atMinute minute: Double) -> Date {
        Date().addingTimeInterval((minute - elapsedMinutes) * 60 / timeScale)
    }

    // MARK: - Cinématique

    private struct State {
        var legIndex: Int          // tronçon en cours (origine = stops[legIndex])
        var latitude: Double
        var longitude: Double
        var speed: Double          // m·s⁻¹
        var heading: Double
        var traveledOnLeg: Double  // mètres parcourus sur le tronçon courant
        var finished: Bool
    }

    /// Départ retardé après chaque arrêt, pour simuler le temps de stationnement.
    private func dwell(before index: Int) -> Double {
        guard index > 0, index < Journey.stops.count else { return 0 }
        let gap = Journey.stops[index].offsetMinutes - Journey.stops[index - 1].offsetMinutes
        return min(2, gap * 0.25)
    }

    private func state() -> State {
        let t = elapsedMinutes
        let stops = Journey.stops

        if t >= stops.last!.offsetMinutes {
            let last = stops.last!
            return State(legIndex: stops.count - 1, latitude: last.latitude, longitude: last.longitude,
                         speed: 0, heading: 0, traveledOnLeg: 0, finished: true)
        }

        // Tronçon courant : celui dont l'arrivée est encore devant nous.
        let index = max(0, stops.firstIndex { $0.offsetMinutes > t }.map { $0 - 1 } ?? 0)
        let from = stops[index], to = stops[index + 1]
        let departureMinute = from.offsetMinutes + dwell(before: index)
        let duration = to.offsetMinutes - departureMinute
        let legDistance = Journey.distance(from.coordinate, to.coordinate)

        // À quai : le train est à l'arrêt, position figée en gare.
        guard t >= departureMinute, duration > 0 else {
            return State(legIndex: index, latitude: from.latitude, longitude: from.longitude,
                         speed: 0, heading: Journey.bearing(from.coordinate, to.coordinate),
                         traveledOnLeg: 0, finished: false)
        }

        let u = min(1, max(0, (t - departureMinute) / duration))
        let (fraction, speedFactor) = trapezoid(u)
        // Vitesse de croisière telle que l'intégrale du profil couvre exactement le tronçon.
        let cruise = legDistance / (duration * 60 * (1 - rampFraction))
        let position = Journey.interpolate(from.coordinate, to.coordinate, fraction)

        return State(legIndex: index, latitude: position.lat, longitude: position.lon,
                     speed: cruise * speedFactor,
                     heading: Journey.bearing(from.coordinate, to.coordinate),
                     traveledOnLeg: legDistance * fraction, finished: false)
    }

    /// Profil trapézoïdal : accélération, palier, freinage.
    /// Renvoie la fraction de distance parcourue et le facteur de vitesse instantané.
    private func trapezoid(_ u: Double) -> (fraction: Double, speed: Double) {
        let r = rampFraction
        let speed: Double
        let area: Double
        if u < r {
            speed = u / r
            area = u * u / (2 * r)
        } else if u <= 1 - r {
            speed = 1
            area = r / 2 + (u - r)
        } else {
            speed = (1 - u) / r
            area = r / 2 + (1 - 2 * r) + (r / 2 - (1 - u) * (1 - u) / (2 * r))
        }
        return (min(1, area / (1 - r)), speed)
    }

    // MARK: - Documents JSON

    func gps() -> [String: Any] {
        let s = state()
        return [
            "success": true,
            "fix": 10,
            "timestamp": Int(Date().timeIntervalSince1970),
            "latitude": s.latitude,
            "longitude": s.longitude,
            // Relief fictif mais reproductible, pour que le menu affiche une altitude plausible.
            "altitude": 40 + 90 * abs(sin(s.latitude * 1.7)) + 25 * abs(cos(s.longitude * 2.3)),
            "speed": s.speed,
            "heading": s.heading,
        ]
    }

    /// Reproduit le schéma réellement observé à bord : pas de champ `carrier`,
    /// `delay` numérique, coordonnées par arrêt, et surtout un bloc `progress`
    /// qui décrit le tronçon *partant* de l'arrêt — absent sur le terminus.
    func trainDetails() -> [String: Any] {
        let s = state()
        let stops = Journey.stops
        let formatter = ISO8601DateFormatter()

        var payload: [[String: Any]] = []
        for (index, stop) in stops.enumerated() {
            var entry: [String: Any] = [
                "code": stop.code,
                "label": stop.label,
                "coordinates": ["latitude": stop.latitude, "longitude": stop.longitude],
                "theoricDate": formatter.string(from: date(atMinute: stop.offsetMinutes)),
                "realDate": formatter.string(from: date(atMinute: stop.offsetMinutes + Double(stop.delayMinutes))),
                "isDelayed": stop.delayMinutes > 0,
                "delay": stop.delayMinutes,
                "isRemoved": false,
                "isCreated": false,
                "isDiversion": false,
                "duration": index == 0 || index == stops.count - 1 ? 0 : 2,
            ]
            if let reason = stop.delayReason { entry["delayReason"] = reason }

            // Le terminus ne porte aucun tronçon, donc aucun `progress`.
            if index < stops.count - 1 {
                let legDistance = Journey.distance(stop.coordinate, stops[index + 1].coordinate)
                let traveled: Double
                if s.finished || index < s.legIndex {
                    traveled = legDistance
                } else if index == s.legIndex {
                    traveled = s.traveledOnLeg
                } else {
                    traveled = 0
                }
                entry["progress"] = [
                    "progressPercentage": legDistance > 0 ? traveled / legDistance * 100 : 0,
                    "traveledDistance": traveled,
                    "remainingDistance": max(0, legDistance - traveled),
                ]
            }
            payload.append(entry)
        }

        return [
            "number": Journey.number,
            "trainId": Journey.trainId,
            "events": [],
            "onboardServices": ["OCEHP", "OCEWO", "OCEPI", "OCECM"],
            "additionalServices": [:],
            "stationUicCodes": ["departure": "87673350", "arrival": "87391003"],
            "stops": payload,
        ]
    }

    /// Schéma relevé à bord : `connection/status` porte en fait le forfait de données,
    /// exprimé en kilo-octets, et `granted_bandwidth` en kbit/s.
    func connectionStatus() -> [String: Any] {
        lock.lock()
        consumedData += 40
        let consumed = consumedData
        lock.unlock()
        return [
            "active": true,
            "status_code": 200,
            "status_description": "identifier has existing grant",
            "service_class": 5,
            "granted_bandwidth": 100_000,
            "consumed_data": Int(consumed),
            "remaining_data": max(0, 1_024_000 - Int(consumed)),
            "next_reset": Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            "profileId": "AUTO-LOGIN-PROFILE-ID",
        ]
    }

    /// `quality` est une note sur 5, pas un pourcentage.
    func connectionStatistics() -> [String: Any] {
        let s = state()
        return [
            // La qualité se dégrade quand le train roule vite (relais, tunnels).
            "quality": max(1, 5 - Int(s.speed * 3.6 / 90)),
            "devices": 20 + Int(15 * abs(sin(Date().timeIntervalSince(startedAt) / 90))),
        ]
    }
}
