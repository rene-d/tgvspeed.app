import Foundation

/// Mode `--socket-dump` : écoute le flux Socket.IO et imprime ce qui arrive.
/// Sert à vérifier le protocole depuis un train, ou contre `tgvsim`.
enum SocketProbe {
    static func run(seconds: Double) {
        let rest = WifiSNCFClient()
        let client = EngineIOClient(root: rest.socketRoot,
                                    namespace: WifiSNCFClient.socketNamespace)
        print("socket   : \(rest.socketRoot.absoluteString)socket.io/")
        print("namespace: \(WifiSNCFClient.socketNamespace)")
        print("écoute \(Int(seconds)) s…\n")

        var finished = false
        var counts: [String: Int] = [:]
        var firstPayload: [String: String] = [:]

        let task = Task {
            defer { finished = true }
            do {
                for try await event in client.stream() {
                    switch event {
                    case .connected:
                        print("connecté au namespace")
                    case .message(let name, let payload):
                        counts[name, default: 0] += 1
                        if firstPayload[name] == nil {
                            firstPayload[name] = String(data: payload, encoding: .utf8) ?? ""
                        }
                    }
                }
            } catch {
                print("interrompu : \(error.localizedDescription)")
            }
        }

        let deadline = Date().addingTimeInterval(seconds)
        while !finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        task.cancel()

        guard !counts.isEmpty else {
            print("aucun événement reçu")
            return
        }

        print("\névénements reçus :")
        for (name, count) in counts.sorted(by: { $0.value > $1.value }) {
            let sample = (firstPayload[name] ?? "").prefix(150)
            print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) ×\(count)")
            print("    \(sample)")
        }
    }
}
