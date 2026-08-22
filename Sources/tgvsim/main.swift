import Foundation
import Network

// Simulateur des API du routeur de bord : `swift run tgvsim`
// puis TGVSPEED_BASE_URL=http://localhost:8000 pour brancher l'application dessus.

func argument(_ name: String, default value: Double) -> Double {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count,
          let parsed = Double(args[index + 1]) else { return value }
    return parsed
}

let port = UInt16(argument("--port", default: 8000))
let startMinutes = argument("--at", default: 60)
let timeScale = argument("--speed", default: 1)

if CommandLine.arguments.contains("--help") {
    print("""
    tgvsim — simulateur des API wifi.sncf

      --port <n>    port d'écoute (défaut 8000)
      --at <min>    minute du trajet où démarrer (défaut 60, entre Bordeaux et Angoulême)
      --speed <n>   accélération du temps (défaut 1 ; 30 rejoue le trajet en 7 minutes)

    Routes servies :
      /train/gps  /train/details
      /connection/status  /connection/statistics
    """)
    exit(0)
}

let simulator = Simulator(startMinutes: startMinutes, timeScale: timeScale)

func body(for path: String) -> [String: Any]? {
    switch path {
    case "/train/gps": simulator.gps()
    case "/train/details": simulator.trainDetails()
    case "/connection/status": simulator.connectionStatus()
    case "/connection/statistics": simulator.connectionStatistics()
    default: nil
    }
}

func response(for path: String) -> Data {
    let status: String
    let payload: Data
    if let object = body(for: path) {
        status = "200 OK"
        payload = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    } else {
        status = "404 Not Found"
        payload = Data(#"{"error":"unknown endpoint"}"#.utf8)
    }

    let header = """
    HTTP/1.1 \(status)\r
    Content-Type: application/json\r
    Content-Length: \(payload.count)\r
    Connection: close\r
    \r

    """
    return Data(header.utf8) + payload
}

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func log(_ path: String, bytes: Int) {
    print("\(logFormatter.string(from: Date()))  \(path)  \(bytes) o")
    fflush(stdout)
}

func handle(_ connection: NWConnection) {
    connection.start(queue: .global())
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
        // Une seule ligne de requête suffit : le simulateur ne sert que des GET.
        let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let data = response(for: path)
        log(path, bytes: data.count)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

guard let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) else {
    FileHandle.standardError.write(Data("impossible d'écouter sur le port \(port)\n".utf8))
    exit(1)
}

listener.newConnectionHandler = handle
listener.stateUpdateHandler = { state in
    if case .ready = state {
        print("tgvsim écoute sur http://localhost:\(port)")
        print("  départ simulé à t+\(Int(startMinutes)) min, échelle de temps ×\(Int(timeScale))")
        print("  TGVSPEED_BASE_URL=http://localhost:\(port) ./TGVSpeed.app/Contents/MacOS/TGVSpeed")
    }
}
listener.start(queue: .main)
dispatchMain()
