# Changelog

All notable changes to Zapat will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-02-26

### Added

- 4 new agent personas: devops-engineer (CI/CD, IaC, reliability), program-manager (delivery sequencing, WIP limits, phase gates), qa-engineer (adversarial testing, coverage gaps), technical-writer (accuracy-first docs, examples)
- 3-tier model strategy: Lead (Opus) for orchestrators, Sub-agent (Opus) for reviewers/analysts, Utility (Haiku) for test runners and scheduled jobs
- Opus sub-agents: team-based prompts spawn Task sub-agents using `CLAUDE_SUBAGENT_MODEL` (default Opus) with `model:` parameter in Task tool calls
- `agent-plan` label for proposed work pending human approval
- `agent-phase-2` and `agent-phase-3` labels for phased execution
- `MAX_WIP_PER_PROGRAM` config for program-level WIP limits (default 3)
- Finish-over-start scan priority in poller (rework > CI fix > test > review > new work)
- `bin/zapat program` CLI command for tracking multi-issue progress, dependencies, and ETA
- Classification labels (`feature`, `bug`, `tech-debt`, `security`, `research`) applied during triage
- Priority labels (`P0-critical`, `P1-high`, `P2-medium`, `P3-low`) applied during triage

### Changed

- Agent roster expanded from 4 core roles to 8 core roles
- Default `CLAUDE_SUBAGENT_MODEL` changed from Sonnet to Opus
- Setup wizards (plugin + project-scoped) updated with COE learnings, 8 agent roles, and Opus sub-agent configuration
- Budget caps removed from wizard defaults (unclear with subscription plans)

## [1.0.0] - 2026-02-15

### Added

- Autonomous dev pipeline: triage, implement, test, review, and auto-merge from a single GitHub label
- GitHub poller with rate limit awareness and configurable 2-minute intervals
- Agent team system with 4 core personas: engineer, security reviewer, product manager, UX reviewer
- 7 trigger handlers: new issue triage, direct implementation, research, PR review, test execution, rework review, test generation
- 11 prompt templates for all pipeline stages plus scheduled jobs
- Auto-merge gate with risk classification (low/medium/high)
- Next.js monitoring dashboard with real-time status, Kanban board, health checks, and analytics
- Pipeline CLI (`bin/zapat`) with status, health, metrics, risk, logs, and dashboard commands
- Interactive setup wizard (`/zapat`) with project-centric onboarding
- Claude Code plugin support with namespaced commands (`/zapat:setup`, `/zapat:add-repo`, `/zapat:pipeline-check`)
- Slack notifications for pipeline events and daily/weekly digests
- Scheduled jobs: daily standup, weekly planning, monthly strategy, weekly security scan
- GitHub issue templates and auto-label GitHub Action
- Shared agent memory system for cross-session knowledge
- Domain-specific agent examples (healthcare, fintech, iOS)
- Isolated git worktree execution for concurrent agent sessions
- tmux-based session management with slot allocation
- Comprehensive documentation: overview, usage guide, customization, Linux setup

[1.1.0]: https://github.com/zapat-ai/zapat/releases/tag/v1.1.0
[1.0.0]: https://github.com/zapat-ai/zapat/releases/tag/v1.0.0
