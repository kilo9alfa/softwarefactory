#!/bin/bash
set -uo pipefail

# sf-slack-commands.sh — let a human drive the pipeline by replying in Slack.
#
# Reply IN THE THREAD of one of the dispatcher's own notifications with one or
# more commands and this poller (run each dispatcher cycle) performs them, in the
# order they appear. Recognised keywords: merge, deploy, approve, close.
#   • single command      →  "merge"          (also "merge to main")
#   • a SEQUENCE           →  "merge, deploy, close"  /  "merge + deploy"  /  "merge deploy close"
# A sequence runs its steps in order and STOPS at the first failure — so
# "merge, deploy, close" closes only if the merge AND the deploy succeeded.
# BEST-EFFORT: always exits 0; it must never break the dispatcher.
#
# Trust model (Slack text is UNTRUSTED):
#   1. only replies from SF_SLACK_ADMIN_USER are honoured; anyone else gets :x:;
#   2. only the four allowlisted keywords are ever run; any other words are noise;
#   3. the TARGET (issue / PR number) is parsed from OUR OWN bot notification (the
#      thread parent), NEVER from the reply — the reply only SELECTS commands;
#   4. every handled reply is marked with a reaction (:white_check_mark: / :x: /
#      :hourglass_flowing_sand: / :grey_question:) which is ALSO the idempotency
#      marker: a reply already carrying one of ours is skipped, so a command never
#      fires twice across the 5-minute cycles.
#
# Because `deploy` is a multi-minute rebuild, any reply that includes deploy (or
# any multi-step sequence) runs in a DETACHED job that reports each step back to
# the thread; the poller reacts :hourglass_flowing_sand: and returns immediately.
#
# Channel: slack_channel: from the repo's .sf.yml (same as sf-notify.sh).
# Token:   SF_SLACK_TOKEN env, else Vaultwarden SF_SLACK_ITEM.
# Admin:   SF_SLACK_ADMIN_USER (Slack user id). Unset ⇒ the poller is disabled.
# Debug:   SF_SLACK_CMD_DRYRUN=1 ⇒ log what it WOULD do; no execute, no reaction.
#
# Usage: sf-slack-commands.sh [repo-dir]
#   (internal) sf-slack-commands.sh --sequence <repo-dir> <issue> <pr> <csv-actions> <thread_ts> <reply_ts>

FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$FACTORY_DIR/scripts/sf-slack-commands.sh"
LOG_DIR="$HOME/.local/share/softwarefactory/logs"; mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%Y.%m.%d %H:%M:%S')] [slack-cmd] $*" | tee -a "$LOG_DIR/dispatcher.log" >&2; }

MODE="poll"
if [ "${1:-}" = "--sequence" ]; then
    MODE="sequence"; shift
    repo_dir="$1"; SEQ_ISSUE="$2"; SEQ_PR="$3"; SEQ_ACTIONS="$4"; SEQ_THREAD="$5"; SEQ_REPLY="$6"
else
    repo_dir="${1:-$PWD}"
fi

REPO="${SF_REPO:-$(cd "$repo_dir" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
[ -z "$REPO" ] && { echo "[slack-cmd] cannot resolve REPO — skip" >&2; exit 0; }

