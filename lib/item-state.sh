#!/usr/bin/env bash
# Zapat - Item State Machine
# Tracks lifecycle of each work item (issue/PR) with retry support.
# Source this file: source "$SCRIPT_DIR/lib/item-state.sh"

# State directory
ITEM_STATE_DIR="${AUTOMATION_DIR}/state/items"
mkdir -p "$ITEM_STATE_DIR"

# Create a new item state file
# Usage: create_item_state "owner/repo" "issue" "123" "pending" ["project-slug"]
# Returns: path to state file
create_item_state() {
    local repo="$1" type="$2" number="$3" initial_status="${4:-pending}"
    local project="${5:-${CURRENT_PROJECT:-default}}"
    local key="${project}--${repo//\//-}_${type}_${number}"
    local state_file="$ITEM_STATE_DIR/${key}.json"

    # If already exists and not retryable, skip
    if [[ -f "$state_file" ]]; then
        local current_status
        current_status=$(jq -r '.status' "$state_file" 2>/dev/null || echo "unknown")
        if [[ "$current_status" == "completed" ]]; then
            echo "$state_file"
            return 1  # Already completed
        fi
    fi

    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    cat > "$state_file" <<ITEMEOF
{
  "project": "$project",
  "repo": "$repo",
  "type": "$type",
  "number": "$number",
  "status": "$initial_status",
  "created_at": "$now",
  "updated_at": "$now",
  "attempts": 0,
  "last_error": null,
  "next_retry_after": null
}
ITEMEOF

    echo "$state_file"
    return 0
}

# Update item state
# Usage: update_item_state "state_file" "running"
# Usage: update_item_state "state_file" "failed" "error message"
update_item_state() {
    local state_file="$1" new_status="$2" error_msg="${3:-}"

    if [[ ! -f "$state_file" ]]; then
        log_error "State file not found: $state_file"
        return 1
    fi

    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local attempts
    attempts=$(jq -r '.attempts' "$state_file")

    local updates=".status = \"$new_status\" | .updated_at = \"$now\""

    case "$new_status" in
        running)
            updates="$updates | .attempts = $((attempts + 1))"
            ;;
        failed)
            if [[ -n "$error_msg" ]]; then
                updates="$updates | .last_error = \"$error_msg\""
            fi
            # Backoff: 10 min after 1st failure, 30 min after 2nd
            local retry_minutes=10
            if [[ $attempts -ge 2 ]]; then
                retry_minutes=30
            fi
            # After 3 attempts, mark abandoned
            if [[ $attempts -ge 3 ]]; then
                updates="$updates | .status = \"abandoned\""
            else
                local retry_time
                retry_time=$(date -u -v+${retry_minutes}M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                    date -u -d "+${retry_minutes} minutes" '+%Y-%m-%dT%H:%M:%SZ')
                updates="$updates | .next_retry_after = \"$retry_time\""
            fi
            ;;
        capacity_rejected)
            # Capacity rejections: 5 min retry, unlimited
            local retry_time
            retry_time=$(date -u -v+5M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                date -u -d "+5 minutes" '+%Y-%m-%dT%H:%M:%SZ')
            updates="$updates | .status = \"pending\" | .next_retry_after = \"$retry_time\""
            ;;
        rate_limited)
            # Account-level rate limit: configurable delay, does NOT count toward attempt limit
            local retry_minutes="${RATE_LIMIT_RETRY_MINUTES:-60}"
            local retry_time
            retry_time=$(date -u -v+${retry_minutes}M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                date -u -d "+${retry_minutes} minutes" '+%Y-%m-%dT%H:%M:%SZ')
            updates="$updates | .status = \"pending\" | .next_retry_after = \"$retry_time\""
            updates="$updates | .last_error = \"Account rate limit hit\""
            # Decrement attempts to cancel the increment from "running" — not the agent's fault
            if [[ $attempts -gt 0 ]]; then
                updates="$updates | .attempts = $((attempts - 1))"
            fi
            ;;
        completed)
            updates="$updates | .next_retry_after = null | .last_error = null"
            ;;
    esac

    local tmp_file="${state_file}.tmp"
    jq "$updates" "$state_file" > "$tmp_file" && mv "$tmp_file" "$state_file"
}

