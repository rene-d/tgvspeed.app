import AppKit

/// Pilote l'élément de barre de menus : polling des API, titre, et construction du menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client: WifiSNCFClient
    private let stats = TripStats()
    private let wifi = WiFiSSID()
    private let prefs = Preferences.shared

    // Cadences : rapide à bord, lente hors du train pour ne pas réveiller le réseau
    // toutes les deux secondes pour rien.
    private let onlineGPSInterval: Duration = .seconds(2)
    private let offlineGPSInterval: Duration = .seconds(20)
    private let detailsInterval: Duration = .seconds(30)
    /// Tant qu'on n'a pas le trajet, on réessaie vite : c'est lui qui nomme le menu.
    private let detailsRetryInterval: Duration = .seconds(5)

    private var gps: GPSFix?
    private var details: TrainDetails?
    private var detailsSignature: String?
    private var lastError: String?
    private var lastRawGPS: Data?

    private var tasks: [Task<Void, Never>] = []

    // Items conservés pour être mis à jour sans reconstruire tout le menu.
    private let menuVoyage = NSMenuItem(title: "Voyage", action: nil, keyEquivalent: "")
    private let menuJourney = NSMenuItem(title: "Trajet", action: nil, keyEquivalent: "")
    private let menuCarte = NSMenuItem(title: "Carte (Google)", action: nil, keyEquivalent: "")
    private let menuWiFi = NSMenuItem(title: "Wi-Fi", action: nil, keyEquivalent: "")
    private let menuStats = NSMenuItem(title: "Statistiques", action: nil, keyEquivalent: "")
    private let menuDisplay = NSMenuItem(title: "Affichage", action: nil, keyEquivalent: "")

    private let journeySubmenu = NSMenu()
    private let wifiSubmenu = NSMenu()
    private let statsSubmenu = NSMenu()
    private let displaySubmenu = NSMenu()

    var isOnline: Bool { gps != nil }

    init(client: WifiSNCFClient = WifiSNCFClient()) {
        self.client = client
        super.init()
        buildMenu()
        updateTitle()
        startPolling()
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        menuVoyage.image = Assets.train
        menuVoyage.target = self
        menuVoyage.action = #selector(openJourney)

        menuJourney.image = Assets.destination
        menuJourney.submenu = journeySubmenu

        menuCarte.image = Assets.map
        menuCarte.target = self
        menuCarte.action = #selector(openMap)

        menuWiFi.submenu = wifiSubmenu
        menuStats.submenu = statsSubmenu
        menuDisplay.submenu = displaySubmenu

        menu.addItem(menuVoyage)
        menu.addItem(menuJourney)
        menu.addItem(menuCarte)
        menu.addItem(.separator())
        menu.addItem(menuWiFi)
        menu.addItem(menuStats)
        menu.addItem(menuDisplay)
        menu.addItem(.separator())

        let statut = NSMenuItem(title: "Statut", action: #selector(showStatus), keyEquivalent: "")
        statut.target = self
        menu.addItem(statut)

        let aide = NSMenuItem(title: "Aide", action: #selector(openHelp), keyEquivalent: "")
        aide.target = self
        menu.addItem(aide)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        journeySubmenu.addItem(JourneyMenu.disabled("En attente du trajet…"))
    }

    /// Le menu est reconstruit à l'ouverture : c'est le seul moment où il est regardé.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menuVoyage.isEnabled = isOnline
        menuCarte.isEnabled = isOnline
        menuJourney.isEnabled = details != nil
        StatsMenu.populate(statsSubmenu, stats: stats, details: details)
        buildDisplayMenu()
        refreshWiFi()
    }

    private func buildDisplayMenu() {
        displaySubmenu.removeAllItems()
        displaySubmenu.autoenablesItems = false

        displaySubmenu.addItem(JourneyMenu.disabled("Barre de menus"))
        for mode in MenuBarDisplay.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(setDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = prefs.display == mode ? .on : .off
            displaySubmenu.addItem(item)
        }

        displaySubmenu.addItem(.separator())
        displaySubmenu.addItem(JourneyMenu.disabled("Unité"))
        for unit in SpeedUnit.allCases {
            let item = NSMenuItem(title: unit.title, action: #selector(setUnit(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = unit.rawValue
            item.state = prefs.unit == unit ? .on : .off
            displaySubmenu.addItem(item)
        }

        displaySubmenu.addItem(.separator())
        let template = NSMenuItem(title: "Icône monochrome", action: #selector(toggleTemplateIcon), keyEquivalent: "")
        template.target = self
        template.state = prefs.templateIcon ? .on : .off
        displaySubmenu.addItem(template)

        let ssid = NSMenuItem(title: "Afficher le réseau Wi-Fi", action: #selector(toggleSSID), keyEquivalent: "")
        ssid.target = self
        ssid.state = prefs.ssidDetection ? .on : .off
        ssid.toolTip = "Nécessite l'autorisation Localisation de macOS pour lire le nom du réseau."
        displaySubmenu.addItem(ssid)
    }

    // MARK: - Polling

    private func startPolling() {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tickGPS()
                try? await Task.sleep(for: self.isOnline ? self.onlineGPSInterval : self.offlineGPSInterval)
            }
        })

        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tickDetails()
                let interval = self.details == nil ? self.detailsRetryInterval : self.detailsInterval
                try? await Task.sleep(for: interval)
            }
        })
    }

    private func tickGPS() async {
        // Si l'utilisateur a activé la détection du SSID, on évite même la requête
        // quand on sait qu'on n'est pas sur le réseau du train.
        if wifi.isOnTrainNetwork == false {
            setGPS(nil, error: "Réseau Wi-Fi \(wifi.current ?? "inconnu") — hors du train")
            return
        }

        do {
            let (fix, raw) = try await client.gps()
            lastRawGPS = raw
            setGPS(fix, error: nil)
        } catch {
            setGPS(nil, error: error.localizedDescription)
        }
    }

    private func tickDetails() async {
        guard isOnline else {
            setDetails(nil)
            return
        }
        setDetails(try? await client.details())
    }

    private func setGPS(_ fix: GPSFix?, error: String?) {
        lastError = error
        gps = fix
        if let fix { stats.record(fix) }
        updateTitle()
    }

    private func setDetails(_ new: TrainDetails?) {
        guard signature(of: new) != detailsSignature else { return }
        detailsSignature = signature(of: new)
        details = new

        if let new {
            menuJourney.title = new.label
            JourneyMenu.populate(journeySubmenu, with: new, stats: stats)
        } else {
            menuJourney.title = "Trajet"
            journeySubmenu.removeAllItems()
            journeySubmenu.addItem(JourneyMenu.disabled("En attente du trajet…"))
        }
        updateTitle()
    }

    /// La progression change en continu ; on ne reconstruit le menu que si la
    /// composition du trajet ou un retard bouge réellement.
    private func signature(of details: TrainDetails?) -> String? {
        guard let details else { return nil }
        let stops = details.stops.map {
            "\($0.code ?? "")|\($0.label)|\($0.realDate?.timeIntervalSince1970 ?? 0)|\($0.isDelayed)|\($0.delay ?? "")|\($0.isDone)"
        }
        return ([details.label] + stops).joined(separator: "\n")
    }

    // MARK: - Titre

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        button.image = Assets.menuBarIcon(template: prefs.templateIcon || !isOnline)
        button.imagePosition = .imageLeading

        guard let gps else {
            button.attributedTitle = NSAttributedString(string: "")
            button.appearsDisabled = true
            button.toolTip = lastError.map { "Hors du réseau du train\n\($0)" } ?? "Hors du réseau du train"
            return
        }

        button.appearsDisabled = false
        button.toolTip = details.map { "\($0.label) — \($0.destination?.label ?? "")" }
        button.attributedTitle = attributed(title(for: gps))
    }

    private func title(for gps: GPSFix) -> String {
        MenuBarTitle.string(mode: prefs.display, fix: gps, details: details, stats: stats)
    }

    /// Chiffres à chasse fixe : sinon le titre tremble à chaque rafraîchissement.
    private func attributed(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ])
    }

    // MARK: - Wi-Fi

    private func refreshWiFi() {
        WiFiMenu.populate(wifiSubmenu, with: WiFiSnapshot(
            ssid: wifi.current,
            ssidHint: ssidHint(),
            error: isOnline ? nil : "Hors du réseau du train"
        ))

        guard isOnline else { return }

        Task { [weak self] in
            guard let self else { return }
            async let status = try? await client.json(.connectionStatus)
            async let statistics = try? await client.json(.connectionStatistics)

            let snapshot = await WiFiSnapshot(
                ssid: self.wifi.current,
                ssidHint: self.ssidHint(),
                status: status,
                statistics: statistics
            )
            WiFiMenu.populate(self.wifiSubmenu, with: snapshot)
        }
    }

    private func ssidHint() -> String? {
        guard prefs.ssidDetection else { return "Réseau : détection désactivée" }
        return wifi.isAuthorized ? nil : "Réseau : autorisation Localisation refusée"
    }

    // MARK: - Actions

    @objc private func openJourney() {
        NSWorkspace.shared.open(URL(string: "https://wifi.sncf/fr/journey")!)
    }

    @objc private func openMap() {
        guard let gps else { return }
        let url = "https://maps.google.com/maps?ll=\(gps.latitude),\(gps.longitude)"
            + "&q=\(gps.latitude),\(gps.longitude)&hl=fr&t=m&z=15"
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/rene-d/tgvspeed.app")!)
    }

    @objc private func showStatus() {
        let alert = NSAlert()
        if let gps {
            alert.messageText = "GPS — \(prefs.unit.format(metersPerSecond: gps.speed))"
            alert.informativeText = [
                lastRawGPS.flatMap(prettyJSON) ?? "—",
                "",
                "endpoint : \(client.baseURL.absoluteString)",
            ].joined(separator: "\n")
            alert.icon = Assets.gps
        } else {
            alert.messageText = "Hors du réseau du train"
            alert.informativeText = lastError ?? "Aucune réponse de wifi.sncf"
            alert.icon = Assets.robotBroken
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copier")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(alert.informativeText, forType: .string)
        }
    }

    /// Le document GPS tel que renvoyé par le routeur, réindenté.
    private func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys])
        else { return String(data: data, encoding: .utf8) }
        return String(data: pretty, encoding: .utf8)
    }

    @objc private func setDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = MenuBarDisplay(rawValue: raw) else { return }
        prefs.display = mode
        updateTitle()
    }

    @objc private func setUnit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let unit = SpeedUnit(rawValue: raw) else { return }
        prefs.unit = unit
        updateTitle()
    }

    @objc private func toggleTemplateIcon() {
        prefs.templateIcon.toggle()
        updateTitle()
    }

    @objc private func toggleSSID() {
        prefs.ssidDetection.toggle()
        // La première activation déclenche la demande d'autorisation macOS.
        if prefs.ssidDetection, !wifi.isAuthorized {
            wifi.requestAuthorization { [weak self] in self?.refreshWiFi() }
        }
        refreshWiFi()
    }
}
