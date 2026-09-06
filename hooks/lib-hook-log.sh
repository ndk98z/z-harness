#!/usr/bin/env bash
#
# Shared helper: appends one JSONL line per hook decision.
#
# Until now no hook recorded what it did, which left three questions unanswerable and every answer
# to them a guess:
#
#   - How often does a guard refuse something legitimate? The regexes in lib-bash-writes.sh were
#     tuned twice with no denominator, and the false positives were only found because a person
#     happened to hit one while doing other work.
#   - How many sessions run degraded? With Docker absent the API gate drops from the full suite to
#     two pure classes. verify-before-stop.sh says so in a note, but nothing counts the notes.
#   - After a block, does the work happen anyway by another route?
#
# Deliberately narrow: paths and short reason codes only. No file contents, no command bodies beyond
# a truncated line, no configuration values. The file is untracked, but that is not a reason to let
# anything from appsettings near it.
#
# Usage:
#   source lib-hook-log.sh
#   hook_log <hook> <session> <tool> <decision> <target> <reason>
#
# Read it back with, for example:
#   jq -s 'group_by(.reason) | map({(.[0].reason): length}) | add' "$(git rev-parse --git-common-dir)/z-harness-hooks.jsonl"

# Most lines to keep before trimming, and how many survive a trim. Small enough that the file stays
# readable by hand and never grows without bound; large enough to cover many sessions.
_HOOK_LOG_MAX_LINES=5000
_HOOK_LOG_KEEP_LINES=2500

# Prints the path of the log file, or nothing when this is not a git repository.
#
# Lives in the git directory, never in a working tree: a log inside the tree would show up in
# `git status` for every worktree and make merge-worktree.sh refuse to merge. `--git-common-dir` is
# what makes that work from a linked worktree, where "$PROJECT_DIR/.git" is a file rather than a
# directory — the same trap that silently broke the stop-attempt counter.
#
# Z_HARNESS_HOOK_LOG overrides the location. Only test-hooks.sh sets it, so that a suite which drives
# every hook dozens of times does not fill the repository's own log with synthetic decisions — the
# log exists to describe real sessions, and test traffic in it would make the false-positive counts
# it is meant to answer meaningless.
_hook_log_path() {
  if [[ -n "${Z_HARNESS_HOOK_LOG:-}" ]]; then
    printf '%s' "$Z_HARNESS_HOOK_LOG"
    return 0
  fi

  local common
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  [[ -n "$common" ]] || return 1
  [[ "$common" = /* ]] || common="$PWD/${common#./}"
  [[ -d "$common" ]] || return 1

  printf '%s/z-harness-hooks.jsonl' "$common"
}

# Keeps the tail of the log once it grows past the cap.
_hook_log_rotate() {
  local file="$1" lines
  lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ') || return 0
  [[ -n "$lines" && "$lines" -gt "$_HOOK_LOG_MAX_LINES" ]] || return 0

  local trimmed="$file.trimmed.$$"
  tail -n "$_HOOK_LOG_KEEP_LINES" "$file" > "$trimmed" 2>/dev/null &&
    mv "$trimmed" "$file" 2>/dev/null
  rm -f "$trimmed" 2>/dev/null
}

# Appends one decision.
#
# $1 hook name          auto-worktree | require-plan | any hook the installing repository adds
# $2 session id         already sanitised by the caller, or "-"
# $3 tool               Edit | Write | Bash | -
# $4 decision           allow | block | note
# $5 target             a path, or a command truncated by the caller
# $6 reason             I1 | I3 | I7 | I8 | KV_TTL | secret | bash-write | not-in-worktree |
#                       gate-failed | docker-absent | conventions | ok
#
# Never fails the caller. A hook that cannot write its log must still return the right verdict, so
# every failure path here is swallowed: logging must not be able to turn an allow into a block.
hook_log() {
  local file
  file=$(_hook_log_path) || return 0
  [[ -n "$file" ]] || return 0

  local target="${5:-}"
  # Truncated here as well as by callers, so one long line cannot bloat the file.
  [[ "${#target}" -gt 120 ]] && target="${target:0:120}"

  local line
  line=$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg hook "${1:--}" \
    --arg session "${2:--}" \
    --arg tool "${3:--}" \
    --arg decision "${4:--}" \
    --arg target "$target" \
    --arg reason "${6:--}" \
    '{ts:$ts, hook:$hook, session:$session, tool:$tool, decision:$decision, target:$target, reason:$reason}' \
    2>/dev/null) || return 0

  printf '%s\n' "$line" >> "$file" 2>/dev/null || return 0
  _hook_log_rotate "$file"

  return 0
}
