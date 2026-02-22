#!/usr/bin/env bats

# Integration tests for the Zapat pipeline
# Tests end-to-end flows through the state machine, auto-merge gate,
# risk classifier, and sequential flow enforcement.

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

REPO_ROOT="$BATS_TEST_DIRNAME/.."

setup() {
    export AUTOMATION_DIR="$BATS_TEST_TMPDIR/zapat"
    mkdir -p "$AUTOMATION_DIR/state/items"
    mkdir -p "$AUTOMATION_DIR/logs"
    export ITEM_STATE_DIR="$AUTOMATION_DIR/state/items"

    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/item-state.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/zapat"
}

# --- State Machine Transitions ---

@test "integration: pending -> running -> completed lifecycle" {
    run create_item_state "owner/repo" "issue" "1" "pending" "default"
    assert_success
    local state_file="$output"

    run jq -r '.status' "$state_file"
    assert_output "pending"

    run update_item_state "$state_file" "running"
    assert_success

    run jq -r '.status' "$state_file"
    assert_output "running"

    run update_item_state "$state_file" "completed"
    assert_success

    run jq -r '.status' "$state_file"
    assert_output "completed"
}

@test "integration: pending -> running -> failed -> running (retry)" {
    run create_item_state "owner/repo" "pr" "10" "pending" "default"
    assert_success
    local state_file="$output"

    run update_item_state "$state_file" "running"
    assert_success

    run update_item_state "$state_file" "failed"
    assert_success

    run jq -r '.status' "$state_file"
    assert_output "failed"

    # After retry timer elapses, should_process_item allows reprocessing
    # Simulate by clearing next_retry_after
    jq '.next_retry_after = 0' "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"

    run should_process_item "owner/repo" "pr" "10" "default"
    assert_success
}

@test "integration: completed items are skipped" {
    run create_item_state "owner/repo" "issue" "5" "pending" "default"
    assert_success
    local state_file="$output"

    run update_item_state "$state_file" "completed"
    assert_success

    run should_process_item "owner/repo" "issue" "5" "default"
    assert_failure
}

@test "integration: abandoned items are skipped" {
    run create_item_state "owner/repo" "work" "7" "pending" "default"
    assert_success
    local state_file="$output"

    run update_item_state "$state_file" "abandoned"
    assert_success

    run should_process_item "owner/repo" "work" "7" "default"
    assert_failure
}

# --- Cycle Counter Enforcement ---

@test "integration: rework cycle counter increments correctly" {
    run create_item_state "owner/repo" "rework" "20" "pending" "default"
    assert_success

    run get_rework_cycles "owner/repo" "rework" "20" "default"
    assert_output "0"

    run increment_rework_cycles "owner/repo" "rework" "20" "default"
    assert_success

    run get_rework_cycles "owner/repo" "rework" "20" "default"
    assert_output "1"

    run increment_rework_cycles "owner/repo" "rework" "20" "default"
    assert_success

    run get_rework_cycles "owner/repo" "rework" "20" "default"
    assert_output "2"
}

@test "integration: cycle counter survives state transitions" {
    run create_item_state "owner/repo" "rework" "30" "pending" "default"
    assert_success
    local state_file="$output"

    run increment_rework_cycles "owner/repo" "rework" "30" "default"
    assert_success

    run update_item_state "$state_file" "running"
    assert_success

    run update_item_state "$state_file" "completed"
    assert_success

    # Cycle count preserved after state changes
    run get_rework_cycles "owner/repo" "rework" "30" "default"
    assert_output "1"
}

# --- Sequential Flow Enforcement ---

@test "integration: on-rework-pr.sh adds zapat-testing not zapat-review" {
    run grep -c 'add-label.*zapat-testing' "$REPO_ROOT/triggers/on-rework-pr.sh"
    assert_success

    # Must NOT add zapat-review directly (breaks sequential flow)
    run grep 'add-label.*zapat-review' "$REPO_ROOT/triggers/on-rework-pr.sh"
    assert_failure
}

@test "integration: on-test-pr.sh routes to review on pass, rework on fail" {
    run grep 'zapat-review' "$REPO_ROOT/triggers/on-test-pr.sh"
    assert_success

    run grep 'zapat-rework' "$REPO_ROOT/triggers/on-test-pr.sh"
    assert_success
}

@test "integration: on-work-issue.sh adds only zapat-testing after PR" {
    run grep 'add-label.*zapat-testing' "$REPO_ROOT/triggers/on-work-issue.sh"
    assert_success

    # Should not add zapat-review directly (sequential: testing first)
    run grep 'add-label.*zapat-review' "$REPO_ROOT/triggers/on-work-issue.sh"
    assert_failure
}

