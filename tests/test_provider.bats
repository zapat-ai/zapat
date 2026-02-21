#!/usr/bin/env bats
# Tests for lib/provider.sh: provider dispatch, credential isolation, interface compliance

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

setup() {
    export TEST_DIR="$(mktemp -d)"
    export AUTOMATION_DIR="$TEST_DIR"
    mkdir -p "$TEST_DIR/lib/providers"
    mkdir -p "$TEST_DIR/logs"

    # Copy real provider files
    cp "$BATS_TEST_DIRNAME/../lib/provider.sh" "$TEST_DIR/lib/provider.sh"
    cp "$BATS_TEST_DIRNAME/../lib/providers/claude.sh" "$TEST_DIR/lib/providers/claude.sh"
    cp "$BATS_TEST_DIRNAME/../lib/providers/codex.sh" "$TEST_DIR/lib/providers/codex.sh"

    # Reset provider loaded guard between tests
    unset _ZAPAT_PROVIDER_LOADED
}

teardown() {
    rm -rf "$TEST_DIR"
    unset _ZAPAT_PROVIDER_LOADED
    unset AGENT_PROVIDER
    unset OPENAI_API_KEY
    unset ANTHROPIC_API_KEY
    unset CLAUDE_MODEL
    unset CODEX_MODEL
    unset CLAUDE_SUBAGENT_MODEL
    unset CODEX_SUBAGENT_MODEL
    unset CLAUDE_UTILITY_MODEL
    unset CODEX_UTILITY_MODEL
}

# --- Provider dispatch tests ---

@test "provider.sh defaults to claude when AGENT_PROVIDER is unset" {
    unset AGENT_PROVIDER
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    assert_equal "$AGENT_PROVIDER" "claude"
}

@test "provider.sh loads claude provider when AGENT_PROVIDER=claude" {
    export AGENT_PROVIDER=claude
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    # Verify claude-specific function behavior
    run provider_get_idle_pattern
    assert_output "^❯"
}

@test "provider.sh loads codex provider when AGENT_PROVIDER=codex" {
    export AGENT_PROVIDER=codex
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    # Verify codex-specific function behavior
    run provider_get_idle_pattern
    assert_output "^>"
}

@test "provider.sh fails for unknown provider" {
    export AGENT_PROVIDER=unknown
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    run source "$TEST_DIR/lib/provider.sh"
    assert_failure
    assert_output --partial "Unknown provider 'unknown'"
}

@test "provider.sh fails when provider is missing required function" {
    export AGENT_PROVIDER=broken
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    # Create a broken provider that's missing functions
    cat > "$TEST_DIR/lib/providers/broken.sh" <<'EOF'
provider_run_noninteractive() { echo "ok"; }
# Missing all other required functions
EOF
    run source "$TEST_DIR/lib/provider.sh"
    assert_failure
    assert_output --partial "does not implement required function"
}

# --- Credential isolation tests ---

@test "claude provider unsets OPENAI_API_KEY" {
    export AGENT_PROVIDER=claude
    export OPENAI_API_KEY="sk-test-key"
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    assert_equal "${OPENAI_API_KEY:-}" ""
}

@test "claude provider unsets CODEX_MODEL" {
    export AGENT_PROVIDER=claude
    export CODEX_MODEL="codex"
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    assert_equal "${CODEX_MODEL:-}" ""
}

@test "claude provider unsets CODEX_SUBAGENT_MODEL" {
    export AGENT_PROVIDER=claude
    export CODEX_SUBAGENT_MODEL="codex"
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    assert_equal "${CODEX_SUBAGENT_MODEL:-}" ""
}

@test "claude provider unsets CODEX_UTILITY_MODEL" {
    export AGENT_PROVIDER=claude
    export CODEX_UTILITY_MODEL="codex"
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    assert_equal "${CODEX_UTILITY_MODEL:-}" ""
}

@test "codex provider unsets ANTHROPIC_API_KEY" {
    export AGENT_PROVIDER=codex
    export ANTHROPIC_API_KEY="sk-ant-test-key"
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    assert_equal "${ANTHROPIC_API_KEY:-}" ""
}

@test "codex provider unsets CLAUDE_MODEL" {
    export AGENT_PROVIDER=codex
    export CLAUDE_MODEL="claude-opus-4-6"
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    assert_equal "${CLAUDE_MODEL:-}" ""
}

@test "codex provider unsets CLAUDE_SUBAGENT_MODEL" {
    export AGENT_PROVIDER=codex
    export CLAUDE_SUBAGENT_MODEL="claude-sonnet-4-6"
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    assert_equal "${CLAUDE_SUBAGENT_MODEL:-}" ""
}

@test "codex provider unsets CLAUDE_UTILITY_MODEL" {
    export AGENT_PROVIDER=codex
    export CLAUDE_UTILITY_MODEL="claude-haiku-4-5-20251001"
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    assert_equal "${CLAUDE_UTILITY_MODEL:-}" ""
}

# --- Claude provider interface tests ---

@test "claude: provider_get_rate_limit_pattern matches expected strings" {
    export AGENT_PROVIDER=claude
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    local pattern
    pattern=$(provider_get_rate_limit_pattern)
    echo "Switch to extra" | grep -qE "$pattern"
    echo "Rate limit exceeded" | grep -qE "$pattern"
    echo "429 error" | grep -qE "$pattern"
}

