import AppKit

/// Installs a missing tool with Homebrew — only after the user says yes to
/// a dialog naming the exact command.
///
/// Homebrew itself is never installed for them: its installer is a script
/// piped into a shell that asks for an administrator password in a terminal,
/// which is theirs to run. Without brew, the dialog says so and links its page.
enum PlinthToolInstaller {
    /// Asks, then runs `brew install <formula>`, tracked in the conversion
    /// panel. `completion` is true once the tool is on disk.
    static func offer(_ tool: PlinthTool, completion: @escaping (Bool) -> Void) {
        guard let brew = Homebrew.executable else {
            let alert = NSAlert()
            alert.messageText = "\(tool.rawValue) is needed, and Homebrew isn't installed"
            alert.informativeText = "Plinth uses ffmpeg for video. Install Homebrew from brew.sh, "
                + "then come back and Plinth can install ffmpeg for you."
            alert.addButton(withTitle: "Open brew.sh")
            alert.addButton(withTitle: "Cancel")
            if FloatingAlert.run(alert) == .alertFirstButtonReturn,
               let url = URL(string: "https://brew.sh") {
                NSWorkspace.shared.open(url)
            }
            completion(false)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Install \(tool.rawValue) with Homebrew?"
        alert.informativeText = "Plinth needs \(tool.rawValue) for this. KlipKlik will run:\n\n"
            + "    brew install \(tool.formula)\n\n"
            + "It downloads from Homebrew and can take a few minutes. Nothing else is changed."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard FloatingAlert.run(alert) == .alertFirstButtonReturn else {
            completion(false)
            return
        }

        ConversionCenter.shared.run("Installing \(tool.rawValue)", onSuccess: { _ in completion(true) }) { _, done in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = install(tool.formula, brew: brew)
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        if let installed = FFmpeg.executable {
                            done(.success(installed))
                        } else {
                            done(.failure(.init(message: "Homebrew finished, but \(tool.rawValue) wasn't found.")))
                            completion(false)
                        }
                    case .failure(let message):
                        done(.failure(.init(message: message)))
                        completion(false)
                    }
                }
            }
        }
    }

    private enum Outcome {
        case success
        case failure(String)
    }

    private static func install(_ formula: String, brew: URL) -> Outcome {
        let process = Process()
        process.executableURL = brew
        process.arguments = ["install", formula]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(brew.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_COLOR"] = "1"
        environment["HOMEBREW_NO_EMOJI"] = "1"
        // No terminal to type a password into: fail fast instead of hanging.
        environment["SUDO_ASKPASS"] = "/usr/bin/false"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .failure(PlinthRunner.reason(from: errorData, tool: "brew"))
        }
        return .success
    }
}
