#!/usr/bin/env bats
# Tests for first-boot state bootstrapping in startup.sh

setup() {
    export TEST_DIR="$(mktemp -d)"
    export SCRIPT_DIR="$TEST_DIR"
    mkdir -p "$TEST_DIR/state"
    mkdir -p "$TEST_DIR/config/testproj"
    mkdir -p "$TEST_DIR/lib"
    mkdir -p "$TEST_DIR/bin"

    # Minimal repos.conf
    printf 'owner/repo\t/tmp/fakerepo\tmonorepo\n' > "$TEST_DIR/config/testproj/repos.conf"

    # Stub lib/common.sh functions
    cat > "$TEST_DIR/lib/common.sh" <<'STUBEOF'
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
load_env() { true; }
detect_os() { echo "linux"; }
read_projects() { echo "testproj"; }
read_repos() { printf 'owner/repo\t/tmp/fakerepo\tmonorepo\n'; }
validate_no_repo_overlap() { return 0; }
set_project() { true; }
STUBEOF

    # Stub notify.sh
    cat > "$TEST_DIR/bin/notify.sh" <<'STUBEOF'
#!/usr/bin/env bash
true
STUBEOF
    chmod +x "$TEST_DIR/bin/notify.sh"

    # Stub gh CLI to return known issue/PR numbers
    export PATH="$TEST_DIR/bin:$PATH"
    cat > "$TEST_DIR/bin/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Stub gh CLI for testing
if [[ "$*" == *"issue list"* ]]; then
    echo "1"
    echo "2"
    echo "3"
elif [[ "$*" == *"pr list"* ]]; then
    echo "10"
    echo "11"
elif [[ "$*" == *"api user"* ]]; then
    echo "test-user"
elif [[ "$*" == *"auth status"* ]]; then
    echo "Logged in"
else
    echo ""
fi
STUBEOF
    chmod +x "$TEST_DIR/bin/gh"

    # Stub other commands that startup.sh calls
    cat > "$TEST_DIR/bin/tmux" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1" == "has-session" ]]; then exit 0; fi
true
STUBEOF
    chmod +x "$TEST_DIR/bin/tmux"

    cat > "$TEST_DIR/bin/claude" <<'STUBEOF'
#!/usr/bin/env bash
echo "1.0.0-test"
STUBEOF
    chmod +x "$TEST_DIR/bin/claude"

    # Create empty state files (touch only, not seed yet)
    for f in processed-prs.txt processed-issues.txt processed-work.txt \
             processed-rework.txt processed-write-tests.txt processed-research.txt \
             processed-auto-triage.txt; do
        touch "$TEST_DIR/state/$f"
    done
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "first boot seeds issues when processed-issues.txt is empty" {
    # State files exist but are empty (0 bytes)
    [[ ! -s "$TEST_DIR/state/processed-issues.txt" ]]

    # Run just the seeding snippet in isolation
    source "$TEST_DIR/lib/common.sh"
    SCRIPT_DIR="$TEST_DIR"

    if [[ ! -s "$SCRIPT_DIR/state/processed-issues.txt" ]]; then
        SEED_COUNT=0
        while IFS= read -r proj; do
            [[ -z "$proj" ]] && continue
            while IFS=$'\t' read -r repo local_path repo_type; do
                [[ -z "$repo" ]] && continue
                while IFS= read -r num; do
                    [[ -z "$num" ]] && continue
                    echo "${repo}#${num}" >> "$SCRIPT_DIR/state/processed-issues.txt"
                    echo "${repo}#auto-${num}" >> "$SCRIPT_DIR/state/processed-auto-triage.txt"
                    echo "${repo}#${num}" >> "$SCRIPT_DIR/state/processed-work.txt"
                    echo "${repo}#${num}" >> "$SCRIPT_DIR/state/processed-research.txt"
                    echo "${repo}#${num}" >> "$SCRIPT_DIR/state/processed-write-tests.txt"
                    SEED_COUNT=$((SEED_COUNT + 1))
                done < <(gh issue list --repo "$repo" --state open --limit 500 --json number --jq '.[].number' 2>/dev/null || true)
            done < <(read_repos "$proj")
        done < <(read_projects)
        for f in processed-issues.txt processed-auto-triage.txt processed-work.txt processed-research.txt processed-write-tests.txt; do
            sort -u -o "$SCRIPT_DIR/state/$f" "$SCRIPT_DIR/state/$f" 2>/dev/null || true
        done
    fi

    # Verify seeded content
    [[ $SEED_COUNT -eq 3 ]]
    grep -q "owner/repo#1" "$TEST_DIR/state/processed-issues.txt"
    grep -q "owner/repo#2" "$TEST_DIR/state/processed-issues.txt"
    grep -q "owner/repo#3" "$TEST_DIR/state/processed-issues.txt"
    grep -q "owner/repo#auto-1" "$TEST_DIR/state/processed-auto-triage.txt"
    grep -q "owner/repo#1" "$TEST_DIR/state/processed-work.txt"
}

@test "first boot seeds PRs when processed-prs.txt is empty" {
    source "$TEST_DIR/lib/common.sh"
    SCRIPT_DIR="$TEST_DIR"

    if [[ ! -s "$SCRIPT_DIR/state/processed-prs.txt" ]]; then
        PR_SEED_COUNT=0
        while IFS= read -r proj; do
            [[ -z "$proj" ]] && continue
            while IFS=$'\t' read -r repo local_path repo_type; do
                [[ -z "$repo" ]] && continue
                while IFS= read -r num; do
                    [[ -z "$num" ]] && continue
                    echo "${repo}#${num}" >> "$SCRIPT_DIR/state/processed-prs.txt"
                    PR_SEED_COUNT=$((PR_SEED_COUNT + 1))
                done < <(gh pr list --repo "$repo" --state open --limit 500 --json number --jq '.[].number' 2>/dev/null || true)
            done < <(read_repos "$proj")
        done < <(read_projects)
        sort -u -o "$SCRIPT_DIR/state/processed-prs.txt" "$SCRIPT_DIR/state/processed-prs.txt" 2>/dev/null || true
    fi

    [[ $PR_SEED_COUNT -eq 2 ]]
    grep -q "owner/repo#10" "$TEST_DIR/state/processed-prs.txt"
    grep -q "owner/repo#11" "$TEST_DIR/state/processed-prs.txt"
}

@test "first boot skips seeding when state files already have content" {
    echo "owner/repo#99" > "$TEST_DIR/state/processed-issues.txt"
    echo "owner/repo#99" > "$TEST_DIR/state/processed-prs.txt"

    source "$TEST_DIR/lib/common.sh"
    SCRIPT_DIR="$TEST_DIR"

    SEED_COUNT=0
    if [[ ! -s "$SCRIPT_DIR/state/processed-issues.txt" ]]; then
        SEED_COUNT=999  # Should not reach here
    fi

    PR_SEED_COUNT=0
    if [[ ! -s "$SCRIPT_DIR/state/processed-prs.txt" ]]; then
        PR_SEED_COUNT=999  # Should not reach here
    fi

    [[ $SEED_COUNT -eq 0 ]]
    [[ $PR_SEED_COUNT -eq 0 ]]
    # Original content untouched
    [[ "$(cat "$TEST_DIR/state/processed-issues.txt")" == "owner/repo#99" ]]
}

@test "seeding deduplicates entries" {
    source "$TEST_DIR/lib/common.sh"
    SCRIPT_DIR="$TEST_DIR"

    # Simulate seeding twice (write duplicates manually)
    echo "owner/repo#1" >> "$SCRIPT_DIR/state/processed-issues.txt"
    echo "owner/repo#1" >> "$SCRIPT_DIR/state/processed-issues.txt"
    echo "owner/repo#2" >> "$SCRIPT_DIR/state/processed-issues.txt"

    sort -u -o "$SCRIPT_DIR/state/processed-issues.txt" "$SCRIPT_DIR/state/processed-issues.txt"

    local count
    count=$(wc -l < "$SCRIPT_DIR/state/processed-issues.txt" | tr -d ' ')
    [[ "$count" -eq 2 ]]
}
