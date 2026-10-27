# Changelog

All notable changes to this plugin. Versions follow `version` in `.claude-plugin/plugin.json`.

An installed copy is cached by version, so a change to a hook does not reach existing installations
until the version moves. Any change in what a hook says or does comes with a bump.

## 0.6.1 — 2026-10-27

### Fixed

- The write detector no longer depends on bash 4 to loop over an empty list, which macOS
  `/bin/bash` 3.2 reports as an unbound variable under `set -u`.

### Added

- `LICENSE` (MIT), `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue and pull request
  templates, and this changelog.
- CI: the test suite runs on Linux, and on macOS under `/bin/bash` 3.2.
- `homepage`, `repository`, `license` and `keywords` in `plugin.json`.
- README: install straight from GitHub.

## 0.6.0 — 2026-10-27

### Changed

- **The stop merges a worktree back onto the branch checked out in the main working tree**, not onto
  the default branch, and **never advances the branch the repository publishes from** unless
  `.claude/harness.json` sets `"merge": { "intoDefaultBranch": true }`. When it refuses, it keeps the
  worktree and prints the command to run. A repository whose main tree sits on its default branch no
  longer gets an automatic merge.
- The Stop hook's gate baseline is that same branch, so a worktree cut from a feature branch is
  gated on its own commits only.

### Added

- `guard-push.sh`: allows `git push` to any branch except a protected one, which is the publish
  branch by default or `push.protectedBranches` in `.claude/harness.json`.

### Fixed

- The Stop hook finds the worktree root when the session stops from a subdirectory of it.
- The worktree-prefix strip no longer reduces a path to its file name when `CLAUDE_PROJECT_DIR` is
  unset, which had let worktree writes past content rules, the plan gate and the review receipt.
- The write detector keeps quote state across lines, ignores comments, and resolves variables
  assigned a literal path.
- Content rules and the Stop hook no longer miss a match in text larger than 64 KiB.
- The test suite no longer writes synthetic decisions into real hook logs.

## 0.5.0 — 2026-09-06

### Added

- The `progress-reader` agent, reading `stateDocs` from `.claude/harness.json` or falling back to
  conventional file names, and saying which file it used.

## 0.4.0 — 2026-09-06

### Added

- `check-content-rules.sh`: `contentRules` in `.claude/harness.json`, with `forbid` (refuse text being
  written) and `require` (refuse its removal), and a declared, expiring escape hatch for mutation
  testing.

## 0.3.0 — 2026-09-06

### Added

- `verify-before-stop.sh`: runs the `gates` the repository declares for what changed, blocks the stop
  while any is red (budgeted to three stops), supports `### NOTE` and `### FAIL`, enforces an optional
  `reviewReceipt`, then fast-forwards the worktree branch.

## 0.2.0 — 2026-09-06

### Added

- `check-conventions.sh` (`PostToolUse`): doc comments on every declaration and `forbiddenText`, both
  opt-in through a `conventions` block.

## 0.1.2 — 2026-09-06

### Added

- Tests for the shell write detector.

## 0.1.1 — 2026-09-06

### Fixed

- Messages no longer claim things a plugin cannot know about the repository it is installed in.

## 0.1.0 — 2026-09-06

### Added

- First release: worktree isolation (`auto-worktree.sh`), the plan gate (`require-plan.sh`) driven by
  `sensitivePaths`, `merge-worktree.sh`, and the decision log.
