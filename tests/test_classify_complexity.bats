#!/usr/bin/env bats

# Tests for classify_complexity() and generate_team_instructions() in lib/common.sh

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

@test "classify_complexity: solo — 0 files, 0 changes (empty)" {
    run classify_complexity 0 0 0 "" ""
    assert_success
    assert_output "solo"
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

@test "classify_complexity: defaults for empty arguments" {
    run classify_complexity
    assert_success
    assert_output "solo"
}

@test "classify_complexity: non-security path with 'auth' substring not in directory" {
    # 'author.js' at top level should NOT trigger security — 'auth' keyword check
    # uses word boundary, but path check uses directory pattern auth/
    run classify_complexity 1 10 5 "author.js" ""
    assert_success
    assert_output "solo"
}

# --- generate_team_instructions ---

@test "generate_team_instructions: solo implement — no team creation" {
    run generate_team_instructions "solo" "implement"
    assert_success
    assert_output --partial "Do NOT create a team"
    assert_output --partial "solo-complexity"
}

@test "generate_team_instructions: duo implement — small team" {
    run generate_team_instructions "duo" "implement"
    assert_success
    assert_output --partial "SMALL team"
    assert_output --partial "duo-complexity"
    assert_output --partial "Do NOT spawn ux-reviewer or product-manager"
}

@test "generate_team_instructions: full implement — full team" {
    run generate_team_instructions "full" "implement"
    assert_success
    assert_output --partial "full-complexity"
    assert_output --partial "ux-reviewer"
    assert_output --partial "product-manager"
}

@test "generate_team_instructions: solo review — no team" {
    run generate_team_instructions "solo" "review"
    assert_success
    assert_output --partial "Do NOT create a team"
    assert_output --partial "solo-complexity"
}

@test "generate_team_instructions: duo review — small team" {
    run generate_team_instructions "duo" "review"
    assert_success
    assert_output --partial "SMALL review team"
    assert_output --partial "duo-complexity"
}

@test "generate_team_instructions: full review — full team" {
    run generate_team_instructions "full" "review"
    assert_success
    assert_output --partial "full-complexity"
    assert_output --partial "ux-reviewer"
}

@test "generate_team_instructions: solo rework — no team" {
    run generate_team_instructions "solo" "rework"
    assert_success
    assert_output --partial "Do NOT create a team"
    assert_output --partial "solo-complexity"
}

@test "generate_team_instructions: duo rework — small team" {
    run generate_team_instructions "duo" "rework"
    assert_success
    assert_output --partial "SMALL team"
    assert_output --partial "duo-complexity"
}

@test "generate_team_instructions: full rework — full team" {
    run generate_team_instructions "full" "rework"
    assert_success
    assert_output --partial "full-complexity"
    assert_output --partial "product-manager"
}

@test "generate_team_instructions: unknown complexity defaults to full" {
    run generate_team_instructions "unknown" "implement"
    assert_success
    assert_output --partial "full-complexity"
}
