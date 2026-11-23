import AppKit

/// Removes what `LeftoverScanner` found.
///
/// Everything goes to the Trash, never straight off the disk, so a mistake can
/// be put back with Finder's "Put Back" or by dragging it out. Items only an
/// administrator can move are moved in one batch behind the standard macOS
/// password prompt — KlipKlik has no privileged helper, and asks once per
/// removal rather than once per file.
enum AppRemover {
    struct Report {
        var removed: [URL] = []
        var failed: [(url: URL, reason: String)] = []
        /// Refused by macOS's privacy protection rather than by file
        /// permissions. No password gets past that; only Full Disk Access.
        var protected: [URL] = []
        var freedBytes: Int64 = 0
        var resetPrivacy = false
        /// The admin prompt was cancelled.
        var adminCancelled = false
    }

    /// Runs off the main thread; `completion` comes back on it.
    ///
    /// - Parameter bundleID: when set, the app's privacy approvals are reset
    ///   too, so a reinstall starts clean instead of finding stale rows in
    ///   System Settings.
    static func remove(
        _ items: [Leftover],
        bundleID: String?,
        completion: @escaping (Report) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var report = Report()

            // Stop background jobs first, or launchd relaunches what is being
            // removed, or keeps a deleted helper's file open.
            for item in items where item.kind == .launchAgent && !item.needsAdmin {
                run("/bin/launchctl", ["bootout", "gui/\(getuid())", item.url.path])
            }

            let userItems = items.filter { !$0.needsAdmin }
            let adminItems = items.filter(\.needsAdmin)

            for item in userItems {
                do {
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                    report.removed.append(item.url)
                    report.freedBytes += item.size ?? 0
                } catch {
                    report.failed.append((item.url, explain(error)))
                    if isPrivacyRefusal(error) { report.protected.append(item.url) }
                }
            }

            if !adminItems.isEmpty {
                switch runAsAdministrator(script(for: adminItems)) {
                case .success:
                    for item in adminItems {
                        if FileManager.default.fileExists(atPath: item.url.path) {
                            report.failed.append((item.url, "Still there after the move."))
                        } else {
                            report.removed.append(item.url)
                            report.freedBytes += item.size ?? 0
                        }
                    }
                case .cancelled:
                    report.adminCancelled = true
                    report.failed += adminItems.map { ($0.url, "Administrator password not given.") }
                case .failed(let message):
                    report.failed += adminItems.map { ($0.url, message) }
                }
            }

            if let bundleID, !bundleID.lowercased().hasPrefix("com.apple.") {
                report.resetPrivacy = run("/usr/bin/tccutil", ["reset", "All", bundleID]) == 0
            }

            DispatchQueue.main.async { completion(report) }
        }
    }

    // MARK: Administrator batch

    /// One shell script for every root-owned item: unload daemons, forget
    /// receipts, move the rest into the user's Trash and hand them back to the
    /// user so the Trash can be emptied normally.
    static func script(for items: [Leftover]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let trash = home.appendingPathComponent(".Trash")
        let user = NSUserName()
        var lines: [String] = ["set -u"]
        var usedNames = Set<String>()

        for item in items {
            switch item.kind {
            case .launchDaemon:
                lines.append("/bin/launchctl bootout system \(quote(item.url.path)) 2>/dev/null || true")
            case .launchAgent:
                lines.append("/bin/launchctl bootout gui/\(getuid()) \(quote(item.url.path)) 2>/dev/null || true")
            case .receipt(let packageID):
                // Both the .bom and the .plist carry the same package; forgetting
                // it once removes both.
                if usedNames.insert("receipt:" + packageID).inserted {
                    lines.append("/usr/sbin/pkgutil --forget \(quote(packageID)) >/dev/null 2>&1 || true")
                }
                continue
            case .appBundle, .file:
                break
            }

            let destination = uniqueTrashURL(for: item.url, in: trash, avoiding: &usedNames)
            lines.append("/bin/mv -f \(quote(item.url.path)) \(quote(destination.path))")
            lines.append("/usr/sbin/chown -R \(quote(user)) \(quote(destination.path)) 2>/dev/null || true")
        }
        return lines.joined(separator: "\n")
    }

    /// `~/.Trash/name`, or `name 18.04.11` when that is taken.
    private static func uniqueTrashURL(for url: URL, in trash: URL, avoiding used: inout Set<String>) -> URL {
        let name = url.lastPathComponent
        var candidate = trash.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) || used.contains(candidate.path) {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let suffixed = "\(stem) \(counter)" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = trash.appendingPathComponent(suffixed)
            counter += 1
        }
        used.insert(candidate.path)
        return candidate
    }

    /// Single-quoted for the shell: `it's` → `'it'\''s'`.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum AdminResult {
        case success
        case cancelled
        case failed(String)
    }

    /// Runs a shell script as root behind the standard password prompt.
    static func runAsAdministrator(_ shellScript: String) -> AdminResult {
        // AppleScript string literal: backslashes first, then quotes.
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return .success }

        let message = String(data: data, encoding: .utf8) ?? ""
        // -128 is "User canceled."
        if message.contains("-128") { return .cancelled }
        return .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private static func explain(_ error: Error) -> String {
        isPrivacyRefusal(error)
            ? "macOS protects this folder. Give KlipKlik Full Disk Access to remove it."
            : (error as NSError).localizedDescription
    }

    /// "Operation not permitted" on a folder the user owns: that is macOS
    /// guarding another app's data (Group Containers, Application Scripts,
    /// Containers), not a permissions problem a password would solve.
    static func isPrivacyRefusal(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        return [nsError, underlying].contains {
            $0?.domain == NSPOSIXErrorDomain && ($0?.code == Int(EPERM) || $0?.code == Int(EACCES))
        }
    }

    /// The Full Disk Access list in System Settings.
    static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

/// Full Disk Access, which removing other apps' protected leftovers needs.
///
/// Unlike Accessibility and Screen Recording, macOS has no prompt for it and
/// never lists an app until the user adds it with the + button. So the route
/// offered is the pane, opened beside a Finder window holding KlipKlik, ready
/// to be dragged into the list.
enum FullDiskAccess {
    /// Whether macOS currently grants it. Read by trying to open a file only
    /// Full Disk Access can open: no API reports it, and reading does not
    /// raise a prompt.
    static var isGranted: Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: probe) else { return false }
        try? handle.close()
        return true
    }

    /// Opens the Full Disk Access pane, and shows KlipKlik in Finder so it can
    /// be dragged straight into the list.
    static func requestByHand() {
        AppRemover.openFullDiskAccessSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }
}
