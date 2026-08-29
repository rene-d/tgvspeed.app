import Foundation
import UserNotifications

@MainActor
extension TrainDetails {
    /// Estimation vivante de l'arrivée : l'ETA calculée quand il s'agit du prochain
    /// arrêt — c'est le seul pour lequel le routeur donne une distance restante —
    /// et l'horaire annoncé, retard inclus, pour tous les autres.
    func estimatedArrival(for stop: Stop, stats: TripStats) -> Date? {
        if stop.code == nextStop?.code,
           let eta = stats.eta(inMeters: remainingDistanceToNextStop) {
            return eta
        }
        return stop.realDate
    }
}

/// Prévient avant l'arrivée à la gare cochée par l'utilisateur.
///
/// La notification part au franchissement du seuil plutôt qu'à une date planifiée :
/// l'heure d'arrivée bouge en permanence — retard annoncé, vitesse réelle — et une
/// notification programmée à l'avance serait fausse dès la minute suivante.
@MainActor
final class ArrivalAlarm {
    /// Délais proposés dans le menu, en minutes.
    static let leadChoices = [5, 10, 15, 20, 25, 30]

    /// Délai de prévenance, en secondes. `TGVSPEED_ALARM_LEAD` court-circuite le
    /// réglage pour les essais : il s'exprime en secondes, pas en minutes.
    static var leadTime: TimeInterval {
        if let forced = ProcessInfo.processInfo.environment["TGVSPEED_ALARM_LEAD"]
            .flatMap(TimeInterval.init) {
            return forced
        }
        return TimeInterval(Preferences.shared.alarmLead * 60)
    }

    struct Selection: Equatable {
        let train: String
        let code: String
    }

    /// Prévenu quand la sélection change, pour rafraîchir les coches du menu.
    var onChange: (() -> Void)?

    private(set) var selection: Selection?
    /// Empêche une seconde notification pour le même arrêt.
    private var firedCode: String?

    init() {
        selection = Preferences.shared.alarmStop
    }

    // MARK: - Sélection

    func isSelected(_ stop: Stop, in details: TrainDetails) -> Bool {
        guard let selection, let code = stop.code else { return false }
        return selection.train == details.label && selection.code == code
    }

    /// Une seule gare à la fois : cocher une autre décoche la précédente.
    func toggle(_ stop: Stop, in details: TrainDetails) {
        guard let code = stop.code else { return }

        if isSelected(stop, in: details) {
            set(nil)
        } else {
            set(Selection(train: details.label, code: code))
            requestAuthorization()
        }
    }

    /// Délai choisi, en minutes. Le changer ne réarme pas une alarme déjà partie :
    /// l'arrêt a été annoncé, le répéter n'apprendrait rien.
    var leadMinutes: Int {
        get { Preferences.shared.alarmLead }
        set {
            guard newValue != leadMinutes else { return }
            Preferences.shared.alarmLead = newValue
            onChange?()
        }
    }

    func selectedStop(in details: TrainDetails) -> Stop? {
        guard let selection, selection.train == details.label else { return nil }
        return details.stops.first { $0.code == selection.code }
    }

    private func set(_ new: Selection?) {
        selection = new
        firedCode = nil
        Preferences.shared.alarmStop = new
        onChange?()
    }

    // MARK: - Évaluation

    /// Appelé à chaque position reçue.
    func evaluate(details: TrainDetails?, stats: TripStats) {
        guard let details else { return }

        // Un changement de train invalide une sélection laissée d'un trajet précédent.
        if let selection, selection.train != details.label {
            set(nil)
            return
        }

        guard let stop = selectedStop(in: details) else { return }

        // L'arrêt est desservi : la sélection n'a plus d'objet.
        if stop.isDone {
            set(nil)
            return
        }

        guard firedCode != stop.code,
              let arrival = Self.arrival(for: stop, in: details, stats: stats),
              arrival.timeIntervalSinceNow <= Self.leadTime
        else { return }

        firedCode = stop.code
        notify(stop: stop, arrival: arrival)
    }

    /// Pour prévenir, l'horaire annoncé prime : il intègre le retard publié et c'est
    /// celui qu'affiche le reste du menu. L'ETA calculée, elle, ignore le freinage en
    /// approche et sous-estime l'arrivée en fin de tronçon — elle annoncerait 7 minutes
    /// là où la fiche horaire en promet 10.
    private static func arrival(for stop: Stop, in details: TrainDetails,
                                stats: TripStats) -> Date? {
        stop.realDate ?? details.estimatedArrival(for: stop, stats: stats)
    }

    // MARK: - Notification

    private func requestAuthorization() {
        guard let center = Self.center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(stop: Stop, arrival: Date) {
        let minutes = Int((arrival.timeIntervalSinceNow / 60).rounded())
        let body = minutes <= 0
            ? "Arrivée imminente"
            : "Arrivée dans \(minutes) min, à \(Formatters.time(arrival))"

        // Trace visible dans `make demo`, où la bannière n'apparaît pas forcément.
        // Le vidage explicite est nécessaire : hors terminal, stdout est bufferisé.
        print("alarme : \(stop.label) — \(body)")
        fflush(stdout)

        guard let center = Self.center else { return }
        let content = UNMutableNotificationContent()
        content.title = stop.label
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: "arrival-\(stop.code ?? stop.label)",
                                            content: content,
                                            trigger: nil)
        center.add(request)
    }

    /// `UNUserNotificationCenter` exige un bundle : les modes `--dump-menu` et
    /// `--socket-dump` peuvent tourner sur le binaire nu.
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }
}
