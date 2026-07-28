#!/bin/bash
set -uo pipefail

# sf-slack-commands.sh — let a human drive the pipeline by replying in Slack.
#
# Reply IN THE THREAD of one of the dispatcher's own notifications with a bare
# command — `merge`, `deploy`, `approve`, or `close` — and this poller (run each
# dispatcher cycle) performs it. BEST-EFFORT: always exits 0; it must never break
# the dispatcher.
#
# Trust model (Slack text is UNTRUSTED — treat like any external input):
#   1. only replies from SF_SLACK_ADMIN_USER are honoured; anyone else gets :x:;
#   2. the command must be an EXACT allowlist match (merge|deploy|approve|close);
#   3. the TARGET (issue / PR number) is parsed from OUR OWN bot notification
#      (the thread parent), NEVER from the user's reply — the reply only SELECTS
#      a command from the fixed set. A user cannot point a command at an arbitrary
#      issue; they can only act on a thread the dispatcher itself opened.
#   4. every handled reply is marked with a reaction (:white_check_mark: / :x: /
#      :hourglass_flowing_sand: / :grey_question:) which is ALSO the idempotency
#      marker: a reply that already carries one of ours is skipped, so a command
#      never fires twice across the 5-minute cycles.
#
# Channel: slack_channel: from the repo's .sf.yml (same as sf-notify.sh).
# Token:   SF_SLACK_TOKEN env, else Vaultwarden SF_SLACK_ITEM.
# Admin:   SF_SLACK_ADMIN_USER (Slack user id). Unset ⇒ the poller is disabled.
# Debug:   SF_SLACK_CMD_DRYRUN=1 ⇒ log what it WOULD do; no execute, no reaction.
#
# Usage: sf-slack-commands.sh [repo-dir]

