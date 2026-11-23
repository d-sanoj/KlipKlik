import Foundation

/// A process listening on a TCP port.
struct ListeningPort: Identifiable, Hashable {
    let port: Int
    let pid: Int32
    let command: String
    let user: String
    /// The address it is bound to: `*`, `127.0.0.1`, `[::1]`.
    let address: String

    var id: String { "\(pid):\(port):\(address)" }

    /// Bound to loopback only, so nothing else on the network can reach it.
    var isLocalOnly: Bool {
        address.hasPrefix("127.") || address == "[::1]" || address == "localhost"
    }
}

/// Reads `lsof -F` field output. Separate so it can be tested on canned text.
///
/// Each line starts with a field letter: `p` begins a process, `c` is its
/// command, `L` its login name, and every `n` after that is one of its
/// sockets, written `address:port`.
enum LsofParser {
    static func parse(_ text: String) -> [ListeningPort] {
        var result: [ListeningPort] = []
        var seen = Set<String>()
        var pid: Int32 = 0
        var command = ""
        var user = ""

        for line in text.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value) ?? 0
                command = ""
                user = ""
            case "c":
                command = value
            case "L":
                user = value
            case "n":
                // "*:3000", "127.0.0.1:5432", "[::1]:8080". Connections
                // ("a:1->b:2") are not listeners; lsof filtered them, but be sure.
                guard !value.contains("->"), let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...])
                else { continue }
                let address = String(value[..<colon])
                let entry = ListeningPort(port: port, pid: pid, command: command, user: user, address: address)
                if seen.insert(entry.id).inserted { result.append(entry) }
            default:
                continue
            }
        }
        return result.sorted { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
    }
}

/// Lists listening ports and stops the processes behind them.
enum Ports {
    /// Runs off the main thread; `completion` comes back on it.
    static func list(completion: @escaping ([ListeningPort]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            // -n -P: no DNS or service-name lookups, which are slow and turn
            // port numbers into names like "http-alt".
            process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcLn"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var text = ""
            if (try? process.run()) != nil {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                text = String(data: data, encoding: .utf8) ?? ""
            }
            let ports = LsofParser.parse(text)
            DispatchQueue.main.async { completion(ports) }
        }
    }

    enum StopResult {
        case stopped
        case notPermitted
        case stillRunning
        case failed(String)
    }

    /// Asks the process to quit (SIGTERM), or forces it (SIGKILL).
    /// Waits briefly to report whether it actually went.
    static func stop(pid: Int32, force: Bool, completion: @escaping (StopResult) -> Void) {
        guard pid > 1, pid != getpid() else {
            completion(.failed("That process cannot be stopped from here."))
            return
        }
        if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
            completion(errno == EPERM ? .notPermitted : .failed(String(cString: strerror(errno))))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            // Signal 0 checks for existence without sending anything.
            completion(kill(pid, 0) == 0 ? .stillRunning : .stopped)
        }
    }

    /// Stops a process owned by another user (or root) behind the password prompt.
    static func stopAsAdministrator(pid: Int32, completion: @escaping (StopResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AppRemover.runAsAdministrator("/bin/kill -9 \(pid)")
            DispatchQueue.main.async {
                switch result {
                case .success: completion(.stopped)
                case .cancelled: completion(.notPermitted)
                case .failed(let message): completion(.failed(message))
                }
            }
        }
    }
}
