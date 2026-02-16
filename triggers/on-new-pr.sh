#!/usr/bin/env bash
# Zapat - PR Review Trigger
# Launches an Agent Team to review a PR with multiple expert perspectives.
# Usage: on-new-pr.sh OWNER/REPO PR_NUMBER

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/item-state.sh"
source "$SCRIPT_DIR/lib/tmux-helpers.sh"
load_env

# --- Args ---
if [[ $# -lt 2 ]]; then
    log_error "Usage: on-new-pr.sh OWNER/REPO PR_NUMBER"
    exit 1
fi

REPO="$1"
PR_NUMBER="$2"
MENTION_CONTEXT="${3:-}"
PROJECT_SLUG="${4:-${CURRENT_PROJECT:-default}}"

# Activate project context (loads project.env overrides)
set_project "$PROJECT_SLUG"

log_info "Reviewing PR #${PR_NUMBER} in ${REPO} (project: $PROJECT_SLUG)"

# --- Add status label ---
gh pr edit "$PR_NUMBER" --repo "$REPO" \
    --add-label "zapat-review" 2>/dev/null || log_warn "Failed to add zapat-review label to PR #${PR_NUMBER}"

# --- Fetch PR Details ---
PR_JSON=$(gh pr view "$PR_NUMBER" --repo "$REPO" \
    --json title,body,files,additions,deletions,baseRefName,headRefName 2>/dev/null)

if [[ -z "$PR_JSON" ]]; then
    log_error "Failed to fetch PR #${PR_NUMBER} from ${REPO}"
    exit 1
fi

PR_TITLE=$(echo "$PR_JSON" | jq -r '.title // "No title"')
PR_BODY=$(echo "$PR_JSON" | jq -r '.body // "No description"')
PR_FILES=$(echo "$PR_JSON" | jq -r '.files[].path' 2>/dev/null | head -100 || echo "Unable to list files")

# --- Fetch Diff ---
PR_DIFF=$(gh pr diff "$PR_NUMBER" --repo "$REPO" 2>/dev/null || echo "Unable to fetch diff")

# Truncate diff if too large (50K chars)
if [[ ${#PR_DIFF} -gt 50000 ]]; then
    PR_DIFF="${PR_DIFF:0:49000}

... (diff truncated at 50K chars — review full diff on GitHub)"
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
    log_warn "Repo path not found for $REPO, using automation dir"
    REPO_PATH="$SCRIPT_DIR"
fi

# --- Build Mention Context Block ---
MENTION_BLOCK=""
if [[ -n "$MENTION_CONTEXT" ]]; then
    MENTION_BLOCK="## Mention Context
A user specifically requested pipeline action with this comment:
> ${MENTION_CONTEXT}

Take this instruction into account when reviewing."
fi

# --- Build Prompt ---
FINAL_PROMPT=$(substitute_prompt "$SCRIPT_DIR/prompts/pr-review.txt" \
    "REPO=$REPO" \
    "PR_NUMBER=$PR_NUMBER" \
    "PR_TITLE=$PR_TITLE" \
    "PR_BODY=$PR_BODY" \
    "PR_FILES=$PR_FILES" \
    "PR_DIFF=$PR_DIFF" \
    "MENTION_CONTEXT=$MENTION_BLOCK")

# Write prompt to temp file (avoids tmux send-keys escaping issues)
PROMPT_FILE=$(mktemp)
echo "$FINAL_PROMPT" > "$PROMPT_FILE"

# --- Launch Claude Interactively in tmux ---
if [[ "$PROJECT_SLUG" != "default" ]]; then
    TMUX_WINDOW="${PROJECT_SLUG}:review-${REPO##*/}-pr-${PR_NUMBER}"
else
    TMUX_WINDOW="review-${REPO##*/}-pr-${PR_NUMBER}"
fi

launch_claude_session "$TMUX_WINDOW" "$REPO_PATH" "$PROMPT_FILE"
rm -f "$PROMPT_FILE"

# --- Monitor with Timeout ---
TIMEOUT=${TIMEOUT_PR_REVIEW:-600}
monitor_session "$TMUX_WINDOW" "$TIMEOUT" 15 "pr-review-${REPO##*/}#${PR_NUMBER}"

log_info "Review session ended for PR #${PR_NUMBER}"

# --- Remove status label ---
gh pr edit "$PR_NUMBER" --repo "$REPO" \
    --remove-label "zapat-review" 2>/dev/null || log_warn "Failed to remove zapat-review label from PR #${PR_NUMBER}"

# --- Notify Slack ---
"$SCRIPT_DIR/bin/notify.sh" \
    --slack \
    --message "Review team completed analysis of PR #${PR_NUMBER}: ${PR_TITLE}\nhttps://github.com/${REPO}/pull/${PR_NUMBER}" \
    --job-name "pr-review" \
    --status success || log_warn "Slack notification failed"

log_info "Review complete for PR #${PR_NUMBER}"
