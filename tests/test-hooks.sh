#!/usr/bin/env bash
#
# Test suite for the harness hooks.
#
# Three classes of case, and the first two exist because the bugs they catch shipped in the
# repository this plugin was extracted from:
#
#   1. Executable check — read the hook list out of plugin.json and require every entry to exist and
#      carry the execute bit. A hook invoked by a bare path that is not executable fails silently,
#      and a silent failure reads exactly like a hook that decided to allow. One guard lived its
#      whole life that way, blocking nothing, and the evidence was negative: no log line ever named
#      it.
#   2. False refusal — every rule that blocks something also gets a case proving it has not opened
#      too wide. This half is more expensive to write than the blocking half, and skipping it is the
#      fastest way to get a guard removed by the person it keeps interrupting.
#   3. Behaviour — the configuration plumbing, including the worktree-prefix strip that every check
#      depends on.
#
# Run: bash tests/test-hooks.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0
FAIL=0

# Records one result and prints a line for the failures only, so a green run stays short.
#
# $1 outcome, "ok" or anything else
# $2 case name
check() {
  if [[ "$1" == "ok" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$2"
  fi
}

# Asserts two strings are equal.
#
# $1 expected, $2 actual, $3 case name
expect_eq() {
  if [[ "$1" == "$2" ]]; then check ok "$3"; else check no "$3 (expected '$1', got '$2')"; fi
}

# Asserts a command succeeds.
#
# $1 case name, rest: command
expect_true() {
  local name="$1"; shift
  if "$@"; then check ok "$name"; else check no "$name"; fi
}

# Asserts a command fails.
#
# $1 case name, rest: command
expect_false() {
  local name="$1"; shift
  if "$@"; then check no "$name"; else check ok "$name"; fi
}

# --- 1. executable check -------------------------------------------------------------------------
# The hook list comes from plugin.json rather than from a listing of the directory: a hook that is
# wired but missing, and a file that is present but unwired, are different bugs and only the wiring
# knows which is which.

HOOK_COMMANDS=$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$ROOT/.claude-plugin/plugin.json")
[[ -n "$HOOK_COMMANDS" ]] && check ok "plugin.json declares at least one hook" || check no "plugin.json declares at least one hook"

while IFS= read -r cmd; do
  [[ -n "$cmd" ]] || continue
  path="${cmd//\"/}"
  path="${path//\$\{CLAUDE_PLUGIN_ROOT\}/$ROOT}"
  expect_true "wired hook exists: ${path#"$ROOT"/}" test -f "$path"
  expect_true "wired hook is executable: ${path#"$ROOT"/}" test -x "$path"
done <<< "$HOOK_COMMANDS"

for f in "$ROOT"/hooks/*.sh; do
  expect_true "parses: ${f#"$ROOT"/}" bash -n "$f"
  expect_true "executable: ${f#"$ROOT"/}" test -x "$f"
done

# --- 2. sensitive paths, unconfigured ------------------------------------------------------------
# An installation with no .claude/harness.json must gate nothing except the harness directory. The
# failure to avoid is an empty regex reaching grep, which matches every line and would put every
# edit in the repository behind the plan gate.

# shellcheck source=/dev/null
source "$ROOT/hooks/lib-sensitive-paths.sh"

BARE=$(mktemp -d)
mkdir -p "$BARE/.claude"

expect_eq "" "$(invariant_paths_regex "$BARE")" "no config: invariant regex is empty"
expect_eq '^\.claude/' "$(plan_paths_regex "$BARE")" "no config: plan regex is the harness directory only"
expect_false "no config: ordinary source file is not invariant code" path_is_invariant_code "src/app.ts" "$BARE"
expect_false "no config: ordinary source file needs no plan" path_needs_plan "src/app.ts" "$BARE"
expect_true "no config: editing the harness still needs a plan" path_needs_plan ".claude/hooks/x.sh" "$BARE"

# Malformed configuration fails closed on the gate and open on the file list, never the reverse: a
# broken file must not silently gate the whole repository.
printf '%s' '{ not json' > "$BARE/.claude/harness.json"
expect_eq "" "$(invariant_paths_regex "$BARE")" "malformed config: invariant regex is empty, not universal"
expect_false "malformed config: ordinary file is not gated" path_is_invariant_code "src/app.ts" "$BARE"

printf '%s' '{"sensitivePaths": []}' > "$BARE/.claude/harness.json"
expect_eq "" "$(invariant_paths_regex "$BARE")" "empty list: invariant regex is empty"

# --- 3. sensitive paths, configured --------------------------------------------------------------

CONF=$(mktemp -d)
mkdir -p "$CONF/.claude"
printf '%s' '{"sensitivePaths": ["^src/billing/", "^migrations/"]}' > "$CONF/.claude/harness.json"

expect_true "configured: listed path is invariant code" path_is_invariant_code "src/billing/charge.ts" "$CONF"
expect_true "configured: second listed path is invariant code" path_is_invariant_code "migrations/001.sql" "$CONF"
expect_false "configured: unlisted path is not invariant code" path_is_invariant_code "src/ui/button.tsx" "$CONF"
expect_false "configured: near-miss prefix is not invariant code" path_is_invariant_code "docs/src/billing/notes.md" "$CONF"

# The coupling that must survive refactoring: a path added to the invariant group is behind the plan
# gate too, without being written down a second time.
expect_true "configured: invariant path also needs a plan" path_needs_plan "src/billing/charge.ts" "$CONF"
expect_true "configured: harness still needs a plan" path_needs_plan ".claude/settings.json" "$CONF"
expect_false "configured: unlisted path needs no plan" path_needs_plan "src/ui/button.tsx" "$CONF"

# --- 4. worktree prefix strip --------------------------------------------------------------------
# Without this every check silently misses every edit, because every edit is supposed to happen
# inside a worktree.

expect_eq "src/billing/charge.ts" \
  "$(sensitive_relpath "$CONF/.claude/worktrees/feature/src/billing/charge.ts" "$CONF")" \
  "relpath: absolute worktree path is stripped to repo-relative"
expect_eq "src/billing/charge.ts" \
  "$(sensitive_relpath ".claude/worktrees/feature/src/billing/charge.ts" "$CONF")" \
  "relpath: relative worktree path is stripped to repo-relative"
expect_eq "src/billing/charge.ts" \
  "$(sensitive_relpath "$CONF/src/billing/charge.ts" "$CONF")" \
  "relpath: plain absolute path is stripped to repo-relative"
expect_true "worktree edit to a sensitive path is still gated" \
  path_is_invariant_code "$CONF/.claude/worktrees/feature/src/billing/charge.ts" "$CONF"
expect_false "worktree edit to an ordinary path is still not gated" \
  path_is_invariant_code "$CONF/.claude/worktrees/feature/src/ui/button.tsx" "$CONF"

# A worktree path under a root other than the one passed — which is what every hook sees when
# CLAUDE_PROJECT_DIR is unset. The fallback strip used to be `##*/.claude/worktrees/*/`, whose trailing
# `*` matches slashes, so it left a bare file name and every rule, the plan gate and the review receipt
# missed the edit.
expect_eq "src/billing/charge.ts" \
  "$(sensitive_relpath "/elsewhere/repo/.claude/worktrees/feature/src/billing/charge.ts" "$CONF")" \
  "relpath: a worktree under another root keeps its directories"
expect_true "worktree path under another root is still gated" \
  path_needs_plan "/elsewhere/repo/.claude/worktrees/feature/src/billing/charge.ts" "$CONF"

# --- 5. log location -----------------------------------------------------------------------------
# The log must never land in a working tree: a file there shows up in git status for every worktree
# and makes the merge refuse.

# shellcheck source=/dev/null
source "$ROOT/hooks/lib-hook-log.sh"
LOG_OVERRIDE=$(mktemp -d)/log.jsonl
expect_eq "$LOG_OVERRIDE" "$(Z_HARNESS_HOOK_LOG="$LOG_OVERRIDE" _hook_log_path)" \
  "log path: environment override wins"
expect_true "log path: default sits in the git directory" \
  bash -c 'cd "$1" && p=$(source "$2/hooks/lib-hook-log.sh" && _hook_log_path) && [[ "$p" == *"/.git/z-harness-hooks.jsonl" ]]' _ "$ROOT" "$ROOT"

rm -rf "$BARE" "$CONF"

# --- 6. the write detector ---------------------------------------------------------------------
# lib-bash-writes decides which shell commands write a file. It is the largest and least obvious
# part of the plugin, and its patterns have twice been adjusted by guesswork. Every case below is
# ported from the suite it grew up in, with the paths made generic.
#
# The allow half is not padding. A guard that refuses `grep -rn 'tee -a' .` refuses the exact kind
# of command someone uses to investigate the guard, and a guard that gets in the way of reading is
# removed rather than reported.

# shellcheck source=/dev/null
source "$ROOT/hooks/lib-bash-writes.sh"
REPO="$ROOT"

# Asserts that bash_write_targets does or does not flag a command.
#
# $1 "flag" or "allow", $2 case name, $3 command text
expect_write() {
  local want="$1" name="$2" cmd="$3" out got
  out=$(bash_write_targets "$cmd" "$REPO")
  got="allow"; [[ -n "$out" ]] && got="flag"
  if [[ "$got" == "$want" ]]; then check ok "$name"; else check no "write: $name (want $want, got $got)"; fi
}

# Writes, in the plainest forms.
expect_write flag  "heredoc redirect into src"      'cat > src/index.ts <<EOF'
expect_write flag  "append redirect into src"       'echo x >> src/index.ts'
expect_write flag  "sed -i on a source file"        "sed -i '' 's/a/b/' src/headers.ts"
expect_write flag  "tee into a source file"         'tee src/Program.cs'
expect_write flag  "python open(...,w)"             "python3 -c \"open('src/layout.ts','w').write('x')\""
expect_write flag  "cp over a tracked file"         'cp /tmp/a src/main.tsx'

# Not writes: scratch space, file descriptors, and reads.
expect_write allow "redirect to /tmp"               'npm test > /tmp/out.log'
expect_write allow "redirect to /dev/null"          'docker info > /dev/null 2>&1'
expect_write allow "fd duplication, not a file"     'npm test 2>&1 | tail -5'
expect_write allow "read-only git"                  'git status --porcelain'
expect_write allow "grep with a pipe"               'grep -rn foo src/ | head'
expect_write allow "build output is not code"       'dotnet run > TestResults/x.log'

# Commands that merely mention a writing command. The first version of the detector refused all of
# these, which made the tools for investigating the harness unusable inside the harness.
expect_write allow "grep for the word tee"          "grep -rn 'tee -a' hooks"
expect_write allow "grep for a redirect"            "grep -rn '>> .*\.log' hooks"
expect_write allow "rg for the word cp"             "rg 'cp a b' src/"
expect_write allow "printf format string"           "printf '[%s]\n' src/index.ts"
expect_write allow "sed without -i is a read"       "sed -n '1,5p' src/index.ts"
expect_write allow "find naming a source file"      "find src -name 'index.ts' -newer src/layout.ts"

# The same commands actually doing the thing, so the exemptions above are narrow rather than blind.
expect_write flag  "cp really overwriting source"   'cp /tmp/x src/index.ts'
expect_write flag  "sed -i really editing source"   "sed -i.bak 's/a/b/' src/layout.ts"
expect_write flag  "tee after a real pipe"          'echo x | tee src/headers.ts'

# Heredoc bodies are text, not commands. A document that quotes a write is not a write.
HEREDOC_DOC=$(printf 'cat <<EOF\ncp /tmp/x src/index.ts\nEOF')
expect_write allow "heredoc body quoting commands"  "$HEREDOC_DOC"
HEREDOC_SRC=$(printf 'cat > src/index.ts <<EOF\nexport const x = 1\nEOF')
expect_write flag  "heredoc really writing source"  "$HEREDOC_SRC"

# Quoted text is likewise not a command.
expect_write allow "escaped quotes inside an argument" \
  "git commit -m \"cp /tmp/x src/index.ts\""
expect_write allow "escaped quotes around a redirect" \
  "echo \"writes with > src/index.ts\""
expect_write flag  "escaped quotes, then a real write" \
  "echo \"a > b\" > src/index.ts"

# A shell inside the shell. Stated limit rather than a claim of coverage: these are caught because
# the inner command is still visible as text on the line.
expect_write flag  "sh -c hiding a redirect"        'sh -c "cat > src/index.ts"'
expect_write flag  "bash -c hiding a sed -i"        "bash -c \"sed -i '' s/a/b/ src/layout.ts\""
expect_write allow "sh -c doing something harmless" 'sh -c "git status --porcelain"'

# Interpreters write without a redirect.
expect_write flag  "pathlib write_text"             "python3 -c \"import pathlib; pathlib.Path('src/x.ts').write_text('y')\""
expect_write flag  "node createWriteStream"         "node -e \"require('fs').createWriteStream('src/x.ts')\""
expect_write allow "python open with no mode"       "python3 -c \"print(open('src/index.ts').read())\""
expect_write allow "pathlib read_text"              "python3 -c \"import pathlib; print(pathlib.Path('src/index.ts').read_text())\""

# Where a relative path lands depends on what the command did first. Resolving every relative path
# against the repository root refused commands that wrote nothing in the repository — twice.
expect_write allow "cd outside the repo, then write" 'cd ~/.claude && jq . settings.json > settings.json'
expect_write allow "cd to /tmp, then write"          'cd /tmp && echo x > notes.txt'
expect_write flag  "cd into the repo, then write"    'cd src && echo x > index.ts'
expect_write flag  "cd away, absolute write back in" "cd /tmp && echo x > $REPO/src/index.ts"
expect_write allow "cd away, relative path follows"  'cd /tmp && echo x > src/index.ts'
expect_write flag  "cd \$SOMEWHERE stays strict"     'cd "$SOMEWHERE" && echo x > src/index.ts'

# Session state is written by agents, not by hooks, and is gitignored so it cannot dirty a worktree.
expect_write allow "write into .claude/state"       'echo x > .claude/state/plan-abc.md'
expect_write allow "receipt via heredoc"            'cat > .claude/state/review-abc.json <<EOF'
expect_write flag  "CI config is not state"         'echo x > .github/workflows/ci.yml'
expect_write flag  "the hooks are not state"        'echo x > .claude/hooks/guard.sh'

# A variable assigned a literal path earlier in the same command is that path. Upstream a session that
# wrote only to its scratchpad was refused four times for `X=/tmp/s; cp a $X/b`. Each allow is paired
# with the flag that keeps it honest.
expect_write allow "cp into a literal-assigned scratch var" 'X=/private/tmp/scratch; cp a.png $X/out.png'
expect_write allow "sed -i through \${VAR}"                  "X=/tmp/s && sed -i '' s/a/b/ \${X}/video.html"
expect_write allow "export then redirect"                   'export OUT=/tmp/o; echo hi > $OUT/log.txt'
expect_write flag  "var assigned a source dir"              'X=src; cp /tmp/a $X/index.ts'
expect_write flag  "unknown var stays strict"               'cp /tmp/a $NOWHERE/index.ts'
expect_write flag  "var assigned from a substitution"       'X=$(pwd); cp /tmp/a $X/src/index.ts'
expect_write flag  "reassigned to something unreadable"     'X=/tmp; X=$HOME/x; cp /tmp/a $X/index.ts'

# A single-quoted script spanning lines is still one argument. The quote state used to reset on every
# line, so `x=>x.ok` in a multi-line `node -e` read as a redirect into a file called `x.ok`.
MULTILINE_NODE=$(printf "node -e '\nconst f = a.filter(x=>x.ok).map((y)=>y.id);\nconsole.log(f)\n' /tmp/in")
expect_write allow "multi-line node -e with arrows"         "$MULTILINE_NODE"
MULTILINE_NODE_REDIRECT=$(printf "node -e '\nconsole.log(1)\n' > src/x.ts")
expect_write flag  "multi-line node -e, real redirect"      "$MULTILINE_NODE_REDIRECT"
# Carrying quote state across lines makes an apostrophe in a comment dangerous: unclosed, it would
# blank every line after it. Comments are dropped, so the write below the comment is still seen.
COMMENT_APOSTROPHE=$(printf "# don't panic\necho hi > src/x.ts")
expect_write flag  "apostrophe in a comment hides nothing"  "$COMMENT_APOSTROPHE"
expect_write allow "hash inside a word is not a comment"    'echo a#b > /tmp/x'

# --- 7. the npm ci remedy ------------------------------------------------------------------------
# Generated from worktree.symlinkDirectories rather than written out, because a hand-written list
# stops being true the day a directory is added. Advice with a missing argument is worse than none:
# it looks runnable.

REMEDY=$(mktemp -d)
printf '%s' '{"worktree":{"symlinkDirectories":["app/node_modules"]}}' > "$REMEDY/per-app.json"
printf '%s' '{"worktree":{"symlinkDirectories":["node_modules"]}}'     > "$REMEDY/root.json"
printf '%s' '{}'                                                        > "$REMEDY/absent.json"

expect_eq "  npm ci --prefix app" "$(linked_deps_remedy "$REMEDY/per-app.json")" \
  "remedy: a per-directory entry names its directory"
expect_eq "  npm ci" "$(linked_deps_remedy "$REMEDY/root.json")" \
  "remedy: a repository-root entry does not print a dangling --prefix"
expect_eq "  npm ci --prefix <app>" "$(linked_deps_remedy "$REMEDY/absent.json")" \
  "remedy: no configuration still prints something actionable"
rm -rf "$REMEDY"

# --- 8. conventions ------------------------------------------------------------------------------
# Runs after the write rather than before it, so nothing here is about refusing an edit — it is about
# whether the finding reaches the model while the file is still what it is working on. The cases that
# matter most are the ones where it must stay quiet: a checker that fires on generated code, on test
# names, or on a repository that never asked for it is uninstalled along with everything shipped
# beside it.

CONV=$(mktemp -d)
mkdir -p "$CONV/.claude" "$CONV/src" "$CONV/test" "$CONV/generated"

# Feeds a PostToolUse payload for one file and prints the hook's exit code.
#
# $1 file path, $2 tool name (optional, defaults to Write)
conv_exit() {
  local file="$1" tool="${2:-Write}"
  printf '{"tool_name":"%s","session_id":"convtest","tool_input":{"file_path":"%s"}}' "$tool" "$file" \
    | Z_HARNESS_HOOK_LOG="$CONV/log.jsonl" CLAUDE_PROJECT_DIR="$CONV" \
      bash "$ROOT/hooks/check-conventions.sh" > /dev/null 2>&1
  printf '%s' "$?"
}

printf 'export const x = 1\n' > "$CONV/src/bare.ts"
printf '/** Documented. */\nexport const x = 1\n' > "$CONV/src/documented.ts"

# Opt-in, twice over: no configuration file at all, then a file that configures other things.
expect_eq "0" "$(conv_exit "$CONV/src/bare.ts")" "conventions: silent with no harness.json"
printf '%s' '{"sensitivePaths":["^src/"]}' > "$CONV/.claude/harness.json"
expect_eq "0" "$(conv_exit "$CONV/src/bare.ts")" "conventions: silent when the block is absent"

printf '%s' '{"conventions":{"docComments":true,"skip":["/generated/"],"generatedBanners":["auto-generated by openapi-typescript"],"forbiddenText":{"pattern":"[àáảãạđ]","label":"non-English text in code"}}}' \
  > "$CONV/.claude/harness.json"

expect_eq "2" "$(conv_exit "$CONV/src/bare.ts")" "conventions: undocumented export is reported"
expect_eq "0" "$(conv_exit "$CONV/src/documented.ts")" "conventions: documented export is clean"

# A re-export carries its documentation at the definition.
printf 'export * from "./bare"\n' > "$CONV/src/reexport.ts"
expect_eq "0" "$(conv_exit "$CONV/src/reexport.ts")" "conventions: a re-export needs no block"

printf 'public class Thing\n{\n    public int Count { get; }\n}\n' > "$CONV/src/Thing.cs"
expect_eq "2" "$(conv_exit "$CONV/src/Thing.cs")" "conventions: undocumented C# member is reported"
printf '/// <summary>A thing.</summary>\npublic class Thing\n{\n    /// <summary>How many.</summary>\n    public int Count { get; }\n}\n' \
  > "$CONV/src/Documented.cs"
expect_eq "0" "$(conv_exit "$CONV/src/Documented.cs")" "conventions: documented C# member is clean"

# A local declaration inside a body is not a member, and demanding a doc comment on one would make
# the rule impossible to satisfy.
printf '/// <summary>A thing.</summary>\npublic class Thing\n{\n    /// <summary>Run.</summary>\n    public void Run()\n    {\n        var total = 1;\n    }\n}\n' \
  > "$CONV/src/Local.cs"
expect_eq "0" "$(conv_exit "$CONV/src/Local.cs")" "conventions: a local variable is not a member"

# The forbidden-text rule applies to tests; the doc-comment rule does not, because a test name here
# is already a sentence and a comment above it would only restate it.
printf 'export const cases = 1\n' > "$CONV/test/suite.ts"
expect_eq "0" "$(conv_exit "$CONV/test/suite.ts")" "conventions: tests need no doc comments"
printf 'export const cases = 1 // đã xong\n' > "$CONV/test/vietnamese.ts"
expect_eq "2" "$(conv_exit "$CONV/test/vietnamese.ts")" "conventions: forbidden text still applies to tests"
printf '/** Documented. */\nexport const x = 1 // đã xong\n' > "$CONV/src/mixed.ts"
expect_eq "2" "$(conv_exit "$CONV/src/mixed.ts")" "conventions: forbidden text is reported in source"

# Generated code is exempt by what it says, not by where it sits. Naming paths is how the upstream
# version failed — the same generator wrote a second file nobody had listed.
printf '// auto-generated by openapi-typescript\nexport const x = 1\n' > "$CONV/src/gen.ts"
expect_eq "0" "$(conv_exit "$CONV/src/gen.ts")" "conventions: a generated banner exempts the file"
# Stated limit, not a claim of coverage: only the first ten lines are searched, so a module that
# discusses the generator in prose further down does not exempt itself — and one that mentions it in
# its opening lines does. Writing the fixture the other way is how this limit was discovered rather
# than assumed.
{ printf 'export const x = 1\n'; for _ in $(seq 12); do printf '// filler\n'; done
  printf '// this module is not auto-generated by openapi-typescript, it is ours\n'; } \
  > "$CONV/src/prose.ts"
expect_eq "2" "$(conv_exit "$CONV/src/prose.ts")" "conventions: a banner below the head does not exempt"

printf 'export const x = 1\n' > "$CONV/generated/thing.ts"
expect_eq "0" "$(conv_exit "$CONV/generated/thing.ts")" "conventions: a configured skip path is exempt"

# Files and calls the rule has no opinion about.
printf 'export const x = 1\n' > "$CONV/src/notes.md"
expect_eq "0" "$(conv_exit "$CONV/src/notes.md")" "conventions: a non-source suffix is ignored"
expect_eq "0" "$(conv_exit "$CONV/src/bare.ts" Read)" "conventions: a read is not a write"
expect_eq "0" "$(conv_exit "$CONV/src/missing.ts")" "conventions: a file that is not there is not a finding"

rm -rf "$CONV"

# --- 9. the stop gate ----------------------------------------------------------------------------
# The frame, exercised against gate commands invented here. What is being tested is never a test
# command's own behaviour: it is which gates the frame decides to run, how it reads their output, what
# it does with a budget, and whether the merge happens.

STOPREPO=$(mktemp -d)/repo
mkdir -p "$STOPREPO/.claude" "$STOPREPO/app" "$STOPREPO/other"
git -C "$STOPREPO" init -q
git -C "$STOPREPO" config user.name t
git -C "$STOPREPO" config user.email t@t
printf 'x\n' > "$STOPREPO/README"
# The .gitignore the README tells an installing repository to write. Without it the main tree is
# permanently dirty and every merge is refused — the fixture is set up the documented way so that the
# case below, which leaves it out on purpose, is testing something real.
printf '.claude/worktrees/\n.claude/state/\n' > "$STOPREPO/.gitignore"
git -C "$STOPREPO" add -A
git -C "$STOPREPO" commit -qm init
# The main tree sits on an integration branch, which is what the automatic merge advances. The
# default branch stays behind and is never merged into by a stop — section 13 covers that refusal.
git -C "$STOPREPO" checkout -q -b integration

# Runs the stop hook against the fixture and prints "<exit>|<stderr on one line>".
#
# $1 cwd for the session, $2 stop_hook_active ("true"/"false")
stop_run() {
  local cwd="$1" active="${2:-false}" out status
  out=$(printf '{"session_id":"stoptest","stop_hook_active":%s,"cwd":"%s"}' "$active" "$cwd" \
    | Z_HARNESS_HOOK_LOG="$STOPREPO/.git/log.jsonl" CLAUDE_PROJECT_DIR="$STOPREPO" \
      bash "$ROOT/hooks/verify-before-stop.sh" 2>&1)
  status=$?
  printf '%s|%s' "$status" "$(printf '%s' "$out" | tr '\n' ' ')"
}

# Nothing changed and nothing configured: there is no work for the hook to do.
expect_eq "0|" "$(stop_run "$STOPREPO")" "stop: clean tree with no configuration passes"

# A gate runs only for the paths it claims. The unmatched gate writes a marker, so "did not run" is
# an observation rather than an absence.
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{
  "gates": {
    "app":   { "match": "^app/",   "dir": "app",   "run": ["true"] },
    "other": { "match": "^other/", "dir": "other", "run": ["touch ran-other"] }
  }
}
JSON
printf 'change\n' > "$STOPREPO/app/main.ts"
RESULT=$(stop_run "$STOPREPO")
expect_eq "0|" "$RESULT" "stop: a passing gate is silent"
expect_false "stop: an unmatched gate does not run" test -f "$STOPREPO/other/ran-other"

# A failing command blocks, and the message names the gate rather than only the command.
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{ "gates": { "app": { "match": "^app/", "dir": "app", "run": ["echo boom >&2; false"] } } }
JSON
RESULT=$(stop_run "$STOPREPO")
expect_eq "2" "${RESULT%%|*}" "stop: a failing gate blocks the stop"
case "$RESULT" in *"--- app"*) check ok "stop: the failure names the gate" ;;
  *) check no "stop: the failure names the gate" ;; esac
