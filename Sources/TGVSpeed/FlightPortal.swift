import Foundation
import WebKit

/// Informations de vol, lues sur `freewifi.airfrance.com/ach/api/flightdata`
/// (`Fixtures/flightdata.json`).
///
/// La position et la vitesse y valent 0 : le portail lui-même les remplace par
/// celles du diagnostic Starlink, que lit `PlaneFeed`. On n'en retient que le vol.
struct FlightInfo: Equatable {
    let number: String?
    let phase: String?
    let origin: String?
    let destination: String?
    let tail: String?
    let aircraftType: String?
    /// Horaires prévus — `arrivalTimeUTC` ne tient pas compte du retard.
    let departure: Date?
    let scheduledArrival: Date?
    /// Horloge du serveur au moment de la réponse.
    let now: Date?
    /// Durées en minutes. `duration` = `flightProgressTime` + `timeToDestination`,
    /// et c'est l'estimée : elle dépasse l'écart entre les horaires prévus quand le vol
    /// est en retard (163 contre 146 min sur l'AF1063 du 13 octobre 2026).
    let duration: Double?
    let elapsed: Double?
    let remaining: Double?

    init?(_ json: JSONValue) {
        guard let flight = json["flight"] else { return nil }
        let aircraft = json["aircraft"]
        number = flight["number"]?.stringValue
        phase = flight["phase"]?.stringValue
        origin = flight["originIATA"]?.stringValue
        destination = flight["destinationIATA"]?.stringValue
        tail = aircraft?["tail"]?.stringValue
        aircraftType = aircraft?["type"]?.stringValue
        departure = Self.date(flight["departureTimeUTC"])
        scheduledArrival = Self.date(flight["arrivalTimeUTC"])
        now = Self.date(flight["currentTimeUTC"])
        duration = flight["duration"]?.doubleValue
        elapsed = flight["flightProgressTime"]?.doubleValue
        remaining = flight["timeToDestination"]?.doubleValue
        guard number != nil || origin != nil || destination != nil else { return nil }
    }

    /// Horaires en millisecondes depuis l'époque Unix.
    private static func date(_ value: JSONValue?) -> Date? {
        guard let ms = value?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// « AF1063 ARN → CDG »
    var label: String {
        let route = [origin, destination].compactMap { $0 }.joined(separator: " → ")
        return [number, route.isEmpty ? nil : route].compactMap { $0 }.joined(separator: " ")
    }

    /// Arrivée estimée : départ + durée estimée.
    ///
    /// `flightProgressTime` et `timeToDestination` ne sont pas rafraîchis : à cinq
    /// minutes d'intervalle, ils valaient toujours 125 et 38 alors que `currentTimeUTC`
    /// avait avancé. Leur somme `duration`, comptée depuis le départ, reste juste.
    var estimatedArrival: Date? {
        if let departure, let duration { return departure.addingTimeInterval(duration * 60) }
        if let remaining { return (now ?? Date()).addingTimeInterval(remaining * 60) }
        return scheduledArrival
    }

    /// Temps restant en secondes, recalculé sur l'horloge du Mac.
    var remainingTime: TimeInterval? {
        estimatedArrival.map { max(0, $0.timeIntervalSinceNow) }
    }

    var progress: Double? {
        guard let departure, let arrival = estimatedArrival else { return nil }
        let total = arrival.timeIntervalSince(departure)
        guard total > 0 else { return nil }
        return min(1, max(0, Date().timeIntervalSince(departure) / total))
    }
}

/// Accès à `flightdata` à travers une `WKWebView` invisible.
///
/// `freewifi.airfrance.com` est derrière l'anti-robot d'Akamai : sans les cookies
/// que pose son JavaScript (`ak_bmsc`, `bm_sv`…), le serveur coupe la requête —
/// `INTERNAL_ERROR` en HTTP/2, expiration en HTTP/1.1 — et `URLSession` n'y peut rien.
/// La vue charge donc le portail comme le ferait Safari, puis interroge l'API
/// depuis la page, avec les cookies que WebKit y a obtenus. Vérifié à bord le
/// 13 octobre 2026 (AF1063, Starlink).
///
/// Les paramètres de la requête sont ceux du portail :
/// - `fcid` : UUID tiré une fois pour toutes, le cookie `ach-fcid` du portail ;
/// - `clientId`, `routerId` : lus sur `wifi.airfrance.com/starlinkrouter/sandbox-client`,
///   qui, lui, n'est pas protégé.
@MainActor
final class FlightPortal: NSObject, WKNavigationDelegate {
    /// `TGVSPEED_FLIGHT_PORTAL` permet de pointer le simulateur local.
    let portal: URL = {
        if let override = ProcessInfo.processInfo.environment["TGVSPEED_FLIGHT_PORTAL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://freewifi.airfrance.com/")!
    }()

