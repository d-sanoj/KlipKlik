import AppKit

/// The two questions only Finder can answer: which folder is in front, and
/// what is selected in it.
///
/// Asked through `osascript`, off the main thread. Scripting Finder is gated
/// by Automation: macOS asks once ("KlipKlik wants to control Finder") and
/// remembers the answer. Accessibility cannot stand in — Finder's window
/// exposes no path through it.
enum FinderScript {
    enum Failure: Error {
        /// The user said no to Automation, or has not been asked yet.
        case notPermitted
        case failed(String)
    }

    /// The folder a paste would land in: the front window's, or the Desktop.
    static func insertionFolder(completion: @escaping (Result<URL, Failure>) -> Void) {
        run("""
        tell application "Finder" to return POSIX path of (insertion location as alias)
        """) { result in
            completion(result.flatMap { output in
                let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { return .failure(.failed("no folder")) }
                return .success(URL(fileURLWithPath: path, isDirectory: true))
            })
        }
    }

    /// Every item selected in Finder's front window, in Finder's order.
    static func selection(completion: @escaping (Result<[URL], Failure>) -> Void) {
        run("""
        tell application "Finder"
            set output to ""
            repeat with chosen in (selection as alias list)
                set output to output & POSIX path of chosen & linefeed
            end repeat
            return output
        end tell
        """) { result in
            completion(result.map { output in
                output.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            })
        }
    }

    /// Selects `url` in Finder, so a file we just wrote is easy to spot.
    static func reveal(_ url: URL) {
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        run("tell application \"Finder\" to select (POSIX file \"\(path)\" as alias)") { _ in }
    }

    /// Runs a script and hands back its output on the main queue.
    private static func run(_ source: String, completion: @escaping (Result<String, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors

            let result: Result<String, Failure>
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let text = String(data: data, encoding: .utf8) ?? ""
                let message = String(data: errorData, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    result = .success(text)
                } else if message.contains("-1743") || message.contains("Not authorized") {
                    // errAEEventNotPermitted: Automation was refused.
                    result = .failure(.notPermitted)
                } else {
                    result = .failure(.failed(message))
                }
            } catch {
                result = .failure(.failed(error.localizedDescription))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
}
