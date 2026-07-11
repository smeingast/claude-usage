# Claude Usage

A macOS menu-bar app that shows your Claude usage limits at a glance (AppKit,
zero third-party dependencies, one colored glyph plus an instrument panel).

## Gates

Run both before handing a change back:

- `./build.sh` builds the canonical `Claude Usage.app` with plain `swiftc` over
  `Sources/*.swift` (ad-hoc signing is fine for local builds). Every file added
  under `Sources/` is compiled into the app by that glob, so it must stay
  dependency-free and plain-swiftc-safe.
- `swift test` runs the unit gate via `Package.swift` (the `ClaudeUsageCore`
  library target plus `ClaudeUsageTests`). Test-only fixtures and helpers live
  under `Tests/`, never under `Sources/`.

## Codex-support effort

The in-progress work to add Codex as a second provider is tracked in
`implement-codex-plan.md`, `implement-codex-brief.md` (the binding package
contract), and `design/codex-support/`.
