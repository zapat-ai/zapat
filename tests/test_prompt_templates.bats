#!/usr/bin/env bats

# Tests for prompt template optimization (issue #31)

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

setup() {
    export AUTOMATION_DIR="$BATS_TEST_TMPDIR/zapat"
    mkdir -p "$AUTOMATION_DIR/state"
    mkdir -p "$AUTOMATION_DIR/logs"
    mkdir -p "$AUTOMATION_DIR/config"
    mkdir -p "$AUTOMATION_DIR/prompts"

    # Create minimal repos.conf so read_repos doesn't fail
    printf 'org/repo\t/tmp/repo\tbackend\n' > "$AUTOMATION_DIR/config/repos.conf"

    # Create minimal agents.conf
    cat > "$AUTOMATION_DIR/config/agents.conf" <<'EOF'
builder=engineer
security=security-reviewer
product=product-manager
ux=ux-reviewer
EOF

    source "$BATS_TEST_DIRNAME/../lib/common.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/zapat"
}

# --- Shared Footer Tests ---

@test "substitute_prompt appends shared footer when _shared-footer.txt exists" {
    cat > "$AUTOMATION_DIR/prompts/test-template.txt" <<'EOF'
Template body here.
EOF
    cat > "$AUTOMATION_DIR/prompts/_shared-footer.txt" <<'EOF'

## Footer Section
Footer content here.
EOF

    run substitute_prompt "$AUTOMATION_DIR/prompts/test-template.txt"
    assert_success
    assert_output --partial "Template body here."
    assert_output --partial "## Footer Section"
    assert_output --partial "Footer content here."
}

@test "substitute_prompt works without _shared-footer.txt" {
    cat > "$AUTOMATION_DIR/prompts/test-template.txt" <<'EOF'
Template body only.
EOF

    run substitute_prompt "$AUTOMATION_DIR/prompts/test-template.txt"
    assert_success
    assert_output --partial "Template body only."
}

@test "substitute_prompt replaces placeholders in footer" {
    cat > "$AUTOMATION_DIR/prompts/test-template.txt" <<'EOF'
Template with {{BUILDER_AGENT}}.
EOF
    cat > "$AUTOMATION_DIR/prompts/_shared-footer.txt" <<'EOF'

Footer with {{BUILDER_AGENT}}.
EOF

    run substitute_prompt "$AUTOMATION_DIR/prompts/test-template.txt"
    assert_success
    assert_output --partial "Footer with engineer."
}

# --- Template Content Verification ---

@test "no prompt template contains '## Repository Map' (moved to footer)" {
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"
    for f in implement-issue.txt issue-triage.txt pr-review.txt rework-pr.txt research-issue.txt; do
        if grep -q '## Repository Map' "$real_prompts/$f"; then
            fail "Found '## Repository Map' in $f — should be in _shared-footer.txt"
        fi
    done
}

@test "shared footer contains '## Repository Map'" {
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"
    run grep '## Repository Map' "$real_prompts/_shared-footer.txt"
    assert_success
}

@test "shared footer contains '## Safety Rules'" {
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"
    run grep '## Safety Rules' "$real_prompts/_shared-footer.txt"
    assert_success
}

@test "no prompt template claims 15-20KB persona sizes" {
    local real_prompts="$BATS_TEST_DIRNAME/../prompts"
    for f in "$real_prompts"/*.txt; do
        if grep -q '15-20KB' "$f"; then
            fail "Found '15-20KB' in $(basename "$f") — persona sizes should say ~1-2KB"
        fi
    done
}

@test "agent persona files are under 3KB each" {
    local agents_dir="$BATS_TEST_DIRNAME/../agents"
    for f in "$agents_dir"/*.md; do
        local size
        size=$(wc -c < "$f" | tr -d ' ')
        if [[ "$size" -gt 3072 ]]; then
            fail "$(basename "$f") is ${size} bytes — expected under 3KB"
        fi
    done
}
