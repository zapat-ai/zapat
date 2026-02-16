#!/usr/bin/env bash
# Zapat - PR Rework Trigger
# Launches an Agent Team to address review feedback on a PR.
# Usage: on-rework-pr.sh OWNER/REPO PR_NUMBER

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/item-state.sh"
source "$SCRIPT_DIR/lib/tmux-helpers.sh"
load_env

# --- Args ---
if [[ $# -lt 2 ]]; then
    log_error "Usage: on-rework-pr.sh OWNER/REPO PR_NUMBER"
    exit 1
fi

REPO="$1"
PR_NUMBER="$2"
_MENTION_CONTEXT="${3:-}"
PROJECT_SLUG="${4:-${CURRENT_PROJECT:-default}}"

# Activate project context (loads project.env overrides)
set_project "$PROJECT_SLUG"

log_info "Starting rework for PR #${PR_NUMBER} in ${REPO} (project: $PROJECT_SLUG)"

# --- Concurrency Slot (shares slots with agent-work) ---
SLOT_DIR="$SCRIPT_DIR/state/agent-work-slots"
MAX_CONCURRENT=${MAX_CONCURRENT_WORK:-10}
if ! acquire_slot "$SLOT_DIR" "$MAX_CONCURRENT"; then
    log_info "At capacity ($MAX_CONCURRENT concurrent sessions), skipping rework PR #${PR_NUMBER}"
    exit 0
fi
trap 'cleanup_on_exit "$SLOT_FILE"' EXIT

# --- Fetch PR Details ---
PR_JSON=$(gh pr view "$PR_NUMBER" --repo "$REPO" \
    --json title,body,headRefName 2>/dev/null)

if [[ -z "$PR_JSON" ]]; then
    log_error "Failed to fetch PR #${PR_NUMBER} from ${REPO}"
    exit 1
fi

PR_TITLE=$(echo "$PR_JSON" | jq -r '.title // "No title"')
PR_BODY=$(echo "$PR_JSON" | jq -r '.body // "No description"')
PR_BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName // ""')

if [[ -z "$PR_BRANCH" ]]; then
    log_error "Could not determine branch for PR #${PR_NUMBER}"
    exit 1
fi

# --- Fetch Review Comments ---
REVIEW_COMMENTS=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
    --jq '.[].body' 2>/dev/null || echo "No inline comments")

PR_REVIEWS=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
    --jq '.[] | select(.state != "APPROVED" and .body != "") | .body' 2>/dev/null || echo "No review comments")

# Also fetch issue comments (human feedback posted as regular comments)
ISSUE_COMMENTS=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    --jq '.[-3:][].body' 2>/dev/null || echo "No issue comments")

# Combine all feedback
ALL_FEEDBACK="### Inline Review Comments
${REVIEW_COMMENTS}

### Review Submissions
${PR_REVIEWS}

### PR Comments
${ISSUE_COMMENTS}"

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
    "$SCRIPT_DIR/bin/notify.sh" \
        --slack \
        --message "Agent-rework failed for PR #${PR_NUMBER}: repo path not found for ${REPO}" \
        --job-name "agent-rework" \
        --status failure
    exit 1
fi

# --- Create Git Worktree from Existing Branch ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${PROJECT_SLUG}--${REPO##*/}--pr-${PR_NUMBER}"
else
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${REPO##*/}-pr-${PR_NUMBER}"
fi

# Clean up any leftover worktree
if [[ -d "$WORKTREE_DIR" ]]; then
    log_warn "Cleaning up leftover worktree at $WORKTREE_DIR"
    cd "$REPO_PATH"
    git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || rm -rf "$WORKTREE_DIR"
fi

cd "$REPO_PATH"
git fetch origin "$PR_BRANCH" 2>/dev/null || true

mkdir -p ${ZAPAT_HOME:-$HOME/.zapat}/worktrees
git worktree add "$WORKTREE_DIR" "origin/${PR_BRANCH}" 2>/dev/null || {
    # Try with local branch
    git worktree add "$WORKTREE_DIR" "$PR_BRANCH" 2>/dev/null || {
        log_error "Failed to create worktree for branch $PR_BRANCH"
        "$SCRIPT_DIR/bin/notify.sh" \
            --slack \
            --message "Agent-rework failed for PR #${PR_NUMBER}: could not create worktree for branch ${PR_BRANCH}" \
            --job-name "agent-rework" \
            --status failure
        exit 1
    }
}

log_info "Worktree created at $WORKTREE_DIR on branch $PR_BRANCH"

# --- Build Prompt ---
FINAL_PROMPT=$(substitute_prompt "$SCRIPT_DIR/prompts/rework-pr.txt" \
    "REPO=$REPO" \
    "PR_NUMBER=$PR_NUMBER" \
    "PR_TITLE=$PR_TITLE" \
    "PR_BODY=$PR_BODY" \
    "PR_BRANCH=$PR_BRANCH" \
    "REVIEW_COMMENTS=$ALL_FEEDBACK" \
    "PR_REVIEWS=$PR_REVIEWS")

# Write prompt to temp file
PROMPT_FILE=$(mktemp)
echo "$FINAL_PROMPT" > "$PROMPT_FILE"

# --- Launch Claude Interactively in tmux ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    TMUX_WINDOW="${PROJECT_SLUG}:rework-${REPO##*/}-pr-${PR_NUMBER}"
else
    TMUX_WINDOW="rework-${REPO##*/}-pr-${PR_NUMBER}"
fi

launch_claude_session "$TMUX_WINDOW" "$WORKTREE_DIR" "$PROMPT_FILE"
rm -f "$PROMPT_FILE"

# --- Monitor with Timeout ---
TIMEOUT=${TIMEOUT_IMPLEMENT:-1800}
monitor_session "$TMUX_WINDOW" "$TIMEOUT" 30

log_info "Agent-rework session ended for PR #${PR_NUMBER}"

# --- Update Labels ---
# Remove zapat-rework, re-add zapat-review for another review pass, add zapat-testing for automated testing
gh pr edit "$PR_NUMBER" --repo "$REPO" \
    --remove-label "zapat-rework" \
    --add-label "zapat-review" \
    --add-label "zapat-testing" 2>/dev/null || log_warn "Failed to update labels on PR #${PR_NUMBER}"
log_info "Added zapat-review and zapat-testing labels to PR #${PR_NUMBER}"

# --- Notify ---
"$SCRIPT_DIR/bin/notify.sh" \
    --slack \
    --message "Agent team addressed review feedback on PR #${PR_NUMBER} (${PR_TITLE}) in ${REPO}.\nThe PR has been re-labeled with zapat-review for another review pass." \
    --job-name "agent-rework" \
    --status success || log_warn "Slack notification failed"

# --- Cleanup Worktree ---
cd "$REPO_PATH"
git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || {
    log_warn "Failed to remove worktree at $WORKTREE_DIR, will clean up later"
}

log_info "Agent-rework complete for PR #${PR_NUMBER}"
