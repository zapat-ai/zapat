# Zapat

Zapat is an autonomous dev pipeline framework powered by Claude Code. It triages GitHub issues, implements features, runs tests, reviews code, and auto-merges -- all triggered by a single label.

## Getting Started

If `.env` does not exist, run `/zapat` (from the repo) or `/zapat:setup` (from the plugin) to configure Zapat for your project.

If already configured, run `/pipeline-check` or `/zapat:pipeline-check` to verify everything is healthy.

## Quick Reference

### Labels

| Label | Description |
|-------|-------------|
| `agent` | Let the pipeline handle this (works on issues and PRs) |
| `agent-work` | Skip triage, implement immediately |
| `agent-research` | Research and analyze, don't code |
| `agent-write-tests` | Write tests for the specified code |
| `hold` | Block auto-merge on this PR |
| `human-only` | Pipeline should not touch this |

Status labels are managed automatically by the pipeline:

| Label | Meaning |
|-------|---------|
| `zapat-triaging` | Triage in progress |
| `zapat-implementing` | Implementation in progress |
| `zapat-review` | Code review pending |
| `zapat-testing` | Tests running |
| `zapat-rework` | Addressing review feedback |
| `needs-rebase` | Auto-rebase failed due to conflicts (manual resolution needed) |

### CLI Commands

| Command | Description |
|---------|-------------|
| `bin/zapat status` | Pipeline overview (active sessions, recent jobs, success rate) |
| `bin/zapat health` | Run health checks on all pipeline components |
| `bin/zapat health --auto-fix` | Auto-repair common issues (orphaned worktrees, stale slots) |
| `bin/zapat metrics query --days 7` | Query job metrics for the last N days |
| `bin/zapat risk REPO PR_NUM` | Classify risk level of a pull request |
| `bin/zapat dashboard` | Launch the Next.js monitoring dashboard |
| `bin/zapat logs rotate` | Rotate and compress old log files |

### Skills (project-scoped)

| Skill | Description |
|-------|-------------|
| `/zapat` | Configure Zapat for your project (interactive wizard) |
| `/add-repo` | Add a new repository to monitor |
| `/pipeline-check` | Quick health check with plain-language results |

### Skills (plugin — available globally after `claude plugin install`)

| Skill | Description |
|-------|-------------|
| `/zapat:setup` | Configure Zapat for your project (interactive wizard) |
| `/zapat:add-repo` | Add a new repository to monitor |
| `/zapat:pipeline-check` | Quick health check with plain-language results |

## Architecture

```
GitHub Issue (labeled) --> Poller (every 2 min) --> Trigger Script --> Claude Code Agent Team --> PR --> Review Agent Team --> Auto-Merge Gate
```

**Flow:**
1. The cron-based poller (`bin/poll-github.sh`) scans configured repos for issues/PRs with pipeline labels.
2. When found, it dispatches the appropriate trigger script (`triggers/on-new-issue.sh`, `triggers/on-work-issue.sh`, etc.) in a background tmux session.
3. The trigger script launches Claude Code with a team of specialized agent personas that collaborate to complete the task.
4. For implementations, the builder agent works in an isolated git worktree, creates a PR, and the pipeline auto-labels it for review and testing.
5. The auto-merge gate evaluates risk (low/medium/high) and merges if all checks pass.
6. When a PR merges and `main` moves forward, the auto-rebase system detects stale `agent/*` PRs and rebases them automatically. On conflict, it adds the `needs-rebase` label and posts details.

**Key directories:**

| Directory | Purpose |
|-----------|---------|
| `bin/` | Pipeline CLI and core scripts (poller, startup, notifications) |
| `triggers/` | Event handlers that launch agent teams |
| `prompts/` | Prompt templates for each job type |
| `agents/` | Agent persona definitions (copied to `~/.claude/agents/`) |
| `lib/` | Shared shell libraries (state machine, tmux helpers, common utilities) |
| `src/` | Node.js source for the pipeline CLI |
| `config/` | Repository and agent configuration |
| `dashboard/` | Next.js monitoring dashboard |
| `state/` | Runtime state (items, slots, locks, PIDs) |
| `logs/` | Job logs and structured metrics |
| `data/` | Metrics data (JSONL) |

