#!/usr/bin/env bash
#
# Shared helper: names the repository's main branch instead of assuming "main".
#
# More than one caller had the name written in. Renaming the branch would not
# have made either of them fail loudly — `git merge-base main HEAD` on a missing ref just returns
# nothing, which leaves the changed-file list empty, which means every gate is skipped and the stop
# is allowed. A guard that answers "nothing to check" when it cannot find its own baseline is worse
# than one that errors, because it looks exactly like a clean run.
#
# Usage:
#   source lib-main-branch.sh
#   branch=$(main_branch_name "$REPO_DIR")

# Prints the name of the repository's main branch.
#
# Asks the remote's HEAD first, since that is what the repository itself considers default. Failing
# that, takes the branch checked out in the *main working tree* — the linked worktrees are the
# session branches, so the one tree that is not a worktree is by construction sitting on the branch
# they get merged into. Only then does it guess main/master, and finally "main" so callers always
# get a usable string.
#
# $1 repository directory (default: $PWD)
main_branch_name() {
  local dir="${1:-$PWD}" ref name line

  ref=$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -n "$ref" ]]; then
    name="${ref##*/}"
    if [[ -n "$name" ]] && git -C "$dir" rev-parse --verify --quiet "$name" > /dev/null 2>&1; then
      printf '%s' "$name"
      return 0
    fi
  fi

  # The first record of `worktree list --porcelain` is always the main working tree.
  while IFS= read -r line; do
    if [[ "$line" == "branch "* ]]; then
      name="${line#branch refs/heads/}"
      [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
      break
    fi
    # A blank line ends the first record; a detached main tree has no branch to offer.
    [[ -z "$line" ]] && break
  done < <(git -C "$dir" worktree list --porcelain 2>/dev/null)

  for name in main master; do
    if git -C "$dir" rev-parse --verify --quiet "$name" > /dev/null 2>&1; then
      printf '%s' "$name"
      return 0
    fi
  done

  printf 'main'
}
