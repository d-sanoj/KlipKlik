import Combine
import Foundation

/// One installed Homebrew package, formula or cask.
struct BrewPackage: Identifiable, Hashable {
    let name: String
    /// What the package calls itself: "Visual Studio Code" for the cask
    /// `visual-studio-code`. Same as `name` for formulae.
    var displayName: String
    let isCask: Bool
    let installed: String
    /// The newest version Homebrew knows of.
    var latest: String
    var isOutdated: Bool
    let pinned: Bool
    var summary: String?
    var homepage: URL?
    /// False for a formula that only came in as another one's dependency.
    var installedOnRequest: Bool = true

    var id: String { (isCask ? "cask:" : "formula:") + name }
}

/// Reads `brew outdated --json=v2`. Separate so it can be tested on canned
/// output.
enum BrewOutdatedParser {
    static func parse(_ data: Data) -> [BrewPackage]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var packages: [BrewPackage] = []
        for (key, isCask) in [("formulae", false), ("casks", true)] {
            for entry in root[key] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String else { continue }
                packages.append(BrewPackage(
                    name: name,
                    displayName: name,
                    isCask: isCask,
                    installed: versionText(entry["installed_versions"]),
                    latest: versionText(entry["current_version"]),
                    isOutdated: true,
                    pinned: entry["pinned"] as? Bool ?? false
                ))
            }
        }
        return packages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Homebrew writes versions as a string or as a list of strings,
    /// depending on the package type and the Homebrew version.
    static func versionText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let list = value as? [String] { return list.last ?? "" }
        return ""
    }
}

/// Reads `brew info --json=v2 --installed`: every installed package, outdated
/// or not.
enum BrewInstalledParser {
    /// - Parameter outdated: the answer from `brew outdated`, which is the
    ///   one to trust on whether something needs updating — it knows which
    ///   casks update themselves and so must not be flagged.
    static func parse(_ data: Data, outdated: [BrewPackage]) -> [BrewPackage]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let newer = Dictionary(outdated.map { ($0.id, $0.latest) }, uniquingKeysWith: { first, _ in first })
        var packages: [BrewPackage] = []

        for entry in root["formulae"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else { continue }
            let installs = entry["installed"] as? [[String: Any]] ?? []
            let current = installs.last
            let versions = entry["versions"] as? [String: Any]
            var package = BrewPackage(
                name: name,
                displayName: name,
                isCask: false,
                installed: current?["version"] as? String ?? "",
                latest: versions?["stable"] as? String ?? "",
                isOutdated: false,
                pinned: entry["pinned"] as? Bool ?? false,
                summary: entry["desc"] as? String,
                homepage: (entry["homepage"] as? String).flatMap(URL.init(string:)),
                installedOnRequest: current?["installed_on_request"] as? Bool ?? true
            )
            if let latest = newer[package.id] {
                package.isOutdated = true
                package.latest = latest
            }
            packages.append(package)
        }

        for entry in root["casks"] as? [[String: Any]] ?? [] {
            guard let token = entry["token"] as? String else { continue }
            let names = entry["name"] as? [String] ?? []
            var package = BrewPackage(
                name: token,
                displayName: names.first ?? token,
                isCask: true,
                installed: BrewOutdatedParser.versionText(entry["installed"]),
                latest: entry["version"] as? String ?? "",
                isOutdated: false,
                pinned: false,
                summary: entry["desc"] as? String,
                homepage: (entry["homepage"] as? String).flatMap(URL.init(string:))
            )
            if let latest = newer[package.id] {
                package.isOutdated = true
                package.latest = latest
            }
            packages.append(package)
        }

        return packages.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

/// Everything installed with Homebrew: what is there, what is out of date, and
/// updating or removing any one of it.
///
/// Runs the real `brew`, rather than reading Homebrew's folders and API behind
/// its back: it already knows which casks update themselves (and so must not
/// be reported as outdated), which are pinned, what depends on what, and how to
/// upgrade or remove each one. Checks twice a day in the background when the
/// setting is on, and on demand from the window.
final class Homebrew: ObservableObject {
    static let shared = Homebrew()

    /// Every installed formula and cask.
    @Published private(set) var installed: [BrewPackage] = []
    /// The ones with a newer version. Drives the badge and the menu count.
    @Published private(set) var outdated: [BrewPackage] = []
    @Published private(set) var isChecking = false
    /// Packages being updated or removed right now, by id.
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?
    /// Output of the last update or removal, for the window to show.
    @Published private(set) var log = ""
    /// One line about how the last action went.
    @Published private(set) var lastResult: String?

    static let checkInterval: TimeInterval = 12 * 60 * 60
    /// Placeholder id while "Update All" runs.
    static let allID = "*"

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    var isWorking: Bool { !busy.isEmpty }

    /// Where brew lives: Apple silicon prefix first, then Intel.
    static var executable: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool { executable != nil }

    private init() {}

    func start() {
        Settings.shared.$brewAutoCheck
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.schedule(enabled) }
            .store(in: &cancellables)
    }

    private func schedule(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled, Self.isInstalled else { return }
        // First check a few minutes after launch, not during it.
        let first = Timer(timeInterval: 5 * 60, repeats: false) { [weak self] _ in
            self?.check(refresh: true)
            self?.scheduleRepeating()
        }
        RunLoop.main.add(first, forMode: .common)
        timer = first
    }

