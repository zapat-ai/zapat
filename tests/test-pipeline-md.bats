#!/usr/bin/env bats

# Tests for CLAUDE-pipeline.md slim context file

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

REPO_ROOT="$BATS_TEST_DIRNAME/.."

# --- File existence ---

@test "CLAUDE-pipeline.md exists at repo root" {
    [ -f "$REPO_ROOT/CLAUDE-pipeline.md" ]
}

@test "CLAUDE-pipeline.md is under 450 words (~600 tokens)" {
    word_count=$(wc -w < "$REPO_ROOT/CLAUDE-pipeline.md")
    [ "$word_count" -le 450 ]
}

@test "original CLAUDE.md is unchanged from git" {
    cd "$REPO_ROOT"
    run git diff --exit-code CLAUDE.md
    assert_success
}

# --- Trigger script cp commands ---

@test "on-new-issue.sh copies CLAUDE-pipeline.md into worktree" {
    run grep -F 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-new-issue.sh"
    assert_success
    assert_output --partial 'cp'
}

@test "on-work-issue.sh copies CLAUDE-pipeline.md into worktree" {
    run grep -F 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-work-issue.sh"
    assert_success
    assert_output --partial 'cp'
}

@test "on-new-pr.sh copies CLAUDE-pipeline.md into worktree" {
    run grep -F 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-new-pr.sh"
    assert_success
    assert_output --partial 'cp'
}

@test "on-rework-pr.sh copies CLAUDE-pipeline.md into worktree" {
    run grep -F 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-rework-pr.sh"
    assert_success
    assert_output --partial 'cp'
}

@test "on-research-issue.sh copies CLAUDE-pipeline.md into worktree" {
    run grep -F 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-research-issue.sh"
    assert_success
    assert_output --partial 'cp'
}

@test "on-write-tests.sh copies CLAUDE-pipeline.md into worktree" {
    run grep -F 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-write-tests.sh"
    assert_success
    assert_output --partial 'cp'
}

@test "on-test-pr.sh copies CLAUDE-pipeline.md into worktree" {
    run grep -F 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-test-pr.sh"
    assert_success
    assert_output --partial 'cp'
}

# --- Sequential flow tests ---

@test "on-rework-pr.sh does NOT add zapat-review label (sequential flow)" {
    # After rework, only zapat-testing should be added; review comes after test passes
    run grep -F 'add-label "zapat-review"' "$REPO_ROOT/triggers/on-rework-pr.sh"
    assert_failure
}

@test "on-rework-pr.sh adds only zapat-testing label after rework" {
    run grep -F 'add-label "zapat-testing"' "$REPO_ROOT/triggers/on-rework-pr.sh"
    assert_success
}

@test "on-test-pr.sh does NOT re-add zapat-testing at entry" {
    # The test trigger should not add zapat-testing at the start (it's already labeled)
    # Only the label update section at the end should reference labels
    run grep -c 'add-label "zapat-testing"' "$REPO_ROOT/triggers/on-test-pr.sh"
    assert_output "0"
}

@test "on-test-pr.sh adds zapat-review on test pass" {
    run grep -F 'add-label "zapat-review"' "$REPO_ROOT/triggers/on-test-pr.sh"
    assert_success
}

@test "on-test-pr.sh adds zapat-rework on test failure" {
    run grep -F 'add-label "zapat-rework"' "$REPO_ROOT/triggers/on-test-pr.sh"
    assert_success
}

@test "on-work-issue.sh adds only zapat-testing (not zapat-review) after PR creation" {
    # Should add zapat-testing but NOT zapat-review
    run grep -F 'add-label "zapat-review"' "$REPO_ROOT/triggers/on-work-issue.sh"
    assert_failure
    run grep -F 'add-label "zapat-testing"' "$REPO_ROOT/triggers/on-work-issue.sh"
    assert_success
}

@test "on-rework-pr.sh has cycle counter check" {
    run grep -F 'MAX_REWORK_CYCLES' "$REPO_ROOT/triggers/on-rework-pr.sh"
    assert_success
}

@test "on-rework-pr.sh adds hold label on cycle limit" {
    run grep -F 'add-label "hold"' "$REPO_ROOT/triggers/on-rework-pr.sh"
    assert_success
}
