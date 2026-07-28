#!/bin/bash
set -uo pipefail

# sf-install.sh — make the CURRENT repository Software Factory-compliant, in one
# command. Idempotent. Run from inside the target repo's working tree.
#
#   1. prerequisite checks (git, gh auth, jq, tmux) + identity sanity
#   2. bootstrap the label state machine (sf-init-labels.sh)
#   3. scaffold a .sf.yml template if absent (never overwrites an existing one)
#   4. print a compliance report + the human's remaining next steps
#
# Usage: bash sf-install.sh          # onboard the current repo
#        bash sf-install.sh -h

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠️  $*"; }
bad()  { echo "  ✗ $*"; }

echo "🏭 Software Factory — onboarding $(pwd)"
echo ""
echo "[1/4] Prerequisites"
fatal=0

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then ok "inside a git repo"; else bad "not a git repo — cd into the target repo first"; exit 1; fi
command -v gh  >/dev/null 2>&1 && ok "gh present"  || { bad "gh (GitHub CLI) not found"; fatal=1; }
command -v jq  >/dev/null 2>&1 && ok "jq present"  || { bad "jq not found (scripts need it)"; fatal=1; }
command -v tmux>/dev/null 2>&1 && ok "tmux present" || warn "tmux not found (needed on the factory host for the dispatcher, not for onboarding)"

repo=""
if command -v gh >/dev/null 2>&1; then
    repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
    active=$(gh api user --jq .login 2>/dev/null || echo "")
    if [ -n "$repo" ]; then
        ok "repo: $repo (gh account: ${active:-unknown})"
        owner="${repo%%/*}"
        if [ -n "$active" ] && [ "$owner" != "$active" ]; then
            warn "gh account '$active' != repo owner '$owner' — if writes fail, run: gh auth switch --user <account>"
        fi
    else
        bad "gh cannot resolve this repo (no remote, or not authenticated)"; fatal=1
    fi
fi
[ "$fatal" -eq 1 ] && { echo ""; echo "✗ Fix the prerequisites above and re-run."; exit 1; }

echo ""
echo "[2/4] Labels (state machine)"
bash "$SCRIPT_DIR/sf-init-labels.sh" "$repo" | sed 's/^/  /'

echo ""
echo "[3/4] Per-project config (.sf.yml)"
if [ -f .sf.yml ]; then
    ok ".sf.yml already present — leaving it untouched"
    grep -qE '^test:[[:space:]]*[^[:space:]#]' .sf.yml   && ok "test: configured"   || warn "test: not set — stage 4 will skip until you add it"
    grep -qE '^deploy:[[:space:]]*[^[:space:]#]' .sf.yml && ok "deploy: configured" || warn "deploy: not set — stage 5 will skip until you add it"
else
    cat > .sf.yml <<'YML'
# Software Factory per-project config. Read from this repo's root.

# Stage 4 (/sf-test): shell command run in the issue's worktree. Exit 0 = pass
# (→ sf:ready-for-prod), non-zero = fail (→ sf:needs-debug). Uncomment + set:
# test: npm test
# test: cd subproject && python -m pytest -q

# Stage 5 (sf-prod.sh, human-run): production deploy command. Exit 0 = deployed
# (→ sf:deployed, issue closed), non-zero = failed (→ sf:deploy-failed).
# deploy: npx wrangler deploy
YML
    ok "scaffolded a .sf.yml template — edit it to set test: and deploy:"
fi

echo ""
echo "[4/4] Next steps (human)"
echo "  1. Edit .sf.yml — set 'test:' (stage 4) and 'deploy:' (stage 5)."
echo "  2. Point your app's feedback button (or CLI) at: gh issue create --label feedback/triage"
echo "  3. On the factory host, run the dispatcher for this repo:"
echo "       SF_REPO_DIR=$(pwd) bash <softwarefactory>/scripts/sf-dispatcher.sh"
echo "     (or add a systemd timer per the runbook)."
echo ""
echo "✅ $repo is Software Factory-compliant."
