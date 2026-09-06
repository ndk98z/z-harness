#!/usr/bin/env bash
#
# PreToolUse hook: blocks file edits outside a git worktree.
#
# Agent edits in the main working tree bypass the review barrier that a
# worktree provides: changes land directly on the checked-out branch with no
# diff gate. This hook forces the agent to use `EnterWorktree` (Claude Code's
# built-in tool) before making any file changes, so that edits go to a
# throwaway branch and merge-worktree.sh merges them back, fast-forward only.
#
# Exit 0 (allow) when already in a worktree.
# Exit 2 (block) when not, with instructions for the agent.

set -uo pipefail

INPUT=$(cat)

# Fast bail, before any subprocess: a payload with neither a path nor a command cannot write anything.
#
# Costs nothing today and is here for what it unblocks. settings.json still matches a list of tool
# names, which is an allowlist — a write-capable tool called anything else is unguarded, and no list of
# names can express "carries a file_path". The fix is a matcher that takes every tool and lets the
# hooks decide, and the thing standing in the way is price: three hooks on one tool call measured 94ms,
# nearly all of it fork and jq, which is too much to pay on every Read. This `case` is pure bash, no
# subprocess, so once the matcher widens a read-only call costs a bash startup and nothing else.
#
# Not widened in the same change on purpose: the wildcard syntax has to be confirmed against the
# Claude Code hook documentation first, and a matcher that silently matches nothing would disable
# every hook here — which is exactly how require-plan.sh spent its whole life doing nothing.
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-bash-writes.sh"

bash_write_is_read_only_tool "$INPUT" && exit 0
case "$INPUT" in
  *'"file_path"'* | *'"command"'* | *'"path"'* | *'"notebook_path"'*) ;;
  *) exit 0 ;;
esac

# Edit, Write, and any Bash command that writes a file. Reads and setup commands
# (npm ci, dotnet restore, docker compose) pass through — the agent needs the main
# tree for those.
#
# Bash was not checked at all until a probe showed `cat > file <<EOF` sailing past
# a hook that had just refused the identical Edit. Covering one of two equivalent
# ways to change a file only moves the edit to the other one.
#
# The field is `tool_name`; an earlier version read `.tool`, which is absent from
# the hook payload. That made TOOL empty, so the guard below matched neither
# "Edit" nor "Write" and the hook exited 0 for every call — allowing every edit
# it was written to block. The `// .tool` fallback keeps it working if the
# payload shape ever changes back.
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // empty')

# lib-bash-writes.sh is already sourced above, before the bail that needs it.
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-hook-log.sh"

SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "-"' 2>/dev/null)
SESSION=$(printf '%s' "$SESSION" | tr -c 'a-zA-Z0-9_-' '_')

# The main working tree, not $PWD. The exemption test treats anything outside the root it is given
# as somebody else's file, and from inside a worktree $PWD is the worktree — which would make every
# absolute path into the main tree, the exact thing this hook blocks, look external and pass.
# `--git-common-dir` resolves to "<main tree>/.git" from either place.
ROOT=$(git rev-parse --git-common-dir 2>/dev/null || true)
[[ "$ROOT" = /* ]] || ROOT="$PWD/${ROOT#./}"
ROOT="${ROOT%/.git}"
[[ -n "$ROOT" && -d "$ROOT" ]] || ROOT="$PWD"

# Every path this call would write, one per line.
TARGETS=""
case "$TOOL" in
  Edit | Write | NotebookEdit | "")
    # Check the file being edited, not the working directory: the session's cwd
    # follows it into the worktree, but the tool payload always carries the target.
    TARGETS=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')
    ;;
  Bash)
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
    [[ -n "$COMMAND" ]] || exit 0
    TARGETS=$(bash_write_targets "$COMMAND" "$ROOT")
    ;;
  *)
    # An unknown tool, judged by the *shape* of its payload rather than its name. This branch used to
    # `exit 0`, which made the whole guard an allowlist of tool names: rename the writing tool, or add
    # a new one, and nothing here applied.
    #
    # A path alone is not enough to call something a write, and that distinction is load-bearing now
    # that the matcher is `*`: this hook sees every MCP tool too, and plenty of them read a file by
    # path — `mcp__rider__read_file` among them. Refusing those would be refusing reads, which is both
    # wrong and the fastest way to get this file deleted. Replacement text is the signal: an unknown
    # tool that carries `content`, `new_string`, `old_string` or `edits` is writing.
    #
    # Stated limit: an unknown tool that writes without carrying text — a move, a touch, a chmod —
    # still gets through. That is narrower than the name allowlist it replaces, not wider.
    if printf '%s' "$INPUT" | jq -e \
      '.tool_input | (has("content") or has("new_string") or has("old_string") or has("edits"))' \
      > /dev/null 2>&1; then
      TARGETS=$(printf '%s' "$INPUT" |
        jq -r '.tool_input | (.file_path // .path // .notebook_path // empty)')
    fi
    ;;
esac

# Not logged: a call that writes nothing is not a decision about a write, and logging every `git
# status` would bury the lines that matter. The denominator this hook's log answers for is "of the
# calls that would write a file, how many were refused".
[[ -n "$TARGETS" ]] || exit 0

# Blocks as soon as one target lives outside a worktree. Matched as a path segment
# rather than against a project root. Resolving the root is what made this fragile:
# inside a worktree `--show-toplevel` returns the worktree itself, so every
# legitimate file in it looked like a main-tree path and the hook blocked the edits
# it exists to permit.
OUTSIDE=""
while IFS= read -r FILE; do
  [[ -n "$FILE" ]] || continue
  # Relative paths are resolved against the working directory before matching.
  [[ "$FILE" = /* ]] || FILE="$PWD/$FILE"
  [[ "$FILE" == */.claude/worktrees/* ]] && continue
  # The same exemptions the Bash branch applies, applied here too. Only that branch consulted them
  # before, so `Write` to /tmp was refused by a hook whose own refusal message ends "So does writing
  # to /tmp, to build output, or to anything outside this repository." Two branches reaching
  # different verdicts about one path is the shape of hole this directory exists to close.
  bash_write_is_exempt "$FILE" "$ROOT" && continue
  OUTSIDE+="  $FILE
"
done <<< "$TARGETS"

if [[ -z "$OUTSIDE" ]]; then
  # Allows are logged too. Without the denominator, a count of refusals says nothing about whether
  # the guard is well calibrated.
  hook_log auto-worktree "$SESSION" "${TOOL:--}" allow "$(head -1 <<< "$TARGETS")" ok
  exit 0
fi

hook_log auto-worktree "$SESSION" "${TOOL:--}" block \
  "$(printf '%s' "$OUTSIDE" | head -1 | sed 's/^ *//')" not-in-worktree

# File is in the main working tree — block the edit.
cat >&2 <<HOOKMSG
This call writes to the main working tree, not to an isolated worktree. Changes
here land directly on the checked-out branch with no diff gate.

Would be written:
$OUTSIDE
HOOKMSG
cat >&2 <<'HOOKMSG'

To edit files safely:
  1. Set up dependencies in the main tree first if needed (npm ci, dotnet
     restore, docker compose up -d).
  2. Call `EnterWorktree` with a descriptive name.
  3. All edits go into the worktree on a dedicated worktree-* branch.
  4. Commit in the worktree, then merge it back with merge-worktree.sh.

Read-only tasks (search, review, investigation) do not need a worktree. So does
writing to /tmp, to build output, or to anything outside this repository.
HOOKMSG
exit 2
