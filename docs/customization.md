# Customization Guide

Zapat is designed to be adapted to any project. This guide covers how to create custom agent personas, add compliance modes, write new triggers, and modify team recipes.

## Custom Agent Personas

Agent personas are the core of how Zapat works. Each persona is a markdown file that tells Claude Code to behave as a specific expert.

### Persona file format

Create a `.md` file in `agents/`. Here's the structure:

```markdown
# Role Title

You are a [role description] with deep expertise in [domain]. You have [N] years of experience [doing what].

## Core Expertise
- Specific skill area 1
- Specific skill area 2
- Specific skill area 3

## Communication Style
[How you communicate -- direct, analytical, concise, empathetic, etc.]
[How you structure your responses -- bullet points, prose, code-first, etc.]

## Decision Framework
When evaluating code, proposals, or issues:
1. First consider [primary concern]
2. Then evaluate [secondary concern]
3. Finally assess [tertiary concern]

## Review Checklist
When reviewing code or pull requests:
- [ ] Check for [thing 1]
- [ ] Verify [thing 2]
- [ ] Confirm [thing 3]
- [ ] Validate [thing 4]

## Anti-patterns
Never recommend or approve:
- [Bad practice 1]
- [Bad practice 2]
```

### Tips for effective personas

- **Be specific.** "Senior backend engineer" is okay. "Senior backend engineer specializing in distributed systems, event-driven architecture, and PostgreSQL performance tuning" is much better.
- **Include domain vocabulary.** If the persona is for a fintech project, include relevant terms (PCI DSS, SOC 2, ledger, reconciliation).
- **Define the decision framework.** This is what makes agents consistent. Without it, different sessions may prioritize different things.
- **Include anti-patterns.** Tell the persona what NOT to do. This prevents common mistakes.
- **Keep it under 500 lines.** Longer personas dilute the signal. Be concise.

### Example: Database Engineer persona

```markdown
# Database Engineer

You are a senior database engineer with 12 years of experience designing and optimizing relational databases. You specialize in PostgreSQL, but have deep knowledge of MySQL, SQLite, and DynamoDB.

## Core Expertise
- Schema design and normalization
- Query optimization and EXPLAIN analysis
- Index strategy and maintenance
- Migration safety (zero-downtime migrations)
- Connection pooling and resource management

## Communication Style
Lead with data. Show EXPLAIN output, row counts, and timing benchmarks. Be direct about performance implications. Use SQL examples liberally.

## Decision Framework
1. Correctness first -- does the schema accurately model the domain?
2. Query performance -- will common queries be efficient?
3. Migration safety -- can this change be deployed without downtime?
4. Operational simplicity -- is this easy to monitor and debug?

## Review Checklist
- [ ] New columns have appropriate NOT NULL constraints and defaults
- [ ] Indexes exist for all foreign keys and frequent WHERE clauses
- [ ] Migrations are reversible and zero-downtime safe
- [ ] No N+1 query patterns in application code
- [ ] Connection pool settings are appropriate for the workload
- [ ] Large tables use partitioning or archival strategies

## Anti-patterns
- Adding indexes without checking if they'll be used
- Using ORM-generated queries without reviewing the SQL
- Storing JSON blobs when a proper relation would work
- Running DDL migrations during peak hours
```

### Deploying personas

After creating or editing persona files:

```bash
# Copy to Claude's agent directory
cp agents/*.md ~/.claude/agents/

# Map the role in agents.conf
echo "database=database-engineer" >> config/agents.conf
```

## Compliance Mode

Compliance mode adds extra review steps for regulated industries. When enabled, the pipeline consults a compliance persona before approving PRs.

### Enabling compliance mode

1. Set in `.env`:
   ```bash
   ENABLE_COMPLIANCE_MODE=true
   ```

2. Create a compliance persona in `agents/`. Example for healthcare:

   ```markdown
   # Healthcare Compliance Advisor

   You are a healthcare compliance specialist with expertise in HIPAA,
   HITECH, and FDA software regulations. You review code for PHI exposure,
   audit logging gaps, and regulatory violations.

   ## Review Checklist
   - [ ] No PHI in logs, error messages, or analytics
   - [ ] Audit logging for all data access
   - [ ] Encryption at rest and in transit
   - [ ] Access controls on all endpoints
   - [ ] Data retention policies enforced
   ```

3. Map it in `config/agents.conf`:
   ```
   compliance=healthcare-compliance
   ```

### How compliance mode works

When `ENABLE_COMPLIANCE_MODE=true`:
- The triage team includes the compliance persona.
- PR reviews include a compliance section.
- Auto-merge requires compliance approval (no blocking findings).
- The weekly security scan includes compliance-specific checks.

### Example for fintech

```markdown
# Fintech Compliance Reviewer

You are a fintech compliance specialist with expertise in PCI DSS, SOC 2,
KYC/AML regulations, and financial data handling.

## Review Checklist
- [ ] No credit card numbers or bank details in logs
- [ ] PCI DSS scope boundaries maintained
- [ ] Transaction audit trail is complete
- [ ] Rate limiting on financial endpoints
- [ ] Idempotency keys on payment operations
- [ ] Currency calculations use decimal types (not floats)
```

## Writing New Triggers

Triggers are shell scripts in `triggers/` that the poller calls when it detects a matching condition (usually a GitHub label).