repo_dir="${1:-$PWD}"
FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${SF_REPO:-$(cd "$repo_dir" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
LOG_DIR="$HOME/.local/share/softwarefactory/logs"; mkdir -p "$LOG_DIR"
log() { echo "[$(date '+%Y.%m.%d %H:%M:%S')] [slack-cmd] $*" | tee -a "$LOG_DIR/dispatcher.log" >&2; }

admin="${SF_SLACK_ADMIN_USER:-}"
[ -z "$admin" ] && { echo "[slack-cmd] SF_SLACK_ADMIN_USER unset — poller disabled" >&2; exit 0; }
[ -z "$REPO" ]  && { echo "[slack-cmd] cannot resolve REPO — skip" >&2; exit 0; }

# Channel from .sf.yml (strip a fully-wrapped matching quote pair only) — same as sf-notify.sh.
channel=$(sed -n 's/^slack_channel:[[:space:]]*//p' "$repo_dir/.sf.yml" 2>/dev/null | head -1)
case "$channel" in \"*\") channel="${channel#\"}"; channel="${channel%\"}" ;; \'*\') channel="${channel#\'}"; channel="${channel%\'}" ;; esac
[ -z "$channel" ] && { echo "[slack-cmd] no slack_channel in .sf.yml — skip" >&2; exit 0; }

# Token: env first, then Vaultwarden (Nuclaw). Never hardcode.
token="${SF_SLACK_TOKEN:-}"
if [ -z "$token" ] && command -v bw >/dev/null 2>&1; then
    export BW_SESSION="${BW_SESSION:-$(cat "$HOME/.config/bw-session" 2>/dev/null || echo "")}"
    token=$(bw --nointeraction get password "${SF_SLACK_ITEM:-Slack Bot Token — kilo9alfa-nuclaw}" </dev/null 2>/dev/null || echo "")
fi
[ -z "$token" ] && { echo "[slack-cmd] no Slack token — skip" >&2; exit 0; }

DRYRUN="${SF_SLACK_CMD_DRYRUN:-}"
BOT_UID=$(curl -s -H "Authorization: Bearer $token" https://slack.com/api/auth.test 2>/dev/null | jq -r '.user_id // empty')
[ -z "$BOT_UID" ] && { log "auth.test failed — skip"; exit 0; }

api()   { curl -s -H "Authorization: Bearer $token" "https://slack.com/api/$1" 2>/dev/null; }
react() { [ -n "$DRYRUN" ] && return 0
          curl -s -X POST -H "Authorization: Bearer $token" -H "Content-type: application/json" \
            --data "$(jq -n --arg c "$channel" --arg t "$1" --arg n "$2" '{channel:$c,timestamp:$t,name:$n}')" \
            https://slack.com/api/reactions.add >/dev/null 2>&1; }
say()   { [ -n "$DRYRUN" ] && { log "would reply: $1"; return 0; }
          curl -s -X POST -H "Authorization: Bearer $token" -H "Content-type: application/json; charset=utf-8" \
            --data "$(jq -n --arg c "$channel" --arg t "$1" --arg th "$2" '{channel:$c,text:$t,thread_ts:$th}')" \
            https://slack.com/api/chat.postMessage >/dev/null 2>&1; }

# Bot notifications (last 40) that have at least one reply.
parents=$(api "conversations.history?channel=$channel&limit=40" \
          | jq -r --arg bot "$BOT_UID" '.messages[]? | select((.user==$bot) and ((.reply_count//0)>0)) | .ts')
[ -z "$parents" ] && { echo "[slack-cmd] no threaded notifications — nothing to do" >&2; exit 0; }

for pts in $parents; do
    thread=$(api "conversations.replies?channel=$channel&ts=$pts")
    parent_text=$(echo "$thread" | jq -r '.messages[0].text // ""')
    issue=$(echo "$parent_text" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
    pr=$(echo "$parent_text"   | grep -oE 'pull/[0-9]+' | head -1 | grep -oE '[0-9]+')

    # Iterate replies (skip parent at [0]). Process-substitution keeps vars in THIS shell.
    while IFS= read -r m; do
        [ -z "$m" ] && continue
        ruser=$(echo "$m" | jq -r '.user // ""')
        rts=$(echo   "$m" | jq -r '.ts')
        rtext=$(echo "$m" | jq -r '.text // ""')
        [ "$ruser" = "$BOT_UID" ] && continue
        # Idempotency: already carries one of our markers?
        marked=$(echo "$m" | jq -r '[.reactions[]?.name] | map(select(.=="white_check_mark" or .=="x" or .=="hourglass_flowing_sand" or .=="grey_question")) | length')
        [ "${marked:-0}" != "0" ] && continue

        # Normalise + allowlist the command.
        cmd=$(echo "$rtext" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')
        case "$cmd" in
            merge|"merge to main")  action=merge  ;;
            deploy)                 action=deploy ;;
            approve|"approve plan") action=approve;;
            close)                  action=close  ;;
            *) log "unknown command '$rtext' (thread #${issue:-?}) — ignoring"; react "$rts" grey_question; continue ;;
        esac

        # Authorize.
        if [ "$ruser" != "$admin" ]; then
            log "UNAUTHORISED '$action' from $ruser (thread #${issue:-?}) — ignoring"; react "$rts" x; continue
        fi
        if [ -z "$issue" ]; then
            log "no issue number in parent of thread $pts — cannot run '$action'"; react "$rts" x; continue
        fi

        if [ -n "$DRYRUN" ]; then
            log "DRYRUN would run: $action  issue=#$issue  pr=#${pr:-?}  by=$ruser"; continue
        fi
        log "running: $action  issue=#$issue  pr=#${pr:-?}  by=$ruser"

        ok=1
        case "$action" in
            merge)
                p="$pr"
                [ -z "$p" ] && p=$(gh pr list --repo "$REPO" --head "sf/impl-$issue" --json number -q '.[0].number' 2>/dev/null)
                if [ -n "$p" ]; then
                    gh pr ready "$p" --repo "$REPO" >/dev/null 2>&1
                    if gh pr merge "$p" --repo "$REPO" --squash >/dev/null 2>&1; then
                        say ":white_check_mark: merged PR #$p → main (Slack, <@$ruser>)" "$pts"
                    else ok=0; fi
                else ok=0; log "merge: no PR for #$issue"; fi
                ;;
            approve)
                if gh issue edit "$issue" --repo "$REPO" --add-label sf:plan-approved >/dev/null 2>&1; then
                    say ":white_check_mark: #$issue approved — sf:plan-approved set, dev will pick it up (Slack, <@$ruser>)" "$pts"
                else ok=0; fi
                ;;
            close)
                if gh issue close "$issue" --repo "$REPO" --reason completed --comment "Closed via Slack by <@$ruser>." >/dev/null 2>&1; then
                    say ":white_check_mark: #$issue closed (Slack, <@$ruser>)" "$pts"
                else ok=0; fi
                ;;
            deploy)
                sess="sf-deploy-$issue"
                if tmux has-session -t "$sess" 2>/dev/null; then
                    log "deploy #$issue already running"; react "$rts" hourglass_flowing_sand; continue
                fi
                dcmd=$(sed -n 's/^deploy:[[:space:]]*//p' "$repo_dir/.sf.yml" 2>/dev/null | head -1)
                if [ -z "$dcmd" ]; then
                    log "deploy: no 'deploy:' command in .sf.yml"; react "$rts" x
                    say ":x: no \`deploy:\` command in this repo's .sf.yml — nothing to run" "$pts"; continue
                fi
                # Heavy + slow (may rebuild): run detached; the job reports back to the thread itself.
                jlog="$LOG_DIR/deploy-$issue.log"
                tmux new-session -d -s "$sess" \
                    "cd '$repo_dir' && { $dcmd; } >'$jlog' 2>&1; rc=\$?; \
                     if [ \$rc -eq 0 ]; then \
                        SF_SLACK_TOKEN='$token' bash '$FACTORY_DIR/scripts/sf-notify.sh' ':white_check_mark: deploy for #$issue succeeded (exit 0)' '$repo_dir'; \
                     else \
                        SF_SLACK_TOKEN='$token' bash '$FACTORY_DIR/scripts/sf-notify.sh' \":x: deploy for #$issue FAILED (exit \$rc) — see $jlog\" '$repo_dir'; \
                     fi"
                react "$rts" hourglass_flowing_sand
                say ":hourglass_flowing_sand: deploy started for #$issue — result to follow (Slack, <@$ruser>)" "$pts"
                continue  # leave the hourglass as the marker; the job posts the outcome
                ;;
        esac

        if [ "$ok" = 1 ]; then react "$rts" white_check_mark
        else react "$rts" x; say ":x: '$action' failed for #$issue — check the dispatcher log" "$pts"; fi
    done < <(echo "$thread" | jq -c '.messages[1:][]?')
done
exit 0
