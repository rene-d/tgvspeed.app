import AppKit

/// Sous-menu du vol, à la place des arrêts du train : le portail Air France ne
/// donne que l'origine, la destination et les temps de vol.
@MainActor
enum FlightMenu {
    static func populate(_ menu: NSMenu, with flight: FlightInfo) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        if let departure = flight.departure {
            menu.addItem(entry("Départ\(flight.origin.map { " de \($0)" } ?? "")",
                               Formatters.time(departure)))
        }
        if let eta = flight.estimatedArrival {
            let item = entry("Arrivée\(flight.destination.map { " à \($0)" } ?? "")",
                             Formatters.time(eta))
            if let scheduled = flight.scheduledArrival {
                let late = eta.timeIntervalSince(scheduled)
                item.toolTip = "Prévue à \(Formatters.time(scheduled))"
                    + (late >= 60 ? ", retard estimé \(Formatters.duration(late))" : "")
            }
            menu.addItem(item)
        }
        if let remaining = flight.remainingTime {
            menu.addItem(entry("Temps restant", Formatters.duration(remaining)))
        }
        if let progress = flight.progress {
            menu.addItem(entry("Progression", String(format: "%.0f %%", progress * 100)))
        }

        let aircraft = [flight.tail.map(registration), flight.aircraftType.map(model)]
            .compactMap { $0 }
        if flight.phase != nil || !aircraft.isEmpty {
            menu.addItem(.separator())
        }
        if let phase = flight.phase {
            menu.addItem(entry("Phase", phaseLabel(phase)))
        }
        if !aircraft.isEmpty {
            menu.addItem(entry("Appareil", aircraft.joined(separator: " · ")))
        }
    }

    private static func entry(_ label: String, _ value: String) -> NSMenuItem {
        let item = JourneyMenu.disabled(label)
        item.badge = NSMenuItemBadge(string: value)
        return item
    }

    /// `FHPNZ` → `F-HPNZ` : les immatriculations françaises ont un préfixe d'une lettre.
    private static func registration(_ tail: String) -> String {
        guard tail.count == 5, tail.hasPrefix("F"), !tail.contains("-") else { return tail }
        return "F-" + tail.dropFirst()
    }

    /// Code de type IATA : seul `223` (A220-300) est vérifié à bord.
    private static func model(_ code: String) -> String {
        switch code {
        case "223": "A220-300"
        case "221": "A220-100"
        case "320": "A320"
        case "32N": "A320neo"
        case "321": "A321"
        case "359": "A350-900"
        case "77W": "777-300ER"
        case "789": "787-9"
        default: code
        }
    }

    private static func phaseLabel(_ phase: String) -> String {
        switch phase.uppercased() {
        case "AIRBORNE": "en vol"
        default: phase.lowercased()
        }
    }
}
