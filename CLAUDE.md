# Software Factory - Claude Code Build Instructions

## Project Overview

The Software Factory is an autonomous feedback-to-production pipeline built as a Claude Code plugin.

**Methodology (how work flows — the contract consuming repos point at):** [METHODOLOGY.md](METHODOLOGY.md)
**Design Document (architecture & rationale):** [docs/2026.07.26.Software_Factory_Design.md](docs/2026.07.26.Software_Factory_Design.md)

## Current Phase: Pipeline complete (stages 0–5) + one-command onboarding

### What's Built

**Foundation & distribution**
- ✅ Installable plugin (`.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` — repo is its own marketplace)
- ✅ `sf-dev-sync.sh` (refresh installed plugin from working tree during development)
- ✅ Systemd service + timer (run dispatcher every 5 min on Nuclaw)

**Skills (advisory-only — never write to GitHub)** — invoked namespaced, e.g. `/softwarefactory:sf-triage <n>`
- ✅ `sf-triage` (Haiku) — classify feedback: bug vs feature vs spam
- ✅ `sf-tospecs` (Sonnet) — classified issue → structured spec (emits `<!--SPEC-->` block)
- ✅ `sf-totickets` (Opus) — spec → vertical-slice tickets (emits format-agnostic JSON)
- ✅ `sf-plan` (Fable 5) — spec + tickets → implementation plan (emits `<!--PLAN-->` block)
- ✅ `sf-dev` (Opus) — implement approved plan in an isolated worktree; commits **locally only** (emits `<!--DEV-->` block)
- ✅ `sf-prod` (Sonnet) — **deploy summary only** (reads deploy log → human-readable report; never gates)

