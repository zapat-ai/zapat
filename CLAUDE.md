<!-- Slim agent context — full docs in CLAUDE.md at repo root -->
# Zapat Pipeline Agent Context

## Labels

| Label | Meaning |
|-------|---------|
| `agent` | Let the pipeline handle this |
| `agent-work` | Implementation task |
| `agent-research` | Research and analyze |
| `agent-write-tests` | Write tests |
| `zapat-triaging` | Triage in progress |
| `zapat-implementing` | Implementation in progress |
| `zapat-review` | Review pending |
| `zapat-testing` | Tests running |
| `zapat-rework` | Addressing review feedback |
| `needs-rebase` | Conflicts need manual resolution |
| `hold` | Block auto-merge |
| `human-only` | Pipeline should not touch this |
| `codex` | Process with OpenAI Codex |
| `claude` | Process with Claude Code |

## Safety Rules

- Never commit secrets, credentials, or .env files
- Never force-push to main
- Always create feature branches from main
- Run tests before marking implementation complete
- Never modify files outside the working directory

## Key Paths

- Repos: `config/repos.conf`
- Agents: `config/agents.conf`
- Prompts: `prompts/`
- Triggers: `triggers/`
- Shared libs: `lib/`

## Agent Memory

Shared knowledge: `~/.claude/agent-memory/_shared/`
- `DECISIONS.md` — architectural decisions
- `CODEBASE.md` — cross-repo patterns
- `PIPELINE.md` — pipeline state and known issues

## Architecture

```
GitHub Issue (labeled) --> Poller --> Trigger Script --> Claude Code Agent Team --> PR --> Review Agent --> Auto-Merge
```

All jobs run in isolated git worktrees under `~/.zapat/worktrees/`.

## Multi-PR Feature Branches

For large features spanning multiple sub-issues, use a feature branch workflow:

1. Create a feature branch from `main` (e.g., `feature/multi-provider-support`)
2. Sub-PRs target the **feature branch**, not `main`
3. Add `hold` label to sub-PRs to prevent auto-merge (auto-merge gate only merges PRs targeting `main`)
4. Human merges sub-PRs into the feature branch manually
5. Once all sub-PRs are merged, rebase the feature branch onto `main`
6. Open a single integration PR from the feature branch to `main`
7. The integration PR gets the full pipeline treatment (triage, review, test, auto-merge)

**Important**: Never let the pipeline auto-merge sub-PRs targeting feature branches. The auto-merge gate skips PRs not targeting `main` by design.