    private func scheduleRepeating() {
        let repeating = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check(refresh: true)
        }
        repeating.tolerance = 10 * 60
        RunLoop.main.add(repeating, forMode: .common)
        timer = repeating
    }

    // MARK: Checking

    /// Reads what is installed and what is outdated.
    ///
    /// - Parameter refresh: run `brew update` first, so the answer reflects
    ///   what has been released since Homebrew last looked.
    func check(refresh: Bool) {
        guard !isChecking, !isWorking, Self.isInstalled else { return }
        isChecking = true
        lastError = nil

        DispatchQueue.global(qos: .utility).async {
            if refresh { _ = Self.run(["update", "--quiet"]) }
            let quiet = ["HOMEBREW_NO_AUTO_UPDATE": "1"]
            let outdatedResult = Self.run(["outdated", "--json=v2"], extraEnvironment: quiet)
            let outdated = BrewOutdatedParser.parse(outdatedResult.output)
            let infoResult = Self.run(["info", "--json=v2", "--installed"], extraEnvironment: quiet)
            let installed = BrewInstalledParser.parse(infoResult.output, outdated: outdated ?? [])

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isChecking = false
                lastChecked = Date()
                if let outdated { self.outdated = outdated }
                if let installed {
                    self.installed = installed
                } else {
                    let error = infoResult.errorText.isEmpty ? outdatedResult.errorText : infoResult.errorText
                    lastError = error.isEmpty ? "Homebrew gave no answer." : error
                }
            }
        }
    }

    // MARK: Updating and removing

    /// Updates `packages`, or everything outdated when nil. Pinned formulae
    /// are left alone, as `brew upgrade` itself does.
    func upgrade(_ packages: [BrewPackage]? = nil) {
        guard !isChecking, Self.isInstalled else { return }

        var commands: [[String]] = [["upgrade"]]
        var ids: Set<String> = [Self.allID]
        if let packages {
            // Formulae and casks in separate runs, so a name shared by both
            // cannot be taken for the wrong one.
            let formulae = packages.filter { !$0.isCask && !$0.pinned }.map(\.name)
            let casks = packages.filter(\.isCask).map(\.name)
            commands = []
            if !formulae.isEmpty { commands.append(["upgrade", "--formula"] + formulae) }
            if !casks.isEmpty { commands.append(["upgrade", "--cask"] + casks) }
            ids = Set(packages.map(\.id))
        }
        guard !commands.isEmpty, busy.isDisjoint(with: ids) else { return }

        let label = packages.map { $0.map(\.displayName).joined(separator: ", ") } ?? "everything"
        perform(commands, ids: ids, success: "Updated \(label).", failure: "Couldn't update \(label).")
    }

    /// Removes one package. `zap` also deletes a cask's settings and support
    /// files, as listed in its recipe.
    func uninstall(_ package: BrewPackage, zap: Bool) {
        guard !isChecking, Self.isInstalled, !busy.contains(package.id) else { return }
        var command = ["uninstall", package.isCask ? "--cask" : "--formula"]
        if package.isCask, zap { command.append("--zap") }
        command.append(package.name)
        perform([command], ids: [package.id],
                success: "Removed \(package.displayName).",
                failure: "Couldn't remove \(package.displayName).")
    }

    private func perform(_ commands: [[String]], ids: Set<String>, success: String, failure: String) {
        busy.formUnion(ids)
        lastResult = nil

        DispatchQueue.global(qos: .userInitiated).async {
            var combined = ""
            var ok = true
            for command in commands {
                let result = Self.run(command, extraEnvironment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
                combined += String(data: result.output, encoding: .utf8) ?? ""
                combined += result.errorText.isEmpty ? "" : "\n" + result.errorText
                if result.status != 0 { ok = false }
            }
            let output = combined.trimmingCharacters(in: .whitespacesAndNewlines)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                busy.subtract(ids)
                log = output
                lastResult = ok ? success : failure + " " + Self.reason(in: output)
                check(refresh: false)
            }
        }
    }

    /// The line of brew's output that says why, when it refused.
    private static func reason(in output: String) -> String {
        output.split(separator: "\n")
            .first { $0.hasPrefix("Error:") || $0.contains("Refusing") || $0.contains("required by") }
            .map { $0.replacingOccurrences(of: "Error: ", with: "") } ?? "See the output for details."
    }

    // MARK: Running brew

    private struct RunResult {
        let output: Data
        let errorText: String
        let status: Int32
    }

    private static func run(_ arguments: [String], extraEnvironment: [String: String] = [:]) -> RunResult {
        guard let brew = executable else { return RunResult(output: Data(), errorText: "", status: -1) }
        let process = Process()
        process.executableURL = brew
        process.arguments = arguments

        // A GUI app inherits launchd's bare PATH; brew and the tools it calls
        // need their own prefix on it.
        var environment = ProcessInfo.processInfo.environment
        let prefix = brew.deletingLastPathComponent().path
        environment["PATH"] = "\(prefix):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_COLOR"] = "1"
        environment["HOMEBREW_NO_EMOJI"] = "1"
        // No terminal to type a password into: fail fast instead of hanging.
        environment["SUDO_ASKPASS"] = "/usr/bin/false"
        for (key, value) in extraEnvironment { environment[key] = value }
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return RunResult(output: Data(), errorText: error.localizedDescription, status: -1)
        }
        // Read both pipes concurrently, or a chatty upgrade fills one and stalls.
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return RunResult(
            output: data,
            errorText: (String(data: errorData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            status: process.terminationStatus
        )
    }
}
