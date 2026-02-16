#!/usr/bin/env bash
# Zapat - Research Issue Trigger
# Launches an Agent Team to research/analyze an issue (strategy, planning, investigation).
# No git worktree needed — research agents read code and create issues/comments, not code changes.
# Usage: on-research-issue.sh OWNER/REPO ISSUE_NUMBER

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/item-state.sh"
source "$SCRIPT_DIR/lib/tmux-helpers.sh"
load_env

# --- Args ---
if [[ $# -lt 2 ]]; then
    log_error "Usage: on-research-issue.sh OWNER/REPO ISSUE_NUMBER"
    exit 1
fi

REPO="$1"
ISSUE_NUMBER="$2"
_MENTION_CONTEXT="${3:-}"
PROJECT_SLUG="${4:-${CURRENT_PROJECT:-default}}"

# Activate project context (loads project.env overrides)
set_project "$PROJECT_SLUG"

log_info "Starting research for issue #${ISSUE_NUMBER} in ${REPO} (project: $PROJECT_SLUG)"

# --- Add status label ---
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --add-label "zapat-researching" 2>/dev/null || log_warn "Failed to add zapat-researching label to issue #${ISSUE_NUMBER}"

# --- Concurrency Slot ---
SLOT_DIR="$SCRIPT_DIR/state/agent-work-slots"
MAX_CONCURRENT=${MAX_CONCURRENT_WORK:-10}
ITEM_STATE_FILE=$(create_item_state "$REPO" "research" "$ISSUE_NUMBER" "running" "$PROJECT_SLUG") || true
if ! acquire_slot "$SLOT_DIR" "$MAX_CONCURRENT"; then
    log_info "At capacity ($MAX_CONCURRENT concurrent sessions), skipping research issue #${ISSUE_NUMBER}"
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
while IFS=$'\t' read -r conf_repo conf_path _conf_type; do
    if [[ "$conf_repo" == "$REPO" ]]; then
        REPO_PATH="$conf_path"
        break
    fi
done < <(read_repos)

if [[ -z "$REPO_PATH" || ! -d "$REPO_PATH" ]]; then
    log_warn "Repo path not found for $REPO, using automation dir"
    REPO_PATH="$SCRIPT_DIR"
fi

# --- Build Prompt ---
FINAL_PROMPT=$(substitute_prompt "$SCRIPT_DIR/prompts/research-issue.txt" \
    "REPO=$REPO" \
    "ISSUE_NUMBER=$ISSUE_NUMBER" \
    "ISSUE_TITLE=$ISSUE_TITLE" \
    "ISSUE_BODY=$ISSUE_BODY" \
    "ISSUE_LABELS=$ISSUE_LABELS")

# Write prompt to temp file (avoids tmux send-keys escaping issues)
PROMPT_FILE=$(mktemp)
echo "$FINAL_PROMPT" > "$PROMPT_FILE"

# --- Launch Claude Interactively in tmux ---
# Research agents run in the repo's main directory (read-only, no worktree needed)
if [[ "$PROJECT_SLUG" != "default" ]]; then
    TMUX_WINDOW="${PROJECT_SLUG}:research-${REPO##*/}-${ISSUE_NUMBER}"
else
    TMUX_WINDOW="research-${REPO##*/}-${ISSUE_NUMBER}"
fi

launch_claude_session "$TMUX_WINDOW" "$REPO_PATH" "$PROMPT_FILE"
rm -f "$PROMPT_FILE"

# --- Monitor with Timeout ---
TIMEOUT=${TIMEOUT_RESEARCH:-1800}
monitor_session "$TMUX_WINDOW" "$TIMEOUT" 30 "research-${REPO##*/}#${ISSUE_NUMBER}"
monitor_exit=$?

if [[ $monitor_exit -eq 2 ]]; then
    log_warn "Session rate limited, scheduling retry for issue #${ISSUE_NUMBER} research"
    [[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "rate_limited"
    [[ -n "${SLOT_FILE:-}" && -f "${SLOT_FILE:-}" ]] && release_slot "$SLOT_FILE"
    exit 0
fi

log_info "Research session ended for issue #${ISSUE_NUMBER}"

# --- Remove status label and agent-research label (prevent reprocessing) ---
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "zapat-researching" \
    --remove-label "agent-research" 2>/dev/null || log_warn "Failed to remove labels from issue #${ISSUE_NUMBER}"

# --- Record Metrics ---
_log_structured "info" "Research completed for issue #${ISSUE_NUMBER} in ${REPO}" \
    "\"type\":\"research\",\"repo\":\"$REPO\",\"issue\":$ISSUE_NUMBER"

# --- Notify Slack ---
"$SCRIPT_DIR/bin/notify.sh" \
    --slack \
    --message "Research completed for issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}\nhttps://github.com/${REPO}/issues/${ISSUE_NUMBER}" \
    --job-name "agent-research" \
    --status success || log_warn "Slack notification failed"

# --- Update Item State ---
[[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "completed"

log_info "Research complete for issue #${ISSUE_NUMBER}"
