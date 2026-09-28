# Shift

Run several coding tasks in parallel with the coding agents you already use.

Add a local Git project, describe what you want changed, and Shift gives each task its own Git worktree, branch, agent session and dev server. The agent works in the background; you come back when there's a checkmark, test it in your browser, and merge.

**Tell it what you want. Leave. Come back when there's a checkmark. Test it. Merge it.**

## Requirements

- macOS 26 or later
- [Claude Code](https://claude.com/claude-code) and/or [Codex](https://github.com/openai/codex) installed and signed in
- Git

## Install

Download `Shift-<version>.zip` from [Releases](https://github.com/fabiogiolito/shift/releases), unzip, and move Shift to Applications.

Builds are not notarized yet, so macOS blocks the first launch: open Shift once, dismiss the warning, then go to System Settings → Privacy & Security and click **Open Anyway**.

Shift checks for updates on its own (or Shift → Check for Updates…).

## Build from source

```sh
brew install xcodegen
scripts/build.sh          # prints the path of the built app
cd Core && swift test     # core tests
```

## License

MIT
