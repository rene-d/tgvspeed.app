import Foundation

// MARK: - /router/api/train/gps

struct GPSFix: Decodable, Equatable {
    let success: Bool
    let fix: Int?
    let timestamp: TimeInterval?
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    /// Vitesse en m·s⁻¹ telle que renvoyée par le routeur.
    let speed: Double
    let heading: Double?

    var speedKmh: Double { speed * 3.6 }
    var date: Date? { timestamp.map { Date(timeIntervalSince1970: $0) } }
}

// MARK: - /router/api/train/details

struct TrainDetails: Decodable, Equatable {
    let trainId: String?
    let carrier: String?
    let number: String?
    let stops: [Stop]

    private enum CodingKeys: String, CodingKey {
        case trainId, carrier, number, stops
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Le routeur mélange les types (number tantôt String, tantôt Int) selon les rames.
        trainId = try c.decodeLoose(String.self, forKey: .trainId)
        carrier = try c.decodeLoose(String.self, forKey: .carrier)
        number = try c.decodeLoose(String.self, forKey: .number)
        stops = try c.decodeIfPresent([Stop].self, forKey: .stops) ?? []
    }

    /// Libellé du sous-menu des arrêts, ex. « TGV INOUI 6155 ».
    /// Le champ `carrier` a disparu de l'API : on retombe sur INOUI, seul
    /// transporteur qui expose ce portail.
    var label: String {
        guard let number, !number.isEmpty else {
            return trainId.map { "TGV INOUI \($0)" } ?? "Trajet"
        }
        guard let carrier, !carrier.isEmpty else { return "TGV INOUI \(number)" }
        return carrier.uppercased().hasPrefix("TGV")
            ? "\(carrier) \(number)"
            : "TGV \(carrier) \(number)"
    }

    var origin: Stop? { stops.first }
    var destination: Stop? { stops.last }

    /// Premier arrêt non encore desservi.
    var nextStop: Stop? { stops.first { !$0.isDone } }

    /// `progress` décrit le tronçon qui *part* de l'arrêt, pas celui qui y arrive
    /// (vérifié sur une rame réelle : l'arrêt d'origine porte la progression courante,
    /// et le terminus n'a pas de bloc `progress` du tout).
    var currentLeg: Stop? { stops.last { $0.isDone } }

    /// Distance restante jusqu'au prochain arrêt : elle se lit sur l'arrêt précédent.
    var remainingDistanceToNextStop: Double? {
        guard let distance = currentLeg?.remainingDistance, distance > 0 else { return nil }
        return distance
    }
}

struct Stop: Decodable, Equatable {
    let code: String?
    let label: String
    let realDate: Date?
    let theoricDate: Date?
    let isDelayed: Bool
    let delay: String?
    let delayReason: String?
    /// Progression du tronçon partant de cet arrêt (absente sur le terminus).
    let progressPercentage: Double
    let traveledDistance: Double
    let remainingDistance: Double
    let duration: Double?
    let latitude: Double?
    let longitude: Double?

    /// Un arrêt est considéré desservi dès que la progression vers lui a commencé,
    /// c'est la même heuristique que la version Python.
    var isDone: Bool { progressPercentage != 0 }

    private enum CodingKeys: String, CodingKey {
        case code, label, realDate, theoricDate, isDelayed, delay, delayReason
        case progress, duration, coordinates
    }

    private enum ProgressKeys: String, CodingKey {
        case progressPercentage, traveledDistance, remainingDistance
    }

    private enum CoordinateKeys: String, CodingKey {
        case latitude, longitude
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeLoose(String.self, forKey: .code)
        label = try c.decodeLoose(String.self, forKey: .label) ?? "?"
        realDate = try c.decodeDate(forKey: .realDate)
        theoricDate = try c.decodeDate(forKey: .theoricDate)
        isDelayed = try c.decodeLoose(Bool.self, forKey: .isDelayed) ?? false
        delay = try c.decodeLoose(String.self, forKey: .delay)
        delayReason = try c.decodeLoose(String.self, forKey: .delayReason)
        duration = try c.decodeLoose(Double.self, forKey: .duration)

        if let p = try? c.nestedContainer(keyedBy: ProgressKeys.self, forKey: .progress) {
            progressPercentage = try p.decodeLoose(Double.self, forKey: .progressPercentage) ?? 0
            traveledDistance = try p.decodeLoose(Double.self, forKey: .traveledDistance) ?? 0
            remainingDistance = try p.decodeLoose(Double.self, forKey: .remainingDistance) ?? 0
        } else {
            progressPercentage = 0
            traveledDistance = 0
            remainingDistance = 0
        }

        if let c = try? c.nestedContainer(keyedBy: CoordinateKeys.self, forKey: .coordinates) {
            latitude = try c.decodeLoose(Double.self, forKey: .latitude)
            longitude = try c.decodeLoose(Double.self, forKey: .longitude)
        } else {
            latitude = nil
            longitude = nil
        }
    }

    var delayMinutes: Int? {
        guard isDelayed, let delay, let value = Double(delay) else { return nil }
        return Int(value)
    }
}

// MARK: - Décodage tolérant

/// Le portail n'a pas de schéma stable : un même champ peut arriver en String, Int ou Bool.
/// On accepte les trois plutôt que de faire échouer tout le document.
extension KeyedDecodingContainer {
    func decodeLoose(_ type: String.Type, forKey key: Key) throws -> String? {
        if let v = try? decodeIfPresent(String.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return String(v) }
        if let v = try? decodeIfPresent(Double.self, forKey: key) {
            return v == v.rounded() ? String(Int(v)) : String(v)
        }
        if let v = try? decodeIfPresent(Bool.self, forKey: key) { return v ? "true" : "false" }
        return nil
    }

    func decodeLoose(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        if let v = try? decodeIfPresent(Bool.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v != 0 }
        if let v = try? decodeIfPresent(String.self, forKey: key) {
            return ["true", "1", "yes", "oui"].contains(v.lowercased())
        }
        return nil
    }

    func decodeLoose(_ type: Double.Type, forKey key: Key) throws -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(String.self, forKey: key) { return Double(v) }
        return nil
    }

    /// Les dates arrivent en ISO 8601 avec ou sans fractions de seconde.
    func decodeDate(forKey key: Key) throws -> Date? {
        guard let raw = try decodeLoose(String.self, forKey: key) else { return nil }
        return Formatters.parseISO8601(raw)
    }
}