# Get item state
# Usage: get_item_state "owner/repo" "issue" "123" ["project-slug"]
# Returns: JSON state or empty string
get_item_state() {
    local repo="$1" type="$2" number="$3"
    local project="${4:-${CURRENT_PROJECT:-default}}"
    local key="${project}--${repo//\//-}_${type}_${number}"
    local state_file="$ITEM_STATE_DIR/${key}.json"

    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    fi
}

# Check if item should be processed (not completed, not waiting for retry)
# Usage: should_process_item "owner/repo" "issue" "123" ["project-slug"]
# Returns: 0 if should process, 1 if should skip
should_process_item() {
    local repo="$1" type="$2" number="$3"
    local project="${4:-${CURRENT_PROJECT:-default}}"
    local key="${project}--${repo//\//-}_${type}_${number}"
    local state_file="$ITEM_STATE_DIR/${key}.json"

    if [[ ! -f "$state_file" ]]; then
        return 0  # New item, should process
    fi

    local status
    status=$(jq -r '.status' "$state_file" 2>/dev/null || echo "unknown")

    # Skip completed or abandoned items
    if [[ "$status" == "completed" || "$status" == "abandoned" ]]; then
        return 1
    fi

    # Skip if still running (unless stuck for over STALE_RUNNING_MINUTES)
    if [[ "$status" == "running" ]]; then
        local stale_minutes="${STALE_RUNNING_MINUTES:-45}"
        local updated_at now_epoch updated_epoch elapsed_minutes
        updated_at=$(jq -r '.updated_at' "$state_file" 2>/dev/null)
        now_epoch=$(date -u '+%s')
        updated_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$updated_at" '+%s' 2>/dev/null || \
            date -u -d "$updated_at" '+%s' 2>/dev/null || echo "0")
        elapsed_minutes=$(( (now_epoch - updated_epoch) / 60 ))

        if [[ $elapsed_minutes -gt $stale_minutes ]]; then
            log_warn "Detected stale running item (${elapsed_minutes}m > ${stale_minutes}m threshold): $(basename "$state_file")"
            update_item_state "$state_file" "failed" "Stale: stuck in running state for ${elapsed_minutes}m"
            return 0  # Now eligible for retry
        fi
        return 1
    fi

    # Check retry timer
    local next_retry
    next_retry=$(jq -r '.next_retry_after // empty' "$state_file" 2>/dev/null)
    if [[ -n "$next_retry" ]]; then
        local now_epoch retry_epoch
        now_epoch=$(date -u '+%s')
        retry_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$next_retry" '+%s' 2>/dev/null || \
            date -u -d "$next_retry" '+%s' 2>/dev/null || echo "0")
        if [[ $now_epoch -lt $retry_epoch ]]; then
            return 1  # Not yet time to retry
        fi
    fi

    return 0  # Ready to process
}

# List all items that are ready for retry
# Usage: list_retryable_items ["project-slug"]
#        If project is given, only return items for that project.
#        If omitted, return all retryable items.
# Output: one state file path per line
list_retryable_items() {
    local filter_project="${1:-}"
    local now_epoch
    now_epoch=$(date -u '+%s')

    for state_file in "$ITEM_STATE_DIR"/*.json; do
        [[ -f "$state_file" ]] || continue

        # Project filter
        if [[ -n "$filter_project" ]]; then
            local file_project
            file_project=$(jq -r '.project // "default"' "$state_file" 2>/dev/null)
            [[ "$file_project" != "$filter_project" ]] && continue
        fi

        local status next_retry
        status=$(jq -r '.status' "$state_file" 2>/dev/null || echo "unknown")

        # Only pending items with a retry timer
        if [[ "$status" != "pending" && "$status" != "failed" ]]; then
            continue
        fi

        next_retry=$(jq -r '.next_retry_after // empty' "$state_file" 2>/dev/null)
        if [[ -z "$next_retry" ]]; then
            # Pending with no retry timer = ready now
            echo "$state_file"
            continue
        fi

        local retry_epoch
        retry_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$next_retry" '+%s' 2>/dev/null || \
            date -u -d "$next_retry" '+%s' 2>/dev/null || echo "999999999999")
        if [[ $now_epoch -ge $retry_epoch ]]; then
            echo "$state_file"
        fi
    done
}