**Trusted scripts (do every label transition; validate the skill's advisory output)**
- ✅ `sf-apply-label.sh` — triage → `feedback/bug`\|`feature`\|`sf:spam` (rewrites title, closes spam)
- ✅ `sf-apply-spec.sh` — extracts spec, posts comment, **+**`sf:spec`
- ✅ `sf-apply-tickets.sh` — parses JSON, renders dependency-ordered checklist, **+**`sf:tickets`
- ✅ `sf-apply-plan.sh` — extracts plan, posts comment, **+**`sf:plan-review` (parks at approval gate)
- ✅ `sf-approve-plan.sh` — **human approval action**: `sf:plan-review` → **+**`sf:plan-approved`
- ✅ `sf-prep-worktree.sh` — isolated `wt-impl-N` (branch `sf/impl-N`), namespaced per repo under `~/sf-worktrees/`
- ✅ `sf-apply-dev.sh` — push branch, open **draft PR**, **+**`sf:implemented`
- ✅ `sf-test.sh` — **stage 4 (script-only, no LLM):** checks out `sf/impl-N`, runs `.sf.yml` `test:`, gates on **exit code** → **+**`sf:ready-for-prod` (0) \| **+**`sf:needs-debug` (≠0) \| **+**`sf:test-skipped` (no `test:` command at all)
- ✅ `sf-prod.sh` — **stage 5 (human-run):** runs `.sf.yml` `deploy:`, gates on exit code → **+**`sf:deployed` (closes issue) \| **+**`sf:deploy-failed`; invokes `/sf-prod` for the report. **Never dispatcher-launched.**
- ✅ `sf-dispatcher.sh` — **multi-stage** poller: launches triage / spec / tickets / plan / dev / test; parks at `sf:plan-review` (human approves) and `sf:ready-for-prod` (human runs `sf-prod.sh`)
- ⏱️ **Per-stage session budgets** (`sf-dispatcher.sh`): `SESSION_TIMEOUT` 900s (triage/spec/tickets/plan) · `DEV_TIMEOUT` **3600s** · `TEST_TIMEOUT` **1800s**. Override per repo via `SF_SESSION_TIMEOUT` / `SF_DEV_TIMEOUT` / `SF_TEST_TIMEOUT` in `~/.config/softwarefactory/<slug>.env`. One shared 900s previously killed dev agents mid-task with the work **uncommitted**, so `sf-apply-dev.sh` saw 0 commits and the stage silently never advanced (localr5 #108).

**Notifications & multi-repo timers**
- ✅ `sf-notify.sh` — per-project Slack post (best-effort). Channel from `.sf.yml` `slack_channel:`; token shared (Vaultwarden `Slack Bot Token — kilo9alfa-nuclaw` or `SF_SLACK_TOKEN`). Every stage transition notifies. Verified live on `#social`.
- ✅ Per-project dispatcher timers: `softwarefactory-dispatcher@<slug>.{service,timer}` template + `sf-dispatcher-run.sh` (fetches `GH_TOKEN` from Vaultwarden at runtime → pins each repo's identity). Enable via `sf-install.sh --enable-timer` (writes `~/.config/softwarefactory/<slug>.env`; set `SF_GH_TOKEN_ITEM`). **Live enable is a Nuclaw step** (no systemd on macOS).

**Per-project config & self-test**
- ✅ `.sf.yml` (repo root) — `test:` (stage 4), `deploy:` (stage 5), `slack_channel:` (notifications); `staging_url` reserved
- ✅ **Hook contract:** `test:`/`deploy:` are `eval`'d in a **child** process, so a hook cannot see the caller's shell variables. **`SF_ISSUE` is exported** at all three call sites (`sf-test.sh`, `sf-prod.sh`, and the Slack `deploy` reply in `sf-slack-commands.sh`) — that is the supported way for a hook to know which issue it is running for. A repo that routes per-issue (e.g. `databeacon/localr5` maps an issue's `area:*` label to a subproject's build/test/deploy) reads it instead of parsing the `sf/impl-<N>` branch name, which the Slack path doesn't have (it runs in the main checkout on the default branch). `cwd` is the worktree for stages 4/5 and the main checkout for the Slack reply
- ✅ `tests/smoke.sh` — this repo's own test (syntax-checks scripts, validates skill frontmatter + JSON manifests); wired as `.sf.yml` `test:`

**Multi-repo / onboarding**
- ✅ **gh-agnostic** — no hardcoded repo or account anywhere. Scripts resolve `REPO` from `SF_REPO` → `gh`, and **fail cleanly** if neither resolves (no silent `kilo9alfa/softwarefactory` default). Identity via `GH_TOKEN` (any account) or machine `gh` auth. One user-scope install serves every repo.
- ✅ **A setup specifies three things:** `/sf-install --repo owner/repo --gh-token-item "<Vaultwarden item>" --slack-channel "#chan" [--enable-timer]` — repo → labels+env; gh account → `SF_GH_TOKEN_ITEM` (→ `GH_TOKEN`); slack channel → `.sf.yml`. Verified on `databeacon/localr5` (david4aero) and kilo9alfa.
- ✅ **`/sf-install`** (skill → `sf-install.sh`) — one-command onboarding: prereq checks (git, `gh` auth **+ identity-mismatch warning**, `jq`, `tmux`), bootstrap labels, scaffold `.sf.yml` if absent, compliance report. Idempotent; never overwrites existing config.
- ✅ `sf-init-labels.sh [owner/repo]` — labels-only primitive (called by `sf-install.sh`).
- ⚠️ For DataBeacon repos: `gh auth switch --user david4aero` first; restore `kilo9alfa` after. (The `gh` active account drifts across sessions — `sf-install` warns on mismatch.)

**State machine**
- ✅ GitHub labels (full pipeline): `feedback/triage` → `feedback/bug`\|`feature` → **+**`sf:spec` → **+**`sf:tickets` → **+**`sf:plan-review` → *(human)* **+**`sf:plan-approved` → **+**`sf:implemented` → **+**`sf:ready-for-prod` \| `sf:needs-debug` → *(human)* **+**`sf:deployed` (closed) \| `sf:deploy-failed` (`sf:*` are additive; classification kept as permanent metadata)
- **Two gates:** (1) plan *approval* — human adds `sf:plan-approved` after reading the plan (dispatcher parks at `sf:plan-review`); (2) code review — dev is autonomous but opens a **draft PR**, and a human reviews the PR before merge.

> Full stage-by-stage build map: see the **Implementation Manifest** table in the design doc.

## Installation (plugin)

The repo is its own single-plugin marketplace. Install from a local checkout (best
for development — testable without pushing) or straight from GitHub (Nuclaw / prod):

```bash
# Local checkout (dev):
claude plugin marketplace add ~/code/softwarefactory
claude plugin install softwarefactory@softwarefactory

# From GitHub (Nuclaw / prod, after pushing):
claude plugin marketplace add kilo9alfa/softwarefactory
claude plugin install softwarefactory@softwarefactory
```

Commands are namespaced by plugin. Invoke the skill as **`/softwarefactory:sf-triage <issue-number>`**.

### Development loop — testing changes as you build

| You edited... | To test the change |
|---|---|
| `scripts/*.sh` (dispatcher, apply-label, dev-sync) | Run directly — they execute live from the repo, no refresh needed |
| `commands/*.md` (the skills) | Run `bash scripts/sf-dev-sync.sh` first — `install` caches a version-pinned **copy**, so command edits need a reinstall to propagate. `plugin update` / `marketplace update` are no-ops at the same version |

### Next Steps

1. **Test the `/sf-triage` skill locally**
   - Create a test feedback issue with `feedback/triage` label
   - Run: `claude --dangerously-skip-permissions -p /sf-triage <issue-number>`
   - Verify: Issue gets updated with classification label

2. **Deploy dispatcher to Nuclaw**
   - Copy scripts to Nuclaw: `scp -r scripts/ r5c-1:~/code/softwarefactory/`
   - Install systemd units: `mkdir -p ~/.config/systemd/user && cp scripts/*.{service,timer} ~/.config/systemd/user/`
   - Enable timer: `systemctl --user enable softwarefactory-dispatcher.timer`
   - Start timer: `systemctl --user start softwarefactory-dispatcher.timer`
   - Verify: `systemctl --user status softwarefactory-dispatcher.timer`

3. **Integration test**
   - Create a test feedback issue on this repo
   - Wait for dispatcher to process it (or manually run `/sf-triage`)
   - Verify label changes from `feedback/triage` → `feedback/bug` or `feedback/feature`

## GitHub Labels (State Machine)

| Label | Color | Purpose | Triggered By |
|-------|-------|---------|--------------|
| `feedback/triage` | Yellow | Raw feedback, awaiting classification | User creates issue |
| `feedback/bug` | Red | Classified as bug | `/sf-triage` agent |
| `feedback/feature` | Blue | Classified as feature request | `/sf-triage` agent |
| `sf:spam` | Orange | Classified as spam | `/sf-triage` agent |
| `sf:spec` | Cyan | Spec generated | `/sf-tospecs` → `sf-apply-spec.sh` |
| `sf:tickets` | Yellow | Tickets broken down | `/sf-totickets` → `sf-apply-tickets.sh` |
| `sf:plan-review` | Purple | Plan generated, **awaiting human approval** | `/sf-plan` → `sf-apply-plan.sh` |
| `sf:plan-approved` | Green | Human approved the plan; ready for dev | **Human** → `sf-approve-plan.sh` |
| `sf:implemented` | Violet | Code implemented; **draft PR open** for review | `/sf-dev` → `sf-apply-dev.sh` |
| `sf:ready-for-prod` | Green | Tests pass; awaiting human stage-5 trigger | `sf-test.sh` (exit 0) |
| `sf:needs-debug` | Red | Tests failed; needs debugging | `sf-test.sh` (exit ≠0) |
| `sf:test-skipped` | Grey | Repo has no `.sf.yml` `test:` — stage 4 **could not gate**; not a code failure. Terminal: add a `test:` and remove the label to re-run, or add `sf:ready-for-prod` to ship ungated | `sf-test.sh` (no `test:`) |
| `sf:deployed` | Blue | Deployed to production; **issue closed** | `sf-prod.sh` (exit 0) |
| `sf:deploy-failed` | Red | Production deploy failed | `sf-prod.sh` (exit ≠0) |

## Git Identity

```bash
git config user.name     # should be: kilo9alfa
git config user.email    # should be: david@kilo9alfa.com
gh auth status           # should be: active on kilo9alfa
```

## Testing Locally

### Create a test issue (manual)

```bash
# Open browser to create issue
open "https://github.com/kilo9alfa/softwarefactory/issues/new?labels=feedback/triage"

# Or via CLI (complex syntax, use browser for now)
```

### Run triage agent manually

```bash
cd ~/code/softwarefactory
claude --dangerously-skip-permissions -p /sf-triage 1
```

## Dispatcher Operation (on Nuclaw)

The dispatcher runs every 5 minutes via systemd timer. Each cycle:

1. Fetches all issues with `feedback/triage` label
2. For each issue:
   - Checks if already processed (has result label) → skip
   - Checks if session already running → skip
   - Spawns tmux session: `tmux new-session -d -s sf-triage-<N>`
   - Runs: `claude --dangerously-skip-permissions -p /sf-triage <N>`
   - Kills session after 10 minutes (timeout)
3. Logs to: `~/.local/share/softwarefactory/logs/dispatcher.log`

## Architecture Constraints (from Design Doc)

- Everything runs on Claude Code CLI, never Claude API directly
- Feedback text is untrusted user input (never inject into instructions)
- GitHub labels coordinate state (no separate state DB)
- Agents run in tmux (persistent, debuggable)
- Worktrees isolate work (created later in phase 3)

## Safety & Idempotency

The dispatcher is idempotent:
- Won't spawn duplicate sessions (checks `tmux has-session`)
- Won't re-process classified issues (checks result labels)
- Retry cap prevents infinite loops
- Timeout kills hung agents

The `/sf-triage` skill is injection-safe:
- Treats issue body as untrusted data
- Extracts structured info only
- Never executes commands from issue body
- Uses haiku model (efficient, focused)

## Next Phase (Phase 2)

- `/sf-tospecs` skill (generate specs from feedback)
- `/sf-totickets` skill (break specs into tickets)
- Update dispatcher to handle more trigger labels
- Slack notifications

## Debugging

### Check dispatcher logs on Nuclaw

```bash
ssh r5c-1 'tail -f ~/.local/share/softwarefactory/logs/dispatcher.log'
```

### Check tmux session (in progress)

```bash
ssh r5c-1 'tmux ls'
ssh r5c-1 'tmux attach -t sf-triage-123'
```

### Test dispatcher locally

```bash
# Run one cycle manually
scripts/sf-dispatcher.sh
```

### Test skill directly

```bash
# Create a test issue first, then:
claude --dangerously-skip-permissions -p /sf-triage <number>
```

## References

- **GitHub API:** `gh issue list`, `gh issue view`, `gh issue label`, `gh issue comment`
- **tmux:** `tmux new-session`, `tmux has-session`, `tmux kill-session`
- **Systemd:** `systemctl --user enable`, `systemctl --user start`, `journalctl --user-unit`
- **Claude Code:** `claude --help`, `claude -p <skill>`, `--dangerously-skip-permissions`
