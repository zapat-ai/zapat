#!/usr/bin/env bash
# Zapat - tmux Helper Functions
# Provides reliable tmux interaction with LLM-driven pane analysis.
# Source this file: source "$SCRIPT_DIR/lib/tmux-helpers.sh"

TMUX_SESSION="${TMUX_SESSION:-zapat}"

# Source pane analyzer (LLM-driven pane interaction)
# shellcheck source=lib/pane-analyzer.sh
source "$(dirname "${BASH_SOURCE[0]}")/pane-analyzer.sh"

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

# Launch a Claude session in a tmux window with LLM-driven startup navigation
# Usage: launch_claude_session "window-name" "/path/to/workdir" "/path/to/prompt-file" [extra_env_vars] [agent_model] [job_context]
# Returns: 0 if session launched and prompt submitted, 1 on failure
launch_claude_session() {
    local window="$1"
    local workdir="$2"
    local prompt_file="$3"
    local extra_env="${4:-}"
    local model="${5:-${CLAUDE_MODEL:-claude-opus-4-6}}"
    local job_context="${6:-unknown job}"

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
    log_info "tmux window '$window' created (job: ${job_context})"

    # Verify the window is still alive after a brief delay.
    # tmux destroys command-bearing windows when the process exits, so if
    # claude fails to start the window vanishes immediately.
    sleep 1
    if ! tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qF "$window"; then
        log_error "Window '$window' died immediately after creation — claude process likely failed to start"
        return 1
    fi

    # Dynamic timeout scaling based on system load
    local active_windows
    active_windows=$(tmux list-windows -t "$TMUX_SESSION" 2>/dev/null | wc -l | tr -d ' ')
    local scale_factor=1
    if [[ $active_windows -gt 5 ]]; then
        scale_factor=$(( 1 + active_windows / 10 ))
    fi
    local startup_timeout=$(( ${TMUX_STARTUP_TIMEOUT:-90} * scale_factor ))

    # LLM-driven startup loop: poll pane every 3s, ask Haiku what to do
    local startup_start
    startup_start=$(date +%s)
    local poll_interval=3

    log_info "Starting LLM-driven startup navigation (timeout: ${startup_timeout}s, job: ${job_context})"

    while true; do
        local elapsed=$(( $(date +%s) - startup_start ))
        if [[ $elapsed -gt $startup_timeout ]]; then
            log_error "Startup timed out after ${startup_timeout}s for window '$window'"
            tmux kill-window -t "${TMUX_SESSION}:${window}" 2>/dev/null || true
            return 1
        fi

        # Check window still alive
        if ! tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qF "$window"; then
            log_error "Window '$window' died during startup"
            return 1
        fi

        local state
        state=$(act_on_pane "$window" "startup" "$job_context")

        case "$state" in
            ready|idle)
                log_info "Session ready in window '$window' (${elapsed}s elapsed)"
                break
                ;;
            trust_dialog|permission_prompt)
                # act_on_pane already sent the keys, continue polling
                ;;
            rate_limit)
                # act_on_pane already sent keys to accept alternate model
                ;;
            account_limit)
                log_error "Account limit hit during startup for window '$window'"
                tmux kill-window -t "${TMUX_SESSION}:${window}" 2>/dev/null || true
                return 1
                ;;
            fatal)
                log_error "Fatal error during startup for window '$window'"
                tmux kill-window -t "${TMUX_SESSION}:${window}" 2>/dev/null || true
                return 1
                ;;
            working|loading)
                # Still starting up, no action needed
                ;;
            error)
                # Haiku call failed — fall back to a simple wait-and-retry
                log_warn "Pane analyzer error, waiting..."
                ;;
            unknown)
                # Unknown dialog captured to logs, continue polling
                log_warn "Unknown pane state in window '$window', continuing..."
                ;;
            *)
                log_warn "Unexpected pane state '${state}' in window '$window'"
                ;;
        esac

        sleep "$poll_interval"
    done

    # Paste the prompt
    tmux load-buffer "$prompt_file"
    tmux paste-buffer -t "${TMUX_SESSION}:${window}"

    # Wait briefly for paste to complete, then submit
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

