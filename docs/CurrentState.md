# Current State — 2026.07.28

## Status
Software Factory is a Claude Code plugin implementing an autonomous feedback-to-production pipeline driven by GitHub labels. **The full pipeline (stages 0–5) is code-complete and verified locally.** Repo is its own installable single-plugin marketplace. **Not yet deployed to Nuclaw; feedback-ingestion endpoint not built** (issues created manually today).

Pipeline: `feedback → triage → spec → tickets → plan → [human approve] → dev → draft PR → test → [human trigger] → deploy → shipped`.

## Built & verified ✅
| Stage / piece | How |
|---|---|
| 0 triage | `/sf-triage` (Haiku) → `sf-apply-label.sh` |
| 1 specs | `/sf-tospecs` (Sonnet) → `sf-apply-spec.sh` |
| 2 tickets | `/sf-totickets` (Opus) → `sf-apply-tickets.sh` |
| 3a plan | `/sf-plan` (Fable 5) → `sf-apply-plan.sh` → **human** `sf-approve-plan.sh` |
| 3b dev | `sf-prep-worktree.sh` → `/sf-dev` (Opus) → `sf-apply-dev.sh` (draft PR) |
| 4 test | `sf-test.sh` — **deterministic exit-code gate** (no LLM) |
| 5 deploy | `sf-prod.sh` (**human-run**) + `/sf-prod` summary |
| dispatcher | `sf-dispatcher.sh` multi-stage; per-project timer template + `sf-dispatcher-run.sh` |
| notifications | `sf-notify.sh` per-project Slack (live-verified on #social) |
| onboarding | `/sf-install --repo --gh-token-item --slack-channel [--enable-timer]` |
| gh-agnostic | no hardcoded repo/account; `GH_TOKEN`; clean guard if unresolvable |

## Pending ⬜
- **High:** Feedback ingestion endpoint (Stage 0 button/HTTP → issue) — the real user entry point
- **High:** Live Nuclaw deploy — enable a real systemd per-project timer; create Vaultwarden PAT items, set `SF_GH_TOKEN_ITEM`
- **Medium:** Real end-to-end run on a production app (`databeacon/localr5`, needs a subproject venv)
- **Medium:** Global concurrency cap on live `sf-*` tmux sessions across repos
- **Low:** Formal rollback command; cleanup cron (worktree/tmux); metrics
- **Low:** Delete parked fixture #4; remove superseded single-repo systemd units

## Key facts
- Skills invoked **namespaced**: `/softwarefactory:sf-triage <n>`
- **Advisory/trusted split** everywhere: skills emit advisory output (JSON/markers) to a machine-local log; trusted `sf-apply-*.sh` validate + do the one label transition. Deterministic stages (test/deploy) gate on real exit code, never LLM.
- `sf:*` labels are **additive** stage markers; `feedback/bug|feature` kept as permanent classification.
- Editing `commands/*.md` needs `bash scripts/sf-dev-sync.sh` (install caches a version-pinned copy); `scripts/*.sh` run live.
- A setup specifies **repo + gh account + slack channel** (via `/sf-install` flags).
- Secrets: never on disk — `GH_TOKEN` (timers) and the Slack token fetched from Vaultwarden at runtime; env files store only item *names*.

## Design doc
[2026.07.26.Software_Factory_Design.md](2026.07.26.Software_Factory_Design.md) — see the **Status snapshot** and **Implementation Manifest** for authoritative build status.
