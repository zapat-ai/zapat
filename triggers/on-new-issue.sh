#!/usr/bin/env bash
# Zapat - Issue Triage Trigger
# Launches an Agent Team to triage an issue with multiple expert perspectives.
# Usage: on-new-issue.sh OWNER/REPO ISSUE_NUMBER

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/item-state.sh"
source "$SCRIPT_DIR/lib/tmux-helpers.sh"
load_env

# --- Args ---
if [[ $# -lt 2 ]]; then
    log_error "Usage: on-new-issue.sh OWNER/REPO ISSUE_NUMBER"
    exit 1
fi

REPO="$1"
ISSUE_NUMBER="$2"
MENTION_CONTEXT="${3:-}"
PROJECT_SLUG="${4:-${CURRENT_PROJECT:-default}}"

# Activate project context (loads project.env overrides)
set_project "$PROJECT_SLUG"

ITEM_STATE_FILE=$(create_item_state "$REPO" "issue" "$ISSUE_NUMBER" "running" "$PROJECT_SLUG") || true

# --- Concurrency Slot ---
SLOT_DIR="$SCRIPT_DIR/state/triage-slots"
MAX_CONCURRENT=${MAX_CONCURRENT_TRIAGE:-${MAX_CONCURRENT_WORK:-10}}
if ! acquire_slot "$SLOT_DIR" "$MAX_CONCURRENT"; then
    log_warn "At capacity ($MAX_CONCURRENT concurrent triage sessions), deferring issue #${ISSUE_NUMBER} (will retry in ~5 min)"
    [[ -n "$ITEM_STATE_FILE" && -f "$ITEM_STATE_FILE" ]] && update_item_state "$ITEM_STATE_FILE" "capacity_rejected"
    exit 0
fi
trap 'cleanup_on_exit "$SLOT_FILE" "$ITEM_STATE_FILE" $?' EXIT

log_info "Triaging issue #${ISSUE_NUMBER} in ${REPO} (project: $PROJECT_SLUG)"

# --- Add status label ---
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --add-label "zapat-triaging" 2>/dev/null || log_warn "Failed to add zapat-triaging label to issue #${ISSUE_NUMBER}"

# --- Fetch Issue Details ---
ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" \
    --json title,body,labels,comments 2>/dev/null)

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

# --- Build Mention Context Block ---
MENTION_BLOCK=""
if [[ -n "$MENTION_CONTEXT" ]]; then
    MENTION_BLOCK="## Mention Context
A user specifically requested pipeline action with this comment:
> ${MENTION_CONTEXT}

Take this instruction into account when triaging."
fi

# --- Build Prompt ---
FINAL_PROMPT=$(substitute_prompt "$SCRIPT_DIR/prompts/issue-triage.txt" \
    "REPO=$REPO" \
    "ISSUE_NUMBER=$ISSUE_NUMBER" \
    "ISSUE_TITLE=$ISSUE_TITLE" \
    "ISSUE_BODY=$ISSUE_BODY" \
    "ISSUE_LABELS=$ISSUE_LABELS" \
    "MENTION_CONTEXT=$MENTION_BLOCK")

# Write prompt to temp file (avoids tmux send-keys escaping issues)
PROMPT_FILE=$(mktemp)
echo "$FINAL_PROMPT" > "$PROMPT_FILE"

# --- Launch Claude Interactively in tmux ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    TMUX_WINDOW="${PROJECT_SLUG}:triage-${REPO##*/}-${ISSUE_NUMBER}"
else
    TMUX_WINDOW="triage-${REPO##*/}-${ISSUE_NUMBER}"
fi

launch_claude_session "$TMUX_WINDOW" "$REPO_PATH" "$PROMPT_FILE"
rm -f "$PROMPT_FILE"

# --- Monitor with Timeout ---
TIMEOUT=${TIMEOUT_ISSUE_TRIAGE:-600}
monitor_session "$TMUX_WINDOW" "$TIMEOUT" 15 "triage-${REPO##*/}#${ISSUE_NUMBER}"
monitor_exit=$?

if [[ $monitor_exit -eq 2 ]]; then
    log_warn "Session rate limited, scheduling retry for issue #${ISSUE_NUMBER} triage"
    [[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "rate_limited"
    exit 0
fi

log_info "Triage session ended for issue #${ISSUE_NUMBER}"

# --- Remove status label ---
gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
    --remove-label "zapat-triaging" 2>/dev/null || log_warn "Failed to remove zapat-triaging label from issue #${ISSUE_NUMBER}"

# --- Post-Triage Verification ---
TRIAGE_STATUS="unknown"
TRIAGE_DETAILS=""

# Check if a triage comment was posted
COMMENT_COUNT=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" \
    --jq 'length' 2>/dev/null || echo "0")
if [[ "$COMMENT_COUNT" -gt 0 ]]; then
    TRIAGE_DETAILS="Triage comment posted."
else
    TRIAGE_STATUS="warning"
    TRIAGE_DETAILS="No triage comment was posted."
fi

# Check if agent-work or agent-research label was added
CURRENT_LABELS=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
if echo "$CURRENT_LABELS" | grep -q "agent-work"; then
    TRIAGE_DETAILS="${TRIAGE_DETAILS} agent-work label added (implementation queued)."
    TRIAGE_STATUS="${TRIAGE_STATUS:-success}"
elif echo "$CURRENT_LABELS" | grep -q "agent-research"; then
    TRIAGE_DETAILS="${TRIAGE_DETAILS} agent-research label added (research team queued)."
    TRIAGE_STATUS="${TRIAGE_STATUS:-success}"
else
    TRIAGE_DETAILS="${TRIAGE_DETAILS} No agent-work/agent-research label (may need human decision)."
fi

# Default to success if no warnings
TRIAGE_STATUS="${TRIAGE_STATUS:-success}"
if [[ "$TRIAGE_STATUS" == "unknown" ]]; then
    TRIAGE_STATUS="success"
fi

# --- Notify Slack ---
"$SCRIPT_DIR/bin/notify.sh" \
    --slack \
    --message "Triage completed for issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}\n${TRIAGE_DETAILS}\nhttps://github.com/${REPO}/issues/${ISSUE_NUMBER}" \
    --job-name "issue-triage" \
    --status "$TRIAGE_STATUS" || log_warn "Slack notification failed"

# --- Update Item State ---
[[ -n "${ITEM_STATE_FILE:-}" && -f "${ITEM_STATE_FILE:-}" ]] && update_item_state "$ITEM_STATE_FILE" "completed"

log_info "Triage complete for issue #${ISSUE_NUMBER} — ${TRIAGE_DETAILS}"
