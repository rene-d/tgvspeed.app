import AppKit

/// État courant de la connexion, rafraîchi à l'ouverture du menu.
struct WiFiSnapshot {
    var ssid: String?
    var ssidHint: String?
    var status: JSONValue?
    var statistics: JSONValue?
    /// Événements Socket.IO sans équivalent REST : `data_consumption`,
    /// `connected_devices`, `bar_attendance`, `train_number`.
    var socketEvents: [String: JSONValue] = [:]
    var error: String?
}

/// Sous-menu Wi-Fi. Les endpoints `connection/*` n'ayant pas de schéma documenté,
/// on les rend génériquement en clé/valeur : le menu s'adapte à ce que renvoie la rame.
@MainActor
enum WiFiMenu {
    static func populate(_ menu: NSMenu, with snapshot: WiFiSnapshot) {
        menu.removeAllItems()

        menu.addItem(networkItem(snapshot))

        if let error = snapshot.error {
            menu.addItem(.separator())
            let item = JourneyMenu.disabled(error)
            item.toolTip = error
            menu.addItem(item)
            return
        }

        section(menu, title: "Connexion", value: snapshot.status)
        section(menu, title: "Qualité", value: snapshot.statistics)

        // Ce que seul le flux Socket.IO fournit.
        for name in snapshot.socketEvents.keys.sorted() {
            section(menu, title: sectionTitle(for: name), value: snapshot.socketEvents[name])
        }

        if menu.items.count == 1 {
            menu.addItem(.separator())
            menu.addItem(JourneyMenu.disabled("Aucune donnée de connexion"))
        }
    }

    private static func networkItem(_ snapshot: WiFiSnapshot) -> NSMenuItem {
        let title: String
        if let ssid = snapshot.ssid {
            title = "Réseau : \(ssid)"
        } else if let hint = snapshot.ssidHint {
            title = hint
        } else {
            title = "Réseau : inconnu"
        }

        let item = JourneyMenu.disabled(title)
        if let ssid = snapshot.ssid, ssid == WiFiSSID.expectedSSID {
            item.badge = NSMenuItemBadge(string: "à bord")
        }
        return item
    }

    /// Une section = un intitulé grisé suivi des couples clé/valeur du document JSON.
    private static func section(_ menu: NSMenu, title: String, value: JSONValue?) {
        guard let value else { return }
        let rows = value.flattened()
        guard !rows.isEmpty else { return }

        menu.addItem(.separator())
        menu.addItem(header(title))

        for row in rows {
            let item = JourneyMenu.disabled(humanize(row.key))
            item.badge = NSMenuItemBadge(string: row.value)
            item.toolTip = "\(row.key) = \(row.value)"
            menu.addItem(item)
        }
    }

    /// Intitulés lisibles pour les événements socket connus.
    private static func sectionTitle(for event: String) -> String {
        switch event {
        case "data_consumption": "Consommation"
        case "connected_devices": "Appareils"
        case "bar_attendance": "Bar"
        case "train_number": "Rame"
        default: humanize(event)
        }
    }

    private static func header(_ title: String) -> NSMenuItem {
        let item = JourneyMenu.disabled(title)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.menuBarFont(ofSize: NSFont.smallSystemFontSize)]
        )
        return item
    }

    /// `remaining_data` → « Remaining data », `progressPercentage` → « Progress percentage ».
    private static func humanize(_ key: String) -> String {
        let leaf = key.split(separator: ".").last.map(String.init) ?? key
        var words: [String] = []
        var current = ""
        for character in leaf {
            if character == "_" || character == "-" {
                if !current.isEmpty { words.append(current); current = "" }
            } else if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character).lowercased()
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return leaf }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }
}
