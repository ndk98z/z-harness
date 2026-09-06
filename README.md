# z-harness

Worktree isolation and a plan gate for Claude Code sessions, packaged as a plugin.

Extracted from a production repository where every guard in here was written after the bug it now
catches. It carries the mechanisms, not that project's rules: what counts as a sensitive path is
declared by the repository you install it into.

Requires `git`, `bash`, and `jq`.

## What it does

**Worktree isolation** (`auto-worktree.sh`, `PreToolUse`). Refuses file edits made outside a git
worktree, so a session's work lands on a branch instead of on the main working tree. Writes to
`/tmp`, to build output (`dist/`, `node_modules/`, `obj/`), and to paths outside the repository are
allowed without one.

It refuses shell commands that write, not only the `Edit` and `Write` tools. A guard that reads tool
payloads and ignores `cat > file <<EOF` will watch a heredoc perform the change it just declined.
The detector skips heredoc bodies and quoted text, so `grep -rn 'tee -a' .` is not mistaken for a
write — this is a syntax guard, not a sandbox, and `sh -c "cat > x"` gets through.

It also refuses an `npm ci` that would delete a `node_modules` symlinked out of the tree the command
runs in. Keyed on the symlink rather than on "am I in a worktree", so `npm ci` in the main tree stays
allowed and `npm ci --prefix <worktree>/app` from anywhere is still caught.

**Plan gate** (`require-plan.sh`, `PreToolUse`). Blocks the first edit into a path the repository
calls sensitive until the session has written `.claude/state/plan-<session>.md` — at least three
lines saying what changes, what it sits near, and how it will be verified. `.claude/` itself is
always in the gated set: editing a hook cannot break your invariants, but it can quietly remove the
check that would have caught something that does.

**Decision log** (`lib-hook-log.sh`). Every hook decision, `allow` as well as `block`, appended as
JSONL to `$(git rev-parse --git-common-dir)/z-harness-hooks.jsonl` — inside the git directory,
never in a working tree, because a log file in the tree makes every worktree dirty and every merge
refuse. Paths and reason codes only, never file contents.

```bash
jq -s 'group_by(.reason) | map({(.[0].reason): length}) | add' \
  "$(git rev-parse --git-common-dir)/z-harness-hooks.jsonl"
```

Logging the allows is the point. Without a denominator, a false-refusal rate is not computable, and
the write detector in here had its patterns tuned twice by guesswork for exactly that reason.

**Merge helper** (`merge-worktree.sh`). Fast-forward-only merge of a worktree branch into the main
branch, run from the main working tree. Refuses a dirty worktree. In this version it is **not wired
to a hook** — see [Not in 0.1.0](#not-in-010).

## Install

From a local directory, which is enough to try it and needs no remote:

```
/plugin marketplace add /absolute/path/to/z-harness
/plugin install z-harness@z-harness
```

## Configure the repository

Create `.claude/harness.json` in the repository you installed it into:

```json
{
  "sensitivePaths": [
    "^src/billing/",
    "^migrations/"
  ]
}
```

Extended regular expressions, matched against repository-relative paths. With no file, or an empty
list, the plan gate covers `.claude/` and nothing else — it never falls back to gating everything.

Add to that repository's `.gitignore`:

```
.claude/worktrees/
.claude/state/
```

Both matter. An un-ignored `.claude/worktrees/` leaves the main tree permanently dirty, which makes
the merge refuse **every** time, silently.

## Tell the model the workflow

The hooks enforce a workflow; they do not explain it. Without the prose, a session gets blocked by a
rule nobody wrote down. Paste this into the repository's `CLAUDE.md`:

```markdown
## Worktree isolation — edit in a worktree, not on main

Every file edit must happen inside a git worktree. The main working tree is for setup
(dependency installs, docker compose) and read-only work.

1. **Setup** (main tree): install dependencies, start services. Bash and Read are allowed here;
   only Edit/Write are blocked.
2. **Edit** (worktree): call `EnterWorktree` with a descriptive name. The worktree is created at
   `.claude/worktrees/{name}` on branch `worktree-{name}`.
3. **Commit inside the worktree** before finishing. A dirty worktree cannot be merged.
4. **Merge**: run `bash <plugin>/hooks/merge-worktree.sh`. Do not merge by hand, and never with
   `git update-ref` — that moves the pointer without touching the main tree's index, so main
   immediately reports the whole merge as staged changes in reverse.

If the merge fails, the branch has diverged: `git rebase main` inside the worktree, then retry.

Editing any path listed in `.claude/harness.json`, or anything under `.claude/`, requires a plan
at `.claude/state/plan-<session>.md` first — at least three lines: what changes, what it sits
near, how it will be verified.
```

## Not in 0.1.0

- **No `Stop` gate.** The upstream `verify-before-stop.sh` runs a repository's test gates before a
  session may finish, and it is what calls the merge helper. It needs the gate table to become
  configuration first. Until then, **the merge is manual** — nothing runs it for you.
- **No content rules.** The upstream `check-invariants.sh` compares text about to be written against
  a table of product rules. The mechanism generalises; the rules do not, so neither ships here yet.

## Tests

```bash
bash tests/test-hooks.sh
```

Three classes of case, and skipping any of them has cost this code before:

1. **Executable check** — the hook list is read out of `plugin.json` and every entry must exist and
   carry the execute bit. A hook invoked by a bare path without that bit fails silently, and a silent
   failure is indistinguishable from a decision to allow. One guard upstream lived its entire life
   that way, blocking nothing; the evidence was negative — no log line ever named it.
2. **False refusal** — every blocking rule also has a case proving it has not opened too wide. This
   half costs more to write than the blocking half, and dropping it is the fastest route to a guard
   being deleted by the person it keeps interrupting.
3. **Behaviour** — configuration plumbing, and the worktree-prefix strip that every check depends on.
   Without that strip, every check silently misses every edit, since every edit happens in a worktree.

The suite is mutation-tested: removing an execute bit, or widening the sensitive-path regex to match
everything, both turn it red.
