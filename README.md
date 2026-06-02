# Claude Usage (menu bar)

A tiny native macOS menu-bar app that shows your current Claude usage as
**5-hour / weekly** utilization, e.g. `14% / 4%`.

It reads the OAuth token Claude Code already stores in your login Keychain and
polls the same usage data that powers Claude Code's `/usage` command. No servers,
no accounts, no config files, no telemetry — it talks only to Anthropic.

```
Menu bar:   14% / 4%        (text turns orange ≥70%, red ≥90%)

Dropdown:   5-hour limit — 14%  ·  resets 17:40
            Weekly limit —  4%  ·  resets Sun 03:00
            ─────────────
            Updated 14:26
            Refresh Now
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
~2-minute poll with rate-limit backoff, and ephemeral network requests.

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
| Display | `NSStatusItem` text with monospaced digits and color thresholds |
| Footprint | Menu-bar only (`LSUIElement`); optional Dock icon; launch-at-login via a per-user LaunchAgent |

## Project layout

```
Sources/
  main.swift          App entry + single-instance guard
  AppDelegate.swift   Status item, menu, polling, rendering
  UsageClient.swift   Usage fetch + token refresh
  Keychain.swift      Read/write the shared Claude Code credentials
  LoginItem.swift     Launch-at-login via LaunchAgent
Resources/
  Info.plist          Bundle manifest (LSUIElement = menu-bar only)
  AppIcon.icns        App icon
tools/
  icongen/main.swift  Renders the icon
  make_icon.sh        Builds AppIcon.icns
build.sh              Compile → bundle → sign (→ install)
```

## License

[MIT](LICENSE) — free to use, modify, and distribute. Provided **as is**, with no
warranty and no liability; use at your own risk.
