# Zapat

**On-demand AI dev teams, powered by Claude Code.**

Label a GitHub issue. An AI team assembles itself -- engineers, security reviewers, product managers, UX critics -- implements the feature, tests it, reviews its own work, and opens a merge-ready PR. When the work is done, the team disbands. No scheduling. No idle seats.

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

Each stage spins up a purpose-built team of Claude Code agents. They collaborate in real time -- the builder writes code while the security reviewer audits it, the product manager validates scope, and the UX critic checks the experience. When they converge on a result, the team dissolves and the next stage takes over. Your entire dev pipeline runs itself, from issue to merged PR, in about an hour.

## Quick Start

### Option A: Install as a Claude Code plugin (recommended)

```bash
# 1. Add the marketplace
claude plugin marketplace add zapat-ai/zapat

# 2. Install the plugin
claude plugin install zapat

# 3. Open Claude Code in any project
claude

# 4. Run the setup wizard
/zapat:setup
```

The setup wizard clones Zapat, configures your repos, agents, and notifications, and starts the pipeline. Once running, label any GitHub issue with `agent` and Zapat handles it.

### Option B: Clone and run locally

```bash
# 1. Clone the repo
git clone https://github.com/zapat-ai/zapat.git
cd zapat

# 2. Open Claude Code
claude

# 3. Run the setup wizard
/zapat
```

The `/zapat` skill walks you through the same setup process from inside the cloned repo.

## Requirements

| Tool | Version | macOS | Linux |
|------|---------|-------|-------|
| tmux | any | `brew install tmux` | `sudo apt install tmux` |
| jq | any | `brew install jq` | `sudo apt install jq` |
| gh (GitHub CLI) | 2.0+ | `brew install gh` | [Install guide](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) |
| Node.js | 18+ | `brew install node` | `sudo apt install nodejs npm` |
| git | 2.20+ | `brew install git` | `sudo apt install git` |
| Claude Code CLI | latest | `npm install -g @anthropic-ai/claude-code` | same |

Runs on any always-on macOS or Linux machine.

## Important: Resource & Cost Considerations

Zapat runs multiple Claude Code agents concurrently -- a single pipeline job can spin up 4+ agents working in parallel. Before deploying, understand what this means for your setup:

**Compute:** Each Claude Code agent is a separate process. When several jobs run simultaneously (e.g., one issue being implemented while another is being reviewed), your machine may have 8-12+ agents active at once. This will saturate CPU and memory on a laptop or shared workstation. **We strongly recommend running Zapat on a dedicated machine** -- a Mac Mini, a Linux server, or a cloud instance that isn't used for your daily work.

**API usage:** Every agent call uses Claude tokens. A typical issue-to-merge pipeline (triage + implement + review + test) consumes significant token volume.

