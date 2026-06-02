import AppKit

// Top-level entry runs on the main thread; assert main-actor isolation so we can
// touch AppKit and our @MainActor AppDelegate.
MainActor.assumeIsolated {
    // Single-instance guard: if another copy is already running (e.g. launched at
    // login and then opened again from Finder), bow out quietly.
    if let bundleID = Bundle.main.bundleIdentifier {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty { exit(0) }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu-bar only — no Dock icon
    app.run()
}