case "$RESULT" in *boom*) check ok "stop: the failure carries the command output" ;;
  *) check no "stop: the failure carries the command output" ;; esac

# The commands of one gate stop at the first failure: a suite that cannot build should not then be
# reported as failing its tests as well.
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{ "gates": { "app": { "match": "^app/", "dir": "app", "run": ["false", "touch ran-second"] } } }
JSON
stop_run "$STOPREPO" > /dev/null
expect_false "stop: commands after a failure do not run" test -f "$STOPREPO/app/ran-second"

# The budget. Three blocked stops, then the escape hatch — loudly, because a stop that gives up must
# not read as a clean run.
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{ "gates": { "app": { "match": "^app/", "dir": "app", "run": ["false"] } } }
JSON
expect_eq "2" "$(stop_run "$STOPREPO" false | cut -d'|' -f1)"  "stop: attempt 1 blocks"
expect_eq "2" "$(stop_run "$STOPREPO" true  | cut -d'|' -f1)"  "stop: attempt 2 blocks"
RESULT=$(stop_run "$STOPREPO" true)
expect_eq "0" "${RESULT%%|*}" "stop: attempt 3 releases rather than looping"
case "$RESULT" in *"GATES ARE STILL FAILING"*) check ok "stop: the release says nothing was verified" ;;
  *) check no "stop: the release says nothing was verified" ;; esac

