#!/bin/bash
set -uo pipefail

# sf-prod.sh — stage 5 (production deploy). HUMAN-TRIGGERED ONLY — never launched
# by the dispatcher (deploy is the highest-blast-radius stage).
#
# Deterministic gate + LLM summary:
#   - runs the repo's .sf.yml `deploy:` command; the label is set from its EXIT
#     CODE (no LLM decides success/failure)
#   - then invokes /sf-prod to write a human-readable deploy report
#   sf:ready-for-prod --(exit 0)--> sf:deployed (issue closed)
#                     --(exit !=0)-> sf:deploy-failed
#
# Usage: bash sf-prod.sh <issue-number>
# Env: SF_REPO, SF_REPO_DIR, SF_WORKTREE_DIR

REPO="${SF_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo kilo9alfa/softwarefactory)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SF_REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LOG_DIR="${HOME}/.local/share/softwarefactory/logs"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y.%m.%d %H:%M:%S')] [prod] $*" | tee -a "$LOG_DIR/dispatcher.log"; }

issue_num="${1:?usage: sf-prod.sh <issue-number>}"

# Guards.
current_labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
if echo "$current_labels" | grep -qx "sf:deployed"; then
    log "Issue #$issue_num: already deployed, nothing to do"; exit 0
fi
if ! echo "$current_labels" | grep -qx "sf:ready-for-prod"; then
    log "Issue #$issue_num: not sf:ready-for-prod — refusing to deploy"; exit 1
fi

# Check out the tested branch and read its deploy command.
wt=$(bash "$SCRIPT_DIR/sf-prep-worktree.sh" "$issue_num" 2>>"$LOG_DIR/dispatcher.log") || {
    log "Issue #$issue_num: could not prepare worktree, aborting"; exit 1; }
deploy_cmd=$(sed -n 's/^deploy:[[:space:]]*//p' "$wt/.sf.yml" 2>/dev/null | head -1)
# Strip surrounding quotes ONLY if the whole value is wrapped in a matching pair
# (never strip a trailing quote that belongs to the command itself).
case "$deploy_cmd" in
    \"*\") deploy_cmd="${deploy_cmd#\"}"; deploy_cmd="${deploy_cmd%\"}" ;;
    \'*\') deploy_cmd="${deploy_cmd#\'}"; deploy_cmd="${deploy_cmd%\'}" ;;
esac
if [ -z "$deploy_cmd" ]; then
    log "Issue #$issue_num: no .sf.yml 'deploy:' command — cannot deploy"
    gh issue comment "$issue_num" --repo "$REPO" --body "🏭 **Deploy skipped** — no \`deploy:\` command in \`.sf.yml\`." 2>/dev/null || true
    exit 1
fi

# Run the deploy (deterministic gate).
prod_log="$LOG_DIR/prod-${issue_num}.log"
log "Issue #$issue_num: deploying via \`$deploy_cmd\` in $wt"
( cd "$wt" && eval "$deploy_cmd" ) >"$prod_log" 2>&1
rc=$?
log "Issue #$issue_num: deploy command exit=$rc"

# LLM summary of the deploy log (advisory only — does not affect the gate).
summary_raw="$LOG_DIR/prod-summary-${issue_num}.log"
( cd "$REPO_DIR" && claude --dangerously-skip-permissions -p "/softwarefactory:sf-prod ${issue_num}" ) >"$summary_raw" 2>&1 || true
summary=$(sed -n '/<!--DEPLOY-SUMMARY-->/,/<!--\/DEPLOY-SUMMARY-->/p' "$summary_raw" | sed '/<!--DEPLOY-SUMMARY-->/d; /<!--\/DEPLOY-SUMMARY-->/d')
[ -z "${summary// /}" ] && summary="_(summary unavailable)_"

log_tail=$(tail -n 40 "$prod_log")

if [ "$rc" -eq 0 ]; then
    gh issue edit "$issue_num" --repo "$REPO" --add-label "sf:deployed"
    gh issue comment "$issue_num" --repo "$REPO" --body "$(printf '🏭🚀 **Shipped** (stage 5) — `%s` exited 0.\n\n%s' "$deploy_cmd" "$summary")" 2>/dev/null || true
    gh issue close "$issue_num" --repo "$REPO" --reason completed 2>/dev/null || true
    bash "$SCRIPT_DIR/sf-notify.sh" "🚀 Shipped #${issue_num} to production — issue closed" "$wt" >/dev/null 2>&1 || true
    log "Issue #$issue_num -> sf:deployed (closed)"
else
    gh issue edit "$issue_num" --repo "$REPO" --add-label "sf:deploy-failed"
    gh issue comment "$issue_num" --repo "$REPO" --body "$(printf '🏭🔴 **Deploy FAILED** (stage 5) — `%s` exited %s.\n\n%s\n\n<details><summary>deploy log</summary>\n\n```\n%s\n```\n</details>' "$deploy_cmd" "$rc" "$summary" "$log_tail")" 2>/dev/null || true
    bash "$SCRIPT_DIR/sf-notify.sh" "🔴 Deploy FAILED for #${issue_num} — see the issue for the log" "$wt" >/dev/null 2>&1 || true
    log "Issue #$issue_num -> sf:deploy-failed"
fi
