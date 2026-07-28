#!/bin/bash
# sf-stages.sh — THE single source of truth for pipeline stage ordinals.
#
# SOURCE this, never execute it:  . "$SCRIPT_DIR/sf-stages.sh"
#
# Every script that shows a human "where in the pipeline am I" — label
# descriptions, issue comments, Slack notifications — reads its stage number
# from here instead of hardcoding one. Change the pipeline shape in this file
# and every consumer follows. tests/smoke.sh fails the build if any script
# emits a literal "Stage N" string that did not come from these helpers.
#
# Numbering: stages 0-5, with 3 split into 3a (plan) / 3b (dev) to match the
# existing 3a/3b language already shipped in comments and docs. The total (5)
# is the highest whole-numbered stage, so "Stage 3a/5" reads correctly.
#
# Keys are the dispatcher's stage names, so `$stage` can be passed straight in.

# Highest whole stage number — the "/N" in "Stage 1/5".
SF_STAGE_TOTAL=5

# Canonical stage order (also the iteration order for validation/tests).
SF_STAGE_ORDER=(triage spec tickets plan plan-approved dev test prod)

# key -> ordinal as displayed (string, because of 3a/3b).
declare -A SF_STAGE_ORDINAL=(
    [triage]="0"
    [spec]="1"
    [tickets]="2"
    [plan]="3a"
    [plan-approved]="3a"
    [dev]="3b"
    [test]="4"
    [prod]="5"
)

# key -> default bold title used in the issue-comment header.
declare -A SF_STAGE_TITLE=(
    [triage]="Triaged"
    [spec]="Spec"
    [tickets]="Tickets"
    [plan]="Implementation Plan"
    [plan-approved]="Plan approved"
    [dev]="Implemented"
    [test]="Tests"
    [prod]="Deploy"
)

# GitHub label name -> stage key. Consumed by sf-init-labels.sh to prefix every
# label description with its stage. Label NAMES never change — they are the
# state machine's exact-match keys (grep -qx / --label) and renaming one would
# silently desync every already-open issue.
declare -A SF_STAGE_OF_LABEL=(
    [feedback/triage]="triage"
    [feedback/bug]="triage"
    [feedback/feature]="triage"
    [sf:spam]="triage"
    [sf:spec]="spec"
    [sf:tickets]="tickets"
    [sf:plan-review]="plan"
    [sf:plan-approved]="plan-approved"
    [sf:implemented]="dev"
    [sf:ready-for-prod]="test"
    [sf:needs-debug]="test"
    [sf:deployed]="prod"
    [sf:deploy-failed]="prod"
)

# --- helpers -------------------------------------------------------------------
# All of them fail loudly on an unknown key rather than emitting an empty
# "Stage /5" — a typo'd key should break the smoke test, not ship to Slack.

_sf_stage_check() {
    if [ -z "${SF_STAGE_ORDINAL[${1:-}]:-}" ]; then
        echo "sf-stages: unknown stage key '${1:-}'" >&2
        return 1
    fi
}

# "1" / "3a" — the bare ordinal.
sf_stage_ord() { _sf_stage_check "$1" || return 1; printf '%s' "${SF_STAGE_ORDINAL[$1]}"; }

# "1/5" — ordinal over total.
sf_stage_num() { _sf_stage_check "$1" || return 1; printf '%s/%s' "${SF_STAGE_ORDINAL[$1]}" "$SF_STAGE_TOTAL"; }

# "Stage 1/5" — the human-facing tag.
sf_stage_tag() { _sf_stage_check "$1" || return 1; printf 'Stage %s/%s' "${SF_STAGE_ORDINAL[$1]}" "$SF_STAGE_TOTAL"; }

# "[Stage 1/5]" — Slack message prefix (call sites prepend this to the text they
# already build; sf-notify.sh's own interface is unchanged).
sf_slack_prefix() { _sf_stage_check "$1" || return 1; printf '[Stage %s/%s]' "${SF_STAGE_ORDINAL[$1]}" "$SF_STAGE_TOTAL"; }

# "🏭 **Spec** — Stage 1/5" — the issue-comment header.
# Usage: sf_comment_header <key> [title-override]
sf_comment_header() {
    _sf_stage_check "$1" || return 1
    printf '🏭 **%s** — Stage %s/%s' "${2:-${SF_STAGE_TITLE[$1]}}" "${SF_STAGE_ORDINAL[$1]}" "$SF_STAGE_TOTAL"
}

# "Stage 1 — Spec generated" — the GitHub label description prefix.
# Usage: sf_label_desc <label-name> <description text>
sf_label_desc() {
    local key="${SF_STAGE_OF_LABEL[${1:-}]:-}"
    if [ -z "$key" ]; then echo "sf-stages: no stage mapped for label '${1:-}'" >&2; return 1; fi
    printf 'Stage %s — %s' "${SF_STAGE_ORDINAL[$key]}" "$2"
}
