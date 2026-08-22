import AppKit

/// Sous-menu « Statistiques » : tout est calculé localement à partir du flux GPS.
@MainActor
enum StatsMenu {
    static func populate(_ menu: NSMenu, stats: TripStats, details: TrainDetails?) {
        menu.removeAllItems()

        guard let fix = stats.last else {
            menu.addItem(JourneyMenu.disabled("Pas encore de position"))
            return
        }

        let unit = Preferences.shared.unit
        add(menu, "Vitesse", unit.format(metersPerSecond: fix.speed))
        add(menu, "Vitesse max", unit.format(metersPerSecond: stats.maxSpeed))
        add(menu, "Vitesse moyenne", unit.format(metersPerSecond: stats.averageSpeed))

        menu.addItem(.separator())
        add(menu, "Distance parcourue", Formatters.distance(stats.traveledDistance))
        add(menu, "Durée de la session", Formatters.duration(stats.duration))

        menu.addItem(.separator())
        if let altitude = fix.altitude {
            add(menu, "Altitude", String(format: "%.0f m", altitude))
        }
        if let heading = fix.heading {
            add(menu, "Cap", Formatters.heading(heading))
        }
        add(menu, "Position", String(format: "%.5f, %.5f", fix.latitude, fix.longitude))

        if let details, let next = details.nextStop {
            menu.addItem(.separator())
            add(menu, "Prochain arrêt", next.label)
            let remaining = details.remainingDistanceToNextStop
            if let remaining {
                add(menu, "Distance restante", Formatters.distance(remaining))
            }
            if let eta = stats.eta(inMeters: remaining) {
                add(menu, "Arrivée estimée", Formatters.time(eta))
            } else if let real = next.realDate {
                add(menu, "Arrivée annoncée", Formatters.time(real))
            }
        }

        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Réinitialiser les statistiques",
                               action: #selector(Handler.reset(_:)), keyEquivalent: "")
        reset.target = Handler.shared
        reset.representedObject = stats
        menu.addItem(reset)
    }

    private static func add(_ menu: NSMenu, _ label: String, _ value: String) {
        let item = JourneyMenu.disabled(label)
        item.badge = NSMenuItemBadge(string: value)
        menu.addItem(item)
    }

    @MainActor
    final class Handler: NSObject {
        static let shared = Handler()

        @objc func reset(_ sender: NSMenuItem) {
            (sender.representedObject as? TripStats)?.reset()
        }
    }
}
