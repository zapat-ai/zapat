#!/usr/bin/env bash
# Zapat — Claude Code Provider
# Implements the provider interface for Claude Code CLI.
# This is the default provider and reproduces existing behavior exactly.

# Run a non-interactive Claude Code session.
# Usage: provider_run_noninteractive prompt_file model allowed_tools budget timeout
# Returns: stdout = command output, exit code = 0 on success
provider_run_noninteractive() {
    local prompt_file="$1"
    local model="${2:-${CLAUDE_MODEL:-claude-opus-4-6}}"
    local allowed_tools="${3:-Read,Glob,Grep}"
    local budget="${4:-5}"
    local timeout="${5:-600}"

    local timeout_cmd
    if [[ "$(uname -s)" == "Darwin" ]]; then
        timeout_cmd="gtimeout"
    else
        timeout_cmd="timeout"
    fi

    $timeout_cmd "$timeout" claude \
        -p "$(cat "$prompt_file")" \
        --model "$model" \
        --allowedTools "$allowed_tools" \
        --max-budget-usd "$budget" \
        2>&1
}

# Regex for idle detection in tmux pane (Claude at ❯ prompt with cost line)
provider_get_idle_pattern() {
    echo "^❯"
}

# Regex for active/working detection (spinner characters)
provider_get_spinner_pattern() {
    echo "(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|Working|Thinking)"
}

# Regex for rate limit detection
provider_get_rate_limit_pattern() {
    echo "(Switch to extra|Rate limit|rate_limit|429|Too Many Requests|Retry after)"
}

# Regex for account limit detection
provider_get_account_limit_pattern() {
    echo "(out of extra usage|resets [0-9]|usage limit|plan limit|You've reached)"
}

# Regex for permission prompts
provider_get_permission_pattern() {
    echo "(Allow once|Allow always|Do you want to allow|Do you want to (create|make|run|write|edit)|wants to use the .* tool|approve this action|Waiting for team lead approval)"
}

# Regex for fatal errors
provider_get_fatal_pattern() {
    echo "(FATAL|OOM|out of memory|Segmentation fault|core dumped|panic:|SIGKILL)"
}

# Full CLI invocation string for tmux session
# Usage: provider_get_launch_cmd model
provider_get_launch_cmd() {
    local model="${1:-${CLAUDE_MODEL:-claude-opus-4-6}}"
    echo "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --model '${model}' --dangerously-skip-permissions --permission-mode bypassPermissions"
}

# Verify CLI is installed and auth is valid
# Returns: 0 if ready, 1 if not
provider_prereq_check() {
    local failed=0
    local failures=""

    if ! command -v claude &>/dev/null; then
        failures="${failures}\n- claude CLI not found (install: npm install -g @anthropic-ai/claude-code)"
        failed=1
    fi

    if [[ $failed -ne 0 ]]; then
        echo "$failures"
        return 1
    fi
    return 0
}

# Convert full model name to shorthand for Task tool model parameter
# Usage: provider_get_model_shorthand "claude-opus-4-6"
# Returns: opus, sonnet, or haiku
provider_get_model_shorthand() {
    local model_string="${1:-}"
    case "$model_string" in
        *opus*)   echo "opus" ;;
        *haiku*)  echo "haiku" ;;
        *sonnet*) echo "sonnet" ;;
        *)        echo "sonnet" ;;  # default fallback
    esac
}
