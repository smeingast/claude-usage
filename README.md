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
no accounts, no config files, no telemetry. It talks only to Anthropic.

```
Menu bar:   ◍   concentric rings (default), or 14% / 4%, bars, gauges, ...

Dropdown:   5-hour limit — 14%  ·  resets 17:40
            Weekly limit —  4%  ·  resets Sun 03:00
            ─────────────
            Updated 14:26
            Refresh Now
            Display Style  ▸   Concentric rings · Percentages · Bars · ...
            Color          ▸   Claude · Thresholds · Monochrome · Heatmap · ...
            ✓ Launch at Login
              Show Dock Icon
            ─────────────
            Quit
```

> **Unofficial.** Not affiliated with, or endorsed by, Anthropic. It relies on a
> private endpoint that Claude Code uses internally: undocumented, and liable to
> change or break without notice. It reads your local Claude Code OAuth token from
> the Keychain and sends requests only to `api.anthropic.com` and
> `console.anthropic.com`. Use at your own risk.

## Display styles & color

Pick how the two values look from the **Display Style** menu: concentric rings
(default; outer = 5-hour, inner = weekly), percentages, bars, twin rings, gauges,
pie slices, or segments.

![Display styles](assets/styles.png)

The **Color** menu controls how usage maps to color:

- **Claude** (default): Anthropic's coral, tuned for light / dark menu bars; red ≥ 90 %
- **Monochrome**: adapts to the menu bar (light / dark)
- **Thresholds**: normal, orange ≥ 70 %, red ≥ 90 %
- **Heatmap**: green to red as usage climbs
- **System accent**: your macOS accent color

## Requirements

- Apple Silicon Mac, macOS 13 (Ventura) or later.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and
  **signed in**. That is what creates the Keychain item the app reads.

## Install

### Download (recommended)

Grab the latest **notarized** build from the
[Releases page](https://github.com/smeingast/claude-usage/releases/latest), unzip,
and drag **Claude Usage.app** to `/Applications`. It is signed with a Developer ID
and notarized by Apple, so it opens with no Gatekeeper warning.

### Build from source

Needs the Swift toolchain (Xcode, or Command Line Tools via `xcode-select --install`):

```sh
./build.sh              # build/Claude Usage.app  (ad-hoc signed)
./build.sh --install    # also copies to /Applications and clears quarantine
```

The result is a self-contained `.app` that uses only system frameworks. It is
deliberately light: one status item and a roughly 5-minute poll (plus an on-demand
refresh when you open the menu) with rate-limit backoff.

<details>
<summary><b>Maintainer: cutting a notarized release</b></summary>

With a **Developer ID Application** certificate installed, `build.sh` signs with a
hardened runtime automatically. To produce and zip the notarized, stapled `.app`:

```sh
./tools/notarize_setup.sh   # one-time: store Apple notary credentials in the keychain
./build.sh --notarize       # sign, submit to Apple, staple, verify
ditto -c -k --keepParent "build/Claude Usage.app" "build/Claude-Usage-v0.1.zip"
```

`build.sh` does not bundle the versioned zip itself, hence the `ditto` step.
`notarize_setup.sh` needs an **app-specific password** (account.apple.com,
Sign-In and Security). Your Apple ID and Team ID live only in the keychain and
never touch the repo.
</details>

## First run

- **Keychain prompt.** The first time it reads the token, macOS asks for
  permission. Click **Always Allow**. (It asks once more the first time it writes a
  refreshed token back, also **Always Allow**.)
- **Can't see it?** A menu-bar manager (Bartender, Ice, and similar) may be hiding
  it. Reveal the hidden section and ⌘-drag the item where you want it.

## How it works

| Piece | Detail |
|-------|--------|
| Data source | `GET /api/oauth/usage`: `five_hour.utilization`, `seven_day.utilization` (plus model-specific weekly caps when in use) |
| Auth | OAuth token from Keychain service `Claude Code-credentials`, auto-refreshed via the stored refresh token |
| Display | `NSStatusItem` rendered as text or a drawn glyph: 7 styles × 5 color modes |
| Footprint | Menu-bar only (`LSUIElement`); optional Dock icon; launch-at-login via `SMAppService` |

## Project layout

```
Sources/
  main.swift           App entry + single-instance guard
  AppDelegate.swift    Status item, menu, polling
  StatusRenderer.swift Display styles + color modes (text / drawn glyphs)
  UsageClient.swift    Usage fetch + token refresh
  Keychain.swift       Read/write the shared Claude Code credentials
  LoginItem.swift      Launch-at-login via SMAppService
Resources/
  Info.plist           Bundle manifest (LSUIElement = menu-bar only)
  AppIcon.icns         App icon
assets/                README images (icon, styles strip)
tools/
  icongen/main.swift   Renders the icon
  make_icon.sh         Builds AppIcon.icns
  notarize_setup.sh    One-time: store Apple notary credentials (see Install)
build.sh               Compile, bundle, sign, optionally notarize and install
```

## License

[MIT](LICENSE). Free to use, modify, and distribute. Provided **as is**, with no
warranty and no liability; use at your own risk.
