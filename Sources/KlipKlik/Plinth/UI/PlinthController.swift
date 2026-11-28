import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Plinth, end to end: watches for Finder in front, docks the bar under its
/// window, owns ⌥⌘K, and hands requests to the bar's model.
///
/// Nothing runs while Finder is in the background or the feature is off —
/// no tracker, no hot key, no panel on screen — so Plinth costs nothing until
/// it is looked at.
@MainActor
final class PlinthController: NSObject, NSWindowDelegate {
    private let settings = PlinthSettings.shared
    private let model = PlinthBarModel()
    private let tracker = FinderWindowTracker()
    /// Built the first time it is needed.
    private var panel: PlinthPanel?
    private var hosting: NSHostingView<PlinthBarView>?
    private var hotKey: CarbonHotKey?
    private var finderIsFrontmost = false
    /// In ⌥⌘K mode: the bar was asked for and has not been dismissed.
    private var summoned = false
    private var observers: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var layoutPending = false

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.frontmostChanged(isFinder: app?.bundleIdentifier == FinderWindowTracker.finderBundleID)
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tracker.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleLayout() }
        })

        // The tracker and Combine call back on the main thread; these say so
        // to the compiler.
        tracker.onChange = { [weak self] _ in MainActor.assumeIsolated { self?.updateVisibility() } }
        model.onDone = { [weak self] in self?.returnKeyboardToFinder() }
        model.objectWillChange
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleLayout() } }
            .store(in: &cancellables)

        settings.$enabled.combineLatest(settings.$presence)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.summoned = false
                    self?.evaluate()
                }
            }
            .store(in: &cancellables)

        finderIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == FinderWindowTracker.finderBundleID
        evaluate()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        cancellables = []
        tracker.stop()
        hotKey = nil
        panel?.orderOut(nil)
    }

    // MARK: When the bar is there

    private func frontmostChanged(isFinder: Bool) {
        guard isFinder != finderIsFrontmost else { return }
        finderIsFrontmost = isFinder
        if !isFinder { summoned = false }
        evaluate()
    }

    /// Starts or stops everything for the current app and settings.
    private func evaluate() {
        if settings.enabled, finderIsFrontmost {
            tracker.start()
            if hotKey == nil {
                // Held only while Finder is in front, like the Finder keys in
                // FinderExtras, so no other app ever loses ⌥⌘K.
                hotKey = CarbonHotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey)) {
                    [weak self] in
                    MainActor.assumeIsolated { self?.toggleFocus() }
                }
            }
        } else {
            tracker.stop()
            hotKey = nil
        }
        updateVisibility()
    }

    private var wantsBar: Bool {
        settings.enabled && finderIsFrontmost && tracker.frame != nil
            && (settings.presence == .always || summoned || model.isBusy)
    }

    private func updateVisibility() {
        guard wantsBar else {
            panel?.orderOut(nil)
            return
        }
        let panel = makePanelIfNeeded()
        layout()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func toggleFocus() {
        if let panel, panel.isKeyWindow {
            returnKeyboardToFinder()
            return
        }
        summoned = true
        updateVisibility()
        guard let panel, panel.isVisible else { return }
        // Key without activating KlipKlik: the panel is non-activating, so
        // Finder stays the frontmost app and the bar stays docked.
        panel.makeKeyAndOrderFront(nil)
    }

    /// esc on an empty bar, or ⌥⌘K again.
    private func returnKeyboardToFinder() {
        guard let panel else { return }
        if settings.presence == .onShortcut, !model.isBusy {
            summoned = false
            panel.orderOut(nil)
        } else {
            // Out and back in front drops key status, so Finder's window
            // takes the keyboard again.
            panel.orderOut(nil)
            if wantsBar { panel.orderFrontRegardless() }
        }
        PlinthBarModel.bringFinderForward()
    }

    // MARK: Panel

    private func makePanelIfNeeded() -> PlinthPanel {
        if let panel { return panel }
        let panel = PlinthPanel()
        let hosting = NSHostingView(rootView: PlinthBarView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private func scheduleLayout() {
        guard !layoutPending else { return }
        layoutPending = true
        // After SwiftUI has applied the change that triggered this.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.layoutPending = false
                self?.updateVisibility()
            }
        }
    }

    /// Width from the Finder window, height from the bar's content, place
    /// from `PlinthPlacement`.
    private func layout() {
        guard let panel, let hosting, let window = tracker.frame else { return }
        let screens = NSScreen.screens
        // The first screen is the one with the menu bar, which Cocoa's
        // coordinates are measured from.
        let mainHeight = screens.first?.frame.height ?? window.maxY
        let visible = screens.map(\.visibleFrame)

        let width = PlinthPlacement.frame(below: window, height: 40, mainDisplayHeight: mainHeight,
                                          visibleFrames: visible).width
        if abs(model.width - width) > 0.5 { model.width = width }
        hosting.layoutSubtreeIfNeeded()
        let height = max(40, hosting.fittingSize.height)
        let frame = PlinthPlacement.frame(below: window, height: height, mainDisplayHeight: mainHeight,
                                          visibleFrames: visible)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    // MARK: NSWindowDelegate

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated { model.didFocus() }
    }
}
