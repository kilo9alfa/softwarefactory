#!/bin/bash
set -euo pipefail

# sf-init-labels.sh — create the Software Factory label state machine on a repo.
#
# Idempotent (uses `gh label create --force`, which updates color/description if
# the label already exists). Run once per repo to make it factory-compliant.
# This is the label half of the future `/sf-install` onboarding command.
#
# Usage:
#   sf-init-labels.sh                 # target the current directory's repo
#   sf-init-labels.sh owner/repo      # target an explicit repo
#
# Auth: gh must be authenticated on the account that owns the repo
# (e.g. `gh auth switch --user david4aero` for databeacon/* repos).

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
if [ -z "$REPO" ]; then
    echo "error: no repo — run inside a git repo or pass owner/repo" >&2
    exit 1
fi

# name|color(hex, no #)|description  — the full pipeline state machine.
LABELS=(
    "feedback/triage|FEF2C0|Raw feedback, awaiting triage"
    "feedback/bug|D73A49|Classified as bug report"
    "feedback/feature|0075CA|Classified as feature request"
    "sf:spam|FDBF57|Classified as spam, will be closed"
    "sf:spec|A2EEEF|Spec generated"
    "sf:tickets|FBCA04|Tickets broken down"
    "sf:plan-review|D4C5F9|Plan generated, awaiting human approval"
    "sf:plan-approved|0E8A16|Human approved the plan; ready for dev"
    "sf:implemented|5319E7|Code merged; ready for testing"
    "sf:ready-for-prod|C2E0C6|Tests pass; awaiting production deploy"
    "sf:deployed|1D76DB|Deployed to production"
    "sf:needs-debug|B60205|Tests failed; needs debugging"
    "sf:test-skipped|D9D9D9|Repo has no .sf.yml test: command; stage 4 could not gate"
    "sf:deploy-failed|E11D21|Production deploy failed"
)

echo "Bootstrapping ${#LABELS[@]} Software Factory labels on $REPO ..."
for entry in "${LABELS[@]}"; do
    IFS='|' read -r name color desc <<< "$entry"
    if gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force >/dev/null 2>&1; then
        echo "  ✓ $name"
    else
        echo "  ✗ $name (failed — check auth/permissions on $REPO)" >&2
    fi
done
echo "Done. $REPO is label-compliant."
