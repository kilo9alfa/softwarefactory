#!/bin/bash
set -euo pipefail

# Software Factory Dispatcher
# Polls GitHub for feedback/triage issues and spawns autonomous triage agents
# Runs in tmux on Nuclaw via systemd timer

REPO="kilo9alfa/softwarefactory"
TMUX_PREFIX="sf-triage"
LOG_DIR="${HOME}/.local/share/softwarefactory/logs"
RETRY_MAX=3
SESSION_TIMEOUT=600  # 10 minutes

# Create log directory
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y.%m.%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/dispatcher.log"
}

# Check if tmux session exists
session_exists() {
    local session_name="$1"
    tmux has-session -t "$session_name" 2>/dev/null || return 1
}

# Check if issue already has a result label (not feedback/triage anymore)
has_result_label() {
    local issue_num="$1"
    local labels
    labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")

    # If it has any of these labels, skip processing
    if echo "$labels" | grep -qE "^feedback/(bug|feature)$|^sf:spam$"; then
        return 0  # has result
    fi
    return 1  # no result yet
}

# Check retry count from issue comments
get_retry_count() {
    local issue_num="$1"
    gh issue view "$issue_num" --repo "$REPO" --json comments --jq '.comments | length' 2>/dev/null || echo "0"
}

# Spawn triage agent in tmux
spawn_agent() {
    local issue_num="$1"
    local session_name="${TMUX_PREFIX}-${issue_num}"
    local log_file="$LOG_DIR/triage-${issue_num}.log"

    # Check if session already exists (idempotency)
    if session_exists "$session_name"; then
        log "Session $session_name already running, skipping"
        return 0
    fi

    # Check if already processed
    if has_result_label "$issue_num"; then
        log "Issue #$issue_num already classified, skipping"
        return 0
    fi

    # Check retry count
    local retries
    retries=$(get_retry_count "$issue_num")
    if (( retries >= RETRY_MAX )); then
        log "Issue #$issue_num exceeded retry limit ($RETRY_MAX), marking as unclear"
        gh issue comment "$issue_num" --repo "$REPO" --body "⚠️ Triage agent couldn't classify this issue after $RETRY_MAX attempts. Please add more details." 2>/dev/null || true
        return 1
    fi

    # Create tmux session and run triage agent
    log "Spawning triage agent for issue #$issue_num in session $session_name"

    tmux new-session -d -s "$session_name" -x 200 -y 50 \
        "cd ${HOME}/code/softwarefactory && \
         claude --dangerously-skip-permissions -p /sf-triage $issue_num 2>&1 | tee $log_file; \
         tmux kill-session -t $session_name"

    # Set session timeout (kill after N seconds if still running)
    (
        sleep "$SESSION_TIMEOUT"
        if session_exists "$session_name"; then
            log "Session $session_name timeout after $SESSION_TIMEOUT seconds, killing"
            tmux kill-session -t "$session_name" 2>/dev/null || true
        fi
    ) &

    return 0
}

# Main loop
main() {
    log "Software Factory Dispatcher started (PID $$)"

    # Fetch all feedback/triage issues
    local issues
    issues=$(gh issue list --repo "$REPO" --label "feedback/triage" --json number --jq '.[].number' 2>/dev/null || echo "")

    if [ -z "$issues" ]; then
        log "No feedback/triage issues found"
        return 0
    fi

    log "Found $(echo "$issues" | wc -l) feedback/triage issue(s): $issues"

    # Process each issue
    while IFS= read -r issue_num; do
        [ -z "$issue_num" ] && continue
        spawn_agent "$issue_num" || log "Failed to spawn agent for issue #$issue_num"
    done <<< "$issues"

    log "Dispatcher cycle complete"
}

# Run main
main "$@"
