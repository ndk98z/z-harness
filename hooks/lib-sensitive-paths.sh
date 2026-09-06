#!/usr/bin/env bash
#
# Shared helper: the one list of paths this repository treats as sensitive, and the two questions
# asked about it.
#
# The list itself is not shipped with the plugin — it is a property of the repository the plugin is
# installed into. It is read from `.claude/harness.json`:
#
#   { "sensitivePaths": ["^src/billing/", "^migrations/"] }
#
# Two hooks used to carry their own copy of such a list, and three copies of one list is three
# chances to drift — the drift being silent, since a path dropped from one copy just stops being
# guarded there.
#
# Two questions, one list:
#
#   invariant_paths_regex   code where the properties no hook can read from a diff may break. A
#                           change here is worth a review before it is committed.
#   plan_paths_regex        the same code plus `.claude/` itself. A change here needs a written plan
#                           before the first edit: these are the places where a wrong turn is
#                           expensive, either because the damage is invisible in the diff or because
#                           the guard that would have caught it is the thing being edited.
#
# The second is derived from the first rather than written out again. Adding a path to the invariant
# group therefore also puts it behind the plan gate, which is the intended coupling.
#
# Usage:
#   source lib-sensitive-paths.sh
#   printf '%s\n' "$CHANGED" | grep -qE "$(invariant_paths_regex)" && ...
#   path_needs_plan "src/billing/charge.ts" && ...
#
# Requires jq.

# Prints the path of the configuration file, whether or not it exists.
#
# Resolved from the repository root rather than from the shell's cwd, because a hook runs with the
# cwd of the session and a session may sit in any subdirectory.
harness_config_path() {
  local root="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  printf '%s/.claude/harness.json' "${root%/}"
}

# Code covered by the properties that are invisible in the text of a diff.
#
# Kept as one extended regular expression rather than a list of globs because both callers already
# feed it to grep -E over a newline-separated list of changed files. Prints nothing when the
# repository declares no sensitive paths; every caller treats an empty regex as "matches nothing",
# never as "matches everything", which is the failure an empty pattern would otherwise cause.
#
# $1 repository root (optional)
invariant_paths_regex() {
  local config
  config=$(harness_config_path "${1:-}")
  [[ -f "$config" ]] || return 0

  jq -r '
    (.sensitivePaths // [])
    | map(select(type == "string" and length > 0))
    | if length == 0 then "" else "(" + join("|") + ")" end
  ' "$config" 2>/dev/null | tr -d '\n'
}

# The invariant group plus the harness itself.
#
# `.claude/` is here and not in the invariant group on purpose: editing a hook cannot break the
# properties the reviewer looks for, but it can quietly remove the check that would have caught
# something that does.
#
# $1 repository root (optional)
plan_paths_regex() {
  local invariant
  invariant=$(invariant_paths_regex "${1:-}")
  if [[ -n "$invariant" ]]; then
    printf '%s|%s' "$invariant" '^\.claude/'
  else
    printf '%s' '^\.claude/'
  fi
}

# Prints a path as the repository sees it: relative to the repository root, with any worktree prefix
# removed.
#
# Both callers receive absolute paths from a hook payload, and a file edited inside
# .claude/worktrees/<name>/ is the same file for every question here. Without the second step every
# check silently missed every worktree edit — which is where all edits are supposed to happen.
#
# $1 path, absolute or already relative
# $2 repository root (optional; defaults to CLAUDE_PROJECT_DIR then $PWD)
sensitive_relpath() {
  local path="$1" root="${2:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  root="${root%/}"

  path="${path#"$root"/}"
  path="${path#./}"
  # Both forms: the payload may give a path relative to a worktree, or an absolute one whose
  # worktree segment sits in the middle.
  path="${path#.claude/worktrees/*/}"
  path="${path##*/.claude/worktrees/*/}"
  printf '%s' "$path"
}

# True when a single path is code the reviewer should look at.
#
# An empty regex means the repository declared no sensitive paths, and the answer is no. Passing an
# empty pattern to grep would answer yes for every path, which would put every edit behind a gate
# nobody asked for and get the gate removed.
#
# $1 path, absolute or repo-relative
# $2 repository root (optional)
path_is_invariant_code() {
  local rel regex
  regex=$(invariant_paths_regex "${2:-}")
  [[ -n "$regex" ]] || return 1
  rel=$(sensitive_relpath "$1" "${2:-}")
  printf '%s' "$rel" | grep -qE "$regex"
}

# True when a single path may not be edited before a plan for this session exists.
#
# $1 path, absolute or repo-relative
# $2 repository root (optional)
path_needs_plan() {
  local rel regex
  regex=$(plan_paths_regex "${2:-}")
  [[ -n "$regex" ]] || return 1
  rel=$(sensitive_relpath "$1" "${2:-}")
  printf '%s' "$rel" | grep -qE "$regex"
}
