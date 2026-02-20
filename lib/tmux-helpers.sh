#!/usr/bin/env bash
# Zapat - tmux Helper Functions
# Provides reliable tmux interaction with readiness detection.
# Source this file: source "$SCRIPT_DIR/lib/tmux-helpers.sh"

TMUX_SESSION="${TMUX_SESSION:-zapat}"

# Patterns for detecting stuck panes
# Permission pattern uses exact Claude CLI prompt phrases to avoid false positives
# from code review output (IAM policies, etc.).
# Note: PANE_PATTERN_BYPASS removed — defaultMode:bypassPermissions in settings.json
# means no startup bypass prompt appears. "shift+tab to cycle" now appears in every
# running session's status bar and must NOT be used as a match pattern.
PANE_PATTERN_ACCOUNT_LIMIT="(out of extra usage|resets [0-9]|usage limit|plan limit|You've reached)"
PANE_PATTERN_RATE_LIMIT="(Switch to extra|Rate limit|rate_limit|429|Too Many Requests|Retry after)"
PANE_PATTERN_PERMISSION="(Allow once|Allow always|Do you want to allow|Do you want to (create|make|proceed|run|write|edit)|wants to use the .* tool|approve this action|Waiting for team lead approval)"
PANE_PATTERN_FATAL="(FATAL|OOM|out of memory|Segmentation fault|core dumped|panic:|SIGKILL)"

# Wait for specific content to appear in a tmux pane
# Usage: wait_for_tmux_content "window-name" "pattern" [timeout_seconds]
# Returns: 0 if pattern found, 1 if timeout
wait_for_tmux_content() {
    local window="$1"
    local pattern="$2"
    local timeout="${3:-30}"
    local interval=1
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local content
        content=$(tmux capture-pane -t "${TMUX_SESSION}:${window}" -p 2>/dev/null || echo "")
        if echo "$content" | grep -qE "$pattern"; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_warn "Timed out waiting for pattern '$pattern' in window '$window' after ${timeout}s"
    return 1
}

