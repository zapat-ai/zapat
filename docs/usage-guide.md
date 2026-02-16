# Zapat Usage Guide

Practical examples of how to use the framework, from setup to daily operation.

---

## Setup (One-Time)

### 1. Clone and configure

```bash
git clone https://github.com/your-org/zapat.git
cd zapat
cp .env.example .env
cp config/repos.conf.example config/repos.conf
```

### 2. Edit `.env`

```bash
# Required
GH_TOKEN=ghp_xxxxxxxxxxxxx          # GitHub PAT (repo, read:org)
SLACK_WEBHOOK_URL=https://hooks...   # Slack incoming webhook
GITHUB_ORG=your-org                  # GitHub organization

# Auto-merge
AUTO_MERGE_ENABLED=true
AUTO_MERGE_DELAY_HOURS=4             # Delay for medium-risk PRs
```

### 3. Edit `config/repos.conf`

```
# owner/repo          local_path                          type
your-org/backend      /Users/you/code/backend             backend
your-org/web-app      /Users/you/code/web-app             web
your-org/ios-app      /Users/you/code/ios-app             ios
your-org/extension    /Users/you/code/extension            extension
```

### 4. Install and start

```bash
npm install                          # Pipeline CLI dependencies
cd dashboard && npm install && npm run build && cd ..
bin/startup.sh                       # Creates tmux, installs cron, starts dashboard
```

The pipeline is now running. It polls GitHub every 2 minutes automatically.

---

## Daily Usage

### Triage an issue automatically

Add the `agent` label to any GitHub issue. Within 10 minutes, a 4-agent team (engineer, security reviewer, product manager, UX reviewer) will post a triage comment with:

- Complexity assessment (Small / Medium / Large)
- Suggested priority (P0–P3)
- Security considerations
- Recommended approach

If the issue is ready for implementation, the team auto-adds the `agent-work` label.

```
Example issue: "Add dark mode toggle to settings page"
Label: agent
→ Triage team posts analysis within 10 min
→ Adds agent-work label if criteria are clear
```

### Implement an issue

Add the `agent-work` label (or let triage add it). A 5-agent team works in an isolated git worktree:

1. Builder reads the codebase and implements
2. Security reviewer checks for vulnerabilities
3. UX reviewer evaluates the interface
4. Product manager confirms acceptance criteria
5. Product manager confirms acceptance criteria

Result: a PR on an `agent/issue-{number}-{slug}` branch with tests.

```
Example issue: "Fix login timeout error on slow connections"
Label: agent-work
→ Builder creates fix in /tmp/agent-worktrees/
→ Runs tests, pushes branch, opens PR
→ PR auto-labeled _review for code review
→ PR auto-labeled zapat-testing for test verification
```

### Review a PR

Add the `agent` label to any PR. A 4-agent review team posts:

- Risk level (Low / Medium / High)
- Auto-merge recommendation
- Security findings
- Code quality assessment
- `[BLOCKING]` issues that must be fixed
- `[SUGGESTION]` improvements

```
Example PR: "feat: add OAuth2 PKCE flow"
Label: agent
→ Review team posts structured analysis within 10 min
→ Flags high-risk auth changes as [BLOCKING] if needed
```

### Fix review feedback

When a reviewer requests changes on an agent PR, the pipeline auto-detects it and adds the `zapat-rework` label. The builder re-reads the feedback, makes fixes, and pushes to the same branch.

You can also add `zapat-rework` manually to any PR to trigger re-work.

### Run a research/strategy task

Add the `agent-research` label to an issue describing a question or investigation. A multi-expert team (product manager + 2-4 domain experts) produces:

- Executive summary
- Key findings by expert
- Prioritized recommendations
- Follow-up issues (auto-created with appropriate labels)

For complex features, the research team decomposes the work into sub-issues with dependency ordering and interface contracts.

```
Example issue: "Evaluate adding CSV export support"
Label: agent-research
→ Product manager + security reviewer + engineer analyze
→ Creates 3 sub-issues: data model, UI, backend
→ Each sub-issue has Blocked By and Interface Contract sections
```

### Write tests for existing code

Add the `agent-write-tests` label to an issue describing what needs test coverage. The QA agent writes unit and integration tests, sets up test infrastructure if missing, and opens a PR.

---

## Pipeline CLI

### Check pipeline status

```bash
bin/zapat status
# Output:
#   Session: zapat (5 windows)
#   Slots:   3/10 active  [███░░░░░░░]
#   Last 24h: 12 jobs (10 success, 2 failure)
#   7d rate:  87% (45/52)

bin/zapat status --slack    # Send to Slack
bin/zapat status --json     # Machine-readable
```

### Monitor health

```bash
bin/zapat health
# Output:
#   ✓ tmux-session          ok     Session exists (5 windows)
#   ✓ orphaned-worktrees    ok     0 orphaned worktree(s)
#   ✓ stale-slots           ok     0 stale slot(s)
#   ✓ gh-auth               ok     Authenticated as your-user
#   ✗ failed-items          error  4 failed/abandoned items

bin/zapat health --auto-fix   # Automatically repair issues
```

### Query metrics

```bash
bin/zapat metrics query --days 7
bin/zapat metrics query --last-hour --status failure
bin/zapat metrics query --job issue-triage --days 30
```

### Classify PR risk

