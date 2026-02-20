#!/usr/bin/env bats

# Tests for classify_complexity() and generate_task_assessment() in lib/common.sh

load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'

setup() {
    export AUTOMATION_DIR="$BATS_TEST_TMPDIR/zapat"
    mkdir -p "$AUTOMATION_DIR/state"
    mkdir -p "$AUTOMATION_DIR/logs"

    source "$BATS_TEST_DIRNAME/../lib/common.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/zapat"
}

# --- classify_complexity: Solo tier ---

@test "classify_complexity: solo — 1 file, 50 changes" {
    run classify_complexity 1 30 20 "src/utils.js" ""
    assert_success
    assert_output "solo"
}

@test "classify_complexity: solo — 2 files, exactly 100 changes (boundary)" {
    run classify_complexity 2 60 40 $'src/a.js\nsrc/b.js' ""
    assert_success
    assert_output "solo"
}

@test "classify_complexity: duo — 0 files, 0 changes (unknown scope floors at duo)" {
    run classify_complexity 0 0 0 "" ""
    assert_success
    assert_output "duo"
}

@test "classify_complexity: solo — docs only" {
    run classify_complexity 1 10 5 "docs/README.md" ""
    assert_success
    assert_output "solo"
}

# --- classify_complexity: Duo tier ---

@test "classify_complexity: duo — 3 files, 150 changes" {
    run classify_complexity 3 100 50 $'src/a.js\nsrc/b.js\nsrc/c.js' ""
    assert_success
    assert_output "duo"
}

@test "classify_complexity: duo — 5 files, 300 changes (boundary)" {
    run classify_complexity 5 200 100 $'src/a.js\nsrc/b.js\nsrc/c.js\nsrc/d.js\nsrc/e.js' ""
    assert_success
    assert_output "duo"
}

@test "classify_complexity: duo — 3 files, 101 changes (just above solo)" {
    run classify_complexity 3 60 41 $'src/a.js\nsrc/b.js\nsrc/c.js' ""
    assert_success
    assert_output "duo"
}

@test "classify_complexity: duo — 2 files but 101 changes (over solo LOC limit)" {
    run classify_complexity 2 60 41 $'src/a.js\nsrc/b.js' ""
    assert_success
    assert_output "duo"
}

# --- classify_complexity: Full tier (by file count) ---

@test "classify_complexity: full — 6 files (over limit)" {
    run classify_complexity 6 100 50 $'src/a.js\nsrc/b.js\nsrc/c.js\nsrc/d.js\nsrc/e.js\nsrc/f.js' ""
    assert_success
    assert_output "full"
}

# --- classify_complexity: Full tier (by total changes) ---

@test "classify_complexity: full — 301 total changes" {
    run classify_complexity 3 200 101 $'src/a.js\nsrc/b.js\nsrc/c.js' ""
    assert_success
    assert_output "full"
}

# --- classify_complexity: Full tier (by security-sensitive paths) ---

@test "classify_complexity: full — auth/ in file list" {
    run classify_complexity 1 10 5 "auth/login.js" ""
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — middleware/ in file list" {
    run classify_complexity 1 10 5 "src/middleware/cors.js" ""
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — security/ in file list" {
    run classify_complexity 1 10 5 "lib/security/encrypt.js" ""
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — token/ in file list" {
    run classify_complexity 1 10 5 "src/token/refresh.js" ""
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — oauth/ in file list" {
    run classify_complexity 1 10 5 "oauth/callback.js" ""
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — migrations/ in file list" {
    run classify_complexity 1 10 5 "db/migrations/001-add-users.sql" ""
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — secrets/ in file list" {
    run classify_complexity 1 10 5 "config/secrets/prod.yaml" ""
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — credentials/ in file list" {
    run classify_complexity 1 10 5 "credentials/service-account.json" ""
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — .env file in file list" {
    run classify_complexity 1 10 5 ".env.production" ""
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — .pem file in file list" {
    run classify_complexity 1 10 5 "certs/server.pem" ""
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — .github/workflows/ in file list" {
    run classify_complexity 1 10 5 ".github/workflows/deploy.yml" ""
    assert_success
    assert_output "full"
}

# --- classify_complexity: Full tier (by keywords in issue body) ---

@test "classify_complexity: full — 'security' keyword in body" {
    run classify_complexity 1 10 5 "src/utils.js" "Fix the security vulnerability in auth"
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — 'migration' keyword in body" {
    run classify_complexity 1 10 5 "src/utils.js" "Database migration for new schema"
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — 'breaking change' keyword in body" {
    run classify_complexity 1 10 5 "src/utils.js" "This is a breaking change to the API"
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — 'authentication' keyword in body" {
    run classify_complexity 1 10 5 "src/utils.js" "Fix authentication flow for SSO"
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — 'authorization' keyword in body" {
    run classify_complexity 1 10 5 "src/utils.js" "Update authorization checks for admin role"
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — 'vulnerability' keyword in body" {
    run classify_complexity 1 10 5 "src/utils.js" "Patch vulnerability in XML parser"
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — 'XSS' keyword in body" {
    run classify_complexity 1 10 5 "src/utils.js" "Prevent XSS in user input fields"
    assert_success
    assert_output "full"
}