# A green run returns the budget, so a later task in the same session is not judged by an earlier
# one's failures.
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{ "gates": { "app": { "match": "^app/", "dir": "app", "run": ["true"] } } }
JSON
stop_run "$STOPREPO" true > /dev/null
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{ "gates": { "app": { "match": "^app/", "dir": "app", "run": ["false"] } } }
JSON
expect_eq "2" "$(stop_run "$STOPREPO" true | cut -d'|' -f1)" "stop: a green run refills the budget"

# The note channel. A missing local daemon is not a broken gate, and treating it as one blocks every
# stop on that machine until someone deletes the hook.
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{ "gates": { "app": { "match": "^app/", "dir": "app", "run": ["echo '### NOTE integration tests skipped'"] } } }
JSON
RESULT=$(stop_run "$STOPREPO")
expect_eq "0" "${RESULT%%|*}" "stop: a note does not block"
case "$RESULT" in *"integration tests skipped"*) check ok "stop: a note is said out loud" ;;
  *) check no "stop: a note is said out loud" ;; esac

# A command that declares a failure and exits 0 is still a failure: the protocol is what it says, not
# what its exit code says.
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{ "gates": { "app": { "match": "^app/", "dir": "app", "run": ["echo '### FAIL suite'; echo detail"] } } }
JSON
expect_eq "2" "$(stop_run "$STOPREPO" | cut -d'|' -f1)" "stop: a declared failure blocks despite exit 0"

