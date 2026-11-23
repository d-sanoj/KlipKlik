import AppKit
import SwiftUI

// MARK: - Homebrew

struct HomebrewView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case updates = "Updates"
        case apps = "Apps"
        case formulae = "Command Line"

        var id: String { rawValue }
    }

    @ObservedObject private var brew = Homebrew.shared
    @ObservedObject private var settings = Settings.shared
    @State private var filter: Filter = .all
    @State private var query = ""
    @AppStorage("brewShowDependencies") private var showDependencies = true
    @State private var showsLog = false

    private var rows: [BrewPackage] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return brew.installed.filter { package in
            switch filter {
            case .all: break
            case .updates: guard package.isOutdated else { return false }
            case .apps: guard package.isCask else { return false }
            case .formulae: guard !package.isCask else { return false }
            }
            if !showDependencies, !package.installedOnRequest, !package.isOutdated { return false }
            guard !trimmed.isEmpty else { return true }
            return package.displayName.localizedCaseInsensitiveContains(trimmed)
                || package.name.localizedCaseInsensitiveContains(trimmed)
                || (package.summary?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
        // Updates first: they are what the page is usually opened for.
        .sorted { $0.isOutdated && !$1.isOutdated }
    }

    var body: some View {
        VStack(spacing: 0) {
            if Homebrew.isInstalled, !brew.installed.isEmpty {
                filterBar
                Divider()
            }
            content.fillsToolArea()
            if Homebrew.isInstalled { actionBar }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                TextField("Search packages", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    brew.check(refresh: true)
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .help("Ask Homebrew for the newest versions")
                .disabled(!Homebrew.isInstalled || brew.isChecking || brew.isWorking)
            }
        }
        .onAppear {
            if brew.installed.isEmpty, Homebrew.isInstalled { brew.check(refresh: false) }
        }
        .sheet(isPresented: $showsLog) { logSheet }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                // One view per segment, never an if/else: the segmented
                // control matches segments by position, and branches change
                // what sits at each position.
                ForEach(Filter.allCases) { option in
                    Text(label(for: option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Toggle("Show dependencies", isOn: $showDependencies)
                .toggleStyle(.checkbox)
                .help("Formulae installed only because another one needs them")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if !Homebrew.isInstalled {
            ContentUnavailableView {
                Label("Homebrew Is Not Installed", systemImage: "shippingbox")
            } description: {
                Text("Install it from brew.sh, then come back to manage your packages here.")
            } actions: {
                Link("Open brew.sh", destination: URL(string: "https://brew.sh")!)
            }
        } else if brew.installed.isEmpty, brew.isChecking {
            ToolProgress(text: "Reading what Homebrew has installed…")
        } else if brew.installed.isEmpty, let error = brew.lastError {
            ContentUnavailableView {
                Label("Couldn't Read Homebrew", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if rows.isEmpty {
            ContentUnavailableView {
                Label(filter == .updates ? "Everything Is Up to Date" : "Nothing Here",
                      systemImage: filter == .updates ? "checkmark.seal" : "shippingbox")
            } description: {
                Text(filter == .updates
                     ? "Apps that update themselves are left to do so."
                     : "No installed package matches.")
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(rows) {
            TableColumn("Package") { package in
                HStack(spacing: 9) {
                    Image(systemName: package.isCask ? "macwindow" : "terminal")
                        .foregroundStyle(package.isCask ? Color.blue : Color.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(package.displayName).lineLimit(1)
                            if package.pinned { ToolTag(text: "Pinned") }
                            if !package.installedOnRequest { ToolTag(text: "Dependency") }
                        }
                        if let summary = package.summary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 220, ideal: 320)

            TableColumn("Kind") { package in
                Text(package.isCask ? "App" : "Formula").foregroundStyle(.secondary)
            }
            .width(64)

            TableColumn("Version") { package in
                HStack(spacing: 5) {
                    Text(package.installed).foregroundStyle(.secondary)
                    if package.isOutdated {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text(package.latest).foregroundStyle(.green)
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
            }
            .width(min: 110, ideal: 170)

            TableColumn("") { package in
                actions(for: package)
            }
            .width(min: 120, ideal: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    @ViewBuilder
    private func actions(for package: BrewPackage) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if brew.busy.contains(package.id) || (brew.busy.contains(Homebrew.allID) && package.isOutdated) {
                ProgressView().controlSize(.small)
            } else if package.isOutdated, !package.pinned {
                Button("Update") { brew.upgrade([package]) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(brew.isChecking)
            }

            Menu {
                if package.isOutdated, !package.pinned {
                    Button("Update") { brew.upgrade([package]) }
                    Divider()
                }
                Button("Uninstall…") { confirmUninstall(package) }
                if let homepage = package.homepage {
                    Divider()
                    Link("Open Website", destination: homepage)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(brew.busy.contains(package.id))
            .help("More")
        }
    }

    private var actionBar: some View {
        ToolActionBar {
            if let result = brew.lastResult {
                ToolMessage(text: result)
            } else {
                Toggle("Check twice a day", isOn: $settings.brewAutoCheck)
                    .toggleStyle(.checkbox)
                if !brew.installed.isEmpty {
                    Text(summaryLine).foregroundStyle(.secondary)
                }
            }
        } trailing: {
            if !brew.log.isEmpty {
                Button("Show Output") { showsLog = true }
                    .buttonStyle(.borderless)
            }
            if brew.isChecking, !brew.installed.isEmpty { ProgressView().controlSize(.small) }
            if !brew.outdated.isEmpty {
                Button("Update All (\(brew.outdated.count))") { brew.upgrade() }
                    .buttonStyle(.borderedProminent)
                    .disabled(brew.isWorking || brew.isChecking)
            }
        }
    }

    private func label(for option: Filter) -> String {
        option == .updates && !brew.outdated.isEmpty
            ? "Updates (\(brew.outdated.count))"
            : option.rawValue
    }

    private var summaryLine: String {
        let apps = brew.installed.filter(\.isCask).count
        let formulae = brew.installed.count - apps
        var parts = ["\(apps) app\(apps == 1 ? "" : "s")", "\(formulae) formula\(formulae == 1 ? "" : "e")"]
        if let checked = brew.lastChecked {
            parts.append("checked \(checked.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    /// Asks first. For an app, offers to remove its settings and support files
    /// too — Homebrew's `--zap`, which follows the list in the app's recipe.
    private func confirmUninstall(_ package: BrewPackage) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall \(package.displayName)?"
        alert.informativeText = package.isCask
            ? "Homebrew removes the app. This cannot be undone from here."
            : "Homebrew removes the formula. If other packages need it, Homebrew refuses and says which."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        if package.isCask {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Also remove its settings and support files"
            alert.suppressionButton?.state = .off
        }
        ToolsAlert.confirm(alert) { confirmed in
            guard confirmed else { return }
            brew.uninstall(package, zap: alert.suppressionButton?.state == .on)
        }
    }

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Homebrew Output").font(.headline)
            ScrollView {
                Text(brew.log)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            Text("Apps installed with an installer package may need a password; update or remove "
                + "those from Terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { showsLog = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 420)
    }
}

// MARK: - Ports

final class PortsModel: ObservableObject {
    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var isLoading = false
    @Published var query = ""
    @Published var message: String?

    var filtered: [ListeningPort] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ports }
        return ports.filter {
            String($0.port).hasPrefix(trimmed) || $0.command.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func refresh() {
        isLoading = true
        Ports.list { [weak self] ports in
            self?.ports = ports
            self?.isLoading = false
        }
    }

    func stop(_ port: ListeningPort) {
        let alert = NSAlert()
        alert.messageText = "Stop \(port.command) (PID \(port.pid))?"
        alert.informativeText = "It is listening on port \(port.port). Unsaved work in it may be lost."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        ToolsAlert.confirm(alert) { [weak self] confirmed in
            if confirmed { self?.send(port, force: false) }
        }
    }

    private func send(_ port: ListeningPort, force: Bool) {
        Ports.stop(pid: port.pid, force: force) { [weak self] result in
            self?.handle(result, for: port, wasForced: force)
        }
    }

    private func handle(_ result: Ports.StopResult, for port: ListeningPort, wasForced: Bool) {
        switch result {
        case .stopped:
            message = "Stopped \(port.command). Port \(port.port) is free."
            refresh()
        case .stillRunning:
            guard !wasForced else {
                message = "\(port.command) is still running."
                return
            }
            let alert = NSAlert()
            alert.messageText = "\(port.command) did not stop"
            alert.informativeText = "Force it to quit? It gets no chance to clean up."
            alert.addButton(withTitle: "Force Quit")
            alert.addButton(withTitle: "Cancel")
            ToolsAlert.confirm(alert) { [weak self] confirmed in
                if confirmed { self?.send(port, force: true) }
            }
        case .notPermitted:
            let alert = NSAlert()
            alert.messageText = "\(port.command) belongs to another user"
            alert.informativeText = "Stopping it needs an administrator password."
            alert.addButton(withTitle: "Stop as Administrator")
            alert.addButton(withTitle: "Cancel")
            ToolsAlert.confirm(alert) { [weak self] confirmed in
                guard confirmed else { return }
                Ports.stopAsAdministrator(pid: port.pid) { [weak self] result in
                    if case .notPermitted = result {
                        self?.message = "Not stopped: no password given."
                    } else {
                        self?.handle(result, for: port, wasForced: true)
                    }
                }
            }
        case .failed(let text):
            message = text
        }
    }
}

struct PortsView: View {
    @ObservedObject var model: PortsModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading, model.ports.isEmpty {
                ToolProgress(text: "Listing ports…")
            } else if model.filtered.isEmpty {
                ContentUnavailableView {
                    Label(model.query.isEmpty ? "Nothing Is Listening" : "No Match",
                          systemImage: "network")
                } description: {
                    Text(model.query.isEmpty
                         ? "No program on this Mac is waiting for connections."
                         : "No port or program matches “\(model.query)”.")
                }
                .fillsToolArea()
            } else {
                Table(model.filtered) {
                    TableColumn("Port") { port in
                        Text(String(port.port))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                    }
                    .width(70)
                    TableColumn("Program") { port in
                        HStack(spacing: 7) {
                            ProcessIcon(pid: port.pid)
                            Text(port.command)
                        }
                    }
                    .width(min: 150, ideal: 200)
                    TableColumn("PID") { port in
                        Text(String(port.pid)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(64)
                    TableColumn("Reachable From") { port in
                        Label(port.isLocalOnly ? "This Mac" : "Network",
                              systemImage: port.isLocalOnly ? "laptopcomputer" : "wifi")
                            .foregroundStyle(port.isLocalOnly ? Color.secondary : Color.orange)
                            .help(port.address)
                    }
                    .width(min: 110, ideal: 130)
                    TableColumn("User") { port in
                        Text(port.user).foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn("") { port in
                        Button("Stop") { model.stop(port) }
                            .controlSize(.small)
                    }
                    .width(56)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }

            if model.message != nil {
                ToolActionBar {
                    ToolMessage(text: model.message)
                } trailing: {
                    EmptyView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                TextField("Port or program", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear { model.refresh() }
    }
}

/// The icon of the app behind a process, or a terminal for a command-line one.
private struct ProcessIcon: View {
    let pid: Int32

    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }
}
