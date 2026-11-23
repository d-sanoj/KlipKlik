import AppKit
import Carbon.HIToolbox

/// The one owner of the ⌘V hot key.
///
/// Three features want to take over ⌘V at times: Finder cut-and-move, the paste
/// stack, and pasting a picture into Finder as a file. Carbon refuses a second
/// registration of a key this process already holds, so if each registered its
/// own, whichever came second would silently fail — a pending Finder cut would
/// stop working the moment a paste stack started. Instead each *claims* ⌘V
/// here, and the highest-priority claim gets the keystroke.
///
/// The key is held only while someone has a claim. With no claims — the normal
/// state — ⌘V reaches apps untouched, exactly as before this existed.
final class PasteKeyRouter {
    static let shared = PasteKeyRouter()

    enum Priority: Int {
        case pasteStack = 10
        case finderImage = 50
        case finderCutMove = 100
    }

    private struct Claim {
        let priority: Priority
        let handler: () -> Void
    }

    private var claims: [String: Claim] = [:]
    private var hotKey: CarbonHotKey?
    /// Raised while a ⌘V of our own is in flight, so it is not caught by the
    /// very key it was posted to stand in for.
    private var suspensions = 0

    private init() {}

    func claim(_ owner: String, priority: Priority, handler: @escaping () -> Void) {
        claims[owner] = Claim(priority: priority, handler: handler)
        update()
    }

    func release(_ owner: String) {
        guard claims.removeValue(forKey: owner) != nil else { return }
        update()
    }

    /// Runs `post` with the hot key released, then takes it back once the
    /// posted keystroke has had time to land.
    func passThrough(_ post: @escaping () -> Void) {
        suspensions += 1
        update()
        // A process-wide singleton, so there is no cycle to guard against.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            post()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.suspensions = max(0, self.suspensions - 1)
                self.update()
            }
        }
    }

    private func update() {
        let wanted = !claims.isEmpty && suspensions == 0
        if wanted, hotKey == nil {
            hotKey = CarbonHotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey)) { [weak self] in
                self?.fire()
            }
        } else if !wanted {
            hotKey = nil
        }
    }

    private func fire() {
        guard let claim = claims.values.max(by: { $0.priority.rawValue < $1.priority.rawValue })
        else {
            // Claims went away between the press and now: hand ⌘V back.
            Paster.paste()
            return
        }
        claim.handler()
    }
}
