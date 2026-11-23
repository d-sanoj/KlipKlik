import AppKit
import SwiftUI

/// A small panel in the corner of the screen listing conversions in flight:
/// a bar while each one runs, then the finished file to open or show, or why
/// it failed. Goes away by itself once the last one has been seen.
final class ConversionPanel {
    static let shared = ConversionPanel()

    private let panel: NSPanel

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let hosting = NSHostingView(rootView: ConversionPanelView(center: .shared))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
    }

    func showIfNeeded() {
        guard !panel.isVisible else { return }
        place()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Bottom-right of the screen with the pointer, above the Dock.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.maxX - 340, y: visible.minY + 20))
    }
}

private struct ConversionPanelView: View {
    @ObservedObject var center: ConversionCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(center.jobs) { job in row(job) }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
    }

    @ViewBuilder
    private func row(_ job: ConversionCenter.Job) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                icon(for: job.state)
                Text(job.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    center.dismiss(job.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            switch job.state {
            case .running(let fraction):
                if let fraction {
                    ProgressView(value: fraction).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
            case .done(let url):
                HStack(spacing: 10) {
                    Text(url.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.borderless).font(.caption)
                    Button("Open") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderless).font(.caption)
                }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private func icon(for state: ConversionCenter.Job.State) -> some View {
        switch state {
        case .running: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
