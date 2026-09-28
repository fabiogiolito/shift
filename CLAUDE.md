# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Shift is a native macOS app (SwiftUI) that runs coding tasks in parallel using installed coding agents (Claude Code, Codex). One task = one Git worktree + branch + agent session + dev server. Product brief: `docs/BRIEF.md`. Architecture and rules: `docs/ARCHITECTURE.md`. Per-feature specs: `docs/specs/`. `docs/` is local only (gitignored, not in the public repo); it may be missing in a fresh clone.

## Commands

```sh
cd Core && swift test                          # all core tests
cd Core && swift test --filter GitServiceTests # one test class
scripts/build.sh                               # generates Shift.xcodeproj (xcodegen) and builds; prints the .app path
open build/Build/Products/Debug/Shift.app
scripts/build.sh --release build-release       # Release build (the only one that checks for updates)
scripts/release.sh 0.2.0 notes.md              # on main, clean tree: bump, build, sign, zip to dist/, update appcast.xml; prints publish commands (--publish runs them)
```

Releasing, signing and the Sparkle key: `docs/RELEASING.md`.

`Shift.xcodeproj` is generated from `project.yml` and is not checked in. New files under `App/` are picked up on the next `scripts/build.sh`.

## Layout

- `Core/` — Swift package `ShiftCore`: models, service contracts, services, orchestrator. No SwiftUI.
- `App/` — SwiftUI app target. Talks only to `AppModel`.
- `Core/Sources/ShiftCore/Models/Services.swift` — the contracts between orchestrator and machinery. Read this first.
