# Software Factory - Claude Code Build Instructions

## Project Overview

The Software Factory is an autonomous feedback-to-production pipeline built as a Claude Code plugin.

**Design Document:** [docs/2026.07.26.Software_Factory_Design.md](docs/2026.07.26.Software_Factory_Design.md)

## Current Phase: 2 (Autonomous Specs & Tickets)

### What's Built

**Foundation & distribution**
- ✅ Installable plugin (`.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` — repo is its own marketplace)
- ✅ `sf-dev-sync.sh` (refresh installed plugin from working tree during development)
- ✅ Systemd service + timer (run dispatcher every 5 min on Nuclaw)

**Skills (advisory-only — never write to GitHub)** — invoked namespaced, e.g. `/softwarefactory:sf-triage <n>`
- ✅ `sf-triage` (Haiku) — classify feedback: bug vs feature vs spam
- ✅ `sf-tospecs` (Sonnet) — classified issue → structured spec (emits `<!--SPEC-->` block)
- ✅ `sf-totickets` (Opus) — spec → vertical-slice tickets (emits format-agnostic JSON)

**Trusted scripts (do every label transition; validate the skill's advisory output)**
- ✅ `sf-apply-label.sh` — triage → `feedback/bug`\|`feature`\|`sf:spam` (rewrites title, closes spam)
- ✅ `sf-apply-spec.sh` — extracts spec, posts comment, **+**`sf:spec`
- ✅ `sf-apply-tickets.sh` — parses JSON, renders dependency-ordered checklist, **+**`sf:tickets`
- ✅ `sf-dispatcher.sh` — **multi-stage** poller: launches triage / spec / tickets on their trigger labels

**State machine**
- ✅ GitHub labels: `feedback/triage` → `feedback/bug`\|`feature` → **+**`sf:spec` → **+**`sf:tickets` (`sf:*` are additive; classification kept as permanent metadata)

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
| `sf:spec` | Cyan | Spec generation in progress/done | (Future: `/sf-tospecs` agent) |
| `sf:tickets` | Yellow | Tickets broken down | (Future: `/sf-totickets` agent) |

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