# A gate naming a directory that is not in this tree is a note, not a failure. Blocking there would
# stop every session in a repository that removed a directory.
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{ "gates": { "app": { "match": "^app/", "dir": "gone", "run": ["false"] } } }
JSON
RESULT=$(stop_run "$STOPREPO")
expect_eq "0" "${RESULT%%|*}" "stop: a missing gate directory does not block"
case "$RESULT" in *"directory missing"*) check ok "stop: a missing gate directory is said out loud" ;;
  *) check no "stop: a missing gate directory is said out loud" ;; esac

# The review receipt, which is the whole mechanism for a rule no hook can read out of a diff.
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{ "sensitivePaths": ["^app/"], "reviewReceipt": { "agent": "invariant-reviewer" } }
JSON
RESULT=$(stop_run "$STOPREPO")
expect_eq "2" "${RESULT%%|*}" "stop: a sensitive change without a receipt blocks"
case "$RESULT" in *invariant-reviewer*) check ok "stop: the block names the reviewer to run" ;;
  *) check no "stop: the block names the reviewer to run" ;; esac

mkdir -p "$STOPREPO/.claude/state"
printf '{"ok":true}' > "$STOPREPO/.claude/state/review-$(git -C "$STOPREPO" rev-parse HEAD).json"
expect_eq "0" "$(stop_run "$STOPREPO" | cut -d'|' -f1)" "stop: a receipt for HEAD satisfies the gate"

# Not opt-in means not enforced: a repository that declares no reviewer is never asked for a receipt.
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{ "sensitivePaths": ["^app/"] }
JSON
rm -rf "$STOPREPO/.claude/state"
expect_eq "0" "$(stop_run "$STOPREPO" | cut -d'|' -f1)" "stop: no reviewer configured means no receipt"

# --- 10. the stop gate inside a worktree ---------------------------------------------------------
# The payoff, and the part that has to work for the plugin to be worth installing: gates green, branch
# merged, without anybody typing a merge command.

# The configuration is committed before the branch is cut. Committing to the main branch after the
# worktree exists makes the branch diverge, and a fast-forward-only merge then correctly refuses —
# which is the behaviour under test two cases further down, not here.
cat > "$STOPREPO/.claude/harness.json" <<'JSON'
{ "gates": { "app": { "match": "^app/", "dir": "app", "run": ["true"] } } }
JSON
git -C "$STOPREPO" add -A > /dev/null 2>&1
git -C "$STOPREPO" commit -qm "work so far" > /dev/null 2>&1

WT="$STOPREPO/.claude/worktrees/feature"
git -C "$STOPREPO" worktree add -q -b worktree-feature "$WT" > /dev/null 2>&1
printf 'from the worktree\n' > "$WT/app/feature.ts"
git -C "$WT" add -A
git -C "$WT" commit -qm "feature work"

RESULT=$(stop_run "$WT")
expect_eq "0" "${RESULT%%|*}" "stop: a worktree session with green gates is allowed to finish"
expect_true "stop: the worktree branch was merged into the main branch" \
  bash -c 'git -C "$1" log --oneline "$(git -C "$1" rev-parse --abbrev-ref HEAD)" | grep -q "feature work"' _ "$STOPREPO"

