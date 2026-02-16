# Introduction to Zapat

You write a GitHub issue. You add a label. An hour later, a tested, reviewed, merge-ready pull request appears. No human reviewer needed. No context switching. No waiting.

That's Zapat.

---

## What is Zapat?

Zapat is an autonomous development pipeline that turns GitHub issues into merged pull requests using teams of AI agents powered by [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

When you label an issue, Zapat assembles a team of specialized agents -- a software engineer, a security reviewer, a product manager, and a UX critic. They collaborate on the task in real time, just like a human team would: the engineer writes code while the reviewers audit it, catch problems, and request changes. When the team converges on a result, they disband and the next stage takes over.

Zapat isn't a single AI assistant writing code. It's a **pipeline** -- a sequence of purpose-built teams that triage, implement, test, review, and merge, each operating independently with fresh context and specific expertise.

## The Problem

Engineering teams lose enormous amounts of time to the mechanics of shipping code, not the engineering itself.

**Code review bottlenecks.** A developer finishes a feature at 4 PM. The reviewer is in meetings until tomorrow. The PR sits idle for 18 hours. Multiply that across every PR, every developer, every week.

**Context switching.** Reviewing someone else's code means loading their mental model into your head -- understanding the problem, the approach, the tradeoffs. By the time you're done reviewing, you've lost your own flow state.

**Slow PR cycles.** Review feedback arrives a day later. The author has moved on to something else. They context-switch back, address the feedback, push again. Another day passes waiting for re-review. A feature that took 2 hours to build takes a week to ship.

**Triage overhead.** New issues pile up. Someone has to read each one, assess complexity, check for security implications, assign priority, and route it to the right person. This meta-work eats hours every week and still results in inconsistent assessments.

Zapat eliminates these bottlenecks by automating the entire pipeline from issue to merge, while keeping humans in control of what gets automated and what doesn't.

## How It Works

```
 GitHub Issue                                                    Merged PR
 (you add a label)                                               (automatic)
     |                                                              ^
     v                                                              |
 +--------+    +-----------+    +--------+    +--------+    +-------+
 | Triage |--->| Implement |--->|  Test  |--->| Review |--->| Merge |
 | team   |    |   team    |    |  team  |    |  team  |    | Gate  |
 +--------+    +-----------+    +--------+    +--------+    +-------+
  assembles     assembles        assembles     assembles     risk-based
  works         works            works          works        auto-merge
  disbands      disbands         disbands       disbands
```

Here's the lifecycle of a typical issue:

1. **You create an issue** describing a feature, bug fix, or task. You add the `agent` label. That's your only job.

2. **Triage team assembles** (4 agents, ~10 minutes). They analyze the issue's complexity, security implications, priority, and recommended approach. If it's ready for implementation, they add the `agent-work` label and disband.

3. **Implementation team assembles** (4-5 agents, ~30 minutes). A builder agent works in an isolated git worktree -- it never touches your main checkout. While the builder writes code and tests, a security reviewer audits for vulnerabilities, a product manager validates scope, and a UX critic evaluates the experience. They iterate until all reviewers approve, then the builder opens a PR and the team disbands.

4. **Test team assembles** (~20 minutes). Runs the full test suite, verifies the build, and posts results.

5. **Review team assembles** (3-4 agents, ~10 minutes). A fresh set of agents reviews the PR from scratch -- security, code quality, architecture, UX implications. They post a structured review with a risk classification: low, medium, or high.

6. **Auto-merge gate** evaluates the risk score and acts:
   - **Low risk:** merge immediately.
   - **Medium risk:** merge after a configurable delay (default: 4 hours).
   - **High risk:** require human approval.

Total time from label to merge: about one hour for a typical feature. Each team exists only for the duration of its task -- no idle agents, no wasted compute.

## Key Features

### Label-driven workflow

Everything is controlled through GitHub labels. No new tools to learn, no dashboards to check, no commands to memorize. Add a label, and the pipeline handles the rest.

| Label | What happens |
|-------|-------------|
| `agent` | Full pipeline: triage, implement, test, review, merge |
| `agent-work` | Skip triage, implement immediately |
| `agent-research` | Research and analyze -- no code changes |
| `agent-write-tests` | Generate tests for existing code |
| `hold` | Block auto-merge on a PR |
| `human-only` | Pipeline ignores this item |

### Collaborative agent teams

Every task uses a team of 3-5 agents with distinct expertise. They don't work sequentially -- they collaborate in real time, catching issues early instead of in review. The four core personas are:

- **Builder** -- reads the codebase, implements features, writes tests.
- **Security reviewer** -- audits for vulnerabilities, injection risks, auth issues.
- **Product manager** -- validates that the implementation meets requirements.
- **UX critic** -- reviews user-facing changes for usability.

You can add custom personas for your domain (database engineer, compliance advisor, accessibility expert) by dropping a markdown file in the `agents/` directory.

### Risk-based auto-merge

Not all changes are equal. Zapat classifies every PR by risk -- based on files touched, changeset size, repository type, and labels -- and applies the appropriate merge strategy. Low-risk PRs merge immediately. High-risk PRs wait for a human.

### Multi-repo support

A single Zapat installation can manage multiple repositories across your organization. Each repo can have its own type classification (backend, web, mobile, etc.) that affects how agents review and merge changes. You can also group repos into projects, each with their own agent configuration, environment overrides, and project context.

### Dependency ordering

For multi-part features, issues can declare dependencies:

```
**Blocked By:** #45, #46
```

Zapat respects these, ensuring issues are implemented in the right order. You can also define interface contracts in issues so agents working on related services produce compatible APIs.

### Self-healing pipeline

Every poll cycle, Zapat automatically cleans up orphaned git worktrees, stale concurrency slots, and dead agent sessions. Failed jobs retry with exponential backoff (10 minutes, then 30 minutes, then abandon). The `bin/zapat health` command gives you a quick status check, and `--auto-fix` repairs common issues.

### Compliance mode

For regulated industries (healthcare, finance, government), enable compliance mode to add a compliance reviewer to every team. The compliance agent checks for domain-specific violations (HIPAA, PCI DSS, SOC 2) and can block auto-merge when it finds issues.

## Getting Started

### Option A: Install as a Claude Code plugin (recommended)

```bash
# Add the marketplace and install
claude plugin marketplace add zapat-ai/zapat
claude plugin install zapat

# Open Claude Code in any project and run the setup wizard
claude
/zapat:setup
```

### Option B: Clone and run locally

```bash
git clone https://github.com/zapat-ai/zapat.git
cd zapat
claude
/zapat
```

Both paths launch an interactive setup wizard that configures your repositories, agents, notifications, and starts the pipeline. Once running, label any GitHub issue with `agent` and Zapat takes it from there.

### Requirements

Zapat runs on any always-on macOS or Linux machine. You'll need:

- **Claude Code CLI** (latest)
- **GitHub CLI** (`gh`) authenticated with your org
- **tmux** for agent session management
- **Node.js 18+** for the pipeline CLI and dashboard
- **jq** for JSON processing

See the [README](../README.md) for detailed installation instructions per platform.

### A note on resources

Zapat runs multiple agents concurrently. A single pipeline job can spin up 4+ agents in parallel, and multiple jobs can run simultaneously. We recommend running Zapat on a **dedicated machine** (Mac Mini, Linux server, or cloud instance) rather than a laptop you use for daily work. Monitor your Claude API usage or subscription quota, and use `MAX_CONCURRENT_WORK` in `.env` to limit parallelism.

## Use Cases

### Solo developer

You're a solo dev with more ideas than hours. You write issues describing features you want, label them `agent`, and go back to the work that needs your brain. Zapat handles the mechanical parts -- scaffolding new endpoints, writing boilerplate, adding test coverage -- while you focus on architecture and the tricky problems.

**Typical workflow:** Write 3-5 issues on Monday morning. Label them `agent`. By end of day, you have PRs to review (or they've already merged if they're low-risk). Your week of work gets compressed into a day.

### Small team (3-10 engineers)

Your team is productive but drowning in PR reviews. Every developer spends 1-2 hours a day reviewing each other's code, and PRs still take 24-48 hours to merge. Zapat handles the first pass -- catching bugs, security issues, and style violations -- so human reviewers can focus on high-level design decisions.

**Typical workflow:** The team uses `agent-work` for well-defined tickets (bug fixes, small features, test coverage). Complex features are still human-implemented, but the PR review is handled by Zapat's review team. A human glances at the review summary and merges or requests changes. PR cycle time drops from days to hours.

### Enterprise / regulated environments

Your org has strict compliance requirements. Every code change needs security review, and certain domains (payments, auth, PII handling) need specialized review. Enable compliance mode, add domain-specific personas, and Zapat ensures every change is reviewed against your regulatory requirements before it can merge.

**Typical workflow:** High-risk PRs (auth, payments, schema changes) are flagged for human approval with a detailed compliance report. Low-risk PRs (docs, config, UI tweaks) flow through automatically. The compliance agent catches issues that humans might miss after reading their 15th PR of the day.

## Customization

Zapat is designed to be adapted to your project. The main areas of customization:

- **Agent personas** -- Create new expert personas (database engineer, accessibility reviewer, compliance advisor) by adding markdown files to `agents/`. See the [Customization Guide](customization.md) for the persona file format and tips.

- **Prompt templates** -- Modify the instructions agents receive for each task type by editing files in `prompts/`. Templates use `{{PLACEHOLDER}}` syntax for runtime substitution.

- **Team recipes** -- Change which agents collaborate on each task by editing the team definitions in prompt templates. Add a QA engineer to the implementation team, or a compliance reviewer to the merge gate.

- **Repository configuration** -- Add repos to `config/repos.conf` or use the `/add-repo` skill. Group repos into projects with independent settings.

- **Merge policy** -- Tune risk thresholds, delay timers, and which risk levels require human approval via `.env`.

- **Shared agent memory** -- Give agents persistent knowledge about your architecture, conventions, and known issues via files in `~/.claude/agent-memory/_shared/`.

## Where to Go Next

| Document | What it covers |
|----------|---------------|
| [Framework Overview](overview.md) | Architecture diagrams, component details, safety guardrails |
| [Usage Guide](usage-guide.md) | Practical examples: setup, daily use, CLI commands, troubleshooting |
| [Customization Guide](customization.md) | Custom personas, compliance mode, new triggers, team recipes |
| [Linux Setup](linux-setup.md) | Linux-specific installation and configuration |
| [README](../README.md) | Quick reference for labels, CLI commands, and project structure |

---

*Zapat is MIT licensed and open source. Found a bug or have a feature request? [Open an issue](https://github.com/zapat-ai/zapat/issues).*
