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
| `agent-plan` | Proposed work, pending human approval (not auto-implemented) |
| `agent-phase-2` | Phase 2 work, awaiting Phase 1 completion |
| `agent-phase-3` | Phase 3 work, awaiting Phase 2 completion |
| `hold` | Block auto-merge on this PR |
| `human-only` | Pipeline should not touch this |
| `agent-full-review` | Force full team review regardless of complexity |
| `codex` | Process with OpenAI Codex |
| `claude` | Process with Claude Code |

Status labels are managed automatically by the pipeline:

| Label | Meaning |
|-------|---------|
| `zapat-triaging` | Triage in progress |
| `zapat-implementing` | Implementation in progress |
| `zapat-review` | Code review pending |
| `zapat-testing` | Tests running |
| `zapat-researching` | Research in progress |
| `zapat-rework` | Addressing review feedback |
| `zapat-visual` | Visual verification in progress |
| `zapat-ci-fix` | CI auto-fix in progress |
| `needs-rebase` | Auto-rebase failed due to conflicts (manual resolution needed) |

Classification labels (applied during triage):

| Label | Description |
|-------|-------------|
| `feature` | New feature |
| `bug` | Bug fix |
| `tech-debt` | Technical debt |
| `security` | Security issue |
| `research` | Research task |

Priority labels (applied during triage):

| Label | Description |
|-------|-------------|
| `P0-critical` | Critical priority |
| `P1-high` | High priority |
| `P2-medium` | Medium priority |
| `P3-low` | Low priority |

### CLI Commands

| Command | Description |
|---------|-------------|
| `bin/zapat status` | Pipeline overview (active sessions, recent jobs, success rate) |
| `bin/zapat health` | Run health checks on all pipeline components |
| `bin/zapat health --auto-fix` | Auto-repair common issues (orphaned worktrees, stale slots) |
| `bin/zapat metrics query --days 7` | Query job metrics for the last N days |
| `bin/zapat risk REPO PR_NUM` | Classify risk level of a pull request |
| `bin/zapat dashboard` | Launch the Next.js monitoring dashboard |
| `bin/zapat program <issue>` | Track multi-issue progress, dependencies, and ETA |
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

> **Detailed architecture reference:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) is the single source of truth for system design — pipeline flow, state machine, label protocol, concurrency, prompt architecture, risk scoring, and extension points.

```
GitHub Issue (labeled) --> Poller (every 2 min) --> Trigger Script --> Claude Code Agent Team --> PR --> Review Agent Team --> Auto-Merge Gate
```

**Flow:**
1. The cron-based poller (`bin/poll-github.sh`) scans configured repos for issues/PRs with pipeline labels.
2. When found, it dispatches the appropriate trigger script (`triggers/on-new-issue.sh`, `triggers/on-work-issue.sh`, etc.) in a background tmux session.
3. The trigger script fetches `origin/main` and creates an isolated worktree under `~/.zapat/worktrees/` before launching agents, ensuring they always see the latest code.
4. All job types (triage, review, research, implementation, rework) run in isolated git worktrees — never touching the user's main checkout. Implementation worktrees create PRs; read-only worktrees are cleaned up after the session.
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

Every task uses a team of specialized agents. The 8 core roles are defined in `config/agents.conf` and map to persona files in `agents/`:

| Role | Persona File | Focus |
|------|-------------|-------|
| builder | `engineer.md` | Senior engineer: implements code, writes tests |
| security | `security-reviewer.md` | OWASP, injection, auth, secrets, dependency vulns |
| product | `product-manager.md` | User problems, acceptance criteria, scope validation |
| ux | `ux-reviewer.md` | Friction, accessibility, consistency |
| program | `program-manager.md` | Delivery sequencing, WIP limits, phase gates |
| devops | `devops-engineer.md` | CI/CD, IaC, reliability, rollback strategies |
| qa | `qa-engineer.md` | Adversarial testing, coverage gaps, regression prevention |
| writer | `technical-writer.md` | Accuracy-first docs, examples, changelog |

Teams are dynamically sized based on complexity classification (solo/duo/full). Not every role joins every task.

### Implementation Team
When implementing a feature (`agent-work` label):
- **builder** -- reads the codebase, implements the feature, writes tests
- **security** -- reviews for vulnerabilities, auth issues, injection risks
- **product** -- validates the implementation meets requirements
- **ux** -- reviews user-facing changes for usability
- **devops** -- joins when infrastructure/CI changes are involved
- **qa** -- joins for full-complexity tasks to verify test coverage

### Code Review Team
When reviewing a PR (`agent` label on PR):
- **security** -- security-focused review
- **builder** -- code quality, architecture, test coverage
- **ux** -- UX implications of the changes (skipped if no UI files)
- **product** -- scope validation (joins for full-complexity reviews)

### Research Team
When investigating a topic (`agent-research` label):
- **product** -- defines research scope and success criteria
- **builder** -- technical investigation and feasibility
- **security** -- security implications and risks
- **program** -- delivery sequencing for phased decomposition

### Triage Team
When triaging a new issue (`agent` label):
- **builder**, **product**, and **security** collaborate to assess complexity, priority, security concerns, and recommended approach.

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
Edit files in `prompts/`. Templates use `{{PLACEHOLDER}}` syntax that gets substituted at runtime by `lib/common.sh`. Available placeholders include `{{REPO}}`, `{{ISSUE_NUMBER}}`, `{{PR_NUMBER}}`, `{{BRANCH}}`, and others. Common repository map and safety rules are auto-appended from `prompts/_shared-footer.txt`.

### Enabling compliance mode
Set `ENABLE_COMPLIANCE_MODE=true` in `.env` and add a compliance agent persona:
1. Create `agents/compliance-advisor.md` with domain-specific rules.
2. Add `compliance=compliance-advisor` to `config/agents.conf`.
3. The pipeline will consult the compliance persona during reviews and before auto-merge.

### Prompt Caching
Claude Code automatically caches static system prompt prefixes (CLAUDE.md + agent personas) between turns. The shared footer (`prompts/_shared-footer.txt`) improves cacheability by ensuring common content is consistent across templates. No additional configuration is needed -- caching is handled by the Claude Code runtime. No `cache_creation_input_tokens` metrics are currently tracked in logs.

### Maintaining the architecture doc
When modifying the pipeline (new triggers, labels, state transitions, CLI commands), update `docs/ARCHITECTURE.md`. Run `npm test` to verify consistency.

### Shared agent memory
Agents share knowledge via files in `~/.claude/agent-memory/_shared/`:
- `DECISIONS.md` -- architectural decisions agents should follow
- `CODEBASE.md` -- cross-repo patterns and conventions
- `PIPELINE.md` -- pipeline state and known issues

Edit these files to give agents persistent context about your project.
