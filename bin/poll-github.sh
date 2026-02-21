#!/usr/bin/env bash
# Zapat - GitHub Event Poller
# Runs every 2 minutes via cron (configurable via POLL_INTERVAL_MINUTES).
# Checks for new PRs and issues across all repos.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/item-state.sh"
load_env

# --- Lock ---
LOCK_FILE="$SCRIPT_DIR/state/poll.lock"
if ! acquire_lock "$LOCK_FILE"; then
    log_info "Another poll instance is running, exiting"
    exit 0
fi
trap 'cleanup_on_exit "$LOCK_FILE"' EXIT

# --- Pre-flight ---
if ! check_prereqs; then
    "$SCRIPT_DIR/bin/notify.sh" \
        --slack \
        --message "GitHub poll failed: prerequisites check failed.$(echo -e "$PREREQ_FAILURES")" \
        --job-name "github-poll" \
        --status emergency
    exit 1
fi

# --- Rate Limit Check ---
RATE_LIMIT_REMAINING=""
RATE_LIMIT_TOTAL=""
RATE_LIMIT_RESET=""
RATE_LIMIT_LOW=false

check_rate_limit() {
    local rate_json
    rate_json=$(gh api rate_limit --jq '.rate' 2>/dev/null || echo "")
    if [[ -z "$rate_json" ]]; then
        log_warn "Could not check GitHub rate limit (gh api failed)"
        return 0  # Don't block on failure to check
    fi
    RATE_LIMIT_REMAINING=$(echo "$rate_json" | jq -r '.remaining // 0')
    RATE_LIMIT_TOTAL=$(echo "$rate_json" | jq -r '.limit // 5000')
    RATE_LIMIT_RESET=$(echo "$rate_json" | jq -r '.reset // 0')

    if [[ "$RATE_LIMIT_REMAINING" -lt 100 ]]; then
        local reset_time
        reset_time=$(date -r "$RATE_LIMIT_RESET" '+%H:%M:%S' 2>/dev/null || \
            date -d "@$RATE_LIMIT_RESET" '+%H:%M:%S' 2>/dev/null || echo "unknown")
        log_warn "GitHub API rate limit critically low: ${RATE_LIMIT_REMAINING}/${RATE_LIMIT_TOTAL} remaining (resets at ${reset_time})"
        log_warn "Skipping this poll cycle to avoid hitting the limit."
        "$SCRIPT_DIR/bin/notify.sh" \
            --slack \
            --message "Rate limit low: ${RATE_LIMIT_REMAINING}/${RATE_LIMIT_TOTAL} requests remaining. Skipping poll cycle. Resets at ${reset_time}. Consider increasing POLL_INTERVAL_MINUTES or reducing the number of repos." \
            --job-name "github-poll" \
            --status warning 2>/dev/null || true
        return 1
    elif [[ "$RATE_LIMIT_REMAINING" -lt 500 ]]; then
        RATE_LIMIT_LOW=true
        log_warn "GitHub API rate limit getting low: ${RATE_LIMIT_REMAINING}/${RATE_LIMIT_TOTAL} remaining"
    else
        log_info "GitHub API rate limit: ${RATE_LIMIT_REMAINING}/${RATE_LIMIT_TOTAL} remaining"
    fi
    return 0
}

if ! check_rate_limit; then
    exit 0
fi

# --- GitHub API Helper ---
# Wraps gh commands to detect rate limiting instead of silently returning empty results.
# Usage: gh_api_safe <result_var> <gh command args...>
# Returns 0 on success, 1 on rate limit, 2 on other error.
gh_safe() {
    local output
    local exit_code=0
    # shellcheck disable=SC2294
    output=$(eval "$@" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        if echo "$output" | grep -qi "rate limit\|API rate limit exceeded\|403"; then
            log_warn "GitHub API rate limit hit during: $*"
            log_warn "Aborting poll cycle. Remaining requests exhausted."
            RATE_LIMIT_LOW=true
            echo "[]"
            return 1
        fi
        # Non-rate-limit error — log but don't abort
        log_warn "GitHub API error (exit $exit_code) during: $*"
        echo "[]"
        return 0
    fi

    echo "$output"
    return 0
}

# --- State Files ---
STATE_DIR="$SCRIPT_DIR/state"
mkdir -p "$STATE_DIR"
PROCESSED_PRS="$STATE_DIR/processed-prs.txt"
PROCESSED_ISSUES="$STATE_DIR/processed-issues.txt"
PROCESSED_WORK="$STATE_DIR/processed-work.txt"
PROCESSED_REWORK="$STATE_DIR/processed-rework.txt"
PROCESSED_WRITE_TESTS="$STATE_DIR/processed-write-tests.txt"
PROCESSED_RESEARCH="$STATE_DIR/processed-research.txt"
PROCESSED_MENTIONS="$STATE_DIR/processed-mentions.txt"
PROCESSED_AUTO_TRIAGE="$STATE_DIR/processed-auto-triage.txt"
PROCESSED_REBASE="$STATE_DIR/processed-rebase.txt"
LAST_MENTION_POLL="$STATE_DIR/last-mention-poll.txt"
touch "$PROCESSED_PRS" "$PROCESSED_ISSUES" "$PROCESSED_WORK" "$PROCESSED_REWORK" "$PROCESSED_WRITE_TESTS" "$PROCESSED_RESEARCH" "$PROCESSED_MENTIONS" "$PROCESSED_AUTO_TRIAGE" "$PROCESSED_REBASE"

# --- Reopened Item Helpers ---
# Remove an exact key from a processed file (whole-line match to avoid substring hits)
# Usage: remove_from_processed_file "file" "key"
remove_from_processed_file() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    local tmp="${file}.tmp"
    grep -vxF "$key" "$file" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
}

# Check if an open item was reopened (completed state but still open on GitHub).
# If so, reset its state and remove it from the processed file so it gets re-processed.
# Returns 0 if item was reopened (caller should continue processing), 1 otherwise (caller should skip).
check_reopened_item() {
    local processed_file="$1" key="$2" repo="$3" type="$4" num="$5" project="$6"
    if reset_completed_item "$repo" "$type" "$num" "$project"; then
        remove_from_processed_file "$processed_file" "$key"
        log_info "Reopened item detected: $key — re-processing"
        return 0
    fi
    return 1
}

# --- Defense-in-depth: detect unseeded state files ---
# If processed-issues.txt AND processed-prs.txt are both empty, startup.sh
# hasn't seeded yet. Polling now would treat every open item as new (issue #4).
if [[ ! -s "$PROCESSED_ISSUES" && ! -s "$PROCESSED_PRS" ]]; then
    log_warn "State files are empty — startup.sh may not have seeded yet. Skipping poll cycle to prevent flood."
    log_warn "Run: bin/startup.sh (or bin/startup.sh --seed-state) to initialize state."
    _log_structured "warn" "Poll skipped: empty state files (unseeded)" \
        "\"type\":\"flood_prevention\",\"reason\":\"empty_state_files\""
    exit 0
