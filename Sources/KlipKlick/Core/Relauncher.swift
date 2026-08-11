import AppKit

/// Quits KlipKlick and opens it again.
///
/// A permission granted while the app is running does not reach the parts that
/// need it. The global event monitors, the Carbon hot keys and the event taps
/// are all claimed at launch, and macOS only hands them to a process that was
/// already trusted when it asked — so re-checking `AXIsProcessTrusted` in place
/// reports the new answer while the features stay dead. The process has to
/// start over.
enum Relauncher {
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to actually exit before reopening. Launching
        // first would leave two instances briefly, each registering the same
        // hot keys and putting up its own menu bar item — and macOS may simply
        // reactivate the running copy instead of starting a new one.
        //
        // The pid and path go in as positional arguments so no quoting of the
        // bundle path is needed.
        task.arguments = [
            "-c",
            #"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open "$2""#,
            "sh",
            String(pid),
            path
        ]

        do {
            try task.run()
        } catch {
            // Nothing sensible to fall back on — leave the app running rather
            // than quitting into nothing.
            return
        }

        NSApp.terminate(nil)
    }
}
