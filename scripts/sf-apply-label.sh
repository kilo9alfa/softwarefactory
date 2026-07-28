#!/bin/bash
set -euo pipefail

# sf-apply-label.sh — trusted state-transition step of the Software Factory pipeline.
#
# The /sf-triage skill only *classifies* (untrusted output). This script is the
# trusted component that validates that output and advances the GitHub label
# state machine: feedback/triage -> feedback/bug | feedback/feature | sf:spam.
#
# Usage: sf-apply-label.sh <issue-number> <triage-log-file>
#   The log file is the captured stdout of `claude -p /sf-triage <n>`, which
#   contains the classification JSON (optionally inside a ```json fence).

REPO="${SF_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo kilo9alfa/softwarefactory)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${HOME}/.local/share/softwarefactory/logs"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y.%m.%d %H:%M:%S')] [apply-label] $*" | tee -a "$LOG_DIR/dispatcher.log"
}

issue_num="${1:?usage: sf-apply-label.sh <issue-number> <triage-log-file>}"
triage_log="${2:?usage: sf-apply-label.sh <issue-number> <triage-log-file>}"

if [ ! -f "$triage_log" ]; then
    log "Issue #$issue_num: triage log '$triage_log' not found, aborting"
    exit 1
fi

# Idempotency guard: only act on issues still awaiting triage. If the triage
# label is already gone, this issue was processed on a prior run — skip quietly
# so re-invocation never double-comments or re-transitions.
current_labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
if ! echo "$current_labels" | grep -qx "feedback/triage"; then
    log "Issue #$issue_num: no feedback/triage label present, already processed — skipping"
    exit 0
fi

# Extract the JSON object from the log. Prefer a ```json fenced block; fall back
# to the first {...} object in the file. Never eval or execute the content.
json=$(sed -n '/```json/,/```/p' "$triage_log" | sed '/```/d')
if [ -z "$json" ]; then
    # Fallback: grab from the first '{' to the last '}' in the log.
    json=$(sed -n '/{/,/}/p' "$triage_log")
fi

if [ -z "$json" ]; then
    log "Issue #$issue_num: no JSON found in triage output, leaving in feedback/triage"
    exit 1
fi

# Parse with jq. -e makes jq fail if the field is missing/null.
classification=$(echo "$json" | jq -re '.classification' 2>/dev/null || echo "")
new_title=$(echo "$json" | jq -r '.title // empty' 2>/dev/null || echo "")
rationale=$(echo "$json" | jq -r '.rationale // empty' 2>/dev/null || echo "")
duplicate_of=$(echo "$json" | jq -r '.duplicate_of // empty' 2>/dev/null || echo "")

# Validate: only these values are allowed to drive a state transition. Anything
# else (including a prompt-injected label) is rejected — the issue stays in triage.
case "$classification" in
    bug)     result_label="feedback/bug" ;;
    feature) result_label="feedback/feature" ;;
    spam)    result_label="sf:spam" ;;
    *)
        log "Issue #$issue_num: classification '$classification' not actionable, leaving in feedback/triage"
        exit 1
        ;;
esac

log "Issue #$issue_num classified as '$classification' -> applying $result_label"

# Advance the state machine: drop triage, add the result label.
gh issue edit "$issue_num" --repo "$REPO" \
    --remove-label "feedback/triage" \
    --add-label "$result_label"

# Rewrite the title if the skill produced a clearer one.
if [ -n "$new_title" ]; then
    current_title=$(gh issue view "$issue_num" --repo "$REPO" --json title --jq '.title' 2>/dev/null || echo "")
    if [ "$new_title" != "$current_title" ]; then
        gh issue edit "$issue_num" --repo "$REPO" --title "$new_title"
        log "Issue #$issue_num: title updated to '$new_title'"
    fi
fi

# Record the decision as a comment for traceability. rationale/duplicate come
# from the classifier and are quoted as data, never interpreted.
comment_body="🏭 **Triaged:** \`${classification}\`"
[ -n "$rationale" ] && comment_body="${comment_body}"$'\n\n'"> ${rationale}"
[ -n "$duplicate_of" ] && comment_body="${comment_body}"$'\n\n'"Possible duplicate of #${duplicate_of}."
gh issue comment "$issue_num" --repo "$REPO" --body "$comment_body" 2>/dev/null || true

# Spam is a terminal state — close it.
if [ "$classification" = "spam" ]; then
    gh issue close "$issue_num" --repo "$REPO" --reason "not planned" 2>/dev/null || true
    log "Issue #$issue_num closed as spam"
fi

bash "$SCRIPT_DIR/sf-notify.sh" "📝 #${issue_num} triaged as \`${classification}\`: ${new_title:-$(gh issue view "$issue_num" --repo "$REPO" --json title -q .title 2>/dev/null)}" >/dev/null 2>&1 || true

log "Issue #$issue_num state transition complete"
