#!/usr/bin/env bash
#
# Shared helper: extracts the files a Bash command would write, and decides which paths are exempt
# from the worktree rule.
#
# Exists because the two PreToolUse hooks only matched `Edit|Write`, so `cat > file <<EOF`,
# `sed -i`, and `tee` walked straight past both of them. A guard that only covers one of two
# equivalent ways to change a file is not a guard — it is a speed bump on the documented path.
#
# Deliberately syntactic. This reads shell text with regular expressions; it cannot resolve `$VAR`,
# command substitution, `sh -c "..."`, or an interpreter writing through its own API. It closes the
# easy door, which is the one an agent walks through by accident or convenience. It is not a sandbox,
# and the same is true of every hook here.
#
# The first version was cruder than that and blocked real work. It matched every rule against the
# whole command string with no notion of quoting or of which command a rule belonged to, so a search
# whose *pattern* contained `tee -a` or `cp a b` was refused as a file write, and `printf '[%s]\n'`
# contributed its format string as a filename. Three rules now do the work instead:
#
#   1. Heredoc bodies are removed. Documentation that quotes example commands is text, not commands.
#   2. Quoted spans are blanked before matching. A pattern is an argument, not syntax.
#   3. A command-specific rule fires only when that command is the one being run, not when its name
#      appears anywhere in the line.
#
# Together those retire the idea of a read-only command allowlist: `grep`, `rg`, `find` and the rest
# are unremarkable once `cp` only means `cp` at the head of a segment.
#
# Usage:
#   source lib-bash-writes.sh
#   targets=$(bash_write_targets "$COMMAND" "$REPO_ROOT")   # newline-separated, may be empty
#   bash_write_is_exempt "$PATH" "$REPO_ROOT" && ...        # true when the path needs no worktree

# Paths that may be written without going through a worktree: build output, dependency trees,
# coverage, scratch space, and anything outside the repository. None of them are reviewed code.
#
# Public because both PreToolUse hooks need the same answer for the same path. It used to live
# inside bash_write_targets, which meant only the Bash branch consulted it — so `Write` to /tmp was
# refused by a hook whose own message says writing to /tmp needs no worktree.
#
# $1 path, absolute or repo-relative
# $2 repository root (the main working tree, not a worktree — see the callers)
# True when the raw payload is a tool call that cannot write a file, judged by name.
#
# The inverse of the matcher in settings.json, and inverted on purpose. That one is an allowlist of
# writing tools, so an unlisted tool is unguarded; this is a *skip* list of reading tools, so an
# unlisted tool is checked. Same kind of list, opposite failure direction.
#
# Its job is price. Three hooks on one tool call measured 131ms for a payload carrying a file_path,
# nearly all fork and jq, and `Read` carries one — so widening the matcher to every tool would put
# that on the most frequent call in a session. Matched with bash patterns against the raw text, no
# subprocess: 19ms for a payload that bails, and this brings `Read` down with it.
#
# A substring match on a malformed payload could be fooled. Like everything in this directory that is
# a guard against accident and not a sandbox — and a tool that only reads is the cheapest possible
# thing to be wrong about.
#
# $1 raw hook payload
bash_write_is_read_only_tool() {
  case "$1" in
    *'"tool_name":"Read"'* | *'"tool_name":"Grep"'* | *'"tool_name":"Glob"'* \
      | *'"tool_name":"WebFetch"'* | *'"tool_name":"WebSearch"'* | *'"tool_name":"TodoWrite"'* \
      | *'"tool_name":"NotebookRead"'* | *'"tool_name":"ListMcpResourcesTool"'*)
      return 0 ;;
  esac
  return 1
}