- **Claude Code subscription (Max/Team/Enterprise):** You get a usage quota rather than per-token billing. Monitor your usage patterns in your account dashboard to ensure you stay within your plan's limits. Zapat's concurrent agents can consume quota quickly.
- **Anthropic API (pay-per-token):** Set spending limits in your [Anthropic Console](https://console.anthropic.com/) to avoid surprises.

Either way:
- Use `CLAUDE_MODEL` in `.env` or per-project `project.env` to choose cost-appropriate models (e.g., Sonnet for routine work, Opus for complex reasoning)
- Adjust `MAX_CONCURRENT_WORK` in `.env` to limit how many jobs run simultaneously

**Rate limits:** The poller makes GitHub API calls every 2 minutes across all configured repos. With many repos or rapid labeling, you may hit GitHub's rate limit (5,000 requests/hour for authenticated users). The poller detects this and backs off automatically, but be mindful of your usage.

## How It Works

1. **You** add the `agent` label to a GitHub issue. That's your only job.
2. **Poller** (runs every 2 min via cron) detects the label and kicks off the pipeline.
3. **Triage team assembles** -- 4 agents analyze complexity, priority, security concerns, and post a structured assessment. If ready, they auto-label it for implementation and disband.
4. **Builder team assembles** -- an engineer, security reviewer, product manager, and UX critic spin up around an isolated git worktree. The engineer implements while the others review in real time. They iterate until all reviewers approve, then the engineer opens a PR and the team disbands.
5. **Review team assembles** -- a fresh set of agents reviews the PR from scratch (security, code quality, UX). They post a structured review with risk classification, then disband.
6. **Test team assembles** -- runs the full test suite, verifies the build, posts results, disbands.
7. **Auto-merge gate** evaluates risk and merges:
   - Low risk: merge immediately
   - Medium risk: merge after a configurable delay (default 4 hours)
   - High risk: require human approval

Total time from label to merge: about 1 hour for a typical feature. Each team exists only for the duration of its task -- no idle agents, no wasted compute. Your human effort: write the issue, add one label.

## Labels

| Label | What happens |
|-------|-------------|
| `agent` | Triage team analyzes the issue, then routes it to the right workflow |
| `agent-work` | Skip triage, go straight to implementation |
| `agent-research` | Research and analyze -- no code changes |
| `agent-write-tests` | Write tests for the specified code |
| `hold` | Block auto-merge on a PR |
| `human-only` | Pipeline ignores this item entirely |

### Internal (auto-managed by the pipeline)

| Label | Meaning |
|-------|---------|
| `zapat-triaging` | Triage in progress |
| `zapat-implementing` | Implementation in progress |
| `zapat-review` | Code review in progress |
| `zapat-testing` | Tests running |
| `zapat-rework` | Addressing review feedback |
| `needs-rebase` | Auto-rebase failed, manual resolution needed |

You never need to add internal labels -- the pipeline manages them automatically.

## CLI

Zapat includes a CLI for monitoring and managing the pipeline.

```bash
# Pipeline overview: active sessions, recent jobs, success rate
bin/zapat status

# Health checks on all components
bin/zapat health

# Auto-repair common issues (orphaned worktrees, stale slots, dead sessions)
bin/zapat health --auto-fix

# Query job metrics
bin/zapat metrics query --days 7
bin/zapat metrics query --last-hour --status failure

# Classify PR risk before merging
bin/zapat risk your-org/backend 42

# Launch the monitoring dashboard
bin/zapat dashboard

# Rotate and compress old logs
bin/zapat logs rotate
```

## Claude Code Skills

Zapat provides Claude Code skills that work in two ways:

**As a plugin** (installed via `claude plugin install`):

| Skill | Description |
|-------|-------------|
| `/zapat:setup` | Interactive configuration wizard |
| `/zapat:add-repo` | Add a new repository |
| `/zapat:pipeline-check` | Quick health check with suggestions |

**From inside the cloned repo** (project-scoped):

| Skill | Description |
|-------|-------------|
| `/zapat` | Interactive configuration wizard |
| `/add-repo` | Add a new repository |
| `/pipeline-check` | Quick health check with suggestions |

## Controlling the Pipeline

**Pause a specific item:** Assign someone to the issue. Items with assignees are skipped.

**Block auto-merge:** Add the `hold` label to the PR.

**Skip an issue:** Add the `human-only` label.

**Order dependent work:** In the issue body, add:
```
**Blocked By:** #45, #46
```
The pipeline waits until the blocking issues are closed.

**Target a feature branch:** In the issue body, add:
```
**Target Branch:** feature/dark-mode
```
The agent branches off `feature/dark-mode` instead of `main`.

**Provide interface contracts:** For multi-part features, add to the issue body:
```markdown
## Interface Contract
### UserService (from issue #45)
- createUser(data: UserInput): Promise<User>
- getUser(id: string): Promise<User | null>
```
This prevents API mismatches when agents work on related issues concurrently.

## Customization

### Adding repositories

Edit `config/repos.conf` or use the `/add-repo` skill:
```
# owner/repo          local_path                    type
your-org/backend      /home/you/code/backend        backend
your-org/web-app      /home/you/code/web-app        web
```

### Multiple projects

A single Zapat installation can manage multiple independent projects. Each project gets its own repos, agent roles, context, and environment overrides.

Create a project directory under `config/`:

```
config/
  my-saas/
    repos.conf              # Repos for this project
    agents.conf             # Agent roles (optional, falls back to global)
    project-context.txt     # Project description injected into agent prompts
    project.env             # Env overrides (model, timeouts, etc.)
  mobile-app/
    repos.conf
    project-context.txt
    project.env
```

Or use the CLI:

```bash
bin/zapat projects           # List configured projects
```

The poller automatically discovers project directories and polls each one independently. Each project's `project.env` layers on top of the global `.env`, so you can use a different model or timeout per project:

```bash
# config/mobile-app/project.env
CLAUDE_MODEL=claude-sonnet-4-5-20250929
TIMEOUT_IMPLEMENT=2400
```

Agents receive the project's `project-context.txt` as `{{PROJECT_CONTEXT}}` in their prompts, so they understand the architecture and conventions of the project they're working on.

A repo can only belong to one project. If you only have one project, the setup wizard handles everything -- no need to create subdirectories manually.

### Adding agent personas

1. Create a `.md` file in `agents/` (see existing personas for the format).
2. Map it in `config/agents.conf`: `compliance=your-persona-name`
3. Copy to Claude's agent dir: `cp agents/*.md ~/.claude/agents/`

### Modifying prompts

Edit files in `prompts/`. Templates use `{{PLACEHOLDER}}` syntax for runtime substitution. See `lib/common.sh` for available placeholders.

### Compliance mode

For regulated industries (healthcare, finance), set `ENABLE_COMPLIANCE_MODE=true` in `.env` and add a compliance persona to `config/agents.conf`. The pipeline will consult the compliance agent during reviews and before auto-merge.

### Shared agent memory

Agents share persistent context via `~/.claude/agent-memory/_shared/`:
- `DECISIONS.md` -- architectural decisions
- `CODEBASE.md` -- cross-repo patterns and conventions
- `PIPELINE.md` -- pipeline operational state

Edit these to give agents knowledge about your project's architecture, conventions, and constraints.

## Architecture

```
zapat/
  bin/              Pipeline CLI and core scripts
    zapat           Node.js CLI (status, health, metrics, risk, dashboard, logs)
    poll-github.sh  Cron-driven poller that scans repos and dispatches agents
    startup.sh      Creates tmux session, installs cron, starts dashboard
    run-agent.sh    Runs Claude Code in non-interactive mode for scheduled jobs
    notify.sh       Slack notifications
    setup-labels.sh Creates required GitHub labels on configured repos
  triggers/         Event handlers launched by the poller
    on-new-issue.sh      Triage a new issue
    on-work-issue.sh     Implement a feature
    on-new-pr.sh         Review a PR
    on-rework-pr.sh      Fix review feedback
    on-rebase-pr.sh      Auto-rebase stale PRs
    on-test-pr.sh        Run tests on a PR
    on-research-issue.sh Research and strategy tasks
    on-write-tests.sh    Write missing tests
  jobs/             Scheduled cron jobs
    daily-standup.sh     Daily activity summary (Mon-Fri)
    weekly-planning.sh   Weekly planning digest
    monthly-strategy.sh  Monthly strategy review
  prompts/          Prompt templates for each job type
  agents/           Agent persona definitions
  lib/              Shared shell libraries
    common.sh       Utilities, logging, prompt substitution
    item-state.sh   State machine (pending -> running -> completed/failed)
    tmux-helpers.sh Tmux session and window management
  plugins/          Claude Code plugin (marketplace format)
    zapat/          The Zapat plugin (commands, plugin.json)
  src/              Node.js source for the pipeline CLI
  config/           Repository and agent configuration (from examples)
  dashboard/        Next.js monitoring dashboard
  state/            Runtime state (items, slots, locks, PIDs)
  logs/             Job logs and structured event logs
  data/             Metrics data (JSONL format)
  docs/             Documentation
```

## License

MIT -- see [LICENSE](LICENSE).
