import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Small Finder conveniences, all active only while Finder is frontmost:
///
/// * **F2** starts renaming the selection, as on Windows. Finder's own key for
///   that is Return, so F2 is answered by posting one.
/// * **⌘V with a picture on the clipboard** writes it into the front folder as
///   a PNG. Finder can only paste files, so without this the keystroke just
///   beeps — taking it over loses nothing.
/// * **⇧⌥⌘S** sends the Finder selection to a shelf.
///
/// The keys are Carbon hot keys, held only while Finder is in front, so no
/// other app ever loses F2, ⌘V or ⇧⌥⌘S.
final class FinderExtras {
    private static let finderBundleID = "com.apple.finder"
    private static let routerOwner = "finderImagePaste"

    /// Hands the selection to the shelves.
    var onAddToShelf: (([URL]) -> Void)?

    private var renameHotKey: CarbonHotKey?
    private var shelfHotKey: CarbonHotKey?
    private var claimsPaste = false
    private var finderIsFrontmost = false
    private var observer: Any?
    /// The Automation explanation is shown once per launch, not on every ⌘V.
    private var explainedAutomation = false

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.finderIsFrontmost = app?.bundleIdentifier == Self.finderBundleID
            self?.update()
        }
        finderIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == Self.finderBundleID
        update()
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        finderIsFrontmost = false
        update()
    }

    /// Re-evaluates every key. Called on app switches, settings changes and
    /// clipboard changes — the last decides whether ⌘V is worth claiming.
    func update() {
        let settings = Settings.shared

        if finderIsFrontmost, settings.finderRenameKey {
            if renameHotKey == nil {
                renameHotKey = CarbonHotKey(keyCode: UInt32(kVK_F2), modifiers: 0) { [weak self] in
                    self?.rename()
                }
            }
        } else {
            renameHotKey = nil
        }

        if finderIsFrontmost, settings.shelvesEnabled {
            if shelfHotKey == nil {
                shelfHotKey = CarbonHotKey(
                    keyCode: UInt32(kVK_ANSI_S),
                    modifiers: UInt32(cmdKey | optionKey | shiftKey)
                ) { [weak self] in
                    self?.sendSelectionToShelf()
                }
            }
        } else {
            shelfHotKey = nil
        }

        let wantsPaste = finderIsFrontmost && settings.finderPasteImage
            && AccessibilityPermission.isTrusted && Self.clipboardHoldsOnlyAPicture()
        if wantsPaste, !claimsPaste {
            claimsPaste = true
            PasteKeyRouter.shared.claim(Self.routerOwner, priority: .finderImage) { [weak self] in
                self?.pasteImage()
            }
        } else if !wantsPaste, claimsPaste {
            claimsPaste = false
            PasteKeyRouter.shared.release(Self.routerOwner)
        }
    }

    // MARK: F2

    private func rename() {
        // Already editing a name, or in the search field: F2 means nothing
        // there, and a posted Return would commit the edit.
        guard !Self.focusedElementIsTextInput() else { return }
        Paster.send(keyCode: CGKeyCode(kVK_Return), flags: [])
    }

    // MARK: ⌘V a picture

    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("public.heic")
    ]

    /// A picture with no file behind it. A copied *file* (an image in Finder)
    /// carries a file URL, and Finder pastes that perfectly well itself.
    private static func clipboardHoldsOnlyAPicture() -> Bool {
        let types = NSPasteboard.general.types ?? []
        return !types.contains(.fileURL) && types.contains(where: imageTypes.contains)
    }

    private func pasteImage() {
        // The rename field or the search box: a normal paste, untouched.
        guard !Self.focusedElementIsTextInput(),
              let png = Self.clipboardPNG()
        else {
            Paster.paste()
            return
        }

        FinderScript.insertionFolder { [weak self] result in
            switch result {
            case .success(let folder):
                Self.write(png, into: folder)
            case .failure(.notPermitted):
                self?.explainAutomation()
            case .failure:
                NSSound.beep()
            }
        }
    }

    /// The clipboard picture as PNG bytes, converting when it arrived as TIFF,
    /// JPEG or anything else `NSImage` can read.
    private static func clipboardPNG() -> Data? {
        let pasteboard = NSPasteboard.general
        if let png = pasteboard.data(forType: .png) { return png }
        for type in imageTypes {
            guard let data = pasteboard.data(forType: type),
                  let bitmap = NSBitmapImageRep(data: data)
            else { continue }
            return bitmap.representation(using: .png, properties: [:])
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    /// "Pasted Image 2026-11-23 at 18.04.11.png", numbered if that is taken.
    private static func write(_ png: Data, into folder: URL) {
        let base = "Pasted Image \(nameFormatter.string(from: Date()))"
        var url = folder.appendingPathComponent(base + ".png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(counter).png")
            counter += 1
        }
        do {
            try png.write(to: url, options: .withoutOverwriting)
            FinderScript.reveal(url)
        } catch {
            NSSound.beep()
        }
    }

    private func explainAutomation() {
        guard !explainedAutomation else { return }
        explainedAutomation = true
        let alert = NSAlert()
        alert.messageText = "KlipKlik needs to ask Finder what is open"
        alert.informativeText = "Pasting a picture as a file, and sending Finder's selection to "
            + "a shelf, need Automation permission for Finder. Turn on Finder under KlipKlik in "
            + "System Settings ▸ Privacy & Security ▸ Automation, then try again."
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Later")
        if FloatingAlert.run(alert) == .alertFirstButtonReturn {
            FinderScript.openAutomationSettings()
        }
    }

    // MARK: Selection to shelf

    private func sendSelectionToShelf() {
        FinderScript.selection { [weak self] result in
            switch result {
            case .success(let urls) where !urls.isEmpty:
                self?.onAddToShelf?(urls)
            case .failure(.notPermitted):
                self?.explainAutomation()
            default:
                NSSound.beep()
            }
        }
    }

    // MARK: Helpers

    /// Same check as cut-and-move: is the keyboard in a text field right now?
    private static func focusedElementIsTextInput() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success,
            let focusedValue = focused,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return false }

        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let roleName = role as? String
        else { return false }

        return roleName == kAXTextFieldRole || roleName == kAXTextAreaRole
    }
}
