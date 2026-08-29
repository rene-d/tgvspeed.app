import Foundation

/// Ce qu'affiche le titre de la barre de menus.
enum MenuBarDisplay: String, CaseIterable {
    case speed
    case speedAndNextStop
    case speedAndETA
    case iconOnly

    var title: String {
        switch self {
        case .speed: "Vitesse"
        case .speedAndNextStop: "Vitesse et prochain arrêt"
        case .speedAndETA: "Vitesse et heure d'arrivée"
        case .iconOnly: "Icône seule"
        }
    }
}

enum SpeedUnit: String, CaseIterable {
    case kmh
    case mph

    var title: String {
        switch self {
        case .kmh: "km/h"
        case .mph: "mph"
        }
    }

    /// Convertit une vitesse en m·s⁻¹.
    func value(fromMetersPerSecond speed: Double) -> Double {
        switch self {
        case .kmh: speed * 3.6
        case .mph: speed * 2.236936
        }
    }

    func format(metersPerSecond speed: Double) -> String {
        String(format: "%.1f %@", value(fromMetersPerSecond: speed), title)
    }
}

/// Préférences persistées dans UserDefaults, sans fenêtre de réglages :
/// tout se pilote depuis le sous-menu « Affichage ».
@MainActor
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let display = "menuBarDisplay"
        static let unit = "speedUnit"
        static let templateIcon = "templateIcon"
        static let ssidDetection = "ssidDetection"
        static let alarmStop = "alarmStop"
        static let alarmLead = "alarmLead"
    }

    var display: MenuBarDisplay {
        get { defaults.string(forKey: Key.display).flatMap(MenuBarDisplay.init) ?? .speed }
        set { defaults.set(newValue.rawValue, forKey: Key.display) }
    }

    var unit: SpeedUnit {
        get { defaults.string(forKey: Key.unit).flatMap(SpeedUnit.init) ?? .kmh }
        set { defaults.set(newValue.rawValue, forKey: Key.unit) }
    }

    /// Icône monochrome qui suit le thème, au lieu du TGV en couleurs.
    var templateIcon: Bool {
        get { defaults.bool(forKey: Key.templateIcon) }
        set { defaults.set(newValue, forKey: Key.templateIcon) }
    }

    /// Lecture du SSID : coûte une autorisation Localisation, donc désactivée par défaut.
    var ssidDetection: Bool {
        get { defaults.bool(forKey: Key.ssidDetection) }
        set { defaults.set(newValue, forKey: Key.ssidDetection) }
    }

    /// Gare pour laquelle prévenir avant l'arrivée, sous la forme `train|code`.
    /// Le numéro de train est mémorisé avec elle pour qu'une sélection oubliée
    /// ne se réveille pas au voyage suivant.
    var alarmStop: ArrivalAlarm.Selection? {
        get {
            let parts = (defaults.string(forKey: Key.alarmStop) ?? "").split(separator: "|",
                                                                            maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return ArrivalAlarm.Selection(train: String(parts[0]), code: String(parts[1]))
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.alarmStop)
                return
            }
            defaults.set("\(newValue.train)|\(newValue.code)", forKey: Key.alarmStop)
        }
    }

    /// Délai de prévenance avant l'arrivée, en minutes. Une valeur absente ou
    /// hors des choix du menu retombe sur les dix minutes d'origine.
    var alarmLead: Int {
        get {
            let stored = defaults.integer(forKey: Key.alarmLead)
            return ArrivalAlarm.leadChoices.contains(stored) ? stored : 10
        }
        set { defaults.set(newValue, forKey: Key.alarmLead) }
    }
}
