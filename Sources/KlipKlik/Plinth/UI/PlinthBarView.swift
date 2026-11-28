import AppKit
import SwiftUI

/// The bar itself: a field, the selection, and below it whatever the request
/// has become — a preview to approve, a message, or progress.
struct PlinthBarView: View {
    @ObservedObject var model: PlinthBarModel
    @FocusState private var fieldFocused: Bool

    private let corner: CGFloat = 14
    private static let maxEffectRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            detail
        }
        .frame(width: model.width, alignment: .leading)
        .background(LiquidGlassBackground(style: .regular, cornerRadius: corner, fallbackMaterial: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .onExitCommand { model.escape() }
        // ⌥⌘K, or a click anywhere on the bar, puts the cursor in the field.
        .onReceive(model.focusRequests) { _ in fieldFocused = true }
    }

    // MARK: Field

    private var inputRow: some View {
        HStack(spacing: 8) {
            Group {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)

            TextField("Convert, resize, compress, zip, rename…", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($fieldFocused)
                .onSubmit { model.submit() }
                .disabled(model.isBusy)

            if model.text.isEmpty, case .idle = model.phase {
                ForEach(PlinthInstantActions.chips, id: \.self) { chip in
                    Button(chip.uppercased()) { model.submit(chip) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.quaternary))
                        .help("Instant: no AI needed")
                }
            }

            if let label = model.selectionLabel {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    // MARK: Below the field

    @ViewBuilder
    private var detail: some View {
        switch model.phase {
        case .idle:
            if case .unavailable(let reason) = model.availability {
                note(reason, symbol: "info.circle", tint: .secondary)
            }
        case .working(let status):
            note(status, symbol: "hourglass", tint: .secondary)
        case .preview(let plan):
            preview(plan, confirming: false)
        case .confirming(let plan):
            preview(plan, confirming: true)
        case .running(let plan):
            divided {
                HStack {
                    Text(plan.title).font(.callout).lineLimit(1)
                    Spacer()
                    Button("Stop") { model.stop() }
                }
            }
        case .message(let text, let isError):
            note(text,
                 symbol: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                 tint: isError ? .orange : .green)
        }
    }

    private func preview(_ plan: PlinthPlan, confirming: Bool) -> some View {
        divided {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.title).font(.system(size: 13, weight: .semibold))

                ForEach(Array(plan.effects.prefix(Self.maxEffectRows).enumerated()), id: \.offset) { _, effect in
                    effectRow(effect)
                }
                if plan.effects.count > Self.maxEffectRows {
                    Text("and \(plan.effects.count - Self.maxEffectRows) more")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !plan.skipped.isEmpty {
                    Text("Skipping \(plan.skipped.count) item\(plan.skipped.count == 1 ? "" : "s") this doesn't apply to.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !plan.missingTools.isEmpty {
                    Label("Needs \(plan.missingTools.map(\.rawValue).joined(separator: ", ")), "
                          + "which isn't installed yet.", systemImage: "shippingbox")
                        .font(.caption).foregroundStyle(.orange)
                }

                DisclosureGroup("Commands") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(plan.steps.prefix(4).enumerated()), id: \.offset) { _, step in
                            Text(step.displayString)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        if plan.steps.count > 4 {
                            Text("and \(plan.steps.count - 4) more like these")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)

                if confirming {
                    Text(confirmation(for: plan))
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { model.escape() }
                    runButton(plan, confirming: confirming)
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func runButton(_ plan: PlinthPlan, confirming: Bool) -> some View {
        if !plan.missingTools.isEmpty {
            Button("Install \(plan.missingTools[0].rawValue)…") { model.run() }
                .keyboardShortcut(.defaultAction)
        } else if confirming {
            // The second yes is ⌘↩ or a click, never a bare ↩, so a double
            // press of Return cannot rename or trash anything.
            Button(destructiveTitle(for: plan), role: .destructive) { model.run() }
                .keyboardShortcut(.return, modifiers: .command)
                .tint(.red)
        } else if plan.isDestructive {
            Button("Review…") { model.run() }
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Run") { model.run() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func effectRow(_ effect: PlinthEffect) -> some View {
        HStack(spacing: 6) {
            switch effect.kind {
            case .create:
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                Text(effect.url.lastPathComponent)
            case .rename(let from):
                Image(systemName: "pencil.circle.fill").foregroundStyle(.blue)
                Text(from.lastPathComponent).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text(effect.url.lastPathComponent)
            case .trash:
                Image(systemName: "trash.circle.fill").foregroundStyle(.red)
                Text(effect.url.lastPathComponent).strikethrough()
            }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func destructiveTitle(for plan: PlinthPlan) -> String {
        let renames = plan.effects.filter { if case .rename = $0.kind { return true } else { return false } }.count
        let trashed = plan.effects.filter { $0.kind == .trash }.count
        if renames > 0 { return "Rename \(renames) Item\(renames == 1 ? "" : "s")" }
        return "Move \(trashed) Original\(trashed == 1 ? "" : "s") to Trash"
    }

    private func confirmation(for plan: PlinthPlan) -> String {
        let trashed = plan.effects.filter { $0.kind == .trash }.count
        if trashed > 0 {
            return "The originals go to the Trash once the new files are written. Press ⌘↩ to go ahead."
        }
        return "This changes the names of the files themselves. Press ⌘↩ to go ahead."
    }

    // MARK: Pieces

    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        divided {
            Label {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
        }
    }

    private func divided<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.5)
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }
}

/// The panel the bar lives in: borderless and non-activating, so typing in
/// it never takes Finder out of the front — which is what keeps the bar
/// docked while you use it.
final class PlinthPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PlinthPlacement.minWidth, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
    }
}
