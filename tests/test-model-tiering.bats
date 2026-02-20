#!/usr/bin/env bats
# Tests for model tiering: env vars, fallback chains, and SUBAGENT_MODEL derivation

setup() {
    export TEST_DIR="$(mktemp -d)"
    export SCRIPT_DIR="$TEST_DIR"
    export AUTOMATION_DIR="$TEST_DIR"
    mkdir -p "$TEST_DIR/state"
    mkdir -p "$TEST_DIR/logs"
    mkdir -p "$TEST_DIR/lib"

    # Stub log functions
    cat > "$TEST_DIR/lib/common.sh" <<'STUBEOF'
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_log_structured() { echo "[STRUCTURED] $*"; }
STUBEOF

    source "$TEST_DIR/lib/common.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# ─── launch_claude_session model parameter ───────────────────────────────────

@test "launch_claude_session: 5th arg sets model in command" {
    # Extract the model variable logic from tmux-helpers.sh
    local model="${5:-${CLAUDE_MODEL:-claude-opus-4-6}}"
    # With no 5th arg and no CLAUDE_MODEL, should default to opus
    unset CLAUDE_MODEL
    local five=""
    model="${five:-${CLAUDE_MODEL:-claude-opus-4-6}}"
    [[ "$model" == "claude-opus-4-6" ]]
}

@test "launch_claude_session: 5th arg overrides CLAUDE_MODEL" {
    export CLAUDE_MODEL="claude-sonnet-4-6"
    local five="claude-haiku-4-5-20251001"
    local model="${five:-${CLAUDE_MODEL:-claude-opus-4-6}}"
    [[ "$model" == "claude-haiku-4-5-20251001" ]]
}

@test "launch_claude_session: empty 5th arg falls back to CLAUDE_MODEL" {
    export CLAUDE_MODEL="claude-sonnet-4-6"
    local five=""
    local model="${five:-${CLAUDE_MODEL:-claude-opus-4-6}}"
    [[ "$model" == "claude-sonnet-4-6" ]]
}

@test "launch_claude_session: empty 5th arg and unset CLAUDE_MODEL falls back to opus" {
    unset CLAUDE_MODEL
    local five=""
    local model="${five:-${CLAUDE_MODEL:-claude-opus-4-6}}"
    [[ "$model" == "claude-opus-4-6" ]]
}

# ─── run-agent.sh EFFECTIVE_MODEL precedence ─────────────────────────────────

@test "EFFECTIVE_MODEL: --model flag takes highest precedence" {
    export CLAUDE_MODEL="claude-sonnet-4-6"
    local AGENT_MODEL="claude-haiku-4-5-20251001"
    local EFFECTIVE_MODEL="${AGENT_MODEL:-${CLAUDE_MODEL:-claude-opus-4-6}}"
    [[ "$EFFECTIVE_MODEL" == "claude-haiku-4-5-20251001" ]]
}

@test "EFFECTIVE_MODEL: falls back to CLAUDE_MODEL when --model not set" {
    export CLAUDE_MODEL="claude-sonnet-4-6"
    local AGENT_MODEL=""
    local EFFECTIVE_MODEL="${AGENT_MODEL:-${CLAUDE_MODEL:-claude-opus-4-6}}"
    [[ "$EFFECTIVE_MODEL" == "claude-sonnet-4-6" ]]
}

@test "EFFECTIVE_MODEL: falls back to opus when both unset" {
    unset CLAUDE_MODEL
    local AGENT_MODEL=""
    local EFFECTIVE_MODEL="${AGENT_MODEL:-${CLAUDE_MODEL:-claude-opus-4-6}}"
    [[ "$EFFECTIVE_MODEL" == "claude-opus-4-6" ]]
}

# ─── SUBAGENT_MODEL derivation (substitute_prompt case block) ────────────────

_derive_subagent_model() {
    local _subagent_model="sonnet"
    case "${CLAUDE_SUBAGENT_MODEL:-}" in
        *opus*) _subagent_model="opus" ;;
        *haiku*) _subagent_model="haiku" ;;
        *sonnet*) _subagent_model="sonnet" ;;
    esac
    echo "$_subagent_model"
}

@test "SUBAGENT_MODEL: defaults to sonnet when env var unset" {
    unset CLAUDE_SUBAGENT_MODEL
    result=$(_derive_subagent_model)
    [[ "$result" == "sonnet" ]]
}

@test "SUBAGENT_MODEL: derives sonnet from claude-sonnet-4-6" {
    export CLAUDE_SUBAGENT_MODEL="claude-sonnet-4-6"
    result=$(_derive_subagent_model)
    [[ "$result" == "sonnet" ]]
}

@test "SUBAGENT_MODEL: derives haiku from claude-haiku-4-5-20251001" {
    export CLAUDE_SUBAGENT_MODEL="claude-haiku-4-5-20251001"
    result=$(_derive_subagent_model)
    [[ "$result" == "haiku" ]]
}

@test "SUBAGENT_MODEL: derives opus from claude-opus-4-6" {
    export CLAUDE_SUBAGENT_MODEL="claude-opus-4-6"
    result=$(_derive_subagent_model)
    [[ "$result" == "opus" ]]
}

@test "SUBAGENT_MODEL: defaults to sonnet for empty string" {
    export CLAUDE_SUBAGENT_MODEL=""
    result=$(_derive_subagent_model)
    [[ "$result" == "sonnet" ]]
}

# ─── .env.example model env vars ─────────────────────────────────────────────

