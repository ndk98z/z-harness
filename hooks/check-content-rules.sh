#!/usr/bin/env bash
#
# Compares the text a call is about to write against the rules the repository declared, and refuses
# the write when one is broken.
#
# The mechanism generalises even though no rule does. Upstream this file guarded four properties of
# one hosting product — which domain serves user content, what a cache key must contain, what a
# caching header may not say — and none of those mean anything in another repository. What carries
# over is the shape: read the payload, compare the text about to be written against a table, exit 2
# with the reason. The table comes from .claude/harness.json.
#
#   "contentRules": [
#     { "match": "^src/edge/",
#       "forbid": "Cache-Control:[^\"]*immutable",
#       "why": "HTML must never be immutable; a browser cannot purge it." },
#     { "match": "^src/edge/robots\\.ts$",
#       "require": "X-Robots-Tag",
#       "why": "The default subdomain must stay noindex." }
#   ]
#
# `match` is an extended regular expression over the repository-relative path. A rule may carry
# `forbid`, `require`, or both.
#
# `forbid` refuses when the text being written matches it. `require` refuses when the text being
# *replaced* matched it and the replacement does not — that is, it catches removal rather than
# absence. The distinction is the whole reason this hook re-reads `old_string`: every check upstream
# asked "what does the new text say", and deleting a line produces no new text at all, so the one
# edit shape that removes a guarantee was the one shape no rule could see.
#
# Shell commands that write a ruled path are refused rather than inspected. This hook cannot read
# what a redirect will produce, and a check that cannot check must not pretend it did — upstream, a
# heredoc walked straight past the rule that had just refused the identical change as an Edit.
#
# Escape hatch, declared: writing .claude/state/mutation-<session>.md with at least one line of
# reason lets this session's writes through for thirty minutes, logged separately. It exists because
# the rule and the test proving the rule is alive point at each other — deliberately breaking a rule
# is how you find out the test still catches it, and without a door that is the one thing the rule
# makes impossible.
#
# Exit 0 to allow, 2 to refuse.

set -uo pipefail

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-bash-writes.sh"
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-hook-log.sh"
# shellcheck source=/dev/null
source "$HOOK_DIR/lib-sensitive-paths.sh"

INPUT=$(cat)
[[ -n "$INPUT" ]] || exit 0

# The raw payload, not the tool name: this helper matches on the payload text so it can answer
# before any subprocess parses it. Handing it the name instead matches nothing and every read walks
# on into the rule loop.
bash_write_is_read_only_tool "$INPUT" && exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // empty' 2>/dev/null)

SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "-"' 2>/dev/null)
SESSION=$(printf '%s' "$SESSION" | tr -c 'a-zA-Z0-9_-' '_')

