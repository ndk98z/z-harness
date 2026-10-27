# Contributing to z-harness

Thanks for looking. This plugin is small, and most of what it does is refuse things, so a change is
judged less on what it adds than on two questions: does it still block what it is supposed to block,
and has it started blocking anything it should not? Most of this file explains how to answer both.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Security problems — a way to
get a write, a push or a merge past a guard that claims to stop it — go through
[SECURITY.md](SECURITY.md), not a public issue.

## Before you start

- **Bug or false refusal?** Open an issue with the tool payload or shell command that was
  mishandled, what the hook did, and what it should have done. The templates ask for exactly that.
- **New guard or new configuration key?** Open an issue first. Every guard costs every installing
  repository some friction, and a proposal is cheaper to turn down than a pull request.
- **Small fixes** — a typo, a missing test, a clearer message — can go straight to a pull request.

## Setup

You need `bash`, `git` (2.28 or later, for `git init -b`) and `jq`. Nothing else: no package manager
and no build step.

```bash
git clone https://github.com/ndk98z/z-harness
cd z-harness
bash tests/test-hooks.sh        # must end with "hooks: N passed" and nothing FAILED
```

To try a change in a real session, install from your checkout:

```
/plugin marketplace add /absolute/path/to/z-harness
/plugin install z-harness@z-harness
```

and work in a scratch repository with a `.claude/harness.json` (see the README).

## The rules a change has to keep

**The plugin ships mechanisms, never a project's rules.** No path, branch name, command or product
name from any particular repository goes into `hooks/`. If a hook needs to know something about the
repository it is installed in, that is a key in `.claude/harness.json`, read at run time, with a
default that does the least surprising thing. A plugin that ships one project's rules is one
project's harness wearing a plugin's name.

**An empty or missing configuration matches nothing.** An empty regular expression handed to `grep`
matches every line, so a missing config that silently becomes "gate everything" is the classic way
for a guard here to get uninstalled. Every caller treats an empty pattern as "matches nothing".

**Decide on purpose whether a hook fails open or closed.** A hook guarding correctness (content
rules, the push guard) refuses what it cannot read. A hook guarding a process step (the plan gate)
allows when the payload is unreadable. Say which one you chose in a comment, and why.

**Exit codes.** `0` allows, `2` blocks and feeds stderr back to the model. Nothing else. A refusal
message says what was refused, why, and what to do instead, because the model reading it has nothing
else to go on.

**Log every decision.** Call `hook_log` (from `hooks/lib-hook-log.sh`) for allows as well as blocks.
Without the allows there is no denominator, and a false-refusal rate cannot be worked out. Log paths
and reason codes only, never file contents.

**Portable bash.** Hooks run under macOS's `/bin/bash` 3.2 as well as current bash on Linux:

- no associative arrays, `mapfile`/`readarray`, `${var,,}` or `${var^^}`;
- expand arrays that may be empty as `${a[@]+"${a[@]}"}`, since bash 3.2 errors on an empty array
  under `set -u`;
- start every hook with `set -uo pipefail`, and match large text with a here-string
  (`grep -q … <<< "$text"`) rather than `printf | grep -q` — under `pipefail` that pipe reports a
  match as no match once the text passes 64 KiB;
- watch for BSD and GNU differences (`sed -i`, `stat`, `date`, `mktemp`).

**Execute bits.** A hook wired into `plugin.json` without the execute bit fails silently, and a
silent failure looks exactly like an allow. The suite checks this, so `chmod +x` any new hook.

**Comments.** Every function gets a comment above it saying what it does, followed by its arguments
as `# $1 …` lines. Where the reason for a line is a bug someone already hit, write the bug down next to
the line. Most comments in this repository exist so the next person does not reintroduce something
that has already shipped once.

## Tests

`tests/test-hooks.sh` is the whole suite. Add your cases to the section for the hook you changed, or
start a new numbered section. CI runs the suite on Linux and on macOS under `/bin/bash` 3.2.

Every change to a rule that blocks needs **both halves**:

1. a case proving it blocks what it should, and
2. a case proving it does not block the nearest thing it should allow — the false-refusal case.

The second half costs more to write and is the one that keeps a guard alive. A guard that refuses
`grep -rn 'tee -a' .` refuses the very commands people use to investigate it.

Then **check that the cases would notice if the fix went away.** Revert your fix by hand, make sure
the new cases go red, and put the fix back. A test that passes against the bug is not testing the
fix. Fixtures make this easy to get wrong. Two traps that have already bitten this suite:

- a fixture under `/tmp` is exempt from the write detector, so a case living there can pass without
  the rule ever running;
- a fixture with no `origin/HEAD` makes "default branch" and "checked-out branch" resolve to the
  same name, so a case cannot tell them apart.

Say in the pull request which mutant you ran and what it turned red.

## Commits and pull requests

- **Subject:** one sentence in the imperative, describing the outcome rather than the mechanism. For
  example: "Find the worktree from a subdirectory of it, not take the subdirectory for it". No
  `feat:` or `fix:` prefixes.
- **Body:** what was wrong, how it showed up, why this fix rather than another, and how you verified
  it. The commit message is the record of why the code is the way it is, so write it for someone
  reading `git log` a year from now.
- **One concern per pull request.** If a fix turns up an unrelated bug, that is a second pull request.
- **Version and changelog.** If the change alters behaviour an installed copy would notice, bump
  `version` in `.claude-plugin/plugin.json` (patch for fixes, minor for new keys or hooks; anything
  that changes a default is called out in the changelog) and add an entry under `Unreleased` in
  [CHANGELOG.md](CHANGELOG.md).
- **README.** If you add or change a configuration key, document it in `README.md` in the same pull
  request.

Fill in the pull request template. CI has to be green before review.

## Licence

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE), the
same as the rest of the project.