# Launch a Claude session in a tmux window with readiness detection
# Usage: launch_claude_session "window-name" "/path/to/workdir" "/path/to/prompt-file" [extra_env_vars] [agent_model]
# Returns: 0 if session launched and prompt submitted, 1 on failure
launch_claude_session() {
    local window="$1"
    local workdir="$2"
    local prompt_file="$3"
    local extra_env="${4:-}"
    local model="${5:-${CLAUDE_MODEL:-claude-opus-4-6}}"

    # Validate inputs
    if [[ ! -d "$workdir" ]]; then
        log_error "Working directory does not exist: $workdir"
        return 1
    fi

    if [[ ! -f "$prompt_file" ]]; then
        log_error "Prompt file does not exist: $prompt_file"
        return 1
    fi

    # Kill any existing window with the same name
    tmux kill-window -t "${TMUX_SESSION}:${window}" 2>/dev/null || true

    # Build the command
    local cmd="cd '$workdir' && "
    cmd+="unset CLAUDECODE && "
    cmd+="CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 "
    if [[ -n "$extra_env" ]]; then
        cmd+="$extra_env "
    fi
    cmd+="claude --model '${model}' "
    cmd+="--dangerously-skip-permissions "
    cmd+="--permission-mode bypassPermissions; "
    cmd+="exit"

    # Create new tmux window
    tmux new-window -t "$TMUX_SESSION" -n "$window" "$cmd"
    log_info "tmux window '$window' created"

    if [[ "${TMUX_USE_SLEEP_FALLBACK:-0}" == "1" ]]; then
        # Legacy fallback: hardcoded sleeps
        log_info "Using sleep fallback for tmux interaction"
        sleep 5
        tmux send-keys -t "${TMUX_SESSION}:${window}" Down
        sleep 1
        tmux send-keys -t "${TMUX_SESSION}:${window}" Enter
        sleep 5
        tmux load-buffer "$prompt_file"
        tmux paste-buffer -t "${TMUX_SESSION}:${window}"
        sleep 2
        tmux send-keys -t "${TMUX_SESSION}:${window}" Enter
        return 0
    fi

    # Dynamic timeout scaling based on system load
    local active_windows
    active_windows=$(tmux list-windows -t "$TMUX_SESSION" 2>/dev/null | wc -l | tr -d ' ')
    local scale_factor=1
    if [[ $active_windows -gt 5 ]]; then
        # Scale timeout: each 10 extra windows adds 1x more time
        scale_factor=$(( 1 + active_windows / 10 ))
    fi
    local perm_timeout=$(( ${TMUX_PERMISSIONS_TIMEOUT:-30} * scale_factor ))
    local ready_timeout=$(( ${TMUX_READINESS_TIMEOUT:-30} * scale_factor ))

    # Step 1: Check if a --dangerously-skip-permissions confirmation dialog appears.
    # Claude Code v2.1.49+ skips this dialog and starts directly in bypass mode.
    # Older versions show a "Do you trust the files" prompt requiring Down+Enter.
    local perm_content
    if wait_for_tmux_content "$window" "(Yes|trust|skip permissions|dangerously|bypass permissions on|❯)" "$perm_timeout"; then
        perm_content=$(tmux capture-pane -pt "${TMUX_SESSION}:${window}" -S -20 2>/dev/null)
        if echo "$perm_content" | grep -qE "(bypass permissions on|❯)"; then
            # Already in bypass mode — no confirmation dialog, skip Step 2
            log_info "Session started directly in bypass mode (no confirmation dialog needed)"
        else
            # Old-style confirmation dialog detected — accept it
            log_info "Permissions confirmation dialog detected, accepting..."
            tmux send-keys -t "${TMUX_SESSION}:${window}" Down
            sleep 1
            tmux send-keys -t "${TMUX_SESSION}:${window}" Enter
        fi
    else
        # Timed out waiting — check if already in bypass mode before sending keys
        perm_content=$(tmux capture-pane -pt "${TMUX_SESSION}:${window}" -S -20 2>/dev/null)
        if echo "$perm_content" | grep -qE "bypass permissions on"; then
            log_info "Session already in bypass mode (confirmation dialog not needed)"
        else
            log_warn "Permissions prompt not detected and not in bypass mode, trying confirmation anyway..."
            tmux send-keys -t "${TMUX_SESSION}:${window}" Down
            sleep 1
            tmux send-keys -t "${TMUX_SESSION}:${window}" Enter
        fi
    fi

    # Step 3: Wait for Claude to be ready (look for the input prompt indicator)
    if ! wait_for_tmux_content "$window" "(>|Claude|Type|message|\\$)" "$ready_timeout"; then
        log_warn "Claude prompt not detected, trying anyway..."
        sleep 5
    fi

    # Step 4: Paste the prompt
    tmux load-buffer "$prompt_file"
    tmux paste-buffer -t "${TMUX_SESSION}:${window}"

    # Step 5: Wait briefly for paste to complete, then submit
    sleep 2
    tmux send-keys -t "${TMUX_SESSION}:${window}" Enter

    log_info "Prompt submitted to Claude session in window '$window'"
    return 0
}

# File-based notification throttle — limits to 1 notification per pane per
# issue type every 5 minutes to prevent Slack spam from the 15s check interval.
# Usage: _pane_health_should_notify "pane_id" "issue_type"
# Returns: 0 if should notify, 1 if throttled
_pane_health_should_notify() {
    local pane_id="$1"
    local issue_type="$2"
    local throttle_dir="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-health-throttle"
    local throttle_file="${throttle_dir}/${pane_id}--${issue_type}"
    local cooldown=300  # 5 minutes

    mkdir -p "$throttle_dir"

    if [[ -f "$throttle_file" ]]; then
        local last_notify
        last_notify=$(cat "$throttle_file" 2>/dev/null || echo "0")
        local now
        now=$(date +%s)
        if (( now - last_notify < cooldown )); then
            return 1  # throttled
        fi
    fi

    date +%s > "$throttle_file"
    return 0
}

