#!/usr/bin/env bash
#
# Shared helper: names the two branches the worktree workflow depends on, instead of assuming "main".
#
# Both the Stop hook and the merge script had the name written in. Renaming the branch would not
# have made either of them fail loudly — `git merge-base main HEAD` on a missing ref just returns
# nothing, which leaves the changed-file list empty, which means every gate is skipped and the stop
# is allowed. A guard that answers "nothing to check" when it cannot find its own baseline is worse
# than one that errors, because it looks exactly like a clean run.
#
# There are two branches here and one function used to answer for both, which is the bug this file
# was split to fix. `main_branch_name()` resolved the repository's default branch and was then used
# as the merge target — while the merge itself, `git merge --ff-only` run in the main working tree,
# advances whichever branch is checked out *there*. On a repository sitting on a feature branch those
# are different branches: the ancestor check asked about `main`, the fast-forward moved
# `feat/ui-rebuild`, and the success message named `main`. Nothing was corrupted, but every message
# and every refusal was about a branch that was not being touched, and the Stop hook's gate baseline
# was 73 files of somebody else's commits.
#
# So the two questions are asked separately, and neither answer is derived from the other:
#
#   target_branch_name    the branch a worktree merges back into: the one checked out in the main
#                         working tree, which is also what `worktree.baseRef: "head"` cuts from.
#                         Cut from it, fast-forward back onto it.
#   default_branch_name   the branch the repository publishes from. The automatic merge does not
#                         advance it unless the repository opts in — that is a decision for a person,
#                         not a side effect of stopping.
#
# Usage:
#   source lib-main-branch.sh
#   target=$(target_branch_name "$REPO_DIR")
#   [[ "$target" == "$(default_branch_name "$REPO_DIR")" ]] && ...

# Prints the branch checked out in the repository's main working tree, or nothing when it is detached.
#
# The first record of `worktree list --porcelain` is always the main working tree, and the linked
# worktrees are by construction the session branches — so the one tree that is not a worktree is
# sitting on the branch they merge into.
#
# Deliberately answered from one source only. Falling back to `default_branch_name` here would put a
# branch nobody has checked out in front of the merge, which is the conflation this file exists to
# undo; callers that need a resolvable ref from a detached main tree handle the empty answer
# themselves, and can say so.
#
# $1 repository directory (default: $PWD)
target_branch_name() {
  local dir="${1:-$PWD}" line name

  while IFS= read -r line; do
    if [[ "$line" == "branch "* ]]; then
      name="${line#branch refs/heads/}"
      [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
      break
    fi
    # A blank line ends the first record; a detached main tree has no branch to offer.
    [[ -z "$line" ]] && break
  done < <(git -C "$dir" worktree list --porcelain 2>/dev/null)
}

# Prints the name of the branch the repository publishes from.
#
# Asks the remote's HEAD first, since that is what the repository itself considers default, then a
# local main or master. The checked-out branch of the main working tree is the last resort rather
# than the second — the ordering is the whole point. As the second step it made this function
# indistinguishable from `target_branch_name` on any repository without a remote, so a protected-branch
# check written against it would refuse every merge. As the last step it answers the one case the
# earlier steps cannot: a single-branch repository called something else entirely, where the branch
# in the main tree genuinely is the branch everything is published from.
#
# Unlike the earlier version this does not require the name to resolve to a local ref. The remote's
# HEAD naming a branch that has never been checked out here still names the publish branch, and this
# answer is compared against a branch name, not passed to `rev-parse`.
#
# $1 repository directory (default: $PWD)
default_branch_name() {
  local dir="${1:-$PWD}" ref name

  ref=$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -n "$ref" ]]; then
    name="${ref##*/}"
    [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
  fi

  for name in main master; do
    if git -C "$dir" rev-parse --verify --quiet "$name" > /dev/null 2>&1; then
      printf '%s' "$name"
      return 0
    fi
  done

  target_branch_name "$dir"
}
