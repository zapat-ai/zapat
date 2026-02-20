#!/usr/bin/env bats

# Tests for substitute_prompt shared footer functionality in lib/common.sh
# Tests for substitute_prompt() diff capping in lib/common.sh

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

setup() {
    export AUTOMATION_DIR="$BATS_TEST_TMPDIR/zapat"
    mkdir -p "$AUTOMATION_DIR/state"
    mkdir -p "$AUTOMATION_DIR/logs"
    mkdir -p "$AUTOMATION_DIR/config"
    mkdir -p "$BATS_TEST_TMPDIR/prompts"

    # Create minimal repos.conf so read_repos doesn't fail
    touch "$AUTOMATION_DIR/config/repos.conf"

    source "$BATS_TEST_DIRNAME/../lib/common.sh"

    # Create a simple template for testing
    TEMPLATE="$BATS_TEST_TMPDIR/template.txt"
    echo 'Diff: {{PR_DIFF}} Files: {{PR_FILES}} PR: {{PR_NUMBER}}' > "$TEMPLATE"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/zapat"
    rm -rf "$BATS_TEST_TMPDIR/prompts"
}

# --- Shared Footer Tests ---

@test "substitute_prompt auto-appends footer when _shared-footer.txt exists" {
    echo "Hello {{NAME}}" > "$BATS_TEST_TMPDIR/prompts/test-template.txt"
    echo "---FOOTER---" > "$BATS_TEST_TMPDIR/prompts/_shared-footer.txt"

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test-template.txt" "NAME=World"
    assert_success
    assert_output --partial "Hello World"
    assert_output --partial "---FOOTER---"
}

@test "substitute_prompt works without footer file (no _shared-footer.txt)" {
    echo "Hello {{NAME}}" > "$BATS_TEST_TMPDIR/prompts/test-template.txt"
    rm -f "$BATS_TEST_TMPDIR/prompts/_shared-footer.txt"

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test-template.txt" "NAME=World"
    assert_success
    assert_output --partial "Hello World"
}

@test "substitute_prompt works when footer file is missing (graceful fallback)" {
    printf "Hello {{NAME}}\n" > "$BATS_TEST_TMPDIR/prompts/test-template.txt"

    # Ensure no footer file exists
    rm -f "$BATS_TEST_TMPDIR/prompts/_shared-footer.txt"

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test-template.txt" "NAME=World"
    assert_success
    assert_output --partial "Hello World"
}

@test "substitute_prompt applies placeholder substitution to footer content" {
    echo "Template for {{REPO}}" > "$BATS_TEST_TMPDIR/prompts/test-template.txt"
    echo "Footer: {{REPO}}" > "$BATS_TEST_TMPDIR/prompts/_shared-footer.txt"

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test-template.txt" "REPO=my-org/my-repo"
    assert_success
    assert_output --partial "Template for my-org/my-repo"
    assert_output --partial "Footer: my-org/my-repo"
}

@test "substitute_prompt footer preserves auto-injected variables" {
    echo "Main content" > "$BATS_TEST_TMPDIR/prompts/test-template.txt"
    printf "\n## Repository Map\n{{REPO_MAP}}" > "$BATS_TEST_TMPDIR/prompts/_shared-footer.txt"

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test-template.txt"
    assert_success
    assert_output --partial "Main content"
    assert_output --partial "## Repository Map"
}

# --- Diff Capping Tests ---

@test "substitute_prompt truncates diff exceeding MAX_DIFF_CHARS" {
    # Generate a diff larger than the limit
    local big_diff
    big_diff=$(printf 'x%.0s' $(seq 1 500))

    export MAX_DIFF_CHARS=100
    run substitute_prompt "$TEMPLATE" "PR_NUMBER=42" "REPO=owner/repo" "PR_DIFF=$big_diff" "PR_FILES=src/main.ts"
    assert_success
    assert_output --partial "DIFF TRUNCATED"
    assert_output --partial "of 500 total chars"
}

