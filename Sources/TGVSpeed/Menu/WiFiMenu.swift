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

/// Sous-menu Wi-Fi.
///
/// Les documents du routeur mêlent l'information utile et sa plomberie, et se
/// recouvrent largement : `connection/status` et l'événement `data_consumption`
/// portent les mêmes six champs, `connection/statistics` et `connected_devices`
/// comptent tous deux les appareils — avec des valeurs qui divergent.
/// Le menu retient donc une lecture curatée, et relègue le rendu brut dans un
/// sous-menu où il reste utile pour diagnostiquer ou encaisser un changement d'API.
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

        let rows = summary(snapshot)
        menu.addItem(.separator())
        if rows.isEmpty {
            menu.addItem(JourneyMenu.disabled("Aucune donnée de connexion"))
        } else {
            for row in rows {
                menu.addItem(entry(row.label, row.value))
            }
        }

        let technical = technicalMenu(snapshot)
        guard !technical.items.isEmpty else { return }
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Détails techniques", action: nil, keyEquivalent: "")
        item.submenu = technical
        menu.addItem(item)
    }

    // MARK: - Lecture curatée

    /// Les six grandeurs qu'on vient réellement chercher dans ce menu.
    private static func summary(_ snapshot: WiFiSnapshot) -> [(label: String, value: String)] {
        // `connection/status` et `data_consumption` portent les mêmes champs :
        // on prend la première source qui répond.
        let quota = [snapshot.status, snapshot.socketEvents["data_consumption"]]
        var rows: [(String, String)] = []

        if let remaining = number("remaining_data", in: quota) {
            // Le forfait vaut 1 024 000 Ko, que ByteCountFormatter rend en « 1 000 MB » :
            // une part restante est plus parlante que ce total.
            let total = number("consumed_data", in: quota).map { $0 + remaining }
            let share = total.flatMap { $0 > 0 ? remaining / $0 * 100 : nil }
            rows.append((
                "Données restantes",
                share.map { String(format: "%@ · %.0f %%", Formatters.kilobytes(remaining), $0) }
                    ?? Formatters.kilobytes(remaining)
            ))
        }

        if let reset = number("next_reset", in: quota) {
            rows.append(("Remise à zéro", Formatters.epoch(reset)))
        }

        if let quality = number("quality", in: [snapshot.statistics]) {
            rows.append(("Qualité du lien", String(format: "%.0f/5", quality)))
        }

        // Deux sources concurrentes pour la même grandeur : le socket est le plus frais.
        if let devices = number("devices", in: [snapshot.socketEvents["connected_devices"],
                                                snapshot.statistics]) {
            rows.append(("Appareils connectés", String(format: "%.0f", devices)))
        }

        if let empty = snapshot.socketEvents["bar_attendance"]?["isBarQueueEmpty"]?.boolValue {
            rows.append(("File du bar", empty ? "vide" : "occupée"))
        }

        return rows
    }

    private static func number(_ key: String, in sources: [JSONValue?]) -> Double? {
        sources.lazy.compactMap { $0?[key]?.doubleValue }.first
    }

    // MARK: - Rendu brut

    private static func technicalMenu(_ snapshot: WiFiSnapshot) -> NSMenu {
        let menu = NSMenu()
        section(menu, title: "Connexion", value: snapshot.status)
        section(menu, title: "Qualité", value: snapshot.statistics)
        for name in snapshot.socketEvents.keys.sorted() {
            section(menu, title: sectionTitle(for: name), value: snapshot.socketEvents[name])
        }
        return menu
    }

    /// Une section = un intitulé grisé suivi des couples clé/valeur du document JSON.
    private static func section(_ menu: NSMenu, title: String, value: JSONValue?) {
        guard let value else { return }
        let rows = value.flattened()
        guard !rows.isEmpty else { return }

        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(header(title))

        for row in rows {
            let item = entry(humanize(row.key), row.value)
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

    // MARK: - Items

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

    private static func entry(_ label: String, _ value: String) -> NSMenuItem {
        let item = JourneyMenu.disabled(label)
        item.badge = NSMenuItemBadge(string: value)
        return item
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
