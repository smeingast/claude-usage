# Claude Usage (menu bar)

A tiny native macOS menu-bar app that shows your current Claude usage as
**5-hour / weekly** utilization, e.g. `14% / 4%`.

It reads the same OAuth token Claude Code stores in your login Keychain and
polls `https://api.anthropic.com/api/oauth/usage` once a minute — the exact data
behind Claude Code's `/usage`. No servers, no config files, no telemetry.

```
Menu bar:   14% / 4%        (text turns orange ≥70%, red ≥90%)

Dropdown:   5-hour limit — 14%  ·  resets 17:40
            Weekly limit —  4%  ·  resets Sun 03:00
            ─────────────
            Updated 14:26
            Refresh Now
            ✓ Launch at Login
            ─────────────
            Quit
```

## Build

Requires the Swift toolchain (Xcode or Command Line Tools: `xcode-select --install`).

```sh
./build.sh              # → build/Claude Usage.app
./build.sh --install    # also copies to /Applications and clears quarantine
```

The result is an **arm64**, self-contained `.app` (only system frameworks; the
Swift runtime ships with macOS). It's lightweight — one status item, a 60-second
timer, ephemeral network requests.

## Run on your other Macs

The built `.app` is portable. Either copy it over (e.g. AirDrop, or
`scp -r "build/Claude Usage.app" othermac:~/Applications/`) or clone this repo
and run `./build.sh` there.

Two things to know on each Mac:

1. **Claude Code must be signed in there** — that's what creates the Keychain
   item the app reads. (The app also refreshes the token itself when it expires,
   so it keeps working even when Claude Code isn't running.)
2. **First launch / Gatekeeper.** The app is ad-hoc signed, not notarized, so a
   copied bundle may be quarantined. Clear it once:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Claude Usage.app"
   ```
   (or right-click the app → **Open** the first time). `build.sh --install` does
   this for you.
3. **Keychain prompt.** The first time it reads the token, macOS asks for
   permission — click **Always Allow**.

## How it works

| Piece | Detail |
|-------|--------|
| Data source | `GET /api/oauth/usage` → `five_hour.utilization`, `seven_day.utilization` (+ model-specific weekly caps when in use) |
| Auth | OAuth token from Keychain service `Claude Code-credentials`; auto-refreshed via the stored refresh token against `/v1/oauth/token` |
| Display | `NSStatusItem` text, monospaced digits, color thresholds |
| Launch at login | A per-user LaunchAgent plist in `~/Library/LaunchAgents/` |

## Project layout

```
Sources/
  main.swift          App entry + single-instance guard
  AppDelegate.swift   Status item, menu, polling, rendering
  UsageClient.swift   Usage fetch + token refresh
  Keychain.swift      Read/write the shared Claude Code credentials
  LoginItem.swift     Launch-at-login via LaunchAgent
Resources/Info.plist  Bundle manifest (LSUIElement = menu-bar only)
build.sh              Compile → bundle → sign (→ install)
```