# Channel from .sf.yml (strip a fully-wrapped matching quote pair only).
channel=$(sed -n 's/^slack_channel:[[:space:]]*//p' "$repo_dir/.sf.yml" 2>/dev/null | head -1)
case "$channel" in \"*\") channel="${channel#\"}"; channel="${channel%\"}" ;; \'*\') channel="${channel#\'}"; channel="${channel%\'}" ;; esac
[ -z "$channel" ] && { echo "[slack-cmd] no slack_channel in .sf.yml — skip" >&2; exit 0; }

# Token: env first, then Vaultwarden.
token="${SF_SLACK_TOKEN:-}"
if [ -z "$token" ] && command -v bw >/dev/null 2>&1; then
    export BW_SESSION="${BW_SESSION:-$(cat "$HOME/.config/bw-session" 2>/dev/null || echo "")}"
    token=$(bw --nointeraction get password "${SF_SLACK_ITEM:-Slack Bot Token — kilo9alfa-nuclaw}" </dev/null 2>/dev/null || echo "")
fi
[ -z "$token" ] && { echo "[slack-cmd] no Slack token — skip" >&2; exit 0; }

DRYRUN="${SF_SLACK_CMD_DRYRUN:-}"
api()   { curl -s -H "Authorization: Bearer $token" "https://slack.com/api/$1" 2>/dev/null; }
react() { [ -n "$DRYRUN" ] && return 0
          curl -s -X POST -H "Authorization: Bearer $token" -H "Content-type: application/json" \
            --data "$(jq -n --arg c "$channel" --arg t "$1" --arg n "$2" '{channel:$c,timestamp:$t,name:$n}')" \
            https://slack.com/api/reactions.add >/dev/null 2>&1; }
say()   { [ -n "$DRYRUN" ] && { log "would reply: $1"; return 0; }
          curl -s -X POST -H "Authorization: Bearer $token" -H "Content-type: application/json; charset=utf-8" \
            --data "$(jq -n --arg c "$channel" --arg t "$1" --arg th "$2" '{channel:$c,text:$t,thread_ts:$th}')" \
            https://slack.com/api/chat.postMessage >/dev/null 2>&1; }

# Run ONE allowlisted action against issue/pr. Returns 0 on success, 1 on failure.
run_one_action() {
    local action="$1" issue="$2" pr="$3"
    case "$action" in
        merge)
            local p="$pr"
            [ -z "$p" ] && p=$(gh pr list --repo "$REPO" --head "sf/impl-$issue" --json number -q '.[0].number' 2>/dev/null)
            [ -z "$p" ] && { log "merge: no PR for #$issue"; return 1; }
            gh pr ready "$p" --repo "$REPO" >/dev/null 2>&1
            gh pr merge "$p" --repo "$REPO" --squash >/dev/null 2>&1 || return 1
            ;;
        approve)
            gh issue edit "$issue" --repo "$REPO" --add-label sf:plan-approved >/dev/null 2>&1 || return 1
            ;;
        close)
            gh issue close "$issue" --repo "$REPO" --reason completed --comment "Closed via Slack command." >/dev/null 2>&1 || return 1
            ;;
        deploy)
            local dcmd; dcmd=$(sed -n 's/^deploy:[[:space:]]*//p' "$repo_dir/.sf.yml" 2>/dev/null | head -1)
            [ -z "$dcmd" ] && { log "deploy: no 'deploy:' command in .sf.yml"; return 1; }
            # SF_ISSUE: unlike the stage-5 path this runs in the MAIN checkout on
            # the default branch — there is no sf/impl-<N> branch to infer the
            # issue from, so a per-issue-routing deploy: hook depends on this.
            ( cd "$repo_dir" && export SF_ISSUE="$issue" && eval "$dcmd" ) >"$LOG_DIR/deploy-$issue.log" 2>&1 || return 1
            ;;
        *) return 1 ;;
    esac
    return 0
}

# ── SEQUENCE MODE (detached): run the ordered actions, report each step, stop on first failure ──
if [ "$MODE" = "sequence" ]; then
    IFS=',' read -ra acts <<< "$SEQ_ACTIONS"
    pretty=$(echo "$SEQ_ACTIONS" | sed 's/,/ → /g')
    say ":hourglass_flowing_sand: running \`$pretty\` for #$SEQ_ISSUE…" "$SEQ_THREAD"
    for a in "${acts[@]}"; do
        log "[seq #$SEQ_ISSUE] $a"
        if run_one_action "$a" "$SEQ_ISSUE" "$SEQ_PR"; then
            say ":white_check_mark: \`$a\` done" "$SEQ_THREAD"
        else
            say ":x: \`$a\` FAILED — stopping the sequence for #$SEQ_ISSUE (see logs)" "$SEQ_THREAD"
            react "$SEQ_REPLY" x
            exit 0
        fi
    done
    react "$SEQ_REPLY" white_check_mark
    say ":checkered_flag: sequence \`$pretty\` complete for #$SEQ_ISSUE" "$SEQ_THREAD"
    exit 0
