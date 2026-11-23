import AppKit

/// A process holding files open under something the user wants to delete,
/// move or eject.
struct FileHolder: Identifiable, Hashable {
    let pid: Int32
    let command: String
    let user: String
    /// The open paths, as lsof reports them.
    let files: [String]

    var id: Int32 { pid }
}

/// Reads `lsof -F pcLn` output into one holder per process. Separate so it can
/// be tested on canned text.
enum LsofFileParser {
    static func parse(_ text: String, excluding ownPID: Int32 = getpid()) -> [FileHolder] {
        var order: [Int32] = []
        var commands: [Int32: String] = [:]
        var users: [Int32: String] = [:]
        var files: [Int32: [String]] = [:]
        var pid: Int32 = 0

        for line in text.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value) ?? 0
                if files[pid] == nil {
                    order.append(pid)
                    files[pid] = []
                }
            case "c": commands[pid] = value
            case "L": users[pid] = value
            case "n":
                if !(files[pid]?.contains(value) ?? true) { files[pid]?.append(value) }
            default: continue
            }
        }

        return order
            .filter { $0 != ownPID && $0 > 0 }
            .map { FileHolder(pid: $0, command: commands[$0] ?? "?", user: users[$0] ?? "", files: files[$0] ?? []) }
    }
}

/// Finds out what is keeping a file, folder or disk busy.
enum FileUsage {
    /// What is open under `url`. A disk is checked as a whole filesystem; a
    /// folder is searched to the bottom, which can take a while on a big one.
    ///
    /// - Parameter asAdministrator: also see other users' and the system's
    ///   processes — Spotlight indexing a disk is the usual culprit, and it
    ///   runs as root. Asks for the password.
    static func holders(of url: URL, asAdministrator: Bool = false,
                        completion: @escaping (Result<[FileHolder], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let arguments = lsofArguments(for: url)
            let result: Result<[FileHolder], Error>
            if asAdministrator {
                let command = (["/usr/sbin/lsof"] + arguments).map(AppRemover.quote).joined(separator: " ")
                    + " || true"
                switch AppRemover.runAsAdministratorCapturing(command) {
                case .success(let output): result = .success(LsofFileParser.parse(output))
                case .failure(let error): result = .failure(error)
                }
            } else {
                result = .success(LsofFileParser.parse(runLsof(arguments)))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func lsofArguments(for url: URL) -> [String] {
        let fields = ["-F", "pcLn", "-w"]
        if isVolume(url) { return fields + [url.path] }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return fields + ["+D", url.path]
        }
        return fields + ["--", url.path]
    }

    private static func runLsof(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        // A huge folder can take lsof a long time; give up after 20 seconds.
        let deadline = DispatchTime.now() + 20
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Disks

    /// Disks that can be ejected: external drives, disk images, card readers.
    static func ejectableVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey,
                                      .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []
        return volumes.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true
            else { return false }
            return values.volumeIsEjectable == true || values.volumeIsRemovable == true
                || values.volumeIsInternal == false
        }
    }

    static func isVolume(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL.path
        return ejectableVolumes().contains { $0.standardizedFileURL.path == standardized }
            || (url.path.hasPrefix("/Volumes/") && url.pathComponents.count == 3)
    }

    static func eject(_ url: URL, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                failure = error
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }
}