@test "claude: provider_get_account_limit_pattern matches expected strings" {
    export AGENT_PROVIDER=claude
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    local pattern
    pattern=$(provider_get_account_limit_pattern)
    echo "out of extra usage" | grep -qE "$pattern"
    echo "plan limit" | grep -qE "$pattern"
}

@test "claude: provider_get_permission_pattern matches Claude CLI prompts" {
    export AGENT_PROVIDER=claude
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    local pattern
    pattern=$(provider_get_permission_pattern)
    echo "Allow once" | grep -qE "$pattern"
    echo "Allow always" | grep -qE "$pattern"
    echo "wants to use the Bash tool" | grep -qE "$pattern"
}

@test "claude: provider_get_permission_pattern does NOT match bypass permissions" {
    export AGENT_PROVIDER=claude
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    local pattern
    pattern=$(provider_get_permission_pattern)
    ! echo "bypass permissions on" | grep -qE "$pattern"
}

@test "claude: provider_get_launch_cmd includes model and bypass flags" {
    export AGENT_PROVIDER=claude
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    run provider_get_launch_cmd "claude-sonnet-4-6"
    assert_output --partial "claude"
    assert_output --partial "claude-sonnet-4-6"
    assert_output --partial "--dangerously-skip-permissions"
}

@test "claude: provider_prereq_check succeeds when claude is installed" {
    export AGENT_PROVIDER=claude
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    # claude should be available in the test environment
    if command -v claude &>/dev/null; then
        run provider_prereq_check
        assert_success
    else
        skip "claude CLI not installed in test environment"
    fi
}

@test "claude: provider_get_model_shorthand maps model names correctly" {
    export AGENT_PROVIDER=claude
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"

    run provider_get_model_shorthand "claude-opus-4-6"
    assert_output "opus"

    run provider_get_model_shorthand "claude-sonnet-4-6"
    assert_output "sonnet"

    run provider_get_model_shorthand "claude-haiku-4-5-20251001"
    assert_output "haiku"

    # Unknown model defaults to sonnet
    run provider_get_model_shorthand "unknown-model"
    assert_output "sonnet"
}

# --- Codex provider interface tests ---

@test "codex: provider_get_launch_cmd includes dangerously-bypass flag" {
    export AGENT_PROVIDER=codex
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    run provider_get_launch_cmd "o3"
    assert_output --partial "codex"
    assert_output --partial "o3"
    assert_output --partial "--dangerously-bypass-approvals-and-sandbox"
}

@test "codex: provider_get_model_shorthand maps OpenAI models" {
    export AGENT_PROVIDER=codex
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"

    run provider_get_model_shorthand "o3"
    assert_output "o3"

    run provider_get_model_shorthand "o4-mini"
    assert_output "o4-mini"

    run provider_get_model_shorthand "codex"
    assert_output "codex"
}

@test "codex: provider_get_rate_limit_pattern matches expected strings" {
    export AGENT_PROVIDER=codex
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    local pattern
    pattern=$(provider_get_rate_limit_pattern)
    echo "Rate limit exceeded" | grep -qE "$pattern"
    echo "429 error" | grep -qE "$pattern"
}

# --- Path traversal prevention tests ---

@test "provider.sh rejects AGENT_PROVIDER with path traversal" {
    export AGENT_PROVIDER="../../etc/malicious"
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    run source "$TEST_DIR/lib/provider.sh"
    assert_failure
    assert_output --partial "Invalid AGENT_PROVIDER"
}

@test "provider.sh rejects AGENT_PROVIDER with slashes" {
    export AGENT_PROVIDER="foo/bar"
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    run source "$TEST_DIR/lib/provider.sh"
    assert_failure
    assert_output --partial "Invalid AGENT_PROVIDER"
}

@test "provider.sh rejects AGENT_PROVIDER with dots" {
    export AGENT_PROVIDER="claude.sh"
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    run source "$TEST_DIR/lib/provider.sh"
    assert_failure
    assert_output --partial "Invalid AGENT_PROVIDER"
}

@test "provider.sh accepts valid AGENT_PROVIDER names" {
    export AGENT_PROVIDER=claude
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    assert_equal "$AGENT_PROVIDER" "claude"
}

# --- Double-source guard test ---

@test "provider.sh can be sourced twice without error" {
    export AGENT_PROVIDER=claude
    export _PROVIDER_DIR="$TEST_DIR/lib/providers"
    source "$TEST_DIR/lib/provider.sh"
    # Second source should be a no-op (guard prevents re-loading)
    source "$TEST_DIR/lib/provider.sh"
    # Functions should still work
    run provider_get_idle_pattern
    assert_output "^❯"
}

# --- tmux-helpers backward compatibility ---

@test "launch_claude_session alias exists and delegates to launch_agent_session" {
    # Source tmux-helpers.sh in a subshell with stubbed dependencies
    (
        export AGENT_PROVIDER=claude
        export _PROVIDER_DIR="$TEST_DIR/lib/providers"
        # Stub log functions
        log_info() { :; }
        log_warn() { :; }
        log_error() { :; }
        _log_structured() { :; }
        source "$BATS_TEST_DIRNAME/../lib/tmux-helpers.sh"
        # Verify the alias function exists
        declare -f launch_claude_session &>/dev/null
    )
}
