# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Shift is a native macOS app (SwiftUI) that runs coding tasks in parallel using installed coding agents (Claude Code, Codex). One task = one Git worktree + branch + agent session + dev server. An iOS companion app follows and steers tasks from a phone; all the work stays on the Mac. Product brief: `docs/BRIEF.md`. Architecture and rules: `docs/ARCHITECTURE.md`. Per-feature specs: `docs/specs/`. `docs/` is local only (gitignored, not in the public repo); it may be missing in a fresh clone.

## Commands

```sh
cd Core && swift test                          # all core tests
cd Core && swift test --filter GitServiceTests # one test class
scripts/build.sh                               # generates Shift.xcodeproj (xcodegen) and builds; prints the Mac .app path, last
                                               # if iOS/ or Core/ changed against main, also builds the iOS app and launches it in the booted simulator (not when run as the `Shift` build target: `ShiftMobile` has its own)
scripts/build.sh --ios                         # the same, whatever changed
open build/Build/Products/Debug/Shift.app
scripts/build.sh --release build-release       # Release build (the only one that checks for updates)
scripts/release.sh --publish                   # on main, clean tree: next patch version, AI-written notes, build, sign, notarize, publish
scripts/release.sh 0.2.0 notes.md              # explicit version and notes; without --publish, stops before going online
```

Releasing, signing and the Sparkle key: `docs/RELEASING.md`.

`Shift.xcodeproj` is generated from `project.yml` and is not checked in. New files under `App/` and `iOS/` are picked up on the next `scripts/build.sh`. To run on a real iPhone, open the project, set a team on the `ShiftMobile` target and run it from Xcode (regenerating the project clears the team).

A simulator build talks to its own Mac build, with no pairing: `scripts/build.sh` launches it with `SIMCTL_CHILD_SHIFT_SERVER=http://127.0.0.1:<port>?token=<token>`, read in Debug builds as `SHIFT_SERVER`. An iOS Simulator build target gets the same variable from `AppModel`. The port and token are the files `remote-port` and `remote-dev-token` in that Mac build's `SHIFT_HOME`. The token only works straight over loopback.

Debug builds add a demo project on launch (`DemoProject`, in that build's `SHIFT_HOME`): a Next.js "Hello World" with two finished tasks, one making the background blue and one making the text red, for testing the servers on main and on tasks, and their previews, on Mac and iOS. It starts over when it's removed or all its tasks are merged. `SHIFT_PREVIEW` builds skip it.

## Layout

- `Core/` — shared Swift package, no SwiftUI. Target `ShiftProtocol` builds for macOS and iOS: models, plain data, transcript parser, wire messages (`Wire.swift`); no Process or AppKit. Target `ShiftCore`, Mac only and re-exporting it: service contracts, services, orchestrator, `Remote/` (the server phones connect to, which only uses `AppModel`).
- `App/` — macOS SwiftUI app, target `Shift`. Talks only to `AppModel`.
- `iOS/` — iOS SwiftUI app, target `ShiftMobile`. Imports only `ShiftProtocol`, and talks only to `RemoteModel`. Also compiles `StatusIcon`, `MarkdownText` and `EmptyState` from `App/Views/Shared/`.
- `Core/Sources/ShiftCore/Models/Services.swift` — the contracts between orchestrator and machinery. Read this first.
