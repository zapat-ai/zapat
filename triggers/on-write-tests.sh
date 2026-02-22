#!/usr/bin/env bash
# Zapat - Write Tests Trigger
# Launches a test-writing agent to write tests for code referenced in an issue.
# Usage: on-write-tests.sh OWNER/REPO ISSUE_NUMBER

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/item-state.sh"
source "$SCRIPT_DIR/lib/provider.sh"
source "$SCRIPT_DIR/lib/tmux-helpers.sh"
load_env

# --- Args ---
if [[ $# -lt 2 ]]; then
    log_error "Usage: on-write-tests.sh OWNER/REPO ISSUE_NUMBER"
    exit 1
fi

REPO="$1"
ISSUE_NUMBER="$2"
_MENTION_CONTEXT="${3:-}"
PROJECT_SLUG="${4:-${CURRENT_PROJECT:-default}}"

# Activate project context (loads project.env overrides)
set_project "$PROJECT_SLUG"

log_info "Starting write-tests for issue #${ISSUE_NUMBER} in ${REPO} (project: $PROJECT_SLUG)"

# --- Concurrency Slot ---
SLOT_DIR="$SCRIPT_DIR/state/agent-work-slots"
MAX_CONCURRENT=${MAX_CONCURRENT_WORK:-10}
ITEM_STATE_FILE=$(create_item_state "$REPO" "write-tests" "$ISSUE_NUMBER" "running" "$PROJECT_SLUG") || true
if ! acquire_slot "$SLOT_DIR" "$MAX_CONCURRENT" "write-tests" "$REPO" "$ISSUE_NUMBER"; then
    log_info "At capacity ($MAX_CONCURRENT concurrent sessions), skipping write-tests #${ISSUE_NUMBER}"
    [[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "capacity_rejected"
    exit 0
fi
trap 'cleanup_on_exit "$SLOT_FILE" "$ITEM_STATE_FILE" $?' EXIT

# --- Fetch Issue Details ---
ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" \
    --json title,body,labels 2>/dev/null)

if [[ -z "$ISSUE_JSON" ]]; then
    log_error "Failed to fetch issue #${ISSUE_NUMBER} from ${REPO}"
    exit 1
fi

ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title // "No title"')
ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // "No description"')
ISSUE_LABELS=$(echo "$ISSUE_JSON" | jq -r '[.labels[].name] | join(", ")' 2>/dev/null || echo "none")

# --- Resolve Repo Local Path ---
REPO_PATH=""
REPO_TYPE=""
while IFS=$'\t' read -r conf_repo conf_path conf_type; do
    if [[ "$conf_repo" == "$REPO" ]]; then
        REPO_PATH="$conf_path"
        REPO_TYPE="$conf_type"
        break
    fi
done < <(read_repos)

if [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]]; then
    log_error "Repo path not found for $REPO in repos.conf"
    "$SCRIPT_DIR/bin/notify.sh" \
        --slack \
        --message "Write-tests failed for issue #${ISSUE_NUMBER}: repo path not found for ${REPO}" \
        --job-name "write-tests" \
        --status failure
    exit 1
fi

# --- Create Git Worktree ---
BRANCH_NAME="agent/write-tests-issue-${ISSUE_NUMBER}"
if [[ "$PROJECT_SLUG" != "default" ]]; then
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${PROJECT_SLUG}--${REPO##*/}--write-tests-${ISSUE_NUMBER}"
else
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${REPO##*/}-write-tests-${ISSUE_NUMBER}"
fi

# Clean up any leftover worktree from a previous failed run
if [[ -d "$WORKTREE_DIR" ]]; then
    log_warn "Cleaning up leftover worktree at $WORKTREE_DIR"
    cd "$REPO_PATH"
    git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || rm -rf "$WORKTREE_DIR"
fi

cd "$REPO_PATH"
git fetch origin main 2>/dev/null || git fetch origin master 2>/dev/null || true

# Determine default branch
DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

mkdir -p "${ZAPAT_HOME:-$HOME/.zapat}"/worktrees
git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" "origin/${DEFAULT_BRANCH}" 2>/dev/null || {
    # Branch may already exist from a previous attempt
    log_warn "Branch $BRANCH_NAME may already exist, trying checkout"
    git worktree add "$WORKTREE_DIR" "$BRANCH_NAME" 2>/dev/null || {
        log_error "Failed to create worktree for $BRANCH_NAME"
        "$SCRIPT_DIR/bin/notify.sh" \
            --slack \
            --message "Write-tests failed for issue #${ISSUE_NUMBER}: could not create worktree" \
            --job-name "write-tests" \
            --status failure
        exit 1
    }
}

log_info "Worktree created at $WORKTREE_DIR on branch $BRANCH_NAME"

# --- Copy slim CLAUDE.md into worktree ---
cp "$SCRIPT_DIR/CLAUDE-pipeline.md" "$WORKTREE_DIR/CLAUDE.md"

# --- Build Prompt ---
FINAL_PROMPT=$(substitute_prompt "$SCRIPT_DIR/prompts/write-tests.txt" \
    "REPO=$REPO" \
    "ISSUE_NUMBER=$ISSUE_NUMBER" \
    "ISSUE_TITLE=$ISSUE_TITLE" \
    "ISSUE_BODY=$ISSUE_BODY" \
    "ISSUE_LABELS=$ISSUE_LABELS" \
    "REPO_TYPE=$REPO_TYPE")

# Write prompt to temp file (avoids tmux send-keys escaping issues)
PROMPT_FILE=$(mktemp)
echo "$FINAL_PROMPT" > "$PROMPT_FILE"

# --- Launch Claude Interactively in tmux ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    TMUX_WINDOW="${PROJECT_SLUG}:write-tests-${REPO##*/}-${ISSUE_NUMBER}"
else
    TMUX_WINDOW="write-tests-${REPO##*/}-${ISSUE_NUMBER}"
fi

launch_agent_session "$TMUX_WINDOW" "$WORKTREE_DIR" "$PROMPT_FILE"
rm -f "$PROMPT_FILE"

# --- Monitor with Timeout ---
TIMEOUT=${TIMEOUT_WRITE_TESTS:-1800}
monitor_session "$TMUX_WINDOW" "$TIMEOUT" 30 "write-tests-${REPO##*/}#${ISSUE_NUMBER}"
monitor_exit=$?

if [[ $monitor_exit -eq 2 ]]; then
    log_warn "Session rate limited, scheduling retry for issue #${ISSUE_NUMBER} write-tests"
    [[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "rate_limited"
    [[ -n "${SLOT_FILE:-}" && -f "${SLOT_FILE:-}" ]] && release_slot "$SLOT_FILE"
    exit 0
fi

log_info "Write-tests session ended for issue #${ISSUE_NUMBER}"

# --- Check if PR Was Created ---
sleep 3
PR_URL=$(gh pr list --repo "$REPO" --head "$BRANCH_NAME" --json url --jq '.[0].url' 2>/dev/null || echo "")

# --- Auto-add zapat-testing label for automated testing ---
if [[ -n "$PR_URL" ]]; then
    PR_NUM_CREATED=$(gh pr list --repo "$REPO" --head "$BRANCH_NAME" --json number --jq '.[0].number' 2>/dev/null || echo "")
    if [[ -n "$PR_NUM_CREATED" ]]; then
        gh pr edit "$PR_NUM_CREATED" --repo "$REPO" \
            --add-label "zapat-testing" 2>/dev/null || log_warn "Failed to add zapat-testing label to PR #${PR_NUM_CREATED}"
        log_info "Added zapat-testing label to PR #${PR_NUM_CREATED} for automated testing"
    fi
fi

# --- Remove agent-write-tests label from the issue ---
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "agent-write-tests" 2>/dev/null || log_warn "Failed to remove agent-write-tests label from issue #${ISSUE_NUMBER}"

# --- Notify ---
if [[ -n "$PR_URL" ]]; then
    NOTIFY_MSG="Write-tests agent completed issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}\nPR: ${PR_URL}"
    NOTIFY_STATUS="success"
    log_info "PR created: $PR_URL"
else
    NOTIFY_MSG="Write-tests agent finished issue #${ISSUE_NUMBER} (${ISSUE_TITLE}) but no PR was created.\nBranch: ${BRANCH_NAME}\nCheck tmux logs for details."
    NOTIFY_STATUS="failure"
    log_warn "No PR was created for write-tests issue #${ISSUE_NUMBER}"
fi

"$SCRIPT_DIR/bin/notify.sh" \
    --slack \
    --message "$NOTIFY_MSG" \
    --job-name "write-tests" \
    --status "$NOTIFY_STATUS" || log_warn "Slack notification failed"

# --- Cleanup Worktree ---
cd "$REPO_PATH"
git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || {
    log_warn "Failed to remove worktree at $WORKTREE_DIR, will clean up later"
}

# --- Update Item State ---
if [[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]]; then
    if [[ -n "$PR_URL" ]]; then
        update_item_state "$ITEM_STATE_FILE" "completed"
    else
        update_item_state "$ITEM_STATE_FILE" "failed" "No PR created"
    fi
fi

log_info "Write-tests complete for issue #${ISSUE_NUMBER}"
