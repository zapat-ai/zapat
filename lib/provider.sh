#!/usr/bin/env bash
# Zapat — Provider Abstraction Layer
# Dispatches to the correct AI CLI provider based on AGENT_PROVIDER env var.
# Source this file: source "$SCRIPT_DIR/lib/provider.sh"
#
# After sourcing, all provider_*() functions are available.
# Default provider: claude (backward compatible).

# Guard against double-sourcing
[[ -n "${_ZAPAT_PROVIDER_LOADED:-}" ]] && return 0
_ZAPAT_PROVIDER_LOADED=1

# Resolve provider — default to claude for backward compatibility
AGENT_PROVIDER="${AGENT_PROVIDER:-claude}"

# Resolve path to provider implementations
_PROVIDER_DIR="${_PROVIDER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/providers" && pwd)}"

# --- Credential Isolation ---
# Only the active provider's credentials are exported. All other provider
# credentials are unset to prevent accidental leakage across providers.
_isolate_credentials() {
    case "$AGENT_PROVIDER" in
        claude)
            # Keep Anthropic credentials, remove OpenAI
            unset OPENAI_API_KEY 2>/dev/null || true
            unset CODEX_MODEL 2>/dev/null || true
            unset CODEX_SUBAGENT_MODEL 2>/dev/null || true
            unset CODEX_UTILITY_MODEL 2>/dev/null || true
            ;;
        codex)
            # Keep OpenAI credentials, remove Anthropic
            unset ANTHROPIC_API_KEY 2>/dev/null || true
            unset CLAUDE_MODEL 2>/dev/null || true
            unset CLAUDE_SUBAGENT_MODEL 2>/dev/null || true
            unset CLAUDE_UTILITY_MODEL 2>/dev/null || true
            ;;
        *)
            # Unknown provider — don't touch credentials, let the provider handle it
            ;;
    esac
}

# --- Load Provider Implementation ---
_provider_file="${_PROVIDER_DIR}/${AGENT_PROVIDER}.sh"

if [[ ! -f "$_provider_file" ]]; then
    echo "[ERROR] Unknown provider '${AGENT_PROVIDER}'. Available providers:" >&2
    for f in "${_PROVIDER_DIR}"/*.sh; do
        [[ -f "$f" ]] && echo "  - $(basename "$f" .sh)" >&2
    done
    return 1
fi

# shellcheck source=/dev/null
source "$_provider_file"

# Verify that the provider implements the required interface
_required_functions=(
    provider_run_noninteractive
    provider_get_idle_pattern
    provider_get_spinner_pattern
    provider_get_rate_limit_pattern
    provider_get_account_limit_pattern
    provider_get_permission_pattern
    provider_get_launch_cmd
    provider_prereq_check
    provider_get_model_shorthand
)

for fn in "${_required_functions[@]}"; do
    if ! declare -f "$fn" &>/dev/null; then
        echo "[ERROR] Provider '${AGENT_PROVIDER}' does not implement required function: $fn" >&2
        return 1
    fi
done

# Isolate credentials after loading provider
_isolate_credentials
