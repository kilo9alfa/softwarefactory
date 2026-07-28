---
description: Onboard a repo to the Software Factory (repo + gh account + slack channel)
argument-hint: [--repo owner/repo] [--gh-token-item "<item>"] [--slack-channel "#chan"] [--enable-timer]
---

# sf-install

Make a repository Software Factory-compliant in one step. **A setup specifies three things** — pass them explicitly:

- `--repo owner/repo` — the GitHub repo (default: current repo)
- `--gh-token-item "<item>"` — the **gh account**: the Vaultwarden item holding that account's PAT (pins identity per repo)
- `--slack-channel "#chan"` — per-project notifications channel (written to `.sf.yml`)

plus `--enable-timer` to install the per-project dispatcher timer.

## Usage

From inside the target repo, e.g.:
`/softwarefactory:sf-install --repo databeacon/localr5 --gh-token-item "GitHub PAT - databeacon" --slack-channel "#localr5-factory" --enable-timer`

## What it does (idempotent)

Runs the bundled `sf-install.sh`:
1. Prerequisites (git, `gh` auth + identity, `jq`, `tmux`).
2. Bootstraps the label state machine (`sf-init-labels.sh`).
3. `.sf.yml` — scaffold if absent; set `slack_channel:` from `--slack-channel`.
4. Writes `~/.config/softwarefactory/<slug>.env` (repo + gh account) when `--gh-token-item`/`--enable-timer` given.
5. Optionally enables the per-project timer. Prints a compliance report.

## Safety

Deterministic setup only — creates labels and, at most, a new `.sf.yml`. Never overwrites existing config, never deploys, never modifies code.

---

## Skill Body

You are the Software Factory onboarding assistant.

**Task:** Onboard the current repository by running the bundled installer, then report the outcome.

**Steps:**
1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/sf-install.sh"` in the current working directory, **forwarding the user's arguments verbatim** (`--repo`, `--gh-token-item`, `--slack-channel`, `--enable-timer`).
2. Relay its output faithfully — labels created, `.sf.yml` status (incl. slack_channel), the env file written, any prerequisite/identity warnings, and the timer step.
3. If the script exits non-zero (failed prerequisites), surface exactly what to fix — do not proceed or pretend it succeeded.
4. If the user didn't specify `--slack-channel` or `--gh-token-item`, remind them a full setup specifies repo + gh account + slack channel.

**Rules:**
- Do not fabricate results — report only what the script actually prints.
- Do not edit `.sf.yml` yourself; the script scaffolds it and the human fills it in.
- Be extremely concise. Sacrifice grammar for the sake of concision.

**Output:** A short report of what the installer did + the human's next steps.