# A branch that has fallen behind the main branch is refused rather than merged, and the refusal names
# the rebase. Fast-forward only is what makes the merge safe to run unattended.
WT3="$STOPREPO/.claude/worktrees/diverged"
git -C "$STOPREPO" worktree add -q -b worktree-diverged "$WT3" > /dev/null 2>&1
printf 'branch side\n' > "$WT3/app/branch.ts"
git -C "$WT3" add -A
git -C "$WT3" commit -qm "branch work"
printf 'main side\n' > "$STOPREPO/app/main-side.ts"
git -C "$STOPREPO" add -A > /dev/null 2>&1
git -C "$STOPREPO" commit -qm "main moved" > /dev/null 2>&1
RESULT=$(stop_run "$WT3")
expect_eq "2" "${RESULT%%|*}" "stop: a diverged branch is not merged"
case "$RESULT" in *rebase*) check ok "stop: the refusal names the rebase" ;;
  *) check no "stop: the refusal names the rebase" ;; esac
git -C "$STOPREPO" worktree remove --force "$WT3" > /dev/null 2>&1
git -C "$STOPREPO" branch -D worktree-diverged > /dev/null 2>&1

# A committed branch is judged by the whole branch, not by its uncommitted files. Judging it by the
# working tree alone would mean committing — the step that makes the merge possible — is what makes
# every gate skip.
#
# Its own fixture, and deliberately so: the first version of this case reused the repository above and
# passed under a mutant that removed the branch diff entirely, because its exit code was coming from
# somewhere else. A case that cannot fail is not a case.
BRANCHED=$(mktemp -d)/repo
mkdir -p "$BRANCHED/.claude" "$BRANCHED/app"
git -C "$BRANCHED" init -q
git -C "$BRANCHED" config user.name t
git -C "$BRANCHED" config user.email t@t
printf '.claude/worktrees/\n.claude/state/\n' > "$BRANCHED/.gitignore"
printf 'a\n' > "$BRANCHED/app/main.ts"
cat > "$BRANCHED/.claude/harness.json" <<'JSON'
{ "gates": { "app": { "match": "^app/", "dir": "app", "run": ["false"] } } }
JSON
git -C "$BRANCHED" add -A
git -C "$BRANCHED" commit -qm init
git -C "$BRANCHED" worktree add -q -b worktree-branched "$BRANCHED/.claude/worktrees/w" > /dev/null 2>&1
printf 'b\n' > "$BRANCHED/.claude/worktrees/w/app/new.ts"
git -C "$BRANCHED/.claude/worktrees/w" add -A
git -C "$BRANCHED/.claude/worktrees/w" commit -qm "committed work"

# Runs the stop hook from the BRANCHED worktree and prints its exit code.
branched_run() {
  printf '{"session_id":"branched","stop_hook_active":false,"cwd":"%s"}' "$BRANCHED/.claude/worktrees/w" \
    | Z_HARNESS_HOOK_LOG="$BRANCHED/.git/log.jsonl" CLAUDE_PROJECT_DIR="$BRANCHED" \
      bash "$ROOT/hooks/verify-before-stop.sh" > /dev/null 2>&1
  printf '%s' "$?"
}
expect_eq "2" "$(branched_run)" "stop: a clean worktree is still gated by what its branch committed"
expect_true "stop: an ungated branch is not merged" \
  bash -c '! git -C "$1" log --oneline master 2>/dev/null | grep -q "committed work"' _ "$BRANCHED"
rm -rf "$(dirname "$BRANCHED")"

# What actually refuses the merge, checked rather than assumed. The check reads
# `--untracked-files=no`, so an untracked directory — including an un-ignored .claude/worktrees/ —
# does not block it; a tracked file with uncommitted changes does, because the merge checks files out
# in that tree and would overwrite them. This case exists because the README claimed the opposite
# until it was run.
DIRTY=$(mktemp -d)/repo
mkdir -p "$DIRTY"
git -C "$DIRTY" init -q
git -C "$DIRTY" config user.name t
git -C "$DIRTY" config user.email t@t
printf 'x\n' > "$DIRTY/README"
git -C "$DIRTY" add -A
git -C "$DIRTY" commit -qm init
git -C "$DIRTY" checkout -q -b integration
git -C "$DIRTY" worktree add -q -b worktree-dirty "$DIRTY/.claude/worktrees/dirty" > /dev/null 2>&1
printf 'work\n' > "$DIRTY/.claude/worktrees/dirty/thing.ts"
git -C "$DIRTY/.claude/worktrees/dirty" add -A
git -C "$DIRTY/.claude/worktrees/dirty" commit -qm "worktree work"

# The worktree directory itself is untracked here, and that alone does not stop the merge.
MERGE_OUT=$(bash "$ROOT/hooks/merge-worktree.sh" "$DIRTY/.claude/worktrees/dirty" "$DIRTY/.claude/worktrees/dirty" 2>&1)
expect_eq "0" "$?" "merge: an untracked directory in the main tree does not block"

# An uncommitted change to a tracked file does.
git -C "$DIRTY" worktree add -q -b worktree-second "$DIRTY/.claude/worktrees/second" > /dev/null 2>&1
printf 'more\n' > "$DIRTY/.claude/worktrees/second/second.ts"
git -C "$DIRTY/.claude/worktrees/second" add -A
git -C "$DIRTY/.claude/worktrees/second" commit -qm "second work"
printf 'edited in the main tree\n' > "$DIRTY/README"
MERGE_OUT=$(bash "$ROOT/hooks/merge-worktree.sh" "$DIRTY/.claude/worktrees/second" "$DIRTY/.claude/worktrees/second" 2>&1)
MERGE_CODE=$?
expect_eq "2" "$MERGE_CODE" "merge: uncommitted changes in the main tree refuse the merge"
case "$MERGE_OUT" in *"main working tree"*|*uncommitted*|*clean*)
    check ok "merge: the refusal says the main tree is not clean" ;;
  *) check no "merge: the refusal says the main tree is not clean (got: $(printf '%s' "$MERGE_OUT" | tr '\n' ' '))" ;;
esac
rm -rf "$(dirname "$DIRTY")"

rm -rf "$(dirname "$STOPREPO")"

# --- 11. content rules --------------------------------------------------------------------------
# The mechanism a repository declares its own rules through. None of the rules below mean anything
# outside this fixture, which is the point: the plugin supplies the reading, never the rule.

# Not under mktemp's directory, and that is load-bearing rather than fussy. The write detector treats
# /tmp, /private/tmp and /var/folders as scratch space and exempts them, so a fixture living there
# makes every shell-command case pass for the wrong reason — the rule never runs at all.
RULES="${HOME}/.cache/z-harness-tests/rules-$$"
rm -rf "$RULES"
mkdir -p "$RULES/.claude/state" "$RULES/src/edge" "$RULES/src/ui"
git -C "$RULES" init -q
cat > "$RULES/.claude/harness.json" <<'JSON'
{
  "contentRules": [
    { "match": "^src/edge/",
      "forbid": "Cache-Control:[^\"]*immutable",
      "why": "HTML must never be immutable; a browser cannot purge it." },
    { "match": "^src/edge/robots\\.ts$",
      "require": "X-Robots-Tag",
      "why": "The default subdomain must stay noindex." }
  ]
}
JSON

# Runs the hook against one payload and prints its exit code.
rules_exit() {
  printf '%s' "$1" | Z_HARNESS_HOOK_LOG="$RULES/.git/log.jsonl" CLAUDE_PROJECT_DIR="$RULES" \
    bash "$ROOT/hooks/check-content-rules.sh" > /dev/null 2>&1
  printf '%s' "$?"
}

# Builds an Edit payload: $1 repo-relative path, $2 old text, $3 new text.
rules_edit() {
  jq -nc --arg f "$RULES/$1" --arg o "$2" --arg n "$3" \
    '{tool_name:"Edit", session_id:"rulestest", tool_input:{file_path:$f, old_string:$o, new_string:$n}}'
}