bash_write_is_exempt() {
  local target="$1" repo="${2:-$PWD}"
  repo="${repo%/}"

  case "$target" in
    /dev/*|/tmp/*|/private/tmp/*|/var/folders/*) return 0 ;;
    */node_modules/*|*/obj/*|*/bin/*|*/dist/*|*/coverage/*|*/.wrangler/*|*/TestResults/*) return 0 ;;
    *.log|*.tmp) return 0 ;;
    # Session state written by agents rather than by hooks: plan receipts, review receipts. Gitignored,
    # so it can never make a worktree dirty and block the merge. It is inside the working tree instead
    # of in the git directory because the git directory turned out to be unreachable: both the Write
    # tool and a Bash redirect into <main>/.git are refused from a worktree session, the first by the
    # harness itself. An earlier design assumed the opposite, and it did not survive being checked.
    .claude/state/*|*/.claude/state/*) return 0 ;;
  esac

  # Anything outside the repository is not this repository's code.
  [[ "$target" = /* && "$target" != "$repo"/* ]] && return 0

  return 1
}

# Removes heredoc bodies, leaving the command lines that introduce them.
#
# The redirection that names the real file (`cat > doc.md <<'EOF'`) is on the command line, so
# nothing is lost. What goes is the body, which is data: writing a document that quotes
# `cat > src/index.ts` was refused because the quotation was read as a command.
_bash_write_strip_heredocs() {
  awk '
    {
      if (skipping) {
        # Delimiters may be indented when the operator was <<- ; compare the trimmed line.
        line = $0
        sub(/^[ \t]+/, "", line)
        if (line == delim) skipping = 0
        next
      }
      print
      if (match($0, /<<-?[ \t]*("[^"]+"|'"'"'[^'"'"']+'"'"'|[A-Za-z_][A-Za-z0-9_]*)/)) {
        delim = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", delim)
        gsub(/["'"'"']/, "", delim)
        skipping = 1
      }
    }
  ' <<< "$1"
}

# Blanks the contents of single- and double-quoted spans, keeping everything else in place.
#
# A quoted span is an argument. Matching shell syntax inside one is how `grep -rn 'tee -a' .` came
# to be reported as a write to a file called `-a`.
_bash_write_blank_quotes() {
  awk '
    {
      out = ""
      quote = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        # A backslash escapes the next character everywhere except inside single quotes, where the
        # shell treats it literally. Without this, an escaped `\"` inside a double-quoted span read
        # as the closing quote, so the rest of that argument was matched as shell syntax: a
        # `jq --arg c "sh -c \"cat > src/x.ts\""` was reported as a write to src/x.ts. Measured by
        # hitting it while probing the hooks, which is the same way the last four of these were found.
        if (c == "\\" && quote != "'"'"'") {
          i++
          # Outside quotes the escaped character is ordinary text and part of a possible filename, so
          # it is kept. Inside a double-quoted span the pair is content and stays blanked.
          if (quote == "") out = out substr($0, i, 1)
          continue
        }
        if (quote == "") {
          if (c == "\"" || c == "'"'"'") { quote = c; out = out " " }
          else out = out c
        } else {
          if (c == quote) quote = ""
        }
      }
      print out
    }
  ' <<< "$1"
}

# Prints the last argument of a segment that is not an option, or nothing when there is none.
_bash_write_last_arg() {
  awk '{ for (i = NF; i >= 2; i--) if (substr($i, 1, 1) != "-") { print $i; exit } }' <<< "$1"
}

# Prints the first argument of a segment that is not an option, or nothing when there is none.
_bash_write_first_arg() {
  awk '{ for (i = 2; i <= NF; i++) if (substr($i, 1, 1) != "-") { print $i; exit } }' <<< "$1"
}

# Prints, one per line, every path the command appears to write. Empty output means the command
# does not look like a file write.
#
# $1 command text
# $2 repository root used to decide what counts as "inside the repo" (default: $PWD)
bash_write_targets() {
  local cmd="$1" repo="${2:-$PWD}"
  repo="${repo%/}"

  local raw clean candidates="" segment first
  raw=$(_bash_write_strip_heredocs "$cmd")
  clean=$(_bash_write_blank_quotes "$raw")

  # The directory a relative path in this command would be written into. Empty means "unknown, assume
  # the caller's", which is the old behaviour and the fail-safe one.
  #
  # It exists because `cd ~/.claude && jq … > settings.json` was reported as a write to
  # <repo>/settings.json: the redirect names a relative path, and every relative path was resolved
  # against the repository root regardless of what the command did first. Hit twice while doing this
  # work, both times refusing a command that wrote nothing in the repository — and a false refusal is
  # the documented way a hook gets deleted.
  local base=""

  local add
  # Relative candidates are resolved against `base` when one is known, so that the exemption tests
  # further down see the path the command would actually write.
  add() {
    [[ -n "$1" ]] || return 0
    if [[ -n "$base" && "$1" != /* ]]; then
      candidates+="$base/$1
"
    else
      candidates+="$1
"
    fi
  }

  # One segment per command in the line: `a && b | c` is three commands, and a rule for `cp` must
  # not fire because `cp` appears as an argument to one of the others.
  while IFS= read -r segment; do
    [[ -n "${segment// }" ]] || continue

    # Redirections apply to any command: `grep foo > src/x.ts` really does write. Excludes `>&`
    # (fd duplication) and the `>(...)` of process substitution.
    while IFS= read -r m; do add "$m"; done < <(
      printf '%s' "$segment" |
        grep -oE '[0-9]?>>?[[:space:]]*[^|&;<>()[:space:]]+' |
        sed -E 's/^[0-9]?>>?[[:space:]]*//' | grep -v '^&'
    )

    # The command actually being run, ignoring a leading environment assignment.
    first=$(awk '{ for (i = 1; i <= NF; i++) if ($i !~ /=/) { print $i; exit } }' <<< "$segment")
    first="${first##*/}"

    # A `cd` changes where every later relative path in this command lands. Resolved for the literal
    # forms only — absolute, `~/…`, and relative-to-wherever-we-are. Anything with a `$` in it cannot
    # be resolved by reading text, and there the base goes back to unknown so the old, stricter
    # behaviour applies: better to over-report a write than to miss one because a variable was opaque.
    if [[ "$first" == cd ]]; then
      local target_dir
      target_dir=$(_bash_write_first_arg "$segment")
      case "$target_dir" in
        "" | *'$'* | *'`'*) base="" ;;
        /*) base="${target_dir%/}" ;;
        "~"/*) base="$HOME/${target_dir#\~/}" ;;
        "~") base="$HOME" ;;
        *) base="${base:-$repo}/${target_dir%/}" ;;
      esac
      continue
    fi

    case "$first" in
      cp|mv|install|rsync)
        add "$(_bash_write_last_arg "$segment")" ;;
      tee)
        add "$(_bash_write_first_arg "$segment")" ;;
      sed)
        # Only `-i` edits in place. `sed -n '1,5p' file` is a read, and treating it as a write is
        # what made reading a source file through sed impossible.
        if grep -qE '(^|[[:space:]])-[a-zA-Z]*i' <<< "$segment"; then
          add "$(_bash_write_last_arg "$segment")"
        fi ;;
      perl)
        if grep -qE '(^|[[:space:]])-[a-zA-Z]*i' <<< "$segment"; then
          add "$(_bash_write_last_arg "$segment")"
        fi ;;
      dd|truncate)
        while IFS= read -r m; do add "$m"; done < <(
          printf '%s' "$segment" | grep -oE 'of=[^|&;[:space:]]+' | sed 's/^of=//'
        ) ;;
    esac
    # awk rather than sed, and a trailing newline rather than none. BSD sed does not turn `\n` in a
    # replacement into a newline, and `read` discards a final line that has no terminator — between
    # them the loop body never ran at all and every real write was reported as no write.
  done < <(printf '%s\n' "$clean" | awk '{ gsub(/\|\||&&|[;|&]/, "\n"); print }')

  # An interpreter opening a file for writing. Run against the unblanked text, because the path is
  # inside the quotes this function otherwise removes — and only when an interpreter is really being
  # invoked with inline source.
  if grep -qE '(^|[[:space:]])(python3?|node|ruby)[[:space:]]+-(c|e)([[:space:]]|$)' <<< "$raw"; then
    # A mode is required. `open(path)` defaults to reading, and matching the bare call reported every
    # inline script that read a file as one that writes it.
    while IFS= read -r m; do add "$m"; done < <(
      printf '%s' "$raw" |
        grep -oE "open\([\"'][^\"']+[\"'][[:space:]]*,[[:space:]]*[\"'][wax]" |
        sed -E "s/^open\([\"']//; s/[\"'][[:space:]]*,.*$//"
    )
    while IFS= read -r m; do add "$m"; done < <(
      printf '%s' "$raw" |
        grep -oE "(writeFileSync|appendFileSync|createWriteStream)\([\"'][^\"']+[\"']" |
        sed -E "s/^[a-zA-Z]+\([\"']//; s/[\"']$//"
    )
    # pathlib, which is how a Python script writes a file when nobody is thinking about `open`. The
    # path sits in `Path(...)` and the write is the method after it, so the method has to be part of
    # the pattern: matching `Path(` alone would report every `read_text()` as a write.
    while IFS= read -r m; do add "$m"; done < <(
      printf '%s' "$raw" |
        grep -oE "Path\([\"'][^\"']+[\"']\)\.write_(text|bytes)" |
        sed -E "s/^Path\([\"']//; s/[\"']\)\.write_(text|bytes)\$//"
    )
  fi

  # `sh -c "…"` hides an entire command inside an argument, and an argument is a quoted span this
  # function blanks before matching — so the inner command was invisible and the wrapper was a way
  # past every rule above. Recursed once, guarded against nesting further: this is still a syntactic
  # reader, and `sh -c "sh -c \"…\""` is not a shape anyone reaches for by accident.
  if [[ -z "${_BASH_WRITE_NESTED:-}" ]] &&
    grep -qE '(^|[[:space:]])(sh|bash|zsh|dash)[[:space:]]+-c([[:space:]]|$)' <<< "$raw"; then
    local inner
    inner=$(printf '%s' "$raw" |
      sed -E 's/^.*(^|[[:space:]])(sh|bash|zsh|dash)[[:space:]]+-c[[:space:]]+//')
    inner="${inner#\"}"
    inner="${inner%\"}"
    inner="${inner#\'}"
    inner="${inner%\'}"
    if [[ -n "$inner" ]]; then
      while IFS= read -r m; do add "$m"; done < <(
        _BASH_WRITE_NESTED=1 bash_write_targets "$inner" "$repo"
      )
    fi
  fi

  printf '%s' "$candidates" | while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    target="${target%\"}"; target="${target#\"}"
    target="${target%\'}"; target="${target#\'}"

    # Leftovers rather than paths: an option the argument scan picked up, or a fragment of a format
    # string. Both were reported as files this command would create.
    [[ "$target" == -* ]] && continue
    [[ "$target" == *%* || "$target" == *'\n'* ]] && continue

    bash_write_is_exempt "$target" "$repo" && continue

    printf '%s\n' "$target"
  done
}

# Prints, one per line, every dependency directory a command would destroy that is a symlink
# pointing out of the tree the command runs in. Empty output means there is nothing to refuse.
#
# This is the one write that bash_write_targets is deliberately blind to. `node_modules` is exempt
# there — it is build output, not reviewed code, and writing it needs no worktree. That exemption is
# right, and it is exactly what makes this case invisible: the destructive part is not the write, it
# is that the path is a symlink into a tree the session does not own.
#
# When `.claude/settings.json` sets `worktree.symlinkDirectories`, every worktree's `node_modules`
# is a symlink into the main working tree. `npm ci` begins by deleting
# `node_modules` outright — that is what separates it from `npm install` — so run from a worktree it
# follows the symlink and erases the main tree's real dependency tree, which every other worktree
# shares. It prints nothing during the unlink, so it reads as a hang rather than as damage, and
# agent-run Bash has no TTY to interrupt with. The observed outcome was forced editor quits and
# worktrees left locked.
#
# Dependency setup belongs in the main tree, and saying so in prose was all that held. Nothing
# enforced it.
#
# Keyed on the symlink rather than on "the session is in a worktree", which matters in both
# directions: `npm ci` in the main tree is ordinary setup and stays allowed, and a `--prefix` into a
# worktree from anywhere is still caught. It also stays correct if `symlinkDirectories` changes,
# because it asks the filesystem instead of repeating the list.
#
# Fails open when it cannot parse the command. This guards a footgun, not correctness, so a
# missed case costs a re-run of a setup command; a false refusal costs the guard its life. Stated
# limits, same as everything else here: `sh -c`, `$VAR`, and any indirection get through.
#
# $1 command text
# $2 directory the command runs in (the session cwd)
bash_write_clobbers_linked_deps() {
  local cmd="$1" cwd="${2:-$PWD}"
  cwd="${cwd%/}"
  [[ -d "$cwd" ]] || return 0

  local raw clean segment first base hits=""
  raw=$(_bash_write_strip_heredocs "$cmd")
  clean=$(_bash_write_blank_quotes "$raw")

  # The tree the command runs in. A path resolving inside this is the session's own and is fine;
  # the refusal is for reaching outside it.
  local own
  own=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")

  base="$cwd"
  while IFS= read -r segment; do
    [[ -n "${segment// }" ]] || continue

    first=$(awk '{ for (i = 1; i <= NF; i++) if ($i !~ /=/) { print $i; exit } }' <<< "$segment")
    first="${first##*/}"

    # Same `cd` handling as bash_write_targets, and for the same reason: `cd app && npm ci`
    # is the natural way to type this and the segment that runs npm carries no path at all.
    if [[ "$first" == cd ]]; then
      local target_dir
      target_dir=$(_bash_write_first_arg "$segment")
      case "$target_dir" in
        "" | *'$'* | *'`'*) base="" ;;
        /*) base="${target_dir%/}" ;;
        "~"/*) base="$HOME/${target_dir#\~/}" ;;
        "~") base="$HOME" ;;
        *) base="${base:-$cwd}/${target_dir%/}" ;;
      esac
      continue
    fi

    # Directories this segment would wipe, relative to `base` unless already absolute.
    local -a dirs=()
    case "$first" in
      npm | pnpm | yarn | bun)
        # Only the subcommands that delete the tree first. `npm run`, `npm test`, `npm ls` and the
        # rest touch nothing, and refusing them would make the guard intolerable.
        local sub
        sub=$(_bash_write_first_arg "$segment")
        case "$sub" in
          ci | install | i | add | prune | rebuild | dedupe) ;;
          *) continue ;;
        esac
        # `npm install` without `ci` only rewrites entries, but `--prefix` and a clean tree make it
        # destructive enough to be worth the same answer, and telling a user "run it in the main
        # tree" is correct advice for all of them.
        local prefix=""
        prefix=$(grep -oE -- '--prefix[= ][^ ]+' <<< "$segment" | head -1 | sed -E 's/^--prefix[= ]//')
        [[ -n "$prefix" ]] || prefix=$(grep -oE -- '(^| )-C[= ][^ ]+' <<< "$segment" |
          head -1 | sed -E 's/^ ?-C[= ]//')
        local root="${prefix:-${base:-$cwd}}"
        [[ "$root" = /* ]] || root="${base:-$cwd}/$root"
        dirs=("$root/node_modules")
        ;;
      rm)
        # Removing the tree by hand has the identical effect through the identical symlink.
        while IFS= read -r m; do
          [[ -n "$m" ]] || continue
          [[ "$m" == */node_modules || "$m" == */node_modules/ ]] || continue
          [[ "$m" = /* ]] || m="${base:-$cwd}/$m"
          dirs+=("${m%/}")
        done < <(awk '{ for (i = 2; i <= NF; i++) if (substr($i, 1, 1) != "-") print $i }' <<< "$segment")
        ;;
      *) continue ;;
    esac

    local dir resolved dir_own
    for dir in "${dirs[@]}"; do
      dir="${dir%/}"
      # Only a symlink can reach out of this tree. A real directory here is the main tree's own, and
      # rebuilding that is the documented way to fix it.
      [[ -L "$dir" ]] || continue
      resolved=$(cd "$(dirname "$dir")" 2>/dev/null && readlink "$(basename "$dir")" || true)
      [[ -n "$resolved" ]] || continue
      [[ "$resolved" = /* ]] || resolved="$(dirname "$dir")/$resolved"
      # Which tree counts as "own" belongs to the directory being installed into, not to the shell's
      # cwd. `--prefix` separates the two, and keying on the cwd got that case backwards: run from the
      # main tree, `npm ci --prefix <worktree>/app` resolves through the worktree's symlink back
      # into the main tree, which the cwd-based test read as "points inside my own tree, harmless" —
      # the exact deletion this guard exists to refuse, waved through. A commit upstream claimed this
      # form was caught; it never was, for any directory in the list.
      dir_own=$(git -C "$(dirname "$dir")" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$own")
      # Pointing inside that tree is harmless; pointing out of it is the whole problem.
      case "$resolved/" in
        "$dir_own"/*) continue ;;
      esac
      hits+="$dir -> $resolved
"
    done
  done < <(printf '%s\n' "$clean" | awk '{ gsub(/\|\||&&|[;|&]/, "\n"); print }')

  printf '%s' "$hits"
}

# Prints the install commands that repair the dependency trees a worktree shares, one per line.
#
# Generated from `worktree.symlinkDirectories` rather than written out, because a hand-written list
# stops being true the day a directory is added — which is exactly how one came to be missing from
# that setting while the refusal message confidently named the other two.
#
# A function, and in this file, so it can be tested the way bash_write_clobbers_linked_deps is. It was
# four lines inline in a hook, and the shape it got wrong is not reachable from the
# current settings: an entry of plain `node_modules` — the repository root, which is what npm
# workspaces would make the whole list collapse into — left `sub` with an empty string and printed
# `npm ci --prefix ` with nothing after it. Advice with a missing argument is worse than none, since
# it looks runnable.
#
# $1 path to settings.json
linked_deps_remedy() {
  local remedy
  remedy=$(jq -r '
    .worktree.symlinkDirectories // []
    | .[]
    | sub("(^|/)node_modules$"; "")
    | if . == "" then "  npm ci" else "  npm ci --prefix " + . end
  ' "$1" 2>/dev/null)
  # A settings file that is missing, unreadable or has no list at all still has to say something
  # actionable, and the placeholder is honest about not knowing which directory.
  [[ -n "$remedy" ]] || remedy="  npm ci --prefix <app>"
  printf '%s' "$remedy"
}
