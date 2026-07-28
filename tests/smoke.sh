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

echo "[smoke] shared stage map (scripts/sf-stages.sh) is sourceable + well-formed"
if ( . scripts/sf-stages.sh ) 2>/dev/null; then note "✓ sourceable"; else note "✗ scripts/sf-stages.sh not sourceable"; fail=1; fi
# shellcheck source=../scripts/sf-stages.sh
. scripts/sf-stages.sh
if printf '%s' "${SF_STAGE_TOTAL:-}" | grep -qE '^[0-9]+$'; then
    note "✓ SF_STAGE_TOTAL=$SF_STAGE_TOTAL"
else
    note "✗ SF_STAGE_TOTAL missing or non-numeric"; fail=1
fi
for k in "${SF_STAGE_ORDER[@]}"; do
    if [ -n "${SF_STAGE_ORDINAL[$k]:-}" ] && [ -n "${SF_STAGE_TITLE[$k]:-}" ]; then
        note "✓ stage '$k' -> $(sf_stage_tag "$k")"
    else
        note "✗ stage '$k' missing an ordinal or title"; fail=1
    fi
done
# Every mapped label must point at a stage that actually exists in the map.
for l in "${!SF_STAGE_OF_LABEL[@]}"; do
    if [ -z "${SF_STAGE_ORDINAL[${SF_STAGE_OF_LABEL[$l]}]:-}" ]; then
        note "✗ label '$l' maps to unknown stage '${SF_STAGE_OF_LABEL[$l]}'"; fail=1
    fi
done
# Unknown keys must fail loudly, not emit "Stage /5".
if sf_stage_tag "no-such-stage" >/dev/null 2>&1; then
    note "✗ sf_stage_tag accepted an unknown stage key"; fail=1
else
    note "✓ unknown stage keys rejected"
fi

echo "[smoke] every bootstrapped label description is stage-prefixed"
label_rows=$(bash scripts/sf-init-labels.sh --list 2>/dev/null)
if [ -z "$label_rows" ]; then
    note "✗ sf-init-labels.sh --list produced nothing"; fail=1
else
    while IFS='|' read -r name _color desc; do
        [ -z "$name" ] && continue
        if printf '%s' "$desc" | grep -qE '^Stage [0-9]'; then
            note "✓ $name — $desc"
        else
            note "✗ $name description not stage-prefixed: '$desc'"; fail=1
        fi
    done <<< "$label_rows"
fi

if [ "$fail" -eq 0 ]; then echo "[smoke] PASS"; else echo "[smoke] FAIL"; fi
exit "$fail"
