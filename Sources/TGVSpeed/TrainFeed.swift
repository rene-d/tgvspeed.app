import Foundation

/// Source des données du train. Le flux Socket.IO est le mode nominal — il pousse
/// la position à 1 Hz et des événements sans équivalent REST — et le sondage REST
/// prend le relais dès que le socket est muet ou tombe.
@MainActor
final class TrainFeed {
    enum Transport: Equatable {
        case socket
        case rest
        case none

        var label: String {
            switch self {
            case .socket: "Socket.IO (long-polling)"
            case .rest: "REST (repli)"
            case .none: "aucune"
            }
        }
    }

    var onGPS: ((GPSFix, Data) -> Void)?
    var onDetails: ((TrainDetails?) -> Void)?
    var onFailure: ((String) -> Void)?
    var onSocketEvent: ((String, JSONValue) -> Void)?
    var onTransportChange: (() -> Void)?
    /// Garde-fou optionnel : renvoyer `false` suspend toute requête réseau.
    var shouldConnect: (() -> Bool)?

    private(set) var transport: Transport = .none

    private let client: WifiSNCFClient
    private let socket: EngineIOClient

    /// Au-delà de ce silence, on considère le socket perdu et le REST reprend la main.
    private let socketSilenceTolerance: TimeInterval = 8
    private let gpsInterval: Duration = .seconds(2)
    private let offlineInterval: Duration = .seconds(20)
    private let detailsInterval: Duration = .seconds(30)
    private let detailsRetryInterval: Duration = .seconds(5)

    private var lastSocketEvent: Date?
    private var hasDetails = false
    private var isOnline = false
    private var tasks: [Task<Void, Never>] = []

    private var socketIsHealthy: Bool {
        guard let lastSocketEvent else { return false }
        return Date().timeIntervalSince(lastSocketEvent) < socketSilenceTolerance
    }

    init(client: WifiSNCFClient = WifiSNCFClient()) {
        self.client = client
        self.socket = EngineIOClient(root: client.socketRoot,
                                     namespace: WifiSNCFClient.socketNamespace)
    }

    func start() {
        tasks = [
            Task { [weak self] in await self?.socketLoop() },
            Task { [weak self] in await self?.gpsLoop() },
            Task { [weak self] in await self?.detailsLoop() },
        ]
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    // MARK: - Socket.IO

    private func socketLoop() async {
        // Reconnexion espacée progressivement : hors du train, insister ne sert à rien.
        var backoff: Duration = .seconds(2)

        while !Task.isCancelled {
            do {
                guard shouldConnect?() ?? true else { throw CancellationError() }
                for try await event in socket.stream() {
                    backoff = .seconds(2)
                    lastSocketEvent = Date()
                    setTransport(.socket)

                    switch event {
                    case .connected:
                        // `trainDetails` n'arrive que toutes les 30 s : on amorce
                        // le menu tout de suite par un appel REST.
                        if !hasDetails { await fetchDetails() }
                    case .message(let name, let payload):
                        handle(name: name, payload: payload)
                    }
                }
            } catch {
                // Rupture attendue à chaque tunnel : on retentera.
            }

            if socketIsHealthy == false, transport == .socket {
                setTransport(isOnline ? .rest : .none)
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }

    private func handle(name: String, payload: Data) {
        switch name {
        case "gps":
            guard let fix = try? JSONDecoder().decode(GPSFix.self, from: payload) else { return }
            guard fix.success else {
                setOnline(false)
                onFailure?("Pas de position GPS (success = false)")
                return
            }
            setOnline(true)
            onGPS?(fix, payload)

        case "trainDetails":
            guard let details = try? JSONDecoder().decode(TrainDetails.self, from: payload) else { return }
            hasDetails = true
            onDetails?(details)

        default:
            // Les autres événements n'ont pas de schéma stable et sont affichés tels quels.
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: payload),
                  value != .null
            else { return }
            onSocketEvent?(name, value)
        }
    }

    // MARK: - Repli REST

    private func gpsLoop() async {
        while !Task.isCancelled {
            if !socketIsHealthy {
                if shouldConnect?() == false {
                    setOnline(false)
                    setTransport(.none)
                    onFailure?("Réseau Wi-Fi hors du train")
                } else {
                    do {
                        let (fix, raw) = try await client.gps()
                        setOnline(true)
                        setTransport(.rest)
                        onGPS?(fix, raw)
                    } catch {
                        setOnline(false)
                        setTransport(.none)
                        onFailure?(error.localizedDescription)
                    }
                }
            }
            try? await Task.sleep(for: isOnline ? gpsInterval : offlineInterval)
        }
    }

    private func detailsLoop() async {
        while !Task.isCancelled {
            // Le socket pousse `trainDetails` de lui-même : inutile de doubler.
            if !socketIsHealthy, shouldConnect?() ?? true {
                if isOnline {
                    await fetchDetails()
                } else {
                    hasDetails = false
                    onDetails?(nil)
                }
            }
            try? await Task.sleep(for: hasDetails ? detailsInterval : detailsRetryInterval)
        }
    }

    private func fetchDetails() async {
        let details = try? await client.details()
        hasDetails = details != nil
        onDetails?(details)
    }

    // MARK: - État

    private func setOnline(_ value: Bool) {
        isOnline = value
        if !value { hasDetails = false }
    }

    private func setTransport(_ new: Transport) {
        guard transport != new else { return }
        transport = new
        onTransportChange?()
    }
}
