#!/usr/bin/env bash
# Zapat — OpenAI Codex Provider
# Implements the provider interface for Codex CLI.

# Run a non-interactive Codex session.
# Usage: provider_run_noninteractive prompt_file model allowed_tools budget timeout
# Returns: stdout = command output, exit code = 0 on success
provider_run_noninteractive() {
    local prompt_file="$1"
    local model="${2:-${CODEX_MODEL:-codex}}"
    local allowed_tools="${3:-}"
    local budget="${4:-}"
    local timeout="${5:-600}"

    # Codex CLI does not support --allowedTools — log warning if specified
    if [[ -n "$allowed_tools" ]]; then
        echo "[WARN] Codex provider: --allowedTools not supported, ignoring: $allowed_tools" >&2
    fi

    # Codex CLI does not support --max-budget-usd — log warning if specified
    if [[ -n "$budget" ]]; then
        echo "[WARN] Codex provider: --max-budget-usd not supported, ignoring: \$${budget}" >&2
    fi

    local timeout_cmd
    if [[ "$(uname -s)" == "Darwin" ]]; then
        timeout_cmd="gtimeout"
    else
        timeout_cmd="timeout"
    fi

    # codex exec for non-interactive headless execution
    $timeout_cmd "$timeout" codex exec \
        --model "$model" \
        --dangerously-bypass-approvals-and-sandbox \
        "$(cat "$prompt_file")" \
        2>&1
}

# Regex for idle detection in tmux pane
provider_get_idle_pattern() {
    echo "^>"
}

# Regex for active/working detection
provider_get_spinner_pattern() {
    echo "(Thinking|Working|Generating|\\.\\.\\.|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏)"
}

# Regex for rate limit detection
provider_get_rate_limit_pattern() {
    echo "(Rate limit|rate_limit|429|Too Many Requests|Retry after)"
}

# Regex for account limit detection
provider_get_account_limit_pattern() {
    echo "(usage limit|quota exceeded|billing|insufficient_quota)"
}

# Regex for permission prompts
provider_get_permission_pattern() {
    echo "(Allow|Approve|Do you want to|approve this action)"
}

# Regex for fatal errors
provider_get_fatal_pattern() {
    echo "(FATAL|OOM|out of memory|Segmentation fault|core dumped|panic:|SIGKILL)"
}

# Full CLI invocation string for tmux session
# Usage: provider_get_launch_cmd model
provider_get_launch_cmd() {
    local model="${1:-${CODEX_MODEL:-codex}}"
    # Codex uses --dangerously-bypass-approvals-and-sandbox (maps to Claude's --dangerously-skip-permissions)
    echo "codex --model '${model}' --dangerously-bypass-approvals-and-sandbox"
}

# Verify CLI is installed and auth is valid
# Returns: 0 if ready, 1 if not
provider_prereq_check() {
    local failed=0
    local failures=""

    if ! command -v codex &>/dev/null; then
        failures="${failures}\n- codex CLI not found (install: npm install -g @openai/codex)"
        failed=1
    fi

    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        failures="${failures}\n- OPENAI_API_KEY not set"
        failed=1
    fi

    if [[ $failed -ne 0 ]]; then
        echo "$failures"
        return 1
    fi
    return 0
}

# Convert full model name to shorthand
# Usage: provider_get_model_shorthand "o3"
provider_get_model_shorthand() {
    local model_string="${1:-}"
    case "$model_string" in
        *o3*)     echo "o3" ;;
        *o4-mini*) echo "o4-mini" ;;
        *codex*)  echo "codex" ;;
        *)        echo "$model_string" ;;  # pass through unknown models
    esac
}
