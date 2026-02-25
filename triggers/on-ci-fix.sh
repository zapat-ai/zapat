#!/usr/bin/env bash
# Zapat - CI Auto-Fix Trigger
# Lightweight single-agent fix for trivial CI failures (lint, type, format).
# Uses utility model (Haiku) for cost efficiency.
# Usage: on-ci-fix.sh OWNER/REPO PR_NUMBER [MENTION_CONTEXT] [PROJECT_SLUG]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/item-state.sh"
source "$SCRIPT_DIR/lib/tmux-helpers.sh"
source "$SCRIPT_DIR/lib/ci-analysis.sh"
load_env

# --- Args ---
if [[ $# -lt 2 ]]; then
    log_error "Usage: on-ci-fix.sh OWNER/REPO PR_NUMBER"
    exit 1
fi

REPO="$1"
PR_NUMBER="$2"
_MENTION_CONTEXT="${3:-}"
PROJECT_SLUG="${4:-${CURRENT_PROJECT:-default}}"

# Activate project context (loads project.env overrides)
set_project "$PROJECT_SLUG"

log_info "CI auto-fix for PR #${PR_NUMBER} in ${REPO} (project: $PROJECT_SLUG)"

# --- Check CI fix attempt counter ---
CI_FIX_ATTEMPTS=$(get_ci_fix_attempts "$REPO" "test" "$PR_NUMBER" "$PROJECT_SLUG")
MAX_CI_FIX=${MAX_CI_FIX_ATTEMPTS:-2}

if [[ "$CI_FIX_ATTEMPTS" -ge "$MAX_CI_FIX" ]]; then
    # Exhausted auto-fix attempts — escalate to full rework
    log_warn "CI auto-fix attempts exhausted (${CI_FIX_ATTEMPTS}/${MAX_CI_FIX}) for PR #${PR_NUMBER}. Escalating to rework."
    gh pr edit "$PR_NUMBER" --repo "$REPO" \
        --remove-label "zapat-ci-fix" \
        --add-label "zapat-rework" 2>/dev/null || log_warn "Failed to update labels on PR #${PR_NUMBER}"

    # Post handoff context if available
    source "$SCRIPT_DIR/lib/handoff.sh" 2>/dev/null || true
    if type post_handoff_comment &>/dev/null; then
        FAILURE_CTX=$(extract_failure_context "$REPO" "$PR_NUMBER")
        post_handoff_comment "$REPO" "$PR_NUMBER" "ci_fix_exhausted" \
            "Auto-fix attempted ${CI_FIX_ATTEMPTS} times without success.

**Last failure:**
\`\`\`
${FAILURE_CTX}
\`\`\`" || true
    fi

    "$SCRIPT_DIR/bin/notify.sh" \
        --slack \
        --message "CI auto-fix exhausted (${CI_FIX_ATTEMPTS}/${MAX_CI_FIX}) for PR #${PR_NUMBER} in ${REPO}. Escalating to full rework.\nhttps://github.com/${REPO}/pull/${PR_NUMBER}" \
        --job-name "ci-fix" \
        --status warning 2>/dev/null || true
    exit 0
fi

# --- Concurrency Slot (shares slots with agent-work) ---
SLOT_DIR="$SCRIPT_DIR/state/agent-work-slots"
MAX_CONCURRENT=${MAX_CONCURRENT_WORK:-10}
ITEM_STATE_FILE=$(create_item_state "$REPO" "ci-fix" "$PR_NUMBER" "running" "$PROJECT_SLUG") || true
if ! acquire_slot "$SLOT_DIR" "$MAX_CONCURRENT" "ci-fix" "$REPO" "$PR_NUMBER"; then
    log_info "At capacity ($MAX_CONCURRENT concurrent sessions), skipping CI fix for PR #${PR_NUMBER}"
    [[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "capacity_rejected"
    exit 0
fi
trap 'cleanup_on_exit "$SLOT_FILE" "$ITEM_STATE_FILE" $?' EXIT

# --- Increment CI fix counter ---
increment_ci_fix_attempts "$REPO" "test" "$PR_NUMBER" "$PROJECT_SLUG"

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

# --- Extract failure context ---
FAILURE_CONTEXT=$(extract_failure_context "$REPO" "$PR_NUMBER")

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
        --message "CI auto-fix failed for PR #${PR_NUMBER}: repo path not found for ${REPO}" \
        --job-name "ci-fix" \
        --status failure
    exit 1
fi

# --- Create Git Worktree from PR Branch ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${PROJECT_SLUG}--${REPO##*/}--ci-fix-pr-${PR_NUMBER}"
else
    WORKTREE_DIR="${ZAPAT_HOME:-$HOME/.zapat}/worktrees/${REPO##*/}-ci-fix-pr-${PR_NUMBER}"
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
            --message "CI auto-fix failed for PR #${PR_NUMBER}: could not create worktree for branch ${PR_BRANCH}" \
            --job-name "ci-fix" \
            --status failure
        exit 1
    }
}

log_info "Worktree created at $WORKTREE_DIR on branch $PR_BRANCH"

# --- Copy slim CLAUDE.md into worktree ---
cp "$SCRIPT_DIR/CLAUDE-pipeline.md" "$WORKTREE_DIR/CLAUDE.md"

# --- Build Prompt ---
FINAL_PROMPT=$(substitute_prompt "$SCRIPT_DIR/prompts/ci-fix.txt" \
    "REPO=$REPO" \
    "PR_NUMBER=$PR_NUMBER" \
    "PR_TITLE=$PR_TITLE" \
    "PR_BRANCH=$PR_BRANCH" \
    "FAILURE_CONTEXT=$FAILURE_CONTEXT" \
    "REPO_TYPE=$REPO_TYPE")

# Write prompt to temp file
PROMPT_FILE=$(mktemp)
echo "$FINAL_PROMPT" > "$PROMPT_FILE"

# --- Launch Claude Session (utility model for cost efficiency) ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    TMUX_WINDOW="${PROJECT_SLUG}:ci-fix-${REPO##*/}-pr-${PR_NUMBER}"
else
    TMUX_WINDOW="ci-fix-${REPO##*/}-pr-${PR_NUMBER}"
fi
START_TIME=$(date +%s)

JOB_CONTEXT="fixing CI for PR #${PR_NUMBER} (${PR_TITLE}) in ${REPO}"
launch_claude_session "$TMUX_WINDOW" "$WORKTREE_DIR" "$PROMPT_FILE" "" "${CLAUDE_UTILITY_MODEL:-claude-haiku-4-5-20251001}" "$JOB_CONTEXT"
rm -f "$PROMPT_FILE"

# --- Monitor with Timeout ---
TIMEOUT=${TIMEOUT_TEST_PR:-1200}
monitor_session "$TMUX_WINDOW" "$TIMEOUT" 30 "ci-fix-${REPO##*/}#${PR_NUMBER}" "$JOB_CONTEXT"
monitor_exit=$?

if [[ $monitor_exit -eq 2 ]]; then
    log_warn "Session rate limited, scheduling retry for PR #${PR_NUMBER} CI fix"
    [[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "rate_limited"
    [[ -n "${SLOT_FILE:-}" && -f "${SLOT_FILE:-}" ]] && release_slot "$SLOT_FILE"
    exit 0
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log_info "CI auto-fix session ended for PR #${PR_NUMBER} (duration: ${DURATION}s)"

# --- After fix: send back to testing ---
# Remove ci-fix label, add testing label to re-run tests
gh pr edit "$PR_NUMBER" --repo "$REPO" \
    --remove-label "zapat-ci-fix" \
    --add-label "zapat-testing" 2>/dev/null || log_warn "Failed to update labels on PR #${PR_NUMBER}"
log_info "CI fix applied for PR #${PR_NUMBER}, added zapat-testing label for re-test"

# --- Record Metrics ---
if command -v node &>/dev/null && [[ -f "$SCRIPT_DIR/bin/zapat" ]]; then
    "$SCRIPT_DIR/bin/zapat" metrics record "$(cat <<METRICSEOF
{"timestamp":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","job":"ci-fix","repo":"$REPO","item":"pr#$PR_NUMBER","exit_code":0,"start":"$(date -u -r "$START_TIME" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")","end":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","duration_s":$DURATION,"status":"completed"}
METRICSEOF
)" 2>/dev/null || true
fi

# --- Notify ---
"$SCRIPT_DIR/bin/notify.sh" \
    --slack \
    --message "CI auto-fix applied for PR #${PR_NUMBER} (${PR_TITLE}) in ${REPO}.\nDuration: ${DURATION}s. Re-running tests.\nhttps://github.com/${REPO}/pull/${PR_NUMBER}" \
    --job-name "ci-fix" \
    --status success || log_warn "Slack notification failed"

# --- Cleanup Worktree ---
cd "$REPO_PATH"
git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || {
    log_warn "Failed to remove worktree at $WORKTREE_DIR, will clean up later"
}

# --- Update Item State ---
[[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "completed"

log_info "CI auto-fix complete for PR #${PR_NUMBER}"