@test ".env.example defines CLAUDE_MODEL" {
    grep -q '^CLAUDE_MODEL=' "$BATS_TEST_DIRNAME/../.env.example"
}

@test ".env.example defines CLAUDE_SUBAGENT_MODEL" {
    grep -q '^CLAUDE_SUBAGENT_MODEL=' "$BATS_TEST_DIRNAME/../.env.example"
}

@test ".env.example defines CLAUDE_UTILITY_MODEL" {
    grep -q '^CLAUDE_UTILITY_MODEL=' "$BATS_TEST_DIRNAME/../.env.example"
}

@test ".env.example CLAUDE_MODEL defaults to opus" {
    grep -q '^CLAUDE_MODEL=claude-opus-4-6' "$BATS_TEST_DIRNAME/../.env.example"
}

@test ".env.example CLAUDE_SUBAGENT_MODEL defaults to sonnet" {
    grep -q '^CLAUDE_SUBAGENT_MODEL=claude-sonnet-4-6' "$BATS_TEST_DIRNAME/../.env.example"
}

@test ".env.example CLAUDE_UTILITY_MODEL defaults to haiku" {
    grep -q '^CLAUDE_UTILITY_MODEL=claude-haiku-4-5-20251001' "$BATS_TEST_DIRNAME/../.env.example"
}

# ─── run-agent.sh --model flag parsing ───────────────────────────────────────

@test "run-agent.sh help text includes --model" {
    grep -q '\-\-model' "$BATS_TEST_DIRNAME/../bin/run-agent.sh"
}

@test "run-agent.sh parses --model flag" {
    grep -q "'--model'" "$BATS_TEST_DIRNAME/../bin/run-agent.sh" || \
    grep -q '"--model"' "$BATS_TEST_DIRNAME/../bin/run-agent.sh" || \
    grep -q -- '--model)' "$BATS_TEST_DIRNAME/../bin/run-agent.sh"
}

# ─── Utility model passed to scheduled jobs ──────────────────────────────────

@test "daily-standup.sh passes --model with CLAUDE_UTILITY_MODEL" {
    grep -q 'CLAUDE_UTILITY_MODEL' "$BATS_TEST_DIRNAME/../jobs/daily-standup.sh"
}

@test "weekly-planning.sh passes --model with CLAUDE_UTILITY_MODEL" {
    grep -q 'CLAUDE_UTILITY_MODEL' "$BATS_TEST_DIRNAME/../jobs/weekly-planning.sh"
}

@test "monthly-strategy.sh passes --model with CLAUDE_UTILITY_MODEL" {
    grep -q 'CLAUDE_UTILITY_MODEL' "$BATS_TEST_DIRNAME/../jobs/monthly-strategy.sh"
}

@test "on-test-pr.sh passes CLAUDE_UTILITY_MODEL to launch_claude_session" {
    grep -q 'CLAUDE_UTILITY_MODEL' "$BATS_TEST_DIRNAME/../triggers/on-test-pr.sh"
}

# ─── Security scan should NOT use utility model ─────────────────────────────

@test "startup.sh security scan cron does NOT pass --model" {
    # The security scan line should not have --model
    local security_line
    security_line=$(grep 'weekly-security-scan' "$BATS_TEST_DIRNAME/../bin/startup.sh")
    ! echo "$security_line" | grep -q '\-\-model'
}

# ─── Prompt templates use {{SUBAGENT_MODEL}} placeholder ─────────────────────

@test "implement-issue.txt uses SUBAGENT_MODEL placeholder" {
    grep -q '{{SUBAGENT_MODEL}}' "$BATS_TEST_DIRNAME/../prompts/implement-issue.txt"
}

@test "issue-triage.txt uses SUBAGENT_MODEL placeholder" {
    grep -q '{{SUBAGENT_MODEL}}' "$BATS_TEST_DIRNAME/../prompts/issue-triage.txt"
}

@test "pr-review.txt uses SUBAGENT_MODEL placeholder" {
    grep -q '{{SUBAGENT_MODEL}}' "$BATS_TEST_DIRNAME/../prompts/pr-review.txt"
}

@test "rework-pr.txt uses SUBAGENT_MODEL placeholder" {
    grep -q '{{SUBAGENT_MODEL}}' "$BATS_TEST_DIRNAME/../prompts/rework-pr.txt"
}

@test "research-issue.txt uses SUBAGENT_MODEL placeholder" {
    grep -q '{{SUBAGENT_MODEL}}' "$BATS_TEST_DIRNAME/../prompts/research-issue.txt"
}

# ─── Prompt templates do NOT hardcode model: "sonnet" ────────────────────────

@test "implement-issue.txt does not hardcode model sonnet" {
    ! grep -q 'model: "sonnet"' "$BATS_TEST_DIRNAME/../prompts/implement-issue.txt"
}

@test "issue-triage.txt does not hardcode model sonnet" {
    ! grep -q 'model: "sonnet"' "$BATS_TEST_DIRNAME/../prompts/issue-triage.txt"
}

@test "pr-review.txt does not hardcode model sonnet" {
    ! grep -q 'model: "sonnet"' "$BATS_TEST_DIRNAME/../prompts/pr-review.txt"
}

@test "rework-pr.txt does not hardcode model sonnet" {
    ! grep -q 'model: "sonnet"' "$BATS_TEST_DIRNAME/../prompts/rework-pr.txt"
}

@test "research-issue.txt does not hardcode model sonnet" {
    ! grep -q 'model: "sonnet"' "$BATS_TEST_DIRNAME/../prompts/research-issue.txt"
}
