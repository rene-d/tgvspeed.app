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

        if details.stops.isEmpty {
            menu.addItem(disabled("Aucun arrêt annoncé"))
        } else {
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

        menu.addItem(.separator())
        menu.addItem(leadItem(alarm: alarm))
    }

    /// Réglage du délai de prévenance, au pied des arrêts : c'est là qu'on coche
    /// la gare, c'est là qu'on veut changer d'avis sur l'avance.
    private static func leadItem(alarm: ArrivalAlarm) -> NSMenuItem {
        let item = NSMenuItem(title: "Prévenir avant l'arrivée", action: nil, keyEquivalent: "")
        // Le délai effectif, qui peut venir de TGVSPEED_ALARM_LEAD lors d'un essai.
        item.badge = NSMenuItemBadge(string: Formatters.duration(ArrivalAlarm.leadTime))

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for minutes in ArrivalAlarm.leadChoices {
            let choice = NSMenuItem(title: "\(minutes) min",
                                    action: #selector(Handler.setLead(_:)), keyEquivalent: "")
            choice.target = Handler.shared
            choice.representedObject = minutes
            choice.state = alarm.leadMinutes == minutes ? .on : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
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
            hints.append("Cocher pour être prévenu \(Formatters.duration(ArrivalAlarm.leadTime)) avant l'arrivée")
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

        @objc func setLead(_ sender: NSMenuItem) {
            guard let minutes = sender.representedObject as? Int else { return }
            alarm?.leadMinutes = minutes
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
