import Foundation

/// Calcul du texte affiché dans la barre de menus, isolé du contrôleur
/// pour être réutilisable (mode `--dump-menu`).
@MainActor
enum MenuBarTitle {
    static func string(mode: MenuBarDisplay, fix: GPSFix, details: TrainDetails?, stats: TripStats) -> String {
        let speed = Preferences.shared.unit.format(metersPerSecond: fix.speed)
        switch mode {
        case .iconOnly:
            return ""
        case .speed:
            return speed
        case .speedAndNextStop:
            guard let next = details?.nextStop else { return speed }
            return "\(speed) · \(next.label.prefix(18))"
        case .speedAndETA:
            guard let details, let next = details.nextStop,
                  let eta = stats.eta(inMeters: details.remainingDistanceToNextStop) ?? next.realDate
            else { return speed }
            return "\(speed) · \(Formatters.time(eta))"
        }
    }
}
