#!/bin/bash
set -euo pipefail

# sf-dev-sync.sh — refresh the locally-installed Software Factory plugin from
# the working tree during development.
#
# WHY: `claude plugin install` copies the plugin into a version-pinned cache
# (~/.claude/plugins/cache/softwarefactory/...). Editing commands/*.md in the
# repo does NOT update that cache, and `plugin update` / `marketplace update`
# are no-ops at the same version. A clean uninstall+reinstall re-copies the
# current working tree, so command (skill) edits take effect.
#
# NOTE: only needed after editing commands/*.md (the skills). Edits to
# scripts/*.sh (dispatcher, apply-label) run live from the repo — no sync needed.
#
# Usage: bash scripts/sf-dev-sync.sh

PLUGIN="softwarefactory@softwarefactory"
MARKETPLACE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ensure the local marketplace is registered (idempotent — ignore "already added").
claude plugin marketplace add "$MARKETPLACE_PATH" 2>/dev/null || true

echo "Refreshing $PLUGIN from $MARKETPLACE_PATH ..."
claude plugin uninstall "$PLUGIN" 2>/dev/null || true
claude plugin install "$PLUGIN"

echo "Done. Invoke the skill as: /softwarefactory:sf-triage <issue-number>"
