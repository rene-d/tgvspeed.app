import CoreLocation
import CoreWLAN
import Foundation

/// Lecture du SSID courant. Depuis macOS 11 elle exige une autorisation Localisation ;
/// on ne la demande donc que si l'utilisateur active explicitement l'option.
@MainActor
final class WiFiSSID: NSObject, CLLocationManagerDelegate {
    static let expectedSSID = "_SNCF_WIFI_INOUI"

    private let locationManager = CLLocationManager()
    private var onAuthorizationChange: (() -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    var isAuthorized: Bool {
        [.authorizedAlways, .authorized].contains(authorizationStatus)
    }

    func requestAuthorization(then handler: @escaping () -> Void) {
        onAuthorizationChange = handler
        locationManager.requestWhenInUseAuthorization()
    }

    /// SSID courant, ou `nil` si pas de Wi-Fi, pas d'autorisation, ou option désactivée.
    var current: String? {
        guard Preferences.shared.ssidDetection, isAuthorized else { return nil }
        return CWWiFiClient.shared().interface()?.ssid()
    }

    var isOnTrainNetwork: Bool? {
        guard let current else { return nil }
        return current == Self.expectedSSID
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            onAuthorizationChange?()
        }
    }
}
