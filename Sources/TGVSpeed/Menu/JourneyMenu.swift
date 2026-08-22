import AppKit

/// Construit le sous-menu des arrêts, à l'identique du menu Python :
/// heure réelle, arrêts déjà desservis grisés, badge et infobulle sur les retards.
@MainActor
enum JourneyMenu {
    static func populate(_ menu: NSMenu, with details: TrainDetails, stats: TripStats) {
        menu.removeAllItems()

        guard !details.stops.isEmpty else {
            menu.addItem(disabled("Aucun arrêt annoncé"))
            return
        }

        let next = details.nextStop
        for stop in details.stops {
            // Seul le prochain arrêt a une distance restante exploitable ; elle est
            // portée par l'arrêt précédent, d'où le passage par `details`.
            let remaining = stop.code == next?.code ? details.remainingDistanceToNextStop : nil
            menu.addItem(item(for: stop, remaining: remaining, stats: stats))
        }
    }

    private static func item(for stop: Stop, remaining: Double?, stats: TripStats) -> NSMenuItem {
        let time = stop.realDate.map(Formatters.time) ?? "--:--"
        let item = NSMenuItem(title: "\(time) \(stop.label)", action: nil, keyEquivalent: "")

        // Un arrêt déjà desservi reste visible mais n'est plus cliquable.
        if !stop.isDone, let code = stop.code {
            item.representedObject = code
            item.target = Handler.shared
            item.action = #selector(Handler.openStop(_:))
        }

        if stop.isDelayed {
            let text = stop.delayMinutes.map { "retard : \($0) min" } ?? "retard"
            item.badge = NSMenuItemBadge(string: text)
            item.toolTip = stop.delayReason
        }

        // L'ETA calculée localement complète l'horaire annoncé pour le prochain arrêt.
        if let remaining, let eta = stats.eta(inMeters: remaining) {
            let distance = Formatters.distance(remaining)
            item.toolTip = [item.toolTip, "\(distance) — arrivée estimée \(Formatters.time(eta))"]
                .compactMap { $0 }
                .joined(separator: "\n")
        }

        return item
    }

    static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Cible des actions de menu : NSMenuItem exige un objet Objective-C.
    @MainActor
    final class Handler: NSObject {
        static let shared = Handler()

        @objc func openStop(_ sender: NSMenuItem) {
            guard let code = sender.representedObject as? String,
                  let url = URL(string: "https://wifi.sncf/fr/stops/\(code)") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
