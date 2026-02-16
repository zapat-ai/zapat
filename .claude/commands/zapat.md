# Zapat Setup Wizard

You are guiding a user through setting up Zapat, an autonomous dev pipeline powered by Claude Code. Walk through each step interactively, asking questions and validating as you go.

**If `.env` already exists in the repo root**, inform the user that Zapat is already configured and ask whether they want to:
- Re-run setup from scratch (backs up existing config first)
- Update specific sections (jump to that step)
- Cancel

---

## Step 0 — System Prerequisites

Check that all required tools are installed. Run each check and report results:

```bash
# Check each tool
tmux -V
jq --version
gh --version
node --version    # Must be 18+
npm --version
git --version     # Must be 2.20+
curl --version
claude --version
```

For any missing tool, provide the install command:

**macOS (Homebrew):**
```bash
brew install tmux jq gh node git curl
```

**Linux (apt):**
```bash
sudo apt-get update && sudo apt-get install -y tmux jq gh nodejs npm git curl
```

**Claude Code CLI** (if missing):
```bash
npm install -g @anthropic-ai/claude-code
```

Verify Node.js is version 18 or higher. If not, suggest upgrading via `nvm install 18` or `brew upgrade node`.

Verify git is version 2.20 or higher (needed for worktree features).

Do NOT proceed until all prerequisites pass. Offer to install missing tools automatically if the user agrees.

### Claude Code Agent Teams Setting

After all tools are verified, check if agent teams are enabled in Claude Code:

```bash
cat ~/.claude/settings.json 2>/dev/null | jq -r '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS // empty'
```

If the value is not `"1"`, explain:

> Zapat uses Claude Code's agent teams feature to spin up specialized teams for every task. This requires a setting in your Claude Code configuration.

Then enable it automatically (or ask first if you prefer):

```bash
SETTINGS_FILE="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
if [ -f "$SETTINGS_FILE" ]; then
  jq '.env += {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
else
  echo '{ "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }' | jq . > "$SETTINGS_FILE"
fi
```

**Note:** This setting may become unnecessary in a future Claude Code release. If already enabled, skip silently.

---

## Step 1 — GitHub

Verify GitHub access automatically:

```bash
gh api user --jq '.login'
```

If authenticated, use the returned login as both the GitHub org and `ZAPAT_BOT_LOGIN` in `.env`.

If NOT authenticated, guide them:
1. Run `gh auth login`
2. Or create a Personal Access Token at https://github.com/settings/tokens/new (scopes: `repo`, `read:org`)

Once authenticated, ask: **"What's your GitHub organization or username?"** (e.g., `acme-corp` or `jdoe`). Default to the authenticated user's login.

---

## Step 2 — Your Project

This is the core of setup. Understand what the user is building so agents have full context.

### What are you building?

Ask: **"Tell me about your project. What are you building?"**

Let the user describe it naturally. Examples:
- "A healthcare SaaS with an iOS app and a Next.js web dashboard"
- "An e-commerce platform with a React frontend and Node.js backend"
- "A single Django app for internal tooling"

Save this description — it goes into `config/project-context.txt` and helps agents understand the big picture.

### Main repository

Ask: **"What's the main repo — the one where most of the development happens?"**

Collect the GitHub path: `owner/repo` (e.g., `acme-corp/backend`)

**Auto-detect the local path.** Try these locations before asking:
```bash
REPO_NAME="${GITHUB_PATH##*/}"
for dir in \
  "$HOME/workplace/$REPO_NAME" \
  "$HOME/code/$REPO_NAME" \
  "$HOME/projects/$REPO_NAME" \
  "$HOME/dev/$REPO_NAME" \
  "$HOME/src/$REPO_NAME" \
  "$HOME/$REPO_NAME" \
  "./$REPO_NAME" \
  "../$REPO_NAME"; do
  if [ -d "$dir/.git" ]; then
    echo "FOUND:$(cd "$dir" && pwd)"
    break
  fi
done
```

If found, confirm: "I found it at `/home/you/code/backend` — is that right?"
If not found, ask: "Where is it cloned locally?" If not cloned yet, offer to clone it:
```bash
gh repo clone <owner/repo> <chosen_path>
```

**Auto-detect the repo type.** Scan the tech stack instead of asking:
```bash
# In the repo's local path:
# - package.json with "next" or "react" → web
# - package.json with "aws-cdk" or "express" or "fastify" → backend
# - Package.swift or *.xcodeproj → ios
# - Podfile or build.gradle with android → mobile
# - wxt.config.* or manifest.json (chrome extension) → extension
# - pyproject.toml with django/flask/fastapi → backend
# - go.mod → backend
# - Cargo.toml → backend
# - If unclear, default to "other"
```

