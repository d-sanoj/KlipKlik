import AppKit
import SwiftUI

// MARK: - Homebrew

struct HomebrewView: View {
    @ObservedObject private var brew = Homebrew.shared
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(spacing: 0) {
            ToolsHeader(
                title: "Homebrew Updates",
                detail: "Formulae and casks with a newer version. Apps that update themselves "
                    + "are left to do so, and pinned formulae stay put."
            ) {
                HStack {
                    if brew.isChecking { ProgressView().controlSize(.small) }
                    Button("Check Now") { brew.check(refresh: true) }
                        .disabled(!Homebrew.isInstalled || brew.isChecking || brew.isUpgrading)
                }
            }

            if !Homebrew.isInstalled {
                ToolsPlaceholder(
                    symbol: "shippingbox",
                    text: "Homebrew is not installed. Get it from brew.sh, then come back."
                )
            } else {
                content
            }

            HStack {
                Toggle("Check twice a day in the background", isOn: $settings.brewAutoCheck)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                if let checked = brew.lastChecked {
                    Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .onAppear {
            if brew.lastChecked == nil, Homebrew.isInstalled { brew.check(refresh: false) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = brew.lastError {
            ToolsPlaceholder(symbol: "exclamationmark.triangle", text: error)
        } else if brew.isUpgrading {
            ToolsPlaceholder(symbol: "shippingbox", text: "Upgrading… this can take a while.", busy: true)
        } else if brew.outdated.isEmpty {
            VStack(spacing: 0) {
                ToolsPlaceholder(
                    symbol: "checkmark.circle",
                    text: brew.lastChecked == nil ? "Checking…" : "Everything is up to date."
                )
                logView
            }
        } else {
            List(brew.outdated) { package in
                HStack {
                    Image(systemName: package.isCask ? "app.badge" : "terminal")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(package.name).font(.system(size: 12.5))
                        Text(package.isCask ? "App (cask)" : "Formula")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(package.installed) → \(package.latest)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if package.pinned {
                        Image(systemName: "pin.fill").foregroundStyle(.secondary).help("Pinned")
                    }
                    Button("Update") { brew.upgrade([package]) }
                        .buttonStyle(.borderless)
                        .disabled(package.pinned)
                }
            }
            .listStyle(.inset)

            HStack {
                Text("Apps installed with an installer package may ask for a password; "
                    + "run those from Terminal with brew upgrade.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Update All") { brew.upgrade() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var logView: some View {
        if !brew.log.isEmpty {
            ScrollView {
                Text(brew.log)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(.horizontal, 12)
        }
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
            ToolsHeader(
                title: "Ports",
                detail: "Programs listening for connections on this Mac. Stop one to free its port."
            ) {
                HStack {
                    TextField("Port or name", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
            }

            if model.isLoading, model.ports.isEmpty {
                ToolsPlaceholder(symbol: "network", text: "Listing ports…", busy: true)
            } else if model.filtered.isEmpty {
                ToolsPlaceholder(symbol: "network",
                                 text: model.query.isEmpty ? "Nothing is listening." : "No match.")
            } else {
                List(model.filtered) { port in
                    HStack(spacing: 10) {
                        Text(String(port.port))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(port.command).font(.system(size: 12.5))
                            Text("PID \(port.pid) · \(port.user) · "
                                + (port.isLocalOnly ? "this Mac only" : "reachable on the network (\(port.address))"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Stop") { model.stop(port) }
                            .buttonStyle(.borderless)
                    }
                }
                .listStyle(.inset)
            }

            if let message = model.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .onAppear { model.refresh() }
    }
}