# Check all panes in a tmux window for stuck prompts and auto-resolve them.
# Collects issues across all panes and sends a single batched Slack notification.
# Usage: check_pane_health "window-name" "job_name"
check_pane_health() {
    local window="$1"
    local job_name="${2:-monitor}"
    local auto_resolve="${AUTO_RESOLVE_PROMPTS:-true}"
    local panes

    panes=$(tmux list-panes -t "${TMUX_SESSION}:${window}" -F '#{pane_index}' 2>/dev/null) || return 0

    # Batch counters for notification aggregation
    local rate_limit_panes=""
    local permission_panes=""
    local fatal_panes=""
    local fatal_snippets=""
    local rate_limit_count=0
    local permission_count=0
    local fatal_count=0

    for pane_idx in $panes; do
        local content
        content=$(tmux capture-pane -t "${TMUX_SESSION}:${window}.${pane_idx}" -p 2>/dev/null) || continue

        local pane_id="${window}.${pane_idx}"

        # Priority 0: Account-level rate limit (unrecoverable in-place)
        if echo "$content" | grep -qE "$PANE_PATTERN_ACCOUNT_LIMIT"; then
            _log_structured "error" "Account-level rate limit detected in pane ${pane_id}" \
                "\"type\":\"pane_health\",\"issue\":\"account_rate_limit\",\"pane\":\"${pane_id}\",\"job\":\"${job_name}\""

            # Signal monitor_session to tear down this session
            local signal_file="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-signals/signal-${window}"
            mkdir -p "$(dirname "$signal_file")"
            echo "rate_limited" > "$signal_file"

            if _pane_health_should_notify "$pane_id" "account_rate_limit"; then
                "${AUTOMATION_DIR:-$SCRIPT_DIR}/bin/notify.sh" \
                    --slack \
                    --message "Account rate limit hit in pane ${pane_id} (job: ${job_name}). Session will be paused and retried later." \
                    --job-name "pane-health" \
                    --status failure 2>/dev/null || log_warn "Pane health Slack notification failed"
            fi
            continue
        fi

        # Priority 1: Rate limit prompt (model switch — recoverable)
        if echo "$content" | grep -qE "$PANE_PATTERN_RATE_LIMIT"; then
            _log_structured "warn" "Rate limit detected in pane ${pane_id}" \
                "\"type\":\"pane_health\",\"issue\":\"rate_limit\",\"pane\":\"${pane_id}\",\"job\":\"${job_name}\""

            if [[ "$auto_resolve" == "true" ]]; then
                tmux send-keys -t "${TMUX_SESSION}:${window}.${pane_idx}" Down Enter
                log_info "Auto-resolved rate limit prompt in pane ${pane_id}"
            fi

            rate_limit_count=$((rate_limit_count + 1))
            rate_limit_panes="${rate_limit_panes:+${rate_limit_panes}, }${pane_id}"
            continue
        fi

        # Priority 2: Permission prompt
        # Note: "Waiting for team lead approval" prompts CANNOT be auto-resolved by
        # pressing Enter — they require the lead agent to send an approval message.
        # Detection here is for monitoring/alerting only (Slack notifications).
        # Fix: ensure leads pass `mode: "bypassPermissions"` when spawning teammates.
        if echo "$content" | grep -qE "$PANE_PATTERN_PERMISSION"; then
            _log_structured "warn" "Permission prompt detected in pane ${pane_id}" \
                "\"type\":\"pane_health\",\"issue\":\"permission\",\"pane\":\"${pane_id}\",\"job\":\"${job_name}\""

            if [[ "$auto_resolve" == "true" ]]; then
                tmux send-keys -t "${TMUX_SESSION}:${window}.${pane_idx}" Enter
                log_info "Auto-resolved permission prompt in pane ${pane_id}"
            fi

            permission_count=$((permission_count + 1))
            permission_panes="${permission_panes:+${permission_panes}, }${pane_id}"
            continue
        fi

        # Priority 3: Fatal error (no auto-resolve)
        if echo "$content" | grep -qE "$PANE_PATTERN_FATAL"; then
            local error_snippet
            error_snippet=$(echo "$content" | grep -E "$PANE_PATTERN_FATAL" | tail -3)

            _log_structured "error" "Fatal error detected in pane ${pane_id}" \
                "\"type\":\"pane_health\",\"issue\":\"fatal\",\"pane\":\"${pane_id}\",\"job\":\"${job_name}\""

            fatal_count=$((fatal_count + 1))
            fatal_panes="${fatal_panes:+${fatal_panes}, }${pane_id}"
            fatal_snippets="${fatal_snippets:+${fatal_snippets}\n---\n}[${pane_id}] ${error_snippet}"
            continue
        fi
    done

    # Send one batched notification if any issues were found
    local total_issues=$((rate_limit_count + permission_count + fatal_count))
    if [[ $total_issues -gt 0 ]] && _pane_health_should_notify "batch-summary" "${job_name}"; then
        local message="Pane health summary for ${window} (job: ${job_name}):"
        if [[ $rate_limit_count -gt 0 ]]; then
            message="${message}\n• Rate limit: ${rate_limit_count} pane(s) [${rate_limit_panes}] (auto-resolve: ${auto_resolve})"
        fi
        if [[ $permission_count -gt 0 ]]; then
            message="${message}\n• Permission: ${permission_count} pane(s) [${permission_panes}] (auto-resolve: ${auto_resolve})"
        fi
        if [[ $fatal_count -gt 0 ]]; then
            message="${message}\n• FATAL: ${fatal_count} pane(s) [${fatal_panes}]\n\`\`\`\n${fatal_snippets}\n\`\`\`"
        fi

        local status="failure"
        if [[ $fatal_count -gt 0 ]]; then
            status="emergency"
        fi

        "${AUTOMATION_DIR:-$SCRIPT_DIR}/bin/notify.sh" \
            --slack \
            --message "$message" \
            --job-name "pane-health" \
            --status "$status" 2>/dev/null || log_warn "Pane health Slack notification failed"
    fi
}

