#!/usr/bin/env bash
#
# PreToolUse hook: the first edit to sensitive code in a session must be preceded by a written plan.
#
# The loop this repository enforces is explore → plan → implement → verify → commit → merge, and until
# now it enforced only the last three. Nothing stopped a session from editing eight files in the
# deploy path starting from its first tool call, and a typo fix and a rewrite of the go-live sequence
# travelled the same road.
#
# Which paths, and why by path: of the thresholds available — by tool, by size of change, by path —
# only by-path can be answered before the edit happens. It reuses the one list of sensitive paths
# (lib-sensitive-paths.sh) rather than introducing a second list to drift, and it does not fire on the
# other several hundred files in the repository — a gate that fires on everything gets removed, which
# is the Phase 7 lesson.
#
# What counts as a plan: a file under .claude/state/ named after the session. Gitignored, so it cannot
# make a worktree dirty and block the merge the session is working towards. An earlier design
# proposed the git directory for the same reason and asked for that to be verified — it does not work:
# a Write to <main>/.git/… is refused by the harness's own worktree isolation, and a Bash redirect
# there is refused by auto-worktree.sh. Inside the working tree, both tools work.
#
# Limit, stated rather than hidden: `printf 'x\ny\nz\n' > plan-<session>.md` passes. Like every hook
# here it guards against accident, not intent. What it changes is that starting without
# a plan is no longer the path of least resistance.
#
# Exit 0 allows. Exit 2 blocks and feeds stderr back to the agent.

set -uo pipefail

INPUT=$(cat)

# Fast bail, before any subprocess. Unlike a content rule this one may come first: an unreadable
# payload is already an allow here (see the note on the parse check below), so bailing early cannot
# turn a refusal into a pass.
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-bash-writes.sh"

bash_write_is_read_only_tool "$INPUT" && exit 0
case "$INPUT" in
  *'"file_path"'* | *'"command"'* | *'"path"'* | *'"notebook_path"'*) ;;
  *) exit 0 ;;
esac

# shellcheck source=/dev/null
source "$HOOK_DIR/lib-hook-log.sh"
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-sensitive-paths.sh"

# Fewest non-empty lines a plan may have. Three is what it takes to say what is being changed, why,
# and how it will be verified; one line is a title, and a title is not a plan.
MIN_PLAN_LINES=3

# An unreadable payload cannot be judged. Unlike a rule that guards correctness, which must fail
# closed, this one guards a process step, and blocking every edit
# in a session because one payload was malformed would be the annoyance that gets the hook deleted.
if ! printf '%s' "$INPUT" | jq -e . > /dev/null 2>&1; then
  hook_log require-plan - - note - unparseable-payload
  exit 0
fi

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // empty')
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')
SESSION=$(printf '%s' "$SESSION" | tr -c 'a-zA-Z0-9_-' '_')

# The main working tree, used to classify paths: from inside a worktree, an absolute path into the
# main tree would otherwise look like it is outside the repository and be skipped.
GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null || true)
[[ "$GIT_DIR" = /* ]] || GIT_DIR="$PWD/${GIT_DIR#./}"
[[ -n "$GIT_DIR" && -d "$GIT_DIR" ]] || exit 0
ROOT="${GIT_DIR%/.git}"

# The tree the session is actually working in, which is where its plan lives. The payload says so
# directly; $PWD is the fallback, and is what this hook runs in when the payload omits it.
PAYLOAD_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
STATE_ROOT=$(git -C "${PAYLOAD_CWD:-$PWD}" rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$STATE_ROOT" ]] || STATE_ROOT="$ROOT"

PLAN_FILE="$STATE_ROOT/.claude/state/plan-$SESSION.md"

# Every path this call would write.
TARGETS=""
case "$TOOL" in
  Edit | Write | NotebookEdit)
    TARGETS=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty') ;;
  Bash)
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
    [[ -n "$COMMAND" ]] || exit 0
    TARGETS=$(bash_write_targets "$COMMAND" "$ROOT") ;;
  *)
    # Same rule as auto-worktree.sh, and the same reason: the matcher is `*` now, so an unknown tool
    # name is not evidence of anything. Replacement text is. A tool that names a path and carries no
    # text is reading, and plenty of MCP tools do exactly that.
    printf '%s' "$INPUT" | jq -e \
      '.tool_input | (has("content") or has("new_string") or has("old_string") or has("edits"))' \
      > /dev/null 2>&1 || exit 0
    TARGETS=$(printf '%s' "$INPUT" |
      jq -r '.tool_input | (.file_path // .path // .notebook_path // empty)') ;;
esac
[[ -n "$TARGETS" ]] || exit 0

GUARDED=""
while IFS= read -r target; do
  [[ -n "$target" ]] || continue
  rel=$(sensitive_relpath "$target" "$ROOT")

  # Session state is not code, and its absence here was a deadlock rather than a nuisance:
  # `plan_paths_regex` includes `^\.claude/`, the plan lives at `.claude/state/plan-<session>.md`, so
  # the one action a session must take to satisfy this gate was refused by it — and the refusal below
  # ends "Use the Write tool", which is precisely the route it blocked. A Bash redirect happened to
  # work, because bash_write_targets already exempts the same directory, so only the documented path
  # was broken.
  #
  # Just this directory, not the whole of `bash_write_is_exempt`. That function also exempts /tmp and
  # /var/folders, and `mktemp -d` lands there — so calling it here made every fixture in
  # test-hooks.sh exempt and four real cases passed while proving nothing. The file already documents
  # that trap for the Bash branch. The broad exemptions buy nothing on this branch anyway: a guarded
  # path is always repo-relative, and an absolute path outside the repository never matches
  # plan_paths_regex to begin with.
  [[ "$rel" == .claude/state/* ]] && continue

  path_needs_plan "$target" "$ROOT" && GUARDED+="  $rel
"
done <<< "$TARGETS"

# Nothing sensitive in this call: not this hook's business, and not worth a log line either. Logging
# every unrelated edit in the repository would bury the decisions this hook actually made.
[[ -n "$GUARDED" ]] || exit 0

# A plan is present when the file exists and says at least a few things.
PLAN_LINES=0
if [[ -f "$PLAN_FILE" ]]; then
  PLAN_LINES=$(grep -cE '[^[:space:]]' "$PLAN_FILE" 2>/dev/null || echo 0)
fi

if [[ "$PLAN_LINES" -ge "$MIN_PLAN_LINES" ]]; then
  hook_log require-plan "$SESSION" "$TOOL" allow \
    "$(printf '%s' "$GUARDED" | head -1 | sed 's/^ *//')" plan-present
  exit 0
fi

cat >&2 <<EOF
This call edits code that needs a written plan first:
$GUARDED
This repository lists those paths in .claude/harness.json, plus .claude/ itself. Both are places
where the cost of a wrong turn is paid by someone other than whoever makes it — code whose damage
does not show up in its own diff, or a guard that silently stops guarding.

Write the plan here, then make this same call again:
  $PLAN_FILE

At least $MIN_PLAN_LINES non-empty lines, covering:
  - what is changing, and which files
  - which of this repository's rules the change is near, and why it does not break them
  - how it will be verified (which test, which gate)

That directory is gitignored on purpose: the plan never shows up in \`git status\`, so it cannot make
the worktree dirty and block the merge at the end. Use the Write tool.

If this change genuinely does not warrant a plan, say so to the user and let them decide — do not
route around the gate by writing three filler lines.
EOF
hook_log require-plan "$SESSION" "$TOOL" block \
  "$(printf '%s' "$GUARDED" | head -1 | sed 's/^ *//')" plan-missing
exit 2
