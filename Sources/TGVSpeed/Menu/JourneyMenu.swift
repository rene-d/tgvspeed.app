import AppKit

/// Construit le sous-menu des arrêts, à l'identique du menu Python :
/// heure réelle, arrêts déjà desservis grisés, badge et infobulle sur les retards.
@MainActor
enum JourneyMenu {
    static func populate(_ menu: NSMenu, with details: TrainDetails,
                         stats: TripStats, alarm: ArrivalAlarm) {
        menu.removeAllItems()
        Handler.shared.details = details
        Handler.shared.alarm = alarm

        guard !details.stops.isEmpty else {
            menu.addItem(disabled("Aucun arrêt annoncé"))
            return
        }

        let next = details.nextStop
        for stop in details.stops {
            // Seul le prochain arrêt a une distance restante exploitable ; elle est
            // portée par l'arrêt précédent, d'où le passage par `details`.
            let remaining = stop.code == next?.code ? details.remainingDistanceToNextStop : nil
            menu.addItem(item(for: stop, remaining: remaining, stats: stats,
                              details: details, alarm: alarm))
            if let alternate = alternate(for: stop) {
                menu.addItem(alternate)
            }
        }
    }

    private static func item(for stop: Stop, remaining: Double?, stats: TripStats,
                             details: TrainDetails, alarm: ArrivalAlarm) -> NSMenuItem {
        let time = stop.realDate.map(Formatters.time) ?? "--:--"
        let item = NSMenuItem(title: "\(time) \(stop.label)", action: nil, keyEquivalent: "")
        // Sans masque explicite, l'item alterné qui suit ne serait pas reconnu.
        item.keyEquivalentModifierMask = []

        var hints: [String] = []

        // Un arrêt déjà desservi reste visible mais n'est plus actionnable.
        if !stop.isDone, let code = stop.code {
            item.representedObject = code
            item.target = Handler.shared
            item.action = #selector(Handler.toggleAlarm(_:))
            item.state = alarm.isSelected(stop, in: details) ? .on : .off
            hints.append("Cocher pour être prévenu \(Int(ArrivalAlarm.leadTime / 60)) min avant l'arrivée")
            hints.append("⌥ pour ouvrir la fiche de l'arrêt")
        }

        if stop.isDelayed {
            let text = stop.delayMinutes.map { "retard : \($0) min" } ?? "retard"
            item.badge = NSMenuItemBadge(string: text)
            if let reason = stop.delayReason { hints.insert(reason, at: 0) }
        }

        // L'ETA calculée localement complète l'horaire annoncé pour le prochain arrêt.
        if let remaining, let eta = stats.eta(inMeters: remaining) {
            hints.insert("\(Formatters.distance(remaining)) — arrivée estimée \(Formatters.time(eta))",
                         at: 0)
        }

        item.toolTip = hints.isEmpty ? nil : hints.joined(separator: "\n")
        return item
    }

    /// Variante affichée touche Option enfoncée : la coche ayant pris le clic simple,
    /// c'est elle qui porte désormais le lien vers la fiche de l'arrêt.
    private static func alternate(for stop: Stop) -> NSMenuItem? {
        guard !stop.isDone, let code = stop.code else { return nil }
        let item = NSMenuItem(title: "Fiche : \(stop.label)",
                              action: #selector(Handler.openStop(_:)), keyEquivalent: "")
        item.target = Handler.shared
        item.representedObject = code
        item.keyEquivalentModifierMask = [.option]
        item.isAlternate = true
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

        var details: TrainDetails?
        var alarm: ArrivalAlarm?

        @objc func openStop(_ sender: NSMenuItem) {
            guard let code = sender.representedObject as? String,
                  let url = URL(string: "https://wifi.sncf/fr/stops/\(code)") else { return }
            NSWorkspace.shared.open(url)
        }

        @objc func toggleAlarm(_ sender: NSMenuItem) {
            guard let code = sender.representedObject as? String,
                  let details, let alarm,
                  let stop = details.stops.first(where: { $0.code == code })
            else { return }
            alarm.toggle(stop, in: details)
        }
    }
}
