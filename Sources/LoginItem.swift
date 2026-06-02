import Foundation

/// "Launch at Login" implemented with a per-user LaunchAgent plist. This works
/// across macOS versions and survives reboot. We only manage the plist file;
/// launchd starts the app at the next login (we deliberately don't bootstrap a
/// second copy while one is already running).
enum LoginItem {
    static let label = "eu.smeingast.claude-menubar-usage"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    /// If launch-at-login is enabled, rewrite the plist to point at the app's
    /// current location. This self-heals after the .app is moved (e.g. from the
    /// build folder to /Applications).
    static func syncIfEnabled() {
        if isEnabled { enable() }
    }

    /// On the very first launch, enable the login item once (per the user's
    /// chosen default). After that, respect whatever the user toggles.
    static func enableOnFirstLaunchIfNeeded() {
        let key = "didApplyDefaultLoginItem"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        if !isEnabled { enable() }
    }

    private static func executablePath() -> String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    private static func enable() {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath()],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            NSLog("ClaudeUsage: failed to write login item: \(error)")
        }
    }

    private static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
