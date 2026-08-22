import AppKit

/// Mode `--dump-menu` : construit le menu à partir des API puis l'imprime en texte.
/// Permet de vérifier le rendu sans ouvrir la barre de menus (tests, CI, capture impossible).
enum MenuDump {
    static func run(socketSeconds: Double) {
        var finished = false
        let client = WifiSNCFClient()

        Task { @MainActor in
            defer { finished = true }

            print("endpoint : \(client.baseURL.absoluteString)")
            let icons = ["train", "destination", "map", "gps", "robot_broken"]
            let missing = icons.filter { Assets.image($0) == nil }
            print("icônes   : \(icons.count - missing.count)/\(icons.count) chargées"
                + (missing.isEmpty ? "" : " — manquantes : \(missing.joined(separator: ", "))"))
            print("")

            let stats = TripStats()
            var fix: GPSFix?

            do {
                let (current, _) = try await client.gps()
                stats.record(current)
                fix = current
            } catch {
                print("GPS indisponible : \(error.localizedDescription)")
            }

            let details = try? await client.details()

            if let fix {
                print("Barre de menus :")
                for mode in MenuBarDisplay.allCases {
                    let title = MenuBarTitle.string(mode: mode, fix: fix, details: details, stats: stats)
                    print("  \(mode.title.padding(toLength: 28, withPad: " ", startingAt: 0))"
                        + "« \(title) »")
                }
            }

            let journey = NSMenu()
            if let details {
                JourneyMenu.populate(journey, with: details, stats: stats)
                print("\n\(details.label) ▸")
            } else {
                print("\nTrajet ▸ (indisponible)")
            }
            dump(journey)

            let statsMenu = NSMenu()
            StatsMenu.populate(statsMenu, stats: stats, details: details)
            print("\nStatistiques ▸")
            dump(statsMenu)

            async let status = try? await client.json(.connectionStatus)
            async let statistics = try? await client.json(.connectionStatistics)

            // Le menu Wi-Fi mêle REST et événements socket : sans ces derniers,
            // le dump ne montrerait qu'une partie de ce que voit l'utilisateur.
            let socketEvents = await collectSocketEvents(client: client, seconds: socketSeconds)

            let wifiMenu = NSMenu()
            WiFiMenu.populate(wifiMenu, with: await WiFiSnapshot(
                ssid: nil,
                ssidHint: "Réseau : détection désactivée",
                status: status,
                statistics: statistics,
                socketEvents: socketEvents
            ))
            print("\nWi-Fi ▸")
            dump(wifiMenu)
            print("\n(\(count(wifiMenu)) lignes)")
        }

        // Le travail est isolé sur le MainActor : on fait tourner la boucle
        // principale plutôt que de la bloquer.
        let deadline = Date().addingTimeInterval(15 + socketSeconds)
        while !finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Écoute brièvement le socket pour récupérer les événements sans équivalent REST.
    private static func collectSocketEvents(client: WifiSNCFClient,
                                            seconds: Double) async -> [String: JSONValue] {
        let socket = EngineIOClient(root: client.socketRoot,
                                    namespace: WifiSNCFClient.socketNamespace)
        var events: [String: JSONValue] = [:]
        let deadline = Date().addingTimeInterval(seconds)

        let task = Task {
            for try await event in socket.stream() {
                guard case .message(let name, let payload) = event else { continue }
                guard !["gps", "trainDetails"].contains(name),
                      let value = try? JSONDecoder().decode(JSONValue.self, from: payload),
                      value != .null
                else { continue }
                events[name] = value
            }
        }
        while Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        task.cancel()
        return events
    }

    private static func count(_ menu: NSMenu) -> Int {
        menu.items.reduce(0) { $0 + 1 + ($1.submenu.map(count) ?? 0) }
    }

    private static func dump(_ menu: NSMenu, indent: String = "  ") {
        for item in menu.items {
            if item.isSeparatorItem {
                print("\(indent)---")
                continue
            }
            var line = indent + item.title
            if let badge = item.badge?.stringValue { line += "   [\(badge)]" }
            if item.action == nil { line += "  (inactif)" }
            print(line)
            if let submenu = item.submenu { dump(submenu, indent: indent + "  ") }
        }
    }
}
