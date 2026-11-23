import AppKit

/// Notices an app disappearing from Applications and offers to clear up after it.
///
/// Watches the Applications folders themselves rather than the Trash. The
/// Trash is privacy-protected — reading it needs Full Disk Access — while the
/// Applications folders are not, and an app leaving them is the event that
/// matters, wherever it went.
///
/// An update looks like a removal followed by a re-add (Sparkle swaps the
/// bundle), so a change is acted on only after it has settled, and only if the
/// app's identifier is then installed nowhere else.
final class AppRemovalWatcher {
    struct RemovedApp {
        let name: String
        let identity: LeftoverMatcher.Identity
        let leftovers: [Leftover]
    }

    /// Called on the main queue when a removed app left something behind.
    var onAppRemoved: ((RemovedApp) -> Void)?

    private struct Snapshot {
        let name: String
        let bundleID: String
        let identity: LeftoverMatcher.Identity
    }

    private var sources: [DispatchSourceFileSystemObject] = []
    private var known: [String: Snapshot] = [:]
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.sanoj.KlipKlik.appwatch", qos: .utility)

    func start() {
        stop()
        queue.async { [weak self] in
            guard let self else { return }
            known = Self.snapshot()
        }
        for root in InstalledApps.roots {
            let fd = open(root.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue
            )
            source.setEventHandler { [weak self] in self?.scheduleCheck() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
        pending?.cancel()
        pending = nil
    }

    deinit { stop() }

    /// Runs on `queue`. A burst of changes — an installer, an update — becomes
    /// one check once it has gone quiet.
    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func check() {
        let now = Self.snapshot()
        let removed = known.filter { now[$0.key] == nil }.map(\.value)
        known = now

        let stillInstalled = Set(now.values.map(\.bundleID))
        for app in removed where !stillInstalled.contains(app.bundleID) && !Self.installedElsewhere(app.bundleID) {
            let others = InstalledApps.allBundleIDs().subtracting([app.bundleID.lowercased()])
            let leftovers = LeftoverScanner.scan(app: app.identity, bundleURL: nil, others: others)
                .filter { $0.strength == .exact }
            guard !leftovers.isEmpty else { continue }

            let report = RemovedApp(name: app.name, identity: app.identity, leftovers: leftovers)
            DispatchQueue.main.async { [weak self] in self?.onAppRemoved?(report) }
        }
    }

    /// LaunchServices still knows the copy sitting in the Trash; that one
    /// does not count as installed.
    private static func installedElsewhere(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .contains { !$0.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func snapshot() -> [String: Snapshot] {
        var result: [String: Snapshot] = [:]
        for root in InstalledApps.roots {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for url in entries where url.pathExtension == "app" {
                guard let app = AppBundle(url: url), InstalledApps.refusal(for: app) == nil else { continue }
                result[url.path] = Snapshot(name: app.name, bundleID: app.bundleID, identity: app.identity)
            }
        }
        return result
    }
}
