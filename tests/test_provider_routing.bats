#!/usr/bin/env bats
# Tests for label-based provider routing in poll-github.sh

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

setup() {
    export TEST_DIR="$(mktemp -d)"

    # Source the detect_provider_label function by extracting it from poll-github.sh
    # We re-implement it here to test in isolation (the function relies on jq and grep)
    detect_provider_label() {
        local labels="$1"
        local has_codex=false
        local has_claude=false

        if [[ "$labels" == "["* ]]; then
            if echo "$labels" | jq -e '.[] | select(.name == "codex")' &>/dev/null; then
                has_codex=true
            fi
            if echo "$labels" | jq -e '.[] | select(.name == "claude")' &>/dev/null; then
                has_claude=true
            fi
        else
            if echo ",$labels," | grep -q ",codex,"; then
                has_codex=true
            fi
            if echo ",$labels," | grep -q ",claude,"; then
                has_claude=true
            fi
        fi

        if [[ "$has_claude" == "true" && "$has_codex" == "true" ]]; then
            export AGENT_PROVIDER="claude"
        elif [[ "$has_codex" == "true" ]]; then
            export AGENT_PROVIDER="codex"
        elif [[ "$has_claude" == "true" ]]; then
            export AGENT_PROVIDER="claude"
        else
            export AGENT_PROVIDER="${AGENT_PROVIDER:-claude}"
        fi
    }
}

teardown() {
    rm -rf "$TEST_DIR"
    unset AGENT_PROVIDER
}

# --- JSON label format tests ---

@test "codex JSON label sets AGENT_PROVIDER=codex" {
    unset AGENT_PROVIDER
    detect_provider_label '[{"name":"agent-work"},{"name":"codex"}]'
    assert_equal "$AGENT_PROVIDER" "codex"
}

@test "claude JSON label sets AGENT_PROVIDER=claude" {
    unset AGENT_PROVIDER
    detect_provider_label '[{"name":"agent"},{"name":"claude"}]'
    assert_equal "$AGENT_PROVIDER" "claude"
}

@test "no provider JSON label falls back to env default" {
    export AGENT_PROVIDER="codex"
    detect_provider_label '[{"name":"agent-work"},{"name":"feature"}]'
    assert_equal "$AGENT_PROVIDER" "codex"
}

@test "no provider JSON label falls back to claude when env unset" {
    unset AGENT_PROVIDER
    detect_provider_label '[{"name":"agent-work"}]'
    assert_equal "$AGENT_PROVIDER" "claude"
}

@test "conflicting JSON labels prefers claude" {
    unset AGENT_PROVIDER
    detect_provider_label '[{"name":"codex"},{"name":"claude"}]'
    assert_equal "$AGENT_PROVIDER" "claude"
}

# --- CSV label format tests ---

@test "codex CSV label sets AGENT_PROVIDER=codex" {
    unset AGENT_PROVIDER
    detect_provider_label "agent-work,codex,feature"
    assert_equal "$AGENT_PROVIDER" "codex"
}

@test "claude CSV label sets AGENT_PROVIDER=claude" {
    unset AGENT_PROVIDER
    detect_provider_label "agent,claude"
    assert_equal "$AGENT_PROVIDER" "claude"
}

@test "no provider CSV label falls back to env default" {
    export AGENT_PROVIDER="codex"
    detect_provider_label "agent-work,feature"
    assert_equal "$AGENT_PROVIDER" "codex"
}

@test "no provider CSV label falls back to claude when env unset" {
    unset AGENT_PROVIDER
    detect_provider_label "agent-work,feature"
    assert_equal "$AGENT_PROVIDER" "claude"
}

@test "conflicting CSV labels prefers claude" {
    unset AGENT_PROVIDER
    detect_provider_label "codex,claude,agent-work"
    assert_equal "$AGENT_PROVIDER" "claude"
}

@test "empty labels fall back to claude" {
    unset AGENT_PROVIDER
    detect_provider_label ""
    assert_equal "$AGENT_PROVIDER" "claude"
}

@test "empty JSON array falls back to claude" {
    unset AGENT_PROVIDER
    detect_provider_label "[]"
    assert_equal "$AGENT_PROVIDER" "claude"
}

# --- CSV substring safety ---

@test "CSV label 'codex-extra' does not match codex" {
    unset AGENT_PROVIDER
    detect_provider_label "agent-work,codex-extra"
    assert_equal "$AGENT_PROVIDER" "claude"
}

@test "CSV label 'my-claude-thing' does not match claude" {
    unset AGENT_PROVIDER
    detect_provider_label "agent-work,my-claude-thing"
    assert_equal "$AGENT_PROVIDER" "claude"
}

# --- setup-labels.sh tests ---

@test "setup-labels.sh contains codex label definition" {
    run grep -c '"codex|74AA9C|Process with OpenAI Codex"' "$(dirname "$BATS_TEST_DIRNAME")/bin/setup-labels.sh"
    assert_success
    assert_output "1"
}

@test "setup-labels.sh contains claude label definition" {
    run grep -c '"claude|D97706|Process with Claude Code"' "$(dirname "$BATS_TEST_DIRNAME")/bin/setup-labels.sh"
    assert_success
    assert_output "1"
}

# --- Trigger script sourcing tests ---

@test "on-work-issue.sh sources lib/provider.sh" {
    run grep -c 'source "$SCRIPT_DIR/lib/provider.sh"' "$(dirname "$BATS_TEST_DIRNAME")/triggers/on-work-issue.sh"
    assert_success
    assert_output "1"
}

@test "on-new-issue.sh sources lib/provider.sh" {
    run grep -c 'source "$SCRIPT_DIR/lib/provider.sh"' "$(dirname "$BATS_TEST_DIRNAME")/triggers/on-new-issue.sh"
    assert_success
    assert_output "1"
}

@test "on-new-pr.sh sources lib/provider.sh" {
    run grep -c 'source "$SCRIPT_DIR/lib/provider.sh"' "$(dirname "$BATS_TEST_DIRNAME")/triggers/on-new-pr.sh"
    assert_success
    assert_output "1"
}

@test "on-research-issue.sh sources lib/provider.sh" {
    run grep -c 'source "$SCRIPT_DIR/lib/provider.sh"' "$(dirname "$BATS_TEST_DIRNAME")/triggers/on-research-issue.sh"
    assert_success
    assert_output "1"
}

@test "on-rework-pr.sh sources lib/provider.sh" {
    run grep -c 'source "$SCRIPT_DIR/lib/provider.sh"' "$(dirname "$BATS_TEST_DIRNAME")/triggers/on-rework-pr.sh"
    assert_success
    assert_output "1"
}

@test "on-test-pr.sh sources lib/provider.sh" {
    run grep -c 'source "$SCRIPT_DIR/lib/provider.sh"' "$(dirname "$BATS_TEST_DIRNAME")/triggers/on-test-pr.sh"
    assert_success
    assert_output "1"
}

@test "on-write-tests.sh sources lib/provider.sh" {
    run grep -c 'source "$SCRIPT_DIR/lib/provider.sh"' "$(dirname "$BATS_TEST_DIRNAME")/triggers/on-write-tests.sh"
    assert_success
    assert_output "1"
}

# --- Trigger scripts use launch_agent_session ---

@test "all triggers use launch_agent_session (not launch_claude_session)" {
    local triggers_dir="$(dirname "$BATS_TEST_DIRNAME")/triggers"
    # No trigger should directly call launch_claude_session
    run grep -rl 'launch_claude_session' "$triggers_dir"
    assert_failure  # grep returns 1 when no matches
}
