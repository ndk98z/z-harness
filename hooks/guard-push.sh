#!/usr/bin/env bash
#
# PreToolUse hook: `git push` is allowed, except when it would update a protected branch.
#
# Upstream, the deploy workflows fired on a push to the publish branch only, so a push of any other
# branch started nothing but CI while a push of that one was a deploy. The line belongs where the
# consequence is, which is why this guards a branch rather than the command.
#
# Which branches: `.claude/harness.json` may list them,
#
#   { "push": { "protectedBranches": ["main", "release"] } }
#
# and an empty list turns the guard off. With no list, the protected branch is the one the repository
# publishes from (`default_branch_name` in lib-main-branch.sh): origin/HEAD, then a local main or
# master.
#
# Why a hook and not a deny entry: deny rules match a command prefix, and "updates main" is not a
# prefix. `git push` with main checked out, `git push origin HEAD:main`, `git push -f origin
# +x:refs/heads/main`, `git push --all`, an alias for push — each reaches main and none starts with
# `git push origin main`. So this reads the command the way git would: global options, aliases,
# refspecs, `remote.<name>.push`, `push.default`, and the branch checked out where the command runs.
#
# Fails closed on what it cannot read. A push whose remote or refspec comes from `$VAR` or command
# substitution, or a `git … push` buried in `xargs`/`find -exec`, is refused: the destination is not
# in the text, so it cannot be shown not to be protected. `--dry-run` is always allowed — it updates
# nothing, and it is how this hook gets probed by hand.
#
# Like every hook here it is a guard against accident, not a sandbox: a script file that pushes, or
# `gh api` writing the ref directly, walks past it. Server-side branch protection is the real lock.
#
# Exit 0 allows. Exit 2 blocks and feeds stderr back to the agent.

set -uo pipefail

INPUT=$(cat)

# Fast bail before any subprocess: every tool call runs this, and nearly none of them push.
case "$INPUT" in
  *'"tool_name":"Bash"'* | *'"tool_name": "Bash"'*) ;;
  *) exit 0 ;;
esac
# A command without the word can still push through an alias (`git p`), so one cheap config read
# decides whether a git command needs a closer look. An alias defined inline with `-c` mentions
# push in the command itself.
case "$INPUT" in
  *push*) ;;
  *git*)
    git config --get-regexp '^alias\.' 2>/dev/null | grep -q push || exit 0 ;;
  *) exit 0 ;;
esac

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-hook-log.sh"
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-bash-writes.sh"
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-main-branch.sh"
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-sensitive-paths.sh"

# A Bash payload that mentions push but cannot be parsed might be the one push this hook exists for,
# so it fails closed, the way a content rule does; a process-step hook such as the plan gate allows.
if ! printf '%s' "$INPUT" | jq -e . > /dev/null 2>&1; then
  hook_log guard-push - Bash block - unparseable-payload
  echo "guard-push: the tool payload could not be parsed, so a possible git push could not be checked." >&2
  exit 2
fi

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[[ -n "$COMMAND" ]] || exit 0
# Captured before sanitising: piping jq straight into `tr -c` turned its trailing newline into `_`, so
# this hook's log lines carried a session id no other hook's lines matched.
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "-"')
SESSION=$(printf '%s' "$SESSION" | tr -c 'a-zA-Z0-9_-' '_')
START_DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[[ -n "$START_DIR" && -d "$START_DIR" ]] || START_DIR="$PWD"

