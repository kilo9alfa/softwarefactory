#!/bin/bash
set -euo pipefail

# sf-version.sh — print the Software Factory plugin name + version.
#
# Reads `.claude-plugin/plugin.json` (resolved relative to this script, not the
# caller's cwd) so operators can confirm which version is deployed from anywhere.
#
# Usage:
#   sf-version.sh        # prints: softwarefactory <version>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_JSON="$SCRIPT_DIR/../.claude-plugin/plugin.json"

if [ ! -f "$PLUGIN_JSON" ]; then
    echo "error: plugin manifest not found at $PLUGIN_JSON" >&2
    exit 1
fi

name="$(jq -r '.name' "$PLUGIN_JSON")"
version="$(jq -r '.version' "$PLUGIN_JSON")"

echo "$name $version"
