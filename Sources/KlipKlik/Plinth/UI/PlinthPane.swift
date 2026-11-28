import AppKit
import SwiftUI

/// The Plinth page in the KlipKlik window: on or off, when the bar shows,
/// and what it needs — Apple Intelligence, ffmpeg, permission to ask Finder.
struct PlinthPane: View {
    @ObservedObject private var settings = PlinthSettings.shared
    @ObservedObject private var permissions = PermissionStatus.shared
    @State private var availability: PlinthModelAvailability = .available
    @State private var hasFFmpeg = FFmpeg.isInstalled

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.enabled) {
                    Text("Command bar under Finder")
                    Text("Type what to do with the selected files: “convert to mp4 at 720p”, "
                        + "“resize to 50%”, “rename to trip-{n}”. Nothing runs before you see it.")
                }
                Picker("Show it", selection: $settings.presence) {
                    ForEach(PlinthPresence.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.enabled)
                Toggle(isOn: $settings.selectResults) {
                    Text("Select the results in Finder")
                    Text("When a request finishes, its new files are selected, ready for the next one.")
                }
                .disabled(!settings.enabled)
            } header: {
                Text("Plinth")
            } footer: {
                Text("⌥⌘K in Finder puts the cursor in the bar. Zip, JPG, PNG and PDF work instantly, without AI.")
                    .foregroundStyle(.secondary)
            }

            Section("What it needs") {
                LabeledContent {
                    status(availability == .available)
                } label: {
                    Text("Apple Intelligence")
                    Text(modelDetail)
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        status(hasFFmpeg)
                        if !hasFFmpeg {
                            Button("Install…") {
                                PlinthToolInstaller.offer(.ffmpeg) { _ in hasFFmpeg = FFmpeg.isInstalled }
                            }
                        }
                    }
                } label: {
                    Text("ffmpeg")
                    Text("For video and audio. Images, zips, renames and PDFs use what macOS has.")
                }
                LabeledContent {
                    Button("Open Settings…") { FinderScript.openAutomationSettings() }
                } label: {
                    Text("Talking to Finder")
                    Text("Plinth reads Finder's selection. macOS asks once; if you said no, "
                        + "turn Finder on for KlipKlik under Automation.")
                }
                LabeledContent {
                    PermissionBadge(granted: permissions.isTrusted)
                } label: {
                    Text("Accessibility (optional)")
                    Text("Lets the bar follow a moving Finder window instantly instead of a moment later.")
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private var modelDetail: String {
        switch availability {
        case .available: return "On this Mac, on device. Used only for requests that aren't instant."
        case .unavailable(let reason): return reason
        }
    }

    private func refresh() {
        availability = PlinthModel.availability
        hasFFmpeg = FFmpeg.isInstalled
    }

    private func status(_ ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? .green : .secondary)
    }
}