# Nothing declared, nothing checked.
NOCONF=$(mktemp -d)
mkdir -p "$NOCONF/.claude"
expect_eq "0" "$(printf '%s' "$(jq -nc --arg f "$NOCONF/src/x.ts" \
  '{tool_name:"Write", session_id:"r", tool_input:{file_path:$f, content:"Cache-Control: immutable"}}')" \
  | CLAUDE_PROJECT_DIR="$NOCONF" bash "$ROOT/hooks/check-content-rules.sh" > /dev/null 2>&1; printf '%s' "$?")" \
  "content: no rules declared means nothing is checked"
rm -rf "$NOCONF"

# forbid, and the path scoping that keeps it from applying everywhere.
expect_eq "2" "$(rules_exit "$(rules_edit src/edge/headers.ts 'a' 'Cache-Control: public, immutable')")" \
  "content: a forbidden pattern in a ruled path is refused"
expect_eq "0" "$(rules_exit "$(rules_edit src/edge/headers.ts 'a' 'Cache-Control: public, max-age=60')")" \
  "content: an allowed value in the same file passes"
expect_eq "0" "$(rules_exit "$(rules_edit src/ui/button.tsx 'a' 'Cache-Control: public, immutable')")" \
  "content: the same text outside the ruled path is not the rule's business"

# require, which is about removal rather than absence. Asking whether the new text contains the
# pattern would refuse every edit to every other line of the file.
expect_eq "2" "$(rules_exit "$(rules_edit src/edge/robots.ts 'X-Robots-Tag: noindex' 'nothing here')")" \
  "content: an edit that removes required text is refused"
expect_eq "0" "$(rules_exit "$(rules_edit src/edge/robots.ts 'X-Robots-Tag: noindex' 'X-Robots-Tag: noindex, nofollow')")" \
  "content: keeping the required text passes"
expect_eq "0" "$(rules_exit "$(rules_edit src/edge/robots.ts 'const port = 1' 'const port = 2')")" \
  "content: an edit elsewhere in the file is not a removal"

# The deletion shape. An Edit whose replacement is empty produces no new text at all, and every check
# phrased as "what does the new text say" is blind to it — which is how a guarantee was removed
# upstream without any rule seeing it.
expect_eq "2" "$(rules_exit "$(rules_edit src/edge/robots.ts 'X-Robots-Tag: noindex' '')")" \
  "content: deleting the required line is refused"

# A shell command is refused on the strength of the path, because the bytes are not readable here.
SHELL_PAYLOAD=$(jq -nc --arg c "cat > $RULES/src/edge/headers.ts <<EOF" \
  '{tool_name:"Bash", session_id:"rulestest", tool_input:{command:$c}}')
expect_eq "2" "$(rules_exit "$SHELL_PAYLOAD")" "content: a shell write to a ruled path is refused"
SHELL_OK=$(jq -nc --arg c "cat > $RULES/src/ui/button.tsx <<EOF" \
  '{tool_name:"Bash", session_id:"rulestest", tool_input:{command:$c}}')
expect_eq "0" "$(rules_exit "$SHELL_OK")" "content: a shell write elsewhere is not refused"
SHELL_READ=$(jq -nc --arg c "grep -rn immutable $RULES/src/edge" \
  '{tool_name:"Bash", session_id:"rulestest", tool_input:{command:$c}}')
expect_eq "0" "$(rules_exit "$SHELL_READ")" "content: reading a ruled path is not writing to it"

# Reads are never the rules' business, whatever they carry.
READ_PAYLOAD=$(jq -nc --arg f "$RULES/src/edge/headers.ts" \
  '{tool_name:"Read", session_id:"rulestest", tool_input:{file_path:$f}}')
expect_eq "0" "$(rules_exit "$READ_PAYLOAD")" "content: a read is not a write"

# A write inside a worktree is the same file as far as the rules are concerned. Without the prefix
# strip this would miss every edit, since every edit is supposed to happen in one.
WT_EDIT=$(jq -nc --arg f "$RULES/.claude/worktrees/feature/src/edge/headers.ts" \
  '{tool_name:"Edit", session_id:"rulestest", tool_input:{file_path:$f, old_string:"a", new_string:"Cache-Control: immutable"}}')
expect_eq "2" "$(rules_exit "$WT_EDIT")" "content: a worktree path is still the ruled path"

# The declared escape hatch, and its expiry. It exists because the rule and the test proving the rule
# is alive point at each other: breaking a rule on purpose is how you learn the test still catches it.
BREAKING=$(rules_edit src/edge/headers.ts 'a' 'Cache-Control: public, immutable')
printf 'Mutating the immutable rule to confirm the suite still catches it.\n' \
  > "$RULES/.claude/state/mutation-rulestest.md"
expect_eq "0" "$(rules_exit "$BREAKING")" "content: a declared mutation is allowed through"
expect_eq "2" "$(printf '%s' "$(rules_edit src/edge/headers.ts 'a' 'Cache-Control: public, immutable' \
  | jq -c '.session_id = "someone_else"')" | Z_HARNESS_HOOK_LOG="$RULES/.git/log.jsonl" \
  CLAUDE_PROJECT_DIR="$RULES" bash "$ROOT/hooks/check-content-rules.sh" > /dev/null 2>&1; printf '%s' "$?")" \
  "content: the escape hatch belongs to one session only"
# Backdated past the window: the door closes on its own, so a declaration made once does not disarm
# the rules for the rest of the session.
touch -t 202001010000 "$RULES/.claude/state/mutation-rulestest.md"
expect_eq "2" "$(rules_exit "$BREAKING")" "content: an expired mutation declaration stops working"
rm -f "$RULES/.claude/state/mutation-rulestest.md"

# An empty declaration is not a declaration.
: > "$RULES/.claude/state/mutation-rulestest.md"
expect_eq "2" "$(rules_exit "$BREAKING")" "content: an empty mutation file does not open the door"
rm -f "$RULES/.claude/state/mutation-rulestest.md"

# Text larger than a pipe buffer. `printf | grep -q` under pipefail reads a match as no match once the
# writer takes SIGPIPE, which past 64 KiB is every time the match comes early — so the decisive text
# goes first and about 200 KB of padding after it.
#
# The content reaches jq on stdin rather than as --arg: Linux caps one argv string at 128 KiB, jq then
# dies with "Argument list too long", and an empty payload passes as whatever the hook does with one.
# Upstream that made a refusal case green while checking nothing.
#
# $1 repo-relative path, $2 text placed before the padding
rules_big_write() {
  { printf '%s\n' "$2"; head -c 200000 /dev/zero | tr '\0' 'x'; printf '\n'; } |
    jq -Rsc --arg f "$RULES/$1" \
      '{tool_name:"Write", session_id:"rulestest", tool_input:{file_path:$f, content:.}}'
}
BIG_BAD=$(rules_big_write src/edge/headers.ts 'Cache-Control: public, immutable')
BIG_OK=$(rules_big_write src/edge/headers.ts 'Cache-Control: public, max-age=60')
expect_true "content: the large payload was built" test "${#BIG_BAD}" -gt 150000
expect_eq "2" "$(rules_exit "$BIG_BAD")" "content: a forbidden pattern in a file over 64 KiB is refused"
expect_eq "0" "$(rules_exit "$BIG_OK")" "content: a compliant file over 64 KiB is allowed"

rm -rf "$RULES"

# --- 12. shipped agents --------------------------------------------------------------------------
# The same class of case as the executable check on the hooks, for the same reason: an agent file
# Claude Code cannot parse is not reported as broken, it is simply absent, and absent looks identical
# to "the caller chose not to use it".

for agent in "$ROOT"/agents/*.md; do
  [[ -e "$agent" ]] || continue
  name="${agent##*/}"
  expect_true "agent has front matter: $name" bash -c 'head -1 "$1" | grep -qx -- ---' _ "$agent"
  for key in name description tools; do
    expect_true "agent declares $key: $name" \
      bash -c 'awk "/^---$/{n++; next} n==1" "$1" | grep -qE "^$2:" ' _ "$agent" "$key"
  done
  # The name in the front matter is what the caller types, and a file whose name disagrees with it is
  # the kind of mismatch nobody notices until the agent cannot be found.
  declared=$(awk '/^---$/{n++; next} n==1' "$agent" | grep -E '^name:' | head -1 | sed 's/^name:[[:space:]]*//')
  expect_eq "${name%.md}" "$declared" "agent name matches its filename: $name"
  # Read-only by construction. An agent shipped with Edit or Write would be editing outside the
  # worktree the rest of this plugin exists to enforce.
  expect_false "agent is read-only: $name" \
    bash -c 'awk "/^---$/{n++; next} n==1" "$1" | grep -E "^tools:" | grep -qE "(Edit|Write|NotebookEdit)"' _ "$agent"
