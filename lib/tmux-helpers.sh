#!/usr/bin/env bash
# Zapat - tmux Helper Functions
# Provides reliable tmux interaction with readiness detection.
# Source this file: source "$SCRIPT_DIR/lib/tmux-helpers.sh"

TMUX_SESSION="${TMUX_SESSION:-zapat}"

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
# Usage: launch_claude_session "window-name" "/path/to/workdir" "/path/to/prompt-file" [extra_env_vars]
# Returns: 0 if session launched and prompt submitted, 1 on failure
launch_claude_session() {
    local window="$1"
    local workdir="$2"
    local prompt_file="$3"
    local extra_env="${4:-}"

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
    cmd+="claude --model ${CLAUDE_MODEL:-claude-opus-4-6} "
    cmd+="--dangerously-skip-permissions; "
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

    # Step 1: Wait for the --dangerously-skip-permissions confirmation prompt
    # Claude CLI shows "Do you trust the files" or similar prompt
    if ! wait_for_tmux_content "$window" "(Yes|trust|skip permissions|dangerously)" 15; then
        log_warn "Permissions prompt not detected, trying anyway..."
        sleep 5
    fi

    # Step 2: Accept the confirmation (Down arrow to select "Yes", Enter to confirm)
    tmux send-keys -t "${TMUX_SESSION}:${window}" Down
    sleep 1
    tmux send-keys -t "${TMUX_SESSION}:${window}" Enter

    # Step 3: Wait for Claude to be ready (look for the input prompt indicator)
    if ! wait_for_tmux_content "$window" "(>|Claude|Type|message|\\$)" 15; then
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

# Monitor a Claude session with timeout
# Usage: monitor_session "window-name" timeout_seconds [check_interval]
# Returns: 0 if session ended normally, 1 if timed out
monitor_session() {
    local window="$1"
    local timeout="$2"
    local interval="${3:-15}"
    local start
    start=$(date +%s)

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
            return 1
        fi
        sleep "$interval"
    done

    log_info "Session '$window' ended normally"
    return 0
}
