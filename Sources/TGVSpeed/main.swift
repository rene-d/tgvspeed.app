import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusItemController()
    }
}

// Mode non interactif : écoute le flux Socket.IO et imprime ce qui arrive.
if CommandLine.arguments.contains("--socket-dump") {
    let index = CommandLine.arguments.firstIndex(of: "--socket-dump").map { $0 + 1 }
    let seconds = index.flatMap { $0 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0]) : nil }
    MainActor.assumeIsolated { SocketProbe.run(seconds: seconds ?? 20) }
    exit(0)
}

// Mode non interactif : imprime le menu tel qu'il serait construit, puis sort.
if CommandLine.arguments.contains("--dump-menu") {
    let index = CommandLine.arguments.firstIndex(of: "--dump-menu").map { $0 + 1 }
    let seconds = index.flatMap { $0 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0]) : nil }
    MainActor.assumeIsolated { MenuDump.run(socketSeconds: seconds ?? 6) }
    exit(0)
}

// Mode non interactif : écrit le document de diagnostic (le même que l'entrée de
// menu) dans un fichier, ou sur la sortie standard si aucun chemin n'est donné.
// `--full` y ajoute les contenus du portail, comme ⌥ dans le menu.
if CommandLine.arguments.contains("--export") {
    let index = CommandLine.arguments.firstIndex(of: "--export").map { $0 + 1 }
    let next = index.flatMap { $0 < CommandLine.arguments.count ? CommandLine.arguments[$0] : nil }
    let path = next?.hasPrefix("--") == false ? next : nil
    MainActor.assumeIsolated {
        DiagnosticExport.run(socketSeconds: 6, path: path,
                             full: CommandLine.arguments.contains("--full"))
    }
    exit(0)
}

// Mode non interactif : charge le portail Air France dans la vue web invisible
// et imprime le premier document `flightdata` obtenu. À lancer à bord.
if CommandLine.arguments.contains("--flight-probe") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let portal = FlightPortal(starlinkRouter: PlaneFeed().url)
        var done = false
        portal.onFlight = { info, raw in
            if let raw, let data = try? JSONEncoder().encode(raw) {
                print(String(decoding: data, as: UTF8.self))
            }
            print(info.map { "vol : \($0.label), arrivée \($0.estimatedArrival.map(Formatters.time) ?? "?")" }
                ?? "flightdata illisible")
            fflush(stdout)
            done = info != nil
        }
        print("portail : \(portal.portal.absoluteString)")
        portal.start()
        let deadline = Date().addingTimeInterval(60)
        while !done, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if !done { print("aucune réponse en 60 s") }
        exit(done ? 0 : 1)
    }
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
