# Changelog

All notable changes to Zapat will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/zapat-ai/zapat/releases/tag/v1.0.0
