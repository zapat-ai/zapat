#!/usr/bin/env bash
# Zapat - Visual Verification Trigger
# Starts the dev server, captures screenshots with Playwright, and launches a UX
# review agent to check for visual regressions.
# Usage: on-visual-verify.sh OWNER/REPO PR_NUMBER [MENTION_CONTEXT] [PROJECT_SLUG]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/item-state.sh"
source "$SCRIPT_DIR/lib/tmux-helpers.sh"
source "$SCRIPT_DIR/lib/visual-helpers.sh"
load_env

# --- Args ---
if [[ $# -lt 2 ]]; then
    log_error "Usage: on-visual-verify.sh OWNER/REPO PR_NUMBER"
    exit 1
fi

REPO="$1"
PR_NUMBER="$2"
_MENTION_CONTEXT="${3:-}"
PROJECT_SLUG="${4:-${CURRENT_PROJECT:-default}}"

# Activate project context (loads project.env overrides)
set_project "$PROJECT_SLUG"

log_info "Visual verification for PR #${PR_NUMBER} in ${REPO} (project: $PROJECT_SLUG)"

# --- Concurrency Slot ---
SLOT_DIR="$SCRIPT_DIR/state/agent-work-slots"
MAX_CONCURRENT=${MAX_CONCURRENT_WORK:-10}
ITEM_STATE_FILE=$(create_item_state "$REPO" "visual" "$PR_NUMBER" "running" "$PROJECT_SLUG") || true
if ! acquire_slot "$SLOT_DIR" "$MAX_CONCURRENT" "visual" "$REPO" "$PR_NUMBER"; then
    log_info "At capacity ($MAX_CONCURRENT concurrent sessions), skipping visual verify for PR #${PR_NUMBER}"
    [[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "capacity_rejected"
    exit 0
fi
# shellcheck disable=SC2154 # _exit_rc is assigned inside the trap at runtime via $?
trap '_exit_rc=$?; stop_dev_server 2>/dev/null; cleanup_on_exit "$SLOT_FILE" "$ITEM_STATE_FILE" $_exit_rc' EXIT

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
        --message "Visual verify failed for PR #${PR_NUMBER}: repo path not found for ${REPO}" \
        --job-name "visual-verify" \
        --status failure
    exit 1
fi

# --- Create Git Worktree from PR Branch ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${PROJECT_SLUG}--${REPO##*/}--visual-pr-${PR_NUMBER}"
else
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${REPO##*/}-visual-pr-${PR_NUMBER}"
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
            --message "Visual verify failed for PR #${PR_NUMBER}: could not create worktree for branch ${PR_BRANCH}" \
            --job-name "visual-verify" \
            --status failure
        exit 1
    }
}

log_info "Worktree created at $WORKTREE_DIR on branch $PR_BRANCH"

# --- Get dev server config ---
get_dev_server_config "$REPO" "$WORKTREE_DIR"

# --- Start Dev Server ---
DEV_SERVER_PID=""
if ! start_dev_server "$WORKTREE_DIR" "$VISUAL_DEV_CMD" "$VISUAL_DEV_PORT"; then
    log_error "Dev server failed to start for PR #${PR_NUMBER}"
    # Fall through to review without screenshots
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "Visual verification skipped: dev server failed to start. Proceeding to code review.

<!-- visual-verify-skipped -->" 2>/dev/null || true
    gh pr edit "$PR_NUMBER" --repo "$REPO" \
        --remove-label "zapat-visual" \
        --add-label "zapat-review" 2>/dev/null || log_warn "Failed to update labels"
    exit 0
fi

# --- Capture Screenshots ---
SCREENSHOT_DIR="${WORKTREE_DIR}/.zapat-screenshots"
VIEWPORTS="${VISUAL_VERIFY_VIEWPORTS:-1920x1080}"

if ! capture_screenshots "$VISUAL_DEV_PORT" "$VISUAL_PAGES" "$VIEWPORTS" "$SCREENSHOT_DIR"; then
    log_warn "Screenshot capture failed for PR #${PR_NUMBER}, proceeding to review without visual check"
    stop_dev_server
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "Visual verification skipped: screenshot capture failed. Proceeding to code review.

<!-- visual-verify-skipped -->" 2>/dev/null || true
    gh pr edit "$PR_NUMBER" --repo "$REPO" \
        --remove-label "zapat-visual" \
        --add-label "zapat-review" 2>/dev/null || log_warn "Failed to update labels"
    exit 0
fi

# Stop dev server before launching agent (saves resources)
stop_dev_server

# --- Copy slim CLAUDE.md into worktree ---
cp "$SCRIPT_DIR/CLAUDE-pipeline.md" "$WORKTREE_DIR/CLAUDE.md"

# --- Build Prompt ---
FINAL_PROMPT=$(substitute_prompt "$SCRIPT_DIR/prompts/visual-verify.txt" \
    "REPO=$REPO" \
    "PR_NUMBER=$PR_NUMBER" \
    "PR_TITLE=$PR_TITLE" \
    "PR_BRANCH=$PR_BRANCH" \
    "REPO_TYPE=$REPO_TYPE" \
    "SCREENSHOT_DIR=$SCREENSHOT_DIR")

# Write prompt to temp file
PROMPT_FILE=$(mktemp)
echo "$FINAL_PROMPT" > "$PROMPT_FILE"

# --- Launch Claude Session ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    TMUX_WINDOW="${PROJECT_SLUG}:visual-${REPO##*/}-pr-${PR_NUMBER}"
else
    TMUX_WINDOW="visual-${REPO##*/}-pr-${PR_NUMBER}"
fi
START_TIME=$(date +%s)

JOB_CONTEXT="visual verification of PR #${PR_NUMBER} (${PR_TITLE}) in ${REPO}"
launch_claude_session "$TMUX_WINDOW" "$WORKTREE_DIR" "$PROMPT_FILE" "" "${CLAUDE_SUBAGENT_MODEL:-claude-sonnet-4-6}" "$JOB_CONTEXT"
rm -f "$PROMPT_FILE"

# --- Monitor with Timeout ---
TIMEOUT=${TIMEOUT_VISUAL_VERIFY:-600}
monitor_session "$TMUX_WINDOW" "$TIMEOUT" 30 "visual-${REPO##*/}#${PR_NUMBER}" "$JOB_CONTEXT"
monitor_exit=$?

if [[ $monitor_exit -eq 2 ]]; then
    log_warn "Session rate limited, scheduling retry for PR #${PR_NUMBER} visual verify"
    [[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "rate_limited"
    [[ -n "${SLOT_FILE:-}" && -f "${SLOT_FILE:-}" ]] && release_slot "$SLOT_FILE"
    exit 0
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log_info "Visual verification session ended for PR #${PR_NUMBER} (duration: ${DURATION}s)"

# --- Determine visual outcome from PR comments ---
VISUAL_COMMENTS=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    --jq '.[].body' 2>/dev/null || echo "")
VISUAL_PASSED=false
if echo "$VISUAL_COMMENTS" | grep -qF "visual-verify-passed"; then
    VISUAL_PASSED=true
fi
VISUAL_SKIPPED=false
if echo "$VISUAL_COMMENTS" | grep -qF "visual-verify-skipped"; then
    VISUAL_SKIPPED=true
fi

# --- Update labels based on visual outcome ---
if [[ "$VISUAL_PASSED" == "true" || "$VISUAL_SKIPPED" == "true" ]]; then
    # Visual passed (or skipped): move to review
    gh pr edit "$PR_NUMBER" --repo "$REPO" \
        --remove-label "zapat-visual" \
        --add-label "zapat-review" 2>/dev/null || log_warn "Failed to update labels on PR #${PR_NUMBER}"
    log_info "Visual verification passed for PR #${PR_NUMBER}, added zapat-review label"
else
    # Visual failed: send back to rework
    gh pr edit "$PR_NUMBER" --repo "$REPO" \
        --remove-label "zapat-visual" \
        --add-label "zapat-rework" 2>/dev/null || log_warn "Failed to update labels on PR #${PR_NUMBER}"
    log_info "Visual verification failed for PR #${PR_NUMBER}, added zapat-rework label"
fi

# --- Record Metrics ---
if command -v node &>/dev/null && [[ -f "$SCRIPT_DIR/bin/zapat" ]]; then
    "$SCRIPT_DIR/bin/zapat" metrics record "$(cat <<METRICSEOF
{"timestamp":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","job":"visual-verify","repo":"$REPO","item":"pr#$PR_NUMBER","exit_code":0,"start":"$(date -u -r "$START_TIME" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")","end":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","duration_s":$DURATION,"status":"completed"}
METRICSEOF
)" 2>/dev/null || true
fi

# --- Notify ---
"$SCRIPT_DIR/bin/notify.sh" \
    --slack \
    --message "Visual verification completed for PR #${PR_NUMBER} (${PR_TITLE}) in ${REPO}.\nDuration: ${DURATION}s\nhttps://github.com/${REPO}/pull/${PR_NUMBER}" \
    --job-name "visual-verify" \
    --status success || log_warn "Slack notification failed"

# --- Cleanup Worktree ---
cd "$REPO_PATH"
git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || {
    log_warn "Failed to remove worktree at $WORKTREE_DIR, will clean up later"
}

# --- Update Item State ---
[[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "completed"

log_info "Visual verification complete for PR #${PR_NUMBER}"