Also run the full tech stack scan:
```bash
# - Check package.json → detect Next.js, React, AWS CDK, Express, etc.
# - Check Package.swift or *.xcodeproj → Swift/SwiftUI (iOS)
# - Check pyproject.toml or setup.py → Python
# - Check Cargo.toml → Rust
# - Check go.mod → Go
# - Count source files in src/ and lib/
# - Check for test framework (jest.config.*, vitest.config.*, pytest.ini)
```

### Other repositories

Ask: **"Are there other repos that are part of this project?"**

Give examples to jog their memory:
- "A separate backend or API service?"
- "A mobile app (iOS or Android)?"
- "A Chrome extension?"
- "A marketing site or docs site?"
- "Infrastructure or deployment repo?"

For each additional repo, collect the GitHub path and auto-detect the local path and type the same way. Keep asking until they say no more.

### Generate project context

Create `config/project-context.txt` combining the user's project description with auto-detected information:

```
## Project Description

<user's description from "What are you building?">

## Repositories

### acme-corp/backend (backend) ★ main
- **Local path**: /home/you/code/backend
- **Stack**: Express.js (TypeScript, PostgreSQL, Redis)
- **Source files**: ~200
- **Tests**: Yes (Jest)

### acme-corp/web-app (web)
- **Local path**: /home/you/code/web-app
- **Stack**: Next.js 15 (React 19, TypeScript, Tailwind)
- **Source files**: ~120
- **Tests**: Yes (Vitest)
```

### Repository relationships

If there are 2+ repositories, ask:

**"How do these repos connect? For example:"**
- "The web app and iOS app both call the backend API"
- "The extension reads data from the web app"

Write the description into a `## Repository Relationships` section.

If the user isn't sure, infer from the detected types:
- web + backend → "The web app calls REST APIs served by the backend"
- ios + backend → "The iOS app calls REST APIs served by the backend"
- web + ios + backend → "Both the web app and iOS app consume the same backend APIs"
- extension + web → "The extension interacts with the web app in the browser"

### Cross-repo rules

Always include:
```
## Cross-Repo Implementation Rules

- If an issue requires changes in multiple repos, the triage agent should create separate sub-issues for each repo
- Frontend changes that need a new API endpoint must specify the API contract in the issue body
- Always read the relevant backend code before assuming an API endpoint exists or doesn't exist
```

### Single repo

If there's only one repository, still generate the context file with the project description and stack detection. Skip the relationships section.

### Confirmation

Show the generated `config/project-context.txt` and ask: "Does this look right? You can edit `config/project-context.txt` later to refine it."

---

## Step 3 — Auto-Merge

Ask: **"Should Zapat auto-merge PRs that pass code review and tests?"**

Explain: "When enabled, low-risk PRs merge immediately and medium-risk PRs merge after a 4-hour delay. High-risk PRs always require human approval. You can block any PR from merging by adding the `hold` label."

- If yes: Set `AUTO_MERGE_ENABLED=true`
- If no: Set `AUTO_MERGE_ENABLED=false`. PRs will still be created and reviewed, but a human must merge.

---

## Step 4 — Review Defaults and Generate

Before generating configuration, show the user all defaults that will be applied and give them a chance to change any.

### Show defaults

Present this summary:

```
Here's how Zapat will be configured. Let me know if you'd like to change anything:

  Model:              Opus 4.6 (best quality)
  Auto-triage:        enabled (every issue triaged; "human-only" label opts out)
  Auto-merge risk:    medium max (high-risk PRs need human approval)
  Merge delay:        4 hours for medium-risk PRs
  Parallel sessions:  10 max
  Polling interval:   every 2 minutes
  Timezone:           <auto-detected>
  Notifications:      none (add Slack webhook later in .env)
  Agent team:         engineer, security, product, ux
  Scheduled tasks:    daily standup, weekly planning, weekly security scan
  Budget caps:        $5 standup / $15 planning / $25 strategy / $15 security
```

Then ask: **"Look good, or would you like to change anything?"**

If the user says it looks good, proceed with these defaults.

If the user wants changes, let them describe what to change in natural language (e.g., "use Sonnet instead of Opus", "disable auto-triage", "set polling to 5 minutes", "add my Slack webhook: https://hooks.slack.com/..."). Apply the changes they request and confirm.

### Defaults reference