done

# --- 13. the two branches: where a worktree merges, and what the repository publishes from --------
# One function used to answer both questions. The merge target is what `git merge --ff-only` in the
# main tree advances — the branch checked out there — and the publish branch is a different branch
# whenever the main tree is on a feature branch. Every message, refusal and gate baseline named the
# wrong one of the two, and on a repository sitting on its default branch the stop fast-forwarded it
# silently.

# shellcheck source=/dev/null
source "$ROOT/hooks/lib-main-branch.sh"

# Prints the default branch of a fresh repository whose only branch is $1.
fresh_default() {
  local repo got
  repo=$(mktemp -d)
  git -C "$repo" init -q -b "$1"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  got=$(default_branch_name "$repo")
  rm -rf "$repo"
  printf '%s' "$got"
}
expect_eq "main"   "$(fresh_default main)"   "branches: a repository on main publishes from main"
expect_eq "master" "$(fresh_default master)" "branches: a repository on master publishes from master"
# Neither main nor master and no origin/HEAD: the last resort is the main tree's own branch, so a
# single-branch repository still has a protected branch rather than none.
expect_eq "trunk"  "$(fresh_default trunk)"  "branches: a repository on trunk publishes from trunk"

# The remote's own idea of default wins over a local main, and need not exist locally.
BR=$(mktemp -d)
git -C "$BR" init -q -b main
git -C "$BR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$BR" remote add origin https://example.invalid/r.git
git -C "$BR" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/release
expect_eq "release" "$(default_branch_name "$BR")" "branches: origin/HEAD names the publish branch"

# The pair the old function could not tell apart. If these came out equal, the protected-branch
# refusal would refuse every merge.
git -C "$BR" checkout -q -b integration
expect_eq "integration" "$(target_branch_name "$BR")" "branches: the target is what the main tree has checked out"
WTB="$BR/.claude/worktrees/w"
git -C "$BR" worktree add -q -b worktree-w "$WTB" > /dev/null 2>&1
expect_eq "integration" "$(target_branch_name "$WTB")" \
  "branches: asked from inside a worktree, the target is still the main tree's branch"
git -C "$BR" checkout -q --detach
expect_eq "" "$(target_branch_name "$BR")" "branches: a detached main tree has no target"
rm -rf "$BR"

# No hook may go back to hardcoding either branch.
expect_eq "" "$(grep -nE 'merge-base[[:space:]]+main\b|(MAIN|TARGET|DEFAULT)_BRANCH=("|'"'"')?(main|master)\b' \
  "$ROOT"/hooks/verify-before-stop.sh "$ROOT"/hooks/merge-worktree.sh)" "branches: no branch name is hardcoded"

# --- 14. merge-worktree, case by case ------------------------------------------------------------
# `pwd -P` on the temporary directory is load-bearing: on macOS mktemp returns /var/... while git
# reports /private/var/..., and a prefix test between the two silently answers no.
#
# The fixture has an origin/HEAD naming main, and that is load-bearing too: without it the old code
# fell through to the branch checked out in the main tree, which is the right answer by accident, so
# every case passed against the code that had the bug.
#
# $1 the branch to leave checked out in the main tree (default: integration). Prints "<repo> <wt>".
mw_setup() {
  local target="${1:-integration}" repo wt
  repo=$(mktemp -d)
  repo=$(cd "$repo" && pwd -P)
  git -C "$repo" init -q -b main
  mkdir -p "$repo/.claude"
  printf '.claude/worktrees/\n.claude/state/\n' > "$repo/.gitignore"
  printf 'x\n' > "$repo/keep.txt"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m init
  git -C "$repo" remote add origin https://example.invalid/r.git
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  [[ "$target" == "main" ]] || git -C "$repo" checkout -q -b "$target"
  wt="$repo/.claude/worktrees/w"
  git -C "$repo" worktree add -q -b worktree-w "$wt" "$target" > /dev/null 2>&1
  printf 'x\n' > "$wt/file.txt"
  git -C "$wt" add file.txt
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m work
  printf '%s %s' "$repo" "$wt"
}

# Prints "<exit>|<target moved: yes/no>|<output on one line>" for one merge.
#
# $1 repo, $2 worktree, $3 session cwd, $4 target branch (default: integration)
mw_run() {
  local repo="$1" wt="$2" cwd="$3" target="${4:-integration}" sha out status moved=no
  sha=$(git -C "$wt" rev-parse HEAD)
  out=$( cd "$repo" && bash "$ROOT/hooks/merge-worktree.sh" "$wt" "$cwd" 2>&1 )
  status=$?
  [[ "$(git -C "$repo" rev-parse "$target" 2>/dev/null)" == "$sha" ]] && moved=yes
  printf '%s|%s|%s' "$status" "$moved" "$(printf '%s' "$out" | tr '\n' ' ')"
}

read -r MW_REPO MW_WT <<< "$(mw_setup)"
R=$(mw_run "$MW_REPO" "$MW_WT" "$MW_REPO")
expect_eq "0|yes" "${R%|*}" "merge: a clean branch fast-forwards the branch it was cut from"
expect_false "merge: a merged worktree the session has left is removed" test -d "$MW_WT"
rm -rf "$MW_REPO"

read -r MW_REPO MW_WT <<< "$(mw_setup)"
printf 'uncommitted\n' > "$MW_WT/dirty.txt"
R=$(mw_run "$MW_REPO" "$MW_WT" "$MW_REPO")
expect_eq "2|no" "${R%|*}" "merge: a dirty worktree is refused"
rm -rf "$MW_REPO"

# Diverged, asserted on the target — the direction the old code got wrong. It compared against the
# publish branch, which was still an ancestor here, so `git merge --ff-only` failed later with git's
# own wording and the message naming the rebase never printed.
read -r MW_REPO MW_WT <<< "$(mw_setup)"
git -C "$MW_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "meanwhile, on the target"
R=$(mw_run "$MW_REPO" "$MW_WT" "$MW_REPO")
expect_eq "2|no" "${R%|*}" "merge: a diverged branch is refused"
case "$R" in *"rebase integration"*) check ok "merge: a divergence names the rebase onto the target" ;;
  *) check no "merge: a divergence names the rebase onto the target" ;; esac
rm -rf "$MW_REPO"

# The publish branch is not advanced by a session stopping. Exit 0, not 2: the session cannot fix this
# by editing code, and a non-zero exit would spend the stop hook's three-stop budget only to release
# with the same news. The worktree survives, since its commits are the only copy of the work.
read -r MW_REPO MW_WT <<< "$(mw_setup main)"
R=$(mw_run "$MW_REPO" "$MW_WT" "$MW_REPO" main)
expect_eq "0|no" "${R%|*}" "merge: the publish branch is not merged into automatically"
expect_true "merge: the refused worktree is kept" test -d "$MW_WT"
case "$R" in *"merge --ff-only worktree-w"*) check ok "merge: the refusal prints the command to run" ;;
  *) check no "merge: the refusal prints the command to run" ;; esac

# Opted in: the same repository, told in harness.json that its default branch may be merged into.
printf '%s' '{"merge":{"intoDefaultBranch":true}}' > "$MW_REPO/.claude/harness.json"
R=$(mw_run "$MW_REPO" "$MW_WT" "$MW_REPO" main)
expect_eq "0|yes" "${R%|*}" "merge: a repository that opts in has its default branch merged into"
rm -rf "$MW_REPO"

# A detached main tree has nothing to fast-forward, and it is not the session's work that is wrong.
read -r MW_REPO MW_WT <<< "$(mw_setup)"
git -C "$MW_REPO" checkout -q --detach
R=$(mw_run "$MW_REPO" "$MW_WT" "$MW_REPO")
expect_eq "0|no" "${R%|*}" "merge: a detached main tree is said, not merged and not blocked"
rm -rf "$MW_REPO"

