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
/// Permet de vérifier le repli REST de l'application en coupant le socket.
let socketDisabled = CommandLine.arguments.contains("--no-socket")
/// Retard annoncé en cours de route, pour vérifier qu'une notification déjà partie
/// se réarme quand l'horaire recule.
let lateMinutes = Int(argument("--late", default: 0))
let lateAfter = argument("--late-after", default: 30)

if CommandLine.arguments.contains("--help") {
    print("""
    tgvsim — simulateur des API wifi.sncf

      --port <n>    port d'écoute (défaut 8000)
      --at <min>    minute du trajet où démarrer (défaut 60, entre Bordeaux et Angoulême)
      --speed <n>   accélération du temps (défaut 1 ; 30 rejoue le trajet en 7 minutes)
      --no-socket   renvoie 404 sur /socket.io/, pour tester le repli REST de l'app
      --late <min>  annonce un retard de <min> sur les arrêts pas encore desservis
      --late-after <s>  au bout de <s> secondes réelles (défaut 30)

    Routes servies :
      /train/gps  /train/details  /train/graph
      /connection/status  /connection/statistics  /bar/attendance
      /socket.io/  (Engine.IO v4 en long-polling, namespace /router/api/pepita)
    """)
    exit(0)
}

let simulator = Simulator(startMinutes: startMinutes, timeScale: timeScale,
                          lateMinutes: lateMinutes, lateAfter: lateAfter)
let socketServer = SocketServer(simulator: simulator)

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func log(_ path: String, bytes: Int) {
    print("\(logFormatter.string(from: Date()))  \(path)  \(bytes) o")
    fflush(stdout)
}

// MARK: - Réponses REST

func body(for path: String) -> [String: Any]? {
    switch path {
    case "/train/gps": simulator.gps()
    case "/train/details": simulator.trainDetails()
    case "/connection/status": simulator.connectionStatus()
    case "/connection/statistics": simulator.connectionStatistics()
    case "/train/graph": simulator.trainGraph()
    case "/bar/attendance": simulator.barAttendance()
    default: nil
    }
}

func httpResponse(status: String, payload: Data, contentType: String = "application/json") -> Data {
    let header = """
    HTTP/1.1 \(status)\r
    Content-Type: \(contentType)\r
    Content-Length: \(payload.count)\r
    Connection: close\r
    \r

    """
    return Data(header.utf8) + payload
}

// MARK: - Requêtes

struct Request {
    let method: String
    let path: String
    let query: [String: String]
    let body: String
    let contentLength: Int
}

func parse(_ raw: String) -> Request? {
    let parts = raw.components(separatedBy: "\r\n\r\n")
    let head = parts.first ?? ""
    let body = parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : ""

    let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
    let requestLine = lines.first?.split(separator: " ") ?? []
    guard requestLine.count >= 2 else { return nil }

    let target = String(requestLine[1])
    let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    var query: [String: String] = [:]
    if split.count > 1 {
        for pair in split[1].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { query[String(kv[0])] = String(kv[1]) }
        }
    }

    let length = lines
        .first { $0.lowercased().hasPrefix("content-length:") }
        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0

    return Request(method: String(requestLine[0]), path: String(split[0]),
                   query: query, body: body, contentLength: length)
}

func respond(to request: Request, on connection: NWConnection) {
    let send: (Data) -> Void = { data in
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // Le long-polling répond quand un événement se présente, pas immédiatement.
    if request.path == "/socket.io/", socketDisabled {
        log("\(request.method) /socket.io/ (désactivé)", bytes: 0)
        send(httpResponse(status: "404 Not Found", payload: Data(#"{"error":"socket disabled"}"#.utf8)))
        return
    }

    if request.path == "/socket.io/" {
        socketServer.handle(method: request.method, query: request.query, body: request.body) { payload in
            log("\(request.method) /socket.io/", bytes: payload.count)
            send(httpResponse(status: "200 OK", payload: Data(payload.utf8), contentType: "text/plain"))
        }
        return
    }

    if let object = body(for: request.path) {
        let payload = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        log(request.path, bytes: payload.count)
        send(httpResponse(status: "200 OK", payload: payload))
    } else {
        log("\(request.path) (404)", bytes: 0)
        send(httpResponse(status: "404 Not Found", payload: Data(#"{"error":"unknown endpoint"}"#.utf8)))
    }
}

func handle(_ connection: NWConnection) {
    connection.start(queue: .global())

    func read(_ accumulated: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            let raw = accumulated + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            guard let request = parse(raw) else {
                connection.cancel()
                return
            }
            // Le corps d'un POST peut arriver après les en-têtes.
            if request.body.utf8.count < request.contentLength {
                read(raw)
                return
            }
            respond(to: request, on: connection)
        }
    }

    read("")
}

guard let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) else {
    FileHandle.standardError.write(Data("impossible d'écouter sur le port \(port)\n".utf8))
    exit(1)
}

listener.newConnectionHandler = handle
listener.stateUpdateHandler = { state in
    if case .ready = state {
        print("tgvsim écoute sur http://localhost:\(port)")
        print("  départ simulé à t+\(Int(startMinutes)) min, échelle de temps ×\(Int(timeScale))"
            + (socketDisabled ? " — socket.io désactivé" : ""))
        print("  TGVSPEED_BASE_URL=http://localhost:\(port) ./TGVSpeed.app/Contents/MacOS/TGVSpeed")
    }
}
listener.start(queue: .main)
dispatchMain()
