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
    | CLAUDE_HARNESS_HOOK_LOG="$CONV/log.jsonl" CLAUDE_PROJECT_DIR="$CONV" \
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

printf '\nhooks: %d passed' "$PASS"
if [[ $FAIL -gt 0 ]]; then printf ', %d FAILED\n' "$FAIL"; exit 1; fi
printf '\n'