### Trigger anatomy

Every trigger script follows this pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/tmux-helpers.sh"
load_env

# Arguments passed by the poller
REPO="$1"                                          # e.g., "acme-corp/backend"
ITEM_NUMBER="$2"                                   # e.g., "42"
MENTION_CONTEXT="${3:-}"                            # e.g., "@zapat fix the bug"
PROJECT_SLUG="${4:-${CURRENT_PROJECT:-default}}"    # e.g., "my-project"

# Activate project context
set_project "$PROJECT_SLUG"

# Build the prompt from a template
FINAL_PROMPT=$(substitute_prompt "$SCRIPT_DIR/prompts/your-template.txt" \
  "REPO=$REPO" \
  "ISSUE_NUMBER=$ITEM_NUMBER")

# Write prompt to temp file and launch in tmux
PROMPT_FILE=$(mktemp)
echo "$FINAL_PROMPT" > "$PROMPT_FILE"
launch_claude_session "your-job-$ITEM_NUMBER" "/path/to/workdir" "$PROMPT_FILE"
rm -f "$PROMPT_FILE"
```

### Connecting to the poller

In `bin/poll-github.sh`, add a new section that queries for your label (following the pattern of existing label handlers):

```bash
# --- Issues with your-new-label ---
YOUR_JSON=$(gh_safe 'gh issue list --repo "'"$repo"'" --label "your-new-label" --json number,title,labels,assignees --state open') || { RATE_LIMIT_LOW="hit"; continue; }

YOUR_COUNT=$(echo "$YOUR_JSON" | jq 'length')
for ((i=0; i<YOUR_COUNT; i++)); do
    YOUR_NUM=$(echo "$YOUR_JSON" | jq -r ".[$i].number")
    # ... dedup, governance checks ...
    "$SCRIPT_DIR/triggers/on-your-event.sh" "$repo" "$YOUR_NUM" "" "$project_slug" &
done
```

### Creating the prompt template

Create `prompts/your-template.txt`:

```
You are working on repository {{REPO}}.

## Task
[Describe what the agent should do]

## Context
- Issue: #{{ISSUE_NUMBER}}
- Repository type: {{REPO_TYPE}}
- Local path: {{LOCAL_PATH}}

## Instructions
1. [Step 1]
2. [Step 2]
3. [Step 3]

## Output
[Describe expected output -- comment on issue, create PR, post analysis, etc.]
```

### Adding a timeout

Add a default to `.env.example`:

```bash
TIMEOUT_YOUR_JOB=600
```

## Modifying Team Recipes

Team recipes define which agents collaborate on each task type. They're embedded in the prompt templates.

### How team recipes work

When a prompt includes lines like:

```
Use a team with these roles:
- builder (engineers/implements the solution)
- security (reviews for vulnerabilities)
- product (validates requirements)
```

Claude Code spawns multiple agent instances, each loaded with the corresponding persona from `~/.claude/agents/`.

### Customizing a recipe

Edit the prompt template in `prompts/`. For example, to add a database expert to the implementation team, edit `prompts/implement-issue.txt` and add the role to the team definition section.

### Creating a new recipe

1. Define the roles in the prompt template.
2. Map each role to a persona in `config/agents.conf`.
3. Ensure the persona files exist in `agents/`.

### Example: Adding a QA step

To add a dedicated QA review after implementation:

1. Create `agents/qa-engineer.md` with the QA persona.
2. Add `qa=qa-engineer` to `config/agents.conf`.
3. Create `prompts/qa-review.txt` with the QA prompt template.
4. Create `triggers/on-qa-review.sh` that launches the QA agent.
5. Add a `agent-qa` label to your detection logic in `bin/poll-github.sh`.

## Shared Agent Memory

Agents share persistent knowledge via files in `~/.claude/agent-memory/_shared/`. Every agent reads these files at the start of each session.

### DECISIONS.md

Record architectural decisions so agents stay consistent:

```markdown
# Architectural Decisions

## API Design
- Use REST for public APIs, gRPC for internal services
- Always version APIs: /v1/, /v2/
- Use UUID v4 for all entity IDs

## Database
- PostgreSQL for transactional data
- Redis for caching and sessions
- No ORMs -- use raw SQL with parameterized queries

## Frontend
- React with TypeScript
- Tailwind CSS for styling
- No CSS-in-JS libraries
```

### CODEBASE.md

Document cross-repo patterns:

```markdown
# Codebase Patterns

## Error Handling
- Backend: throw AppError with status code and message
- Frontend: use ErrorBoundary components
- Always log errors with correlation ID

## Testing
- Unit tests: colocated with source (*.test.ts)
- Integration tests: tests/ directory at repo root
- E2E tests: cypress/ directory
```

### PIPELINE.md

Track pipeline-specific operational state:

```markdown
# Pipeline State

## Known Issues
- Repo X has flaky tests in CI -- retry once before failing
- Repo Y requires Node 20 (not 18) for builds

## Recent Changes
- 2025-01-15: Added rate limiting to API -- agents should include rate limit headers
- 2025-01-20: Migrated auth to OAuth2 -- old session-based code is deprecated
```

## Adding New CLI Commands

See [CONTRIBUTING.md](../CONTRIBUTING.md) for details on adding commands to the `bin/zapat` CLI. Commands are Node.js modules in `src/commands/`.