fi

# --- Governance Check ---
# Returns 0 if item should be processed, 1 if it should be skipped
should_process() {
    local labels_json="$1"
    local assignees_json="$2"

    # Skip if has 'human-only' label
    if echo "$labels_json" | jq -e '.[] | select(.name == "human-only")' &>/dev/null; then
        return 1
    fi

    # Skip if has any assignee
    local assignee_count
    assignee_count=$(echo "$assignees_json" | jq 'length')
    if [[ "$assignee_count" -gt 0 ]]; then
        return 1
    fi

    return 0
}

# --- Dependency Check ---
# Returns 0 if all "Blocked By" dependencies are closed, 1 if still blocked
check_dependencies() {
    local repo="$1"
    local issue_num="$2"

    # Fetch issue body and look for **Blocked By:** #N, #M pattern
    local body
    body=$(gh issue view "$issue_num" --repo "$repo" --json body --jq '.body // ""' 2>/dev/null || echo "")

    local blocked_by
    blocked_by=$(echo "$body" | grep -oP '\*\*Blocked By:\*\*\s*#?\K[0-9, #]+' 2>/dev/null || echo "")
    [[ -z "$blocked_by" ]] && return 0

    # Parse comma-separated issue numbers
    local dep_nums
    dep_nums=$(echo "$blocked_by" | tr ',' '\n' | tr -d ' #' | grep -E '^[0-9]+$')
    [[ -z "$dep_nums" ]] && return 0

    for dep_num in $dep_nums; do
        local dep_state
        dep_state=$(gh issue view "$dep_num" --repo "$repo" --json state --jq '.state' 2>/dev/null || echo "OPEN")
        if [[ "$dep_state" != "CLOSED" ]]; then
            log_info "Issue #${issue_num} blocked by open issue #${dep_num} in ${repo}"
            return 1
        fi
    done

    return 0
}

