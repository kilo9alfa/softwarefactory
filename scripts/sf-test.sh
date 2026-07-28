#!/bin/bash
set -uo pipefail

# sf-test.sh — trusted stage 4 (testing). DETERMINISTIC gate: it runs the repo's
# real test command (from .sf.yml) against the issue's branch and sets the label
# purely from the command's EXIT CODE — no LLM decides pass/fail.
#   sf:implemented --(exit 0)--> sf:ready-for-prod
#                  --(exit !=0)-> sf:needs-debug   (+ failing output posted)
#
# Usage: sf-test.sh <issue-number>
# Env: SF_REPO, SF_REPO_DIR, SF_WORKTREE_DIR (see sf-prep-worktree.sh)

REPO="${SF_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo kilo9alfa/softwarefactory)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${HOME}/.local/share/softwarefactory/logs"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y.%m.%d %H:%M:%S')] [test] $*" | tee -a "$LOG_DIR/dispatcher.log"; }

issue_num="${1:?usage: sf-test.sh <issue-number>}"

# Idempotency + stage guards.
current_labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
if echo "$current_labels" | grep -qE "^sf:ready-for-prod$|^sf:needs-debug$"; then
    log "Issue #$issue_num: already tested, skipping"; exit 0
fi
if ! echo "$current_labels" | grep -qx "sf:implemented"; then
    log "Issue #$issue_num: no sf:implemented label — not ready for test, skipping"; exit 1
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
    log "Issue #$issue_num: no .sf.yml 'test:' command — cannot gate, leaving sf:implemented"
    gh issue comment "$issue_num" --repo "$REPO" --body "🏭 **Test skipped** — no \`test:\` command in \`.sf.yml\`. Add one to enable stage 4 gating." 2>/dev/null || true
    exit 1
fi

log "Issue #$issue_num: running \`$test_cmd\` in $wt"
out=$(mktemp)
( cd "$wt" && eval "$test_cmd" ) >"$out" 2>&1
rc=$?
tail_out=$(tail -n 60 "$out")
log "Issue #$issue_num: test command exit=$rc"

if [ "$rc" -eq 0 ]; then
    gh issue edit "$issue_num" --repo "$REPO" --add-label "sf:ready-for-prod"
    gh issue comment "$issue_num" --repo "$REPO" --body "$(printf '🏭 **Tests pass** (stage 4) — `%s` exited 0. Ready for production.\n\n<details><summary>output</summary>\n\n```\n%s\n```\n</details>' "$test_cmd" "$tail_out")" 2>/dev/null || true
    bash "$SCRIPT_DIR/sf-notify.sh" "✅ Tests pass on #${issue_num} — ready for production" "$wt" >/dev/null 2>&1 || true
    log "Issue #$issue_num -> sf:ready-for-prod"
else
    gh issue edit "$issue_num" --repo "$REPO" --add-label "sf:needs-debug"
    gh issue comment "$issue_num" --repo "$REPO" --body "$(printf '🏭 **Tests FAILED** (stage 4) — `%s` exited %s. Needs debugging.\n\n```\n%s\n```' "$test_cmd" "$rc" "$tail_out")" 2>/dev/null || true
    bash "$SCRIPT_DIR/sf-notify.sh" "❌ Tests FAILED on #${issue_num} — needs debugging" "$wt" >/dev/null 2>&1 || true
    log "Issue #$issue_num -> sf:needs-debug"
fi
rm -f "$out"
