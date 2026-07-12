# Headroom (formerly Claude Usage)

macOS menu-bar app showing Claude and Codex usage limits (AppKit, zero
dependencies). Claude data comes from the authenticated usage API; Codex data
is reconstructed READ-ONLY from `~/.codex/sessions` rollout logs (never
`auth.json`, never the network).

## Gates (run both before handing a change back)

- `./build.sh`: canonical app build, plain `swiftc` over `Sources/*.swift`.
  That glob compiles EVERY file under `Sources/` into the app: keep them
  dependency-free and plain-swiftc-safe; fixtures and helpers go under
  `Tests/`, one-shot harnesses under `tools/`.
- `swift test`: unit gate via `Package.swift` (Sources minus `main.swift`).
  Includes pixel-parity corpora under `Tests/Fixtures/render-goldens/` that
  pin the renderer; regenerate only deliberately (README in that directory).

## Conventions and traps

- Comments explain WHY (constraints, reasoning), never what the next line does.
- The installed app in /Applications and dev builds in `build/` share the
  bundle id; a single-instance guard means you must quit one to run the other.
  Restore the installed app after manual checks.
- `design/` is gitignored by convention (design records, review archives).
- Rollout file/dir names are LOCAL time, timestamps UTC: order by mtime only.

## Status

Codex support is complete; the effort's records (package contract, plan,
amendments, review archives) live under `design/codex-support/`. Remaining:
release prep (in-app rebrand to Headroom, README with a new hero screenshot,
versioning, notarized release). Bundle id stays
`eu.smeingast.claude-menubar-usage` unless a migration is deliberately built:
it keys Application Support, defaults, the Keychain ACL, and the login item.
