#!/usr/bin/env bats

# Tests for provider-conditional block processing in substitute_prompt() (issue #52)

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

    # Create minimal agents.conf
    cat > "$AUTOMATION_DIR/config/agents.conf" <<'EOF'
builder=engineer
security=security-reviewer
product=product-manager
ux=ux-reviewer
EOF

    source "$BATS_TEST_DIRNAME/../lib/common.sh"

    TEMPLATE="$BATS_TEST_TMPDIR/prompts/template.txt"
}

teardown() {
    unset PROVIDER
    unset CODEX_MODEL
    rm -rf "$BATS_TEST_TMPDIR/zapat"
    rm -rf "$BATS_TEST_TMPDIR/prompts"
}

# --- Default provider behavior ---

@test "default provider is claude when PROVIDER is unset" {
    unset PROVIDER
    printf '{{#IF_CLAUDE}}claude-content{{/IF_CLAUDE}}{{#IF_CODEX}}codex-content{{/IF_CODEX}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "claude-content"
    refute_output --partial "codex-content"
}

@test "PROVIDER=claude keeps Claude blocks and strips Codex blocks" {
    export PROVIDER=claude
    printf '{{#IF_CLAUDE}}claude-content{{/IF_CLAUDE}}{{#IF_CODEX}}codex-content{{/IF_CODEX}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "claude-content"
    refute_output --partial "codex-content"
}

@test "PROVIDER=codex keeps Codex blocks and strips Claude blocks" {
    export PROVIDER=codex
    printf '{{#IF_CLAUDE}}claude-content{{/IF_CLAUDE}}{{#IF_CODEX}}codex-content{{/IF_CODEX}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "codex-content"
    refute_output --partial "claude-content"
}

# --- Subagent model selection ---

@test "Codex provider uses o3 as default subagent model" {
    export PROVIDER=codex
    unset CODEX_MODEL
    printf 'Model: {{SUBAGENT_MODEL}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "Model: o3"
}

@test "Codex provider respects CODEX_MODEL override" {
    export PROVIDER=codex
    export CODEX_MODEL=gpt-4o
    printf 'Model: {{SUBAGENT_MODEL}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "Model: gpt-4o"
}

@test "Claude provider uses claude subagent model (not o3)" {
    export PROVIDER=claude
    printf 'Model: {{SUBAGENT_MODEL}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    refute_output --partial "Model: o3"
}

# --- PROVIDER placeholder ---

@test "PROVIDER placeholder resolves to current provider" {
    export PROVIDER=codex
    printf 'Provider: {{PROVIDER}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "Provider: codex"
}

@test "PROVIDER placeholder resolves to claude when default" {
    unset PROVIDER
    printf 'Provider: {{PROVIDER}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "Provider: claude"
}

# --- Tag leak prevention ---

@test "conditional tags do not leak into output for claude" {
    export PROVIDER=claude
    printf '{{#IF_CLAUDE}}content{{/IF_CLAUDE}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    refute_output --partial "{{#IF_CLAUDE}}"
    refute_output --partial "{{/IF_CLAUDE}}"
}

@test "conditional tags do not leak into output for codex" {
    export PROVIDER=codex
    printf '{{#IF_CODEX}}content{{/IF_CODEX}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    refute_output --partial "{{#IF_CODEX}}"
    refute_output --partial "{{/IF_CODEX}}"
}

@test "stripped block tags do not leak into output" {
    export PROVIDER=claude
    printf '{{#IF_CODEX}}codex-only{{/IF_CODEX}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    refute_output --partial "{{#IF_CODEX}}"
    refute_output --partial "{{/IF_CODEX}}"
    refute_output --partial "codex-only"
}

# --- Multiple blocks ---

@test "multiple conditional blocks in same template" {
    export PROVIDER=claude
    printf 'A{{#IF_CLAUDE}}B{{/IF_CLAUDE}}C{{#IF_CODEX}}D{{/IF_CODEX}}E{{#IF_CLAUDE}}F{{/IF_CLAUDE}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "ABCEF"
    refute_output --partial "D"
}

@test "multiple codex blocks all kept when PROVIDER=codex" {
    export PROVIDER=codex
    printf '{{#IF_CODEX}}first{{/IF_CODEX}} middle {{#IF_CODEX}}second{{/IF_CODEX}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "first"
    assert_output --partial "second"
}

# --- Empty blocks ---

@test "empty conditional blocks are handled without error" {
    export PROVIDER=claude
    printf 'before{{#IF_CODEX}}{{/IF_CODEX}}after' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "beforeafter"
}

@test "empty active conditional blocks are handled without error" {
    export PROVIDER=claude
    printf 'before{{#IF_CLAUDE}}{{/IF_CLAUDE}}after' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "beforeafter"
}

# --- Placeholders inside conditional blocks ---

@test "placeholders inside IF_CLAUDE blocks are resolved" {
    export PROVIDER=claude
    printf '{{#IF_CLAUDE}}Agent: {{BUILDER_AGENT}}{{/IF_CLAUDE}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "Agent: engineer"
}

@test "placeholders inside IF_CODEX blocks are resolved" {
    export PROVIDER=codex
    printf '{{#IF_CODEX}}Model: {{SUBAGENT_MODEL}}{{/IF_CODEX}}' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "Model: o3"
}