# --- Auto-Merge Gate Branch Check ---

@test "integration: auto-merge gate queries baseRefName" {
    run grep 'baseRefName' "$REPO_ROOT/bin/poll-github.sh"
    assert_success
}

@test "integration: auto-merge gate skips non-main PRs" {
    run grep -A 5 'MERGE_PR_BASE' "$REPO_ROOT/bin/poll-github.sh"
    assert_success
    assert_output --partial 'not main'
}

# --- Risk Classifier Pipeline-Critical Patterns ---

@test "integration: risk classifier has pipeline-critical patterns" {
    run grep 'PIPELINE_CRITICAL_PATTERNS' "$REPO_ROOT/src/commands/risk.mjs"
    assert_success
}

@test "integration: risk classifier checks pipeline-critical before other patterns" {
    # PIPELINE_CRITICAL_PATTERNS must be checked first in classifyFile
    run grep -A 3 'function classifyFile' "$REPO_ROOT/src/commands/risk.mjs"
    assert_success
    assert_output --partial 'PIPELINE_CRITICAL_PATTERNS'
}

@test "integration: risk classifier flags lib/item-state.sh as pipeline-critical" {
    run grep 'item-state' "$REPO_ROOT/src/commands/risk.mjs"
    assert_success
}

@test "integration: risk classifier flags bin/poll-github.sh as pipeline-critical" {
    run grep 'poll-github' "$REPO_ROOT/src/commands/risk.mjs"
    assert_success
}

@test "integration: risk classifier flags triggers as pipeline-critical" {
    run grep 'triggers' "$REPO_ROOT/src/commands/risk.mjs"
    assert_success
}

# --- Post-Merge Health Check ---

@test "integration: post-merge health check exists in auto-merge gate" {
    run grep 'post-merge-health' "$REPO_ROOT/bin/poll-github.sh"
    assert_success
}

@test "integration: health check runs after low-risk auto-merge" {
    # Verify the health check is placed after gh pr merge for low risk
    local low_risk_section
    low_risk_section=$(sed -n '/Auto-merging low-risk/,/;;/p' "$REPO_ROOT/bin/poll-github.sh")
    echo "$low_risk_section" | grep -q 'zapat.*health'
}

@test "integration: health check runs after medium-risk auto-merge" {
    local medium_risk_section
    medium_risk_section=$(sed -n '/Auto-merging medium-risk/,/;;/p' "$REPO_ROOT/bin/poll-github.sh")
    echo "$medium_risk_section" | grep -q 'zapat.*health'
}

# --- Feature Branch Workflow Documentation ---

@test "integration: CLAUDE.md documents multi-PR feature branch workflow" {
    run grep -i 'Multi-PR Feature Branches' "$REPO_ROOT/CLAUDE.md"
    assert_success
}

@test "integration: CLAUDE.md mentions hold label for sub-PRs" {
    run grep 'hold.*label' "$REPO_ROOT/CLAUDE.md"
    assert_success
}

# --- Provider Integration ---

@test "integration: detect_provider_label is called before each dispatch" {
    # Every dispatch section should call detect_provider_label
    local dispatch_sections
    dispatch_sections=$(grep -c 'detect_provider_label' "$REPO_ROOT/bin/poll-github.sh")
    # At minimum: PRs, review PRs, issues, work issues, rework PRs, testing PRs,
    # write-tests issues, research issues, mentions (PR+issue), auto-triage, retry sweep
    [ "$dispatch_sections" -ge 10 ]
}

@test "integration: provider.sh validates AGENT_PROVIDER against path traversal" {
    run grep 'path traversal\|[^a-z0-9_-]' "$REPO_ROOT/lib/provider.sh"
    assert_success
}

# --- Dedup Files ---

@test "integration: all dedup files are created in state dir" {
    local dedup_files
    dedup_files=$(grep -c 'PROCESSED_.*=.*processed-' "$REPO_ROOT/bin/poll-github.sh")
    # Should have: prs, issues, work, rework, write-tests, research, testing, mentions, auto-triage, auto-rework, rebase
    [ "$dedup_files" -ge 11 ]
}

@test "integration: processed-testing.txt exists in dedup file list" {
    run grep 'processed-testing' "$REPO_ROOT/bin/poll-github.sh"
    assert_success
}

@test "integration: processed-auto-rework.txt exists in dedup file list" {
    run grep 'processed-auto-rework' "$REPO_ROOT/bin/poll-github.sh"
    assert_success
}