fi

# ── POLL MODE ──
admin="${SF_SLACK_ADMIN_USER:-}"
[ -z "$admin" ] && { echo "[slack-cmd] SF_SLACK_ADMIN_USER unset — poller disabled" >&2; exit 0; }
BOT_UID=$(api auth.test | jq -r '.user_id // empty')
[ -z "$BOT_UID" ] && { log "auth.test failed — skip"; exit 0; }

parents=$(api "conversations.history?channel=$channel&limit=40" \
          | jq -r --arg bot "$BOT_UID" '.messages[]? | select((.user==$bot) and ((.reply_count//0)>0)) | .ts')
[ -z "$parents" ] && { echo "[slack-cmd] no threaded notifications — nothing to do" >&2; exit 0; }

for pts in $parents; do
    thread=$(api "conversations.replies?channel=$channel&ts=$pts")
    parent_text=$(echo "$thread" | jq -r '.messages[0].text // ""')
    issue=$(echo "$parent_text" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
    pr=$(echo "$parent_text"   | grep -oE 'pull/[0-9]+' | head -1 | grep -oE '[0-9]+')

    while IFS= read -r m; do
        [ -z "$m" ] && continue
        ruser=$(echo "$m" | jq -r '.user // ""')
        rts=$(echo   "$m" | jq -r '.ts')
        rtext=$(echo "$m" | jq -r '.text // ""')
        [ "$ruser" = "$BOT_UID" ] && continue
        marked=$(echo "$m" | jq -r '[.reactions[]?.name] | map(select(.=="white_check_mark" or .=="x" or .=="hourglass_flowing_sand" or .=="grey_question")) | length')
        [ "${marked:-0}" != "0" ] && continue

        # Extract recognised command keywords IN ORDER (word-bounded, lower-cased).
        actions=$(echo "$rtext" | tr '[:upper:]' '[:lower:]' | grep -oiE '\b(merge|deploy|approve|close)\b')
        if [ -z "$actions" ]; then
            log "no recognised command in '$rtext' (thread #${issue:-?}) — ignoring"; react "$rts" grey_question; continue
        fi
        if [ "$ruser" != "$admin" ]; then
            log "UNAUTHORISED command from $ruser (thread #${issue:-?}) — ignoring"; react "$rts" x; continue
        fi
        if [ -z "$issue" ]; then
            log "no issue number in parent of thread $pts — cannot run"; react "$rts" x; continue
        fi

        count=$(echo "$actions" | grep -c .)
        csv=$(echo "$actions" | paste -sd, -)

        if [ -n "$DRYRUN" ]; then
            log "DRYRUN would run: [$csv]  issue=#$issue  pr=#${pr:-?}  by=$ruser"; continue
        fi

        # A sequence, or anything containing deploy → detached job (deploy is slow).
        if [ "$count" -gt 1 ] || echo "$actions" | grep -qi '^deploy$'; then
            sess="sf-seq-$issue"
            if tmux has-session -t "$sess" 2>/dev/null; then
                log "sequence for #$issue already running"; react "$rts" hourglass_flowing_sand; continue
            fi
            log "spawning sequence [$csv] for #$issue (pr #${pr:-?})"
            tmux new-session -d -s "$sess" \
                "SF_SLACK_TOKEN='$token' SF_REPO='$REPO' bash '$SELF' --sequence '$repo_dir' '$issue' '${pr:-}' '$csv' '$pts' '$rts'"
            react "$rts" hourglass_flowing_sand
            continue
        fi

        # Single quick command → run inline.
        action=$(echo "$actions" | head -1)
        log "running: $action  issue=#$issue  pr=#${pr:-?}  by=$ruser"
        if run_one_action "$action" "$issue" "$pr"; then
            react "$rts" white_check_mark; say ":white_check_mark: \`$action\` done for #$issue (Slack, <@$ruser>)" "$pts"
        else
            react "$rts" x; say ":x: \`$action\` failed for #$issue — check the dispatcher log" "$pts"
        fi
    done < <(echo "$thread" | jq -c '.messages[1:][]?')
done
exit 0
