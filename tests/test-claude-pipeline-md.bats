#!/usr/bin/env bats
# Tests for CLAUDE-pipeline.md slim context and trigger script swap logic

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "CLAUDE-pipeline.md exists at repo root" {
    [[ -f "$REPO_ROOT/CLAUDE-pipeline.md" ]]
}

@test "CLAUDE-pipeline.md is under 600 tokens (approx 450 words)" {
    word_count=$(wc -w < "$REPO_ROOT/CLAUDE-pipeline.md")
    echo "Word count: $word_count (limit: 450)" >&2
    [[ $word_count -le 450 ]]
}

@test "CLAUDE.md still exists and is unchanged" {
    [[ -f "$REPO_ROOT/CLAUDE.md" ]]
    # Verify it's the full version (much larger than the slim one)
    full_words=$(wc -w < "$REPO_ROOT/CLAUDE.md")
    slim_words=$(wc -w < "$REPO_ROOT/CLAUDE-pipeline.md")
    echo "Full CLAUDE.md: $full_words words, Slim: $slim_words words" >&2
    [[ $full_words -gt $slim_words ]]
}

@test "on-work-issue.sh contains CLAUDE-pipeline.md copy command" {
    grep -q 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-work-issue.sh"
}

@test "on-rework-pr.sh contains CLAUDE-pipeline.md copy command" {
    grep -q 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-rework-pr.sh"
}

@test "on-write-tests.sh contains CLAUDE-pipeline.md copy command" {
    grep -q 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-write-tests.sh"
}

@test "on-test-pr.sh contains CLAUDE-pipeline.md copy command" {
    grep -q 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-test-pr.sh"
}

@test "on-new-issue.sh contains CLAUDE-pipeline.md copy command" {
    grep -q 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-new-issue.sh"
}

@test "on-new-pr.sh contains CLAUDE-pipeline.md copy command" {
    grep -q 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-new-pr.sh"
}

@test "on-research-issue.sh contains CLAUDE-pipeline.md copy command" {
    grep -q 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-research-issue.sh"
}

@test "on-rebase-pr.sh does NOT contain CLAUDE-pipeline.md copy command" {
    ! grep -q 'CLAUDE-pipeline.md' "$REPO_ROOT/triggers/on-rebase-pr.sh"
}

@test "implementation triggers copy to WORKTREE_DIR" {
    for script in on-work-issue.sh on-rework-pr.sh on-write-tests.sh on-test-pr.sh; do
        grep -q 'cp.*CLAUDE-pipeline.md.*WORKTREE_DIR/CLAUDE.md' "$REPO_ROOT/triggers/$script"
    done
}

@test "readonly triggers copy to EFFECTIVE_PATH with READONLY_WORKTREE guard" {
    for script in on-new-issue.sh on-new-pr.sh on-research-issue.sh; do
        grep -q 'READONLY_WORKTREE' "$REPO_ROOT/triggers/$script"
        grep -q 'cp.*CLAUDE-pipeline.md.*EFFECTIVE_PATH/CLAUDE.md' "$REPO_ROOT/triggers/$script"
    done
}
