# Contributing to Zapat

Thanks for your interest in contributing to Zapat. This guide covers the main ways to extend and improve the project.

## Development Setup

```bash
git clone https://github.com/zapat-ai/zapat.git
cd zapat
npm install
cd dashboard && npm install && cd ..
```

You don't need a running pipeline to develop -- most components can be tested individually.

## Project Structure

- **Shell scripts** (`bin/`, `triggers/`, `lib/`, `jobs/`) handle orchestration -- polling, dispatching, state management.
- **Node.js** (`src/`, `bin/zapat`) handles data processing -- metrics, risk scoring, health checks, the CLI.
- **Prompts** (`prompts/`) are text templates that define what agents do.
- **Personas** (`agents/`) define agent expertise and behavior.
- **Dashboard** (`dashboard/`) is a standalone Next.js app.

## Adding a New Trigger Script

Trigger scripts live in `triggers/` and are called by `bin/poll-github.sh` when a matching label is detected.

1. Create `triggers/on-your-event.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/tmux-helpers.sh"
load_env

REPO="$1"
ITEM_NUMBER="$2"
MENTION_CONTEXT="${3:-}"
PROJECT_SLUG="${4:-${CURRENT_PROJECT:-default}}"

set_project "$PROJECT_SLUG"

# Build the prompt from a template
FINAL_PROMPT=$(substitute_prompt "prompts/your-template.txt" \
  "REPO=$REPO" \
  "ISSUE_NUMBER=$ITEM_NUMBER")

# Write prompt to temp file and launch in tmux
PROMPT_FILE=$(mktemp)
echo "$FINAL_PROMPT" > "$PROMPT_FILE"
launch_claude_session "your-job-$ITEM_NUMBER" "/path/to/workdir" "$PROMPT_FILE"
rm -f "$PROMPT_FILE"
```

2. Create the corresponding prompt template in `prompts/your-template.txt`.
3. Add detection logic in `bin/poll-github.sh` to recognize your label and call the trigger.
4. Add a timeout default to `.env.example`.

## Creating Custom Agent Personas

Agent personas are markdown files in `agents/` that define an expert's knowledge, communication style, and decision framework.

1. Create `agents/your-persona.md`:

```markdown
# Your Persona Name

You are a [role description] with [N] years of experience in [domain].

## Expertise
- Area 1
- Area 2
- Area 3

## Communication Style
[How this persona communicates -- direct, academic, concise, etc.]

## Decision Framework
[How this persona evaluates options and makes recommendations]

## Review Checklist
When reviewing code or proposals, always check:
- [ ] Item 1
- [ ] Item 2
- [ ] Item 3
```

2. Map it in `config/agents.conf`:
```
yourrole=your-persona
```

3. Deploy: `cp agents/*.md ~/.claude/agents/`

The persona file is loaded by Claude Code when the agent is spawned. Write it as if you're briefing a senior consultant on their role.

## Customizing Prompts

Prompt templates in `prompts/` use `{{PLACEHOLDER}}` syntax. At runtime, `lib/common.sh` substitutes these with actual values.

Available placeholders:
- `{{REPO}}` -- GitHub owner/repo
- `{{ISSUE_NUMBER}}`, `{{PR_NUMBER}}` -- item number
- `{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}` -- issue content
- `{{BRANCH}}` -- target branch
- `{{LOCAL_PATH}}` -- local repo path
- `{{REPO_TYPE}}` -- repo type from repos.conf
- `{{WORKTREE_PATH}}` -- isolated worktree path (for implementations)

To add a new placeholder, update the `substitute_prompt` function in `lib/common.sh`.

## Adding CLI Commands

The CLI is built with Node.js in `src/`. Each command is a module in `src/commands/`.

1. Create `src/commands/your-command.mjs`:

```javascript
export const command = 'your-command';
export const description = 'What it does';

export function builder(yargs) {
  return yargs
    .option('flag', { type: 'string', describe: 'A flag' });
}

export async function handler(argv) {
  // Implementation
}
```

2. Register it in `src/cli.mjs` by adding it to the yargs command chain.

3. Test it: `node bin/zapat your-command`

## Branching Strategy

We use a simple branching model:

- **`main`** is always stable and releasable. All releases are tagged from `main`.
- **Feature branches** (`feat/description`, `fix/description`, `docs/description`) branch off `main` and merge back via PR.
- No `develop` branch. No long-lived branches.

```
main ─────●─────●─────●─── (v1.0.0) ───●─────●─── (v1.1.0)
           \   /       \               /
            feat/       fix/
            new-trigger  health-check
```

### Branch naming

Use the conventional commit type as a prefix:

| Prefix | Use for |
|--------|---------|
| `feat/` | New features or capabilities |
| `fix/` | Bug fixes |
| `docs/` | Documentation changes |
| `refactor/` | Code restructuring without behavior change |
| `chore/` | Build, CI, dependency updates |

## Submitting Pull Requests

### Commit messages

Use [conventional commits](https://www.conventionalcommits.org/):

```
feat: add Jira integration trigger
fix: handle missing worktree gracefully in health check
docs: add Linux systemd setup guide
refactor: extract label detection into shared function
chore: bump dashboard dependencies
```

**Format:** `type: short description` (lowercase, no period, imperative mood)

**Types:**

| Type | When to use |
|------|-------------|
| `feat` | A new feature or capability |
| `fix` | A bug fix |
| `docs` | Documentation only |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `chore` | Build process, CI, dependencies, tooling |
| `test` | Adding or updating tests |
| `perf` | Performance improvement |

For breaking changes, add `!` after the type: `feat!: redesign config format`

### Before submitting

1. **Test your changes.** For shell scripts, run them manually against a test repo. For Node.js code, ensure `node bin/zapat <command>` works.
2. **Check shell scripts with shellcheck** if available: `shellcheck bin/*.sh triggers/*.sh lib/*.sh`
3. **Don't break existing behavior.** The pipeline runs unattended -- regressions can go unnoticed.
4. **Keep prompts model-agnostic.** Don't assume a specific Claude model version in prompt templates.
5. **Update `.env.example`** if you add new environment variables.
6. **Update `CLAUDE.md`** if you add new commands, labels, or skills.

### What makes a good PR

- Solves one specific problem
- Includes a clear description of what changed and why
- Updates relevant documentation
- Doesn't introduce new hard-coded paths (use `$AUTOMATION_DIR` or `$HOME`)

## Releases

We use [semantic versioning](https://semver.org/) (MAJOR.MINOR.PATCH):

| Bump | When |
|------|------|
| **patch** (1.0.0 -> 1.0.1) | Bug fixes, docs updates, non-breaking tweaks |
| **minor** (1.0.0 -> 1.1.0) | New features, backward-compatible changes |
| **major** (1.0.0 -> 2.0.0) | Breaking changes (config format, CLI interface, etc.) |

Releases are cut from `main` using the release script:

```bash
bin/release.sh patch   # or minor, or major
```

This bumps versions, prompts for a CHANGELOG entry, tags, and optionally creates a GitHub Release. See the script for details.

### Changelog

We maintain a [Keep a Changelog](https://keepachangelog.com/) formatted `CHANGELOG.md`. Every release should have an entry describing what changed. The release script will check for this.

## Reporting Issues

When reporting a bug, include:
- Output of `bin/zapat health`
- Relevant log file from `logs/`
- Your OS (macOS version or Linux distribution)
- Node.js version (`node --version`)

## Code of Conduct

Be respectful. Keep discussions technical and constructive. We're building tools to help developers ship faster -- that mission works best when everyone feels welcome to contribute.
