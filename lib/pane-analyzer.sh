#!/usr/bin/env bash
# Zapat — LLM-Driven Pane Interaction
# Uses Claude Haiku to interpret tmux pane content and decide what action to take.
# Source this file: source "$SCRIPT_DIR/lib/pane-analyzer.sh"

# Allowlisted keystrokes — anything else from Haiku is rejected
_PANE_ALLOWED_KEYS="Enter Down Escape C-c"

# Analyze a tmux pane's content using Haiku.
# Usage: analyze_pane "window-name" "startup|monitoring" "job context string"
# Outputs: JSON object with state, keys, reason fields
# Returns: 0 on success, 1 on failure (Haiku unavailable, bad response, etc.)
analyze_pane() {
    local window="$1"
    local phase="$2"
    local job_context="$3"

    # Capture last 30 lines of the pane
    local pane_content
    pane_content=$(tmux capture-pane -t "${TMUX_SESSION}:${window}" -p -S -30 2>/dev/null) || {
        echo '{"state":"error","keys":"","reason":"Failed to capture pane content"}'
        return 1
    }

    # Empty pane — still loading
    if [[ -z "$pane_content" || "$pane_content" =~ ^[[:space:]]*$ ]]; then
        echo '{"state":"loading","keys":"","reason":"Pane is empty, still loading"}'
        return 0
    fi

    local phase_instructions
    if [[ "$phase" == "startup" ]]; then
        phase_instructions="We just launched Claude Code in this tmux window. We need to navigate through any startup dialogs (trust prompts, permission confirmations) until we reach the interactive prompt (the arrow character) where we can paste a task.
Tell us what keystroke to send to proceed, or empty string if we should wait.
IMPORTANT: The trust dialog defaults to 'Yes, I trust this folder' (first option, already highlighted). Just press Enter to accept. Do NOT send Down — that selects 'No, exit' and kills the session."
    else
        phase_instructions="Claude Code is running a task. We are monitoring for stuck states: rate limit dialogs, permission prompts asking for approval, account usage limits, fatal errors, or the session being idle at the prompt after finishing work.
If the session is actively working (spinner visible, text being generated), report state as 'working' with empty keys.
For rate limit prompts (offering to switch model), send Down then Enter to accept the alternate model.
For permission prompts, send Enter to approve.
For account-level limits (out of usage, plan limit), report state as 'account_limit' — do NOT send keys, the session must be torn down."
    fi

    local response
    response=$(claude -p "You are the pane interaction controller for Zapat, an autonomous dev pipeline.
Zapat launches Claude Code sessions inside tmux windows to work on GitHub issues and PRs.

CURRENT SITUATION:
- Phase: ${phase}
- Job: ${job_context}
- You are looking at the tmux pane content of a Claude Code CLI session.

YOUR TASK (${phase} phase):
${phase_instructions}

RULES:
- Respond with ONLY a JSON object, no markdown fences, no other text
- \"keys\" must be one of: \"Enter\", \"Down Enter\", \"Down\", \"Escape\", \"C-c\", or \"\" (empty = do nothing)
- \"state\" must be one of: \"ready\" (at the input prompt, ready for task), \"trust_dialog\" (trust folder prompt), \"permission_prompt\" (permission/approval dialog), \"rate_limit\" (rate limit, switch model), \"account_limit\" (account usage exhausted), \"fatal\" (unrecoverable error), \"working\" (actively processing), \"loading\" (still starting up), \"idle\" (finished work, at prompt with cost summary visible), \"unknown\" (cannot determine)
- If you see a selection menu, determine which option is already highlighted (marked with a pointer or similar) before deciding whether Down is needed
- If unsure what the screen shows, use {\"state\": \"unknown\", \"keys\": \"\"}
- NEVER guess keystrokes — wrong keys can kill the session

<screen>
${pane_content}
</screen>

Respond as JSON: {\"state\": \"...\", \"keys\": \"...\", \"reason\": \"...\"}" \
        --model claude-haiku-4-5-20251001 \
        --max-tokens 150 2>/dev/null)

    local exit_code=$?
    if [[ $exit_code -ne 0 || -z "$response" ]]; then
        echo '{"state":"error","keys":"","reason":"Haiku API call failed"}'
        return 1
    fi

    # Strip markdown fences if Haiku wrapped the response
    response=$(echo "$response" | sed 's/^```json//; s/^```//; s/```$//' | tr -d '\n')

    # Validate it's parseable JSON with required fields
    if ! echo "$response" | jq -e '.state and (.keys != null) and .reason' &>/dev/null; then
        echo '{"state":"error","keys":"","reason":"Invalid JSON from Haiku"}'
        return 1
    fi

    echo "$response"
    return 0
}

# Act on the pane analysis result: validate keys and send them.
# Usage: act_on_pane "window-name" "startup|monitoring" "job context string"
# Returns: The state string from the analysis (for caller to switch on)
act_on_pane() {
    local window="$1"
    local phase="$2"
    local job_context="$3"

    local result
    result=$(analyze_pane "$window" "$phase" "$job_context")
    local analyze_exit=$?

    local state keys reason
    state=$(echo "$result" | jq -r '.state // "error"')
    keys=$(echo "$result" | jq -r '.keys // ""')
    reason=$(echo "$result" | jq -r '.reason // "no reason"')

    # Log the analysis
    _log_structured "info" "Pane analysis: state=${state}, keys='${keys}', reason=${reason}" \
        "\"type\":\"pane_analysis\",\"window\":\"${window}\",\"phase\":\"${phase}\",\"state\":\"${state}\",\"keys\":\"${keys}\""

    # Validate keys against allowlist before sending
    if [[ -n "$keys" ]]; then
        local keys_valid=true
        # Split compound keys (e.g., "Down Enter") and validate each
        for key in $keys; do
            local found=false
            for allowed in $_PANE_ALLOWED_KEYS; do
                if [[ "$key" == "$allowed" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                keys_valid=false
                log_warn "Pane analyzer returned disallowed key: '$key' — rejecting"
                break
            fi
        done

        if [[ "$keys_valid" == "true" ]]; then
            for key in $keys; do
                tmux send-keys -t "${TMUX_SESSION}:${window}" "$key"
                # Brief pause between compound keystrokes
                sleep 0.3
            done
            log_info "Sent keys '${keys}' to window '${window}' (reason: ${reason})"
        fi
    fi

    # Capture unknown dialogs for debugging
    if [[ "$state" == "unknown" ]]; then
        _capture_unknown_pane "$window" "$result"
    fi

    echo "$state"
}

# Dump unknown pane content for debugging
_capture_unknown_pane() {
    local window="$1"
    local analysis_result="$2"
    local log_dir="${AUTOMATION_DIR:-$SCRIPT_DIR}/logs"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local dump_file="${log_dir}/unknown-pane-${window}-${timestamp}.txt"

    mkdir -p "$log_dir"

    {
        echo "=== Unknown Pane Capture ==="
        echo "Window: ${window}"
        echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "Analysis: ${analysis_result}"
        echo ""
        echo "=== Full Pane Content ==="
        tmux capture-pane -t "${TMUX_SESSION}:${window}" -p 2>/dev/null || echo "(capture failed)"
    } > "$dump_file"

    log_warn "Unknown pane state captured to $dump_file"

    _log_structured "warn" "Unknown pane dialog captured" \
        "\"type\":\"unknown_pane\",\"window\":\"${window}\",\"dump_file\":\"${dump_file}\""
}

# Fast-path check: determine if the pane is actively working without calling Haiku.
# Usage: _pane_is_active "window-name" "previous_content_hash"
# Outputs: "active" if clearly working, "check" if Haiku should be called
# Also outputs the current content hash on a second line.
_pane_is_active() {
    local window="$1"
    local prev_hash="$2"

    local content
    content=$(tmux capture-pane -t "${TMUX_SESSION}:${window}" -p -S -10 2>/dev/null) || {
        echo "check"
        echo ""
        return
    }

    # Check for spinner characters — active work in progress
    if echo "$content" | grep -qE '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'; then
        local cur_hash
        cur_hash=$(echo "$content" | md5 -q 2>/dev/null || echo "$content" | md5sum 2>/dev/null | cut -d' ' -f1)
        echo "active"
        echo "$cur_hash"
        return
    fi

    # Check if content changed since last check — actively working
    local cur_hash
    cur_hash=$(echo "$content" | md5 -q 2>/dev/null || echo "$content" | md5sum 2>/dev/null | cut -d' ' -f1)
    if [[ -n "$prev_hash" && "$cur_hash" != "$prev_hash" ]]; then
        echo "active"
        echo "$cur_hash"
        return
    fi

    # Content unchanged and no spinner — might be stuck, call Haiku
    echo "check"
    echo "$cur_hash"
}
