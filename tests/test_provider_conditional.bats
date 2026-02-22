#!/usr/bin/env bats

# Tests for provider-conditional block processing in substitute_prompt()
# Issue #52: Codex-compatible prompt templates

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
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/zapat"
    rm -rf "$BATS_TEST_TMPDIR/prompts"
    unset AGENT_PROVIDER
}

# --- Default provider detection ---

@test "default provider is claude when AGENT_PROVIDER is unset" {
    unset AGENT_PROVIDER
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Provider: {{PROVIDER}}
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Provider: claude"
}

@test "AGENT_PROVIDER=codex sets provider to codex" {
    export AGENT_PROVIDER=codex
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Provider: {{PROVIDER}}
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Provider: codex"
}

# --- IF_CLAUDE block processing ---

@test "IF_CLAUDE blocks are kept when provider is claude" {
    unset AGENT_PROVIDER
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Before
{{#IF_CLAUDE}}
Claude content here
{{/IF_CLAUDE}}
After
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Claude content here"
    assert_output --partial "Before"
    assert_output --partial "After"
}

@test "IF_CLAUDE blocks are removed when provider is codex" {
    export AGENT_PROVIDER=codex
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Before
{{#IF_CLAUDE}}
Claude content here
{{/IF_CLAUDE}}
After
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    refute_output --partial "Claude content here"
    assert_output --partial "Before"
    assert_output --partial "After"
}

# --- IF_CODEX block processing ---

@test "IF_CODEX blocks are removed when provider is claude" {
    unset AGENT_PROVIDER
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Before
{{#IF_CODEX}}
Codex content here
{{/IF_CODEX}}
After
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    refute_output --partial "Codex content here"
    assert_output --partial "Before"
    assert_output --partial "After"
}

@test "IF_CODEX blocks are kept when provider is codex" {
    export AGENT_PROVIDER=codex
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Before
{{#IF_CODEX}}
Codex content here
{{/IF_CODEX}}
After
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Codex content here"
    assert_output --partial "Before"
    assert_output --partial "After"
}

# --- Tag stripping ---

@test "IF_CLAUDE tags are stripped from active content (no leftover tags)" {
    unset AGENT_PROVIDER
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
{{#IF_CLAUDE}}
Active content
{{/IF_CLAUDE}}
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Active content"
    refute_output --partial "{{#IF_CLAUDE}}"
    refute_output --partial "{{/IF_CLAUDE}}"
}

@test "IF_CODEX tags are stripped from active content (no leftover tags)" {
    export AGENT_PROVIDER=codex
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
{{#IF_CODEX}}
Active content
{{/IF_CODEX}}
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Active content"
    refute_output --partial "{{#IF_CODEX}}"
    refute_output --partial "{{/IF_CODEX}}"
}

# --- Mixed conditional blocks ---

@test "mixed IF_CLAUDE and IF_CODEX blocks resolve correctly for claude" {
    unset AGENT_PROVIDER
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Header
{{#IF_CLAUDE}}
Use TeamCreate tool
{{/IF_CLAUDE}}
{{#IF_CODEX}}
Work solo
{{/IF_CODEX}}
Footer
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Use TeamCreate tool"
    refute_output --partial "Work solo"
    assert_output --partial "Header"
    assert_output --partial "Footer"
}

@test "mixed IF_CLAUDE and IF_CODEX blocks resolve correctly for codex" {
    export AGENT_PROVIDER=codex
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Header
{{#IF_CLAUDE}}
Use TeamCreate tool
{{/IF_CLAUDE}}
{{#IF_CODEX}}
Work solo
{{/IF_CODEX}}
Footer
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    refute_output --partial "Use TeamCreate tool"
    assert_output --partial "Work solo"
    assert_output --partial "Header"
    assert_output --partial "Footer"
}

# --- Multiple blocks of same type ---

@test "multiple IF_CLAUDE blocks are all processed correctly" {
    unset AGENT_PROVIDER
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Start
{{#IF_CLAUDE}}
Block 1
{{/IF_CLAUDE}}
Middle
{{#IF_CLAUDE}}
Block 2
{{/IF_CLAUDE}}
End
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Block 1"
    assert_output --partial "Block 2"
    assert_output --partial "Middle"
}

# --- PROVIDER placeholder ---

@test "PROVIDER placeholder resolves to claude by default" {
    unset AGENT_PROVIDER
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Running on {{PROVIDER}} provider
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Running on claude provider"
}

@test "PROVIDER placeholder resolves to codex when set" {
    export AGENT_PROVIDER=codex
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Running on {{PROVIDER}} provider
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Running on codex provider"
}

# --- Input sanitization ---

@test "AGENT_PROVIDER with path traversal characters is sanitized" {
    export AGENT_PROVIDER="../../../etc/passwd"
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Provider: {{PROVIDER}}
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    # Path traversal chars are stripped, leaving "etcpasswd"
    refute_output --partial "../"
    refute_output --partial "/"
}

@test "AGENT_PROVIDER with empty value defaults to claude" {
    export AGENT_PROVIDER=""
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Provider: {{PROVIDER}}
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Provider: claude"
}

@test "AGENT_PROVIDER with special characters is sanitized to safe value" {
    export AGENT_PROVIDER='$(evil_cmd)'
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Provider: {{PROVIDER}}
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    # Injection characters ($, parens) are stripped; safe chars (letters, underscore) remain
    refute_output --partial '$(evil_cmd)'
    assert_output --partial "Provider: evil_cmd"
}

@test "AGENT_PROVIDER with mixed case is normalized to lowercase" {
    export AGENT_PROVIDER='Claude'
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Provider: {{PROVIDER}}
{{#IF_CLAUDE}}
Claude content.
{{/IF_CLAUDE}}
{{#IF_CODEX}}
Codex content.
{{/IF_CODEX}}
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Provider: claude"
    assert_output --partial "Claude content."
    refute_output --partial "Codex content."
}

@test "unclosed conditional tag is left verbatim (not stripped)" {
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Before.
{{#IF_CLAUDE}}
Unclosed claude block with no closing tag.
After.
EOF

    # When provider is codex, the unclosed IF_CLAUDE block has no matching
    # closing tag, so the regex won't match and the content (including the
    # opening tag) remains in the output verbatim. This is expected behavior.
    export AGENT_PROVIDER=codex
    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Before."
    assert_output --partial "After."
    # The opening tag remains since it has no matching close
    assert_output --partial "{{#IF_CLAUDE}}"
}

# --- Conditional blocks in footer ---

@test "conditional blocks in shared footer are processed correctly" {
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Main content
EOF
    cat > "$BATS_TEST_TMPDIR/prompts/_shared-footer.txt" <<'EOF'
{{#IF_CLAUDE}}
Run /exit when done
{{/IF_CLAUDE}}
{{#IF_CODEX}}
Simply end your response
{{/IF_CODEX}}
EOF

    unset AGENT_PROVIDER
    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    assert_output --partial "Run /exit when done"
    refute_output --partial "Simply end your response"
}

@test "conditional blocks in footer work for codex provider" {
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
Main content
EOF
    cat > "$BATS_TEST_TMPDIR/prompts/_shared-footer.txt" <<'EOF'
{{#IF_CLAUDE}}
Run /exit when done
{{/IF_CLAUDE}}
{{#IF_CODEX}}
Simply end your response
{{/IF_CODEX}}
EOF

    export AGENT_PROVIDER=codex
    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt"
    assert_success
    refute_output --partial "Run /exit when done"
    assert_output --partial "Simply end your response"
}

# --- Conditional blocks inside TASK_ASSESSMENT (two-pass) ---

@test "conditional blocks inside TASK_ASSESSMENT are processed correctly" {
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
{{TASK_ASSESSMENT}}
EOF

    local assessment='{{#IF_CLAUDE}}
Spawn team with TeamCreate
{{/IF_CLAUDE}}
{{#IF_CODEX}}
Work solo
{{/IF_CODEX}}'

    unset AGENT_PROVIDER
    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt" "TASK_ASSESSMENT=$assessment"
    assert_success
    assert_output --partial "Spawn team with TeamCreate"
    refute_output --partial "Work solo"
}

@test "conditional blocks inside TASK_ASSESSMENT work for codex" {
    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
{{TASK_ASSESSMENT}}
EOF

    local assessment='{{#IF_CLAUDE}}
Spawn team with TeamCreate
{{/IF_CLAUDE}}
{{#IF_CODEX}}
Work solo
{{/IF_CODEX}}'

    export AGENT_PROVIDER=codex
    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt" "TASK_ASSESSMENT=$assessment"
    assert_success
    refute_output --partial "Spawn team with TeamCreate"
    assert_output --partial "Work solo"
}

# --- No regression on real prompt templates ---

@test "real implement-issue.txt produces valid output for claude provider" {
    unset AGENT_PROVIDER
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"
    run substitute_prompt "$real_prompts/implement-issue.txt" \
        "REPO=test/repo" "ISSUE_NUMBER=1" "ISSUE_TITLE=Test" \
        "ISSUE_LABELS=agent-work" "COMPLEXITY=duo" "ISSUE_BODY=Test body" \
        "MENTION_CONTEXT=" "TASK_ASSESSMENT=Test assessment"
    assert_success
    # Claude content should be present
    assert_output --partial "TeamCreate"
    # Codex content should be absent
    refute_output --partial "working solo. Complete all phases"
}

@test "real implement-issue.txt produces valid output for codex provider" {
    export AGENT_PROVIDER=codex
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"
    run substitute_prompt "$real_prompts/implement-issue.txt" \
        "REPO=test/repo" "ISSUE_NUMBER=1" "ISSUE_TITLE=Test" \
        "ISSUE_LABELS=agent-work" "COMPLEXITY=duo" "ISSUE_BODY=Test body" \
        "MENTION_CONTEXT=" "TASK_ASSESSMENT=Test assessment"
    assert_success
    # Codex content should be present
    assert_output --partial "solo"
    # Claude-specific content should be absent
    refute_output --partial "TeamCreate"
    refute_output --partial "Task tool"
}

# --- Codex prompts must not contain Claude-specific references ---

@test "codex issue-triage.txt has no Claude-specific references" {
    export AGENT_PROVIDER=codex
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"
    run substitute_prompt "$real_prompts/issue-triage.txt" \
        "REPO=test/repo" "ISSUE_NUMBER=1" "ISSUE_TITLE=Test" \
        "ISSUE_LABELS=agent" "ISSUE_BODY=Test body" "MENTION_CONTEXT="
    assert_success
    refute_output --partial "TeamCreate"
    refute_output --partial "Task tool"
    refute_output --partial "/exit"
}

@test "codex pr-review.txt has no Claude-specific references" {
    export AGENT_PROVIDER=codex
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"
    run substitute_prompt "$real_prompts/pr-review.txt" \
        "REPO=test/repo" "PR_NUMBER=1" "PR_TITLE=Test PR" \
        "PR_BODY=Test body" "PR_FILES=src/main.ts" "PR_DIFF=+new" \
        "COMPLEXITY=duo" "MENTION_CONTEXT=" \
        "TASK_ASSESSMENT=Test assessment"
    assert_success
    refute_output --partial "TeamCreate"
    refute_output --partial "Task tool"
    refute_output --partial "/exit"
}

@test "codex research-issue.txt has no Claude-specific references" {
    export AGENT_PROVIDER=codex
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"
    run substitute_prompt "$real_prompts/research-issue.txt" \
        "REPO=test/repo" "ISSUE_NUMBER=1" "ISSUE_TITLE=Test" \
        "ISSUE_LABELS=agent-research" "ISSUE_BODY=Test body"
    assert_success
    refute_output --partial "TeamCreate"
    refute_output --partial "Task tool"
    refute_output --partial "/exit"
}

@test "codex rework-pr.txt has no Claude-specific references" {
    export AGENT_PROVIDER=codex
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"
    run substitute_prompt "$real_prompts/rework-pr.txt" \
        "REPO=test/repo" "PR_NUMBER=1" "PR_TITLE=Test PR" \
        "PR_BODY=Test body" "PR_BRANCH=agent/test" \
        "COMPLEXITY=duo" "REVIEW_COMMENTS=Looks good" \
        "PR_REVIEWS=Approved" \
        "TASK_ASSESSMENT=Test assessment"
    assert_success
    refute_output --partial "TeamCreate"
    refute_output --partial "Task tool"
    refute_output --partial "/exit"
}

# --- generate_task_assessment with provider conditionals ---

@test "generate_task_assessment duo/implement contains IF_CLAUDE blocks" {
    run generate_task_assessment "duo" "implement"
    assert_success
    assert_output --partial "{{#IF_CLAUDE}}"
    assert_output --partial "{{/IF_CLAUDE}}"
    assert_output --partial "{{#IF_CODEX}}"
    assert_output --partial "{{/IF_CODEX}}"
}

@test "generate_task_assessment solo/implement contains security checklist" {
    run generate_task_assessment "solo" "implement"
    assert_success
    assert_output --partial "security checklist"
}

@test "generate_task_assessment full/review contains IF_CLAUDE blocks" {
    run generate_task_assessment "full" "review"
    assert_success
    assert_output --partial "{{#IF_CLAUDE}}"
    assert_output --partial "{{#IF_CODEX}}"
}

@test "generate_task_assessment rework contains IF_CLAUDE blocks" {
    run generate_task_assessment "duo" "rework"
    assert_success
    assert_output --partial "{{#IF_CLAUDE}}"
    assert_output --partial "{{#IF_CODEX}}"
}

# --- End-to-end: assessment + prompt substitution ---

@test "full pipeline: assessment + prompt for claude resolves all conditionals" {
    unset AGENT_PROVIDER
    local assessment
    assessment=$(generate_task_assessment "duo" "implement")

    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
{{TASK_ASSESSMENT}}
---
Issue: {{ISSUE_NUMBER}}
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt" \
        "TASK_ASSESSMENT=$assessment" "ISSUE_NUMBER=42"
    assert_success
    # Claude team instructions should be present
    assert_output --partial "Core team (3 agents)"
    # Codex solo instructions should be absent
    refute_output --partial "Work solo with multi-perspective"
    # No leftover conditional tags
    refute_output --partial "{{#IF_CLAUDE}}"
    refute_output --partial "{{/IF_CLAUDE}}"
    refute_output --partial "{{#IF_CODEX}}"
    refute_output --partial "{{/IF_CODEX}}"
    # Issue number resolved
    assert_output --partial "Issue: 42"
}

@test "full pipeline: assessment + prompt for codex resolves all conditionals" {
    export AGENT_PROVIDER=codex
    local assessment
    assessment=$(generate_task_assessment "duo" "implement")

    cat > "$BATS_TEST_TMPDIR/prompts/test.txt" <<'EOF'
{{TASK_ASSESSMENT}}
---
Issue: {{ISSUE_NUMBER}}
EOF

    run substitute_prompt "$BATS_TEST_TMPDIR/prompts/test.txt" \
        "TASK_ASSESSMENT=$assessment" "ISSUE_NUMBER=42"
    assert_success
    # Codex solo instructions should be present
    assert_output --partial "Work solo with multi-perspective"
    # Claude team instructions should be absent
    refute_output --partial "Core team (3 agents)"
    # No leftover conditional tags
    refute_output --partial "{{#IF_CLAUDE}}"
    refute_output --partial "{{/IF_CLAUDE}}"
    refute_output --partial "{{#IF_CODEX}}"
    refute_output --partial "{{/IF_CODEX}}"
    # Issue number resolved
    assert_output --partial "Issue: 42"
}
