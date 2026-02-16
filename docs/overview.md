# Zapat Framework Overview

**An autonomous development pipeline powered by Claude Code agent teams.**

Label a GitHub issue. Walk away. Come back to a tested, reviewed, merge-ready PR.

---

## How It Works

```
 GitHub Issue                                                    Merged PR
 (labeled)                                                       (auto)
     │                                                              ▲
     ▼                                                              │
 ┌────────┐    ┌───────────┐    ┌──────────┐    ┌────────┐    ┌────────┐
 │ Triage │───▶│ Implement │───▶│   Test   │───▶│ Review │───▶│  Merge │
 │ 4 agents│   │  5 agents │    │ 1 agent  │    │4 agents│    │  Gate  │
 └────────┘    └───────────┘    └──────────┘    └────────┘    └────────┘
  10 min        30 min           20 min          10 min        risk-based
```

A cron job polls GitHub every 2 minutes. When it finds a labeled issue or PR, it dispatches a **multi-agent team** in a background tmux session. Each stage uses specialized expert personas -- engineers, security reviewers, product managers, UX critics -- that debate, review each other's work, and converge on a result.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Always-On Host (macOS/Linux)                 │
│                                                                 │
│  ┌──────────────┐     ┌──────────────┐     ┌────────────────┐  │
│  │  Cron (2min) │────▶│ poll-github  │────▶│  Trigger       │  │
│  └──────────────┘     │   .sh        │     │  Scripts       │  │
│                       │              │     │                │  │
│                       │ • Scan repos │     │ • on-new-issue │  │
│                       │ • Check deps │     │ • on-work-issue│  │
│                       │ • Auto-rework│     │ • on-new-pr    │  │
│                       │ • Auto-merge │     │ • on-rework-pr │  │
│                       │ • Retry sweep│     │ • on-test-pr   │  │
│                       │ • Health fix │     │ • on-research  │  │
│                       └──────────────┘     └───────┬────────┘  │
│                                                    │           │
│                                            ┌───────▼────────┐  │
│  ┌──────────────┐     ┌──────────────┐     │  Claude Code   │  │
│  │  Dashboard   │     │  Pipeline    │     │  Agent Teams   │  │
│  │  (Next.js)   │     │  CLI         │     │                │  │
│  │              │     │              │     │ ┌────────────┐ │  │
│  │ • Kanban     │     │ • status     │     │ │  Builder   │ │  │
│  │ • Charts     │     │ • health     │     │ │  Security  │ │  │
│  │ • Activity   │     │ • metrics    │     │ │  UX Critic │ │  │
│  │ • Health     │     │ • risk       │     │ │  Product   │ │  │
│  └──────────────┘     │ • dashboard  │     │ │  Product   │ │  │
│                       │ • logs       │     │ └────────────┘ │  │
│                       └──────────────┘     └────────────────┘  │
│                                                                 │
│  ┌──────────────┐     ┌──────────────┐     ┌────────────────┐  │
│  │ Shared Memory│     │ State Machine│     │  Notifications │  │
│  │ (cross-agent)│     │ (retries)    │     │  (Slack)       │  │
│  └──────────────┘     └──────────────┘     └────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Components

| Component | What It Does |
|-----------|-------------|
| **Poll Loop** | Scans GitHub repos every 2 min for labeled issues/PRs, dispatches agents |
| **Trigger Scripts** | 7 scripts that launch Claude agent teams for triage, implementation, testing, review, rework, research, and test-writing |
| **Agent Personas** | Expert personas (engineer, security, UX, product, and optional domain-specific roles) with deep domain prompts |
| **Agent Teams** | Every task uses 3-5 agents that collaborate — implementation gets a builder + 4 reviewers |
| **State Machine** | Tracks each item through pending → running → completed/failed with exponential-backoff retries (10min → 30min → abandoned) |
| **Risk Classifier** | Scores PRs by files touched, changeset size, repo type, and labels to determine merge safety |
| **Auto-Merge Gate** | Low risk: merge immediately. Medium risk: 4-hour delay. High risk: require human review |
| **Pipeline CLI** | `bin/zapat` with subcommands: status, health, metrics, risk, dashboard, logs |
| **Dashboard** | Next.js app with real-time Kanban board, success rate charts, health monitoring |
| **Self-Healing** | Every poll cycle runs health auto-fix: cleans orphaned worktrees, stale slots, dead sessions |
| **Shared Memory** | Agents share architectural decisions, codebase patterns, and pipeline state across sessions |
| **Notifications** | Slack alerts for every job (success/failure) + emergency alerts when the pipeline is down |

---

## Safety & Guardrails

- **Governance**: Items with `human-only` label or any assignee are skipped
- **Dependency blocking**: Issues specify `**Blocked By:** #X` to enforce ordering
- **Concurrency cap**: Max 10 parallel agent sessions (slot-based with PID tracking)
- **Timeouts**: Every session has a hard timeout (10-30 min) enforced by tmux monitor
- **Hold label**: Add `hold` to any PR to block auto-merge indefinitely
- **Atomic locking**: Directory-based locks prevent concurrent poll runs
- **Git worktrees**: Each implementation runs in an isolated `/tmp/` worktree — never touches the main checkout

---

## What You Need

- **Always-on macOS or Linux machine** (Mac Mini, cloud VM, home server, etc.)
- **Claude Code CLI** with API key
- **GitHub CLI** (`gh`) authenticated
- **tmux** for session management
- **Slack webhook** for notifications (optional)
- **Repos** cloned locally and listed in `config/repos.conf`

---

## Numbers

| Metric | Value |
|--------|-------|
| Lines of code | ~10,000 (shell + Node.js) |
| Agent personas | 4 core + custom |
| Team recipes | 20 |
| Trigger scripts | 7 |
| Prompt templates | 12 |
| Pipeline CLI commands | 6 |
| Max parallel agents | 10 |
| Poll interval | 2 minutes |
| Triage time | ~10 minutes |
| Implementation time | ~30 minutes |
| Review time | ~10 minutes |

---

*Shell for orchestration. Node.js for data. Agents for judgment.*