# Monitor a Claude session with timeout
# Usage: monitor_session "window-name" timeout_seconds [check_interval] [job_name]
# Returns: 0 if session ended normally, 1 if timed out, 2 if account rate limited
monitor_session() {
    local window="$1"
    local timeout="$2"
    local interval="${3:-15}"
    local job_name="${4:-monitor}"
    local signal_file="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-signals/signal-${window}"
    mkdir -p "$(dirname "$signal_file")"
    local start
    start=$(date +%s)

    # Clean up any stale signal file from a previous run
    rm -f "$signal_file"

    # Clean up stale throttle files older than 10 minutes from previous sessions
    local throttle_dir="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-health-throttle"
    if [[ -d "$throttle_dir" ]]; then
        find "$throttle_dir" -type f -mmin +10 -delete 2>/dev/null || true
    fi

    log_info "Monitoring session '$window' (timeout: ${timeout}s)"

    while tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qF "$window"; do
        local elapsed=$(( $(date +%s) - start ))
        if [[ $elapsed -gt $timeout ]]; then
            log_warn "Session '$window' timed out after ${timeout}s"
            # Try graceful shutdown
            tmux send-keys -t "${TMUX_SESSION}:${window}" C-c
            sleep 5
            tmux send-keys -t "${TMUX_SESSION}:${window}" "/exit" Enter
            sleep 5
            # Force kill if still alive
            if tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qF "$window"; then
                tmux kill-window -t "${TMUX_SESSION}:${window}" 2>/dev/null || true
            fi
            rm -f "$signal_file"
            return 1
        fi
        check_pane_health "$window" "$job_name"

        # Check for account-level rate limit signal
        if [[ -f "$signal_file" ]] && [[ "$(cat "$signal_file" 2>/dev/null)" == "rate_limited" ]]; then
            log_warn "Account rate limit signal detected for session '$window' — tearing down"
            # Graceful shutdown
            tmux send-keys -t "${TMUX_SESSION}:${window}" C-c
            sleep 3
            tmux send-keys -t "${TMUX_SESSION}:${window}" "/exit" Enter
            sleep 5
            # Force kill if still alive
            if tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qF "$window"; then
                tmux kill-window -t "${TMUX_SESSION}:${window}" 2>/dev/null || true
            fi
            rm -f "$signal_file"
            return 2
        fi

        sleep "$interval"
    done

    rm -f "$signal_file"
    log_info "Session '$window' ended normally"
    return 0
}
