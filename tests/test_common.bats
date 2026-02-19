#!/usr/bin/env bats

# Tests for lib/common.sh (slots, locks)

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

setup() {
    export AUTOMATION_DIR="$BATS_TEST_TMPDIR/zapat"
    mkdir -p "$AUTOMATION_DIR/state"
    mkdir -p "$AUTOMATION_DIR/logs"

    source "$BATS_TEST_DIRNAME/../lib/common.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/zapat"
}

# --- Slot Tests ---

@test "acquire_slot succeeds under limit" {
    local slot_dir="$AUTOMATION_DIR/state/test-slots"
    run acquire_slot "$slot_dir" 5
    assert_success

    # Slot file should exist
    [ -f "$slot_dir/slot-$$.pid" ]
}

@test "acquire_slot fails at capacity" {
    local slot_dir="$AUTOMATION_DIR/state/test-slots"
    mkdir -p "$slot_dir"

    # Create fake slot files with active PIDs (use our own PID to simulate active)
    for i in 1 2 3; do
        echo $$ > "$slot_dir/slot-fake${i}.pid"
    done

    run acquire_slot "$slot_dir" 3
    assert_failure
}

@test "acquire_slot cleans stale slots" {
    local slot_dir="$AUTOMATION_DIR/state/test-slots"
    mkdir -p "$slot_dir"

    # Create slot files with a PID that definitely doesn't exist
    echo "99999999" > "$slot_dir/slot-99999999.pid"

    # Should succeed because the stale slot gets cleaned up
    run acquire_slot "$slot_dir" 1
    assert_success

    # Stale slot should be gone
    [ ! -f "$slot_dir/slot-99999999.pid" ]
}

@test "release_slot removes file" {
    local slot_dir="$AUTOMATION_DIR/state/test-slots"
    mkdir -p "$slot_dir"

    local slot_file="$slot_dir/slot-$$.pid"
    echo $$ > "$slot_file"
    [ -f "$slot_file" ]

    release_slot "$slot_file"
    [ ! -f "$slot_file" ]
}

# --- Lock Tests ---

@test "acquire_lock works with mkdir" {
    local lock_file="$AUTOMATION_DIR/state/test.lock"

    run acquire_lock "$lock_file"
    assert_success

    # Lock directory should exist
    [ -d "${lock_file}.d" ]
    # PID file should contain our PID
    [ "$(cat "${lock_file}.d/pid")" = "$$" ]

    # Clean up
    release_lock "$lock_file"
}

@test "acquire_lock detects stale locks" {
    local lock_file="$AUTOMATION_DIR/state/test-stale.lock"
    mkdir -p "${lock_file}.d"
    echo "99999999" > "${lock_file}.d/pid"

    # Should succeed after detecting and cleaning up stale lock
    run acquire_lock "$lock_file"
    assert_success

    # Clean up
    release_lock "$lock_file"
}
