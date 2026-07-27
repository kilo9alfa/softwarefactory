#!/bin/bash
set -euo pipefail

# sf-apply-dev.sh — trusted state-transition step for stage 3b (dev).
#
# The /sf-dev skill only writes code + commits LOCALLY in an isolated worktree.
# This script does the outward-facing mutations: push the branch, open a DRAFT
# PR, and advance the label state machine:
#   sf:plan-approved  --(add)-->  sf:implemented
# The PR (draft, human-reviewed before merge) is the code-review gate.
#
# Usage: sf-apply-dev.sh <issue-number> <worktree-path> <dev-log-file>

REPO="${SF_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo kilo9alfa/softwarefactory)}"
LOG_DIR="${HOME}/.local/share/softwarefactory/logs"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y.%m.%d %H:%M:%S')] [apply-dev] $*" | tee -a "$LOG_DIR/dispatcher.log"
}

issue_num="${1:?usage: sf-apply-dev.sh <issue-number> <worktree-path> <dev-log-file>}"
wt="${2:?usage: sf-apply-dev.sh <issue-number> <worktree-path> <dev-log-file>}"
dev_log="${3:?usage: sf-apply-dev.sh <issue-number> <worktree-path> <dev-log-file>}"

[ -d "$wt" ]       || { log "Issue #$issue_num: worktree '$wt' missing, aborting"; exit 1; }
[ -f "$dev_log" ]  || { log "Issue #$issue_num: dev log '$dev_log' missing, aborting"; exit 1; }

# Idempotency + stage guards.
current_labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
if echo "$current_labels" | grep -qx "sf:implemented"; then
    log "Issue #$issue_num: sf:implemented already present, skipping"
    exit 0
fi
if ! echo "$current_labels" | grep -qx "sf:plan-approved"; then
    log "Issue #$issue_num: no sf:plan-approved label — not ready for dev, skipping"
    exit 1
fi

branch="sf/impl-${issue_num}"
default_branch=$(gh repo view --repo "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)

# Validate the skill actually committed something ahead of the base.
git -C "$wt" fetch --quiet origin "$default_branch" || true
ahead=$(git -C "$wt" rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null || echo 0)
if [ "$ahead" -eq 0 ]; then
    log "Issue #$issue_num: worktree has 0 commits ahead of $default_branch — nothing to PR, leaving stage unchanged"
    exit 1
fi
log "Issue #$issue_num: $ahead commit(s) on $branch -> pushing + opening draft PR"

# Push the branch (idempotent; -u sets upstream).
git -C "$wt" push -u origin "$branch" >&2

# Extract the <!--DEV--> summary for the PR body (data only, never executed).
summary=$(sed -n '/<!--DEV-->/,/<!--\/DEV-->/p' "$dev_log" | sed '/<!--DEV-->/d; /<!--\/DEV-->/d')
[ -z "${summary// /}" ] && summary="_(no summary emitted)_"

issue_title=$(gh issue view "$issue_num" --repo "$REPO" --json title -q .title 2>/dev/null || echo "issue #$issue_num")
pr_body="🏭 Autonomous implementation (stage 3b) — Refs #${issue_num}. Plan was human-approved (\`sf:plan-approved\`). **Draft: review before merging.**"$'\n\n'"${summary}"

# Open a draft PR, or reuse an existing one for this branch (retry-safe).
if pr_url=$(gh pr create --repo "$REPO" --head "$branch" --base "$default_branch" \
        --draft --title "$issue_title" --body "$pr_body" 2>/dev/null); then
    log "Issue #$issue_num: draft PR opened $pr_url"
else
    pr_url=$(gh pr list --repo "$REPO" --head "$branch" --json url -q '.[0].url' 2>/dev/null || echo "")
    log "Issue #$issue_num: reusing existing PR ${pr_url:-<none>}"
fi

# Advance the state machine + link the PR on the issue.
gh issue edit "$issue_num" --repo "$REPO" --add-label "sf:implemented"
[ -n "$pr_url" ] && gh issue comment "$issue_num" --repo "$REPO" \
    --body "🏭 **Implemented** (stage 3b) — draft PR: ${pr_url}. Review before merge." 2>/dev/null || true

log "Issue #$issue_num state transition complete (sf:implemented)"
