#!/bin/bash
set -uo pipefail

# sf-install.sh — make a repository Software Factory-compliant, in one command.
# Idempotent. Run from inside the target repo's working tree.
#
# A setup is defined by THREE things — specify them explicitly:
#   --repo owner/repo        the GitHub repo         (default: current repo via gh)
#   --gh-token-item "<item>" the gh ACCOUNT to use   (Vaultwarden item holding that
#                            account's PAT; pins identity per repo via GH_TOKEN)
#   --slack-channel "#chan"  per-project notifications channel (written to .sf.yml)
# plus:
#   --enable-timer           install + enable the per-project systemd dispatcher timer
#
# What it does (idempotent):
#   1. prerequisite checks (git, gh auth + identity, jq, tmux)
#   2. bootstrap the label state machine (sf-init-labels.sh)
#   3. .sf.yml — scaffold if absent; set slack_channel if --slack-channel given
#   4. identity/env — write ~/.config/softwarefactory/<slug>.env (repo + gh account)
#   5. optionally enable the per-project timer
#
# Example (full setup):
#   bash sf-install.sh --repo databeacon/localr5 \
#        --gh-token-item "GitHub PAT - databeacon" \
#        --slack-channel "#localr5-factory" --enable-timer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENABLE_TIMER=0; ARG_REPO=""; GH_TOKEN_ITEM=""; SLACK_CHANNEL=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)         sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --enable-timer)    ENABLE_TIMER=1 ;;
        --repo)            ARG_REPO="${2:?--repo needs owner/repo}"; shift ;;
        --gh-token-item)   GH_TOKEN_ITEM="${2:?--gh-token-item needs a Vaultwarden item name}"; shift ;;
        --slack-channel)   SLACK_CHANNEL="${2:?--slack-channel needs a channel, e.g. #proj}"; shift ;;
        *) echo "unknown argument: $1 (see --help)" >&2; exit 1 ;;
    esac
    shift
done

ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠️  $*"; }
bad()  { echo "  ✗ $*"; }

echo "🏭 Software Factory — onboarding $(pwd)"
echo ""
echo "[1/5] Prerequisites"
fatal=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then ok "inside a git repo"; else bad "not a git repo — cd into the target repo first"; exit 1; fi
command -v gh  >/dev/null 2>&1 && ok "gh present"  || { bad "gh (GitHub CLI) not found"; fatal=1; }
command -v jq  >/dev/null 2>&1 && ok "jq present"  || { bad "jq not found (scripts need it)"; fatal=1; }
command -v tmux>/dev/null 2>&1 && ok "tmux present" || warn "tmux not found (needed on the factory host, not for onboarding)"

repo="${ARG_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")}"
if [ -z "$repo" ]; then bad "no repo — pass --repo owner/repo, or run inside a gh-authenticated repo"; fatal=1; fi
[ "$fatal" -eq 1 ] && { echo ""; echo "✗ Fix the prerequisites above and re-run."; exit 1; }
owner="${repo%%/*}"
active=$(gh api user --jq .login 2>/dev/null || echo "")
ok "repo: $repo (gh account: ${active:-unknown})"
if [ -n "$active" ] && [ "$owner" != "$active" ] && [ -z "$GH_TOKEN_ITEM" ]; then
    warn "gh account '$active' != repo owner '$owner' and no --gh-token-item given — writes may fail. Pass --gh-token-item to pin this repo's account."
fi

echo ""
echo "[2/5] Labels (state machine)"
bash "$SCRIPT_DIR/sf-init-labels.sh" "$repo" | sed 's/^/  /'

echo ""
echo "[3/5] Per-project config (.sf.yml)"
if [ -f .sf.yml ]; then
    ok ".sf.yml present"
    grep -qE '^test:[[:space:]]*[^[:space:]#]' .sf.yml   && ok "test: configured"   || warn "test: not set — stage 4 skips until you add it"
    grep -qE '^deploy:[[:space:]]*[^[:space:]#]' .sf.yml && ok "deploy: configured" || warn "deploy: not set — stage 5 skips until you add it"
else
    cat > .sf.yml <<'YML'
# Software Factory per-project config. Read from this repo's root.

# Stage 4 (/sf-test): shell command run in the issue's worktree. Exit 0 = pass.
# test: npm test

# Stage 5 (sf-prod.sh, human-run): production deploy command. Exit 0 = deployed.
# deploy: npx wrangler deploy
YML
    ok "scaffolded .sf.yml — set test: and deploy:"
fi
if [ -n "$SLACK_CHANNEL" ]; then
    if grep -qE '^slack_channel:' .sf.yml 2>/dev/null; then
        perl -pi -e "s|^slack_channel:.*|slack_channel: \"$SLACK_CHANNEL\"|" .sf.yml
    else
        printf '\nslack_channel: "%s"\n' "$SLACK_CHANNEL" >> .sf.yml
    fi
    ok "slack_channel: \"$SLACK_CHANNEL\" (commit .sf.yml to version it)"
else
    grep -qE '^slack_channel:[[:space:]]*[^[:space:]#]' .sf.yml && ok "slack_channel: configured" || warn "slack_channel: not set — notifications skip. Pass --slack-channel."
fi

echo ""
echo "[4/5] gh account / dispatcher env"
slug=$(echo "$repo" | tr '/' '-')
if [ -n "$GH_TOKEN_ITEM" ] || [ "$ENABLE_TIMER" -eq 1 ]; then
    cfg="$HOME/.config/softwarefactory"; mkdir -p "$cfg"
    envf="$cfg/$slug.env"
    {
        echo "SF_REPO_DIR=$(pwd)"
        echo "SF_REPO=$repo"
        echo "# gh account for this repo: Vaultwarden item holding its PAT (pins identity via GH_TOKEN)"
        echo "SF_GH_TOKEN_ITEM=$GH_TOKEN_ITEM"
        echo "# Optional: Vaultwarden item for the Slack bot token (else the default is used)"
        echo "# SF_SLACK_ITEM="
    } > "$envf"
    ok "wrote $envf (repo + gh account)"
    [ -z "$GH_TOKEN_ITEM" ] && warn "SF_GH_TOKEN_ITEM is empty — set it (or the timer uses the machine's active gh account)"
else
    warn "no --gh-token-item and no --enable-timer — skipped env file (needed only for the systemd timer)"
fi

echo ""
echo "[5/5] Per-project dispatcher timer"
if [ "$ENABLE_TIMER" -eq 1 ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        ud="$HOME/.config/systemd/user"; mkdir -p "$ud"
        cp "$SCRIPT_DIR/softwarefactory-dispatcher@.service" "$SCRIPT_DIR/softwarefactory-dispatcher@.timer" "$ud/"
        systemctl --user daemon-reload
        systemctl --user enable --now "softwarefactory-dispatcher@$slug.timer" 2>&1 | sed 's/^/    /'
        ok "enabled softwarefactory-dispatcher@$slug.timer (every 5 min, staggered)"
    else
        warn "systemd --user not available here (e.g. macOS) — env file written. On the factory host:"
        echo "       cp $SCRIPT_DIR/softwarefactory-dispatcher@.{service,timer} ~/.config/systemd/user/"
        echo "       systemctl --user daemon-reload && systemctl --user enable --now softwarefactory-dispatcher@$slug.timer"
    fi
else
    echo "  (skipped — pass --enable-timer to install it)"
fi

echo ""
echo "✅ $repo is Software Factory-compliant."
[ -n "$SLACK_CHANNEL" ] && echo "   Remember to commit the updated .sf.yml."
