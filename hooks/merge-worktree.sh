#!/usr/bin/env bash
#
# Merges a session worktree branch back onto the branch it was cut from, after gates pass.
#
# That branch is the one checked out in the main working tree, which is not necessarily the branch
# the repository publishes from — and when it is, this script refuses and prints the command instead,
# unless .claude/harness.json sets `"merge": { "intoDefaultBranch": true }`. Advancing the publish
# branch is a decision for a person, not a side effect of a session stopping.
#
# Called from verify-before-stop.sh, which passes the worktree path as $1 and the
# session's working directory as $2. Can also be run by hand from inside a
# worktree, in which case both are detected.
#
# Only runs when:
#   - The target directory is a registered worktree under .claude/worktrees/
#   - Its branch is not the target branch itself
#   - The target branch is not the one the repository publishes from, or the repository opted in
#   - There are no uncommitted changes
#
# Exit 0 on success or when there is nothing to do. Exit 2 on failure (blocks the
# stop, so the agent has to fix it rather than report the work as finished).
#
# The merge is fast-forward only: if the worktree branch has diverged from the
# target (someone committed to it while the agent was working), it fails and the
# agent must rebase.

set -uo pipefail

WORKTREE="${1:-}"
SESSION_CWD="${2:-$PWD}"

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-main-branch.sh"
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-sensitive-paths.sh"

# Main repository root. `--git-common-dir` returns "<repo>/.git" from both the
# main working tree and a linked worktree, unlike `--show-toplevel`, which
# returns the worktree root when called inside one.
#
# Asked of the worktree being merged when one was named, and only of the shell's own directory
# otherwise. Reading the cwd unconditionally is a bug this script had: told to merge a worktree in
# one repository while the shell stood in another, it resolved the second repository's root, decided
# the named path was not one of its worktrees, and exited 0 — merging nothing and reporting success.
# The Stop hook happened to hide it by changing directory first; running the script by hand, which
# the header above advertises, did not.
#
# $1 directory to ask from (optional)
resolve_project_dir() {
  local from="${1:-$PWD}" common
  [[ -d "$from" ]] || from="$PWD"
  common=$(git -C "$from" rev-parse --git-common-dir 2>/dev/null || true)
  if [[ -n "$common" ]]; then
    [[ "$common" = /* ]] || common="$from/${common#./}"
    if [[ "$common" == */.git ]]; then
      printf '%s' "${common%/.git}"
      return 0
    fi
  fi
  git -C "$from" rev-parse --show-toplevel 2>/dev/null || true
}

PROJECT_DIR=$(resolve_project_dir "${WORKTREE:-$PWD}")
PROJECT_DIR="${PROJECT_DIR%/}"
[[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]] || exit 0

# The branch this merge actually advances: the one checked out in the main working tree.
#
# Not the repository's default branch, which is what this used to ask for. `git merge --ff-only` run
# in the main tree moves whatever is checked out there, so asking about `main` while moving
# `feat/ui-rebuild` made every message and every refusal below describe a branch that was not being
# touched. See lib-main-branch.sh for the whole of that split.
TARGET_BRANCH=$(target_branch_name "$PROJECT_DIR")

