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
#   plan   : sf:tickets                      -> sf-plan      -> sf-apply-plan.sh    (done: sf:plan-review|sf:plan-approved)
#   dev    : sf:plan-approved                -> sf-dev       -> sf-apply-dev.sh     (done: sf:implemented) [writes: worktree + draft PR]
#   test   : sf:implemented                  -> (script-only) sf-test.sh           (done: sf:ready-for-prod|sf:needs-debug) [runs .sf.yml test:]
#
# Plan GENERATION is autonomous; plan APPROVAL is human-only (sf-approve-plan.sh
# adds sf:plan-approved). The dispatcher never advances past sf:plan-review.
# Dev (3b) runs autonomously in an isolated worktree and opens a DRAFT PR — the
# PR is the human code-review gate before merge.

# REPO_DIR is the working tree the agents run in; REPO defaults to that dir's
# GitHub repo (so `SF_REPO_DIR=~/code/localr5` alone targets databeacon/localr5).
REPO_DIR="${SF_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO="${SF_REPO:-$(cd "$REPO_DIR" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
: "${REPO:?SF_REPO unset and gh cannot resolve the repo -- run inside the repo, set SF_REPO, or export GH_TOKEN}"

# FACTORY_DIR is the Software Factory checkout itself (this script's repo). The
# trusted apply/prep/test scripts live HERE, not in the target repo — so they must
# be invoked from FACTORY_DIR, never REPO_DIR (which is the repo being processed).
FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${HOME}/.local/share/softwarefactory/logs"
RETRY_MAX=3
SESSION_TIMEOUT=900  # 15 minutes — spec/tickets explore the codebase

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y.%m.%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/dispatcher.log"
}

# Best-effort Slack alert (never fails the dispatcher). Channel comes from the
# repo's .sf.yml (SF_REPO_DIR); token from Vaultwarden / SF_SLACK_TOKEN.
notify() {
    SF_REPO="$REPO" bash "$FACTORY_DIR/scripts/sf-notify.sh" "$1" "$REPO_DIR" >/dev/null 2>&1 || true
}

# Fire a "gave up" alert exactly once per stuck stage (guarded by a .gaveup
# marker), so hitting the retry cap doesn't re-alert every 5-min cycle.
gaveup_notify() {
    local stage="$1" issue_num="$2" marker="$LOG_DIR/${1}-${2}.gaveup"
    [ -f "$marker" ] && return 0
    : > "$marker"
    notify "🛑 #${issue_num} stuck at '${stage}' — gave up after ${RETRY_MAX} attempts. Needs a human (see ${stage}-${issue_num}.log)."
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
        gaveup_notify "$stage" "$issue_num"
        return 1
    fi

    log "[$stage] spawning agent for #$issue_num in $session_name"
    # `timeout` self-limits the agent INSIDE the session — the old external
    # watchdog subshell was reaped when the systemd oneshot exited, so hung
    # sessions blocked forever. On timeout (exit 124) fire a Slack alert.
    tmux new-session -d -s "$session_name" -x 200 -y 50 \
        "export SF_REPO='${REPO}' SF_REPO_DIR='${REPO_DIR}'; cd ${REPO_DIR} && \
         timeout -k 30s ${SESSION_TIMEOUT}s claude --dangerously-skip-permissions -p '/softwarefactory:${skill} ${issue_num}' 2>&1 | tee ${log_file}; rc=\${PIPESTATUS[0]}; \
         if [ \$rc -eq 124 ]; then bash ${FACTORY_DIR}/scripts/sf-notify.sh \"⏱️ #${issue_num} '${stage}' agent hung >${SESSION_TIMEOUT}s and was killed — will retry until the ${RETRY_MAX}-try cap.\" '${REPO_DIR}' >/dev/null 2>&1; fi; \
         bash ${FACTORY_DIR}/scripts/${apply_script} ${issue_num} ${log_file}; \
         tmux kill-session -t ${session_name}"
}

# Spawn the WRITING stage (3b dev): prep an isolated worktree, run the dev skill
# with cwd = that worktree, then push + draft-PR + label via sf-apply-dev.sh.
spawn_dev() {
    local issue_num="$1"
    local session_name="sf-dev-${issue_num}"
    local log_file="$LOG_DIR/dev-${issue_num}.log"

    if session_exists "$session_name"; then
        log "[dev] session $session_name already running, skipping #$issue_num"; return 0
    fi
    if ! attempts_ok "dev-${issue_num}"; then
        log "[dev] #$issue_num exceeded retry limit ($RETRY_MAX), skipping"
        gaveup_notify "dev" "$issue_num"; return 1
    fi

    log "[dev] spawning agent for #$issue_num in $session_name"
    tmux new-session -d -s "$session_name" -x 200 -y 50 \
        "export SF_REPO='${REPO}' SF_REPO_DIR='${REPO_DIR}'; \
         wt=\$(bash '${FACTORY_DIR}/scripts/sf-prep-worktree.sh' ${issue_num}) && cd \"\$wt\" && \
         timeout -k 30s ${SESSION_TIMEOUT}s claude --dangerously-skip-permissions -p '/softwarefactory:sf-dev ${issue_num}' 2>&1 | tee '${log_file}'; rc=\${PIPESTATUS[0]}; \
         if [ \$rc -eq 124 ]; then bash '${FACTORY_DIR}/scripts/sf-notify.sh' \"⏱️ #${issue_num} 'dev' agent hung >${SESSION_TIMEOUT}s and was killed — will retry until the ${RETRY_MAX}-try cap.\" '${REPO_DIR}' >/dev/null 2>&1; fi; \
         bash '${FACTORY_DIR}/scripts/sf-apply-dev.sh' ${issue_num} \"\$wt\" '${log_file}'; \
         tmux kill-session -t ${session_name}"
}

# Process the dev stage: trigger sf:plan-approved, done sf:implemented.
process_dev() {
    local issues issue_num labels
    issues=$(gh issue list --repo "$REPO" --state open --label "sf:plan-approved" --json number --jq '.[].number' 2>/dev/null || echo "")
    issues=$(echo "$issues" | grep -E '^[0-9]+$' | sort -u || echo "")
    [ -z "$issues" ] && return 0
    log "[dev] candidates: $(echo "$issues" | tr '\n' ' ')"
    while IFS= read -r issue_num; do
        [ -z "$issue_num" ] && continue
        labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
        if echo "$labels" | grep -qx "sf:implemented"; then
            log "[dev] #$issue_num already implemented, skipping"; continue
        fi
        spawn_dev "$issue_num" || log "[dev] failed to spawn for #$issue_num"
    done <<< "$issues"
}

# Spawn the TEST stage (4): script-only (no LLM) — runs the repo's test command
# and gates on its exit code via sf-test.sh.
spawn_test() {
    local issue_num="$1"
    local session_name="sf-test-${issue_num}"
    if session_exists "$session_name"; then
        log "[test] session $session_name already running, skipping #$issue_num"; return 0
    fi
    if ! attempts_ok "test-${issue_num}"; then
        log "[test] #$issue_num exceeded retry limit ($RETRY_MAX), skipping"
        gaveup_notify "test" "$issue_num"; return 1
    fi
    log "[test] spawning tester for #$issue_num in $session_name"
    tmux new-session -d -s "$session_name" -x 200 -y 50 \
        "export SF_REPO='${REPO}' SF_REPO_DIR='${REPO_DIR}'; \
         timeout -k 30s ${SESSION_TIMEOUT}s bash '${FACTORY_DIR}/scripts/sf-test.sh' ${issue_num}; rc=\$?; \
         if [ \$rc -eq 124 ]; then bash '${FACTORY_DIR}/scripts/sf-notify.sh' \"⏱️ #${issue_num} 'test' run hung >${SESSION_TIMEOUT}s and was killed — will retry until the ${RETRY_MAX}-try cap.\" '${REPO_DIR}' >/dev/null 2>&1; fi; \
         tmux kill-session -t ${session_name}"
}

# Process the test stage: trigger sf:implemented, done sf:ready-for-prod|needs-debug.
process_test() {
    local issues issue_num labels
    issues=$(gh issue list --repo "$REPO" --state open --label "sf:implemented" --json number --jq '.[].number' 2>/dev/null || echo "")
    issues=$(echo "$issues" | grep -E '^[0-9]+$' | sort -u || echo "")
    [ -z "$issues" ] && return 0
    log "[test] candidates: $(echo "$issues" | tr '\n' ' ')"
    while IFS= read -r issue_num; do
        [ -z "$issue_num" ] && continue
        labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
        if echo "$labels" | grep -qE "^sf:ready-for-prod$|^sf:needs-debug$"; then
            log "[test] #$issue_num already tested, skipping"; continue
        fi
        spawn_test "$issue_num" || log "[test] failed to spawn for #$issue_num"
    done <<< "$issues"
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
    process_stage "plan"    "sf-plan"      "sf-apply-plan.sh"    "sf:tickets"                      "sf:plan-review sf:plan-approved"
    process_dev    # 3b: sf:plan-approved -> worktree -> /sf-dev -> draft PR -> sf:implemented
    process_test   # 4:  sf:implemented -> run .sf.yml test cmd -> sf:ready-for-prod | sf:needs-debug

    log "Dispatcher cycle complete"
}

main "$@"