# The session standing inside the worktree: the merge happens and the directory stays. Removing it
# deleted a session's cwd out from under it upstream, twice.
read -r MW_REPO MW_WT <<< "$(mw_setup)"
R=$(mw_run "$MW_REPO" "$MW_WT" "$MW_WT")
expect_eq "0|yes" "${R%|*}" "merge: the session's own worktree still merges"
expect_true "merge: the worktree the session stands in is never removed" test -d "$MW_WT"
rm -rf "$MW_REPO"

# --- 15. the stop gate's baseline, and the worktree found from a subdirectory --------------------
# The baseline is the branch the worktree was cut from. Against the publish branch, a worktree cut from
# a long-lived feature branch was measured across the entire feature: upstream, 73 files and four gates
# on every stop, for a diff whose own contents were empty. Both directions, because the failure modes
# are opposite and a fix for one is the other's bug.
#
# $1 expected exit, $2 case name, $3 path committed on the target, $4 path committed in the worktree,
# $5 cwd below the worktree root the session stops from (optional)
baseline_case() {
  local want="$1" name="$2" on_target="$3" in_worktree="$4" sub="${5:-}" repo wt got
  repo=$(mktemp -d)
  repo=$(cd "$repo" && pwd -P)
  git -C "$repo" init -q -b main
  mkdir -p "$repo/.claude"
  printf '.claude/worktrees/\n.claude/state/\n' > "$repo/.gitignore"
  printf '%s' '{ "gates": { "app": { "match": "^app/", "dir": "app", "run": ["false"] } } }' \
    > "$repo/.claude/harness.json"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m init
  git -C "$repo" remote add origin https://example.invalid/r.git
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$repo" checkout -q -b integration
  mkdir -p "$repo/$(dirname "$on_target")"
  printf 'x\n' > "$repo/$on_target"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m "already on the target"
  wt="$repo/.claude/worktrees/w"
  git -C "$repo" worktree add -q -b worktree-w "$wt" integration > /dev/null 2>&1
  mkdir -p "$wt/$(dirname "$in_worktree")"
  printf 'y\n' > "$wt/$in_worktree"
  git -C "$wt" add -A
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m "this session's work"
  [[ -n "$sub" ]] && mkdir -p "$wt/$sub"
  jq -nc --arg c "$wt${sub:+/$sub}" '{stop_hook_active:false, session_id:"baseline", cwd:$c}' |
    Z_HARNESS_HOOK_LOG="$repo/.git/log.jsonl" CLAUDE_PROJECT_DIR="$repo" \
      bash "$ROOT/hooks/verify-before-stop.sh" > /dev/null 2>&1
  got=$?
  rm -rf "$repo"
  expect_eq "$want" "$got" "stop baseline: $name"
}
baseline_case 0 "work already on the target does not dispatch its gate" app/other.ts notes.txt
baseline_case 2 "work done in the worktree still dispatches its gate"   notes.txt app/mine.ts
# A session whose shell last `cd`-ed into a subdirectory stops from there. Taken as the worktree, that
# subdirectory became the tree every gate's `dir` was looked up in: the gate read "directory missing",
# noted it and let a red gate through.
baseline_case 2 "a stop from a subdirectory still runs the gate at the worktree root" \
  notes.txt app/mine.ts tools/e2e

# --- 16. guard-push ------------------------------------------------------------------------------
# A deny rule matches a prefix, and "reaches the publish branch" is not one. The hook has to recognise
# every spelling that lands there — a bare push with it checked out, `HEAD:main`, `:main`, an alias,
# `sh -c` — and must still let a feature branch through, or it is a deny list with extra steps.

PUSH_REPO=$(mktemp -d)
PUSH_REPO=$(cd "$PUSH_REPO" && pwd -P)
git init -q --bare "$PUSH_REPO/origin.git"
git init -q -b main "$PUSH_REPO/repo"
git -C "$PUSH_REPO/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$PUSH_REPO/repo" remote add origin "$PUSH_REPO/origin.git"
git -C "$PUSH_REPO/repo" push -q origin main 2>/dev/null
git -C "$PUSH_REPO/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$PUSH_REPO/repo" branch feature
git -C "$PUSH_REPO/repo" config alias.p push
git -C "$PUSH_REPO/repo" config alias.sync '!git fetch && git push'

# $1 expected exit, $2 branch checked out, $3 command
push_case() {
  local want="$1" branch="$2" cmd="$3" got
  git -C "$PUSH_REPO/repo" checkout -q "$branch"
  ( cd "$PUSH_REPO/repo" && jq -nc --arg c "$cmd" --arg d "$PUSH_REPO/repo" \
      '{tool_name:"Bash", session_id:"pushtest", cwd:$d, tool_input:{command:$c}}' |
    Z_HARNESS_HOOK_LOG="$PUSH_REPO/log.jsonl" CLAUDE_PROJECT_DIR="$PUSH_REPO/repo" \
      bash "$ROOT/hooks/guard-push.sh" ) > /dev/null 2>&1
  got=$?
  expect_eq "$want" "$got" "push on $branch: $cmd"
}

push_case 0 feature 'git push origin feature'
push_case 0 feature 'git push -u origin feature'
push_case 0 feature 'git push'
push_case 0 feature 'git push origin HEAD'
push_case 0 feature 'git push origin feature 2>&1 | tail -5'
push_case 0 feature 'git p origin feature'
push_case 0 feature 'git push origin main:refs/heads/backup-main'
push_case 0 feature 'git push --dry-run origin main'
push_case 0 feature 'git push --tags'
push_case 0 feature "grep -rn 'git push origin main' ."
push_case 0 feature 'git commit -m "push to main later"'
push_case 2 main    'git push'
push_case 2 main    'git push origin HEAD'
push_case 2 feature 'git push origin main'
push_case 2 feature 'git push origin "main"'
push_case 2 feature 'git push origin HEAD:main'
push_case 2 feature 'git push -f origin +feature:refs/heads/main'
push_case 2 feature 'git push origin :main'
push_case 2 feature 'git push --delete origin main'
push_case 2 feature 'git push --all origin'
push_case 2 feature 'git push origin feature && git push origin main'
push_case 2 feature 'git -c push.default=matching push'
push_case 2 feature 'git push origin refs/heads/*:refs/heads/*'
push_case 2 feature 'git p origin main'
push_case 2 feature 'git sync'
push_case 2 feature 'sh -c "git push origin main"'
push_case 2 feature 'eval git push origin main'
push_case 2 feature 'timeout 30 git push origin main'
# The destination is not in the text, so it cannot be shown not to be protected.
push_case 2 feature 'git push origin $BRANCH'
push_case 2 feature 'git push origin $(git branch --show-current)'
push_case 2 feature 'echo x | xargs git push origin'
push_case 2 main    "cd /tmp && cd $PUSH_REPO/repo && git push"

# The log line carries the payload's session id unchanged. Piping jq into `tr -c` once logged
# `pushtest_`, so the decisions never joined up with the other hooks' lines for a session.
expect_eq "pushtest" "$(grep '"hook":"guard-push"' "$PUSH_REPO/log.jsonl" | tail -1 | jq -r '.session')" \
  "push: the log carries the session id it was given"

# Unconfigured, the protected branch is whatever origin/HEAD names, so a rename does not open a hole.
git -C "$PUSH_REPO/repo" branch release
git -C "$PUSH_REPO/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/release
push_case 2 feature 'git push origin release'

# A declared list replaces the default, and an empty one turns the guard off.
mkdir -p "$PUSH_REPO/repo/.claude"
printf '%s' '{"push":{"protectedBranches":["main","prod"]}}' > "$PUSH_REPO/repo/.claude/harness.json"
push_case 2 feature 'git push origin prod'
push_case 2 feature 'git push origin main'
push_case 0 feature 'git push origin release'
printf '%s' '{"push":{"protectedBranches":[]}}' > "$PUSH_REPO/repo/.claude/harness.json"
push_case 0 feature 'git push origin main'
rm -rf "$PUSH_REPO"

printf '\nhooks: %d passed' "$PASS"
if [[ $FAIL -gt 0 ]]; then printf ', %d FAILED\n' "$FAIL"; exit 1; fi
printf '\n'
