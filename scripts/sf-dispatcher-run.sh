#!/bin/bash
set -uo pipefail

# sf-dispatcher-run.sh — wrapper invoked by the per-project systemd template unit
# (softwarefactory-dispatcher@<slug>.service). It loads this repo's secrets from
# Vaultwarden AT RUNTIME (never stored on disk) and then runs the dispatcher.
#
# Env (from the instance's env file ~/.config/softwarefactory/<slug>.env):
#   SF_REPO_DIR        required — the repo's working tree
#   SF_REPO            optional — owner/repo (dispatcher derives it otherwise)
#   SF_GH_TOKEN_ITEM   optional — Vaultwarden item holding this repo's gh PAT
#                      (pins identity per repo; solves the multi-account drift)
#   SF_SLACK_ITEM      optional — Vaultwarden item for the Slack bot token
#   SF_FACTORY_DIR     optional — softwarefactory checkout (default ~/code/softwarefactory)

: "${SF_REPO_DIR:?SF_REPO_DIR required (set in the instance env file)}"

# Vaultwarden session (Nuclaw auto-loads it; systemd env may not have it).
export BW_SESSION="${BW_SESSION:-$(cat "$HOME/.config/bw-session" 2>/dev/null || echo "")}"

# Pin this repo's gh identity via a token fetched from Vaultwarden. Prefer the item's password
# field; fall back to its Notes field so a secure-note item holding just the PAT works too.
if [ -n "${SF_GH_TOKEN_ITEM:-}" ] && command -v bw >/dev/null 2>&1; then
    tok=$(bw --nointeraction get password "$SF_GH_TOKEN_ITEM" </dev/null 2>/dev/null || echo "")
    if [ -z "$tok" ]; then
        tok=$(bw --nointeraction get notes "$SF_GH_TOKEN_ITEM" </dev/null 2>/dev/null \
              | grep -oE 'github_pat_[A-Za-z0-9_]+|ghp_[A-Za-z0-9]+' | head -1 || echo "")
    fi
    [ -n "$tok" ] && export GH_TOKEN="$tok"
fi

FACTORY_DIR="${SF_FACTORY_DIR:-$HOME/code/softwarefactory}"
exec bash "$FACTORY_DIR/scripts/sf-dispatcher.sh"
