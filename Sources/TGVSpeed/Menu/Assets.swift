import AppKit

/// Les icônes reprises de la version Python, redimensionnées pour les menus (22×22)
/// et la barre de menus (18 px de haut).
enum Assets {
    /// Le bundle de ressources produit par SwiftPM.
    ///
    /// `Bundle.module` le cherche à côté de l'exécutable — convention SwiftPM, fausse
    /// pour une `.app`, où `make app` le range dans `Contents/Resources`. À défaut,
    /// l'accesseur généré retombe sur le chemin de build absolu : l'application
    /// fonctionne alors sur la machine qui l'a compilée et nulle part ailleurs.
    /// On interroge donc d'abord le bundle de l'application.
    private static let resources: Bundle = {
        if let url = Bundle.main.url(forResource: "TGVSpeed_TGVSpeed", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    static func image(_ name: String, size: NSSize = NSSize(width: 22, height: 22)) -> NSImage? {
        guard let image = resources.image(forResource: name) else { return nil }
        let copy = image.copy() as! NSImage
        copy.size = size
        return copy
    }

    static var train: NSImage? { image("train") }
    static var destination: NSImage? { image("destination") }
    static var map: NSImage? { image("map") }
    static var gps: NSImage? { image("gps") }
    static var robotBroken: NSImage? { image("robot_broken", size: NSSize(width: 128, height: 128)) }

    /// Icône de la barre de menus : le TGV en couleurs, ou un symbole monochrome
    /// qui suit le thème clair/sombre si l'utilisateur préfère.
    static func menuBarIcon(template: Bool) -> NSImage? {
        if template {
            let symbol = NSImage(systemSymbolName: "train.side.front.car",
                                 accessibilityDescription: "TGV")
            symbol?.isTemplate = true
            return symbol
        }
        let image = Self.image("train", size: NSSize(width: 20, height: 20))
        image?.isTemplate = false
        return image
    }
}