ROOT="${CLAUDE_PROJECT_DIR:-}"
if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
  ROOT=$(git rev-parse --git-common-dir 2>/dev/null || true)
  [[ "$ROOT" = /* ]] || ROOT="$PWD/${ROOT#./}"
  ROOT="${ROOT%/.git}"
fi
[[ -n "$ROOT" && -d "$ROOT" ]] || ROOT="$PWD"

CONFIG=$(harness_config_path "$ROOT")
[[ -f "$CONFIG" ]] || exit 0
RULE_COUNT=$(jq -r '(.contentRules // []) | length' "$CONFIG" 2>/dev/null)
[[ "${RULE_COUNT:-0}" -gt 0 ]] || exit 0

# The declared escape hatch. Its own reason code rather than `allow`, so the log can answer how often
# rules were suspended without that count hiding inside the ordinary allows.
MUTATION_FILE="$ROOT/.claude/state/mutation-$SESSION.md"
if [[ -s "$MUTATION_FILE" ]]; then
  if find "$MUTATION_FILE" -mmin -30 2>/dev/null | grep -q .; then
    hook_log check-content-rules "$SESSION" "${TOOL:--}" allow "declared" mutation-declared
    exit 0
  fi
fi

# Every path this call would write, one per line, and for a shell command that is all this hook can
# know: the paths, never the bytes.
IS_SHELL=0
case "$TOOL" in
  Bash)
    IS_SHELL=1
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [[ -n "$COMMAND" ]] || exit 0
    TARGETS=$(bash_write_targets "$COMMAND" "$ROOT")
    ;;
  *)
    TARGETS=$(printf '%s' "$INPUT" |
      jq -r '.tool_input | (.file_path // .path // .notebook_path // empty)' 2>/dev/null)
    ;;
esac
[[ -n "$TARGETS" ]] || exit 0

# The text this call would write, and the text it would replace, each flattened to one blob. Both
# halves are read because a rule can be broken by what appears and by what disappears.
NEW_TEXT=$(printf '%s' "$INPUT" | jq -r '
  .tool_input // {} |
  [ .content?, .new_string?, .new_source?, (.edits // [])[]?.new_string? ]
  | map(select(type == "string")) | join("\n")' 2>/dev/null)
OLD_TEXT=$(printf '%s' "$INPUT" | jq -r '
  .tool_input // {} |
  [ .old_string?, .old_source?, (.edits // [])[]?.old_string? ]
  | map(select(type == "string")) | join("\n")' 2>/dev/null)

VIOLATIONS=""
REFUSED_SHELL=""

while IFS= read -r target; do
  [[ -n "$target" ]] || continue
  [[ "$target" = /* ]] || target="$PWD/$target"
  rel=$(sensitive_relpath "$target" "$ROOT")

  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    pattern=$(printf '%s' "$rule" | jq -r '.match // empty')
    [[ -n "$pattern" ]] || continue
    printf '%s' "$rel" | grep -qE "$pattern" || continue

    why=$(printf '%s' "$rule" | jq -r '.why // "This repository forbids it."')

    # A shell command reaching a ruled path is refused on the strength of the path alone. The bytes
    # are unreadable here, and a rule that cannot be evaluated must not report that it passed.
    if [[ "$IS_SHELL" -eq 1 ]]; then
      REFUSED_SHELL+="  $rel
"
      continue
    fi

    forbid=$(printf '%s' "$rule" | jq -r '.forbid // empty')
    if [[ -n "$forbid" && -n "$NEW_TEXT" ]] && printf '%s' "$NEW_TEXT" | grep -qE "$forbid"; then
      VIOLATIONS+="  $rel — writes text matching /$forbid/
    $why
"
    fi

    # Removal, not absence. Asking whether the new text contains the required pattern would refuse
    # every edit to every other part of the file; asking whether the edit takes it away is the
    # question that has an answer here, and it is the one that covers a deletion — an Edit whose
    # replacement is empty, which no rule phrased as "what does the new text say" can see at all.
    require=$(printf '%s' "$rule" | jq -r '.require // empty')
    if [[ -n "$require" && -n "$OLD_TEXT" ]] \
      && printf '%s' "$OLD_TEXT" | grep -qE "$require" \
      && ! printf '%s' "$NEW_TEXT" | grep -qE "$require"; then
      VIOLATIONS+="  $rel — removes text matching /$require/
    $why
"
    fi
  done < <(jq -c '(.contentRules // [])[]' "$CONFIG" 2>/dev/null)
done <<< "$TARGETS"

if [[ -n "$REFUSED_SHELL" ]]; then
  hook_log check-content-rules "$SESSION" "${TOOL:--}" block \
    "$(printf '%s' "$REFUSED_SHELL" | head -1 | sed 's/^ *//')" shell-unreadable
  cat >&2 <<EOF
This shell command writes to a path this repository has content rules for:
$REFUSED_SHELL
The rules are checked against the text being written, and a shell redirect does not carry that text
where this hook can read it. Refusing is the honest answer: a check that cannot run must not report
that it passed.

Use the Edit or Write tool for these paths instead.
EOF
  exit 2
fi

if [[ -n "$VIOLATIONS" ]]; then
  hook_log check-content-rules "$SESSION" "${TOOL:--}" block \
    "$(printf '%s' "$VIOLATIONS" | head -1 | sed 's/^ *//' | cut -d' ' -f1)" content-rule
  cat >&2 <<EOF
This call breaks a content rule declared in .claude/harness.json:

$VIOLATIONS
These rules are the repository's, not the plugin's. If one is wrong, say so to the user and let them
change the rule — do not reach the same result by another route.
EOF
  exit 2
fi

exit 0
