import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Poll cadence. The data changes slowly and the endpoint is rate-limited,
    // so a gentle interval keeps things light and avoids 429s. We also refresh
    // on menu-open and wake, so the number is fresh whenever you actually look.
    private let refreshInterval: TimeInterval = 300
    // Don't refetch more often than this (guards rapid menu opens / wakes).
    private let minFetchGap: TimeInterval = 20
    // Back off this long after the server rate-limits us (HTTP 429).
    private let rateLimitCooldown: TimeInterval = 300

    private let client = UsageClient()
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    // Light/dark menu-bar tracking. The colored glyph is a non-template NSImage, so
    // AppKit does NOT re-run its drawing handler when the menu bar flips appearance —
    // the dynamic coral would otherwise stay frozen on the old shade until the next
    // fetch. We KVO the button's effectiveAppearance (more precise than NSApp's for a
    // status item) and redraw when the light/dark bucket actually changes.
    private var appearanceObservation: NSKeyValueObservation?
    private var lastIsDark: Bool?

    private var isFetching = false
    private var lastFetchAt = Date.distantPast
    private var cooldownUntil = Date.distantPast

    private var snapshot: ProviderUsageSnapshot?
    private var lastError: String?
    private var needsAuth = false       // true only when the token is rejected
    private var forecast: Forecast?     // recomputed on every panel render

    // Panel rows (custom views) and the remaining text rows.
    private let headerView = PanelHeaderView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width,
                                                           height: PanelHeaderView.height))
    private let headerItem = NSMenuItem()
    private let pillsView = RangeModePillsView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width,
                                                             height: RangeModePillsView.height))
    private let pillsItem = NSMenuItem()
    private let opusItem = NSMenuItem()
    private let sonnetItem = NSMenuItem()
    private let statusLine = NSMenuItem()
    private let loginToggle = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let dockToggle = NSMenuItem(title: "Show Dock Icon", action: nil, keyEquivalent: "")

    // Active local Claude Code sessions (read from ~/.claude). Pre-allocated, hidden
    // menu rows we fill in place — mutating title/isHidden is safe while the menu is
    // open; structurally inserting rows would not be. maxSessionRows caps the display;
    // the header still reports the true count and the last slot absorbs any overflow.
    private static let maxSessionRows = 8
    private let sessionsClient = SessionsClient()
    private var sessions: [SessionInfo] = []
    private var isReadingSessions = false
    private var lastSessionsReadAt = Date.distantPast
    private let sessionsMinGap: TimeInterval = 2
    private let sessionsHeader = NSMenuItem()
    private var sessionRowItems: [NSMenuItem] = []
    private let sessionsSeparator = NSMenuItem.separator()

    // Usage-history graph: a passive custom-view row above the status line, fed from a
    // persisted local sample store. See HistoryStore / HistoryGraphView.
    private let historyStore = HistoryStore()
    private var history: [HistorySample] = []
    private let graphView = HistoryGraphView(frame: NSRect(x: 0, y: 0, width: 360, height: 116))
    private let graphItem = NSMenuItem()
    private let graphSeparator = NSMenuItem.separator()
    private let historyMaxAge: TimeInterval = 32 * 24 * 3600   // 30d largest range + 2d margin
    private let minSampleGap: TimeInterval = 240               // keep the ~5-min grid even when "Refresh Now" bypasses the fetch gate
    private var lastHistoryAppendAt = Date.distantPast
    private var lastDiskTrimAt = Date()                        // launch task trims; recordHistory re-trims ~daily

    private let barFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)

    // Display-time date formatters. Built once and reused: DateFormatter creation is
    // costly, and these run on every menu render. Safe to share — all use is on the
    // main actor. Locale is captured at first use, fine for a login-launched menu-bar
    // app (a mid-session locale change is picked up on the next launch).
    // Templates (not literal formats) so the hour respects the user's 12/24-hour
    // clock preference: "jmm" renders as "HH:mm" or "h:mm a" per locale.
    private static let updatedFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()
    private static let weeklyResetFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEjmm"); return f
    }()
    private static let dailyResetFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()

    func applicationWillTerminate(_ notification: Notification) {
        client.flushPendingWriteBack()   // never leave the Keychain holding a dead pair
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = barFont
        renderBar()                       // shows "…" until first fetch
        buildMenu()
        renderMenu()                      // prime rows with "Loading…" before first fetch

        applyDockVisibility()             // honor saved preference (default: no Dock icon)
        LoginItem.migrateLegacyAgentIfNeeded()   // upgrade pre-SMAppService installs in place
        LoginItem.enableOnFirstLaunchIfNeeded()  // brand-new installs default to launch-at-login
        refreshLoginToggle()

        // Refresh when the Mac wakes from sleep so numbers aren't stale.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // Redraw the glyph when the menu bar switches light/dark (see appearance note
        // above). KVO fires on the main thread; hop to the main actor to be safe.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.appearanceDidChange() }
        }

        // Prime the usage history off the main actor FIRST, so the disk read (fast) sets
        // lastHistoryAppendAt before the network fetch below can record a too-close sample.
        // MERGE (do not overwrite) so a fetch that still lands first is preserved; trim disk.
        let store = historyStore
        let maxAge = historyMaxAge
        Task.detached(priority: .utility) {
            let loaded = store.load(maxAge: maxAge)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.history = self.mergeHistory(loaded, self.history)
                if let last = self.history.last?.t {
                    self.lastHistoryAppendAt = max(self.lastHistoryAppendAt, last)
                }
                self.applyGraphData()
            }
            store.trim(maxAge: maxAge)
        }

        startTimer()
        refreshNow()
        refreshSessions(force: true)
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false       // keep info rows full-color & readable
        menu.delegate = self

        // The instrument panel: header (rings + numbers) and the
        // model-specific weekly text rows (shown only when in use).
        headerItem.isEnabled = false
        headerItem.view = headerView
        menu.addItem(headerItem)
        for item in [opusItem, sonnetItem] {
            item.isEnabled = false
            item.isHidden = true
            menu.addItem(item)
        }

        // Graph card: range/mode pills directly above the (now interactive)
        // graph. Both items stay enabled — a disabled item can gate event
        // delivery to its view, and these views handle their own clicks/hover.
        pillsItem.isEnabled = true
        pillsItem.view = pillsView
        menu.addItem(pillsItem)
        pillsView.onChange = { [weak self] in self?.applyGraphData() }
        graphItem.isEnabled = true
        graphItem.view = graphView
        menu.addItem(graphItem)
        menu.addItem(graphSeparator)

        // Active-sessions section: header + fixed row slots + trailing separator.
        sessionsHeader.isEnabled = false
        sessionsHeader.attributedTitle = Self.sessionsHeaderTitle("Sessions…")
        menu.addItem(sessionsHeader)
        for _ in 0..<Self.maxSessionRows {
            let it = NSMenuItem()
            it.isEnabled = false
            it.isHidden = true
            it.view = SessionRowView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width,
                                                   height: SessionRowView.height))
            sessionRowItems.append(it)
            menu.addItem(it)
        }
        menu.addItem(sessionsSeparator)

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        addAction(to: menu, title: "Refresh Now", key: "r", action: #selector(refreshNowClicked))

        menu.addItem(.separator())

        let styleRoot = NSMenuItem(title: "Display Style", action: nil, keyEquivalent: "")
        styleRoot.submenu = buildStyleMenu()
        menu.addItem(styleRoot)

        let colorRoot = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorRoot.submenu = buildColorMenu()
        menu.addItem(colorRoot)

        loginToggle.action = #selector(toggleLoginItem)
        loginToggle.target = self
        menu.addItem(loginToggle)

        dockToggle.action = #selector(toggleDockIcon)
        dockToggle.target = self
        menu.addItem(dockToggle)

        menu.addItem(.separator())
        // Quit targets NSApp explicitly — terminate(_:) lives on NSApplication, not on
        // us, so the generic addAction (target = self) would silently no-op the click.
        let quit = NSMenuItem(title: "Quit Claude Usage",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private static func sessionsHeaderTitle(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.6,
        ])
    }

    private func addAction(to menu: NSMenu, title: String, key: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    // Lay out the panel and session rows from the in-memory cache *before* the
    // menu is shown, so counts, relative reset times, and the banner height are
    // fresh on every open. The async reads kicked from menuWillOpen only
    // refresh the caches for next time.
    func menuNeedsUpdate(_ menu: NSMenu) {
        renderMenu()            // recomputes forecast + state; includes applyGraphData()
        renderSessions()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshNow()                        // freshen on open (gated by minFetchGap)
        refreshSessions()                   // re-read local sessions (gated by sessionsMinGap)
    }

    // MARK: - Fetching

    private func startTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
                self?.refreshSessions()
            }
        }
        t.tolerance = 15                    // let the OS coalesce wakeups
        timer = t
    }

    @objc private func systemDidWake() { refreshNow(); refreshSessions() }

    // Timer / wake / menu-open: respect the gates (gap + 429 cooldown).
    @objc private func refreshNow() { performFetch(force: false) }
    // The explicit "Refresh Now" menu item: bypass the cooldown / min-gap rate
    // limits (but still coalesce if a fetch is already in flight).
    @objc private func refreshNowClicked() { performFetch(force: true) }

    private func performFetch(force: Bool) {
        guard !isFetching else { return }
        let now = Date()
        if !force {
            guard now >= cooldownUntil,
                  now >= lastFetchAt.addingTimeInterval(minFetchGap) else { return }
        }
        isFetching = true
        lastFetchAt = now
        Task { @MainActor in
            defer { isFetching = false }
            // Token rotation is only safe while NO local Claude Code is alive (a
            // running one holds the single-use refresh token in memory and gets
            // logged out if we spend it). Checked fresh per fetch, off the main
            // actor; "Refresh Now" bypasses the time gates but never this.
            let sessions = sessionsClient
            let claudeAlive = await Task.detached(priority: .utility) { sessions.anyClaudeAlive() }.value
            do {
                let usage = try await client.fetch(allowRefresh: !claudeAlive,
                                                   isClaudeAlive: { sessions.anyClaudeAlive() })
                snapshot = ProviderUsageSnapshot(claude: usage)
                lastError = nil
                needsAuth = false
                recordHistory(snapshot)
            } catch let e as UsageError {
                lastError = e.description
                if case .auth = e { needsAuth = true } else { needsAuth = false }
                if case .http(429) = e { cooldownUntil = Date().addingTimeInterval(rateLimitCooldown) }
            } catch let e as KeychainError {
                // Not signed in (no Keychain item) is the most likely first-run
                // state — flag it loudly. Transient Keychain hiccups stay calm.
                lastError = e.description
                if case .notFound = e { needsAuth = true } else { needsAuth = false }
            } catch {
                lastError = (error as CustomStringConvertible).description
                needsAuth = false
            }
            renderMenu()    // before the bar: the panel render refreshes the forecast
            renderBar()
        }
    }

    // Re-read the local session registry off the main actor (pure file I/O), then
    // update the menu rows on the main actor. Gated by sessionsMinGap to coalesce
    // rapid menu opens; force bypasses the gate (initial load).
    private func refreshSessions(force: Bool = false) {
        guard !isReadingSessions else { return }
        let now = Date()
        if !force, now < lastSessionsReadAt.addingTimeInterval(sessionsMinGap) { return }
        isReadingSessions = true
        lastSessionsReadAt = now
        let client = sessionsClient
        Task.detached(priority: .utility) {
            let list = client.fetch()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sessions = list
                self.isReadingSessions = false
                self.renderSessions()
            }
        }
    }

    // MARK: - Rendering

    private func renderBar() {
        guard let button = statusItem.button else { return }

        // A rejected token wins over everything: surface the loud "⚠" even when we
        // still hold a stale snapshot from before the token went bad — otherwise the
        // bar would keep showing old numbers as if all were well.
        if needsAuth {
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: "⚠", attributes: [
                .font: barFont,
                .foregroundColor: NSColor.systemRed,
            ])
            button.toolTip = lastError ?? "Not authorized."
            return
        }

        guard let snap = snapshot else {
            // No data yet and no auth problem — a rate-limit / network hiccup or the
            // first load. Show a calm "…" since we retry automatically.
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: "…", attributes: [
                .font: barFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            button.toolTip = lastError ?? "Loading…"
            return
        }

        StatusRenderer.apply(to: button,
                             five: snap.primary?.utilization,
                             week: snap.secondary?.utilization,
                             style: Settings.style,
                             color: Settings.colorMode,
                             font: barFont,
                             projected: forecast?.projected)
        button.toolTip = Self.tooltipText(snap, lastError: lastError)
    }

    /// Re-render only when the menu bar actually crosses the light/dark boundary,
    /// so vibrancy / contrast sub-changes don't trigger needless redraws.
    private func appearanceDidChange() {
        let isDark = statusItem.button?.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard lastIsDark != isDark else { return }
        lastIsDark = isDark
        renderBar()
    }

    private func renderMenu() {
        let now = Date()
        let five = snapshot?.primary?.utilization
        let resetsAt = snapshot?.primary?.resetsAt
        forecast = Forecast.compute(samples: history, now: now, current: five, resetsAt: resetsAt)

        headerView.configure(PanelHeaderModel(
            five: five,
            week: snapshot?.secondary?.utilization,
            projected: forecast?.projected,
            fiveIsRed: (five ?? 0) >= 90,
            fiveResetAbs: resetsAt.map { "resets \(Self.dailyResetFormatter.string(from: $0))" },
            fiveResetRel: resetsAt.map { "in \(Self.rel($0.timeIntervalSince(now)))" },
            weekResetAbs: snapshot?.secondary?.resetsAt.map { "resets \(Self.weeklyResetFormatter.string(from: $0))" },
            weekResetRel: snapshot?.secondary?.resetsAt.map { "in \(Self.rel($0.timeIntervalSince(now)))" },
            signedOut: needsAuth))

        if let snap = snapshot {
            configureModelRow(opusItem, label: "Weekly · Opus", snap.extra("opus"))
            configureModelRow(sonnetItem, label: "Weekly · Sonnet", snap.extra("sonnet"))
        }
        statusLine.title = Self.statusLineText(fetchedAt: snapshot?.fetchedAt,
                                               lastError: lastError, formatter: Self.updatedFormatter)
        applyGraphData()        // refresh the graph row when a fetch lands
    }

    /// Compact relative time: "2h 07m", "38m", "6 days".
    private static func rel(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s >= 48 * 3600 { return "\(Int((Double(s) / 86400).rounded())) days" }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : "\(m)m"
    }

    /// Model-specific weekly caps only appear when actually in use.
    private func configureModelRow(_ item: NSMenuItem, label: String, _ window: UsageWindow?) {
        if Self.modelRowVisible(window) {
            item.isHidden = false
            item.title = Self.modelRowText(label, window, resetFormatter: Self.weeklyResetFormatter)
        } else {
            item.isHidden = true
        }
    }

    /// Fill the pre-allocated session rows in place (view content / isHidden
    /// only — safe while the menu is open). The header carries the true count
    /// even when more sessions exist than visible slots; the last slot then
    /// absorbs the overflow.
    private func renderSessions() {
        let list = sessions
        if list.isEmpty {
            sessionsHeader.attributedTitle = Self.sessionsHeaderTitle("No active Claude sessions")
            for it in sessionRowItems { it.isHidden = true }
            return
        }
        sessionsHeader.attributedTitle = Self.sessionsHeaderTitle(
            list.count == 1 ? "1 active session" : "\(list.count) active sessions")

        let cap = Self.maxSessionRows
        let overflow = list.count > cap
        let realRows = overflow ? cap - 1 : list.count
        for (i, it) in sessionRowItems.enumerated() {
            guard let view = it.view as? SessionRowView else { continue }
            if i < realRows {
                view.configure(list[i])
                it.isHidden = false
            } else if overflow, i == realRows {
                view.configureOverflow(list.count - realRows)
                it.isHidden = false
            } else {
                it.isHidden = true
            }
        }
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

    // MARK: - Display settings

    private func buildStyleMenu() -> NSMenu {
        let m = NSMenu()
        for s in DisplayStyle.allCases {
            let it = NSMenuItem(title: s.title, action: #selector(selectStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s.rawValue
            it.state = (s == Settings.style) ? .on : .off
            it.image = StatusRenderer.previewImage(for: s)
            m.addItem(it)
        }
        return m
    }

    private func buildColorMenu() -> NSMenu {
        let m = NSMenu()
        for c in ColorMode.allCases {
            let it = NSMenuItem(title: c.title, action: #selector(selectColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.rawValue
            it.state = (c == Settings.colorMode) ? .on : .off
            m.addItem(it)
        }
        return m
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = DisplayStyle(rawValue: raw) else { return }
        Settings.style = s
        sender.menu?.items.forEach { $0.state = (($0.representedObject as? String) == raw) ? .on : .off }
        renderBar()
    }

    @objc private func selectColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = ColorMode(rawValue: raw) else { return }
        Settings.colorMode = c
        sender.menu?.items.forEach { $0.state = (($0.representedObject as? String) == raw) ? .on : .off }
        renderBar()
        // The panel follows the color mode too: rings, pills, session dots, and
        // the graph all resolve their accent from Settings at draw time — mark
        // them dirty so the next menu open repaints in the new mode.
        renderMenu()
        pillsView.needsDisplay = true
        for it in sessionRowItems { it.view?.needsDisplay = true }
    }

    // MARK: - Usage history

    /// Record a sample from a successful fetch: throttle to the ~5-min grid (Refresh
    /// Now bypasses the fetch gate), append in memory + persist off-main.
    private func recordHistory(_ snap: ProviderUsageSnapshot?) {
        guard let snap else { return }
        let sample = Self.historySample(from: snap)
        guard sample.t.timeIntervalSince(lastHistoryAppendAt) >= minSampleGap else { return }
        lastHistoryAppendAt = sample.t
        history.append(sample)
        trimHistoryInMemory()
        let store = historyStore
        Task.detached(priority: .utility) { store.append(sample) }
        // Keep the on-disk file bounded across long uptimes too — without this,
        // trim only ran at launch and the file grew (~17 KB/day) until a relaunch.
        if sample.t.timeIntervalSince(lastDiskTrimAt) > 24 * 3600 {
            lastDiskTrimAt = sample.t
            let maxAge = historyMaxAge
            Task.detached(priority: .utility) { store.trim(maxAge: maxAge) }
        }
    }

    /// Build the windowed GraphData from the in-memory buffer and hand it to the view. Cheap
    /// (a slice); the view skips the redraw when nothing meaningful changed.
    private func applyGraphData() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Settings.historyRange.duration)
        let sliced = history.filter { $0.t >= cutoff }
        graphView.update(GraphData(
            samples: sliced,
            mode: Settings.graphMode,
            range: Settings.historyRange,
            colorMode: Settings.colorMode,
            now: now,
            fiveNow: snapshot?.primary?.utilization,
            weekNow: snapshot?.secondary?.utilization,
            fiveResetsAt: snapshot?.primary?.resetsAt,
            projected: forecast?.projected,
            crosses: forecast?.crosses ?? false,
            crossTime: forecast?.crossTime))
    }

    /// Merge two sample lists, de-duplicating by whole-second timestamp (`b` wins), sorted.
    private func mergeHistory(_ a: [HistorySample], _ b: [HistorySample]) -> [HistorySample] {
        var byT: [Int: HistorySample] = [:]
        for s in a { byT[Int(s.t.timeIntervalSince1970.rounded())] = s }
        for s in b { byT[Int(s.t.timeIntervalSince1970.rounded())] = s }
        return byT.values.sorted { $0.t < $1.t }
    }

    private func trimHistoryInMemory() {
        let cutoff = Date().addingTimeInterval(-historyMaxAge)
        if let first = history.first?.t, first < cutoff {
            history.removeAll { $0.t < cutoff }
        }
    }

    // MARK: - Pure string builders
    //
    // Extracted from the render methods into nonisolated static helpers so the
    // golden tests can assert byte-identical output without a live menu. Each
    // returns exactly what the pre-refactor instance method did; the only change is
    // that the formatter and `lastError` arrive as parameters rather than read off
    // `self`, which also keeps them provably pure.

    /// Rounded integer percent, em-dash for a missing value.
    nonisolated static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded()))%"
    }

    /// "resets <time>" for a window's reset instant, nil when there is none. The
    /// caller supplies the formatter (weekly rows use the weekday-bearing one).
    nonisolated static func resetText(_ date: Date?, formatter: DateFormatter) -> String? {
        guard let date else { return nil }
        return "resets \(formatter.string(from: date))"
    }

    /// One weekly model-cap row, e.g. "Weekly · Opus — 42%  ·  resets Sun 03:00".
    nonisolated static func modelRowText(_ label: String, _ window: UsageWindow?,
                                         resetFormatter: DateFormatter) -> String {
        guard let window else { return "\(label) — —" }
        var s = "\(label) — \(percent(window.utilization))"
        if let reset = resetText(window.resetsAt, formatter: resetFormatter) { s += "  ·  \(reset)" }
        return s
    }

    /// A model-cap row is shown only when that model is actually in use.
    nonisolated static func modelRowVisible(_ window: UsageWindow?) -> Bool {
        guard let window else { return false }
        return window.utilization > 0
    }

    /// The bar's tooltip: the title, the present headline windows, and any error.
    nonisolated static func tooltipText(_ snap: ProviderUsageSnapshot, lastError: String?) -> String {
        var lines = ["Claude usage"]
        if let f = snap.primary { lines.append("5-hour: \(percent(f.utilization))") }
        if let w = snap.secondary { lines.append("Weekly: \(percent(w.utilization))") }
        if let e = lastError { lines.append("⚠ \(e)") }
        return lines.joined(separator: "\n")
    }

    /// The status row text. `fetchedAt == nil` means no snapshot yet (the loading /
    /// error branch); a snapshot present shows "Updated <time>", or "Stale — …"
    /// when a later poll failed but the previous numbers still stand.
    nonisolated static func statusLineText(fetchedAt: Date?, lastError: String?,
                                           formatter: DateFormatter) -> String {
        guard let fetchedAt else { return lastError ?? "Loading…" }
        return lastError == nil
            ? "Updated \(formatter.string(from: fetchedAt))"
            : "Stale — \(lastError!)"
    }

    /// The history sample a successful poll records: the two headline utilizations
    /// and their reset instants at the fetch time. Optionals stay genuine gaps.
    nonisolated static func historySample(from snap: ProviderUsageSnapshot) -> HistorySample {
        HistorySample(
            t: snap.fetchedAt,
            five: snap.primary?.utilization,
            week: snap.secondary?.utilization,
            fiveResetsAt: snap.primary?.resetsAt,
            weekResetsAt: snap.secondary?.resetsAt)
    }
}
