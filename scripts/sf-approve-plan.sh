#!/bin/bash
set -euo pipefail

# sf-approve-plan.sh — the human approval action for stage 3a.
#
# This is the ONE gate a human must drive. It advances a reviewed plan past the
# gate so stage 3b (dev) can begin:
#   sf:3-plan-review  --(add)-->  sf:3-plan-approved
#
# Run this only after reading the plan comment on the issue and agreeing with it.
#
# Usage: sf-approve-plan.sh <issue-number>

REPO="${SF_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
: "${REPO:?SF_REPO unset and gh cannot resolve the repo -- run inside the repo, set SF_REPO, or export GH_TOKEN}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${HOME}/.local/share/softwarefactory/logs"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y.%m.%d %H:%M:%S')] [approve-plan] $*" | tee -a "$LOG_DIR/dispatcher.log"
}

issue_num="${1:?usage: sf-approve-plan.sh <issue-number>}"

current_labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
if echo "$current_labels" | grep -qx "sf:3-plan-approved"; then
    log "Issue #$issue_num: already approved, nothing to do"
    exit 0
fi
if ! echo "$current_labels" | grep -qx "sf:3-plan-review"; then
    log "Issue #$issue_num: not at the plan-review gate (no sf:3-plan-review label), refusing"
    exit 1
fi

gh issue edit "$issue_num" --repo "$REPO" --add-label "sf:3-plan-approved"
gh issue comment "$issue_num" --repo "$REPO" --body "🏭 **Plan approved** by a human — ready for stage 3b (dev)." 2>/dev/null || true
bash "$SCRIPT_DIR/sf-notify.sh" "✅ Plan approved on #${issue_num} — dev will start" >/dev/null 2>&1 || true
log "Issue #$issue_num approved (sf:3-plan-approved) — dev may begin"
