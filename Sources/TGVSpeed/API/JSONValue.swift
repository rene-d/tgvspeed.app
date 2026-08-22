import Foundation

/// Valeur JSON quelconque : les endpoints `connection/*` ne sont pas documentés,
/// on les décode donc sans schéma et on les rend en clé/valeur dans le menu.
enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "JSON inattendu")
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary[key]
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let n): n != 0
        case .string(let s): ["true", "1", "yes", "oui"].contains(s.lowercased())
        default: nil
        }
    }

    /// Aplatit l'arbre en couples (chemin, valeur affichable), pour un rendu en menu.
    func flattened(prefix: String = "") -> [(key: String, value: String)] {
        switch self {
        case .object(let dict):
            return dict.sorted { $0.key < $1.key }.flatMap { key, value in
                value.flattened(prefix: prefix.isEmpty ? key : "\(prefix).\(key)")
            }
        case .array(let items):
            if items.isEmpty { return [(prefix, "[]")] }
            return items.enumerated().flatMap { index, value in
                value.flattened(prefix: "\(prefix)[\(index)]")
            }
        default:
            return [(prefix, displayString(forKey: prefix))]
        }
    }

    /// Rendu d'une feuille, avec quelques heuristiques de formatage selon le nom du champ.
    private func displayString(forKey key: String) -> String {
        let leaf = key.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        switch self {
        case .null:
            return "—"
        case .bool(let b):
            return b ? "oui" : "non"
        case .string(let s):
            return s.isEmpty ? "—" : s
        case .number(let n):
            if leaf.contains("data") {
                return Formatters.kilobytes(n)
            }
            if leaf.contains("bytes") || leaf.contains("volume")
                || leaf.contains("download") || leaf.contains("upload")
                || leaf.contains("rx") || leaf.contains("tx") {
                return Formatters.bytes(n)
            }
            if leaf.contains("bandwidth") {
                return Formatters.kilobitrate(n)
            }
            if leaf.contains("bitrate") || leaf.contains("speed") {
                return Formatters.bitrate(n)
            }
            if leaf.contains("latency") || leaf.contains("ping") || leaf.contains("rtt") {
                return String(format: "%.0f ms", n)
            }
            if leaf.contains("uptime") || leaf.contains("duration") || leaf.contains("elapsed") {
                return Formatters.duration(n)
            }
            if leaf.contains("timestamp") || leaf.hasSuffix("date") || leaf.contains("reset") {
                return Formatters.epoch(n)
            }
            if leaf.contains("loss") {
                return String(format: "%.1f %%", n)
            }
            // `quality` vaut 0 à 5 sur les rames observées, pas un pourcentage.
            if leaf.contains("quality") || leaf.contains("level") {
                return n <= 5 ? String(format: "%.0f/5", n) : String(format: "%.0f %%", n)
            }
            if leaf.contains("percent") {
                return String(format: "%.0f %%", n)
            }
            return n == n.rounded() && abs(n) < 1e15
                ? String(Int64(n))
                : String(format: "%.2f", n)
        case .object, .array:
            return ""
        }
    }
}
