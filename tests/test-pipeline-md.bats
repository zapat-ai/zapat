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