# Check all panes in a tmux window for stuck prompts using LLM-driven analysis.
# Uses fast-path optimization: only calls Haiku when pane appears stuck.
# Collects issues across all panes and sends a single batched Slack notification.
# Usage: check_pane_health "window-name" "job_name" [job_context]
check_pane_health() {
    local window="$1"
    local job_name="${2:-monitor}"
    local job_context="${3:-${job_name}}"
    local panes

    panes=$(tmux list-panes -t "${TMUX_SESSION}:${window}" -F '#{pane_index}' 2>/dev/null) || return 0

    # Ensure hash cache is initialized
    _pane_hash_ensure

    # Batch counters for notification aggregation
    local rate_limit_panes=""
    local permission_panes=""
    local fatal_panes=""
    local account_limit_panes=""
    local fatal_snippets=""
    local rate_limit_count=0
    local permission_count=0
    local fatal_count=0
    local account_limit_count=0

    for pane_idx in $panes; do
        local pane_id="${window}.${pane_idx}"

        # Fast-path: check if pane is actively working (spinner or content changing)
        local fast_result cur_hash
        fast_result=$(_pane_is_active "${window}.${pane_idx}" "$(_pane_hash_get "$pane_id")")
        cur_hash=$(echo "$fast_result" | tail -1)
        fast_result=$(echo "$fast_result" | head -1)
        _pane_hash_set "$pane_id" "$cur_hash"

        if [[ "$fast_result" == "active" ]]; then
            # Pane is clearly working — skip Haiku call
            continue
        fi

        # Pane might be stuck — ask Haiku
        local state
        state=$(act_on_pane "${window}.${pane_idx}" "monitoring" "$job_context")

        case "$state" in
            working|loading)
                # Haiku says it's fine
                ;;
            account_limit)
                _log_structured "error" "Account-level rate limit detected in pane ${pane_id}" \
                    "\"type\":\"pane_health\",\"issue\":\"account_rate_limit\",\"pane\":\"${pane_id}\",\"job\":\"${job_name}\""

                # Signal monitor_session to tear down this session
                local signal_file="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-signals/signal-${window}"
                mkdir -p "$(dirname "$signal_file")"
                echo "rate_limited" > "$signal_file"

                account_limit_count=$((account_limit_count + 1))
                account_limit_panes="${account_limit_panes:+${account_limit_panes}, }${pane_id}"

                if _pane_health_should_notify "$pane_id" "account_rate_limit"; then
                    "${AUTOMATION_DIR:-$SCRIPT_DIR}/bin/notify.sh" \
                        --slack \
                        --message "Account rate limit hit in pane ${pane_id} (job: ${job_name}). Session will be paused and retried later." \
                        --job-name "pane-health" \
                        --status failure 2>/dev/null || log_warn "Pane health Slack notification failed"
                fi
                ;;
            rate_limit)
                _log_structured "warn" "Rate limit detected in pane ${pane_id}" \
                    "\"type\":\"pane_health\",\"issue\":\"rate_limit\",\"pane\":\"${pane_id}\",\"job\":\"${job_name}\""
                # act_on_pane already sent keys if auto_resolve is handled by Haiku
                rate_limit_count=$((rate_limit_count + 1))
                rate_limit_panes="${rate_limit_panes:+${rate_limit_panes}, }${pane_id}"
                ;;
            permission_prompt)
                _log_structured "warn" "Permission prompt detected in pane ${pane_id}" \
                    "\"type\":\"pane_health\",\"issue\":\"permission\",\"pane\":\"${pane_id}\",\"job\":\"${job_name}\""
                # act_on_pane already sent Enter
                permission_count=$((permission_count + 1))
                permission_panes="${permission_panes:+${permission_panes}, }${pane_id}"
                ;;
            fatal)
                local error_snippet
                error_snippet=$(tmux capture-pane -t "${TMUX_SESSION}:${window}.${pane_idx}" -p -S -5 2>/dev/null | tail -3)

                _log_structured "error" "Fatal error detected in pane ${pane_id}" \
                    "\"type\":\"pane_health\",\"issue\":\"fatal\",\"pane\":\"${pane_id}\",\"job\":\"${job_name}\""

                fatal_count=$((fatal_count + 1))
                fatal_panes="${fatal_panes:+${fatal_panes}, }${pane_id}"
                fatal_snippets="${fatal_snippets:+${fatal_snippets}\n---\n}[${pane_id}] ${error_snippet}"
                ;;
            *)
                # ready, idle, unknown, error — no health issue to report
                ;;
        esac
    done

    # Send one batched notification if any issues were found
    local total_issues=$((rate_limit_count + permission_count + fatal_count + account_limit_count))
    if [[ $total_issues -gt 0 ]] && _pane_health_should_notify "batch-summary" "${job_name}"; then
        local message="Pane health summary for ${window} (job: ${job_name}):"
        if [[ $account_limit_count -gt 0 ]]; then
            message="${message}\n• Account limit: ${account_limit_count} pane(s) [${account_limit_panes}]"
        fi
        if [[ $rate_limit_count -gt 0 ]]; then
            message="${message}\n• Rate limit: ${rate_limit_count} pane(s) [${rate_limit_panes}] (auto-resolved)"
        fi
        if [[ $permission_count -gt 0 ]]; then
            message="${message}\n• Permission: ${permission_count} pane(s) [${permission_panes}] (auto-resolved)"
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

# File-based pane content hash cache (fast-path optimization)
# Uses temp files instead of associative arrays for bash 3.2 compatibility (macOS)
_PANE_HASH_CACHE_DIR=""

_pane_hash_get() {
    local key="$1"
    local safe_key="${key//[^a-zA-Z0-9_-]/_}"
    [[ -n "$_PANE_HASH_CACHE_DIR" && -f "$_PANE_HASH_CACHE_DIR/$safe_key" ]] && cat "$_PANE_HASH_CACHE_DIR/$safe_key" || echo ""
}

