#!/usr/bin/env bats

# Tests for PR diff capping in substitute_prompt()

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

setup() {
    export AUTOMATION_DIR="$BATS_TEST_TMPDIR/zapat"
    mkdir -p "$AUTOMATION_DIR/state"
    mkdir -p "$AUTOMATION_DIR/logs"
    mkdir -p "$AUTOMATION_DIR/config"

    # Create minimal repos.conf and agents.conf so common.sh doesn't error
    touch "$AUTOMATION_DIR/config/repos.conf"
    touch "$AUTOMATION_DIR/config/agents.conf"

    source "$BATS_TEST_DIRNAME/../lib/common.sh"

    # Create a simple template for testing
    TEMPLATE_FILE="$BATS_TEST_TMPDIR/template.txt"
    echo 'Diff: {{PR_DIFF}} End.' > "$TEMPLATE_FILE"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/zapat"
    rm -f "$BATS_TEST_TMPDIR/template.txt"
}

# --- Diff Capping Tests ---

@test "substitute_prompt passes small diffs through unchanged" {
    local small_diff="diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -1 +1 @@
-old
+new"

    run substitute_prompt "$TEMPLATE_FILE" "PR_DIFF=$small_diff"
    assert_success
    assert_output --partial "+new"
    refute_output --partial "DIFF TRUNCATED"
}

@test "substitute_prompt truncates diffs exceeding MAX_DIFF_CHARS" {
    # Generate a diff larger than the limit
    export MAX_DIFF_CHARS=100
    local big_diff
    big_diff=$(printf 'x%.0s' $(seq 1 200))

    run substitute_prompt "$TEMPLATE_FILE" "PR_DIFF=$big_diff"
    assert_success
    assert_output --partial "DIFF TRUNCATED"
    assert_output --partial "limit: 100 chars"
}

@test "substitute_prompt truncation includes total line count" {
    export MAX_DIFF_CHARS=50
    # Create a multi-line diff
    local multi_line_diff
    multi_line_diff=$(printf 'line %d\n' $(seq 1 20))

    run substitute_prompt "$TEMPLATE_FILE" "PR_DIFF=$multi_line_diff"
    assert_success
    assert_output --partial "DIFF TRUNCATED"
    assert_output --partial "total lines"
}

@test "substitute_prompt uses default 40000 char limit" {
    # Unset any override
    unset MAX_DIFF_CHARS

    # Generate a diff under 40K - should not be truncated
    local under_limit
    under_limit=$(printf 'x%.0s' $(seq 1 1000))

    run substitute_prompt "$TEMPLATE_FILE" "PR_DIFF=$under_limit"
    assert_success
    refute_output --partial "DIFF TRUNCATED"
}

@test "substitute_prompt respects custom MAX_DIFF_CHARS" {
    export MAX_DIFF_CHARS=200
    local diff_250
    diff_250=$(printf 'y%.0s' $(seq 1 250))

    run substitute_prompt "$TEMPLATE_FILE" "PR_DIFF=$diff_250"
    assert_success
    assert_output --partial "DIFF TRUNCATED"
    assert_output --partial "limit: 200 chars"
}

@test "substitute_prompt does not truncate non-PR_DIFF keys" {
    export MAX_DIFF_CHARS=10
    local template="$BATS_TEST_TMPDIR/other_template.txt"
    echo '{{OTHER_KEY}}' > "$template"

    local big_value
    big_value=$(printf 'z%.0s' $(seq 1 100))

    run substitute_prompt "$template" "OTHER_KEY=$big_value"
    assert_success
    refute_output --partial "DIFF TRUNCATED"
    # Output should contain the full value
    assert_output --partial "$(printf 'z%.0s' $(seq 1 100))"
}
