#!/bin/bash
set -uo pipefail

# sf-test.sh — trusted stage 4 (testing). DETERMINISTIC gate: it runs the repo's
# real test command (from .sf.yml) against the issue's branch and sets the label
# purely from the command's EXIT CODE — no LLM decides pass/fail.
#   sf:4-implemented --(exit 0)--> sf:5-ready-for-prod
#                  --(exit !=0)-> sf:5-needs-debug   (+ failing output posted)
#
# Usage: sf-test.sh <issue-number>
# Env: SF_REPO, SF_REPO_DIR, SF_WORKTREE_DIR (see sf-prep-worktree.sh)

REPO="${SF_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
: "${REPO:?SF_REPO unset and gh cannot resolve the repo -- run inside the repo, set SF_REPO, or export GH_TOKEN}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${HOME}/.local/share/softwarefactory/logs"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y.%m.%d %H:%M:%S')] [test] $*" | tee -a "$LOG_DIR/dispatcher.log"; }

issue_num="${1:?usage: sf-test.sh <issue-number>}"

# Idempotency + stage guards.
current_labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
if echo "$current_labels" | grep -qE "^sf:5-ready-for-prod$|^sf:5-needs-debug$|^sf:5-test-skipped$"; then
    log "Issue #$issue_num: already tested, skipping"; exit 0
fi
if ! echo "$current_labels" | grep -qx "sf:4-implemented"; then
    log "Issue #$issue_num: no sf:4-implemented label — not ready for test, skipping"; exit 1
fi

# Check out the issue's branch in a worktree (reuses the dev worktree if present).
wt=$(bash "$SCRIPT_DIR/sf-prep-worktree.sh" "$issue_num" 2>>"$LOG_DIR/dispatcher.log") || {
    log "Issue #$issue_num: could not prepare worktree, aborting"; exit 1; }

# Read the test command from the branch's .sf.yml.
test_cmd=$(sed -n 's/^test:[[:space:]]*//p' "$wt/.sf.yml" 2>/dev/null | head -1)
# Strip surrounding quotes ONLY if the whole value is a matching quoted pair.
case "$test_cmd" in
    \"*\") test_cmd="${test_cmd#\"}"; test_cmd="${test_cmd%\"}" ;;
    \'*\') test_cmd="${test_cmd#\'}"; test_cmd="${test_cmd%\'}" ;;
esac

if [ -z "$test_cmd" ]; then
    # TERMINAL, not a retry. This used to leave sf:4-implemented in place and exit
    # 1, which made the issue a test candidate again on the next 5-min cycle: the
    # dispatcher respawned it, burned the 3-attempt cap and fired a 🛑 "needs a
    # human" alert — for a repo-config gap that no amount of retrying can fix.
    # sf:5-test-skipped stops the loop and says exactly what is missing. The issue
    # holds at stage 4 on purpose: a human adds the test: command (then removes
    # the label to re-run) or ships it deliberately with sf:5-ready-for-prod.
    log "Issue #$issue_num: no .sf.yml 'test:' command — cannot gate -> sf:5-test-skipped"
    gh issue edit "$issue_num" --repo "$REPO" --add-label "sf:5-test-skipped" 2>/dev/null || true
    gh issue comment "$issue_num" --repo "$REPO" --body "🏭 **Test skipped** — no \`test:\` command in \`.sf.yml\`, so stage 4 cannot gate this. Held at \`sf:5-test-skipped\`. Add a \`test:\` command and remove the label to re-run, or add \`sf:5-ready-for-prod\` to ship it ungated." 2>/dev/null || true
    bash "$SCRIPT_DIR/sf-notify.sh" "⚠️ #${issue_num} held at stage 4 — the repo's .sf.yml has no \`test:\` command, so nothing can gate it. Not a code failure." "$wt" >/dev/null 2>&1 || true
    exit 1
fi

log "Issue #$issue_num: running \`$test_cmd\` in $wt"
out=$(mktemp)
# SF_ISSUE: the hook runs in a CHILD process, so a repo whose test: command
# routes per-issue (e.g. by an issue label) has no other way to learn which
# issue it is. Exported here so it never has to infer it from the branch name.
( cd "$wt" && export SF_ISSUE="$issue_num" && eval "$test_cmd" ) >"$out" 2>&1
rc=$?
tail_out=$(tail -n 60 "$out")
log "Issue #$issue_num: test command exit=$rc"

if [ "$rc" -eq 0 ]; then
    gh issue edit "$issue_num" --repo "$REPO" --add-label "sf:5-ready-for-prod"
    gh issue comment "$issue_num" --repo "$REPO" --body "$(printf '🏭 **Tests pass** (stage 4) — `%s` exited 0. Ready for production.\n\n<details><summary>output</summary>\n\n```\n%s\n```\n</details>' "$test_cmd" "$tail_out")" 2>/dev/null || true
    bash "$SCRIPT_DIR/sf-notify.sh" "✅ Tests pass on #${issue_num} — ready for production" "$wt" >/dev/null 2>&1 || true
    log "Issue #$issue_num -> sf:5-ready-for-prod"
else
    gh issue edit "$issue_num" --repo "$REPO" --add-label "sf:5-needs-debug"
    gh issue comment "$issue_num" --repo "$REPO" --body "$(printf '🏭 **Tests FAILED** (stage 4) — `%s` exited %s. Needs debugging.\n\n```\n%s\n```' "$test_cmd" "$rc" "$tail_out")" 2>/dev/null || true
    bash "$SCRIPT_DIR/sf-notify.sh" "❌ Tests FAILED on #${issue_num} — needs debugging" "$wt" >/dev/null 2>&1 || true
    log "Issue #$issue_num -> sf:5-needs-debug"
fi
rm -f "$out"