# --- @zapat Mention Scanning ---
scan_mentions() {
    local repo="$1"

    # Check if mention scanning is enabled
    if [[ "${ZAPAT_MENTION_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    # Determine the since timestamp
    local since_ts
    if [[ -f "$LAST_MENTION_POLL" && -s "$LAST_MENTION_POLL" ]]; then
        since_ts=$(cat "$LAST_MENTION_POLL")
    else
        # Default to POLL_INTERVAL_MINUTES ago (macOS and Linux compatible)
        local interval="${POLL_INTERVAL_MINUTES:-2}"
        since_ts=$(date -u -v-"${interval}"M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
            date -u -d "${interval} minutes ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
        if [[ -z "$since_ts" ]]; then
            log_warn "Could not compute default mention poll timestamp, skipping mentions"
            return 0
        fi
    fi

    # Fetch recent comments (since window is short, no pagination needed)
    local comments_json
    comments_json=$(gh_safe 'gh api "repos/'"${repo}"'/issues/comments?since='"${since_ts}"'"') || return 0

    local comment_count
    comment_count=$(echo "$comments_json" | jq 'length' 2>/dev/null || echo "0")

    for ((j=0; j<comment_count; j++)); do
        local comment_id comment_body comment_login issue_url
        comment_id=$(echo "$comments_json" | jq -r ".[$j].id")
        comment_body=$(echo "$comments_json" | jq -r ".[$j].body // \"\"")
        comment_login=$(echo "$comments_json" | jq -r ".[$j].user.login // \"\"")
        issue_url=$(echo "$comments_json" | jq -r ".[$j].issue_url // \"\"")

        # Check if comment mentions @zapat (case-insensitive)
        if ! echo "$comment_body" | grep -qi '@zapat'; then
            continue
        fi

        # Dedup by comment ID
        if grep -qF "$comment_id" "$PROCESSED_MENTIONS"; then
            continue
        fi

        # Self-mention prevention
        if [[ -n "${ZAPAT_BOT_LOGIN:-}" && "$comment_login" == "$ZAPAT_BOT_LOGIN" ]]; then
            log_info "Skipping self-mention from $comment_login on comment $comment_id"
            echo "$comment_id" >> "$PROCESSED_MENTIONS"
            continue
        fi

        # Extract item number from issue_url
        local item_number
        item_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
        if [[ -z "$item_number" ]]; then
            log_warn "Could not extract item number from issue_url: $issue_url"
            echo "$comment_id" >> "$PROCESSED_MENTIONS"
            continue
        fi

        # Extract instruction text (everything after @zapat on the matching line)
        local mention_text
        mention_text=$(echo "$comment_body" | sed -n 's/.*@[Zz][Aa][Pp][Aa][Tt][[:space:]]\{1,\}\(.*\)/\1/p' | head -1)
        if [[ -z "$mention_text" ]]; then
            mention_text="User requested pipeline action (no specific instruction)."
        fi

        # Determine if this is a PR or issue
        local is_pr=false
        if gh pr view "$item_number" --repo "$repo" --json number &>/dev/null; then
            is_pr=true
        fi

        log_info "@zapat mention by $comment_login on #${item_number} in ${repo}: $mention_text"

        # Route to appropriate trigger (pass project_slug from outer loop via CURRENT_PROJECT)
        # Check dispatch cap (DISPATCH_COUNT/MAX_DISPATCH are global, set in main loop)
        # Do NOT mark as processed here — mention will be retried next cycle
        TOTAL_ITEMS_FOUND=$((TOTAL_ITEMS_FOUND + 1))
        if [[ ${DISPATCH_COUNT:-0} -ge ${MAX_DISPATCH:-20} ]]; then
            log_warn "Per-cycle dispatch limit reached — deferring mention on #${item_number}"
            continue
        fi

        local cur_project="${CURRENT_PROJECT:-default}"
        if [[ "$is_pr" == "true" ]]; then
            "$SCRIPT_DIR/triggers/on-new-pr.sh" "$repo" "$item_number" "$mention_text" "$cur_project" &
            TOTAL_PRS=$((TOTAL_PRS + 1))
        else
            # Check if issue has agent-work label
            local issue_labels
            issue_labels=$(gh issue view "$item_number" --repo "$repo" --json labels \
                --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")

            if echo "$issue_labels" | grep -q "agent-work"; then
                "$SCRIPT_DIR/triggers/on-work-issue.sh" "$repo" "$item_number" "$mention_text" "$cur_project" &
            else
                "$SCRIPT_DIR/triggers/on-new-issue.sh" "$repo" "$item_number" "$mention_text" "$cur_project" &
            fi
            TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
        fi
        DISPATCH_COUNT=$((DISPATCH_COUNT + 1))

        echo "$comment_id" >> "$PROCESSED_MENTIONS"
    done
}

# --- Process Repos (per project) ---
TOTAL_PRS=0
TOTAL_ISSUES=0
TOTAL_ITEMS_FOUND=0
DISPATCH_COUNT=0
MAX_DISPATCH=${MAX_DISPATCH_PER_CYCLE:-20}
BACKLOG_WARNING_THRESHOLD=${BACKLOG_WARNING_THRESHOLD:-30}

# Check if we've hit the per-cycle dispatch cap
DISPATCH_LIMIT_LOGGED=false
dispatch_limit_reached() {
    if [[ $DISPATCH_COUNT -ge $MAX_DISPATCH ]]; then
        if [[ "$DISPATCH_LIMIT_LOGGED" != "true" ]]; then
            log_warn "Per-cycle dispatch limit reached ($DISPATCH_COUNT/$MAX_DISPATCH). Remaining items deferred to next cycle."
            DISPATCH_LIMIT_LOGGED=true
        fi
        return 0
    fi
    return 1
}

while IFS= read -r project_slug; do
    [[ -z "$project_slug" ]] && continue

    # Activate this project's config
    set_project "$project_slug"
    log_info "=== Polling project: $project_slug ==="

while IFS=$'\t' read -r repo local_path repo_type; do
    [[ -z "$repo" ]] && continue

    log_info "Polling $repo (project: $project_slug)..."

    # Bail out if rate limit was hit during a previous repo
    if [[ "$RATE_LIMIT_LOW" == "hit" ]]; then
        log_warn "Rate limit hit — stopping repo iteration"
        break
    fi

    # --- PRs with agent label ---
    PR_JSON=$(gh_safe 'gh pr list --repo "'"$repo"'" --label "agent" --json number,title,labels,assignees,url --state open') || { RATE_LIMIT_LOW="hit"; continue; }

    PR_COUNT=$(echo "$PR_JSON" | jq 'length')
    for ((i=0; i<PR_COUNT; i++)); do
        PR_NUM=$(echo "$PR_JSON" | jq -r ".[$i].number")
        PR_TITLE=$(echo "$PR_JSON" | jq -r ".[$i].title")
        PR_LABELS=$(echo "$PR_JSON" | jq ".[$i].labels")
        PR_ASSIGNEES=$(echo "$PR_JSON" | jq ".[$i].assignees")
        PR_KEY="${repo}#${PR_NUM}"

        # Skip if already processed (legacy file + item state)
        if grep -qF "$PR_KEY" "$PROCESSED_PRS"; then
            check_reopened_item "$PROCESSED_PRS" "$PR_KEY" "$repo" "pr" "$PR_NUM" "$project_slug" || continue
        fi
        if ! should_process_item "$repo" "pr" "$PR_NUM" "$project_slug"; then
            continue
        fi

        # Governance checks
        if ! should_process "$PR_LABELS" "$PR_ASSIGNEES"; then
            log_info "Skipping PR $PR_KEY (governance: human-only or assigned)"
            echo "$PR_KEY" >> "$PROCESSED_PRS"
            continue
        fi

        TOTAL_ITEMS_FOUND=$((TOTAL_ITEMS_FOUND + 1))
        dispatch_limit_reached && continue
        log_info "Processing PR: $PR_KEY — $PR_TITLE (project: $project_slug)"
        create_item_state "$repo" "pr" "$PR_NUM" "pending" "$project_slug" || true
        "$SCRIPT_DIR/triggers/on-new-pr.sh" "$repo" "$PR_NUM" "" "$project_slug" &
        echo "$PR_KEY" >> "$PROCESSED_PRS"
        TOTAL_PRS=$((TOTAL_PRS + 1))
        DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
    done

    # --- PRs with zapat-review label (agent-created PRs needing review) ---
    REVIEW_JSON=$(gh_safe 'gh pr list --repo "'"$repo"'" --label "zapat-review" --json number,title,labels,assignees --state open') || { RATE_LIMIT_LOW="hit"; continue; }

    REVIEW_COUNT=$(echo "$REVIEW_JSON" | jq 'length')
    for ((i=0; i<REVIEW_COUNT; i++)); do
        REVIEW_NUM=$(echo "$REVIEW_JSON" | jq -r ".[$i].number")
        REVIEW_TITLE=$(echo "$REVIEW_JSON" | jq -r ".[$i].title")
        REVIEW_LABELS=$(echo "$REVIEW_JSON" | jq ".[$i].labels")
        REVIEW_ASSIGNEES=$(echo "$REVIEW_JSON" | jq ".[$i].assignees")
        REVIEW_KEY="${repo}#review-${REVIEW_NUM}"

        # Skip if already processed
        if grep -qF "$REVIEW_KEY" "$PROCESSED_PRS"; then
            check_reopened_item "$PROCESSED_PRS" "$REVIEW_KEY" "$repo" "pr" "$REVIEW_NUM" "$project_slug" || continue
        fi
        if ! should_process_item "$repo" "pr" "$REVIEW_NUM" "$project_slug"; then
            continue
        fi

        # Governance checks
        if ! should_process "$REVIEW_LABELS" "$REVIEW_ASSIGNEES"; then
            log_info "Skipping zapat-review $REVIEW_KEY (governance: human-only or assigned)"
            echo "$REVIEW_KEY" >> "$PROCESSED_PRS"
            continue
        fi

        TOTAL_ITEMS_FOUND=$((TOTAL_ITEMS_FOUND + 1))
        dispatch_limit_reached && continue
        log_info "Processing zapat-review: $REVIEW_KEY — $REVIEW_TITLE (project: $project_slug)"
        create_item_state "$repo" "pr" "$REVIEW_NUM" "pending" "$project_slug" || true
        "$SCRIPT_DIR/triggers/on-new-pr.sh" "$repo" "$REVIEW_NUM" "" "$project_slug" &
        echo "$REVIEW_KEY" >> "$PROCESSED_PRS"
        TOTAL_PRS=$((TOTAL_PRS + 1))
        DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
    done

    # --- Issues with agent label ---
    ISSUE_JSON=$(gh_safe 'gh issue list --repo "'"$repo"'" --label "agent" --json number,title,labels,assignees,url --state open') || { RATE_LIMIT_LOW="hit"; continue; }

    ISSUE_COUNT=$(echo "$ISSUE_JSON" | jq 'length')
    for ((i=0; i<ISSUE_COUNT; i++)); do
        ISSUE_NUM=$(echo "$ISSUE_JSON" | jq -r ".[$i].number")
        ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r ".[$i].title")
        ISSUE_LABELS=$(echo "$ISSUE_JSON" | jq ".[$i].labels")
        ISSUE_ASSIGNEES=$(echo "$ISSUE_JSON" | jq ".[$i].assignees")
        ISSUE_KEY="${repo}#${ISSUE_NUM}"

        # Skip if already processed (legacy file + item state)
        if grep -qF "$ISSUE_KEY" "$PROCESSED_ISSUES"; then
            check_reopened_item "$PROCESSED_ISSUES" "$ISSUE_KEY" "$repo" "issue" "$ISSUE_NUM" "$project_slug" || continue
        fi
        if ! should_process_item "$repo" "issue" "$ISSUE_NUM" "$project_slug"; then
            continue
        fi

        # Governance checks
        if ! should_process "$ISSUE_LABELS" "$ISSUE_ASSIGNEES"; then
            log_info "Skipping issue $ISSUE_KEY (governance: human-only or assigned)"
            echo "$ISSUE_KEY" >> "$PROCESSED_ISSUES"
            continue
        fi

        TOTAL_ITEMS_FOUND=$((TOTAL_ITEMS_FOUND + 1))
        dispatch_limit_reached && continue
        log_info "Processing issue: $ISSUE_KEY — $ISSUE_TITLE (project: $project_slug)"
        create_item_state "$repo" "issue" "$ISSUE_NUM" "pending" "$project_slug" || true
        "$SCRIPT_DIR/triggers/on-new-issue.sh" "$repo" "$ISSUE_NUM" "" "$project_slug" &
        echo "$ISSUE_KEY" >> "$PROCESSED_ISSUES"
        TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
        DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
    done

    # --- Issues with agent-work label (implementation) ---
    WORK_JSON=$(gh_safe 'gh issue list --repo "'"$repo"'" --label "agent-work" --json number,title,labels,assignees,url --state open') || { RATE_LIMIT_LOW="hit"; continue; }

    WORK_COUNT=$(echo "$WORK_JSON" | jq 'length')
    for ((i=0; i<WORK_COUNT; i++)); do
        WORK_NUM=$(echo "$WORK_JSON" | jq -r ".[$i].number")
        WORK_TITLE=$(echo "$WORK_JSON" | jq -r ".[$i].title")
        WORK_LABELS=$(echo "$WORK_JSON" | jq ".[$i].labels")
        WORK_ASSIGNEES=$(echo "$WORK_JSON" | jq ".[$i].assignees")
        WORK_KEY="${repo}#${WORK_NUM}"

        # Skip if already processed (legacy file + item state)
        if grep -qF "$WORK_KEY" "$PROCESSED_WORK"; then
            check_reopened_item "$PROCESSED_WORK" "$WORK_KEY" "$repo" "work" "$WORK_NUM" "$project_slug" || continue
        fi
        if ! should_process_item "$repo" "work" "$WORK_NUM" "$project_slug"; then
            continue
        fi

        # Governance checks
        if ! should_process "$WORK_LABELS" "$WORK_ASSIGNEES"; then
            log_info "Skipping agent-work $WORK_KEY (governance: human-only or assigned)"
            echo "$WORK_KEY" >> "$PROCESSED_WORK"
            continue
        fi

        # Dependency check — skip if blocked by open issues
        if ! check_dependencies "$repo" "$WORK_NUM"; then
            log_info "Deferring agent-work $WORK_KEY (blocked by open dependencies)"
            continue
        fi

        TOTAL_ITEMS_FOUND=$((TOTAL_ITEMS_FOUND + 1))
        dispatch_limit_reached && continue
        log_info "Processing agent-work: $WORK_KEY — $WORK_TITLE (project: $project_slug)"
        create_item_state "$repo" "work" "$WORK_NUM" "pending" "$project_slug" || true
        "$SCRIPT_DIR/triggers/on-work-issue.sh" "$repo" "$WORK_NUM" "" "$project_slug" &
        echo "$WORK_KEY" >> "$PROCESSED_WORK"
        TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
        DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
    done

    # --- PRs with zapat-rework label (change requests) ---
    REWORK_JSON=$(gh_safe 'gh pr list --repo "'"$repo"'" --label "zapat-rework" --json number,title,labels,assignees --state open') || { RATE_LIMIT_LOW="hit"; continue; }

    REWORK_COUNT=$(echo "$REWORK_JSON" | jq 'length')
    for ((i=0; i<REWORK_COUNT; i++)); do
        REWORK_NUM=$(echo "$REWORK_JSON" | jq -r ".[$i].number")
        REWORK_TITLE=$(echo "$REWORK_JSON" | jq -r ".[$i].title")
        REWORK_LABELS=$(echo "$REWORK_JSON" | jq ".[$i].labels")
        REWORK_ASSIGNEES=$(echo "$REWORK_JSON" | jq ".[$i].assignees")
        REWORK_KEY="${repo}#pr${REWORK_NUM}"

        # Skip if already processed (legacy file + item state)
        if grep -qF "$REWORK_KEY" "$PROCESSED_REWORK"; then
            check_reopened_item "$PROCESSED_REWORK" "$REWORK_KEY" "$repo" "rework" "$REWORK_NUM" "$project_slug" || continue
        fi
        if ! should_process_item "$repo" "rework" "$REWORK_NUM" "$project_slug"; then
            continue
        fi

        # Governance checks
        if ! should_process "$REWORK_LABELS" "$REWORK_ASSIGNEES"; then
            log_info "Skipping zapat-rework $REWORK_KEY (governance: human-only or assigned)"
            echo "$REWORK_KEY" >> "$PROCESSED_REWORK"
            continue
        fi

        TOTAL_ITEMS_FOUND=$((TOTAL_ITEMS_FOUND + 1))
        dispatch_limit_reached && continue
        log_info "Processing zapat-rework: $REWORK_KEY — $REWORK_TITLE (project: $project_slug)"
        create_item_state "$repo" "rework" "$REWORK_NUM" "pending" "$project_slug" || true
        "$SCRIPT_DIR/triggers/on-rework-pr.sh" "$repo" "$REWORK_NUM" "" "$project_slug" &
        echo "$REWORK_KEY" >> "$PROCESSED_REWORK"
        TOTAL_PRS=$((TOTAL_PRS + 1))
        DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
    done

    # --- PRs with zapat-testing label (test runner) ---
    TEST_JSON=$(gh_safe 'gh pr list --repo "'"$repo"'" --label "zapat-testing" --json number,title,labels,assignees --state open') || { RATE_LIMIT_LOW="hit"; continue; }

    TEST_COUNT=$(echo "$TEST_JSON" | jq 'length')
    for ((i=0; i<TEST_COUNT; i++)); do
        TEST_NUM=$(echo "$TEST_JSON" | jq -r ".[$i].number")
        TEST_TITLE=$(echo "$TEST_JSON" | jq -r ".[$i].title")
        TEST_LABELS=$(echo "$TEST_JSON" | jq ".[$i].labels")
        TEST_ASSIGNEES=$(echo "$TEST_JSON" | jq ".[$i].assignees")
        TEST_KEY="${repo}#test-pr${TEST_NUM}"

        if ! should_process_item "$repo" "test" "$TEST_NUM" "$project_slug"; then
            # No processed file for zapat-testing; check if reopened via state alone
            reset_completed_item "$repo" "test" "$TEST_NUM" "$project_slug" || continue
        fi

        if ! should_process "$TEST_LABELS" "$TEST_ASSIGNEES"; then
            log_info "Skipping zapat-testing $TEST_KEY (governance: human-only or assigned)"
            continue
        fi

        TOTAL_ITEMS_FOUND=$((TOTAL_ITEMS_FOUND + 1))
        dispatch_limit_reached && continue
        log_info "Processing zapat-testing: $TEST_KEY — $TEST_TITLE (project: $project_slug)"
        create_item_state "$repo" "test" "$TEST_NUM" "pending" "$project_slug" >/dev/null || true
        "$SCRIPT_DIR/triggers/on-test-pr.sh" "$repo" "$TEST_NUM" "" "$project_slug" &
        TOTAL_PRS=$((TOTAL_PRS + 1))
        DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
    done

    # --- Issues with agent-write-tests label (test writing) ---
    WRITE_TESTS_JSON=$(gh_safe 'gh issue list --repo "'"$repo"'" --label "agent-write-tests" --json number,title,labels,assignees --state open') || { RATE_LIMIT_LOW="hit"; continue; }

    WRITE_TESTS_COUNT=$(echo "$WRITE_TESTS_JSON" | jq 'length')
    for ((i=0; i<WRITE_TESTS_COUNT; i++)); do
        WT_NUM=$(echo "$WRITE_TESTS_JSON" | jq -r ".[$i].number")
        WT_TITLE=$(echo "$WRITE_TESTS_JSON" | jq -r ".[$i].title")
        WT_LABELS=$(echo "$WRITE_TESTS_JSON" | jq ".[$i].labels")
        WT_ASSIGNEES=$(echo "$WRITE_TESTS_JSON" | jq ".[$i].assignees")
        WT_KEY="${repo}#${WT_NUM}"

        # Skip if already processed (legacy file + item state)
        if grep -qF "$WT_KEY" "$PROCESSED_WRITE_TESTS"; then
            check_reopened_item "$PROCESSED_WRITE_TESTS" "$WT_KEY" "$repo" "write-tests" "$WT_NUM" "$project_slug" || continue
        fi
        if ! should_process_item "$repo" "write-tests" "$WT_NUM" "$project_slug"; then
            continue
        fi

        # Governance checks
        if ! should_process "$WT_LABELS" "$WT_ASSIGNEES"; then
            log_info "Skipping agent-write-tests $WT_KEY (governance: human-only or assigned)"
            echo "$WT_KEY" >> "$PROCESSED_WRITE_TESTS"
            continue
        fi

        TOTAL_ITEMS_FOUND=$((TOTAL_ITEMS_FOUND + 1))
        dispatch_limit_reached && continue
        log_info "Processing agent-write-tests: $WT_KEY — $WT_TITLE (project: $project_slug)"
        create_item_state "$repo" "write-tests" "$WT_NUM" "pending" "$project_slug" || true
        "$SCRIPT_DIR/triggers/on-write-tests.sh" "$repo" "$WT_NUM" "" "$project_slug" &
        echo "$WT_KEY" >> "$PROCESSED_WRITE_TESTS"
        TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
        DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
    done

    # --- Issues with agent-research label (strategy/research) ---
    RESEARCH_JSON=$(gh_safe 'gh issue list --repo "'"$repo"'" --label "agent-research" --json number,title,labels,assignees --state open') || { RATE_LIMIT_LOW="hit"; continue; }

    RESEARCH_COUNT=$(echo "$RESEARCH_JSON" | jq 'length')
    for ((i=0; i<RESEARCH_COUNT; i++)); do
        RESEARCH_NUM=$(echo "$RESEARCH_JSON" | jq -r ".[$i].number")
        RESEARCH_TITLE=$(echo "$RESEARCH_JSON" | jq -r ".[$i].title")
        RESEARCH_LABELS=$(echo "$RESEARCH_JSON" | jq ".[$i].labels")
        RESEARCH_ASSIGNEES=$(echo "$RESEARCH_JSON" | jq ".[$i].assignees")
        RESEARCH_KEY="${repo}#${RESEARCH_NUM}"

        # Skip if already processed (legacy file + item state)
        if grep -qF "$RESEARCH_KEY" "$PROCESSED_RESEARCH"; then
            check_reopened_item "$PROCESSED_RESEARCH" "$RESEARCH_KEY" "$repo" "research" "$RESEARCH_NUM" "$project_slug" || continue
        fi
        if ! should_process_item "$repo" "research" "$RESEARCH_NUM" "$project_slug"; then
            continue
        fi

        # Governance checks
        if ! should_process "$RESEARCH_LABELS" "$RESEARCH_ASSIGNEES"; then
            log_info "Skipping agent-research $RESEARCH_KEY (governance: human-only or assigned)"
            echo "$RESEARCH_KEY" >> "$PROCESSED_RESEARCH"
            continue
        fi

        TOTAL_ITEMS_FOUND=$((TOTAL_ITEMS_FOUND + 1))
        dispatch_limit_reached && continue
        log_info "Processing agent-research: $RESEARCH_KEY — $RESEARCH_TITLE (project: $project_slug)"
        create_item_state "$repo" "research" "$RESEARCH_NUM" "pending" "$project_slug" || true
        "$SCRIPT_DIR/triggers/on-research-issue.sh" "$repo" "$RESEARCH_NUM" "" "$project_slug" &
        echo "$RESEARCH_KEY" >> "$PROCESSED_RESEARCH"
        TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
        DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
    done

    # --- @zapat Mention Scanning ---
    scan_mentions "$repo"

    # --- Auto-Triage: Pick up ALL new issues without labels ---
    if [[ "${AUTO_TRIAGE_NEW_ISSUES:-false}" == "true" ]]; then
        # All Zapat-managed labels — issues with any of these are already handled above
        ZAPAT_LABELS="agent,agent-work,agent-research,agent-write-tests,human-only,zapat-triaging,zapat-implementing,zapat-review,zapat-testing,zapat-rework,zapat-researching"

        ALL_ISSUES_JSON=$(gh_safe 'gh issue list --repo "'"$repo"'" --state open --json number,title,labels,assignees --limit 50') || { RATE_LIMIT_LOW="hit"; continue; }

        ALL_ISSUES_COUNT=$(echo "$ALL_ISSUES_JSON" | jq 'length')
        for ((i=0; i<ALL_ISSUES_COUNT; i++)); do
            AT_NUM=$(echo "$ALL_ISSUES_JSON" | jq -r ".[$i].number")
            AT_TITLE=$(echo "$ALL_ISSUES_JSON" | jq -r ".[$i].title")
            AT_LABELS=$(echo "$ALL_ISSUES_JSON" | jq ".[$i].labels")
            AT_ASSIGNEES=$(echo "$ALL_ISSUES_JSON" | jq ".[$i].assignees")
            AT_KEY="${repo}#auto-${AT_NUM}"

            # Skip if already seen by auto-triage
            if grep -qF "$AT_KEY" "$PROCESSED_AUTO_TRIAGE"; then
                check_reopened_item "$PROCESSED_AUTO_TRIAGE" "$AT_KEY" "$repo" "issue" "$AT_NUM" "$project_slug" || continue
            fi

            # Skip if already processed by any other pipeline path
            if grep -qF "${repo}#${AT_NUM}" "$PROCESSED_ISSUES" "$PROCESSED_WORK" "$PROCESSED_RESEARCH" "$PROCESSED_WRITE_TESTS" 2>/dev/null; then
                if reset_completed_item "$repo" "issue" "$AT_NUM" "$project_slug"; then
                    # Reopened: remove from all processed files
                    remove_from_processed_file "$PROCESSED_ISSUES" "${repo}#${AT_NUM}"
                    remove_from_processed_file "$PROCESSED_WORK" "${repo}#${AT_NUM}"
                    remove_from_processed_file "$PROCESSED_RESEARCH" "${repo}#${AT_NUM}"
                    remove_from_processed_file "$PROCESSED_WRITE_TESTS" "${repo}#${AT_NUM}"
                    log_info "Reopened item detected: ${repo}#${AT_NUM} — cleared from all processed files"
                else
                    echo "$AT_KEY" >> "$PROCESSED_AUTO_TRIAGE"
                    continue
                fi
            fi

            # Skip if issue has ANY Zapat label (already managed)
            HAS_ZAPAT_LABEL=$(echo "$AT_LABELS" | jq -r --arg labels "$ZAPAT_LABELS" '
                ($labels | split(",")) as $zl |
                [.[].name] | any(. as $name | $zl | any(. == $name))
            ')
            if [[ "$HAS_ZAPAT_LABEL" == "true" ]]; then
                echo "$AT_KEY" >> "$PROCESSED_AUTO_TRIAGE"
                continue
            fi

            # Governance: skip if assigned or human-only
            if ! should_process "$AT_LABELS" "$AT_ASSIGNEES"; then
                echo "$AT_KEY" >> "$PROCESSED_AUTO_TRIAGE"
                continue
            fi

            # Skip if already triaged (item state exists)
            if ! should_process_item "$repo" "issue" "$AT_NUM" "$project_slug"; then
                echo "$AT_KEY" >> "$PROCESSED_AUTO_TRIAGE"
                continue
            fi

            TOTAL_ITEMS_FOUND=$((TOTAL_ITEMS_FOUND + 1))
            dispatch_limit_reached && continue
            log_info "Auto-triage: new issue $AT_KEY — $AT_TITLE (project: $project_slug)"
            create_item_state "$repo" "issue" "$AT_NUM" "pending" "$project_slug" || true
            "$SCRIPT_DIR/triggers/on-new-issue.sh" "$repo" "$AT_NUM" "" "$project_slug" &
            echo "$AT_KEY" >> "$PROCESSED_AUTO_TRIAGE"
            TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
            DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
        done
    fi

    # --- Auto-Rework Detection ---
    # Detect PRs from agent/* branches with CHANGES_REQUESTED review state
    AGENT_PRS_JSON=$(gh_safe 'gh pr list --repo "'"$repo"'" --json number,headRefName,reviewDecision,labels --state open') || { RATE_LIMIT_LOW="hit"; continue; }

    AGENT_PRS_COUNT=$(echo "$AGENT_PRS_JSON" | jq 'length')
    for ((i=0; i<AGENT_PRS_COUNT; i++)); do
        AGENT_PR_NUM=$(echo "$AGENT_PRS_JSON" | jq -r ".[$i].number")
        AGENT_PR_BRANCH=$(echo "$AGENT_PRS_JSON" | jq -r ".[$i].headRefName")
        AGENT_PR_DECISION=$(echo "$AGENT_PRS_JSON" | jq -r ".[$i].reviewDecision // \"\"")
        AGENT_PR_HAS_REWORK=$(echo "$AGENT_PRS_JSON" | jq -r ".[$i].labels | map(.name) | index(\"zapat-rework\") // empty")

        # Only agent branches with changes requested and no existing zapat-rework label
        if [[ "$AGENT_PR_BRANCH" != agent/* ]]; then
            continue
        fi
        if [[ "$AGENT_PR_DECISION" != "CHANGES_REQUESTED" ]]; then
            continue
        fi
        if [[ -n "$AGENT_PR_HAS_REWORK" ]]; then
            continue
        fi

        log_info "Auto-rework detected: PR #${AGENT_PR_NUM} on branch ${AGENT_PR_BRANCH} has changes requested"
        gh pr edit "$AGENT_PR_NUM" --repo "$repo" \
            --add-label "zapat-rework" 2>/dev/null || log_warn "Failed to add zapat-rework label to PR #${AGENT_PR_NUM}"
    done

    # --- Auto-Merge Gate ---
    if [[ "${AUTO_MERGE_ENABLED:-true}" == "true" ]]; then
        MERGE_PRS_JSON=$(gh_safe 'gh pr list --repo "'"$repo"'" --json number,headRefName,labels --state open') || { RATE_LIMIT_LOW="hit"; continue; }

        MERGE_PRS_COUNT=$(echo "$MERGE_PRS_JSON" | jq 'length')
        for ((i=0; i<MERGE_PRS_COUNT; i++)); do
            MERGE_PR_NUM=$(echo "$MERGE_PRS_JSON" | jq -r ".[$i].number")
            MERGE_PR_HAS_HOLD=$(echo "$MERGE_PRS_JSON" | jq -r ".[$i].labels | map(.name) | index(\"hold\") // empty")

            # Skip if has hold label
            if [[ -n "$MERGE_PR_HAS_HOLD" ]]; then
                continue
            fi

            # Check for approval
            HAS_APPROVAL=$(gh_safe 'gh api "repos/'"${repo}"'/pulls/'"${MERGE_PR_NUM}"'/reviews" --jq '"'"'[.[] | select(.state == "APPROVED")] | length'"'"'') || { RATE_LIMIT_LOW="hit"; break; }
            [[ -z "$HAS_APPROVAL" ]] && HAS_APPROVAL=0
            if [[ "$HAS_APPROVAL" -lt 1 ]]; then
                continue
            fi

            # Check for test pass marker
            PR_COMMENTS=$(gh_safe 'gh api "repos/'"${repo}"'/issues/'"${MERGE_PR_NUM}"'/comments" --jq '"'"'.[].body'"'"'') || { RATE_LIMIT_LOW="hit"; break; }
            HAS_TEST_PASS=$(echo "$PR_COMMENTS" | grep -c "agent-test-passed" 2>/dev/null || echo "0")
            if [[ "$HAS_TEST_PASS" -lt 1 ]]; then
                continue
            fi

            # Classify risk
            RISK_LEVEL="unknown"
            RISK_JSON='{}'
            if command -v node &>/dev/null && [[ -f "$SCRIPT_DIR/bin/zapat" ]]; then
                RISK_JSON=$("$SCRIPT_DIR/bin/zapat" risk "$repo" "$MERGE_PR_NUM" 2>/dev/null || echo '{"risk":"unknown"}')
                RISK_LEVEL=$(echo "$RISK_JSON" | jq -r '.risk // "unknown"')
            fi

            case "$RISK_LEVEL" in
                low)
                    log_info "Auto-merging low-risk PR #${MERGE_PR_NUM} in ${repo}"
                    if gh pr merge "$MERGE_PR_NUM" --repo "$repo" --squash --auto 2>/dev/null; then
                        "$SCRIPT_DIR/bin/notify.sh" \
                            --slack \
                            --message "Auto-merged low-risk PR #${MERGE_PR_NUM} in ${repo}" \
                            --job-name "auto-merge" \
                            --status success 2>/dev/null || true
                    fi
                    ;;
                medium)
                    HAS_DELAY_COMMENT=$(echo "$PR_COMMENTS" | grep -c "auto-merge-scheduled" 2>/dev/null || echo "0")
                    DELAY_HOURS=${AUTO_MERGE_DELAY_HOURS:-4}
                    if [[ "$HAS_DELAY_COMMENT" -lt 1 ]]; then
                        gh pr comment "$MERGE_PR_NUM" --repo "$repo" --body "<!-- auto-merge-scheduled -->
This PR has passed all gates (tests + review) and is classified as **medium risk**.

It will be auto-merged in **${DELAY_HOURS} hours** unless a \`hold\` label is added." 2>/dev/null || true
                        log_info "Medium-risk PR #${MERGE_PR_NUM} scheduled for auto-merge in ${DELAY_HOURS}h"
                    else
                        # Check if delay period has elapsed
                        SCHEDULE_TIME=$(gh api "repos/${repo}/issues/${MERGE_PR_NUM}/comments" \
                            --jq '[.[] | select(.body | contains("auto-merge-scheduled"))] | .[0].created_at // ""' 2>/dev/null || echo "")
                        if [[ -n "$SCHEDULE_TIME" ]]; then
                            SCHEDULE_EPOCH=$(date -jf '%Y-%m-%dT%H:%M:%SZ' "$SCHEDULE_TIME" '+%s' 2>/dev/null || \
                                date -d "$SCHEDULE_TIME" '+%s' 2>/dev/null || echo "0")
                            NOW_EPOCH=$(date '+%s')
                            ELAPSED_HOURS=$(( (NOW_EPOCH - SCHEDULE_EPOCH) / 3600 ))
                            if [[ $ELAPSED_HOURS -ge $DELAY_HOURS ]]; then
                                CURRENT_LABELS=$(gh pr view "$MERGE_PR_NUM" --repo "$repo" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
                                if ! echo "$CURRENT_LABELS" | grep -q "hold"; then
                                    log_info "Auto-merging medium-risk PR #${MERGE_PR_NUM} after ${DELAY_HOURS}h delay"
                                    if gh pr merge "$MERGE_PR_NUM" --repo "$repo" --squash --auto 2>/dev/null; then
                                        "$SCRIPT_DIR/bin/notify.sh" \
                                            --slack \
                                            --message "Auto-merged medium-risk PR #${MERGE_PR_NUM} in ${repo} after ${DELAY_HOURS}h delay" \
                                            --job-name "auto-merge" \
                                            --status success 2>/dev/null || true
                                    fi
                                fi
                            fi
                        fi
                    fi
                    ;;
                high)
                    HAS_HIGH_COMMENT=$(echo "$PR_COMMENTS" | grep -c "high-risk-review-needed" 2>/dev/null || echo "0")
                    if [[ "$HAS_HIGH_COMMENT" -lt 1 ]]; then
                        RISK_REASONS=$(echo "$RISK_JSON" | jq -r '.reasons | join(", ")' 2>/dev/null || echo "See risk analysis")
                        gh pr comment "$MERGE_PR_NUM" --repo "$repo" --body "<!-- high-risk-review-needed -->
This PR is classified as **high risk** and requires human review before merging.

**Risk factors**: ${RISK_REASONS}

Please review and merge manually." 2>/dev/null || true
                        "$SCRIPT_DIR/bin/notify.sh" \
                            --slack \
                            --message "High-risk PR #${MERGE_PR_NUM} in ${repo} needs human review.\nhttps://github.com/${repo}/pull/${MERGE_PR_NUM}" \
                            --job-name "auto-merge" \
                            --status warning 2>/dev/null || true
                    fi
                    ;;
            esac
        done
    fi

    # --- Auto-Rebase Stale Zapat PRs ---
    if [[ "${AUTO_REBASE_ENABLED:-true}" == "true" ]]; then
        # Get current main SHA for dedup
        MAIN_SHA=$(cd "$local_path" && git fetch origin 2>/dev/null && git rev-parse --short origin/main 2>/dev/null || echo "unknown")

        REBASE_PRS_JSON=$(gh_safe 'gh pr list --repo "'"$repo"'" --json number,headRefName,baseRefName,labels --state open') || { RATE_LIMIT_LOW="hit"; continue; }

        REBASE_PRS_COUNT=$(echo "$REBASE_PRS_JSON" | jq 'length')
        for ((i=0; i<REBASE_PRS_COUNT; i++)); do
            REBASE_PR_NUM=$(echo "$REBASE_PRS_JSON" | jq -r ".[$i].number")
            REBASE_PR_BRANCH=$(echo "$REBASE_PRS_JSON" | jq -r ".[$i].headRefName")
            REBASE_PR_BASE=$(echo "$REBASE_PRS_JSON" | jq -r ".[$i].baseRefName // \"main\"")
            REBASE_PR_LABELS=$(echo "$REBASE_PRS_JSON" | jq -r "[.[$i].labels[].name] | join(\",\")")

            # Only rebase agent branches
            if [[ "$REBASE_PR_BRANCH" != agent/* ]]; then
                continue
            fi

            # Skip PRs with blocking labels
            if echo "$REBASE_PR_LABELS" | grep -qE "hold|needs-rebase|zapat-implementing|zapat-rework"; then
                continue
            fi

            # Dedup: only attempt once per PR per main SHA
            REBASE_KEY="${repo}#rebase-${REBASE_PR_NUM}@${MAIN_SHA}"
            if grep -qF "$REBASE_KEY" "$PROCESSED_REBASE"; then
                continue
            fi

            # Check if PR branch is behind base branch
            cd "$local_path"
            git fetch origin "$REBASE_PR_BRANCH" 2>/dev/null || continue
            if git merge-base --is-ancestor "origin/${REBASE_PR_BASE}" "origin/${REBASE_PR_BRANCH}" 2>/dev/null; then
                # PR is up-to-date, mark as processed
                echo "$REBASE_KEY" >> "$PROCESSED_REBASE"
                continue
            fi

            log_info "PR #${REBASE_PR_NUM} in ${repo} is behind ${REBASE_PR_BASE}, dispatching rebase"
            "$SCRIPT_DIR/triggers/on-rebase-pr.sh" "$repo" "$REBASE_PR_NUM" "" "$project_slug" &
            echo "$REBASE_KEY" >> "$PROCESSED_REBASE"
        done
    fi

    # Rate limit: pause between repos to avoid GitHub secondary rate limits
    sleep 2

done < <(read_repos "$project_slug")

done < <(read_projects)

# --- Update Mention Poll Timestamp ---
if [[ "${ZAPAT_MENTION_ENABLED:-true}" == "true" ]]; then
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$LAST_MENTION_POLL"
fi

# --- Backlog Flood Detection ---
if [[ $TOTAL_ITEMS_FOUND -gt $BACKLOG_WARNING_THRESHOLD ]]; then
    log_warn "Flood detection: Found $TOTAL_ITEMS_FOUND items across all repos in this cycle (threshold: $BACKLOG_WARNING_THRESHOLD). This may indicate a first-boot scenario or label misconfiguration. Items are capped at MAX_DISPATCH_PER_CYCLE=$MAX_DISPATCH per cycle."
    _log_structured "warn" "Backlog flood detected" "\"total_items_found\":$TOTAL_ITEMS_FOUND,\"threshold\":$BACKLOG_WARNING_THRESHOLD,\"dispatched\":$DISPATCH_COUNT"
    "$SCRIPT_DIR/bin/notify.sh" \
        --slack \
        --message "Flood detection: Found $TOTAL_ITEMS_FOUND items in a single poll cycle (threshold: $BACKLOG_WARNING_THRESHOLD). Dispatched $DISPATCH_COUNT/$MAX_DISPATCH. This may indicate a first-boot scenario or label misconfiguration. If first boot, this self-resolves over subsequent cycles (batched at $MAX_DISPATCH/cycle). If unexpected, check labels with: bin/zapat health" \
        --job-name "flood-detection" \
        --status warning 2>/dev/null || true
fi

# --- Retry Sweep ---
log_info "Checking for retryable items..."
while IFS= read -r state_file; do
    [[ -f "$state_file" ]] || continue

    item_project=$(jq -r '.project // "default"' "$state_file")
    item_repo=$(jq -r '.repo' "$state_file")
    item_type=$(jq -r '.type' "$state_file")
    item_number=$(jq -r '.number' "$state_file")

    # Activate the item's project before dispatching
    set_project "$item_project"

    log_info "Retrying $item_type #$item_number in $item_repo (project: $item_project)"
    update_item_state "$state_file" "running"

    case "$item_type" in
        pr)
            "$SCRIPT_DIR/triggers/on-new-pr.sh" "$item_repo" "$item_number" "" "$item_project" &
            ;;
        issue)
            "$SCRIPT_DIR/triggers/on-new-issue.sh" "$item_repo" "$item_number" "" "$item_project" &
            ;;
        work)
            "$SCRIPT_DIR/triggers/on-work-issue.sh" "$item_repo" "$item_number" "" "$item_project" &
            ;;
        rework)
            "$SCRIPT_DIR/triggers/on-rework-pr.sh" "$item_repo" "$item_number" "" "$item_project" &
            ;;
        test)
            "$SCRIPT_DIR/triggers/on-test-pr.sh" "$item_repo" "$item_number" "" "$item_project" &
            ;;
        write-tests)
            "$SCRIPT_DIR/triggers/on-write-tests.sh" "$item_repo" "$item_number" "" "$item_project" &
            ;;
        research)
            "$SCRIPT_DIR/triggers/on-research-issue.sh" "$item_repo" "$item_number" "" "$item_project" &
            ;;
    esac
done < <(list_retryable_items "$@")

# --- Failure Alerting ---
if command -v node &>/dev/null && [[ -f "$SCRIPT_DIR/bin/zapat" ]]; then
    FAILURE_COUNT=$("$SCRIPT_DIR/bin/zapat" metrics query --last-hour --status failure 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    if [[ "$FAILURE_COUNT" -ge 3 ]]; then
        "$SCRIPT_DIR/bin/notify.sh" \
            --slack \
            --message "Alert: ${FAILURE_COUNT} failures in the last hour. Run: bin/zapat health --auto-fix" \
            --job-name "failure-alert" \
            --status warning 2>/dev/null || true
    fi
fi

# --- Health Auto-Fix ---
# Clean up orphaned worktrees, stale slots, etc. every poll cycle
if command -v node &>/dev/null && [[ -f "$SCRIPT_DIR/bin/zapat" ]]; then
    "$SCRIPT_DIR/bin/zapat" health --auto-fix --json 2>/dev/null | {
        read -r health_json
        fixed_count=$(echo "$health_json" | jq '[.checks[] | select(.status == "fixed")] | length' 2>/dev/null || echo "0")
        if [[ "$fixed_count" -gt 0 ]]; then
            log_info "Health auto-fix: repaired $fixed_count issue(s)"
        fi
    } || true
fi

# Background triggers are self-contained (own tmux windows, monitoring, cleanup).
# Don't wait — release the poll lock so the next cron cycle can detect new items.
# Triage/review finish in ~5 min. Work/rework run in tmux for up to 30 min each.

if [[ $TOTAL_PRS -gt 0 || $TOTAL_ISSUES -gt 0 ]]; then
    log_info "Poll complete: dispatched $TOTAL_PRS PRs, $TOTAL_ISSUES issues"
else
    log_info "Poll complete: no new items"
fi

# Log rate limit status at end of cycle for monitoring
if [[ -n "$RATE_LIMIT_REMAINING" ]]; then
    log_info "GitHub API rate limit after poll: ${RATE_LIMIT_REMAINING}/${RATE_LIMIT_TOTAL} remaining"
fi
if [[ "$RATE_LIMIT_LOW" == "hit" ]]; then
    log_warn "Poll cycle ended early due to rate limit. Next cycle will retry."
fi