@test "stripped blocks do not expose placeholder values" {
    export PROVIDER=codex
    printf '{{#IF_CLAUDE}}Agent: {{BUILDER_AGENT}}{{/IF_CLAUDE}}remaining' > "$TEMPLATE"
    run substitute_prompt "$TEMPLATE"
    assert_success
    refute_output --partial "Agent:"
    assert_output --partial "remaining"
}

# --- Footer conditional blocks ---

@test "footer conditional blocks work correctly for codex" {
    export PROVIDER=codex
    printf 'Main content' > "$BATS_TEST_TMPDIR/prompts/footer-test.txt"
    cat > "$BATS_TEST_TMPDIR/prompts/_shared-footer.txt" <<'EOF'
{{#IF_CLAUDE}}
Run /exit when done.
{{/IF_CLAUDE}}
{{#IF_CODEX}}
Simply end your response.
{{/IF_CODEX}}
EOF
    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/footer-test.txt"
    assert_success
    assert_output --partial "Simply end your response."
    refute_output --partial "/exit"
}

@test "footer conditional blocks work correctly for claude" {
    export PROVIDER=claude
    printf 'Main content' > "$BATS_TEST_TMPDIR/prompts/footer-test.txt"
    cat > "$BATS_TEST_TMPDIR/prompts/_shared-footer.txt" <<'EOF'
{{#IF_CLAUDE}}
Run /exit when done.
{{/IF_CLAUDE}}
{{#IF_CODEX}}
Simply end your response.
{{/IF_CODEX}}
EOF
    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/footer-test.txt"
    assert_success
    assert_output --partial "Run /exit when done."
    refute_output --partial "Simply end your response."
}

# --- Real prompt files validation ---

@test "Codex prompts contain no Claude-specific TeamCreate references" {
    export PROVIDER=codex
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"
    local failed=0

    for f in "$real_prompts"/*.txt; do
        [[ "$(basename "$f")" == "_shared-footer.txt" ]] && continue
        # Skip scheduled/utility prompts that don't use teams
        [[ "$(basename "$f")" == "daily-standup.txt" ]] && continue
        [[ "$(basename "$f")" == "weekly-planning.txt" ]] && continue
        [[ "$(basename "$f")" == "monthly-strategy.txt" ]] && continue
        [[ "$(basename "$f")" == "weekly-security-scan.txt" ]] && continue
        [[ "$(basename "$f")" == "build-tests.txt" ]] && continue

        local output
        output=$(substitute_prompt "$f" \
            "REPO=test/repo" \
            "ISSUE_NUMBER=1" \
            "ISSUE_TITLE=Test" \
            "ISSUE_LABELS=agent-work" \
            "ISSUE_BODY=Test body" \
            "PR_NUMBER=1" \
            "PR_TITLE=Test" \
            "PR_BODY=Test" \
            "PR_FILES=test.ts" \
            "PR_DIFF=test" \
            "PR_BRANCH=test" \
            "COMPLEXITY=duo" \
            "TASK_ASSESSMENT=Assessment" \
            "REVIEW_COMMENTS=None" \
            "PR_REVIEWS=None" \
            "MENTION_CONTEXT=")

        if echo "$output" | grep -q 'TeamCreate'; then
            echo "FAIL: $(basename "$f") contains 'TeamCreate' in Codex mode" >&2
            failed=1
        fi
        if echo "$output" | grep -qE '`Task` tool|the Task tool'; then
            echo "FAIL: $(basename "$f") contains 'Task tool' reference in Codex mode" >&2
            failed=1
        fi
    done

    [[ "$failed" -eq 0 ]]
}

@test "Claude prompts contain no leftover conditional tags" {
    export PROVIDER=claude
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"

    for f in "$real_prompts"/*.txt; do
        [[ "$(basename "$f")" == "_shared-footer.txt" ]] && continue

        local output
        output=$(substitute_prompt "$f" \
            "REPO=test/repo" \
            "ISSUE_NUMBER=1" \
            "ISSUE_TITLE=Test" \
            "ISSUE_LABELS=agent-work" \
            "ISSUE_BODY=Test body" \
            "PR_NUMBER=1" \
            "PR_TITLE=Test" \
            "PR_BODY=Test" \
            "PR_FILES=test.ts" \
            "PR_DIFF=test" \
            "PR_BRANCH=test" \
            "COMPLEXITY=duo" \
            "TASK_ASSESSMENT=Assessment" \
            "REVIEW_COMMENTS=None" \
            "PR_REVIEWS=None" \
            "MENTION_CONTEXT=")

        if echo "$output" | grep -qF '{{#IF_'; then
            fail "$(basename "$f") contains leftover {{#IF_ tags in Claude mode"
        fi
        if echo "$output" | grep -qF '{{/IF_'; then
            fail "$(basename "$f") contains leftover {{/IF_ tags in Claude mode"
        fi
    done
}

@test "multiline content in conditional blocks is handled correctly" {
    export PROVIDER=claude
    cat > "$TEMPLATE" <<'EOF'
{{#IF_CLAUDE}}
Line 1
Line 2
Line 3
{{/IF_CLAUDE}}
{{#IF_CODEX}}
Codex line 1
Codex line 2
{{/IF_CODEX}}
EOF
    run substitute_prompt "$TEMPLATE"
    assert_success
    assert_output --partial "Line 1"
    assert_output --partial "Line 2"
    assert_output --partial "Line 3"
    refute_output --partial "Codex line 1"
}
