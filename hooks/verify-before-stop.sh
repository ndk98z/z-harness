#!/usr/bin/env bash
#
# Stop hook: runs the gates for whatever changed, then merges the session's worktree.
#
# The gate commands are not in here. This file is the frame — decide what changed, decide which gates
# that implies, run them, collect what failed, spend a budget, merge — and every command it runs comes
# from `.claude/harness.json` in the repository it was installed into. A plugin that shipped one
# project's test commands would be one project's Stop hook wearing a plugin's name.
#
# Configuration:
#
#   "gates": {
#     "router": { "match": "^apps/router/", "dir": "apps/router", "run": ["npm run lint", "npm test"] },
#     "web":    { "match": "^apps/web/",    "dir": "apps/web",    "run": ["npm run build", "npm test"] }
#   },
#   "reviewReceipt": { "agent": "invariant-reviewer" }
#
# Keys run in the order they are written. `match` is an extended regular expression tested against
# every changed path, so one gate can answer for several directories — a shared package that two
# applications import belongs in both of their patterns, and a change to it should run both.
#
# A gate's commands run in `dir` in order and stop at the first failure. Output is captured and shown
# only when something fails; a passing gate is silent. A command may also print
#
#   ### NOTE <name>
#
# and exit 0 to say something was left unverified without failing the stop — a missing local Docker
# daemon is not a broken gate, and treating it as one blocks every stop on that machine until someone
# deletes the hook. `### FAIL <name>` is accepted in the same way for a command that reports several
# results in one run.
#
# Exit 0 lets the stop proceed. Exit 2 blocks it and feeds stderr back so the failure gets fixed.

set -uo pipefail

INPUT=$(cat)
[[ -n "$INPUT" ]] || exit 0

# How many times a session may be sent back before the hook gives up and lets the stop through with a
# warning.
#
# The alternative — blocking until it is fixed — has been tried, and a guard that can trap a session
# in a loop is removed rather than fixed. What the budget buys is that giving up is loud: the stop
# goes through and says, in capitals, that nothing was verified.
MAX_ATTEMPTS=3

# Resolved once, before anything changes directory. Upstream this was recomputed in four places and
# three of them ran after the `cd`, so under a relative invocation the libraries silently failed to
# load and a regex read as the empty string — which matches every line.
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-hook-log.sh"
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-main-branch.sh"
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-sensitive-paths.sh"

STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
# The two-step is deliberate: piping jq straight into `tr -c` also translates the newline jq emits, so
# the id gains a trailing underscore and the second stop looks up a different file than the first one
# wrote — silently restoring the uncounted behaviour the budget exists to replace.
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -c 'a-zA-Z0-9_-' '_')

# Main repository root, the same value from the main working tree and from inside a worktree.
# `--show-toplevel` returns the worktree root when called inside one, and CLAUDE_PROJECT_DIR is not
# guaranteed to be set.
resolve_project_dir() {
  local common
  common=$(git rev-parse --git-common-dir 2>/dev/null || true)
  if [[ -n "$common" ]]; then
    [[ "$common" = /* ]] || common="$PWD/${common#./}"
    if [[ "$common" == */.git ]]; then
      printf '%s' "${common%/.git}"
      return 0
    fi
  fi
  git rev-parse --show-toplevel 2>/dev/null || true
}

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(resolve_project_dir)}"
PROJECT_DIR="${PROJECT_DIR%/}"
[[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]] || exit 0

