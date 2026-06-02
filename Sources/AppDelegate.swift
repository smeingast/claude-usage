import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Poll cadence. The data changes slowly and the endpoint is rate-limited,
    // so a gentle interval keeps things light and avoids 429s.
    private let refreshInterval: TimeInterval = 120
    // Don't refetch more often than this (guards rapid menu opens / wakes).
    private let minFetchGap: TimeInterval = 20
    // Back off this long after the server rate-limits us (HTTP 429).
    private let rateLimitCooldown: TimeInterval = 120

    // Color thresholds (percent) for the menu bar text.
    private let warnAt = 70.0
    private let dangerAt = 90.0

    private let client = UsageClient()
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private var isFetching = false
    private var lastFetchAt = Date.distantPast
    private var cooldownUntil = Date.distantPast

    private var snapshot: UsageSnapshot?
    private var lastError: String?

    // Menu rows we mutate as data arrives.
    private let fiveHourItem = NSMenuItem()
    private let weeklyItem = NSMenuItem()
    private let opusItem = NSMenuItem()
    private let sonnetItem = NSMenuItem()
    private let statusLine = NSMenuItem()
    private let loginToggle = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let dockToggle = NSMenuItem(title: "Show Dock Icon", action: nil, keyEquivalent: "")

    private let barFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = barFont
        renderBar()                       // shows "…" until first fetch
        buildMenu()

        applyDockVisibility()             // honor saved preference (default: no Dock icon)
        LoginItem.enableOnFirstLaunchIfNeeded()
        LoginItem.syncIfEnabled()         // keep login-item path current if app moved
        refreshLoginToggle()

        // Refresh when the Mac wakes from sleep so numbers aren't stale.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        startTimer()
        refreshNow()
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false       // keep info rows full-color & readable
        menu.delegate = self

        for item in [fiveHourItem, weeklyItem, opusItem, sonnetItem] {
            item.isEnabled = false          // informational rows
            menu.addItem(item)
        }
        opusItem.isHidden = true
        sonnetItem.isHidden = true

        menu.addItem(.separator())

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        addAction(to: menu, title: "Refresh Now", key: "r", action: #selector(refreshNow))

        loginToggle.action = #selector(toggleLoginItem)
        loginToggle.target = self
        menu.addItem(loginToggle)

        dockToggle.action = #selector(toggleDockIcon)
        dockToggle.target = self
        menu.addItem(dockToggle)

        menu.addItem(.separator())
        addAction(to: menu, title: "Quit Claude Usage", key: "q", action: #selector(NSApplication.terminate(_:)))

        statusItem.menu = menu
    }

    private func addAction(to menu: NSMenu, title: String, key: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshNow()                        // freshen on open (gated by minFetchGap)
    }

    // MARK: - Fetching

    private func startTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        t.tolerance = 15                    // let the OS coalesce wakeups
        timer = t
    }

    @objc private func systemDidWake() { refreshNow() }

    @objc private func refreshNow() {
        let now = Date()
        guard !isFetching,
              now >= cooldownUntil,
              now >= lastFetchAt.addingTimeInterval(minFetchGap) else { return }

        isFetching = true
        lastFetchAt = now
        Task { @MainActor in
            defer { isFetching = false }
            do {
                snapshot = try await client.fetch()
                lastError = nil
            } catch let e as UsageError {
                lastError = e.description
                if case .http(429) = e { cooldownUntil = Date().addingTimeInterval(rateLimitCooldown) }
            } catch {
                lastError = (error as CustomStringConvertible).description
            }
            renderBar()
            renderMenu()
        }
    }

    // MARK: - Rendering

    private func renderBar() {
        guard let button = statusItem.button else { return }

        guard let snap = snapshot else {
            // No data yet: show a placeholder, or a warning glyph if we failed.
            let text = lastError == nil ? "…" : "⚠"
            button.attributedTitle = attributed(text, color: lastError == nil ? nil : .systemRed)
            button.toolTip = lastError
            return
        }

        let five = snap.fiveHour?.utilization
        let week = snap.sevenDay?.utilization
        let text = "\(percent(five)) / \(percent(week))"
        let worst = max(five ?? 0, week ?? 0)
        button.attributedTitle = attributed(text, color: color(for: worst))
        button.toolTip = tooltip(snap)
    }

    private func renderMenu() {
        if let snap = snapshot {
            fiveHourItem.title = row("5-hour limit", snap.fiveHour, weekly: false)
            weeklyItem.title = row("Weekly limit", snap.sevenDay, weekly: true)
            configureModelRow(opusItem, label: "Weekly · Opus", snap.sevenDayOpus)
            configureModelRow(sonnetItem, label: "Weekly · Sonnet", snap.sevenDaySonnet)

            let f = DateFormatter(); f.dateFormat = "HH:mm"
            statusLine.title = lastError == nil
                ? "Updated \(f.string(from: snap.fetchedAt))"
                : "Stale — \(lastError!)"
        } else {
            fiveHourItem.title = "5-hour limit — …"
            weeklyItem.title = "Weekly limit — …"
            statusLine.title = lastError ?? "Loading…"
        }
    }

    /// Model-specific weekly caps only appear when actually in use.
    private func configureModelRow(_ item: NSMenuItem, label: String, _ window: LimitWindow?) {
        if let window, window.utilization > 0 {
            item.isHidden = false
            item.title = row(label, window, weekly: true)
        } else {
            item.isHidden = true
        }
    }

    private func row(_ label: String, _ window: LimitWindow?, weekly: Bool) -> String {
        guard let window else { return "\(label) — —" }
        var s = "\(label) — \(percent(window.utilization))"
        if let reset = resetText(window.resetsAt, weekly: weekly) { s += "  ·  \(reset)" }
        return s
    }

    // MARK: - Toggles

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        refreshLoginToggle()
    }

    private func refreshLoginToggle() {
        loginToggle.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func toggleDockIcon() {
        let show = !UserDefaults.standard.bool(forKey: "showDockIcon")
        UserDefaults.standard.set(show, forKey: "showDockIcon")
        applyDockVisibility()
    }

    private func applyDockVisibility() {
        let show = UserDefaults.standard.bool(forKey: "showDockIcon")   // default false → menu bar only
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        dockToggle.state = show ? .on : .off
    }

    // MARK: - Formatting helpers

    private func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded()))%"
    }

    private func color(for util: Double) -> NSColor? {
        if util >= dangerAt { return .systemRed }
        if util >= warnAt { return .systemOrange }
        return nil                          // nil = default adaptive menu-bar color
    }

    private func attributed(_ text: String, color: NSColor?) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: barFont]
        if let color { attrs[.foregroundColor] = color }
        return NSAttributedString(string: text, attributes: attrs)
    }

    private func resetText(_ date: Date?, weekly: Bool) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = weekly ? "EEE HH:mm" : "HH:mm"
        return "resets \(f.string(from: date))"
    }

    private func tooltip(_ snap: UsageSnapshot) -> String {
        var lines = ["Claude usage"]
        if let f = snap.fiveHour { lines.append("5-hour: \(percent(f.utilization))") }
        if let w = snap.sevenDay { lines.append("Weekly: \(percent(w.utilization))") }
        if let e = lastError { lines.append("⚠ \(e)") }
        return lines.joined(separator: "\n")
    }
}