# True when the path is a directory inside .claude/worktrees/ of this repository.
is_session_worktree() {
  local path root
  path=$(harness_realpath "${1%/}")
  root=$(harness_realpath "$PROJECT_DIR")
  [[ -n "$path" && "${path#"$root"/}" == .claude/worktrees/* ]]
}

# Falls back to detection when no path was passed: the current directory if it is
# a session worktree, otherwise the single registered one. More than one and the
# caller has to say which, because guessing would merge the wrong branch.
if [[ -z "$WORKTREE" ]]; then
  if is_session_worktree "$PWD"; then
    WORKTREE="$PWD"
  else
    count=0
    while IFS= read -r line; do
      [[ "$line" == "worktree "* ]] || continue
      path="${line#worktree }"
      is_session_worktree "$path" || continue
      count=$((count + 1))
      WORKTREE="$path"
    done < <(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null)
    if [[ "$count" -ne 1 ]]; then
      [[ "$count" -gt 1 ]] &&
        echo "merge-worktree: $count session worktrees registered; pass the one to merge as an argument." >&2
      exit 0
    fi
  fi
fi

# Not a worktree of this repository — nothing to merge, and not an error: the
# hook calls this unconditionally and most sessions run on the main tree.
if ! is_session_worktree "$WORKTREE"; then
  exit 0
fi
if [[ ! -d "$WORKTREE" ]]; then
  echo "merge-worktree: worktree path '$WORKTREE' does not exist" >&2
  exit 2
fi

# A detached main working tree has no branch to fast-forward. Nothing here can be done safely — a
# merge would move a detached HEAD — and it is not a failure of the session's work, so it is said and
# allowed rather than blocking a stop that has nothing left to fix.
if [[ -z "$TARGET_BRANCH" ]]; then
  echo "merge-worktree: the main working tree is on a detached HEAD; there is no branch to merge into." >&2
  echo "merge-worktree: check out the branch this work belongs on in $PROJECT_DIR, then stop again." >&2
  exit 0
fi

# Every git call below is explicitly scoped with -C. Relying on the caller's
# working directory is what made an earlier version resolve HEAD in the main tree
# and silently decide there was nothing to merge.
BRANCH=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ -z "$BRANCH" || "$BRANCH" == "HEAD" ]]; then
  echo "merge-worktree: worktree is not on a branch (detached HEAD). Skipping auto-merge." >&2
  exit 0
fi
# Any branch name is accepted except the target itself. EnterWorktree names
# branches "worktree-<name>", not "claude/*"; hardcoding the old prefix meant this
# script skipped every real worktree it was written to merge.
if [[ "$BRANCH" == "$TARGET_BRANCH" ]]; then
  echo "merge-worktree: worktree is on '$TARGET_BRANCH'. Nothing to merge." >&2
  exit 0
fi

if [[ -n "$(git -C "$WORKTREE" status --porcelain 2>/dev/null)" ]]; then
  echo "merge-worktree: uncommitted changes in worktree. Commit or stash before merging." >&2
  echo "merge-worktree:   git add . && git commit -m \"...\"" >&2
  exit 2
fi

TARGET_SHA=$(git -C "$PROJECT_DIR" rev-parse "$TARGET_BRANCH" 2>/dev/null || true)
BRANCH_SHA=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)

if [[ -z "$TARGET_SHA" || -z "$BRANCH_SHA" ]]; then
  echo "merge-worktree: could not resolve $TARGET_BRANCH or $BRANCH" >&2
  exit 2
fi

if [[ "$TARGET_SHA" == "$BRANCH_SHA" ]]; then
  echo "merge-worktree: branch '$BRANCH' has no commits beyond $TARGET_BRANCH. Nothing to merge."
  exit 0
fi

# The branch the repository publishes from is not advanced automatically unless the repository says so.
#
# This is the one question the earlier version could not even ask, because the branch it named as the
# target was the default branch — so on a repository sitting on `main` it fast-forwarded `main`
# silently, as a side effect of a session stopping, and on a repository sitting on a feature branch it
# said `main` while moving something else. Neither is a decision anybody made. A repository where
# that is the decision says so once, in .claude/harness.json, rather than having it happen to it.
#
# Exit 0 rather than 2, and that distinction is load-bearing: a refusal here is not something the
# session can fix by editing code, and the merge branch of verify-before-stop.sh spends a three-stop
# budget on anything that exits non-zero. Blocking would cost three stops and then release with a
# warning that the work is not merged — which is the same outcome as this message, three stops later.
# The worktree is deliberately left in place, since its commits are the only copy of the work.
DEFAULT_BRANCH=$(default_branch_name "$PROJECT_DIR")
INTO_DEFAULT=$(jq -r '.merge.intoDefaultBranch // false' "$(harness_config_path "$PROJECT_DIR")" 2>/dev/null)
if [[ "$TARGET_BRANCH" == "$DEFAULT_BRANCH" && "$INTO_DEFAULT" != "true" ]]; then
  cat >&2 <<EOF
merge-worktree: '$TARGET_BRANCH' is the branch this repository publishes from, so it is not merged
into automatically. The work is committed on '$BRANCH' and the worktree is left in place.

Tell the user, and give them the command:
  git -C '$PROJECT_DIR' merge --ff-only $BRANCH

To let the automatic merge run instead, either check out an integration branch in the main working
tree before the next session — the worktree is cut from whatever is checked out there, and merged back
onto the same branch — or set "merge": { "intoDefaultBranch": true } in .claude/harness.json.
EOF
  exit 0
fi

echo "merge-worktree: merging branch '$BRANCH' into $TARGET_BRANCH"

# Refresh the target's remote-tracking ref, so a target that has moved on the remote is visible here
# rather than at push time. Best-effort: ignored when there is no remote, when the branch has never
# been pushed, or when the machine is offline. The fast-forward check below reads local refs only.
git -C "$PROJECT_DIR" fetch origin "$TARGET_BRANCH" 2>/dev/null || true

# Diverged branches are reported here rather than left to `merge --ff-only`, so
# the message names the rebase the agent has to run.
#
# Asked about the target, which is what makes the answer usable. Against the default branch it was
# wrong in both directions: a target that had moved ahead still passed this check and then failed
# inside `git merge` with git's own message, so the rebase line below never printed; and a default
# branch that had moved independently of the target was refused here even though the fast-forward
# would have been fine.
if ! git -C "$PROJECT_DIR" merge-base --is-ancestor "$TARGET_SHA" "$BRANCH_SHA" 2>/dev/null; then
  echo "merge-worktree: fast-forward merge failed. Branch has diverged from $TARGET_BRANCH." >&2
  echo "merge-worktree: rebase the worktree branch: git -C '$WORKTREE' rebase $TARGET_BRANCH" >&2
  exit 2
fi

# The main working tree has to be clean, because the merge below checks files out
# into it. Refusing early gives a better message than git's own.
#
# Tracked changes only. Untracked files cannot make a fast-forward unsafe — git refuses on its own,
# and by name, if one would be overwritten — while counting them made this refuse always: a registered
# worktree is an untracked directory to the main tree, so `?? .claude/worktrees/` was present for the
# whole life of every worktree this script exists to merge. The directory is gitignored now too, but
# the narrower question is the correct one regardless of what happens to be ignored.
if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  echo "merge-worktree: the main working tree has uncommitted changes; refusing to merge into it." >&2
  echo "merge-worktree: commit or stash them in $PROJECT_DIR, then stop again." >&2
  exit 2
fi

# A real merge run from the main working tree, which is why the target is defined as the branch
# checked out there: this command advances that branch and no other. An earlier version used
# `git update-ref` on the theory that the branch could not be moved from another worktree — true, but
# this command runs against the main tree itself, and moving the ref alone left every merged file
# sitting in that tree at its old content, so it immediately reported the whole merge back as
# uncommitted reverse changes.
if ! MERGE_ERR=$(git -C "$PROJECT_DIR" merge --ff-only "$BRANCH_SHA" 2>&1); then
  echo "merge-worktree: git merge --ff-only failed" >&2
  printf '%s\n' "$MERGE_ERR" >&2
  exit 2
fi

echo "merge-worktree: branch '$BRANCH' merged into $TARGET_BRANCH"

# Cleanup is deliberately conditional, and the session's own directory is the
# thing being protected. Two earlier versions got this wrong: the first answered a
# failed `git worktree remove` with `rm -rf` on that directory, and the second
# guarded only on git's lock file, which is not set when a session re-enters an
# existing worktree by path — so the removal went through and deleted the
# directory the session was standing in, out from under it.
#
# A worktree the session is inside is never removed here. ExitWorktree and the
# session-exit prompt own that, and they can put the session somewhere else first.
if [[ "$SESSION_CWD" == "$WORKTREE" || "$SESSION_CWD" == "$WORKTREE"/* ]]; then
  echo "merge-worktree: the session is working inside this worktree; leaving it in place."
  echo "merge-worktree: it is removed by ExitWorktree or at session exit."
  exit 0
fi

if git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null |
  grep -A3 -F "worktree $WORKTREE" | grep -q '^locked'; then
  echo "merge-worktree: worktree is locked by a running session; leaving it in place."
  exit 0
fi

if ! git -C "$PROJECT_DIR" worktree remove "$WORKTREE" 2>/dev/null; then
  echo "merge-worktree: could not remove worktree at $WORKTREE; leaving it for manual cleanup." >&2
  echo "merge-worktree:   git worktree remove --force '$WORKTREE'" >&2
  exit 0
fi

if ! git -C "$PROJECT_DIR" branch -d "$BRANCH" 2>/dev/null; then
  echo "merge-worktree: could not delete branch '$BRANCH' (may have unmerged commits)" >&2
fi

echo "merge-worktree: worktree cleaned up"
exit 0
