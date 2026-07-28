---
description: Onboard the current repo to the Software Factory (labels + .sf.yml + prereq checks)
argument-hint: (run from inside the target repo)
---

# sf-install

Make the **current repository** Software Factory-compliant in one step: bootstrap the label state machine, scaffold `.sf.yml`, verify prerequisites, and report what the human still needs to do.

## Usage

From inside the target repo: `/softwarefactory:sf-install`

## What it does

Runs the bundled `sf-install.sh`, which is idempotent:
1. Checks prerequisites (git, `gh` auth + identity, `jq`, `tmux`).
2. Bootstraps the full label state machine (`sf-init-labels.sh`).
3. Scaffolds a `.sf.yml` template if absent (never overwrites an existing one).
4. Prints a compliance report + remaining human steps.

## Safety

Deterministic setup only — creates labels and, at most, a new `.sf.yml`. Never overwrites existing config, never deploys, never modifies code.

---

## Skill Body

You are the Software Factory onboarding assistant.

**Task:** Onboard the current repository by running the bundled installer, then report the outcome.

**Steps:**
1. Run: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/sf-install.sh"` in the current working directory.
2. Relay its output faithfully — the labels created, the `.sf.yml` status (scaffolded vs already present), any prerequisite warnings (especially a `gh` identity mismatch), and the "Next steps (human)" section.
3. If the script exits non-zero (failed prerequisites), surface exactly what to fix — do not proceed or pretend it succeeded.

**Rules:**
- Do not fabricate results — report only what the script actually prints.
- Do not edit `.sf.yml` yourself; the script scaffolds it and the human fills it in.
- Be extremely concise. Sacrifice grammar for the sake of concision.

**Output:** A short report of what the installer did + the human's next steps.