# Branches no push may update: the repository's own list when it declares one, otherwise the branch it
# publishes from. Resolved once, from where the command starts.
#
# The configuration is read from the main repository root, not from the command's directory, so a
# session inside a worktree is judged by the same list as one on the main tree.
CONFIG_ROOT=$(git -C "$START_DIR" rev-parse --git-common-dir 2>/dev/null || true)
[[ -z "$CONFIG_ROOT" || "$CONFIG_ROOT" = /* ]] || CONFIG_ROOT="$START_DIR/${CONFIG_ROOT#./}"
CONFIG_ROOT="${CONFIG_ROOT%/.git}"
CONFIG=$(harness_config_path "${CLAUDE_PROJECT_DIR:-${CONFIG_ROOT:-$START_DIR}}")
PROTECTED=()
if [[ -f "$CONFIG" ]] && jq -e '.push.protectedBranches | type == "array"' "$CONFIG" > /dev/null 2>&1; then
  while IFS= read -r branch; do
    [[ -n "$branch" ]] && PROTECTED+=("$branch")
  done < <(jq -r '.push.protectedBranches[] | strings' "$CONFIG" 2>/dev/null)
  # Declared empty: the repository has chosen not to guard pushes at all.
  [[ "${#PROTECTED[@]}" -gt 0 ]] || exit 0
else
  DEFAULT_BRANCH=$(default_branch_name "$START_DIR")
  [[ -n "$DEFAULT_BRANCH" ]] && PROTECTED+=("$DEFAULT_BRANCH")
  [[ "${#PROTECTED[@]}" -gt 0 ]] || exit 0
fi
PROTECTED_LIST=$(printf '%s, ' "${PROTECTED[@]}")
PROTECTED_LIST="${PROTECTED_LIST%, }"

# Reasons to refuse, one per line, and whether any push was seen at all (for the log).
BLOCK_REASONS=""
PUSH_SEEN=0
DRY_RUN_SEEN=0

# Records a reason to refuse.
block() {
  BLOCK_REASONS+="  - $1
"
}

# True when a branch name (already stripped of refs/heads/) is protected.
is_protected() {
  local name="$1" p
  for p in "${PROTECTED[@]}"; do
    [[ "$name" == "$p" ]] && return 0
  done
  return 1
}

# Splits shell text into words, one per line as `<kind>\t<text>`.
#
# kind is W for a literal word, D for a word holding an unquoted or double-quoted `$` or backtick
# (its value is not in the text), and S for a command boundary (`;`, `&`, `|`, newline, parentheses).
# Quotes are removed the way the shell removes them, so `git push origin "main"` yields `main` — the
# quote-blanking in lib-bash-writes.sh is right for finding redirects and wrong here, where the quoted
# text is exactly what matters. Redirections and their targets are dropped, so `2>&1` is not read as
# a refspec called `2`. A newline inside a quoted word is written as \037 to keep one word per line.
#
# $1 shell text, heredoc bodies already removed
tokenize() {
  awk '
    { text = (NR == 1) ? $0 : text "\n" $0 }
    function flush() {
      if (has) {
        if (skipnext) skipnext = 0
        else { gsub(/\n/, "\037", cur); print (dyn ? "D" : "W") "\t" cur }
      }
      cur = ""; has = 0; dyn = 0
    }
    END {
      n = length(text); q = ""; cur = ""; has = 0; dyn = 0; skipnext = 0
      for (i = 1; i <= n; i++) {
        c = substr(text, i, 1)
        if (q == "\047") {
          if (c == "\047") q = ""; else cur = cur c
          continue
        }
        if (q == "\"") {
          if (c == "\\") {
            nx = substr(text, i + 1, 1); i++
            if (nx == "$" || nx == "`" || nx == "\"" || nx == "\\") cur = cur nx
            else if (nx != "\n") cur = cur "\\" nx
          } else if (c == "\"") q = ""
          else { if (c == "$" || c == "`") dyn = 1; cur = cur c }
          continue
        }
        if (c == "\\") {
          nx = substr(text, i + 1, 1); i++
          if (nx != "\n") { cur = cur nx; has = 1 }
          continue
        }
        if (c == "\047" || c == "\"") { q = c; has = 1; continue }
        if (c == " " || c == "\t") { flush(); continue }
        if (c == "#" && !has) {
          while (i < n && substr(text, i + 1, 1) != "\n") i++
          continue
        }
        if (c == ">" || c == "<" || (c == "&" && substr(text, i + 1, 1) == ">")) {
          # A file-descriptor number glued to the operator belongs to it, not to the arguments.
          if (cur ~ /^[0-9]+$/ && !dyn) { cur = ""; has = 0 }
          flush()
          while (i < n && substr(text, i + 1, 1) ~ /[<>&|-]/) i++
          # A heredoc marker or a duplicated descriptor has no file word after it worth reading,
          # but skipping one more word is harmless next to reading a filename as a refspec.
          skipnext = 1
          continue
        }
        if (c == ";" || c == "&" || c == "|" || c == "\n" || c == "(" || c == ")") {
          flush(); skipnext = 0; print "S\t"; continue
        }
        if (c == "$" || c == "`") dyn = 1
        cur = cur c; has = 1
      }
      flush()
    }
  ' <<< "$1"
}

# Resolves a directory word against a base. Prints nothing when the result is unknown.
#
# $1 word, $2 base directory (may be empty = unknown)
resolve_dir() {
  local word="$1" base="$2"
  case "$word" in
    "~") word="$HOME" ;;
    "~/"*) word="$HOME/${word#\~/}" ;;
  esac
  if [[ "$word" != /* ]]; then
    [[ -n "$base" ]] || return 0
    word="$base/$word"
  fi
  (cd "$word" 2>/dev/null && pwd) || true
}

# Global options (`-c`, `--git-dir`, …) of the git invocation being judged. One at a time, so global.
GOPTS=()

# Runs git in a directory with the command's own global options, so `-c push.default=…` counts.
#
# Every array expansion in this file uses the `${a[@]+…}` form: hooks run under macOS's /bin/bash
# 3.2, where expanding an empty array under `set -u` is an "unbound variable" error.
#
# $1 directory, rest: git arguments
git_in() {
  local dir="$1"
  shift
  git -C "$dir" ${GOPTS[@]+"${GOPTS[@]}"} "$@" 2>/dev/null
}

# Checks one refspec for a protected destination.
#
# $1 refspec, $2 directory (may be empty), $3 remote, $4 "1" when the refspec came from
# remote.<name>.push rather than the command line
check_refspec() {
  local spec="$1" dir="$2" remote="$3" from_config="$4"
  local s="${spec#+}" src dst cur

  [[ "$s" == ^* ]] && return 0
  if [[ "$s" == ":" ]]; then
    block "\`$spec\` pushes every matching branch, $PROTECTED_LIST included"
    return
  fi

  if [[ "$s" == *:* ]]; then
    src="${s%%:*}"
    dst="${s#*:}"
    if [[ -z "$dst" ]]; then
      block "\`$spec\` has no destination; not guessing where it goes"
      return
    fi
  else
    src="$s"
    dst="$s"
    # Without a destination, a configured push mapping decides where the branch lands.
    if [[ "$from_config" != 1 && -n "$dir" ]] &&
      [[ -n "$(git_in "$dir" config --get-all "remote.$remote.push")" ]]; then
      block "\`$spec\` has no destination and remote.$remote.push remaps it; give \`src:dst\` explicitly"
      return
    fi
    if [[ "$src" == "HEAD" || "$src" == "@" ]]; then
      if [[ -z "$dir" ]]; then
        block "\`$spec\` means the current branch, and the directory it runs in is not known"
        return
      fi
      cur=$(git_in "$dir" symbolic-ref --short -q HEAD)
      [[ -n "$cur" ]] || return 0
      dst="$cur"
    fi
  fi

  if [[ "$dst" == *"*"* ]]; then
    block "\`$spec\` is a pattern, and patterns can cover $PROTECTED_LIST"
    return
  fi
  dst="${dst#refs/heads/}"
  dst="${dst#heads/}"
  if [[ "$dst" == "HEAD" ]]; then
    block "\`$spec\` updates the remote's HEAD branch, which is the publish branch"
    return
  fi
  is_protected "$dst" && block "\`$spec\` updates $dst"
  return 0
}

# Analyses one `git push` invocation.
#
# $1 directory (may be empty), rest: `kind\ttext` lines after `push`
check_push() {
  local dir="$1"
  shift
  PUSH_SEEN=1

  local dry=0 all=0 prune=0 tags=0 endopts=0 dyn=0 repo_opt="" want_arg=""
  local -a pos=()
  local item kind tok
  for item in "$@"; do
    kind="${item%%$'\t'*}"
    tok="${item#*$'\t'}"
    if [[ -n "$want_arg" ]]; then
      [[ "$want_arg" == repo ]] && repo_opt="$tok"
      [[ "$want_arg" == repo && "$kind" == D ]] && dyn=1
      want_arg=""
      continue
    fi
    if [[ "$endopts" == 1 ]]; then
      pos+=("$tok"); [[ "$kind" == D ]] && dyn=1
      continue
    fi
    case "$tok" in
      --) endopts=1 ;;
      -n | --dry-run) dry=1 ;;
      --all | --mirror | --branches) all=1 ;;
      --prune) prune=1 ;;
      --tags) tags=1 ;;
      --repo=*) repo_opt="${tok#--repo=}"; [[ "$kind" == D ]] && dyn=1 ;;
      --repo) want_arg=repo ;;
      -o | --push-option | --receive-pack | --exec) want_arg=skip ;;
      --*) ;;
      -o*) ;;
      -*) [[ "$tok" == *n* ]] && dry=1 ;;
      *) pos+=("$tok"); [[ "$kind" == D ]] && dyn=1 ;;
    esac
  done

  if [[ "$dry" == 1 ]]; then
    DRY_RUN_SEEN=1
    return 0
  fi
  if [[ "$all" == 1 ]]; then
    block "--all / --mirror / --branches push every branch, $PROTECTED_LIST included"
    return
  fi
  if [[ "$prune" == 1 ]]; then
    block "--prune can delete remote branches, $PROTECTED_LIST included"
    return
  fi
  if [[ "$dyn" == 1 ]]; then
    block "the remote or a refspec comes from a variable or command substitution, so the destination is not in the text"
    return
  fi

  local remote="${pos[0]:-$repo_opt}"
  local spec

  if [[ "${#pos[@]}" -gt 1 ]]; then
    for spec in "${pos[@]:1}"; do
      check_refspec "$spec" "$dir" "${remote:-origin}" 0
    done
    return
  fi

  # No refspec: `--tags` alone pushes only tags.
  [[ "$tags" == 1 ]] && return 0

  if [[ -z "$dir" ]]; then
    block "a bare \`git push\` pushes the current branch, and the directory it runs in is not known"
    return
  fi

  local cur
  cur=$(git_in "$dir" symbolic-ref --short -q HEAD)
  if [[ -z "$remote" ]]; then
    remote=$(git_in "$dir" config --get "branch.$cur.pushRemote")
    [[ -n "$remote" ]] || remote=$(git_in "$dir" config --get remote.pushDefault)
    [[ -n "$remote" ]] || remote=$(git_in "$dir" config --get "branch.$cur.remote")
    [[ -n "$remote" ]] || remote=origin
  fi

  local configured
  configured=$(git_in "$dir" config --get-all "remote.$remote.push")
  if [[ -n "$configured" ]]; then
    while IFS= read -r spec; do
      [[ -n "$spec" ]] && check_refspec "$spec" "$dir" "$remote" 1
    done <<< "$configured"
    return
  fi

  local mode dst
  mode=$(git_in "$dir" config --get push.default)
  case "${mode:-simple}" in
    matching)
      block "push.default=matching pushes every branch that exists on the remote, $PROTECTED_LIST included"
      return ;;
    nothing) return 0 ;;
    upstream | tracking)
      dst=$(git_in "$dir" config --get "branch.$cur.merge")
      dst="${dst#refs/heads/}" ;;
    *) dst="$cur" ;;
  esac
  # Detached HEAD: git refuses a bare push by itself.
  [[ -n "$dst" ]] || return 0
  is_protected "$dst" && block "a bare \`git push\` here pushes $dst (the branch checked out in $dir)"
  return 0
}

# Analyses a `git` invocation: global options, aliases, then push.
#
# $1 directory (may be empty), rest: `kind\ttext` lines after `git`
check_git() {
  local dir="$1"
  shift
  local -a rest=("$@")
  local kind tok next nextkind
  GOPTS=()

  while [[ "${#rest[@]}" -gt 0 ]]; do
    kind="${rest[0]%%$'\t'*}"
    tok="${rest[0]#*$'\t'}"
    next="${rest[1]:-}"
    nextkind="${next%%$'\t'*}"
    next="${next#*$'\t'}"
    case "$tok" in
      -C)
        if [[ "$nextkind" == D ]]; then dir=""; else dir=$(resolve_dir "$next" "$dir"); fi
        rest=("${rest[@]:2}") ;;
      -c) GOPTS+=(-c "$next"); rest=("${rest[@]:2}") ;;
      --git-dir | --work-tree | --namespace | --config-env)
        GOPTS+=("$tok" "$next"); rest=("${rest[@]:2}") ;;
      --git-dir=* | --work-tree=* | --namespace=* | --config-env=*)
        GOPTS+=("$tok"); rest=("${rest[@]:1}") ;;
      -*) rest=("${rest[@]:1}") ;;
      *) break ;;
    esac
  done
  [[ "${#rest[@]}" -gt 0 ]] || return 0

  kind="${rest[0]%%$'\t'*}"
  tok="${rest[0]#*$'\t'}"
  rest=("${rest[@]:1}")

  if [[ "$tok" == push ]]; then
    check_push "$dir" ${rest[@]+"${rest[@]}"}
    return
  fi

  if [[ "$kind" == D ]]; then
    local r
    for r in ${rest[@]+"${rest[@]}"}; do
      if [[ "${r#*$'\t'}" == push ]]; then
        block "the git subcommand comes from a variable and push appears after it"
        return
      fi
    done
    return 0
  fi

  # An alias that expands to push is a push. `!` aliases run a shell, which cannot be followed.
  local alias_val
  alias_val=$(git_in "${dir:-$START_DIR}" config --get "alias.$tok")
  [[ -n "$alias_val" ]] || return 0
  if [[ "$alias_val" == '!'* ]]; then
    [[ "$alias_val" == *push* ]] && block "alias \`git $tok\` runs a shell command that mentions push"
    return 0
  fi
  local -a expanded=()
  local line
  while IFS= read -r line; do
    [[ "${line%%$'\t'*}" == S ]] && break
    expanded+=("$line")
  done < <(tokenize "$alias_val")
  if [[ "${#expanded[@]}" -gt 0 && "${expanded[0]#*$'\t'}" == push ]]; then
    expanded=("${expanded[@]:1}")
    check_push "$dir" ${expanded[@]+"${expanded[@]}"} ${rest[@]+"${rest[@]}"}
  fi
  return 0
}

# Walks a piece of shell text segment by segment. Tracks `cd` so a bare push is judged in the
# directory it actually runs in.
#
# $1 shell text, $2 starting directory, $3 recursion depth
check_text() {
  local text="$1" depth="$3"
  CUR_DIR="$2"
  if [[ "$depth" -gt 3 ]]; then
    [[ "$text" == *push* ]] && block "nested shells more than three deep around a push"
    return
  fi

  local -a seg=()
  local line
  while IFS= read -r line; do
    if [[ "${line%%$'\t'*}" == S ]]; then
      [[ "${#seg[@]}" -gt 0 ]] && check_segment "$depth" "${seg[@]}"
      seg=()
    else
      seg+=("$line")
    fi
  done < <(tokenize "$(_bash_write_strip_heredocs "$text")")
  [[ "${#seg[@]}" -gt 0 ]] && check_segment "$depth" "${seg[@]}"
  return 0
}

# Judges one simple command.
#
# $1 recursion depth, rest: `kind\ttext` lines
check_segment() {
  local depth="$1"
  shift
  local -a w=("$@")
  local tok kind

  # Leading words that do not change which program runs.
  while [[ "${#w[@]}" -gt 0 ]]; do
    kind="${w[0]%%$'\t'*}"
    tok="${w[0]#*$'\t'}"
    case "$tok" in
      command | exec | builtin | nohup | time | caffeinate | stdbuf | \
        '{' | '}' | '!' | if | then | else | elif | do | while | until)
        w=("${w[@]:1}") ;;
      env | nice)
        w=("${w[@]:1}")
        while [[ "${#w[@]}" -gt 0 && "${w[0]#*$'\t'}" == -* ]]; do w=("${w[@]:1}"); done ;;
      timeout)
        w=("${w[@]:1}")
        while [[ "${#w[@]}" -gt 0 && "${w[0]#*$'\t'}" == -* ]]; do w=("${w[@]:1}"); done
        [[ "${#w[@]}" -gt 0 ]] && w=("${w[@]:1}") ;;
      *)
        if [[ "$kind" == W && "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          w=("${w[@]:1}")
        else
          break
        fi ;;
    esac
  done
  [[ "${#w[@]}" -gt 0 ]] || return 0

  kind="${w[0]%%$'\t'*}"
  tok="${w[0]#*$'\t'}"
  local cmd="${tok##*/}"
  local arg1="${w[1]:-}"
  local arg1kind="${arg1%%$'\t'*}"
  arg1="${arg1#*$'\t'}"
  local i

  case "$cmd" in
    cd | pushd)
      if [[ "${#w[@]}" -lt 2 ]]; then
        CUR_DIR="$HOME"
      elif [[ "$arg1kind" == D || "$arg1" == "-" ]]; then
        CUR_DIR=""
      else
        CUR_DIR=$(resolve_dir "$arg1" "$CUR_DIR")
      fi
      return 0 ;;
    git)
      w=("${w[@]:1}")
      check_git "$CUR_DIR" ${w[@]+"${w[@]}"}
      return ;;
    sh | bash | zsh | dash)
      for ((i = 1; i < ${#w[@]}; i++)); do
        tok="${w[i]#*$'\t'}"
        if [[ "$tok" == -*c* && "$tok" != --* ]]; then
          local inner="${w[i + 1]:-}"
          inner="${inner#*$'\t'}"
          local saved="$CUR_DIR"
          check_text "${inner//$'\037'/$'\n'}" "$CUR_DIR" $((depth + 1))
          CUR_DIR="$saved"
          return
        fi
      done ;;
    eval)
      local joined="" saved="$CUR_DIR"
      for ((i = 1; i < ${#w[@]}; i++)); do joined+="${w[i]#*$'\t'} "; done
      check_text "${joined//$'\037'/$'\n'}" "$CUR_DIR" $((depth + 1))
      CUR_DIR="$saved"
      return ;;
  esac

  # Anything else that runs git with push as separate words — `xargs git push`, `find -exec git
  # push` — is a push whose arguments are not in the text.
  local seen_git=0
  for ((i = 1; i < ${#w[@]}; i++)); do
    tok="${w[i]#*$'\t'}"
    [[ "${tok##*/}" == git ]] && seen_git=1
    if [[ "$seen_git" == 1 && "$tok" == push ]]; then
      block "\`$cmd\` runs git push with arguments that are not in the command text"
      return
    fi
  done
  return 0
}

CUR_DIR=""
check_text "$COMMAND" "$START_DIR" 0

TARGET=$(printf '%s' "$COMMAND" | tr '\n' ' ' | cut -c1-120)

if [[ -z "$BLOCK_REASONS" ]]; then
  if [[ "$PUSH_SEEN" == 1 ]]; then
    reason=push-ok
    [[ "$DRY_RUN_SEEN" == 1 ]] && reason=push-dry-run
    hook_log guard-push "$SESSION" Bash allow "$TARGET" "$reason"
  fi
  exit 0
fi

cat >&2 <<EOF
This command would push to a protected branch ($PROTECTED_LIST), or its destination cannot be read
from the text:
$BLOCK_REASONS
Pushing any other branch is allowed: \`git push origin <branch>\` with an explicit branch name is the
form this hook can always read.

Do not route around this (a script, \`gh api\`, a different remote). Updating a protected branch is the
user's call: tell them what would be pushed and let them run it from their own terminal.
EOF
hook_log guard-push "$SESSION" Bash block "$TARGET" push-protected
exit 2
