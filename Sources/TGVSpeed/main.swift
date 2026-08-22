import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusItemController()
    }
}

// Mode non interactif : imprime le menu tel qu'il serait construit, puis sort.
if CommandLine.arguments.contains("--dump-menu") {
    MainActor.assumeIsolated { MenuDump.run() }
    exit(0)
}

// Le point d'entrée s'exécute sur le thread principal : on peut donc entrer
// directement dans l'isolation MainActor exigée par AppKit.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Application d'accessoire : pas d'icône dans le Dock, pas de menu d'application.
    app.setActivationPolicy(.accessory)
    app.run()
}
