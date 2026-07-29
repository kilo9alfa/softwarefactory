# Current State — 2026.07.29 18:39

## Status
Software Factory is a Claude Code plugin implementing an autonomous feedback-to-production pipeline driven by GitHub labels. **The full pipeline (stages 0–5) is code-complete and verified locally.** Repo is its own installable single-plugin marketplace. This session added a **canonical `METHODOLOGY.md`** (single source of truth) and pointed both `softwarefactory` and `localr5` CLAUDE.md files at it. **Not yet deployed to Nuclaw; feedback-ingestion endpoint not built** (issues created manually).

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
| Slack drive | `sf-slack-commands.sh` — in-thread `merge/deploy/approve/close` (admin-only, reactions = idempotency) |
| notifications | `sf-notify.sh` per-project Slack (live-verified on #social) |
| onboarding | `/sf-install --repo --gh-token-item --slack-channel [--enable-timer]` |
| methodology | `METHODOLOGY.md` (canonical contract); CLAUDE.md files point to it, don't copy |

## Pending ⬜
- **High:** Feedback ingestion endpoint (Stage 0 button/HTTP → issue) — the real user entry point
- **High:** Live Nuclaw deploy — enable a real systemd per-project timer; create Vaultwarden PAT items, set `SF_GH_TOKEN_ITEM`
- **Medium:** Real end-to-end run on a production app (`databeacon/localr5`, needs a subproject venv)
- **Medium:** Global concurrency cap on live `sf-*` tmux sessions across repos
- **Low:** Push localr5 commit `ca6e3cc` (CLAUDE.md → METHODOLOGY pointer) — committed locally, unpushed
- **Low:** Pull on Nuclaw's SF checkout so it picks up `METHODOLOGY.md` (next dispatcher `git pull` does this anyway)
- **Low:** Formal rollback command; cleanup cron (worktree/tmux); metrics; delete fixture #4

## Key facts
- Skills invoked **namespaced**: `/softwarefactory:sf-triage <n>`
- **Advisory/trusted split** everywhere: skills emit advisory output (JSON/markers); trusted `sf-apply-*.sh` validate + do the one label transition. Deterministic stages (test/deploy) gate on real exit code, never LLM.
- **Single source of truth:** methodology lives ONLY in `METHODOLOGY.md`. Tenant repos (e.g. localr5) carry only `.sf.yml` + a pointer link — never a copy. localr5's link uses the absolute GitHub URL (cross-repo).
- **Live-script model:** consuming repos hold no SF scripts; the Nuclaw dispatcher runs them live from `~/code/softwarefactory/scripts/`. "Propagate to a tenant" = Nuclaw's SF checkout on latest main. No copy step.
- `sf:*` labels are **additive** stage markers; `feedback/bug|feature` kept as permanent classification.
- Editing `commands/*.md` needs `bash scripts/sf-dev-sync.sh` (install caches a version-pinned copy); `scripts/*.sh` run live.
- Two identities: **kilo9alfa** (softwarefactory), **david4aero** (localr5/DataBeacon, remote via `github.com-db`). Verify before commit.
- Secrets: never on disk — `GH_TOKEN`/Slack token fetched from Vaultwarden at runtime; env files store only item *names*.

## Design doc
[2026.07.26.Software_Factory_Design.md](2026.07.26.Software_Factory_Design.md) — **Status snapshot** + **Implementation Manifest** = authoritative build status. Adoption contract: [../METHODOLOGY.md](../METHODOLOGY.md).

## Resume
```bash
claude --resume 6a454b30-c0bc-4508-9c28-38819e1bd325
```
