# Software Factory — Development Methodology

The **canonical, adoption-facing contract** for how work flows through the Software
Factory. If you are working in a repo that has a `.sf.yml`, this is the methodology
that repo follows. Point your project's `CLAUDE.md` at this file rather than copying it.

> **Scope of this file:** *how to use it* (workflow, gates, commands). For *how it is
> built* (architecture, rationale, risks) see
> [`docs/2026.07.26.Software_Factory_Design.md`](docs/2026.07.26.Software_Factory_Design.md).
> The skills themselves live in [`commands/`](commands/); the trusted scripts in
> [`scripts/`](scripts/).

---

## 1. The core idea

**Feedback becomes a deployed change by walking a GitHub issue through a label state
machine.** Each stage is either automated (a skill drafts, a trusted script commits
the transition) or a human gate. Three invariants make it safe:

| Invariant | Meaning |
|---|---|
| **Labels are the only state** | No separate database. The issue's `sf:*` labels *are* the pipeline position. Anyone can read progress from the issue. |
| **Skills advise, scripts act** | LLM skills only ever produce *advisory* output (JSON / marked blocks). A trusted shell script validates that output and performs the actual label change / GitHub write. A skill misbehaving cannot corrupt state. |
| **Feedback is untrusted** | Issue/Slack text is treated as data, never as instructions. Commands come only from an allowlist and an authorised user. |

---

## 2. The pipeline

```
feedback/triage → feedback/bug|feature → sf:1-spec → sf:2-tickets → sf:3-plan-review
   → (human) sf:3-plan-approved → sf:4-implemented → sf:5-ready-for-prod | sf:5-needs-debug
   → (human) sf:6-deployed (issue closed) | sf:6-deploy-failed
```

| Stage | Label in → out | Driven by | Auto / gate |
|---|---|---|---|
| **0 Triage** | `feedback/triage` → `feedback/bug`\|`feature`\|`sf:spam` | `sf-triage` (Haiku) → `sf-apply-label.sh` | auto |
| **1 Spec** | +`sf:1-spec` | `sf-tospecs` (Sonnet) → `sf-apply-spec.sh` | auto |
| **2 Tickets** | +`sf:2-tickets` | `sf-totickets` (Opus) → `sf-apply-tickets.sh` | auto |
| **3a Plan** | +`sf:3-plan-review` | `sf-plan` (Fable 5) → `sf-apply-plan.sh` | auto → **parks** |
| **3b Approve** | +`sf:3-plan-approved` | **human** → `sf-approve-plan.sh` | 🚦 **gate 1** |
| **3c Develop** | +`sf:4-implemented` (draft PR) | `sf-dev` (Opus) in isolated worktree → `sf-apply-dev.sh` | auto |
| **4 Test** | +`sf:5-ready-for-prod` \| `sf:5-needs-debug` | `sf-test.sh` (**no LLM** — gates on `.sf.yml` `test:` exit code) | auto → **parks** |
| **5 Deploy** | +`sf:6-deployed` (closes issue) \| `sf:6-deploy-failed` | **human runs** `sf-prod.sh` (`.sf.yml` `deploy:`) | 🚦 **gate 2** |

`sf:*` labels are **additive** — the `feedback/bug`\|`feature` classification stays on
the issue permanently as metadata.

---

## 3. The two human gates

Everything else is autonomous. A human is required at exactly two points:

1. **Plan approval** — the dispatcher parks at `sf:3-plan-review`. A human reads the
   posted plan and, if good, adds `sf:3-plan-approved` (via `sf-approve-plan.sh`, the
   `/sf-approve` skill, or a Slack `approve` reply). Nothing implements until then.
2. **Code review + deploy** — `sf-dev` opens a **draft PR**; it never merges itself.
   A human reviews/merges the PR, then triggers stage 5 (`sf-prod.sh`, or a Slack
   `deploy` reply). Production deploys are never launched by the dispatcher.

---

## 4. How to use it (as a human)

| I want to… | Do this |
|---|---|
| **File feedback** | Open a GitHub issue with the `feedback/triage` label. The body is free text; the dispatcher picks it up within ~5 min. |
| **See where an issue is** | Read its `sf:*` labels (see the pipeline table). |
| **Approve a plan** | Add `sf:3-plan-approved` to the issue, or reply `approve` in the Slack notification thread. |
| **Review code** | Review the draft PR the pipeline opened; merge when satisfied. |
| **Deploy** | Reply `deploy` in the Slack thread, or run `sf-prod.sh <issue>` on the host. |
| **Do several at once** | Reply a sequence in-thread: `merge, deploy, close` (runs in order, stops on first failure). |
| **Roll back a stage** | `sf-revise.sh <issue> <stage>` — sends an issue back for human revision. |

### Slack commands (in-thread)

Reply **in the thread** of one of the dispatcher's own notifications. Recognised
keywords: `merge`, `deploy`, `approve`, `close` — singly or as an ordered sequence
(`merge, deploy, close`). Only the configured admin user is honoured; the target
issue/PR is parsed from the bot's own message, never from your reply. Each handled
reply is marked with a reaction (✅ done · ❌ failed · ⏳ running · ❓ unrecognised).

---

## 5. Onboarding a repo

A repo joins the factory with **three facts**: which repo, which GitHub account, which
Slack channel.

```bash
/sf-install --repo owner/repo --gh-token-item "<Vaultwarden item>" \
            --slack-channel "#chan" [--enable-timer]
```

This bootstraps the labels, scaffolds a `.sf.yml` if absent, and (with
`--enable-timer`, a Nuclaw step) starts a per-repo 5-min dispatcher. What the repo
must provide:

| File | Purpose |
|---|---|
| **`.sf.yml`** (repo root) | `test:` (stage-4 gate command), `deploy:` (stage-5 command), `slack_channel:` |
| Per-instance env | `~/.config/softwarefactory/<slug>.env` — repo dir, `SF_GH_TOKEN_ITEM`, `SF_SLACK_ADMIN_USER` |

The pipeline (skills, dispatcher, scripts, label definitions) lives **only** in this
repo. Consuming repos hold just their `.sf.yml` — they run the shared scripts live.

---

## 6. Where to go deeper

| Topic | File |
|---|---|
| Architecture, rationale, risks, roadmap | [`docs/2026.07.26.Software_Factory_Design.md`](docs/2026.07.26.Software_Factory_Design.md) |
| Build status / what exists today | [`CLAUDE.md`](CLAUDE.md) |
| The skills (advisory LLM steps) | [`commands/`](commands/) |
| The trusted scripts (state transitions) | [`scripts/`](scripts/) |
| Label reference table | [`CLAUDE.md`](CLAUDE.md) § *GitHub Labels* |
