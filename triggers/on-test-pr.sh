#!/usr/bin/env bash
# Zapat - Test Runner Trigger
# Launches Claude to run the test suite on a PR and post results.
# Usage: on-test-pr.sh OWNER/REPO PR_NUMBER

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/item-state.sh"
source "$SCRIPT_DIR/lib/tmux-helpers.sh"
load_env

# --- Args ---
if [[ $# -lt 2 ]]; then
    log_error "Usage: on-test-pr.sh OWNER/REPO PR_NUMBER"
    exit 1
fi

REPO="$1"
PR_NUMBER="$2"
_MENTION_CONTEXT="${3:-}"
PROJECT_SLUG="${4:-${CURRENT_PROJECT:-default}}"

# Activate project context (loads project.env overrides)
set_project "$PROJECT_SLUG"

log_info "Running tests for PR #${PR_NUMBER} in ${REPO} (project: $PROJECT_SLUG)"

# --- Add status label ---
gh pr edit "$PR_NUMBER" --repo "$REPO" \
    --add-label "zapat-testing" 2>/dev/null || log_warn "Failed to add zapat-testing label to PR #${PR_NUMBER}"

# --- Concurrency Slot (shares slots with agent-work) ---
SLOT_DIR="$SCRIPT_DIR/state/agent-work-slots"
MAX_CONCURRENT=${MAX_CONCURRENT_WORK:-10}
ITEM_STATE_FILE=$(create_item_state "$REPO" "test" "$PR_NUMBER" "running" "$PROJECT_SLUG") || true
if ! acquire_slot "$SLOT_DIR" "$MAX_CONCURRENT"; then
    log_info "At capacity ($MAX_CONCURRENT concurrent sessions), skipping test for PR #${PR_NUMBER}"
    [[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "capacity_rejected"
    exit 0
fi
trap 'cleanup_on_exit "$SLOT_FILE" "$ITEM_STATE_FILE" $?' EXIT

# --- Fetch PR Details ---
PR_JSON=$(gh pr view "$PR_NUMBER" --repo "$REPO" \
    --json title,headRefName 2>/dev/null)

if [[ -z "$PR_JSON" ]]; then
    log_error "Failed to fetch PR #${PR_NUMBER} from ${REPO}"
    exit 1
fi

PR_TITLE=$(echo "$PR_JSON" | jq -r '.title // "No title"')
PR_BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName // ""')

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
    "$SCRIPT_DIR/bin/notify.sh" \
        --slack \
        --message "Agent-test failed for PR #${PR_NUMBER}: repo path not found for ${REPO}" \
        --job-name "agent-test" \
        --status failure
    exit 1
fi

# --- Create Git Worktree from PR Branch ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${PROJECT_SLUG}--${REPO##*/}--test-pr-${PR_NUMBER}"
else
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${REPO##*/}-test-pr-${PR_NUMBER}"
fi

# Clean up any leftover worktree
if [[ -d "$WORKTREE_DIR" ]]; then
    log_warn "Cleaning up leftover worktree at $WORKTREE_DIR"
    cd "$REPO_PATH"
    git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || rm -rf "$WORKTREE_DIR"
fi

cd "$REPO_PATH"
git fetch origin "$PR_BRANCH" 2>/dev/null || true

mkdir -p "${ZAPAT_HOME:-$HOME/.zapat}"/worktrees
git worktree add "$WORKTREE_DIR" "origin/${PR_BRANCH}" 2>/dev/null || {
    git worktree add "$WORKTREE_DIR" "$PR_BRANCH" 2>/dev/null || {
        log_error "Failed to create worktree for branch $PR_BRANCH"
        "$SCRIPT_DIR/bin/notify.sh" \
            --slack \
            --message "Agent-test failed for PR #${PR_NUMBER}: could not create worktree for branch ${PR_BRANCH}" \
            --job-name "agent-test" \
            --status failure
        exit 1
    }
}

log_info "Worktree created at $WORKTREE_DIR on branch $PR_BRANCH"

# --- Build Prompt ---
FINAL_PROMPT=$(substitute_prompt "$SCRIPT_DIR/prompts/test-pr.txt" \
    "REPO=$REPO" \
    "PR_NUMBER=$PR_NUMBER" \
    "PR_TITLE=$PR_TITLE" \
    "PR_BRANCH=$PR_BRANCH")

# Write prompt to temp file
PROMPT_FILE=$(mktemp)
echo "$FINAL_PROMPT" > "$PROMPT_FILE"

# --- Launch Claude Session ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    TMUX_WINDOW="${PROJECT_SLUG}:test-${REPO##*/}-pr-${PR_NUMBER}"
else
    TMUX_WINDOW="test-${REPO##*/}-pr-${PR_NUMBER}"
fi
START_TIME=$(date +%s)

launch_claude_session "$TMUX_WINDOW" "$WORKTREE_DIR" "$PROMPT_FILE"
rm -f "$PROMPT_FILE"

# --- Monitor with Timeout ---
TIMEOUT=${TIMEOUT_TEST_PR:-1200}
monitor_session "$TMUX_WINDOW" "$TIMEOUT" 30 "test-${REPO##*/}#${PR_NUMBER}"
monitor_exit=$?

if [[ $monitor_exit -eq 2 ]]; then
    log_warn "Session rate limited, scheduling retry for PR #${PR_NUMBER} test"
    [[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "rate_limited"
    [[ -n "${SLOT_FILE:-}" && -f "${SLOT_FILE:-}" ]] && release_slot "$SLOT_FILE"
    exit 0
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log_info "Test session ended for PR #${PR_NUMBER} (duration: ${DURATION}s)"

# --- Remove zapat-testing label ---
gh pr edit "$PR_NUMBER" --repo "$REPO" \
    --remove-label "zapat-testing" 2>/dev/null || log_warn "Failed to remove zapat-testing label from PR #${PR_NUMBER}"

# --- Record Metrics ---
if command -v node &>/dev/null && [[ -f "$SCRIPT_DIR/bin/zapat" ]]; then
    "$SCRIPT_DIR/bin/zapat" metrics record "$(cat <<METRICSEOF
{"timestamp":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","job":"agent-test","repo":"$REPO","item":"pr#$PR_NUMBER","exit_code":0,"start":"$(date -u -r "$START_TIME" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")","end":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","duration_s":$DURATION,"status":"completed"}
METRICSEOF
)" 2>/dev/null || true
fi

# --- Notify ---
"$SCRIPT_DIR/bin/notify.sh" \
    --slack \
    --message "Test run completed for PR #${PR_NUMBER} (${PR_TITLE}) in ${REPO}.\nDuration: ${DURATION}s\nhttps://github.com/${REPO}/pull/${PR_NUMBER}" \
    --job-name "agent-test" \
    --status success || log_warn "Slack notification failed"

# --- Cleanup Worktree ---
cd "$REPO_PATH"
git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || {
    log_warn "Failed to remove worktree at $WORKTREE_DIR, will clean up later"
}

# --- Update Item State ---
[[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "completed"

log_info "Agent-test complete for PR #${PR_NUMBER}"
