#!/usr/bin/env bats
# Tests for tmux-helpers.sh: batch notifications and dynamic timeouts

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

    _pane_health_should_notify "test-pane" "rate_limit"
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
    _pane_health_should_notify "test-pane" "rate_limit"

    # Second call within cooldown should be throttled
    ! _pane_health_should_notify "test-pane" "rate_limit"
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
    _pane_health_should_notify "batch-summary" "test-job"
    [[ -f "$TEST_DIR/state/pane-health-throttle/batch-summary--test-job" ]]
}

# --- Dynamic timeout tests ---

@test "timeout defaults to 30 when env vars are unset" {
    unset TMUX_PERMISSIONS_TIMEOUT
    unset TMUX_READINESS_TIMEOUT

    local perm_timeout=$(( ${TMUX_PERMISSIONS_TIMEOUT:-30} * 1 ))
    local ready_timeout=$(( ${TMUX_READINESS_TIMEOUT:-30} * 1 ))

    [[ $perm_timeout -eq 30 ]]
    [[ $ready_timeout -eq 30 ]]
}

@test "timeout respects TMUX_PERMISSIONS_TIMEOUT override" {
    export TMUX_PERMISSIONS_TIMEOUT=60
    local perm_timeout=$(( ${TMUX_PERMISSIONS_TIMEOUT:-30} * 1 ))
    [[ $perm_timeout -eq 60 ]]
}

@test "timeout respects TMUX_READINESS_TIMEOUT override" {
    export TMUX_READINESS_TIMEOUT=45
    local ready_timeout=$(( ${TMUX_READINESS_TIMEOUT:-30} * 1 ))
    [[ $ready_timeout -eq 45 ]]
}

@test "timeout scales with active windows > 5" {
    local active_windows=15
    local scale_factor=1
    if [[ $active_windows -gt 5 ]]; then
        scale_factor=$(( 1 + active_windows / 10 ))
    fi
    local perm_timeout=$(( 30 * scale_factor ))

    # 15 windows -> scale_factor = 1 + 15/10 = 2
    [[ $scale_factor -eq 2 ]]
    [[ $perm_timeout -eq 60 ]]
}

@test "timeout does not scale with 5 or fewer windows" {
    local active_windows=5
    local scale_factor=1
    if [[ $active_windows -gt 5 ]]; then
        scale_factor=$(( 1 + active_windows / 10 ))
    fi

    [[ $scale_factor -eq 1 ]]
}

@test "timeout scales correctly with 25 windows" {
    local active_windows=25
    local scale_factor=1
    if [[ $active_windows -gt 5 ]]; then
        scale_factor=$(( 1 + active_windows / 10 ))
    fi
    local perm_timeout=$(( 30 * scale_factor ))

    # 25 windows -> scale_factor = 1 + 25/10 = 3
    [[ $scale_factor -eq 3 ]]
    [[ $perm_timeout -eq 90 ]]
}

# --- Permission pattern tests ---
# Load the actual pattern from tmux-helpers.sh for testing

_load_permission_pattern() {
    # Extract the pattern from the real source file
    local src="${BATS_TEST_DIRNAME}/../lib/tmux-helpers.sh"
    PANE_PATTERN_PERMISSION=$(grep '^PANE_PATTERN_PERMISSION=' "$src" | sed 's/^PANE_PATTERN_PERMISSION=//' | tr -d '"')
}

# -- True positives: real Claude CLI permission prompts --

@test "permission pattern matches 'Allow once'" {
    _load_permission_pattern
    echo "  Allow once  " | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern matches 'Allow always'" {
    _load_permission_pattern
    echo "  Allow always  " | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern matches 'Do you want to allow'" {
    _load_permission_pattern
    echo "Do you want to allow this tool to run?" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern matches 'wants to use the Bash tool'" {
    _load_permission_pattern
    echo "Claude wants to use the Bash tool" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern matches 'wants to use the Read tool'" {
    _load_permission_pattern
    echo "Claude wants to use the Read tool" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern matches 'wants to use the Write tool'" {
    _load_permission_pattern
    echo "Claude wants to use the Write tool" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern matches 'approve this action'" {
    _load_permission_pattern
    echo "Do you approve this action?" | grep -qE "$PANE_PATTERN_PERMISSION"
}

# -- False positives: status bar and code review text that must NOT match --

@test "permission pattern does NOT match 'bypass permissions on'" {
    _load_permission_pattern
    ! echo "bypass permissions on" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern does NOT match bare 'Allow'" {
    _load_permission_pattern
    ! echo "Allow" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern does NOT match bare 'Deny'" {
    _load_permission_pattern
    ! echo "Deny" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern does NOT match bare 'permission'" {
    _load_permission_pattern
    ! echo "permission" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern does NOT match 'Do you want to proceed'" {
    _load_permission_pattern
    ! echo "Do you want to proceed?" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern does NOT match IAM Allow/Deny policy text" {
    _load_permission_pattern
    ! echo '{"Effect": "Allow", "Action": "s3:GetObject"}' | grep -qE "$PANE_PATTERN_PERMISSION"
    ! echo '{"Effect": "Deny", "Action": "s3:*"}' | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern does NOT match 'AllowUsers' SSH config" {
    _load_permission_pattern
    ! echo "AllowUsers admin deploy" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern does NOT match 'DenyGroups' SSH config" {
    _load_permission_pattern
    ! echo "DenyGroups nogroup" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern does NOT match status bar with permissions mode" {
    _load_permission_pattern
    ! echo "> claude --dangerously-skip-permissions  bypass permissions on  auto-compact" | grep -qE "$PANE_PATTERN_PERMISSION"
}

@test "permission pattern does NOT match code review mentioning permissions" {
    _load_permission_pattern
    ! echo "This PR updates the file permissions for the deploy script" | grep -qE "$PANE_PATTERN_PERMISSION"
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
    [[ ! -f "$throttle_dir/old-pane--permission" ]]
    [[ -f "$throttle_dir/fresh-pane--rate_limit" ]]
}
