import Combine
import Foundation

/// One outdated package.
struct BrewPackage: Identifiable, Hashable {
    let name: String
    let isCask: Bool
    let installed: String
    let latest: String
    let pinned: Bool

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
                    isCask: isCask,
                    installed: versionText(entry["installed_versions"]),
                    latest: versionText(entry["current_version"]),
                    pinned: entry["pinned"] as? Bool ?? false
                ))
            }
        }
        return packages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Homebrew writes versions as a string or as a list of strings,
    /// depending on the package type and the Homebrew version.
    private static func versionText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let list = value as? [String] { return list.last ?? "" }
        return ""
    }
}

/// Checks Homebrew for outdated packages, and upgrades them on request.
///
/// Runs the real `brew`, rather than reading Homebrew's folders and API behind
/// its back: it already knows which casks update themselves (and so must not
/// be reported as outdated), which are pinned, and how to upgrade each one.
/// Twice a day in the background when the setting is on, and on demand from
/// the Tools window.
final class Homebrew: ObservableObject {
    static let shared = Homebrew()

    @Published private(set) var outdated: [BrewPackage] = []
    @Published private(set) var isChecking = false
    @Published private(set) var isUpgrading = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?
    /// Output of the last upgrade, for the window to show.
    @Published private(set) var log = ""

    static let checkInterval: TimeInterval = 12 * 60 * 60

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

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

    /// - Parameter refresh: run `brew update` first, so the answer reflects
    ///   what has been released since Homebrew last looked.
    func check(refresh: Bool) {
        guard !isChecking, !isUpgrading, Self.isInstalled else { return }
        isChecking = true
        lastError = nil

        DispatchQueue.global(qos: .utility).async {
            if refresh { _ = Self.run(["update", "--quiet"]) }
            let result = Self.run(["outdated", "--json=v2"])
            let packages = BrewOutdatedParser.parse(result.output)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isChecking = false
                lastChecked = Date()
                if let packages {
                    outdated = packages
                } else {
                    lastError = result.errorText.isEmpty ? "Homebrew gave no answer." : result.errorText
                }
            }
        }
    }

    /// Upgrades `packages`, or everything outdated when nil. Pinned formulae
    /// are left alone, as `brew upgrade` itself does.
    func upgrade(_ packages: [BrewPackage]? = nil) {
        guard !isUpgrading, !isChecking, Self.isInstalled else { return }

        var commands: [[String]] = [["upgrade"]]
        if let packages {
            // Formulae and casks in separate runs, so a name shared by both
            // cannot be taken for the wrong one.
            let formulae = packages.filter { !$0.isCask && !$0.pinned }.map(\.name)
            let casks = packages.filter(\.isCask).map(\.name)
            commands = []
            if !formulae.isEmpty { commands.append(["upgrade", "--formula"] + formulae) }
            if !casks.isEmpty { commands.append(["upgrade", "--cask"] + casks) }
        }
        guard !commands.isEmpty else { return }

        isUpgrading = true
        log = ""
        upgradeSequence(commands)
    }

    private func upgradeSequence(_ commands: [[String]]) {
        DispatchQueue.global(qos: .userInitiated).async {
            var combined = ""
            for command in commands {
                let result = Self.run(command, extraEnvironment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
                combined += String(data: result.output, encoding: .utf8) ?? ""
                combined += result.errorText.isEmpty ? "" : "\n" + result.errorText
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isUpgrading = false
                log = combined.trimmingCharacters(in: .whitespacesAndNewlines)
                check(refresh: false)
            }
        }
    }

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
