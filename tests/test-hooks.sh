#!/usr/bin/env bash
#
# Test suite for the harness hooks.
#
# Three classes of case, and the first two exist because the bugs they catch shipped in the
# repository this plugin was extracted from:
#
#   1. Executable check — read the hook list out of plugin.json and require every entry to exist and
#      carry the execute bit. A hook invoked by a bare path that is not executable fails silently,
#      and a silent failure reads exactly like a hook that decided to allow. One guard lived its
#      whole life that way, blocking nothing, and the evidence was negative: no log line ever named
#      it.
#   2. False refusal — every rule that blocks something also gets a case proving it has not opened
#      too wide. This half is more expensive to write than the blocking half, and skipping it is the
#      fastest way to get a guard removed by the person it keeps interrupting.
#   3. Behaviour — the configuration plumbing, including the worktree-prefix strip that every check
#      depends on.
#
# Run: bash tests/test-hooks.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0
FAIL=0

# Records one result and prints a line for the failures only, so a green run stays short.
#
# $1 outcome, "ok" or anything else
# $2 case name
check() {
  if [[ "$1" == "ok" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$2"
  fi
}

# Asserts two strings are equal.
#
# $1 expected, $2 actual, $3 case name
expect_eq() {
  if [[ "$1" == "$2" ]]; then check ok "$3"; else check no "$3 (expected '$1', got '$2')"; fi
}

# Asserts a command succeeds.
#
# $1 case name, rest: command
expect_true() {
  local name="$1"; shift
  if "$@"; then check ok "$name"; else check no "$name"; fi
}

# Asserts a command fails.
#
# $1 case name, rest: command
expect_false() {
  local name="$1"; shift
  if "$@"; then check no "$name"; else check ok "$name"; fi
}

# --- 1. executable check -------------------------------------------------------------------------
# The hook list comes from plugin.json rather than from a listing of the directory: a hook that is
# wired but missing, and a file that is present but unwired, are different bugs and only the wiring
# knows which is which.

HOOK_COMMANDS=$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$ROOT/.claude-plugin/plugin.json")
[[ -n "$HOOK_COMMANDS" ]] && check ok "plugin.json declares at least one hook" || check no "plugin.json declares at least one hook"

while IFS= read -r cmd; do
  [[ -n "$cmd" ]] || continue
  path="${cmd//\"/}"
  path="${path//\$\{CLAUDE_PLUGIN_ROOT\}/$ROOT}"
  expect_true "wired hook exists: ${path#"$ROOT"/}" test -f "$path"
  expect_true "wired hook is executable: ${path#"$ROOT"/}" test -x "$path"
done <<< "$HOOK_COMMANDS"

for f in "$ROOT"/hooks/*.sh; do
  expect_true "parses: ${f#"$ROOT"/}" bash -n "$f"
  expect_true "executable: ${f#"$ROOT"/}" test -x "$f"
done

# --- 2. sensitive paths, unconfigured ------------------------------------------------------------
# An installation with no .claude/harness.json must gate nothing except the harness directory. The
# failure to avoid is an empty regex reaching grep, which matches every line and would put every
# edit in the repository behind the plan gate.

# shellcheck source=/dev/null
source "$ROOT/hooks/lib-sensitive-paths.sh"

BARE=$(mktemp -d)
mkdir -p "$BARE/.claude"

expect_eq "" "$(invariant_paths_regex "$BARE")" "no config: invariant regex is empty"
expect_eq '^\.claude/' "$(plan_paths_regex "$BARE")" "no config: plan regex is the harness directory only"
expect_false "no config: ordinary source file is not invariant code" path_is_invariant_code "src/app.ts" "$BARE"
expect_false "no config: ordinary source file needs no plan" path_needs_plan "src/app.ts" "$BARE"
expect_true "no config: editing the harness still needs a plan" path_needs_plan ".claude/hooks/x.sh" "$BARE"

# Malformed configuration fails closed on the gate and open on the file list, never the reverse: a
# broken file must not silently gate the whole repository.
printf '%s' '{ not json' > "$BARE/.claude/harness.json"
expect_eq "" "$(invariant_paths_regex "$BARE")" "malformed config: invariant regex is empty, not universal"
expect_false "malformed config: ordinary file is not gated" path_is_invariant_code "src/app.ts" "$BARE"

printf '%s' '{"sensitivePaths": []}' > "$BARE/.claude/harness.json"
expect_eq "" "$(invariant_paths_regex "$BARE")" "empty list: invariant regex is empty"

# --- 3. sensitive paths, configured --------------------------------------------------------------

CONF=$(mktemp -d)
mkdir -p "$CONF/.claude"
printf '%s' '{"sensitivePaths": ["^src/billing/", "^migrations/"]}' > "$CONF/.claude/harness.json"

expect_true "configured: listed path is invariant code" path_is_invariant_code "src/billing/charge.ts" "$CONF"
expect_true "configured: second listed path is invariant code" path_is_invariant_code "migrations/001.sql" "$CONF"
expect_false "configured: unlisted path is not invariant code" path_is_invariant_code "src/ui/button.tsx" "$CONF"
expect_false "configured: near-miss prefix is not invariant code" path_is_invariant_code "docs/src/billing/notes.md" "$CONF"

# The coupling that must survive refactoring: a path added to the invariant group is behind the plan
# gate too, without being written down a second time.
expect_true "configured: invariant path also needs a plan" path_needs_plan "src/billing/charge.ts" "$CONF"
expect_true "configured: harness still needs a plan" path_needs_plan ".claude/settings.json" "$CONF"
expect_false "configured: unlisted path needs no plan" path_needs_plan "src/ui/button.tsx" "$CONF"

# --- 4. worktree prefix strip --------------------------------------------------------------------
# Without this every check silently misses every edit, because every edit is supposed to happen
# inside a worktree.

expect_eq "src/billing/charge.ts" \
  "$(sensitive_relpath "$CONF/.claude/worktrees/feature/src/billing/charge.ts" "$CONF")" \
  "relpath: absolute worktree path is stripped to repo-relative"
expect_eq "src/billing/charge.ts" \
  "$(sensitive_relpath ".claude/worktrees/feature/src/billing/charge.ts" "$CONF")" \
  "relpath: relative worktree path is stripped to repo-relative"
expect_eq "src/billing/charge.ts" \
  "$(sensitive_relpath "$CONF/src/billing/charge.ts" "$CONF")" \
  "relpath: plain absolute path is stripped to repo-relative"
expect_true "worktree edit to a sensitive path is still gated" \
  path_is_invariant_code "$CONF/.claude/worktrees/feature/src/billing/charge.ts" "$CONF"
expect_false "worktree edit to an ordinary path is still not gated" \
  path_is_invariant_code "$CONF/.claude/worktrees/feature/src/ui/button.tsx" "$CONF"

# --- 5. log location -----------------------------------------------------------------------------
# The log must never land in a working tree: a file there shows up in git status for every worktree
# and makes the merge refuse.

# shellcheck source=/dev/null
source "$ROOT/hooks/lib-hook-log.sh"
LOG_OVERRIDE=$(mktemp -d)/log.jsonl
expect_eq "$LOG_OVERRIDE" "$(Z_HARNESS_HOOK_LOG="$LOG_OVERRIDE" _hook_log_path)" \
  "log path: environment override wins"
expect_true "log path: default sits in the git directory" \
  bash -c 'cd "$1" && p=$(source "$2/hooks/lib-hook-log.sh" && _hook_log_path) && [[ "$p" == *"/.git/z-harness-hooks.jsonl" ]]' _ "$ROOT" "$ROOT"

rm -rf "$BARE" "$CONF"

printf '\nhooks: %d passed' "$PASS"
if [[ $FAIL -gt 0 ]]; then printf ', %d FAILED\n' "$FAIL"; exit 1; fi
printf '\n'