```bash
bin/zapat risk your-org/backend 42
# Output:
#   Risk: medium (score: 6)
#   Reasons:
#     - 2 high-risk file(s) (auth, schema)
#     - Medium changeset: 300 lines
#     - Backend repository
```

### View dashboard

```bash
bin/zapat dashboard --serve       # Start Next.js on port 3000
bin/zapat dashboard --dev         # Development mode with hot reload
bin/zapat dashboard --static      # Generate static HTML
```

---

## Labels Reference

| Label | What Happens |
|-------|-------------|
| `agent` | On issues: triage team analyzes. On PRs: review team posts code review |
| `agent-work` | Skip triage, implementation team builds it immediately |
| `agent-research` | Strategy team investigates and decomposes |
| `hold` | Blocks auto-merge on a PR |
| `human-only` | Pipeline skips this item entirely |
| `zapat-triaging` | [Auto] Triage in progress |
| `zapat-implementing` | [Auto] Implementation in progress |
| `zapat-review` | [Auto] Code review pending |
| `zapat-testing` | [Auto] Tests running |
| `zapat-rework` | [Auto] Builder fixing review feedback |

---

## Controlling the Pipeline

### Pause a specific item
Assign someone to the issue. Items with assignees are skipped.

### Block auto-merge
Add the `hold` label to the PR.

### Skip an issue entirely
Add the `human-only` label.

### Order dependent work
In the issue body, add:
```
**Blocked By:** #45, #46
```
The pipeline won't start this issue until #45 and #46 are closed.

### Target a feature branch
In the issue body, add:
```
**Target Branch:** feature/dark-mode
```
The agent creates its branch off `feature/dark-mode` instead of `main`.

### Provide interface contracts
For multi-service features, add to the issue body:
```
## Interface Contract
### ThemeService (implemented by issue #45)
- func toggleTheme() -> void
- var currentTheme: "light" | "dark"
- event: onThemeChange(theme: string)
```
This prevents API mismatches when multiple agents work on related issues.

---

## Customizing for Your Project

### Add a new repo

1. Clone the repo locally
2. Add a line to `config/repos.conf`:
   ```
   your-org/new-repo    /path/to/new-repo    web
   ```
3. The next poll cycle picks it up automatically

### Adjust timeouts

Edit `.env`:
```bash
TIMEOUT_IMPLEMENT=2700      # Allow 45 minutes
MAX_CONCURRENT_WORK=5       # Limit to 5 parallel agents
```

### Change the auto-merge policy

```bash
AUTO_MERGE_ENABLED=false          # Disable entirely
AUTO_MERGE_DELAY_HOURS=8          # 8-hour delay for medium risk
AUTO_MERGE_MAX_RISK=low           # Only auto-merge low-risk PRs
```

### Customize agent personas

Agent definitions live in `~/.claude/agents/`. Each is a markdown file defining the persona's expertise, communication style, and decision framework. Edit or add personas to match your team's domain.

### Add shared knowledge

Write to `~/.claude/agent-memory/_shared/`:
- `DECISIONS.md` — Architectural decisions agents should follow
- `CODEBASE.md` — Cross-repo patterns and conventions
- `PIPELINE.md` — Pipeline state and known issues

Agents read these before every task.

---

## Troubleshooting

### Nothing is happening after labeling

```bash
bin/zapat health               # Check for issues
bin/zapat status               # Check if poller is running
tail -20 logs/cron-poll.log       # Check poller logs
```

### Agent session timed out

Check the job log:
```bash
ls -lt logs/                      # Find recent log
cat logs/issue-work-2026-02-10T12:00:00.log
```

The item will auto-retry with exponential backoff (10min, 30min, then abandon).

### Too many orphaned worktrees

```bash
bin/zapat health --auto-fix    # Cleans them up
```

This also runs automatically every poll cycle.

### Dashboard not loading

```bash
# Check if running
lsof -i :3000

# Restart
kill $(cat state/dashboard.pid)
cd dashboard && AUTOMATION_DIR=.. nohup npx next start -H 0.0.0.0 -p 3000 >> ../logs/dashboard.log 2>&1 &
echo $! > ../state/dashboard.pid
```

---

## End-to-End Example

A complete lifecycle of a feature request:

```
1. You create GitHub issue: "Add export to PDF button on reports page"

2. You add label: agent

3. [10 min] Triage team posts:
   "Complexity: Medium. Priority: P2. Affects: web-app/src/pages/reports.
    No security concerns. Recommended: agent-work."
   → Adds agent-work label

4. [30 min] Implementation team:
   → Creates worktree at /tmp/agent-worktrees/web-app-123
   → Builder implements ExportPDFButton component
   → Writes unit tests for the component
   → Security reviewer confirms no sensitive data in export
   → UX reviewer confirms button placement
   → Opens PR #87 on branch agent/issue-123-export-pdf

5. [10 min] Review team posts structured review on PR #87
   → Risk: Low (score 2). Auto-merge: Safe.
   → No blocking issues.

6. [20 min] Test runner verifies PR builds and tests pass
   → Posts agent-test-passed comment

7. Auto-merge gate:
   → Low risk + approved + tests passed
   → Squash-merged immediately
   → Slack: "PR #87 auto-merged (low risk)"

8. Issue #123 auto-closed via "Closes #123" in PR description
```

Total time: ~1 hour. Human effort: writing the issue + adding one label.