## Agent Team Recipes

Every task uses a team of specialized agents. The roles are defined in `config/agents.conf` and map to persona files in `agents/`.

### Implementation Team
When implementing a feature (`agent-work` label):
- **builder** (from agents.conf) -- reads the codebase, implements the feature, writes tests
- **security** (from agents.conf) -- reviews for vulnerabilities, auth issues, injection risks
- **product** (from agents.conf) -- validates the implementation meets requirements
- **ux** (from agents.conf) -- reviews user-facing changes for usability

### Code Review Team
When reviewing a PR (`agent` label on PR):
- **security** -- security-focused review
- **builder** -- code quality, architecture, test coverage
- **ux** -- UX implications of the changes

### Research Team
When investigating a topic (`agent-research` label):
- **product** -- defines research scope and success criteria
- **builder** -- technical investigation and feasibility
- **security** -- security implications and risks

### Triage Team
When triaging a new issue (`agent` label):
- All four core roles collaborate to assess complexity, priority, security concerns, and recommended approach.

### Bug Investigation Team
When debugging a complex issue, spin up parallel hypothesis investigators:
- **hypothesis-1** (builder) -- investigate theory A (e.g., frontend rendering)
- **hypothesis-2** (builder) -- investigate theory B (e.g., backend API response)
- **hypothesis-3** (security) -- investigate theory C (e.g., auth/session issue)
Each investigates independently, shares findings, and tries to disprove each other's theories.

### Full-Stack Feature Team
When a feature spans backend + frontend (or multiple repos):
- **backend-engineer** (builder) -- builds API endpoints, database changes
- **frontend-engineer** (builder) -- consumes the API from the web/mobile app
- **security** -- reviews the entire data flow end-to-end
- **product** -- validates the feature meets requirements across layers
Assign different repos to different agents to avoid file conflicts. Backend builds the API first and shares the contract.

## Troubleshooting

**Nothing happens after labeling an issue:**
```bash
bin/zapat health          # Check for issues
bin/zapat status          # Verify poller is running
tail -20 logs/cron-poll.log  # Check poller logs
```

**Agent session timed out:**
Check the job log in `logs/`. The item will auto-retry with exponential backoff (10 min, 30 min, then abandon).

**Orphaned worktrees or stale slots:**
```bash
bin/zapat health --auto-fix
```
This also runs automatically every poll cycle.

**Dashboard not loading:**
```bash
lsof -i :8080              # Check if process is running
bin/startup.sh             # Restart everything
```

**GitHub auth errors:**
```bash
gh auth status             # Check current auth
gh auth login              # Re-authenticate
```

## Customization

### Adding repositories
Edit `config/repos.conf` or run the `/add-repo` skill. Format: `owner/repo<TAB>local_path<TAB>type`.

### Adding agent personas
1. Create a `.md` file in `agents/` following the format of existing personas.
2. Add a role mapping in `config/agents.conf` (e.g., `compliance=healthcare-advisor`).
3. Run `cp agents/*.md ~/.claude/agents/` to deploy.

### Modifying prompts
Edit files in `prompts/`. Templates use `{{PLACEHOLDER}}` syntax that gets substituted at runtime by `lib/common.sh`. Available placeholders include `{{REPO}}`, `{{ISSUE_NUMBER}}`, `{{PR_NUMBER}}`, `{{BRANCH}}`, and others.

### Enabling compliance mode
Set `ENABLE_COMPLIANCE_MODE=true` in `.env` and add a compliance agent persona:
1. Create `agents/compliance-advisor.md` with domain-specific rules.
2. Add `compliance=compliance-advisor` to `config/agents.conf`.
3. The pipeline will consult the compliance persona during reviews and before auto-merge.

### Shared agent memory
Agents share knowledge via files in `~/.claude/agent-memory/_shared/`:
- `DECISIONS.md` -- architectural decisions agents should follow
- `CODEBASE.md` -- cross-repo patterns and conventions
- `PIPELINE.md` -- pipeline state and known issues

Edit these files to give agents persistent context about your project.