| Setting | Default |
|---------|---------|
| `CLAUDE_MODEL` | `claude-opus-4-6` |
| `AUTO_TRIAGE_NEW_ISSUES` | `true` |
| `AUTO_MERGE_MAX_RISK` | `medium` |
| `AUTO_MERGE_DELAY_HOURS` | `4` |
| `MAX_PARALLEL_SESSIONS` | `10` |
| `POLL_INTERVAL_MINUTES` | `2` |
| `SLACK_WEBHOOK_URL` | (empty) |
| `TIMEZONE` | (auto-detected) |
| `ENABLE_DAILY_STANDUP` | `true` |
| `ENABLE_WEEKLY_PLANNING` | `true` |
| `ENABLE_MONTHLY_STRATEGY` | `false` |
| `ENABLE_WEEKLY_SECURITY` | `true` |
| Budget caps | $5/$15/$25/$15 |

**Detect timezone automatically:**
```bash
# macOS
DETECTED_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
# Linux fallback
[ -z "$DETECTED_TZ" ] && DETECTED_TZ=$(cat /etc/timezone 2>/dev/null)
# Final fallback
[ -z "$DETECTED_TZ" ] && DETECTED_TZ="America/New_York"
```

### Generate repos.conf

Write `config/repos.conf` from the repos collected in Step 2:
```
# Zapat — Repository Configuration
# Format: owner/repo<TAB>local_path<TAB>type
acme-corp/backend	/home/you/code/backend	backend
acme-corp/web-app	/home/you/code/web-app	web
```

### Generate agents.conf

Use the 4 core roles (always):
```
# Zapat — Agent Team Configuration
builder=engineer
security=security-reviewer
product=product-manager
ux=ux-reviewer
```

### Generate .env

Create `.env` from `.env.example` using the defaults (with any user modifications applied). If `.env` already exists, back it up to `.env.backup.<timestamp>` first.

### Copy agent personas
```bash
mkdir -p ~/.claude/agents
cp agents/*.md ~/.claude/agents/
```

### Generate shared memory templates
```bash
mkdir -p ~/.claude/agent-memory/_shared
```
Create template files if they don't exist:
- `~/.claude/agent-memory/_shared/DECISIONS.md` — with header and placeholder
- `~/.claude/agent-memory/_shared/CODEBASE.md` — with header and placeholder
- `~/.claude/agent-memory/_shared/PIPELINE.md` — with header and placeholder

### Install dependencies
```bash
npm install
```

### Build dashboard
```bash
cd dashboard && npm install && npm run build
```

### Set up GitHub labels
```bash
bin/setup-labels.sh
```
This creates the required labels (`agent`, `agent-work`, `agent-research`, etc.) on all configured repos.

### Install issue templates and GitHub Action (optional)

Ask: **"Would you like to install issue templates and the auto-label GitHub Action on your repos?"**

Explain: "This gives your team pre-built issue templates (Bug Report, Feature Request, Research, Human Only) that automatically apply the right labels. It also installs a GitHub Action that labels new issues instantly so Zapat picks them up faster."

If yes, for each repo collected in Step 2:
```bash
REPO_PATH="/path/to/repo"  # from repos.conf
mkdir -p "$REPO_PATH/.github/ISSUE_TEMPLATE"
cp examples/issue-templates/*.yml "$REPO_PATH/.github/ISSUE_TEMPLATE/"

mkdir -p "$REPO_PATH/.github/workflows"
cp examples/github-actions/zapat-auto-label.yml "$REPO_PATH/.github/workflows/"
```

After copying, remind the user: "The templates and Action have been copied to your repos. You'll need to commit and push these files for them to take effect."

If no, note: "You can install these later by copying from the `examples/` directory."

### Start the pipeline
```bash
bin/startup.sh
```
This creates the tmux session, installs the cron job, and starts the dashboard.

### Verify health
```bash
bin/zapat health
```

### Print summary

Print a summary of everything that was configured:

```
Zapat is running.

  Project:          <user's project description>
  Main repo:        acme-corp/backend
  Other repos:      2 additional
  Agent team:       engineer, security, product, ux
  Model:            Opus 4.6
  Auto-merge:       <enabled/disabled>
  Dashboard:        http://localhost:8080

  Next steps:
  1. Label a GitHub issue with "agent" to start triage
  2. Or comment "@zapat please triage this" on any issue
  3. Run "bin/zapat status" to check pipeline health
  4. Visit http://localhost:8080 for the dashboard
  5. Edit .env anytime to change settings
```