@test "substitute_prompt truncation message includes line count" {
    # Generate multi-line diff that exceeds limit
    local big_diff=""
    for i in $(seq 1 200); do
        big_diff+="line ${i}: some diff content here"$'\n'
    done

    export MAX_DIFF_CHARS=500
    run substitute_prompt "$TEMPLATE" "PR_NUMBER=99" "REPO=test/repo" "PR_DIFF=$big_diff" "PR_FILES=a.ts"
    assert_success
    assert_output --partial "total lines"
    assert_output --partial "MUST fetch the full diff"
    assert_output --partial "gh pr diff 99 --repo test/repo"
}

@test "substitute_prompt truncation message includes gh pr diff command" {
    local big_diff
    big_diff=$(printf 'x%.0s' $(seq 1 200))

    export MAX_DIFF_CHARS=50
    run substitute_prompt "$TEMPLATE" "PR_NUMBER=77" "REPO=myorg/myrepo" "PR_DIFF=$big_diff" "PR_FILES=a.ts"
    assert_success
    assert_output --partial "gh pr diff 77 --repo myorg/myrepo"
}

@test "substitute_prompt does not truncate diff under limit" {
    local small_diff="--- a/file.txt
+++ b/file.txt
@@ -1 +1 @@
-old
+new"

    export MAX_DIFF_CHARS=40000
    run substitute_prompt "$TEMPLATE" "PR_NUMBER=10" "REPO=o/r" "PR_DIFF=$small_diff" "PR_FILES=file.txt"
    assert_success
    refute_output --partial "DIFF TRUNCATED"
    assert_output --partial "+new"
}

@test "custom MAX_DIFF_CHARS override works" {
    local diff_200
    diff_200=$(printf 'y%.0s' $(seq 1 200))

    # At 300 limit, 200-char diff should NOT be truncated
    export MAX_DIFF_CHARS=300
    run substitute_prompt "$TEMPLATE" "PR_NUMBER=1" "REPO=o/r" "PR_DIFF=$diff_200" "PR_FILES=a.ts"
    assert_success
    refute_output --partial "DIFF TRUNCATED"

    # At 100 limit, 200-char diff SHOULD be truncated
    export MAX_DIFF_CHARS=100
    run substitute_prompt "$TEMPLATE" "PR_NUMBER=1" "REPO=o/r" "PR_DIFF=$diff_200" "PR_FILES=a.ts"
    assert_success
    assert_output --partial "DIFF TRUNCATED"
}

@test "substitute_prompt replaces PR_FILES placeholder" {
    run substitute_prompt "$TEMPLATE" "PR_NUMBER=5" "REPO=o/r" "PR_DIFF=small" "PR_FILES=src/app.tsx
src/index.ts
README.md"
    assert_success
    assert_output --partial "src/app.tsx"
    assert_output --partial "src/index.ts"
    assert_output --partial "README.md"
}

# --- TASK_ASSESSMENT two-pass resolution test ---

@test "substitute_prompt resolves placeholders inside TASK_ASSESSMENT (two-pass)" {
    # Template uses TASK_ASSESSMENT which itself contains {{BUILDER_AGENT}}
    echo '{{TASK_ASSESSMENT}} and builder is {{BUILDER_AGENT}}' > "$BATS_TEST_TMPDIR/prompts/two-pass.txt"

    local assessment="Agent: {{BUILDER_AGENT}} Model: {{SUBAGENT_MODEL}}"
    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/two-pass.txt" "TASK_ASSESSMENT=$assessment"
    assert_success
    # PASS 1 expands TASK_ASSESSMENT, PASS 2 resolves BUILDER_AGENT and SUBAGENT_MODEL inside it
    assert_output --partial "Agent: engineer"
    assert_output --partial "Model: sonnet"
    assert_output --partial "and builder is engineer"
}
