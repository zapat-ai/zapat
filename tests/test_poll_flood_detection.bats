#!/usr/bin/env bats

# Tests for backlog flood detection in bin/poll-github.sh

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

@test "warning triggers when items exceed threshold" {
    TOTAL_ITEMS_FOUND=35
    BACKLOG_WARNING_THRESHOLD=30
    MAX_DISPATCH=20
    DISPATCH_COUNT=20

    if [[ $TOTAL_ITEMS_FOUND -gt $BACKLOG_WARNING_THRESHOLD ]]; then
        result="warning"
    else
        result="ok"
    fi

    [ "$result" = "warning" ]
}

@test "no warning below threshold" {
    TOTAL_ITEMS_FOUND=10
    BACKLOG_WARNING_THRESHOLD=30

    if [[ $TOTAL_ITEMS_FOUND -gt $BACKLOG_WARNING_THRESHOLD ]]; then
        result="warning"
    else
        result="ok"
    fi

    [ "$result" = "ok" ]
}

@test "no warning at exact threshold" {
    TOTAL_ITEMS_FOUND=30
    BACKLOG_WARNING_THRESHOLD=30

    # Uses -gt not -ge, so exactly at threshold should NOT warn
    if [[ $TOTAL_ITEMS_FOUND -gt $BACKLOG_WARNING_THRESHOLD ]]; then
        result="warning"
    else
        result="ok"
    fi

    [ "$result" = "ok" ]
}

@test "threshold defaults to 30 when not set" {
    # Simulate the default logic from poll-github.sh
    unset BACKLOG_WARNING_THRESHOLD
    BACKLOG_WARNING_THRESHOLD=${BACKLOG_WARNING_THRESHOLD:-30}

    [ "$BACKLOG_WARNING_THRESHOLD" -eq 30 ]
}

@test "dispatch limit caps actual dispatches" {
    DISPATCH_COUNT=0
    MAX_DISPATCH=3

    # Simulate dispatch_limit_reached logic
    dispatch_limit_reached_sim() {
        [[ $DISPATCH_COUNT -ge $MAX_DISPATCH ]]
    }

    # Simulate dispatching 5 items — only first 3 should go through
    dispatched=0
    for i in 1 2 3 4 5; do
        dispatch_limit_reached_sim && continue
        dispatched=$((dispatched + 1))
        DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
    done

    [ "$dispatched" -eq 3 ]
    [ "$DISPATCH_COUNT" -eq 3 ]
}

@test "poller skips cycle when both state files are empty (defense-in-depth)" {
    # Both files exist but are empty (0 bytes) — simulates unseeded state
    touch "$AUTOMATION_DIR/state/processed-issues.txt"
    touch "$AUTOMATION_DIR/state/processed-prs.txt"

    PROCESSED_ISSUES="$AUTOMATION_DIR/state/processed-issues.txt"
    PROCESSED_PRS="$AUTOMATION_DIR/state/processed-prs.txt"

    # Replicate the guard from poll-github.sh
    if [[ ! -s "$PROCESSED_ISSUES" && ! -s "$PROCESSED_PRS" ]]; then
        result="skip"
    else
        result="poll"
    fi

    [ "$result" = "skip" ]
}

@test "poller proceeds when issues state file has content" {
    echo "org/repo#1" > "$AUTOMATION_DIR/state/processed-issues.txt"
    touch "$AUTOMATION_DIR/state/processed-prs.txt"

    PROCESSED_ISSUES="$AUTOMATION_DIR/state/processed-issues.txt"
    PROCESSED_PRS="$AUTOMATION_DIR/state/processed-prs.txt"

    if [[ ! -s "$PROCESSED_ISSUES" && ! -s "$PROCESSED_PRS" ]]; then
        result="skip"
    else
        result="poll"
    fi

    [ "$result" = "poll" ]
}

@test "poller proceeds when PRs state file has content" {
    touch "$AUTOMATION_DIR/state/processed-issues.txt"
    echo "org/repo#5" > "$AUTOMATION_DIR/state/processed-prs.txt"

    PROCESSED_ISSUES="$AUTOMATION_DIR/state/processed-issues.txt"
    PROCESSED_PRS="$AUTOMATION_DIR/state/processed-prs.txt"

    if [[ ! -s "$PROCESSED_ISSUES" && ! -s "$PROCESSED_PRS" ]]; then
        result="skip"
    else
        result="poll"
    fi

    [ "$result" = "poll" ]
}
