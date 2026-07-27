#!/bin/bash
set -euo pipefail

# sf-approve-plan.sh — the human approval action for stage 3a.
#
# This is the ONE gate a human must drive. It advances a reviewed plan past the
# gate so stage 3b (dev) can begin:
#   sf:plan-review  --(add)-->  sf:plan-approved
#
# Run this only after reading the plan comment on the issue and agreeing with it.
#
# Usage: sf-approve-plan.sh <issue-number>

REPO="${SF_REPO:-kilo9alfa/softwarefactory}"
LOG_DIR="${HOME}/.local/share/softwarefactory/logs"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y.%m.%d %H:%M:%S')] [approve-plan] $*" | tee -a "$LOG_DIR/dispatcher.log"
}

issue_num="${1:?usage: sf-approve-plan.sh <issue-number>}"

current_labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
if echo "$current_labels" | grep -qx "sf:plan-approved"; then
    log "Issue #$issue_num: already approved, nothing to do"
    exit 0
fi
if ! echo "$current_labels" | grep -qx "sf:plan-review"; then
    log "Issue #$issue_num: not at the plan-review gate (no sf:plan-review label), refusing"
    exit 1
fi

gh issue edit "$issue_num" --repo "$REPO" --add-label "sf:plan-approved"
gh issue comment "$issue_num" --repo "$REPO" --body "🏭 **Plan approved** by a human — ready for stage 3b (dev)." 2>/dev/null || true
log "Issue #$issue_num approved (sf:plan-approved) — dev may begin"
