import AppKit
import Combine

/// Copy several things, then paste them back one ⌘V at a time, in the order
/// they were copied.
///
/// While the stack is on, every copy that reaches history is also queued here.
/// Once something is queued, ⌘V is claimed through `PasteKeyRouter`: each press
/// puts the oldest queued item on the clipboard and lets the paste through.
/// The stack switches itself off when the last item has been pasted.
///
/// ⌘V is never claimed without Accessibility. Posting the paste back to the
/// app needs it, and holding the key without being able to post would swallow
/// every paste.
final class PasteStack: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var queue: [ClipboardItem] = []

    /// Reports pasteboard writes, so the monitor does not record a queued item
    /// coming back as a new copy.
    var onDidWriteToPasteboard: ((Int) -> Void)?

    private let store: HistoryStore
    private static let routerOwner = "pasteStack"
    private var claimed = false

    init(store: HistoryStore) {
        self.store = store
    }

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        queue = []
        isActive = true
    }

    func stop() {
        isActive = false
        queue = []
        updateClaim()
    }

    /// A new copy, from `ClipboardMonitor`.
    func collect(_ item: ClipboardItem) {
        guard isActive else { return }
        queue.append(item)
        updateClaim()
    }

    private func updateClaim() {
        let wanted = isActive && !queue.isEmpty && AccessibilityPermission.isTrusted
        if wanted, !claimed {
            claimed = true
            PasteKeyRouter.shared.claim(Self.routerOwner, priority: .pasteStack) { [weak self] in
                self?.pasteNext()
            }
        } else if !wanted, claimed {
            claimed = false
            PasteKeyRouter.shared.release(Self.routerOwner)
        }
    }

    private func pasteNext() {
        guard isActive, !queue.isEmpty else {
            updateClaim()
            Paster.paste()
            return
        }

        let next = store.materialized(queue.removeFirst())
        let changeCount = next.write(to: .general, plainTextOnly: Settings.shared.stripFormatting)
        onDidWriteToPasteboard?(changeCount)
        Paster.paste()

        if queue.isEmpty {
            // Done. Released after the paste has gone through, so the last ⌘V
            // is not caught twice.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, queue.isEmpty else { return }
                stop()
            }
        }
    }
}
