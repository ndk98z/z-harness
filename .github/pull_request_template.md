## What and why

<!-- What was wrong or missing, how it showed up, and why this fix rather than another. -->

## Verification

- [ ] `bash tests/test-hooks.sh` passes locally
- [ ] Every rule that blocks has a case for what it blocks **and** a false-refusal case for the nearest thing it must allow
- [ ] I reverted the fix by hand and the new cases went red (which mutant, and how many cases failed):

## Checklist

- [ ] No path, branch, command or product name from a particular repository in `hooks/`; anything repository-specific is a `.claude/harness.json` key with a safe default
- [ ] Portable to macOS `/bin/bash` 3.2 (no associative arrays, `mapfile`, `${x,,}`; empty arrays expanded as `${a[@]+"${a[@]}"}`)
- [ ] New hook files are executable and wired into `.claude-plugin/plugin.json`
- [ ] Behaviour change: `version` bumped in `.claude-plugin/plugin.json` and an entry added to `CHANGELOG.md`
- [ ] New or changed configuration key documented in `README.md`
