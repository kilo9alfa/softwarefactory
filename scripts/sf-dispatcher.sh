#!/bin/bash
set -euo pipefail

# Software Factory Dispatcher (multi-stage)
# Polls GitHub and spawns the right autonomous agent per pipeline stage.
# Runs in tmux on Nuclaw via systemd timer.
#
# Each stage is: trigger label(s) -> skill (claude -p, advisory) -> apply script
# (trusted, does the label transition). The apply scripts also guard themselves,
# so a dispatcher race can never drive a wrong-stage transition.
#
# Stage table (processed in order each cycle):
#   triage : feedback/triage                 -> sf-triage    -> sf-apply-label.sh   (done: feedback/bug|feature|sf:spam)
#   spec   : feedback/bug | feedback/feature -> sf-tospecs   -> sf-apply-spec.sh    (done: sf:spec)
#   tickets: sf:spec                         -> sf-totickets -> sf-apply-tickets.sh (done: sf:tickets)

REPO="${SF_REPO:-kilo9alfa/softwarefactory}"
REPO_DIR="${SF_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_DIR="${HOME}/.local/share/softwarefactory/logs"
RETRY_MAX=3
SESSION_TIMEOUT=900  # 15 minutes — spec/tickets explore the codebase

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y.%m.%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/dispatcher.log"
}

session_exists() {
    tmux has-session -t "$1" 2>/dev/null || return 1
}

# True if the issue already carries any of the stage's "done" labels.
has_any_label() {
    local labels="$1"; shift
    local want
    for want in "$@"; do
        echo "$labels" | grep -qx "$want" && return 0
    done
    return 1
}

# Attempt counter (machine-local). Prevents infinite relaunch of a failing stage.
attempts_ok() {
    local marker="$LOG_DIR/$1.attempts"
    local n=0
    [ -f "$marker" ] && n=$(cat "$marker" 2>/dev/null || echo 0)
    if (( n >= RETRY_MAX )); then
        return 1
    fi
    echo $(( n + 1 )) > "$marker"
    return 0
}

# Spawn one stage's agent for one issue.
#   $1 stage  $2 skill  $3 apply_script  $4 issue_num
spawn() {
    local stage="$1" skill="$2" apply_script="$3" issue_num="$4"
    local session_name="sf-${stage}-${issue_num}"
    local log_file="$LOG_DIR/${stage}-${issue_num}.log"

    if session_exists "$session_name"; then
        log "[$stage] session $session_name already running, skipping #$issue_num"
        return 0
    fi
    if ! attempts_ok "${stage}-${issue_num}"; then
        log "[$stage] #$issue_num exceeded retry limit ($RETRY_MAX), skipping"
        return 1
    fi

    log "[$stage] spawning agent for #$issue_num in $session_name"
    tmux new-session -d -s "$session_name" -x 200 -y 50 \
        "cd ${REPO_DIR} && \
         claude --dangerously-skip-permissions -p '/softwarefactory:${skill} ${issue_num}' 2>&1 | tee ${log_file}; \
         bash ${REPO_DIR}/scripts/${apply_script} ${issue_num} ${log_file}; \
         tmux kill-session -t ${session_name}"

    # Watchdog: kill a hung session after the timeout.
    (
        sleep "$SESSION_TIMEOUT"
        if session_exists "$session_name"; then
            log "[$stage] session $session_name timeout (${SESSION_TIMEOUT}s), killing"
            tmux kill-session -t "$session_name" 2>/dev/null || true
        fi
    ) &
}

# Process one stage across all matching open issues.
#   $1 stage  $2 skill  $3 apply_script  $4 "trigger labels (space-sep, OR)"  $5 "done labels (space-sep, any=skip)"
process_stage() {
    local stage="$1" skill="$2" apply_script="$3" trigger_labels="$4" done_labels="$5"

    # Gather candidate issue numbers across all trigger labels (OR), deduped.
    local issues="" label
    for label in $trigger_labels; do
        local found
        found=$(gh issue list --repo "$REPO" --state open --label "$label" --json number --jq '.[].number' 2>/dev/null || echo "")
        issues="${issues}"$'\n'"${found}"
    done
    issues=$(echo "$issues" | grep -E '^[0-9]+$' | sort -u || echo "")

    [ -z "$issues" ] && return 0
    log "[$stage] candidates: $(echo "$issues" | tr '\n' ' ')"

    local issue_num
    while IFS= read -r issue_num; do
        [ -z "$issue_num" ] && continue
        local labels
        labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
        # shellcheck disable=SC2086
        if has_any_label "$labels" $done_labels; then
            log "[$stage] #$issue_num already has a done label, skipping"
            continue
        fi
        spawn "$stage" "$skill" "$apply_script" "$issue_num" || log "[$stage] failed to spawn for #$issue_num"
    done <<< "$issues"
}

main() {
    log "Dispatcher started (PID $$) repo=$REPO dir=$REPO_DIR"

    process_stage "triage"  "sf-triage"    "sf-apply-label.sh"   "feedback/triage"                 "feedback/bug feedback/feature sf:spam"
    process_stage "spec"    "sf-tospecs"   "sf-apply-spec.sh"    "feedback/bug feedback/feature"   "sf:spec"
    process_stage "tickets" "sf-totickets" "sf-apply-tickets.sh" "sf:spec"                         "sf:tickets"

    log "Dispatcher cycle complete"
}

main "$@"
