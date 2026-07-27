#!/bin/bash
set -uo pipefail

# smoke.sh — fast, dependency-free self-test for the Software Factory repo.
# Exit 0 = all good; non-zero = something is broken. This is the command
# stage 4 (/sf-test) runs via .sf.yml (`test: bash tests/smoke.sh`).

cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail=0
note() { echo "  $*"; }

echo "[smoke] bash syntax-check all scripts"
for s in scripts/*.sh tests/*.sh; do
    if bash -n "$s" 2>/dev/null; then note "✓ $s"; else note "✗ $s (syntax error)"; fail=1; fi
done

echo "[smoke] skills have YAML frontmatter"
for c in commands/*.md; do
    if head -1 "$c" | grep -qx -- '---'; then note "✓ $c"; else note "✗ $c (no frontmatter)"; fail=1; fi
done

echo "[smoke] plugin manifests are valid JSON"
for j in .claude-plugin/plugin.json .claude-plugin/marketplace.json; do
    if jq -e . "$j" >/dev/null 2>&1; then note "✓ $j"; else note "✗ $j (invalid JSON)"; fail=1; fi
done

if [ "$fail" -eq 0 ]; then echo "[smoke] PASS"; else echo "[smoke] FAIL"; fi
exit "$fail"
