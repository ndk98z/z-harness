# Security policy

## What counts as a vulnerability here

z-harness guards against accident, not intent: it reads tool payloads and shell text with patterns,
and it says so wherever it can. `sh -c "cat > x"`, a script file that writes, or `gh api` writing a
ref directly all get past it, and that is documented behaviour rather than a vulnerability.

Report as a vulnerability:

- a hook that **reports a check as passed when it did not run**. For example, a payload shape that
  makes a content rule, the plan gate or the review receipt match nothing while it looks like a clean
  allow;
- a way for the Stop hook or `merge-worktree.sh` to **advance, overwrite or delete work** it should
  not: merging into the publish branch without the opt-in, removing the worktree a session stands in,
  or discarding uncommitted changes;
- `guard-push.sh` **allowing a push to a protected branch** through a spelling it claims to read
  (refspecs, aliases, `push.default`, `remote.<name>.push`, `cd`, `sh -c`, `eval`);
- a hook that **runs or evaluates** text from a tool payload or from a file in the repository it is
  installed in, beyond the `gates` commands a repository declares in `.claude/harness.json`;
- a hook log entry that **contains file contents** rather than paths and reason codes.

Not in scope: anything that needs the attacker to already control `.claude/harness.json` or the hook
files, since both are trusted configuration by design.

## Reporting

Please do not open a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/ndk98z/z-harness/security/advisories/new), or
email **ndk98z.tech@gmail.com** with `z-harness security` in the subject.

Include the hook, the payload or command that triggers it, what happened, and what you expected. A
failing case for `tests/test-hooks.sh` is the most useful form of all.

You should hear back within a week. Fixes go out as a new plugin version, with the reporter credited
in the changelog unless you would rather not be.

## Supported versions

Only the latest released version gets fixes. To update:

```bash
claude plugin marketplace update z-harness
claude plugin update z-harness@z-harness
```
