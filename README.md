<p align="center">
  <img src="assets/icon.png" width="120" height="120" alt="Claude Usage icon">
</p>

<h1 align="center">Claude Usage</h1>

<p align="center">
  A tiny native macOS menu-bar app that shows your current Claude usage as
  <b>5-hour</b> and <b>weekly</b> utilization.
</p>

It reads the OAuth token Claude Code already stores in your login Keychain and
polls the same usage data that powers Claude Code's `/usage` command. No servers,
no accounts, no config files, no telemetry — it talks only to Anthropic.

```
Menu bar:   ◍   ← concentric rings (default), or 14% / 4%, bars, gauges, …

Dropdown:   5-hour limit — 14%  ·  resets 17:40
            Weekly limit —  4%  ·  resets Sun 03:00
            ─────────────
            Updated 14:26
            Refresh Now
            Display Style  ▸   Concentric rings · Percentages · Bars · …
            Color          ▸   Thresholds · Monochrome · Heatmap · Accent
            ✓ Launch at Login
              Show Dock Icon
            ─────────────
            Quit
```

> **Unofficial.** Not affiliated with, or endorsed by, Anthropic. It relies on a
> private endpoint that Claude Code uses internally — undocumented, and liable to
> change or break without notice. It reads your local Claude Code OAuth token from
> the Keychain and sends requests only to `api.anthropic.com` /
> `console.anthropic.com`. Use at your own risk.

## Display styles & color

Choose how the two values look from the **Display Style** menu — from concentric
rings (default; outer = 5-hour, inner = weekly) to percentages, bars, twin rings,
gauges, pie slices, or segments:

![Display styles](assets/styles.png)

The **Color** menu controls how usage maps to color:

- **Monochrome** (default) — adapts to the menu bar (light / dark)
- **Thresholds** — normal, orange ≥ 70 %, red ≥ 90 %
- **Heatmap** — green → red as usage climbs
- **System accent** — your macOS accent color

## Requirements

- Apple Silicon Mac, macOS 13 (Ventura) or later.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and
  **signed in** — that's what creates the Keychain item the app reads.
- To build: the Swift toolchain (Xcode, or Command Line Tools via
  `xcode-select --install`).

## Build

```sh
./build.sh              # → build/Claude Usage.app
./build.sh --install    # also copies to /Applications and clears quarantine
```

The result is a self-contained `.app` that uses only system frameworks (the Swift
runtime ships with macOS). It's deliberately light: a single status item, a
~5-minute poll (plus on-demand refresh when you open the menu) with rate-limit
backoff, and ephemeral network requests.

## Run on your other Macs

The built `.app` is portable — AirDrop it over, or clone this repo and run
`./build.sh` there. Two things to know on each Mac:

1. **Claude Code must be signed in** on that Mac. The app refreshes the token
   itself when it expires, so it keeps working even when Claude Code isn't running.
2. **First launch / Gatekeeper.** The app is ad-hoc signed, not notarized, so a
   copied bundle may be quarantined. Clear it once (or right-click → **Open**):
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Claude Usage.app"
   ```
   `build.sh --install` does this for you.
3. **Keychain prompt.** The first time it reads the token, macOS asks for
   permission — click **Always Allow**.

> Tip: if you can't see it in the menu bar, a menu-bar manager (Bartender, Ice, …)
> may be hiding it. Reveal the hidden section and ⌘-drag the item where you want it.

## How it works

| Piece | Detail |
|-------|--------|
| Data source | `GET /api/oauth/usage` → `five_hour.utilization`, `seven_day.utilization` (plus model-specific weekly caps when in use) |
| Auth | OAuth token from Keychain service `Claude Code-credentials`; auto-refreshed via the stored refresh token |
| Display | `NSStatusItem` rendered as text or a drawn glyph — 7 styles × 4 color modes |
| Footprint | Menu-bar only (`LSUIElement`); optional Dock icon; launch-at-login via a per-user LaunchAgent |

## Project layout

```
Sources/
  main.swift           App entry + single-instance guard
  AppDelegate.swift    Status item, menu, polling
  StatusRenderer.swift Display styles + color modes (text / drawn glyphs)
  UsageClient.swift    Usage fetch + token refresh
  Keychain.swift       Read/write the shared Claude Code credentials
  LoginItem.swift      Launch-at-login via LaunchAgent
Resources/
  Info.plist           Bundle manifest (LSUIElement = menu-bar only)
  AppIcon.icns         App icon
assets/                README images (icon, styles strip)
tools/
  icongen/main.swift   Renders the icon
  make_icon.sh         Builds AppIcon.icns
build.sh               Compile → bundle → sign (→ install)
```

## License

[MIT](LICENSE) — free to use, modify, and distribute. Provided **as is**, with no
warranty and no liability; use at your own risk.
