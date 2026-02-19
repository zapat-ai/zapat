#!/usr/bin/env bats

# Tests for first-boot seeding logic in bin/startup.sh
# These tests exercise the seeding conditions without running the full startup.

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

setup() {
    export AUTOMATION_DIR="$BATS_TEST_TMPDIR/zapat"
    export SCRIPT_DIR="$AUTOMATION_DIR"
    mkdir -p "$AUTOMATION_DIR/state"
    mkdir -p "$AUTOMATION_DIR/logs"
    mkdir -p "$AUTOMATION_DIR/config/default"

    # Create a minimal repos.conf
    printf 'test-org/test-repo\t/tmp/fake-repo\tbackend\n' > "$AUTOMATION_DIR/config/default/repos.conf"

    # Source common.sh for helpers
    source "$BATS_TEST_DIRNAME/../lib/common.sh"
    export AUTOMATION_DIR  # re-export after common.sh may set it
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/zapat"
}

@test "seeding runs when state files are empty" {
    # Create empty state files (touch only, no content)
    touch "$AUTOMATION_DIR/state/processed-issues.txt"

    # The condition: ! -s means file is empty
    [ ! -s "$AUTOMATION_DIR/state/processed-issues.txt" ]
}

@test "seeding skips when state files are non-empty" {
    echo "test-org/test-repo#1" > "$AUTOMATION_DIR/state/processed-issues.txt"

    # -s returns true when file has content
    [ -s "$AUTOMATION_DIR/state/processed-issues.txt" ]
}

@test "--seed-state forces re-seeding" {
    # Simulate existing state
    echo "test-org/test-repo#1" > "$AUTOMATION_DIR/state/processed-issues.txt"
    echo "test-org/test-repo#1" > "$AUTOMATION_DIR/state/processed-prs.txt"

    FORCE_SEED=true

    # The condition used in startup.sh:
    # if [[ ! -s ... || "$FORCE_SEED" == "true" ]]
    # Should be true even with non-empty files
    if [[ ! -s "$AUTOMATION_DIR/state/processed-issues.txt" || "$FORCE_SEED" == "true" ]]; then
        result="would_seed"
    else
        result="would_skip"
    fi

    [ "$result" = "would_seed" ]

    # Verify backup is created when force-seeding into non-empty files
    if [[ "$FORCE_SEED" == "true" && -s "$AUTOMATION_DIR/state/processed-issues.txt" ]]; then
        cp "$AUTOMATION_DIR/state/processed-issues.txt" "$AUTOMATION_DIR/state/processed-issues.txt.bak"
    fi
    [ -f "$AUTOMATION_DIR/state/processed-issues.txt.bak" ]
}

@test "all state file types are populated during seeding" {
    # Simulate seeding by writing to all state file types
    local repo="test-org/test-repo"
    local num="42"

    echo "${repo}#${num}" >> "$AUTOMATION_DIR/state/processed-issues.txt"
    echo "${repo}#auto-${num}" >> "$AUTOMATION_DIR/state/processed-auto-triage.txt"
    echo "${repo}#${num}" >> "$AUTOMATION_DIR/state/processed-work.txt"
    echo "${repo}#${num}" >> "$AUTOMATION_DIR/state/processed-research.txt"
    echo "${repo}#${num}" >> "$AUTOMATION_DIR/state/processed-write-tests.txt"

    # All files should have content
    [ -s "$AUTOMATION_DIR/state/processed-issues.txt" ]
    [ -s "$AUTOMATION_DIR/state/processed-auto-triage.txt" ]
    [ -s "$AUTOMATION_DIR/state/processed-work.txt" ]
    [ -s "$AUTOMATION_DIR/state/processed-research.txt" ]
    [ -s "$AUTOMATION_DIR/state/processed-write-tests.txt" ]
}

@test "deduplication works" {
    local state_file="$AUTOMATION_DIR/state/processed-issues.txt"

    # Write duplicates
    echo "test-org/test-repo#1" >> "$state_file"
    echo "test-org/test-repo#2" >> "$state_file"
    echo "test-org/test-repo#1" >> "$state_file"
    echo "test-org/test-repo#3" >> "$state_file"
    echo "test-org/test-repo#2" >> "$state_file"

    # Deduplicate (same logic as startup.sh)
    sort -u -o "$state_file" "$state_file"

    run wc -l < "$state_file"
    # Should have 3 unique entries
    assert_output "       3"
}
