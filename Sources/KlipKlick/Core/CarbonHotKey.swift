import AppKit
import Carbon.HIToolbox

/// A system-wide hot key registered through Carbon's `RegisterEventHotKey`.
///
/// Unlike `NSEvent` keyboard monitoring, this requires no Accessibility
/// permission, so it works the moment the app launches. It's the secondary
/// trigger that keeps KlipKlick reachable before permission is granted —
/// double-tap ⌘ is the primary one.
final class CarbonHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4B4C4B4B  // 'KLKK'

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: a `kVK_*` virtual key code.
    ///   - modifiers: Carbon modifier mask (`cmdKey`, `shiftKey`, ...).
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()

        id = Self.nextID
        Self.nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else { return nil }
        hotKeyRef = ref
        Self.handlers[id] = handler
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The callback is a C function pointer, so it can capture nothing —
        // it looks the handler up by id instead.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == CarbonHotKey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                CarbonHotKey.handlers[hotKeyID.id]?()
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }
}