    var onFlight: ((FlightInfo?, JSONValue?) -> Void)?

    private let sandboxClient: URL
    private var webView: WKWebView?
    private var isLoaded = false
    private var loadedAt: Date?
    private var task: Task<Void, Never>?

    private let interval: Duration = .seconds(30)
    private let retryInterval: Duration = .seconds(10)
    /// Les cookies d'Akamai expirent : on recharge le portail de temps en temps.
    private let reloadAfter: TimeInterval = 15 * 60

    /// `starlinkRouter` : l'URL du diagnostic, dont `sandbox-client` est le voisin.
    init(starlinkRouter: URL) {
        sandboxClient = starlinkRouter.deletingLastPathComponent()
            .appendingPathComponent("sandbox-client")
        super.init()
    }

    /// Démarre au passage en mode avion, s'arrête en le quittant : hors de l'avion,
    /// inutile de garder une vue web chargée.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
        webView?.stopLoading()
        webView = nil
        isLoaded = false
    }

    private func loop() async {
        while !Task.isCancelled {
            var ok = false
            if loadedAt.map({ Date().timeIntervalSince($0) > reloadAfter }) ?? true {
                load()
            }
            if isLoaded, let (info, raw) = await fetch() {
                onFlight?(info, raw)
                ok = info != nil
            }
            try? await Task.sleep(for: ok ? interval : retryInterval)
        }
    }

    private func load() {
        let configuration = WKWebViewConfiguration()
        // Magasin persistant : les cookies du portail survivent à un relancement.
        configuration.websiteDataStore = .default()
        // Une vue hors fenêtre est considérée comme cachée, et WebKit y suspendrait
        // les minuteries dont dépend le script d'Akamai.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                             configuration: configuration)
        view.navigationDelegate = self
        webView = view
        isLoaded = false
        loadedAt = Date()
        view.load(URLRequest(url: portal))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { isLoaded = true }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                             withError error: Error) {
        MainActor.assumeIsolated { loadedAt = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        MainActor.assumeIsolated { loadedAt = nil }
    }

    // MARK: - Requête

    private func fetch() async -> (FlightInfo?, JSONValue)? {
        guard let webView, let query = await queryItems() else { return nil }
        var components = URLComponents(url: portal.appendingPathComponent("ach/api/flightdata"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url?.absoluteString else { return nil }

        let script = """
            const r = await fetch(url, {headers: {accept: "application/json"}, credentials: "include"});
            if (!r.ok) throw new Error("HTTP " + r.status);
            return await r.text();
            """
        guard let text = try? await webView.callAsyncJavaScript(
                  script, arguments: ["url": url], contentWorld: .defaultClient) as? String,
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        else {
            // Probablement les cookies d'Akamai expirés : on recharge au prochain tour.
            loadedAt = nil
            return nil
        }
        return (FlightInfo(json), json)
    }

    private var routerIdentifiers: (clientId: String, routerId: String)?

    private func queryItems() async -> [URLQueryItem]? {
        if routerIdentifiers == nil,
           let (data, _) = try? await URLSession.shared.data(from: sandboxClient),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data),
           let clientId = json["clientId"]?.stringValue,
           let routerId = json["routerId"]?.stringValue {
            routerIdentifiers = (clientId, routerId)
        }
        guard let ids = routerIdentifiers else { return nil }
        return [
            URLQueryItem(name: "fcid", value: Preferences.shared.flightClientId),
            URLQueryItem(name: "cb", value: "1"),
            URLQueryItem(name: "clientId", value: ids.clientId),
            URLQueryItem(name: "routerId", value: ids.routerId),
        ]
    }
}
