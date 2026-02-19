#!/usr/bin/env bats

# Tests for lib/item-state.sh

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

setup() {
    export AUTOMATION_DIR="$BATS_TEST_TMPDIR/zapat"
    mkdir -p "$AUTOMATION_DIR/state/items"
    mkdir -p "$AUTOMATION_DIR/logs"

    # Minimal common.sh stubs
    export ITEM_STATE_DIR="$AUTOMATION_DIR/state/items"

    # Source common.sh for logging functions, then item-state.sh
    source "$BATS_TEST_DIRNAME/../lib/common.sh"
    source "$BATS_TEST_DIRNAME/../lib/item-state.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/zapat"
}

@test "create_item_state creates valid JSON" {
    run create_item_state "owner/repo" "issue" "42" "pending" "default"
    assert_success

    local state_file="$output"
    [ -f "$state_file" ]

    # Validate JSON structure
    run jq -r '.repo' "$state_file"
    assert_output "owner/repo"

    run jq -r '.type' "$state_file"
    assert_output "issue"

    run jq -r '.number' "$state_file"
    assert_output "42"

    run jq -r '.status' "$state_file"
    assert_output "pending"

    run jq -r '.project' "$state_file"
    assert_output "default"

    run jq -r '.attempts' "$state_file"
    assert_output "0"
}

@test "should_process_item returns 0 for new items" {
    run should_process_item "owner/repo" "issue" "999" "default"
    assert_success
}

@test "should_process_item returns 1 for completed items" {
    create_item_state "owner/repo" "issue" "50" "pending" "default"
    local state_file="$ITEM_STATE_DIR/default--owner-repo_issue_50.json"
    update_item_state "$state_file" "completed"

    run should_process_item "owner/repo" "issue" "50" "default"
    assert_failure
}

@test "should_process_item returns 1 for abandoned items" {
    local state_file
    state_file=$(create_item_state "owner/repo" "issue" "51" "pending" "default")

    # Simulate 3 failed attempts to trigger abandoned status
    update_item_state "$state_file" "running"
    update_item_state "$state_file" "failed" "error 1"
    update_item_state "$state_file" "running"
    update_item_state "$state_file" "failed" "error 2"
    update_item_state "$state_file" "running"
    update_item_state "$state_file" "failed" "error 3"

    # After 3 attempts, should be abandoned
    run jq -r '.status' "$state_file"
    assert_output "abandoned"

    run should_process_item "owner/repo" "issue" "51" "default"
    assert_failure
}

@test "should_process_item respects retry timer" {
    local state_file
    state_file=$(create_item_state "owner/repo" "issue" "52" "pending" "default")

    # Set a future retry time
    local future
    future=$(date -u -v+30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
        date -u -d "+30 minutes" '+%Y-%m-%dT%H:%M:%SZ')
    jq --arg t "$future" '.next_retry_after = $t' "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"

    run should_process_item "owner/repo" "issue" "52" "default"
    assert_failure
}

@test "update_item_state to failed sets next_retry_after" {
    local state_file
    state_file=$(create_item_state "owner/repo" "issue" "53" "pending" "default")

    update_item_state "$state_file" "running"
    update_item_state "$state_file" "failed" "something broke"

    run jq -r '.status' "$state_file"
    assert_output "failed"

    run jq -r '.last_error' "$state_file"
    assert_output "something broke"

    run jq -r '.next_retry_after' "$state_file"
    refute_output "null"
}

@test "update_item_state to capacity_rejected sets 5-min retry" {
    local state_file
    state_file=$(create_item_state "owner/repo" "issue" "54" "pending" "default")

    update_item_state "$state_file" "running"
    update_item_state "$state_file" "capacity_rejected"

    # Status should go back to pending
    run jq -r '.status' "$state_file"
    assert_output "pending"

    # Should have a retry timer set
    run jq -r '.next_retry_after' "$state_file"
    refute_output "null"
}

@test "update_item_state to completed clears retry info" {
    local state_file
    state_file=$(create_item_state "owner/repo" "issue" "55" "pending" "default")

    update_item_state "$state_file" "running"
    update_item_state "$state_file" "failed" "temp error"

    # Verify retry info exists
    run jq -r '.next_retry_after' "$state_file"
    refute_output "null"

    update_item_state "$state_file" "completed"

    run jq -r '.status' "$state_file"
    assert_output "completed"

    run jq -r '.next_retry_after' "$state_file"
    assert_output "null"

    run jq -r '.last_error' "$state_file"
    assert_output "null"
}
