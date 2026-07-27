# Current State — 2026.07.27 10:42

## Status
Software Factory is a Claude Code plugin implementing an autonomous feedback-to-production pipeline driven by GitHub labels. **Phase 1 (triage) is functionally complete and verified end-to-end.** The repo is now its own installable single-plugin marketplace; the triage → label state machine works via the packaged, namespaced plugin. Not yet deployed to Nuclaw.

## Pending
- High: Commit `docs/CurrentState.md` + `docs/2026.07.27.EndOfSessionSummary.md` (untracked — not yet in git)
- High: Deploy to Nuclaw (runbook Tests 4–6) — install plugin from GitHub, copy scripts, enable systemd timer for the live 5-min dispatcher loop
- Medium: Phase 2 skills — `/sf-tospecs` (specs from classified feedback) and `/sf-totickets` (break specs into tickets)
- Low: Close test issues #2 (feature) and #3 (bug) on the repo when done using them as fixtures

## Quick Start
1. Verify plugin still installed: `claude plugin list | grep softwarefactory` (should be enabled, v0.1.0)
2. Full triage flow: `claude -p "/softwarefactory:sf-triage <n>" | tee LOG` then `bash scripts/sf-apply-label.sh <n> LOG`
3. After editing `commands/*.md`, run `bash scripts/sf-dev-sync.sh` to propagate (install caches a version-pinned copy)

## Key Facts
- Skill is invoked **namespaced**: `/softwarefactory:sf-triage <n>` — bare `/sf-triage` does NOT resolve
- Trusted/untrusted split: skill only classifies (advisory JSON); `scripts/sf-apply-label.sh` validates it's exactly `bug|feature|spam` before swapping the GitHub label. This survives the skill disobeying "JSON only"
- Refresh mechanics: `marketplace update` = metadata only; `plugin update` = no-op at same version; **uninstall+reinstall** (= `sf-dev-sync.sh`) is the only reliable content refresh
- `scripts/*.sh` run live from repo (no refresh); only `commands/*.md` need dev-sync
- Session was on Opus 4.8 (1M context) — hit "usage credits required for 1M context" error; switch via `/usage-credits` or `/model`

## Resume
```bash
claude --resume 05063ee0-920d-456d-a0f3-db3179cb1eb3
```
