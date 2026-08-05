import AppKit

/// Force-clears history once per day at a fixed local hour (5 AM by default).
///
/// A plain `Timer` is not enough: it does not fire while the machine is asleep,
/// and a Mac closed overnight would sail past 5 AM untouched. So instead of
/// relying on the timer firing at the right moment, every check recomputes the
/// most recent boundary that has passed and clears if we haven't cleared for it
/// yet. Waking from sleep triggers a check, which is what catches the overnight case.
final class DailyPurge {
    private let store: HistoryStore
    private let calendar = Calendar.current
    private var timer: Timer?
    /// The most recent purge boundary already accounted for.
    private var lastHandledBoundary: Date

    /// Safety net in case both the timer and the wake notification are missed.
    private let sweepInterval: TimeInterval = 300

    init(store: HistoryStore) {
        self.store = store
        // Treat the boundary before launch as already handled — the app starts
        // with an empty history anyway, so there is nothing to clear for it.
        self.lastHandledBoundary = Self.mostRecentBoundary(
            atOrBefore: Date(),
            hour: Settings.shared.purgeHour,
            calendar: calendar
        )
    }

    func start() {
        let timer = Timer(timeInterval: sweepInterval, repeats: true) { [weak self] _ in
            self?.checkAndPurge()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func systemDidWake() {
        checkAndPurge()
    }

    /// Also worth calling right before showing the popup, so the user never sees
    /// entries that should already have been purged.
    func checkAndPurge() {
        let boundary = Self.mostRecentBoundary(
            atOrBefore: Date(),
            hour: Settings.shared.purgeHour,
            calendar: calendar
        )
        guard boundary > lastHandledBoundary else { return }
        lastHandledBoundary = boundary
        // A force-clear, so it takes pinned items too — unlike the footer's
        // "Clear History", which deliberately keeps them.
        store.clearAll()
    }

    /// The latest occurrence of `hour:00` local time at or before `date`.
    static func mostRecentBoundary(atOrBefore date: Date, hour: Int, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = 0
        components.second = 0

        guard let todayBoundary = calendar.date(from: components) else { return date }
        if todayBoundary <= date { return todayBoundary }
        // Before this morning's boundary — the last one was yesterday.
        return calendar.date(byAdding: .day, value: -1, to: todayBoundary) ?? todayBoundary
    }
}
