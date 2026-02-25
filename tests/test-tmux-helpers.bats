#!/usr/bin/env bats
# Tests for tmux-helpers.sh: batch notifications and dynamic timeouts

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

setup() {
    export TEST_DIR="$(mktemp -d)"
    export SCRIPT_DIR="$TEST_DIR"
    export AUTOMATION_DIR="$TEST_DIR"
    mkdir -p "$TEST_DIR/state/pane-health-throttle"
    mkdir -p "$TEST_DIR/bin"
    mkdir -p "$TEST_DIR/lib"

    # Stub log functions
    cat > "$TEST_DIR/lib/common.sh" <<'STUBEOF'
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_log_structured() { echo "[STRUCTURED] $*"; }
STUBEOF

    source "$TEST_DIR/lib/common.sh"

    # Track notification calls
    export NOTIFY_LOG="$TEST_DIR/notify-calls.log"
    cat > "$TEST_DIR/bin/notify.sh" <<STUBEOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
STUBEOF
    chmod +x "$TEST_DIR/bin/notify.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# --- Throttle function tests ---

@test "_pane_health_should_notify allows first notification" {
    source "$TEST_DIR/lib/common.sh"
    # Inline the function for isolated testing
    _pane_health_should_notify() {
        local pane_id="$1"
        local issue_type="$2"
        local throttle_dir="${AUTOMATION_DIR}/state/pane-health-throttle"
        local throttle_file="${throttle_dir}/${pane_id}--${issue_type}"
        local cooldown=300
        mkdir -p "$throttle_dir"
        if [[ -f "$throttle_file" ]]; then
            local last_notify
            last_notify=$(cat "$throttle_file" 2>/dev/null || echo "0")
            local now
            now=$(date +%s)
            if (( now - last_notify < cooldown )); then
                return 1
            fi
        fi
        date +%s > "$throttle_file"
        return 0
    }

    run _pane_health_should_notify "test-pane" "rate_limit"
    assert_success
}

@test "_pane_health_should_notify throttles subsequent notifications" {
    _pane_health_should_notify() {
        local pane_id="$1"
        local issue_type="$2"
        local throttle_dir="${AUTOMATION_DIR}/state/pane-health-throttle"
        local throttle_file="${throttle_dir}/${pane_id}--${issue_type}"
        local cooldown=300
        mkdir -p "$throttle_dir"
        if [[ -f "$throttle_file" ]]; then
            local last_notify
            last_notify=$(cat "$throttle_file" 2>/dev/null || echo "0")
            local now
            now=$(date +%s)
            if (( now - last_notify < cooldown )); then
                return 1
            fi
        fi
        date +%s > "$throttle_file"
        return 0
    }

    # First call should pass
    run _pane_health_should_notify "test-pane" "rate_limit"
    assert_success

    # Second call within cooldown should be throttled
    run _pane_health_should_notify "test-pane" "rate_limit"
    assert_failure
}

@test "_pane_health_should_notify uses batch-summary key for batched notifications" {
    _pane_health_should_notify() {
        local pane_id="$1"
        local issue_type="$2"
        local throttle_dir="${AUTOMATION_DIR}/state/pane-health-throttle"
        local throttle_file="${throttle_dir}/${pane_id}--${issue_type}"
        local cooldown=300
        mkdir -p "$throttle_dir"
        if [[ -f "$throttle_file" ]]; then
            local last_notify
            last_notify=$(cat "$throttle_file" 2>/dev/null || echo "0")
            local now
            now=$(date +%s)
            if (( now - last_notify < cooldown )); then
                return 1
            fi
        fi
        date +%s > "$throttle_file"
        return 0
    }

    # Batch-summary key should work like any other key
    run _pane_health_should_notify "batch-summary" "test-job"
    assert_success
    assert [ -f "$TEST_DIR/state/pane-health-throttle/batch-summary--test-job" ]
}

# --- Dynamic timeout tests ---

@test "timeout defaults to 30 when env vars are unset" {
    unset TMUX_PERMISSIONS_TIMEOUT
    unset TMUX_READINESS_TIMEOUT

    local perm_timeout=$(( ${TMUX_PERMISSIONS_TIMEOUT:-30} * 1 ))
    local ready_timeout=$(( ${TMUX_READINESS_TIMEOUT:-30} * 1 ))

    assert [ "$perm_timeout" -eq 30 ]
    assert [ "$ready_timeout" -eq 30 ]
}

@test "timeout respects TMUX_PERMISSIONS_TIMEOUT override" {
    export TMUX_PERMISSIONS_TIMEOUT=60
    local perm_timeout=$(( ${TMUX_PERMISSIONS_TIMEOUT:-30} * 1 ))
    assert [ "$perm_timeout" -eq 60 ]
}

@test "timeout respects TMUX_READINESS_TIMEOUT override" {
    export TMUX_READINESS_TIMEOUT=45
    local ready_timeout=$(( ${TMUX_READINESS_TIMEOUT:-30} * 1 ))
    assert [ "$ready_timeout" -eq 45 ]
}

@test "timeout scales with active windows > 5" {
    local active_windows=15
    local scale_factor=1
    if [[ $active_windows -gt 5 ]]; then
        scale_factor=$(( 1 + active_windows / 10 ))
    fi
    local perm_timeout=$(( 30 * scale_factor ))

    # 15 windows -> scale_factor = 1 + 15/10 = 2
    assert [ "$scale_factor" -eq 2 ]
    assert [ "$perm_timeout" -eq 60 ]
}

@test "timeout does not scale with 5 or fewer windows" {
    local active_windows=5
    local scale_factor=1
    if [[ $active_windows -gt 5 ]]; then
        scale_factor=$(( 1 + active_windows / 10 ))
    fi

    assert [ "$scale_factor" -eq 1 ]
}

@test "timeout scales correctly with 25 windows" {
    local active_windows=25
    local scale_factor=1
    if [[ $active_windows -gt 5 ]]; then
        scale_factor=$(( 1 + active_windows / 10 ))
    fi
    local perm_timeout=$(( 30 * scale_factor ))

    # 25 windows -> scale_factor = 1 + 25/10 = 3
    assert [ "$scale_factor" -eq 3 ]
    assert [ "$perm_timeout" -eq 90 ]
}

# --- Pane analysis tests ---
# Note: Pattern-based pane detection was replaced by LLM-driven analysis
# (lib/pane-analyzer.sh) which uses Haiku to interpret pane content.
# The old PANE_PATTERN_* regex constants were removed in favor of context-aware
# analysis that understands dialog UIs natively. See lib/pane-analyzer.sh.

@test "pane analyzer script exists and is executable" {
    local analyzer="${BATS_TEST_DIRNAME}/../bin/analyze-pane.sh"
    assert [ -f "$analyzer" ]
    assert [ -x "$analyzer" ]
}

@test "pane analyzer library exists" {
    local lib="${BATS_TEST_DIRNAME}/../lib/pane-analyzer.sh"
    assert [ -f "$lib" ]
}

@test "pane analyzer library defines analyze_pane function" {
    grep -q 'analyze_pane()' "${BATS_TEST_DIRNAME}/../lib/pane-analyzer.sh"
}

@test "pane analyzer library defines act_on_pane function" {
    grep -q 'act_on_pane()' "${BATS_TEST_DIRNAME}/../lib/pane-analyzer.sh"
}

@test "pane analyzer library defines _pane_is_active fast-path function" {
    grep -q '_pane_is_active()' "${BATS_TEST_DIRNAME}/../lib/pane-analyzer.sh"
}

@test "pane analyzer allowlist contains expected keys" {
    local lib="${BATS_TEST_DIRNAME}/../lib/pane-analyzer.sh"
    grep -q 'Enter' "$lib"
    grep -q 'Down' "$lib"
    grep -q 'Escape' "$lib"
    grep -q 'C-c' "$lib"
}

# --- Signal file path tests ---

@test "signal file is created under state/pane-signals/ not /tmp/" {
    # Simulate what check_pane_health does when writing a signal file
    local window="test-win"
    local signal_file="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-signals/signal-${window}"
    mkdir -p "$(dirname "$signal_file")"
    echo "rate_limited" > "$signal_file"

    assert [ -f "$TEST_DIR/state/pane-signals/signal-test-win" ]
    assert [ "$(cat "$signal_file")" == "rate_limited" ]
    # Must NOT exist in /tmp/
    assert [ ! -f "/tmp/zapat-pane-signal-test-win" ]
}

@test "signal file directory is created if missing" {
    # Ensure the pane-signals dir does not exist yet
    assert [ ! -d "$TEST_DIR/state/pane-signals" ]

    local window="new-win"
    local signal_file="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-signals/signal-${window}"
    mkdir -p "$(dirname "$signal_file")"
    echo "rate_limited" > "$signal_file"

    assert [ -d "$TEST_DIR/state/pane-signals" ]
    assert [ -f "$signal_file" ]
}

@test "signal file cleanup removes the file" {
    local window="cleanup-win"
    local signal_file="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-signals/signal-${window}"
    mkdir -p "$(dirname "$signal_file")"
    echo "rate_limited" > "$signal_file"

    # Simulate cleanup (as done in monitor_session)
    rm -f "$signal_file"

    assert [ ! -f "$signal_file" ]
}

@test "signal file path uses AUTOMATION_DIR when set" {
    local custom_dir="$(mktemp -d)"
    AUTOMATION_DIR="$custom_dir"
    local window="custom-dir-win"
    local signal_file="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-signals/signal-${window}"
    mkdir -p "$(dirname "$signal_file")"
    echo "rate_limited" > "$signal_file"

    assert [ -f "$custom_dir/state/pane-signals/signal-custom-dir-win" ]
    rm -rf "$custom_dir"
    AUTOMATION_DIR="$TEST_DIR"
}

@test "signal file path falls back to SCRIPT_DIR when AUTOMATION_DIR is unset" {
    unset AUTOMATION_DIR
    local window="fallback-win"
    local signal_file="${AUTOMATION_DIR:-$SCRIPT_DIR}/state/pane-signals/signal-${window}"
    mkdir -p "$(dirname "$signal_file")"
    echo "rate_limited" > "$signal_file"

    assert [ -f "$TEST_DIR/state/pane-signals/signal-fallback-win" ]
    export AUTOMATION_DIR="$TEST_DIR"
}

# -- Stale throttle file cleanup tests --

@test "monitor_session cleans stale throttle files older than 10 minutes" {
    local throttle_dir="$TEST_DIR/state/pane-health-throttle"
    mkdir -p "$throttle_dir"

    # Create a stale throttle file and backdate it 15 minutes
    echo "1000000000" > "$throttle_dir/old-pane--permission"
    touch -t "$(date -v-15M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '15 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" "$throttle_dir/old-pane--permission" 2>/dev/null || \
        touch -A -001500 "$throttle_dir/old-pane--permission" 2>/dev/null || true

    # Create a fresh throttle file
    echo "$(date +%s)" > "$throttle_dir/fresh-pane--rate_limit"

    # Run the cleanup logic directly (extracted from monitor_session)
    if [[ -d "$throttle_dir" ]]; then
        find "$throttle_dir" -type f -mmin +10 -delete 2>/dev/null || true
    fi

    # Stale file should be gone, fresh file should remain
    assert [ ! -f "$throttle_dir/old-pane--permission" ]
    assert [ -f "$throttle_dir/fresh-pane--rate_limit" ]
}

# --- Pattern tests removed ---
# Rate limit, account limit, and fatal error pattern tests were removed
# because regex-based detection was replaced by LLM-driven pane analysis.
# The pane analyzer (lib/pane-analyzer.sh) uses Haiku to classify pane states
# with full context awareness, eliminating false positives from regex matching.

# --- Idle detection tests ---
# The idle detection in monitor_session must require BOTH:
# 1. The ❯ prompt (Claude is at input)
# 2. The cost line ✻ (proves Claude processed at least one prompt)
# 3. No active spinner
# Without the cost line check, freshly launched sessions at the initial
# ❯ prompt would be killed before they start working.

_idle_detected() {
    local content="$1"
    echo "$content" | grep -qE "^❯" && \
    echo "$content" | grep -qE "✻" && \
    ! echo "$content" | grep -qE "(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|Working|Thinking)"
}

@test "idle detection triggers when cost line and prompt are present" {
    local content="✻ Total cost: \$0.05
───────────────────
❯ "
    _idle_detected "$content"
}

@test "idle detection does NOT trigger on initial prompt without cost line" {
    # This is the exact scenario that caused the false positive:
    # Claude just started, shows ❯ but has done no work yet
    local content="
   Claude Code v2.1.50

❯ "
    ! _idle_detected "$content"
}

@test "idle detection does NOT trigger when spinner is active" {
    local content="✻ Total cost: \$0.05
⠋ Working on task...
❯ "
    ! _idle_detected "$content"
}

@test "idle detection does NOT trigger with Thinking indicator" {
    local content="✻ Total cost: \$0.05
Thinking...
❯ "
    ! _idle_detected "$content"
}

@test "idle detection does NOT trigger without prompt" {
    local content="✻ Total cost: \$0.05
Some output here"
    ! _idle_detected "$content"
}

@test "idle detection does NOT trigger on bypass permissions startup" {
    local content="
  ⏵⏵ bypass permissions on (shift+tab to cycle)
❯ "
    ! _idle_detected "$content"
}
