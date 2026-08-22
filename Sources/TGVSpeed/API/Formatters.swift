import Foundation

enum Formatters {
    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let hourMinute: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    static func parseISO8601(_ string: String) -> Date? {
        iso8601.date(from: string) ?? iso8601Fractional.date(from: string)
    }

    /// Heure locale du Mac, comme dans la version Python (`astimezone(None)`).
    static func time(_ date: Date) -> String {
        hourMinute.string(from: date)
    }

    static func bytes(_ value: Double) -> String {
        byteFormatter.string(fromByteCount: Int64(value))
    }

    /// Le routeur compte les volumes en kilo-octets : `consumed_data` + `remaining_data`
    /// totalisent 1 024 000, soit le forfait de 1 Go.
    static func kilobytes(_ value: Double) -> String {
        bytes(value * 1024)
    }

    /// `granted_bandwidth` vaut 100 000, soit 100 Mbit/s : l'unité est le kbit/s.
    static func kilobitrate(_ value: Double) -> String {
        bitrate(value * 1000)
    }

    static func bitrate(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1f Mbit/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f kbit/s", value / 1_000) }
        return String(format: "%.0f bit/s", value)
    }

    /// Les timestamps du routeur sont tantôt en secondes, tantôt en millisecondes.
    static func epoch(_ value: Double) -> String {
        let seconds = value > 4_000_000_000 ? value / 1000 : value
        let date = Date(timeIntervalSince1970: seconds)
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h) h \(String(format: "%02d", m))" }
        if m > 0 { return "\(m) min" }
        return "\(total) s"
    }

    static func distance(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.1f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }

    /// Cap en points cardinaux, plus lisible qu'un azimut brut.
    static func heading(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSO", "SO", "OSO", "O", "ONO", "NO", "NNO"]
        let index = Int((degrees.truncatingRemainder(dividingBy: 360) / 22.5).rounded()) % 16
        return String(format: "%.0f° %@", degrees, points[index])
    }
}