_pane_hash_set() {
    local key="$1" value="$2"
    local safe_key="${key//[^a-zA-Z0-9_-]/_}"
    if [[ -n "$_PANE_HASH_CACHE_DIR" ]]; then
        echo "$value" > "$_PANE_HASH_CACHE_DIR/$safe_key"
    fi
}

_pane_hash_reset() {
    if [[ -n "$_PANE_HASH_CACHE_DIR" ]]; then
        rm -rf "$_PANE_HASH_CACHE_DIR"
    fi
    _PANE_HASH_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zapat-pane-hash.XXXXXX")
}

_pane_hash_cleanup() {
    if [[ -n "$_PANE_HASH_CACHE_DIR" ]]; then
        rm -rf "$_PANE_HASH_CACHE_DIR"
        _PANE_HASH_CACHE_DIR=""
    fi
}

_pane_hash_ensure() {
    if [[ -z "$_PANE_HASH_CACHE_DIR" || ! -d "$_PANE_HASH_CACHE_DIR" ]]; then
        _pane_hash_reset
    fi
}

# Monitor a Claude session with timeout and LLM-driven health checks
# Usage: monitor_session "window-name" timeout_seconds [check_interval] [job_name] [job_context]
# Returns: 0 if session ended normally, 1 if timed out, 2 if account rate limited
monitor_session() {
    local window="$1"
    local timeout="$2"
    local interval="${3:-15}"
    local job_name="${4:-monitor}"
    local job_context="${5:-${job_name}}"
    local signal_file="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-signals/signal-${window}"
    mkdir -p "$(dirname "$signal_file")"
    local start
    start=$(date +%s)

    # Clean up any stale signal file from a previous run
    rm -f "$signal_file"

    # Reset pane hash cache for this session; clean up on exit
    _pane_hash_reset
    trap '_pane_hash_cleanup' RETURN

    # Clean up stale throttle files older than 10 minutes from previous sessions
    local throttle_dir="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-health-throttle"
    if [[ -d "$throttle_dir" ]]; then
        find "$throttle_dir" -type f -mmin +10 -delete 2>/dev/null || true
    fi

    log_info "Monitoring session '$window' (timeout: ${timeout}s, job: ${job_context})"

    # Idle detection: count consecutive checks where Claude appears idle.
    # After 2 consecutive idle checks, kill the window.
    local idle_checks=0
    local idle_threshold=2
    local prev_content_hash=""

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

        # Run health check with LLM analysis on sub-panes
        check_pane_health "$window" "$job_name" "$job_context"

        # Check for account-level rate limit signal
        if [[ -f "$signal_file" ]] && [[ "$(cat "$signal_file" 2>/dev/null)" == "rate_limited" ]]; then
            log_warn "Account rate limit signal detected for session '$window' — tearing down"
            tmux send-keys -t "${TMUX_SESSION}:${window}" C-c
            sleep 3
            tmux send-keys -t "${TMUX_SESSION}:${window}" "/exit" Enter
            sleep 5
            if tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qF "$window"; then
                tmux kill-window -t "${TMUX_SESSION}:${window}" 2>/dev/null || true
            fi
            rm -f "$signal_file"
            return 2
        fi

        # Idle detection via fast-path check on main pane
        local fast_result cur_hash
        fast_result=$(_pane_is_active "$window" "$prev_content_hash")
        cur_hash=$(echo "$fast_result" | tail -1)
        fast_result=$(echo "$fast_result" | head -1)

        if [[ "$fast_result" == "check" ]]; then
            # Content unchanged and no spinner — might be idle, ask Haiku
            local state
            state=$(act_on_pane "$window" "monitoring" "$job_context")

            case "$state" in
                idle|ready)
                    idle_checks=$((idle_checks + 1))
                    if [[ $idle_checks -ge $idle_threshold ]]; then
                        log_info "Session '$window' idle at prompt for $idle_checks checks — killing window"
                        tmux kill-window -t "${TMUX_SESSION}:${window}" 2>/dev/null || true
                        rm -f "$signal_file"
                        log_info "Session '$window' terminated after idle detection"
                        return 0
                    fi
                    ;;
                account_limit)
                    log_warn "Account rate limit detected in main pane of '$window' — tearing down"
                    tmux send-keys -t "${TMUX_SESSION}:${window}" C-c
                    sleep 3
                    tmux kill-window -t "${TMUX_SESSION}:${window}" 2>/dev/null || true
                    rm -f "$signal_file"
                    return 2
                    ;;
                *)
                    # working, rate_limit (handled), permission_prompt (handled), etc.
                    idle_checks=0
                    ;;
            esac
        else
            # Pane is active — reset idle counter
            idle_checks=0
        fi

        prev_content_hash="$cur_hash"
        sleep "$interval"
    done

    rm -f "$signal_file"
    log_info "Session '$window' ended normally"
    return 0
}
