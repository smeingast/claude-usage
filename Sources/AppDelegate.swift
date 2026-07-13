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

    // Two-provider derived state (package 4b). `twoProvider` is resolved AT MENU
    // OPEN (NSMenu can't restructure rows while up); the derived states and
    // forecasts are recomputed on every render so the copy stays fresh. In
    // Claude-only mode `twoProvider` is false and every field below is inert, so
    // the panel/bar/graph paths are the literal v0.8 behavior (amendment 7).
    private var twoProvider = false
    private var claudeDerived: ClaudeDerived?
    private var codexDerived: CodexDerived?
    private var codexForecast: Forecast?
    // True once openResolve has run for the CURRENT tracking session; cleared in
    // menuDidClose. menuNeedsUpdate re-enters on every menu-tracking tick (the
    // HistoryGraphView signature comment documents this), and openResolve must not
    // re-run then: it would re-resize the strip row, whose structure and height are
    // per-open (amendment 1).
    private var openResolved = false
    private static let codexRootPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true).path

    // Panel rows (custom views) and the remaining text rows.
    private let headerView = PanelHeaderView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width,
                                                           height: PanelHeaderView.height))
    private let headerItem = NSMenuItem()
    private let pillsView = RangeModePillsView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width,
                                                             height: RangeModePillsView.height))
    private let pillsItem = NSMenuItem()
    private let opusItem = NSMenuItem()
    private let sonnetItem = NSMenuItem()

    // Two-provider panel chrome (package 4b): a provider tag row ABOVE the instrument,
    // the compact secondary strip, and the graph provider pill. All hidden in
    // Claude-only mode (kept out of layout), so the panel is the literal v0.8
    // instrument then. There is NO honesty banner under the instrument (amendment 24:
    // "this box should never appear"): the signals live in the tag-row age line, the
    // rings, the status line, and the secondary strip's compact sub-line.
    private let tagRowItem = NSMenuItem()
    private let tagRowView = TagRowView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width,
                                                      height: TagRowView.height))
    private let stripItem = NSMenuItem()
    private let stripView = StripView(frame: NSRect(x: 0, y: 0, width: PanelStyle.width,
                                                    height: StripView.mainRowHeight + 11))
    // Second graph card (amendment 26: both providers get stacked graphs, the
    // provider pill is gone). The first card is the existing `graphView`; this one
    // sits directly below it and is hidden unless two-provider mode shows two cards.
    // Which provider each card renders is CONTENT, resolved on every applyGraphData
    // (primary first, secondary below), so a mid-open Lead swap re-renders both in
    // place; only the card COUNT is structural and per-open.
    private let secondGraphItem = NSMenuItem()
    private let secondGraphView = HistoryGraphView(frame: NSRect(x: 0, y: 0, width: 360, height: 116))
    private let statusLine = NSMenuItem()
    // The Settings window (v0.10: all options moved out of the dropdown).
    // Created on first open, kept for the app's lifetime.
    private var settingsWC: SettingsWindowController?

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

    // Codex, the second provider. Polled and recorded on its OWN gate, fully
    // isolated from the Claude path above: it never reads or writes isFetching,
    // lastFetchAt, cooldownUntil, or needsAuth. Read-only local file I/O against
    // ~/.codex, no auth, no network. Package 2 stores and records only; nothing here
    // is rendered yet. `codexScanHighWater` is the newest event timestamp SEEN across
    // polls (kept or dropped), tracked in-memory so later polls do not re-read events
    // the decimator already discarded; it is separate from the last STORED sample.
    private let codexClient = CodexUsageClient()
    private var codexUsage: CodexUsageResult?
    private var codexHistory: [HistorySample] = []
    private let codexHistoryStore = HistoryStore(filename: "history-codex.jsonl")
    private var isFetchingCodex = false
    private var lastCodexFetchAt = Date.distantPast
    private let codexMinFetchGap: TimeInterval = 20
    private var codexScanHighWater = Date.distantPast
    private var lastCodexDiskTrimAt = Date()                   // launch task trims; ingest re-trims ~daily

    // Codex sessions (merged into the session list in two-provider mode). Read on its
    // OWN gate off the main actor, same detached pattern as the Claude session poll;
    // fully isolated from the Claude fetch and the codex usage poll.
    private let codexSessionsClient = CodexSessionsClient()
    private var codexSessions = CodexSessionsSnapshot(rows: [], execRunsToday: 0)
    private var isReadingCodexSessions = false
    private var lastCodexSessionsReadAt = Date.distantPast

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

        // Prime the Codex history the same detached way, into the codex store/list, so
        // the decimator is seeded from the last stored codex sample before the first
        // codex poll can record a too-close one. Trim the codex file at launch too.
        //
        // The first codex poll is launched HERE, inside the merge continuation and only
        // AFTER codexHistory holds the stored samples, not from the block below. The
        // ordering is load-bearing: refreshCodex's collect cutoff is
        // max(codexScanHighWater, codexHistory.last?.t), and at launch codexScanHighWater
        // is still .distantPast. Were the poll to run before this merge, the cutoff would
        // be .distantPast and the first backfill would re-read every sample already on
        // disk and re-append it. Merge first, poll second, and a launch can never
        // backfill from .distantPast or duplicate stored samples.
        let codexStore = codexHistoryStore
        Task.detached(priority: .utility) {
            let loaded = Self.repairCodexSamples(codexStore.load(maxAge: maxAge))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.codexHistory = self.mergeHistory(loaded, self.codexHistory)
                self.refreshCodex(force: true)
            }
            codexStore.trim(maxAge: maxAge)
        }

        startTimer()
        refreshNow()
        refreshSessions(force: true)
        refreshCodexSessions(force: true)
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false       // keep info rows full-color & readable
        menu.delegate = self

        // The instrument panel. In two-provider mode a provider tag row sits ABOVE
        // the header; it is hidden (out of layout) in Claude-only mode, so the
        // header is rings + numbers exactly as v0.8. No honesty banner exists below
        // the instrument (amendment 24): the state signals live in the tag-row age
        // line, the rings, the status line, and the strip's sub-line.
        tagRowItem.isEnabled = false
        tagRowItem.view = tagRowView
        tagRowItem.isHidden = true
        menu.addItem(tagRowItem)

        headerItem.isEnabled = false
        headerItem.view = headerView
        menu.addItem(headerItem)

        // Model-specific weekly rows (shown only when Claude is primary and in use).
        for item in [opusItem, sonnetItem] {
            item.isEnabled = false
            item.isHidden = true
            menu.addItem(item)
        }

        // The compact secondary strip (two-provider only). Its Lead button swaps
        // which provider leads the instrument, in place.
        stripItem.isEnabled = true          // the Lead button needs the click
        stripItem.view = stripView
        stripItem.isHidden = true
        stripView.onLead = { [weak self] in self?.leadSwap() }
        menu.addItem(stripItem)

        // Graph cards: one shared range/mode pills row above up to two stacked
        // graphs (amendment 26: no provider pill; two-provider mode shows both
        // providers' histories, primary first). All enabled, since a disabled item
        // can gate event delivery to its view, and these views handle their own
        // clicks/hover. The second card is hidden outside two-provider mode.
        pillsItem.isEnabled = true
        pillsItem.view = pillsView
        menu.addItem(pillsItem)
        pillsView.onChange = { [weak self] in self?.applyGraphData() }
        graphItem.isEnabled = true
        graphItem.view = graphView
        menu.addItem(graphItem)
        secondGraphItem.isEnabled = true
        secondGraphItem.view = secondGraphView
        secondGraphItem.isHidden = true
        menu.addItem(secondGraphItem)
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

        // All options live in the Settings window (v0.10); the dropdown carries
        // only actions. About shares the window (its About tab) rather than the
        // standard about panel, so app/build info and settings are one surface.
        addAction(to: menu, title: "Settings…", key: ",", action: #selector(openSettingsClicked))
        addAction(to: menu, title: "About Headroom", key: "", action: #selector(openAboutClicked))

        menu.addItem(.separator())
        // Quit targets NSApp explicitly — terminate(_:) lives on NSApplication, not on
        // us, so the generic addAction (target = self) would silently no-op the click.
        let quit = NSMenuItem(title: "Quit Headroom",
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
    //
    // menuNeedsUpdate RE-ENTERS on every menu-tracking tick (the HistoryGraphView
    // signature comment documents this), so the per-open structural work runs at
    // most once per tracking session: openResolve is gated by `openResolved`, which
    // menuDidClose clears. Re-running it mid-open would reset graphProvider
    // (stomping a mid-open graph-pill selection) and re-resize the banner/strip
    // rows, whose heights are fixed at open (amendment 1). The content renders
    // below stay per-tick, as today.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if !openResolved { openResolve() }
        renderMenu()            // recomputes forecast + state; includes applyGraphData()
        renderSessions()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshNow()                        // freshen on open (gated by minFetchGap)
        refreshSessions()                   // re-read local sessions (gated by sessionsMinGap)
        refreshCodex()                      // freshen Codex on open (its own 20s gate)
        refreshCodexSessions()              // re-read Codex sessions (its own 2s gate)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Arm the next open's structural resolution (see menuNeedsUpdate).
        openResolved = false
    }

    /// Resolve the two-provider layout ONCE per menu open (amendment 1: NSMenu can't
    /// restructure rows while up). This decides `twoProvider`, sets the tag / strip /
    /// second-graph row visibility, freezes the strip HEIGHT for this open, and
    /// resolves whether the two-provider settings items appear. `renderMenu` then
    /// only mutates row CONTENT (safe while open); a mid-open Lead swap changes
    /// content but the frozen height stands until the next open. No honesty banner
    /// row exists (amendment 24).
    private func openResolve() {
        openResolved = true
        computeDerived(now: Date())
        twoProvider = codexUISurfacesVisible()

        tagRowItem.isHidden = !twoProvider
        stripItem.isHidden = !twoProvider
        // The second graph card is structural too: visible only when the Graphs
        // setting resolves to two cards (amendment 26). WHICH provider each card
        // shows is content, re-resolved on every applyGraphData, so a mid-open Lead
        // swap re-renders both cards in place without touching row structure.
        secondGraphItem.isHidden = ProviderState.graphCards(
            Settings.graphs, twoProvider: twoProvider,
            primary: Settings.primaryProvider).count < 2

        guard twoProvider else { return }
        // Freeze this open's strip height from the secondary strip model (its
        // sub-banner, when present, drives the height).
        resize(stripView, height: StripView.height(for: secondaryStripModel(), viewWidth: PanelStyle.width))
    }

    private func resize(_ view: NSView, height: CGFloat) {
        view.frame = NSRect(x: 0, y: 0, width: PanelStyle.width, height: ceil(height))
    }

    /// Whether the Codex UI surfaces are shown. `Show Codex` resolves the intent
    /// (auto/on/off), but a provider with no install (`.notInstalled`) has nothing
    /// meaningful to render, so it stays hidden even under `on` (amendment: production
    /// renders nothing for an absent provider). Auto's install gate is a LIVE stat of
    /// `~/.codex`, not the (poll-cached) usage status alone: a root deleted mid-run
    /// hides the surfaces immediately. Accepted residual in the other direction: a
    /// root APPEARING mid-run still becomes visible only once the next codex poll
    /// (20 s gate / 5 min timer / menu open) flips the status off `.notInstalled`,
    /// matching the packages' poll-driven design.
    private func codexUISurfacesVisible() -> Bool {
        let status = codexUsage?.status ?? .notInstalled
        guard status != .notInstalled else { return false }
        let rootExists = FileManager.default.fileExists(atPath: Self.codexRootPath)
        return ProviderState.codexVisible(Settings.showCodex, codexRootExists: rootExists)
    }

    // MARK: - Fetching

    private func startTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
                self?.refreshSessions()
                self?.refreshCodex()
                self?.refreshCodexSessions()
            }
        }
        t.tolerance = 15                    // let the OS coalesce wakeups
        timer = t
    }

    @objc private func systemDidWake() {
        refreshNow(); refreshSessions(); refreshCodex(); refreshCodexSessions()
    }

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

    // Re-read the Codex interactive sessions off the main actor (read-only file I/O),
    // then merge into the session list on the main actor. Same detached pattern and
    // gate as refreshSessions; fully isolated from every Claude gate.
    private func refreshCodexSessions(force: Bool = false) {
        guard !isReadingCodexSessions else { return }
        let now = Date()
        if !force, now < lastCodexSessionsReadAt.addingTimeInterval(sessionsMinGap) { return }
        isReadingCodexSessions = true
        lastCodexSessionsReadAt = now
        let client = codexSessionsClient
        Task.detached(priority: .utility) {
            let snap = client.fetch()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.codexSessions = snap
                self.isReadingCodexSessions = false
                self.renderSessions()
            }
        }
    }

    // Poll Codex on its OWN gate, fully isolated from the Claude fetch. Cheap
    // read-only file I/O off the main actor (like refreshSessions), hopping to the
    // main actor only to store the snapshot, record history, and re-render. It never
    // reads or writes any Claude gate. The collect cutoff is max(scanHighWater,
    // lastStored): the high-water keeps us from re-reading events the decimator
    // already dropped, while the last stored sample bounds a fresh launch before any
    // high-water has been observed.
    private func refreshCodex(force: Bool = false) {
        guard !isFetchingCodex else { return }
        let now = Date()
        if !force, now < lastCodexFetchAt.addingTimeInterval(codexMinFetchGap) { return }
        isFetchingCodex = true
        lastCodexFetchAt = now
        let client = codexClient
        let cutoff = max(codexScanHighWater, codexHistory.last?.t ?? .distantPast)
        Task.detached(priority: .utility) {
            let result = client.fetch()
            let events = client.backfillEvents(after: cutoff)
            await MainActor.run { [weak self] in
                guard let self else { return }
                defer { self.isFetchingCodex = false }
                self.codexUsage = result
                self.ingestCodexEvents(events)
                // A fresh Codex reading can flip two-provider visibility or the
                // panel dot severities; refresh the bar (always safe) and the panel
                // content (safe while open: row STRUCTURE was resolved at open, this
                // only mutates content). Rows are added/removed only on the next open.
                self.renderMenu()
                self.renderBar()
            }
        }
    }

    // MARK: - Rendering

    /// The bar resolves Codex visibility on EVERY render (it is not a menu, so the
    /// "restructure only at open" rule does not apply): a hidden/absent Codex keeps
    /// the literal v0.8 bar; a present one respects `Bar Shows`.
    /// `codexUISurfacesVisible()` reads the freshest usage status, so the bar
    /// tracks Codex even while the menu is closed.
    private func renderBar() {
        guard let button = statusItem.button else { return }
        if codexUISurfacesVisible() {
            renderBarTwoProvider(button)
        } else {
            renderBarClaudeOnly(button)
        }
    }

    /// The unchanged v0.8 bar: the Claude glyph, with the rejected-token "⚠" takeover.
    private func renderBarClaudeOnly(_ button: NSStatusBarButton) {
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

    /// The two-provider bar. `Bar Shows` selects Primary, Both (side-by-side
    /// glyphs), or a single provider. Provider isolation (amendment 13): the "⚠"
    /// auth takeover fires ONLY when the bar shows Claude alone (Bar Shows =
    /// Claude); otherwise a signed-out Claude is carried by the panel copy, and
    /// the bar keeps drawing glyphs. The bar carries NO secondary-provider state
    /// light: the corner pip was removed in v0.10 (Stefan: an amber dot for a
    /// merely inferred-zero Codex read as noise; the panel keeps the full
    /// severity table).
    private func renderBarTwoProvider(_ button: NSStatusBarButton) {
        computeDerived(now: Date())
        let style = Settings.style
        let mode = Settings.colorMode
        let bar = Settings.barShows
        let primary = Settings.primaryProvider

        if bar == .claude && needsAuth {
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: "⚠", attributes: [
                .font: barFont, .foregroundColor: NSColor.systemRed])
            button.toolTip = lastError ?? "Not authorized."
            return
        }

        let cFive = snapshot?.primary?.utilization
        let cWeek = snapshot?.secondary?.utilization
        let xFive = codexDerived?.five
        let xWeek = codexDerived?.week
        let xInfF = codexDerived?.inferredFive ?? false
        let xInfW = codexDerived?.inferredWeek ?? false
        let xProj = (codexDerived?.forecastActive ?? false) ? codexDerived?.projFive : nil

        // Only Codex can be a one-window provider; Claude's API keeps both windows.
        let xSingle = codexHidesFive()

        if style == .percentages {
            let attr: NSAttributedString
            switch bar {
            case .primary, .both:
                // Text can't stack two providers cleanly; Both falls back to the
                // primary's numbers.
                let codexLeads = primary == .codex
                let (f, w) = codexLeads ? (xFive, xWeek) : (cFive, cWeek)
                attr = StatusRenderer.percentText(f, w, mode, barFont,
                                                  singleWindow: codexLeads && xSingle)
            case .claude:
                attr = StatusRenderer.percentText(cFive, cWeek, mode, barFont)
            case .codex:
                attr = StatusRenderer.percentText(xFive, xWeek, mode, barFont,
                                                  singleWindow: xSingle)
            }
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = attr
        } else {
            func claudeGlyph() -> NSImage {
                StatusRenderer.image(five: cFive, week: cWeek, style: style, mode: mode,
                                     projected: forecast?.projected, provider: .claude)
            }
            func codexGlyph() -> NSImage {
                StatusRenderer.image(five: xFive, week: xWeek, style: style, mode: mode,
                                     projected: xProj, provider: .codex,
                                     inferredFive: xInfF, inferredWeek: xInfW,
                                     singleWindow: xSingle)
            }
            let img: NSImage
            switch bar {
            case .primary:
                img = primary == .claude ? claudeGlyph() : codexGlyph()
            case .both:
                img = StatusRenderer.sideBySide(claudeGlyph(), codexGlyph())
            case .claude:
                img = claudeGlyph()
            case .codex:
                img = codexGlyph()
            }
            button.attributedTitle = NSAttributedString(string: "")
            button.image = img
            button.imagePosition = .imageOnly
        }
        button.toolTip = twoProviderTooltip()
    }

    private func twoProviderTooltip() -> String {
        var tip = snapshot.map { Self.tooltipText($0, lastError: lastError) } ?? (lastError ?? "Loading…")
        if let cd = codexDerived, cd.hasData {
            // Only the windows Codex actually reports: a weekly-only account has no
            // 5-hour line to state.
            if cd.hasFive { tip += "\nCodex \(cd.fiveTitle): \(Self.percent(cd.five))" }
            if cd.week != nil { tip += "\nCodex \(cd.weekTitle): \(Self.percent(cd.week))" }
        }
        return tip
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
        computeDerived(now: now)
        if twoProvider {
            renderTwoProviderInstrument(now: now)
        } else {
            renderClaudeOnlyHeader(now: now)   // the literal v0.8 header
        }
        configureExtrasRows()                  // Opus/Sonnet only when Claude is primary
        renderStatusLine(now: now)
        applyGraphData()                       // refresh the graph row when a fetch lands
    }

    /// Recompute the two providers' forecasts and derived UI states. `forecast`
    /// (Claude's, also feeding the header ghost arc) is computed exactly as before;
    /// `codexForecast` runs the same math over the Codex history and is gated inside
    /// `deriveCodex`. Pure derivation lives in ProviderState; this only gathers the
    /// live inputs off `self`.
    private func computeDerived(now: Date) {
        let five = snapshot?.primary?.utilization
        let fiveReset = snapshot?.primary?.resetsAt
        forecast = Forecast.compute(samples: history, now: now, current: five, resetsAt: fiveReset)

        let cx = codexUsage?.snapshot
        codexForecast = Forecast.compute(samples: codexHistory, now: now,
                                         current: cx?.primary?.utilization,
                                         resetsAt: cx?.primary?.resetsAt)

        let hm = Self.updatedFormatter
        // "Stale" is the app's existing condition: a later poll failed but the prior
        // snapshot still stands. Signed-out is the rejected-token state.
        let staleError = lastError != nil && snapshot != nil
        claudeDerived = ProviderState.deriveClaude(
            five: five, week: snapshot?.secondary?.utilization,
            fiveResetsAt: fiveReset, weekResetsAt: snapshot?.secondary?.resetsAt,
            signedOut: needsAuth, staleError: staleError,
            observedAt: snapshot?.fetchedAt, forecast: forecast, now: now, hm: hm)
        codexDerived = ProviderState.deriveCodex(
            result: codexUsage ?? CodexUsageResult(status: .notInstalled, snapshot: nil),
            forecast: codexForecast, now: now, hm: hm)
    }

    /// The unchanged v0.8 instrument header (Claude, no tag row, no banner). Byte-for-
    /// byte the pre-4b construction: the model's `provider`/`inferred*` defaults leave
    /// the rings coral and solid.
    private func renderClaudeOnlyHeader(now: Date) {
        let five = snapshot?.primary?.utilization
        let resetsAt = snapshot?.primary?.resetsAt
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
    }

    /// Configure the two-provider instrument: the primary provider's tag row, rings +
    /// numbers (in the shared header view), and honesty banner, plus the secondary
    /// provider's compact strip.
    private func renderTwoProviderInstrument(now: Date) {
        let primary = Settings.primaryProvider
        if primary == .claude {
            configureClaudePrimary(now: now)
        } else {
            configureCodexPrimary(now: now)
        }
        stripView.configure(secondaryStripModel())
    }

    private func configureClaudePrimary(now: Date) {
        let cd = claudeDerived
        tagRowView.configure(TagRowModel(
            provider: .claude, label: "Claude", planType: nil, showLocalChip: false,
            ageLine: cd?.ageLine ?? "", ageWarn: cd?.ageWarn ?? false))
        let five = snapshot?.primary?.utilization
        let resetsAt = snapshot?.primary?.resetsAt
        headerView.configure(PanelHeaderModel(
            five: five, week: snapshot?.secondary?.utilization,
            projected: forecast?.projected, fiveIsRed: cd?.isRed ?? false,
            fiveResetAbs: resetsAt.map { "resets \(Self.dailyResetFormatter.string(from: $0))" },
            fiveResetRel: resetsAt.map { "in \(Self.rel($0.timeIntervalSince(now)))" },
            weekResetAbs: snapshot?.secondary?.resetsAt.map { "resets \(Self.weeklyResetFormatter.string(from: $0))" },
            weekResetRel: snapshot?.secondary?.resetsAt.map { "in \(Self.rel($0.timeIntervalSince(now)))" },
            signedOut: needsAuth, provider: .claude))
    }

    private func configureCodexPrimary(now: Date) {
        let cd = codexDerived
        tagRowView.configure(TagRowModel(
            provider: .codex, label: "Codex", planType: cd?.planType, showLocalChip: cd?.hasData ?? false,
            ageLine: cd?.ageLine ?? "", ageWarn: cd?.ageWarn ?? false))
        let five = cd?.five
        let fr = cd?.fiveResetsAt
        let wr = cd?.weekResetsAt
        headerView.configure(PanelHeaderModel(
            five: five, week: cd?.week,
            projected: (cd?.forecastActive ?? false) ? cd?.projFive : nil,
            fiveIsRed: cd?.fiveIsRed ?? false,
            fiveResetAbs: fr.map { "resets \(Self.dailyResetFormatter.string(from: $0))" },
            fiveResetRel: fr.map { "in \(Self.rel($0.timeIntervalSince(now)))" },
            weekResetAbs: wr.map { "resets \(Self.weeklyResetFormatter.string(from: $0))" },
            weekResetRel: wr.map { "in \(Self.rel($0.timeIntervalSince(now)))" },
            signedOut: !(cd?.hasData ?? false),
            provider: .codex,
            inferredFive: cd?.inferredFive ?? false,
            inferredWeek: cd?.inferredWeek ?? false,
            fiveTitle: cd?.fiveTitle ?? "5-hour",
            weekTitle: cd?.weekTitle ?? "Weekly",
            weekIsRed: cd?.weekIsRed ?? false,
            hideFive: codexHidesFive()))
    }

    /// Whether the Codex surfaces should drop their near-term slot: only when there IS
    /// a reading and it carried no near-term window. A Codex with no data at all keeps
    /// the familiar two-window skeleton (it has no evidence for either shape).
    private func codexHidesFive() -> Bool {
        guard let cd = codexDerived, cd.hasData else { return false }
        return !cd.hasFive
    }

    /// The strip sub-banner's bullet color: the pip severity's color, falling back
    /// to the provider accent for a calm state (pipColor returns the accent there)
    /// and to a neutral gray if the severity is hidden. Only the strip uses this
    /// now; the primary honesty banner is gone (amendment 24).
    private func bannerDot(_ pip: PipSeverity?, _ provider: UsageProviderKind) -> NSColor {
        guard let pip else { return StatusRenderer.providerAccent(provider) }
        return StatusRenderer.pipColor(pip) ?? .tertiaryLabelColor
    }

    /// Build the compact strip model for the SECONDARY provider (the one not leading
    /// the instrument). Codex secondary carries its own honesty sub-banner; Claude
    /// secondary appends compact in-use Opus/Sonnet extras to the reset line
    /// (amendment 8) since its dedicated extras rows are hidden.
    private func secondaryStripModel() -> StripModel {
        let secondary: UsageProviderKind = Settings.primaryProvider == .claude ? .codex : .claude
        let now = Date()
        return secondary == .codex ? codexStripModel(now: now) : claudeStripModel(now: now)
    }

    private func codexStripModel(now: Date) -> StripModel {
        let cd = codexDerived
        let hasData = cd?.hasData ?? false
        // The reset line names the HEADLINE window's reset, which is the weekly one for
        // a Codex with no near-term window. A window a day or longer needs the weekday
        // in front of the clock time, or "resets 03:00" would not say which day.
        let resetLine: String? = {
            guard hasData, let r = cd?.headResetsAt else { return nil }
            let long = (cd?.headWindowMinutes ?? 300) >= 1440
            let fmt = long ? Self.weeklyResetFormatter : Self.dailyResetFormatter
            return "resets \(fmt.string(from: r)) \u{00B7} \(Self.rel(r.timeIntervalSince(now)))"
        }()
        // The honesty sub-banner shows for any inferred window (amendment 9 treats
        // the weekly roll first-class; its appended msg sentence must be visible) as
        // well as for an aged reading.
        let inferredAny = (cd?.inferredFive ?? false) || (cd?.inferredWeek ?? false)
        let sub: BannerModel? = (hasData && (inferredAny || (cd?.aged ?? false)))
            ? BannerModel(dotColor: bannerDot(cd?.pip, .codex), text: cd?.msg ?? "") : nil
        return StripModel(
            provider: .codex, label: "Codex", planType: cd?.planType,
            showLocalChip: hasData, hasData: hasData,
            noDataMessage: hasData ? nil : cd?.msg,
            ageLine: cd?.ageLine ?? "", ageWarn: cd?.ageWarn ?? false,
            five: cd?.five, week: cd?.week, mode: Settings.colorMode,
            fiveIsRed: cd?.fiveIsRed ?? false,
            inferredFive: cd?.inferredFive ?? false, inferredWeek: cd?.inferredWeek ?? false,
            rawFivePct: (cd?.inferredFive ?? false) ? cd?.rawFive.map { Int($0.rounded()) } : nil,
            rawWeekPct: (cd?.inferredWeek ?? false) ? cd?.rawWeek.map { Int($0.rounded()) } : nil,
            resetLine: resetLine, subBanner: sub, otherLabel: "Claude",
            fiveUnit: cd?.fiveUnit ?? "5h", weekUnit: cd?.weekUnit ?? "wk",
            weekIsRed: cd?.weekIsRed ?? false, hideFive: codexHidesFive())
    }

    private func claudeStripModel(now: Date) -> StripModel {
        let cd = claudeDerived
        let hasData = snapshot != nil && !needsAuth
        var resetLine: String? = nil
        if hasData, let fr = snapshot?.primary?.resetsAt {
            var s = "resets \(Self.dailyResetFormatter.string(from: fr)) \u{00B7} \(Self.rel(fr.timeIntervalSince(now)))"
            // Amendment 8: warning-relevant model caps ride along on the reset line
            // when Claude is secondary (its dedicated extras rows are hidden).
            if let opus = snapshot?.extra("opus"), opus.utilization > 0 {
                s += " \u{00B7} Opus \(Int(opus.utilization.rounded()))%"
            }
            if let sonnet = snapshot?.extra("sonnet"), sonnet.utilization > 0 {
                s += " \u{00B7} Sonnet \(Int(sonnet.utilization.rounded()))%"
            }
            resetLine = s
        }
        return StripModel(
            provider: .claude, label: "Claude", planType: nil,
            showLocalChip: false, hasData: hasData,
            noDataMessage: hasData ? nil : (cd?.msg ?? "Signed out."),
            ageLine: cd?.ageLine ?? "", ageWarn: cd?.ageWarn ?? false,
            five: snapshot?.primary?.utilization, week: snapshot?.secondary?.utilization,
            mode: Settings.colorMode, fiveIsRed: cd?.isRed ?? false,
            inferredFive: false, inferredWeek: false, rawFivePct: nil, rawWeekPct: nil,
            resetLine: resetLine, subBanner: nil, otherLabel: "Codex")
    }

    /// The Opus/Sonnet weekly rows appear only when Claude is the primary instrument
    /// (amendment 8): today's behavior in Claude-only mode, and unchanged when Claude
    /// leads in two-provider mode. When Codex leads they hide (the strip carries the
    /// compact extras instead).
    private func configureExtrasRows() {
        let claudePrimary = !twoProvider || Settings.primaryProvider == .claude
        if claudePrimary, let snap = snapshot {
            configureModelRow(opusItem, label: "Weekly · Opus", snap.extra("opus"))
            configureModelRow(sonnetItem, label: "Weekly · Sonnet", snap.extra("sonnet"))
        } else {
            opusItem.isHidden = true
            sonnetItem.isHidden = true
        }
    }

    /// The status line. Claude-only keeps today's plain string (amendment 12); two-
    /// provider becomes an attributed title "Updated HH:MM · Codex as of HH:MM · Nh
    /// ago" with the Codex age segment amber when aged. In two-provider mode the
    /// Claude segment is COMPACT (amendment 25): NSMenu sizes itself to its widest
    /// text item, and the raw error string of the old "Stale" form forced the whole
    /// menu wider than the 360 pt panel. The error text moves to the status item's
    /// tooltip.
    private func renderStatusLine(now: Date) {
        guard twoProvider else {
            // Claude-only: today's exact full string (golden-tested), plain title.
            statusLine.attributedTitle = nil        // revert to the plain title path
            statusLine.title = Self.statusLineText(fetchedAt: snapshot?.fetchedAt,
                                                   lastError: lastError, formatter: Self.updatedFormatter)
            // No tooltip in Claude-only mode (never set pre-4b; assigning nil also
            // clears a leftover from a two-provider open after Codex is hidden).
            statusLine.toolTip = nil
            return
        }
        // EVERY two-provider state takes the compact form, including Codex noData
        // (the codex segment is just absent then): the wide error string must never
        // reach a text item while the strip keeps the panel at 360 pt.
        let claudeSeg = ProviderState.claudeStatusSegment(
            fetchedAt: snapshot?.fetchedAt,
            stale: lastError != nil && snapshot != nil,
            hm: Self.updatedFormatter)
        statusLine.toolTip = lastError              // the full error lives here now
        let cd = codexDerived
        let seg = (cd?.hasData ?? false)
            ? ProviderState.codexStatusSegment(observedAt: cd?.observedAt, aged: cd?.aged ?? false,
                                               hm: Self.updatedFormatter, now: now)
            : nil
        let full = ProviderState.twoProviderStatusLine(claudeText: claudeSeg, codexSegment: seg)
        let attr = NSMutableAttributedString(string: full, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor])
        // Color just the trailing age ("Nh ago") amber when the reading is aged.
        if let cd, cd.aged, let obs = cd.observedAt {
            let ageStr = ProviderState.relAge(now.timeIntervalSince(obs))
            if let r = full.range(of: ageStr, options: .backwards) {
                attr.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: NSRange(r, in: full))
            }
        }
        statusLine.attributedTitle = attr
    }

    /// The strip's Lead button: promote the secondary provider to primary, in place.
    /// Content swaps immediately (rings, numbers, strip, graph cards, bar); the row
    /// HEIGHTS stay frozen at this open's values (amendment 1) because only
    /// `openResolve` resizes them, and it runs on the next open. The stacked graph
    /// cards reorder as content (primary first) inside applyGraphData, which
    /// renderMenu calls.
    private func leadSwap() {
        Settings.primaryProvider = Settings.primaryProvider == .claude ? .codex : .claude
        renderMenu()
        renderSessions()
        renderBar()
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

    /// One filled session row: a Claude session, a Codex session, the overflow tail,
    /// or the muted Codex-exec summary.
    private enum SessionRow {
        case claude(SessionInfo)
        case codex(ProviderSessionInfo)
        case overflow(Int)
        case exec(Int)
    }

    /// Fill the pre-allocated session rows in place (view content / isHidden only —
    /// safe while the menu is open). In two-provider mode the list merges Claude and
    /// Codex sessions under a split header (amendment 11) with a trailing exec-summary
    /// row; Claude-only keeps today's exact wording and layout.
    private func renderSessions() {
        let claude = sessions
        let codexRows = twoProvider ? codexSessions.rows : []
        let execCount = twoProvider ? codexSessions.execRunsToday : 0

        if claude.isEmpty && codexRows.isEmpty && execCount == 0 {
            let title = twoProvider
                ? ProviderState.sessionsHeader(claudeCount: 0, codexCount: 0, twoProvider: true)
                : "No active Claude sessions"
            sessionsHeader.attributedTitle = Self.sessionsHeaderTitle(title)
            for it in sessionRowItems { it.isHidden = true }
            return
        }
        sessionsHeader.attributedTitle = Self.sessionsHeaderTitle(
            ProviderState.sessionsHeader(claudeCount: claude.count, codexCount: codexRows.count,
                                         twoProvider: twoProvider))

        // Sessions first (Claude then Codex), the exec summary last. The exec row
        // reserves one slot and is never counted in the overflow "+ N more".
        let cap = Self.maxSessionRows
        let hasExec = execCount > 0
        let sessionBudget = hasExec ? cap - 1 : cap
        var descriptors: [SessionRow] = claude.map { .claude($0) } + codexRows.map { .codex($0) }
        var rows: [SessionRow] = []
        if descriptors.count > sessionBudget {
            let shown = max(0, sessionBudget - 1)
            rows = Array(descriptors.prefix(shown))
            rows.append(.overflow(descriptors.count - shown))
        } else {
            rows = descriptors
        }
        if hasExec { rows.append(.exec(execCount)) }
        descriptors = rows

        for (i, it) in sessionRowItems.enumerated() {
            guard let view = it.view as? SessionRowView else { continue }
            guard i < descriptors.count else { it.isHidden = true; continue }
            switch descriptors[i] {
            case .claude(let s):   view.configure(s)
            case .codex(let s):    view.configure(codex: s)
            case .overflow(let n): view.configureOverflow(n)
            case .exec(let n):     view.configureExec(n)
            }
            it.isHidden = false
        }
    }

    // MARK: - Settings window

    private func applyDockVisibility() {
        let show = UserDefaults.standard.bool(forKey: "showDockIcon")   // default false → menu bar only
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    @objc private func openSettingsClicked() { settingsWindow().show(tab: nil) }
    @objc private func openAboutClicked() { settingsWindow().show(tab: .about) }

    private func settingsWindow() -> SettingsWindowController {
        if let wc = settingsWC { return wc }
        let wc = SettingsWindowController(
            hooks: SettingsHooks(
                // Style / Bar Shows change only the bar readout.
                barChanged: { [weak self] in self?.renderBar() },
                colorChanged: { [weak self] in self?.repaintForColorMode() },
                // Show Codex / Graphs: the bar updates now; the panel's row
                // structure resolves on the next open (NSMenu can't restructure
                // rows while up), exactly as the old menu handlers behaved.
                codexChanged: { [weak self] in self?.renderBar() },
                dockChanged: { [weak self] in self?.applyDockVisibility() }),
            codexRootPath: Self.codexRootPath)
        settingsWC = wc
        return wc
    }

    /// The panel follows the color mode too: rings, pills, session dots, and
    /// the graph all resolve their accent from Settings at draw time — mark
    /// them dirty so the next menu open repaints in the new mode.
    private func repaintForColorMode() {
        renderBar()
        renderMenu()
        pillsView.needsDisplay = true
        for v in [tagRowView, stripView] as [NSView] { v.needsDisplay = true }
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

    /// Feed the stacked graph cards (amendment 26). The visible card LIST (order:
    /// primary first) comes from the pure `ProviderState.graphCards`; the first card
    /// always exists, the second only in two-provider mode with Graphs = Both (its
    /// row visibility was resolved at open). Which provider each card renders is
    /// re-resolved here on every call, so a mid-open Lead swap reorders the cards as
    /// a pure content swap. Claude-only stays byte-for-byte v0.8: one card, Claude
    /// data, no readout prefix. Cheap (a slice per card); the views skip the redraw
    /// when nothing meaningful changed.
    private func applyGraphData() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Settings.historyRange.duration)
        let cards = ProviderState.graphCards(Settings.graphs, twoProvider: twoProvider,
                                             primary: Settings.primaryProvider)
        graphView.update(graphData(for: cards[0], now: now, cutoff: cutoff))
        if cards.count > 1 {
            secondGraphView.update(graphData(for: cards[1], now: now, cutoff: cutoff))
        }
    }

    /// The GraphData for one provider's card. The Claude branch is the pre-4b build
    /// verbatim (plus the two-provider-only readout prefix, nil in Claude-only mode);
    /// the Codex branch mirrors it from the derived state, with the forecast gate and
    /// the idle placeholder. The prefix names the provider in its accent so the two
    /// stacked cards stay distinguishable in the non-Brand color modes.
    private func graphData(for provider: UsageProviderKind, now: Date, cutoff: Date) -> GraphData {
        let prefix: String? = twoProvider ? (provider == .claude ? "Claude" : "Codex") : nil
        if provider == .codex {
            let cd = codexDerived
            let active = cd?.forecastActive ?? false
            return GraphData(
                samples: codexHistory.filter { $0.t >= cutoff },
                mode: Settings.graphMode, range: Settings.historyRange,
                colorMode: Settings.colorMode, now: now,
                fiveNow: cd?.five, weekNow: cd?.week,
                fiveResetsAt: cd?.fiveResetsAt,
                projected: active ? cd?.projFive : nil,
                crosses: active && (codexForecast?.crosses ?? false),
                crossTime: active ? cd?.crossTime : nil,
                provider: .codex, forecastIdle: !active,
                readoutPrefix: prefix,
                showFive: !codexHidesFive(),
                fiveUnit: cd?.fiveUnit ?? "5h", weekUnit: cd?.weekUnit ?? "wk")
        }
        return GraphData(
            samples: history.filter { $0.t >= cutoff },
            mode: Settings.graphMode,
            range: Settings.historyRange,
            colorMode: Settings.colorMode,
            now: now,
            fiveNow: snapshot?.primary?.utilization,
            weekNow: snapshot?.secondary?.utilization,
            fiveResetsAt: snapshot?.primary?.resetsAt,
            projected: forecast?.projected,
            crosses: forecast?.crosses ?? false,
            crossTime: forecast?.crossTime,
            readoutPrefix: prefix)
    }

    /// Merge two sample lists, de-duplicating by whole-second timestamp (`b` wins), sorted.
    private func mergeHistory(_ a: [HistorySample], _ b: [HistorySample]) -> [HistorySample] {
        Self.mergeHistorySamples(a, b)
    }

    /// The body of `mergeHistory`, factored out pure and nonisolated (same pattern as
    /// `decimateCodex`) so the history tests can drive it without a live menu. The
    /// instance method above delegates here, so every existing call site is
    /// byte-identical: de-duplicate by whole-second timestamp (later argument, i.e. the
    /// second element of a colliding pair, wins), returned ascending by time.
    nonisolated static func mergeHistorySamples(_ a: [HistorySample],
                                                _ b: [HistorySample]) -> [HistorySample] {
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

    // MARK: - Codex history

    /// Fold a batch of backfill events (chronological) into the codex history:
    /// advance the in-memory scan high-water past every event SEEN (kept, decimated,
    /// or dropped as a stray) so later polls do not re-read them, drop isolated
    /// stray-anchor readings, greedily decimate to the ~5-min grid, then persist and
    /// merge the survivors. Samples are stamped with the EVENT time.
    private func ingestCodexEvents(_ events: [CodexUsageClient.Event]) {
        guard let newest = events.last?.timestamp else { return }   // ascending: last is newest
        codexScanHighWater = max(codexScanHighWater, newest)

        // Stray-anchor run filter on the RAW batch, before decimation: runs caught
        // between two runs of the same anchor cluster are exec-subagent strays, not
        // rollovers, when their own cluster is strictly outnumbered batch-wide (see
        // CodexUsageClient.filterStrays for the population-weighted span rule).
        let cleaned = CodexUsageClient.filterStrays(events)

        let lastKept = codexHistory.last?.t ?? .distantPast
        let kept = Self.decimateCodex(events: cleaned, lastKept: lastKept, minGap: minSampleGap)
        guard !kept.isEmpty else { return }

        let store = codexHistoryStore
        Task.detached(priority: .utility) { for s in kept { store.append(s) } }
        codexHistory = mergeHistory(codexHistory, kept)
        trimCodexHistoryInMemory()
        // Keep the on-disk codex file bounded across long uptimes too, mirroring
        // recordHistory's ~daily re-trim of the Claude store. Keyed on WALL CLOCK, not
        // the kept sample's event time: during a backfill the newest kept event can lag
        // hours (or days) behind now, which would defer the trim indefinitely and let
        // the file grow, the pre-v0.8 launch-only-trim growth bug in new clothes.
        if Date().timeIntervalSince(lastCodexDiskTrimAt) > 24 * 3600 {
            lastCodexDiskTrimAt = Date()
            let maxAge = historyMaxAge
            Task.detached(priority: .utility) { store.trim(maxAge: maxAge) }
        }
    }

    /// Re-slot Codex samples recorded BEFORE windows were keyed by length. Builds up to
    /// v0.10 mapped the event's `rate_limits.primary` straight into the sample's 5-hour
    /// field, so every sample taken after Codex went weekly-only (2026-07-12) stored the
    /// WEEKLY figure, and its weekly reset, as 5-hour data. Left alone those samples
    /// graph a weekly series as a 5-hour one for as long as they are retained (32 days).
    ///
    /// The tell is exact, not a guess: a real 5-hour window cannot reset more than five
    /// hours after the reading that observed it. A sample whose 5-hour slot resets
    /// further out than that was never a 5-hour window, so it moves to the weekly slot.
    /// Samples that carry both windows are never touched, so genuine old-shape history
    /// passes through untouched. In memory only; the file is left alone and ages out.
    nonisolated static func repairCodexSamples(_ samples: [HistorySample]) -> [HistorySample] {
        let slack: TimeInterval = 10 * 60      // clock skew between the event and its reset
        return samples.map { s in
            guard s.week == nil, let five = s.five, let reset = s.fiveResetsAt,
                  reset.timeIntervalSince(s.t) > Forecast.fiveWindow + slack else { return s }
            return HistorySample(t: s.t, five: nil, week: five,
                                 fiveResetsAt: nil, weekResetsAt: reset)
        }
    }

    /// Greedy decimation of chronological Codex events into history samples: keep an
    /// event iff its timestamp is at least `minGap` after the last KEPT sample,
    /// seeded with `lastKept` (the last already-stored sample time, or .distantPast).
    /// Even spacing by construction, so no seconds-apart neighbors survive. Values
    /// pass straight through, resets included: there is no rise math here, so a window
    /// reset between neighbors can never manufacture a negative downstream. Pure and
    /// nonisolated so the backfill tests drive it without a live menu.
    nonisolated static func decimateCodex(events: [CodexUsageClient.Event], lastKept: Date,
                                          minGap: TimeInterval) -> [HistorySample] {
        var last = lastKept
        var out: [HistorySample] = []
        for ev in events {
            guard ev.timestamp >= last.addingTimeInterval(minGap) else { continue }
            last = ev.timestamp
            out.append(HistorySample(t: ev.timestamp, five: ev.primaryPercent,
                                     week: ev.secondaryPercent,
                                     fiveResetsAt: ev.primaryResetsAt,
                                     weekResetsAt: ev.secondaryResetsAt))
        }
        return out
    }

    private func trimCodexHistoryInMemory() {
        let cutoff = Date().addingTimeInterval(-historyMaxAge)
        if let first = codexHistory.first?.t, first < cutoff {
            codexHistory.removeAll { $0.t < cutoff }
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
