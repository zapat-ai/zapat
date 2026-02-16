#!/usr/bin/env bash
# Zapat - Auto-Rebase Trigger
# Rebases a stale PR onto the latest base branch. Pure git operations, no Claude agent needed.
# Usage: on-rebase-pr.sh OWNER/REPO PR_NUMBER [MENTION_CONTEXT] [PROJECT_SLUG]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/item-state.sh"
load_env

# --- Args ---
if [[ $# -lt 2 ]]; then
    log_error "Usage: on-rebase-pr.sh OWNER/REPO PR_NUMBER"
    exit 1
fi

REPO="$1"
PR_NUMBER="$2"
_MENTION_CONTEXT="${3:-}"
PROJECT_SLUG="${4:-${CURRENT_PROJECT:-default}}"

# Activate project context (loads project.env overrides)
set_project "$PROJECT_SLUG"

log_info "Rebasing PR #${PR_NUMBER} in ${REPO} (project: $PROJECT_SLUG)"

# --- Fetch PR Details ---
PR_JSON=$(gh pr view "$PR_NUMBER" --repo "$REPO" \
    --json headRefName,baseRefName 2>/dev/null)

if [[ -z "$PR_JSON" ]]; then
    log_error "Failed to fetch PR #${PR_NUMBER} from ${REPO}"
    exit 1
fi

PR_BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName // ""')
BASE_BRANCH=$(echo "$PR_JSON" | jq -r '.baseRefName // "main"')

if [[ -z "$PR_BRANCH" ]]; then
    log_error "Could not determine branch for PR #${PR_NUMBER}"
    exit 1
fi

# --- Resolve Repo Local Path ---
REPO_PATH=""
while IFS=$'\t' read -r conf_repo conf_path _conf_type; do
    if [[ "$conf_repo" == "$REPO" ]]; then
        REPO_PATH="$conf_path"
        break
    fi
done < <(read_repos)

if [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]]; then
    log_error "Repo path not found for $REPO in repos.conf"
    exit 1
fi

# --- Create Temporary Worktree for Rebase ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${PROJECT_SLUG}--${REPO##*/}--rebase-pr-${PR_NUMBER}"
else
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${REPO##*/}-rebase-pr-${PR_NUMBER}"
fi

# Clean up any leftover worktree
if [[ -d "$WORKTREE_DIR" ]]; then
    log_warn "Cleaning up leftover worktree at $WORKTREE_DIR"
    cd "$REPO_PATH"
    git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || rm -rf "$WORKTREE_DIR"
fi

cd "$REPO_PATH"
git fetch origin "$PR_BRANCH" "$BASE_BRANCH" 2>/dev/null || {
    log_error "Failed to fetch branches from origin"
    exit 1
}

mkdir -p ${ZAPAT_HOME:-$HOME/.zapat}/worktrees
git worktree add "$WORKTREE_DIR" "origin/${PR_BRANCH}" 2>/dev/null || {
    git worktree add "$WORKTREE_DIR" "$PR_BRANCH" 2>/dev/null || {
        log_error "Failed to create worktree for branch $PR_BRANCH"
        exit 1
    }
}

log_info "Worktree created at $WORKTREE_DIR on branch $PR_BRANCH"

# --- Attempt Rebase ---
cd "$WORKTREE_DIR"

# Ensure we're on the PR branch (not detached HEAD)
git checkout "$PR_BRANCH" 2>/dev/null || git checkout -b "$PR_BRANCH" "origin/${PR_BRANCH}" 2>/dev/null || true

REBASE_OUTPUT=""
REBASE_EXIT=0
REBASE_OUTPUT=$(git rebase "origin/${BASE_BRANCH}" 2>&1) || REBASE_EXIT=$?

if [[ $REBASE_EXIT -eq 0 ]]; then
    # --- Success: Push and notify ---
    BASE_SHA=$(git rev-parse --short "origin/${BASE_BRANCH}")

    if git push --force-with-lease origin "$PR_BRANCH" 2>/dev/null; then
        log_info "Successfully rebased PR #${PR_NUMBER} onto ${BASE_BRANCH} (${BASE_SHA})"

        # Post success comment
        gh pr comment "$PR_NUMBER" --repo "$REPO" --body "### Rebased onto latest \`${BASE_BRANCH}\`

This PR was automatically rebased onto the latest \`${BASE_BRANCH}\` branch (commit \`${BASE_SHA}\`).

Tests will re-run to verify everything still works.

---
_Auto-rebase by [Zapat](https://github.com/zapat-ai/zapat)_" 2>/dev/null || log_warn "Failed to post rebase success comment"

        # Re-add zapat-testing label to trigger test re-run
        gh pr edit "$PR_NUMBER" --repo "$REPO" \
            --add-label "zapat-testing" 2>/dev/null || log_warn "Failed to add zapat-testing label"

        _log_structured "info" "Auto-rebase succeeded" \
            "\"repo\":\"$REPO\",\"pr\":$PR_NUMBER,\"base\":\"$BASE_BRANCH\",\"base_sha\":\"$BASE_SHA\""
    else
        log_error "Rebase succeeded but push failed for PR #${PR_NUMBER}"
        gh pr comment "$PR_NUMBER" --repo "$REPO" --body "### Rebase push failed

The rebase onto \`${BASE_BRANCH}\` succeeded locally but the push failed. This may indicate the remote branch was updated concurrently.

---
_Auto-rebase by [Zapat](https://github.com/zapat-ai/zapat)_" 2>/dev/null || true
    fi
else
    # --- Conflict: Abort and notify ---
    git rebase --abort 2>/dev/null || true

    log_warn "Rebase conflict for PR #${PR_NUMBER} in ${REPO}"

    # Add needs-rebase label
    gh pr edit "$PR_NUMBER" --repo "$REPO" \
        --add-label "needs-rebase" 2>/dev/null || log_warn "Failed to add needs-rebase label"

    # Post conflict comment
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "### Rebase conflict detected

This PR could not be automatically rebased onto the latest \`${BASE_BRANCH}\` branch.

**What happened:** Another PR was merged into \`${BASE_BRANCH}\` and the changes conflict with this branch.

**What to do:**
- Resolve the conflicts manually, or
- Comment \`@zapat please rebase\` to retry after fixing

<details>
<summary>Conflict details</summary>

\`\`\`
${REBASE_OUTPUT}
\`\`\`

</details>

---
_Auto-rebase by [Zapat](https://github.com/zapat-ai/zapat)_" 2>/dev/null || log_warn "Failed to post rebase conflict comment"

    # Slack notification for conflicts
    "$SCRIPT_DIR/bin/notify.sh" \
        --slack \
        --message "Rebase conflict on PR #${PR_NUMBER} in ${REPO}. Manual resolution needed.\nhttps://github.com/${REPO}/pull/${PR_NUMBER}" \
        --job-name "auto-rebase" \
        --status warning 2>/dev/null || true

    _log_structured "warn" "Auto-rebase conflict" \
        "\"repo\":\"$REPO\",\"pr\":$PR_NUMBER,\"base\":\"$BASE_BRANCH\""
fi

# --- Cleanup Worktree ---
cd "$REPO_PATH"
git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || {
    log_warn "Failed to remove worktree at $WORKTREE_DIR, will clean up later"
}

log_info "Auto-rebase complete for PR #${PR_NUMBER}"
