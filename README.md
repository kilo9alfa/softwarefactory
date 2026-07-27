# Software Factory

An autonomous feedback-to-production pipeline powered by Claude Code, GitHub, and Slack.

**Status:** 🔬 Design & Spike Phase

## Overview

The Software Factory accelerates the journey from user feedback to deployed features by automating mechanical work (specs, tickets, testing, deployment) while preserving human judgment at critical gates (design & implementation).

## Quick Start

- **Design Document:** [docs/2026.07.26.Software_Factory_Design.md](docs/2026.07.26.Software_Factory_Design.md) — Complete architecture, advantages, risks, roadmap
- **Status:** Phase 1 (foundation) — Building feedback endpoint & `/sf-tospecs` skill

## Pipeline Stages

```
User Feedback → Classify & Issue → Specs (auto) → Tickets (auto) → Plan (manual)
                                                                        ↓
                                                                     Develop (manual)
                                                                        ↓
                                                                    Test (auto)
                                                                        ↓
                                                                   Deploy (auto)
```

## Key Concepts

- **Source of Truth:** GitHub issues with labels for state tracking
- **Communication:** Slack notifications at each stage
- **Isolation:** Git worktrees per agent; tmux sessions for persistence
- **Human Gates:** Manual review at planning & development stages
- **Autonomy:** Stages 1, 2, 4, 5 run without human intervention

## Skills & Commands

| Command | Purpose | Status |
|---------|---------|--------|
| `/sf-feedback` | Capture user feedback → create GitHub issue | 📋 TODO |
| `/sf-tospecs` | Auto-generate specs from issue | 🔨 In Development |
| `/sf-totickets` | Break specs into implementation tickets | 📋 TODO |
| `/sf-plan` | Generate implementation plan (requires approval) | 📋 TODO |
| `/sf-dev` | Implement from plan (manual iteration loop) | 📋 TODO |
| `/sf-test` | Run tests, deploy to staging | 📋 TODO |
| `/sf-prod` | Deploy to production | 📋 TODO |

## Repository Structure

```
softwarefactory/
├── README.md                              # This file
├── docs/                                  # Documentation
│   ├── 2026.07.26.Software_Factory_Design.md  # Full design document
│   ├── architecture/                      # Architecture docs
│   ├── runbooks/                          # Operations runbooks
│   └── examples/                          # Example workflows
├── skills/                                # Claude Code skills
│   ├── sf-feedback/
│   ├── sf-tospecs/
│   ├── sf-totickets/
│   ├── sf-plan/
│   ├── sf-dev/
│   ├── sf-test/
│   └── sf-prod/
├── scripts/                               # Helper scripts
│   ├── setup.sh                           # Initial setup
│   ├── feedback-endpoint.js               # Feedback ingestion webhook
│   └── cleanup.sh                         # Worktree & tmux cleanup
└── CLAUDE.md                              # Project instructions for Claude Code
```

## Development Roadmap

### Phase 1: Foundation (Weeks 1–2)
- [ ] Feedback endpoint (HTTP + CLI)
- [ ] `/sf-tospecs` skill (spec generation)
- [ ] GitHub label schema
- [ ] End-to-end test: feedback → issue → spec

### Phase 2: Autonomous Pipeline (Weeks 3–4)
- [ ] `/sf-totickets` skill
- [ ] `/sf-test` skill
- [ ] `/sf-prod` skill
- [ ] Slack integration

### Phase 3: Manual Gates (Weeks 5–6)
- [ ] `/sf-plan` skill (with tmux + approval)
- [ ] `/sf-dev` skill (with iteration loop)
- [ ] Full end-to-end test

### Phase 4: Hardening (Weeks 7–8)
- [ ] Error handling & rollback
- [ ] Monitoring & observability
- [ ] Cleanup automation
- [ ] Documentation

## Contributing

This is David's personal research project. Design input welcome; feature contributions follow the project roadmap.

## Questions?

See the design document for detailed architecture, advantages/disadvantages, and open questions.