@test "classify_complexity: full — 'credential' keyword in body" {
    run classify_complexity 1 10 5 "src/utils.js" "Rotate credential storage mechanism"
    assert_success
    assert_output "full"
}

@test "classify_complexity: solo — 'author' does NOT trigger full" {
    run classify_complexity 1 10 5 "src/utils.js" "Fix author name display"
    assert_success
    assert_output "solo"
}

# --- classify_complexity: Full tier (by directory spread) ---

@test "classify_complexity: full — 3+ top-level directories" {
    run classify_complexity 3 50 30 $'src/a.js\nlib/b.js\ntests/c.js' ""
    assert_success
    assert_output "full"
}

@test "classify_complexity: duo — only 2 top-level directories" {
    run classify_complexity 3 50 30 $'src/a.js\nsrc/b.js\nlib/c.js' ""
    assert_success
    assert_output "duo"
}

# --- classify_complexity: Edge cases ---

@test "classify_complexity: defaults for empty arguments (unknown scope floors at duo)" {
    run classify_complexity
    assert_success
    assert_output "duo"
}

@test "classify_complexity: non-security path with 'auth' substring not in directory" {
    # 'author.js' at top level should NOT trigger security — 'auth' keyword check
    # uses word boundary, but path check uses directory pattern auth/
    run classify_complexity 1 10 5 "author.js" ""
    assert_success
    assert_output "solo"
}

# --- generate_task_assessment ---

@test "generate_task_assessment: solo implement — recommends solo" {
    run generate_task_assessment "solo" "implement"
    assert_success
    assert_output --partial "Classification: Solo"
    assert_output --partial "Work solo"
}

@test "generate_task_assessment: duo implement — recommends small team" {
    run generate_task_assessment "duo" "implement"
    assert_success
    assert_output --partial "Classification: Duo"
    assert_output --partial "Small team (2 agents)"
    assert_output --partial "{{BUILDER_AGENT}}"
    assert_output --partial "{{SECURITY_AGENT}}"
}

@test "generate_task_assessment: full implement — recommends full team" {
    run generate_task_assessment "full" "implement"
    assert_success
    assert_output --partial "Classification: Full"
    assert_output --partial "Full team (4 agents)"
    assert_output --partial "{{UX_AGENT}}"
    assert_output --partial "{{PRODUCT_AGENT}}"
}

@test "generate_task_assessment: solo review — recommends solo review" {
    run generate_task_assessment "solo" "review"
    assert_success
    assert_output --partial "Classification: Solo"
    assert_output --partial "Review solo"
}

@test "generate_task_assessment: duo review — recommends small review team" {
    run generate_task_assessment "duo" "review"
    assert_success
    assert_output --partial "Classification: Duo"
    assert_output --partial "Small review team (2 agents)"
}

@test "generate_task_assessment: full review — recommends full review team" {
    run generate_task_assessment "full" "review"
    assert_success
    assert_output --partial "Classification: Full"
    assert_output --partial "Full review team (3 agents)"
}

@test "generate_task_assessment: rework — recommends feedback-based sizing" {
    run generate_task_assessment "full" "rework"
    assert_success
    assert_output --partial "Feedback-based sizing"
    assert_output --partial "Announce your classification"
}

@test "generate_task_assessment: unknown complexity defaults to full" {
    run generate_task_assessment "unknown" "implement"
    assert_success
    assert_output --partial "Classification: Full"
}

@test "generate_task_assessment: includes Leadership Principles" {
    run generate_task_assessment "solo" "implement"
    assert_success
    assert_output --partial "Leadership Principles"
    assert_output --partial "Customer obsession"
    assert_output --partial "Frugality"
}

@test "generate_task_assessment: includes Model Budget Guide" {
    run generate_task_assessment "duo" "review"
    assert_success
    assert_output --partial "Model Budget Guide"
    assert_output --partial "{{SUBAGENT_MODEL}}"
}

@test "generate_task_assessment: includes Available Roles" {
    run generate_task_assessment "full" "implement"
    assert_success
    assert_output --partial "Available Roles"
    assert_output --partial "{{BUILDER_AGENT}}"
    assert_output --partial "{{SECURITY_AGENT}}"
}

@test "generate_task_assessment: includes Lead's Authority section" {
    run generate_task_assessment "solo" "implement"
    assert_success
    assert_output --partial "Your Authority as Lead"
    assert_output --partial "advisory, not mandatory"
}
