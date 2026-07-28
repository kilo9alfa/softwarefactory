#!/bin/bash
set -uo pipefail

# sf-notify.sh — post a per-project Slack notification. BEST-EFFORT: it never
# fails the caller (always exits 0) — notifications must not break the pipeline.
#
# Channel: `slack_channel:` from the repo's .sf.yml (per-project).
# Token:   SF_SLACK_TOKEN env, else Vaultwarden item SF_SLACK_ITEM
#          (default "Slack Bot Token — kilo9alfa-nuclaw"). The token is
#          workspace-level and shared; only the channel is per-project.
#
# Usage: sf-notify.sh "<message>" [repo-dir]   (repo-dir defaults to cwd)
# Debug: SF_NOTIFY_DRYRUN=1 prints the payload instead of posting.

message="${1:?usage: sf-notify.sh <message> [repo-dir]}"
repo_dir="${2:-$PWD}"

# Channel from .sf.yml (strip a fully-wrapped matching quote pair only).
channel=$(sed -n 's/^slack_channel:[[:space:]]*//p' "$repo_dir/.sf.yml" 2>/dev/null | head -1)
case "$channel" in
    \"*\") channel="${channel#\"}"; channel="${channel%\"}" ;;
    \'*\') channel="${channel#\'}"; channel="${channel%\'}" ;;
esac
if [ -z "$channel" ]; then
    echo "[notify] no slack_channel in $repo_dir/.sf.yml — skipping" >&2; exit 0
fi

if [ "${SF_NOTIFY_DRYRUN:-}" = "1" ]; then
    echo "[notify DRYRUN] $channel: $message"; exit 0
fi

# Token: env first, then Vaultwarden (Nuclaw). Never hardcode.
token="${SF_SLACK_TOKEN:-}"
if [ -z "$token" ] && command -v bw >/dev/null 2>&1; then
    token=$(bw get password "${SF_SLACK_ITEM:-Slack Bot Token — kilo9alfa-nuclaw}" 2>/dev/null || echo "")
fi
if [ -z "$token" ]; then
    echo "[notify] no Slack token (SF_SLACK_TOKEN / Vaultwarden '${SF_SLACK_ITEM:-Slack Bot Token — kilo9alfa-nuclaw}') — skipping" >&2; exit 0
fi

resp=$(curl -sS -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $token" \
    -H "Content-type: application/json; charset=utf-8" \
    --data "$(jq -n --arg c "$channel" --arg t "$message" '{channel:$c, text:$t}')" 2>/dev/null || echo "")
if [ "$(echo "$resp" | jq -r '.ok // false' 2>/dev/null)" = "true" ]; then
    echo "[notify] posted to $channel" >&2
else
    echo "[notify] Slack post failed: $(echo "$resp" | jq -r '.error // "unknown"' 2>/dev/null)" >&2
fi
exit 0