# Attempt counters live in the git directory so they never appear as a change in any working tree.
# `--git-common-dir` and not "$PROJECT_DIR/.git": inside a worktree that path is a *file* pointing at
# the real git directory, so mkdir fails silently and the counter never persists.
GIT_DIR_PATH=$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null || true)
[[ "$GIT_DIR_PATH" = /* ]] || GIT_DIR_PATH="$PROJECT_DIR/${GIT_DIR_PATH#./}"
[[ -n "$GIT_DIR_PATH" && -d "$GIT_DIR_PATH" ]] || GIT_DIR_PATH="$PROJECT_DIR"
ATTEMPT_DIR="$GIT_DIR_PATH/z-harness-stop-attempts"
ATTEMPT_FILE="$ATTEMPT_DIR/$SESSION_ID"
mkdir -p "$ATTEMPT_DIR" 2>/dev/null
if [[ "$STOP_ACTIVE" == "true" && -f "$ATTEMPT_FILE" ]]; then
  ATTEMPT=$(( $(cat "$ATTEMPT_FILE" 2>/dev/null || echo 0) + 1 ))
else
  ATTEMPT=1
fi
printf '%s' "$ATTEMPT" > "$ATTEMPT_FILE" 2>/dev/null

# True when the path is a directory inside .claude/worktrees/ of this repository.
is_session_worktree() {
  local path root
  path=$(harness_realpath "${1%/}")
  root=$(harness_realpath "$PROJECT_DIR")
  [[ -n "$path" && "${path#"$root"/}" == .claude/worktrees/* ]]
}

# Which tree the session actually worked in. Without this the hook inspects the main tree while the
# session edited a worktree, finds it clean, and exits before running a single gate — so a worktree
# session silently has no gates at all.
PAYLOAD_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
SESSION_CWD="${PAYLOAD_CWD:-$PWD}"

resolve_worktree() {
  local count=0 pick="" line path
  if is_session_worktree "$SESSION_CWD"; then
    printf '%s' "$SESSION_CWD"
    return 0
  fi

  # The payload said where the session is, and it is not a worktree: this is a main-tree session.
  # Scanning anyway would adopt a worktree left over from some other session and merge a branch this
  # session never touched.
  if [[ -n "$PAYLOAD_CWD" ]]; then
    return 0
  fi
  while IFS= read -r line; do
    [[ "$line" == "worktree "* ]] || continue
    path="${line#worktree }"
    is_session_worktree "$path" || continue
    count=$((count + 1))
    pick="$path"
  done < <(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null)
  [[ "$count" -eq 1 ]] && printf '%s' "$pick"
}

WORKTREE=$(resolve_worktree)
WORK_DIR="${WORKTREE:-$PROJECT_DIR}"
cd "$WORK_DIR" || exit 0

MAIN_BRANCH=$(main_branch_name "$PROJECT_DIR")

# Uncommitted work. Comparing against the main branch on every stop would re-run every gate for
# changes already committed earlier in the branch, which makes the hook slow enough that someone turns
# it off.
#
# `-uall` is load-bearing. Plain `--porcelain` collapses an untracked directory to a single entry, so
# a session that creates a whole new directory sees one line naming its parent and every pattern
# misses. Adding a directory is exactly when gates matter most.
CHANGED=$(git status --porcelain -uall 2>/dev/null | sed 's/^...//' | tr -d '"')

# A worktree branch is one unit of work, and the merge below refuses a dirty tree. Judging it by
# uncommitted files alone would mean committing — the step that makes the merge possible — is what
# makes every gate skip.
if [[ -n "$WORKTREE" ]]; then
  BASE=$(git merge-base "$MAIN_BRANCH" HEAD 2>/dev/null || true)
  if [[ -n "$BASE" ]]; then
    CHANGED=$(printf '%s\n%s\n' "$CHANGED" "$(git diff --name-only "$BASE" HEAD 2>/dev/null)")
  fi
  CHANGED=$(printf '%s\n' "$CHANGED" | grep -v '^[[:space:]]*$' | sort -u)
fi

# In a worktree an empty diff still has to reach the merge step, which reports the branch state; on
# the main tree there is nothing left to do.
if [[ -z "$CHANGED" && -z "$WORKTREE" ]]; then
  exit 0
fi

# True when any changed path matches the pattern.
touched() {
  [[ -n "${1:-}" ]] || return 1
  printf '%s\n' "$CHANGED" | grep -qE "$1"
}

FAILURES=""
NOTES=""

# Records a failure and keeps going, so one stop reports every broken gate instead of making the
# session discover them one run at a time.
fail() {
  FAILURES+="
--- $1 ---
$2"
  hook_log verify-before-stop "$SESSION_ID" - block "$1" "${3:-gate-failed}"
}

# Records something to say out loud without blocking the stop.
#
# Notes are the record of running in a degraded mode, and they are logged because they were once
# stated to the model and then lost, so nobody could say how often it happened.
note() {
  NOTES+="
--- $1 ---
$2"
  hook_log verify-before-stop "$SESSION_ID" - note "$1" "${3:-degraded}"
}

CONFIG=$(harness_config_path "$PROJECT_DIR")

# Reads one gate's output and files each declared block. A command that exits non-zero without
# declaring anything gets a failure named after itself, so a gate can never fail silently just because
# it does not know the protocol.
#
# $1 gate name, $2 command, $3 exit status, $4 output
file_gate_output() {
  local gate="$1" cmd="$2" status="$3" out="$4"
  local line kind="" name="" body="" declared=0

  while IFS= read -r line; do
    case "$line" in
      '### FAIL '* | '### NOTE '*)
        [[ -n "$kind" ]] && { [[ "$kind" == fail ]] && fail "$name" "$body" || note "$name" "$body"; }
        declared=1
        if [[ "$line" == '### FAIL '* ]]; then kind=fail; name="${line#"### FAIL "}"
        else kind=note; name="${line#"### NOTE "}"; fi
        body="" ;;
      *)
        body+="${body:+
}$line" ;;
    esac
  done <<< "$out"
  [[ -n "$kind" ]] && { [[ "$kind" == fail ]] && fail "$name" "$body" || note "$name" "$body"; }

  if [[ "$status" -ne 0 && "$declared" -eq 0 ]]; then
    fail "$gate — $cmd" "$(printf '%s' "$out" | tail -40)"
  fi
}

# Runs one gate's commands in order, stopping at the first that fails.
#
# $1 gate name
run_gate() {
  local gate="$1" dir cmd out status
  dir=$(jq -r --arg g "$gate" '.gates[$g].dir // "."' "$CONFIG" 2>/dev/null)
  [[ -d "$WORK_DIR/$dir" ]] || {
    note "$gate — directory missing" \
      "The gate names $dir, which is not in this tree, so its commands did not run." gate-dir-missing
    return 0
  }
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    out=$( (cd "$WORK_DIR/$dir" && eval "$cmd") 2>&1 )
    status=$?
    file_gate_output "$gate" "$cmd" "$status" "$out"
    [[ "$status" -eq 0 ]] || break
  done < <(jq -r --arg g "$gate" '.gates[$g].run // [] | .[]' "$CONFIG" 2>/dev/null)
}

# One pass over the declared gates, in the order they were written.
GATED=""
if [[ -f "$CONFIG" ]]; then
  while IFS= read -r gate; do
    [[ -n "$gate" ]] || continue
    pattern=$(jq -r --arg g "$gate" '.gates[$g].match // empty' "$CONFIG" 2>/dev/null)
    touched "$pattern" || continue
    GATED+="${GATED:+,}$gate"
    run_gate "$gate"
  done < <(jq -r '.gates // {} | keys_unsorted[]' "$CONFIG" 2>/dev/null)
fi

# A review nothing here can perform, made observable rather than assumed.
#
# The six-invariant kind of rule — write order, where a value came from, whether an operation is
# idempotent — cannot be read out of a diff by any hook, so upstream a subagent read it and the gate
# could only ask nicely. A gate that cannot observe its own condition must not block; the fix is not
# to block blindly but to make the condition observable, which a receipt named after the reviewed
# commit does.
#
# Keyed to HEAD, so committing again after a review invalidates it. That is correct: it is a different
# diff, and the review belongs after the last commit rather than before it.
#
# Stated limit: an agent that writes the file without reading anything passes. This guards against
# forgetting, not against intent.
REVIEW_AGENT=$(jq -r '.reviewReceipt.agent // empty' "$CONFIG" 2>/dev/null)
if [[ -n "$REVIEW_AGENT" ]] && touched "$(invariant_paths_regex "$PROJECT_DIR")"; then
  HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || true)
  # Under the working tree, not in the git directory: .claude/state/ is gitignored and is the only
  # place an agent can actually write. A write into <main>/.git is refused by this plugin's own
  # worktree isolation, so a receipt kept there could never be produced by the reviewer meant to
  # produce it.
  REVIEW_DIR="$WORK_DIR/.claude/state"
  REVIEW_FILE="$REVIEW_DIR/review-$HEAD_SHA.json"
  if [[ -z "$HEAD_SHA" ]]; then
    note "$REVIEW_AGENT not confirmed" \
"This change touches paths listed in .claude/harness.json, but HEAD could not be resolved, so there is
nothing to key a review receipt to. Run the '$REVIEW_AGENT' subagent and report what it found." \
      reviewer-unconfirmed
  elif [[ ! -s "$REVIEW_FILE" ]]; then
    fail "review missing" \
"This change touches paths this repository lists as sensitive in .claude/harness.json — the code whose
damage does not show up in its own diff.

Run the '$REVIEW_AGENT' subagent on this diff and report what it found. It writes its receipt to
  $REVIEW_FILE
which is what this gate looks for. If the tree still has uncommitted changes, commit them first: the
receipt is keyed to HEAD, so a review of an earlier commit does not count for this one." \
      review-missing
  fi

  # Receipts for commits no longer near HEAD. Left alone they accumulate one file per reviewed commit
  # forever, in a directory that is otherwise all live state.
  if [[ -n "$HEAD_SHA" ]]; then
    RECENT=$(git rev-list -n 30 HEAD 2>/dev/null || true)
    for stale in "$REVIEW_DIR"/review-*.json; do
      [[ -e "$stale" ]] || continue
      sha="${stale##*/review-}"
      sha="${sha%.json}"
      printf '%s\n' "$RECENT" | grep -qx "$sha" || rm -f "$stale" 2>/dev/null
    done
  fi
fi

if [[ -n "$FAILURES" ]]; then
  # The escape hatch. A stuck gate must not trap the session in a loop, but it must not look like
  # success either: the stop goes through and the failure is stated as loudly as the block would have
  # been, because the user is the only one who can decide what to do about a gate that will not go
  # green.
  if [[ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]]; then
    cat >&2 <<EOF
GATES ARE STILL FAILING after $ATTEMPT attempts. The stop is being allowed through so the session
does not loop, but NOTHING HERE IS VERIFIED. Do not report this work as done or as tested. Tell the
user exactly which gates are red and what you tried.
$FAILURES${NOTES:+
$NOTES}
EOF
    # The SHA comes first and always in that position: given a commit on the main branch, the only way
    # to ask whether the session that produced it gave up in front of a red gate is to join this log
    # to that commit, and a commit records no session id.
    hook_log verify-before-stop "$SESSION_ID" - note \
      "$(git rev-parse HEAD 2>/dev/null || echo unknown) released after $ATTEMPT attempts" gate-released
    exit 0
  fi
  cat >&2 <<EOF
Gates failed for the files changed in this session (attempt $ATTEMPT of $MAX_ATTEMPTS). These are the
checks this repository requires before the work counts as done, so fix them rather than reporting the
task complete.
$FAILURES${NOTES:+
$NOTES}
EOF
  exit 2
fi

# Gates are green, so the next task in this session starts with a full budget again.
rm -f "$ATTEMPT_FILE" 2>/dev/null

# A passing stop is recorded too, and the reason says whether anything was left unverified. Without
# this line the log has numerators and no denominator: the degraded runs are counted and the runs are
# not, so "how often does a session finish without the slow tests" has no answer.
hook_log verify-before-stop "$SESSION_ID" - allow "${GATED:--}" \
  "$(if [[ -n "$NOTES" ]]; then echo gates-passed-degraded; else echo gates-passed; fi)"

if [[ -n "$NOTES" ]]; then
  printf 'Gates passed, with something left unverified:%s\n' "$NOTES" >&2
fi

# ── merge worktree ───────────────────────────────────────────────────────────────────────────────
# The worktree path is passed explicitly rather than left to the script to detect: this hook runs with
# its own working directory, and letting the merge infer its target from that is how it used to
# resolve HEAD in the main tree and decide there was nothing to merge.
if [[ -z "$WORKTREE" ]]; then
  exit 0
fi

MERGE_OUTPUT=$(bash "$HOOK_DIR/merge-worktree.sh" "$WORKTREE" "$SESSION_CWD" 2>&1)
MERGE_EXIT=$?

# A failing merge on its own counter, not the gate one. Sharing it means two unrelated failures spend
# one budget, and a session that fixed its gates arrives at the merge with nothing left — worse, a
# green gate deletes the counter a few lines above, so a shared counter never counts at all and a
# session that cannot merge can never stop. That loop is not hypothetical; this hook was in it.
MERGE_ATTEMPT_FILE="$ATTEMPT_FILE.merge"
if [[ "$MERGE_EXIT" -ne 0 ]]; then
  MERGE_ATTEMPT=$(( $(cat "$MERGE_ATTEMPT_FILE" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$MERGE_ATTEMPT" > "$MERGE_ATTEMPT_FILE" 2>/dev/null
  if [[ "$MERGE_ATTEMPT" -ge "$MAX_ATTEMPTS" ]]; then
    cat >&2 <<EOF
THE MERGE IS STILL FAILING after $MERGE_ATTEMPT attempts. The stop is being allowed through so the
session does not loop forever, but THE WORK IS NOT ON $MAIN_BRANCH. It is committed on the worktree
branch and nowhere else. Tell the user that, name the branch, and give them the merge command — do
not report the task as finished or as merged.
$MERGE_OUTPUT
EOF
    hook_log verify-before-stop "$SESSION_ID" - note \
      "$(git rev-parse HEAD 2>/dev/null || echo unknown) merge released after $MERGE_ATTEMPT attempts" \
      merge-released
    exit 0
  fi
  printf 'Gates passed but merge-worktree failed (attempt %s of %s):\n%s\n' \
    "$MERGE_ATTEMPT" "$MAX_ATTEMPTS" "$MERGE_OUTPUT" >&2
  exit 2
fi
rm -f "$MERGE_ATTEMPT_FILE" 2>/dev/null
if [[ -n "$MERGE_OUTPUT" ]]; then
  printf '%s\n' "$MERGE_OUTPUT" >&2
fi

exit 0
