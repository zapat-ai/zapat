#!/usr/bin/env bash
# Zapat - Post-Reboot Startup
# Run this after reboot: bin/startup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Flag Parsing ---
FORCE_SEED=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed-state)
            FORCE_SEED=true
            shift
            ;;
        --help|-h)
            echo "Usage: bin/startup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --seed-state  Force re-seed state files with current open issues/PRs"
            echo "  --help, -h    Show this help message"
            echo ""
            echo "Run this script after a reboot or fresh install to initialize"
            echo "the Zapat pipeline (tmux, cron, state files, dashboard)."
            exit 0
            ;;
        *)
            log_error "Unknown option: $1 (use --help for usage)"
            exit 1
            ;;
    esac
done

echo "============================================"
echo "  Zapat — Startup"
echo "============================================"
echo ""

# --- Step 1: Check/Create .env and repos.conf ---
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
        cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
        log_warn ".env created from .env.example — EDIT IT before running again!"
        log_warn "Set at minimum: SLACK_WEBHOOK_URL, GH_TOKEN"
        echo ""
        echo "  Edit: $SCRIPT_DIR/.env"
        echo ""
        exit 1
    else
        log_error ".env.example not found. Something is wrong with the installation."
        exit 1
    fi
fi

# Check for repos.conf — look in project dirs first, fall back to top-level
REPOS_FOUND=false
for dir in "$SCRIPT_DIR"/config/*/; do
    [[ -d "$dir" && -f "$dir/repos.conf" ]] && REPOS_FOUND=true && break
done
if [[ "$REPOS_FOUND" != "true" && ! -f "$SCRIPT_DIR/config/repos.conf" ]]; then
    if [[ -f "$SCRIPT_DIR/config/repos.conf.example" ]]; then
        cp "$SCRIPT_DIR/config/repos.conf.example" "$SCRIPT_DIR/config/repos.conf"
        log_warn "repos.conf created from repos.conf.example — EDIT paths for this machine!"
        echo ""
        echo "  Edit: $SCRIPT_DIR/config/repos.conf"
        echo ""
        exit 1
    else
        log_error "repos.conf.example not found. Something is wrong with the installation."
        exit 1
    fi
fi

# --- Step 1b: Auto-migrate legacy single-project layout ---
if [[ -f "$SCRIPT_DIR/config/repos.conf" && ! -L "$SCRIPT_DIR/config/repos.conf" && ! -d "$SCRIPT_DIR/config/default" ]]; then
    log_info "Migrating single-project config to config/default/..."
    mkdir -p "$SCRIPT_DIR/config/default"

    mv "$SCRIPT_DIR/config/repos.conf" "$SCRIPT_DIR/config/default/repos.conf"
    [[ -f "$SCRIPT_DIR/config/agents.conf" && ! -L "$SCRIPT_DIR/config/agents.conf" ]] && \
        mv "$SCRIPT_DIR/config/agents.conf" "$SCRIPT_DIR/config/default/agents.conf"
    [[ -f "$SCRIPT_DIR/config/project-context.txt" && ! -L "$SCRIPT_DIR/config/project-context.txt" ]] && \
        mv "$SCRIPT_DIR/config/project-context.txt" "$SCRIPT_DIR/config/default/project-context.txt"

    # Leave symlinks for backward compat (scripts run directly, not via poller)
    ln -sf "default/repos.conf" "$SCRIPT_DIR/config/repos.conf"
    [[ -f "$SCRIPT_DIR/config/default/agents.conf" ]] && \
        ln -sf "default/agents.conf" "$SCRIPT_DIR/config/agents.conf"
    [[ -f "$SCRIPT_DIR/config/default/project-context.txt" ]] && \
        ln -sf "default/project-context.txt" "$SCRIPT_DIR/config/project-context.txt"

    log_info "Migration complete. Config now in config/default/"
fi

load_env

# --- Step 1c: Validate no repo overlap between projects ---
if ! validate_no_repo_overlap; then
    log_warn "Repo overlap detected between projects. Each repo should belong to exactly one project."
fi

# --- Step 2: tmux Session ---
echo "[1/9] Setting up tmux session..."
if tmux has-session -t zapat 2>/dev/null; then
    log_info "tmux session 'zapat' already exists"
else
    tmux new-session -d -s zapat
    log_info "tmux session 'zapat' created"
fi

# --- Step 3: Keychain (macOS only) ---
echo "[2/9] Unlocking keychain..."
if [[ "$(detect_os)" == "macos" ]]; then
    if security unlock-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null; then
        log_info "Keychain unlocked"
    else
        log_warn "Keychain unlock skipped or failed (may already be unlocked)"
    fi
else
    log_info "Keychain step skipped (not macOS)"
fi

# --- Step 4: Verify gh CLI ---
echo "[3/9] Verifying GitHub CLI auth..."
if [[ -z "${GH_TOKEN:-}" ]]; then
    log_warn "GH_TOKEN not set in .env — gh CLI may not work in cron"
    echo "  Set GH_TOKEN in .env for reliable headless operation"
fi
GH_USER=$(gh api user --jq .login 2>/dev/null || echo "")
if [[ -n "$GH_USER" ]]; then
    log_info "GitHub CLI authenticated as $GH_USER"
else
    log_error "GitHub CLI NOT authenticated"
    echo ""
    echo "  Set GH_TOKEN in .env (recommended) or run: gh auth login"
    echo ""
    exit 1
fi

# --- Step 5: Verify claude CLI ---
echo "[4/9] Verifying claude CLI..."
if command -v claude &>/dev/null; then
    CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
    log_info "claude CLI found (version: $CLAUDE_VERSION)"
else
    log_error "claude CLI NOT found"
    echo ""
    echo "  Install: npm install -g @anthropic-ai/claude-code"
    echo ""
    exit 1
fi

# --- Step 5b: Clean up orphaned worktrees ---
echo "[4b/9] Cleaning up orphaned worktrees..."
WORKTREE_CLEANED=0
if [[ -d ${ZAPAT_HOME:-$HOME/.zapat}/worktrees ]]; then
    for wt in "${ZAPAT_HOME:-$HOME/.zapat}"/worktrees/*/; do
        [[ -d "$wt" ]] || continue
        rm -rf "$wt"
        WORKTREE_CLEANED=$((WORKTREE_CLEANED + 1))
    done
fi

# Prune worktrees in all repos (across all projects)
while IFS= read -r proj; do
    [[ -z "$proj" ]] && continue
    while IFS=$'\t' read -r repo local_path repo_type; do
        [[ -z "$repo" ]] && continue
        if [[ -d "$local_path" ]]; then
            git -C "$local_path" worktree prune 2>/dev/null || true
        fi
    done < <(read_repos "$proj")
done < <(read_projects)

log_info "Cleaned $WORKTREE_CLEANED orphaned worktrees"

# --- Step 6: Pull repos ---
echo "[5/9] Pulling latest code..."
PULL_SUCCESS=0
PULL_FAIL=0

while IFS= read -r proj; do
    [[ -z "$proj" ]] && continue
    while IFS=$'\t' read -r repo local_path repo_type; do
        [[ -z "$repo" ]] && continue
        if [[ -d "$local_path" ]]; then
            if git -C "$local_path" pull --ff-only &>/dev/null; then
                log_info "Pulled $repo"
                PULL_SUCCESS=$((PULL_SUCCESS + 1))
            else
                log_warn "Failed to pull $repo (may have local changes)"
                PULL_FAIL=$((PULL_FAIL + 1))
            fi
        else
            log_warn "Repo path not found: $local_path ($repo)"
            PULL_FAIL=$((PULL_FAIL + 1))
        fi
    done < <(read_repos "$proj")
done < <(read_projects)

echo "  Pulled: $PULL_SUCCESS repos, Failed: $PULL_FAIL repos"

# --- Step 7: State Files & First-Boot Seeding ---
# IMPORTANT: State seeding MUST happen before cron installation to prevent
# a race where the first poll fires before seeding completes, causing the
# poller to treat the entire backlog as new items (issue #4).
# Safety net: poll-github.sh also checks for empty state files and skips
# the cycle if seeding hasn't run yet (defense-in-depth).
echo "[6/9] Initializing state files..."
mkdir -p "$SCRIPT_DIR/state"
mkdir -p "$SCRIPT_DIR/state/items"
touch "$SCRIPT_DIR/state/processed-prs.txt"
touch "$SCRIPT_DIR/state/processed-issues.txt"
touch "$SCRIPT_DIR/state/processed-work.txt"
touch "$SCRIPT_DIR/state/processed-rework.txt"
touch "$SCRIPT_DIR/state/processed-write-tests.txt"
touch "$SCRIPT_DIR/state/processed-research.txt"
touch "$SCRIPT_DIR/state/processed-auto-triage.txt"
log_info "State files ready"

# Track seeding outcome for the summary box
ISSUES_SEEDED=-1  # -1 = skipped, 0+ = count seeded
PRS_SEEDED=-1

# --- First-boot state bootstrapping ---
# When state files are empty (fresh install), seed them with all currently
# open issues/PRs so the poller doesn't treat the entire backlog as new.
# Also triggers when --seed-state is passed (force re-seed).
if [[ ! -s "$SCRIPT_DIR/state/processed-issues.txt" || "$FORCE_SEED" == "true" ]]; then
    if [[ "$FORCE_SEED" == "true" && -s "$SCRIPT_DIR/state/processed-issues.txt" ]]; then
        log_info "Force re-seed requested — backing up existing issue state files to state/*.bak..."
        for f in processed-issues.txt processed-auto-triage.txt processed-work.txt processed-research.txt processed-write-tests.txt; do
            [[ -s "$SCRIPT_DIR/state/$f" ]] && cp "$SCRIPT_DIR/state/$f" "$SCRIPT_DIR/state/${f}.bak"
        done
    fi
    if [[ "$FORCE_SEED" == "true" ]]; then
        log_info "Force re-seed — seeding existing issues as already processed..."
    else
        log_info "First boot detected — seeding existing issues as already processed..."
    fi
    SEED_COUNT=0
    while IFS= read -r proj; do
        [[ -z "$proj" ]] && continue
        while IFS=$'\t' read -r repo local_path repo_type; do
            [[ -z "$repo" ]] && continue
            # Seed open issues
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
    # Deduplicate
    for f in processed-issues.txt processed-auto-triage.txt processed-work.txt processed-research.txt processed-write-tests.txt; do
        sort -u -o "$SCRIPT_DIR/state/$f" "$SCRIPT_DIR/state/$f" 2>/dev/null || true
    done
    if [[ $SEED_COUNT -eq 0 ]]; then
        log_warn "No issues seeded — check gh CLI auth if repos have open issues"
    else
        log_info "Seeded $SEED_COUNT existing issues across all repos"
    fi
    ISSUES_SEEDED=$SEED_COUNT
else
    log_info "Issue state files already seeded — skipping (use --seed-state to force re-seed)"
fi

# Same for PRs (also seeds processed-rework.txt for any open rework PRs)
if [[ ! -s "$SCRIPT_DIR/state/processed-prs.txt" || "$FORCE_SEED" == "true" ]]; then
    if [[ "$FORCE_SEED" == "true" && -s "$SCRIPT_DIR/state/processed-prs.txt" ]]; then
        log_info "Force re-seed requested — backing up existing PR state files to state/*.bak..."
        for f in processed-prs.txt processed-rework.txt; do
            [[ -s "$SCRIPT_DIR/state/$f" ]] && cp "$SCRIPT_DIR/state/$f" "$SCRIPT_DIR/state/${f}.bak"
        done
    fi
    if [[ "$FORCE_SEED" == "true" ]]; then
        log_info "Force re-seed — seeding existing PRs as already processed..."
    else
        log_info "First boot detected — seeding existing PRs as already processed..."
    fi
    PR_SEED_COUNT=0
    while IFS= read -r proj; do
        [[ -z "$proj" ]] && continue
        while IFS=$'\t' read -r repo local_path repo_type; do
            [[ -z "$repo" ]] && continue
            while IFS= read -r num; do
                [[ -z "$num" ]] && continue
                echo "${repo}#${num}" >> "$SCRIPT_DIR/state/processed-prs.txt"
                echo "${repo}#pr${num}" >> "$SCRIPT_DIR/state/processed-rework.txt"
                PR_SEED_COUNT=$((PR_SEED_COUNT + 1))
            done < <(gh pr list --repo "$repo" --state open --limit 500 --json number --jq '.[].number' 2>/dev/null || true)
        done < <(read_repos "$proj")
    done < <(read_projects)
    sort -u -o "$SCRIPT_DIR/state/processed-prs.txt" "$SCRIPT_DIR/state/processed-prs.txt" 2>/dev/null || true
    sort -u -o "$SCRIPT_DIR/state/processed-rework.txt" "$SCRIPT_DIR/state/processed-rework.txt" 2>/dev/null || true
    if [[ $PR_SEED_COUNT -eq 0 ]]; then
        log_warn "No PRs seeded — check gh CLI auth if repos have open PRs"
    else
        log_info "Seeded $PR_SEED_COUNT existing PRs across all repos"
    fi
    PRS_SEEDED=$PR_SEED_COUNT
else
    log_info "PR state files already seeded — skipping (use --seed-state to force re-seed)"
fi

# --- Step 8: Install Crontab ---
echo "[7/9] Installing crontab..."

# Read existing crontab, stripping everything between our marker comments
EXISTING_CRON=$(crontab -l 2>/dev/null | sed '/^# --- Zapat/,/^# --- End Zapat/d' || true)

# Build new crontab
NEW_CRON="${EXISTING_CRON}
# --- Zapat (managed by startup.sh) ---
# Daily standup Mon-Fri 8 AM
0 8 * * 1-5 ${SCRIPT_DIR}/jobs/daily-standup.sh >> ${SCRIPT_DIR}/logs/cron-daily.log 2>&1
# Weekly planning Monday 9 AM
0 9 * * 1 ${SCRIPT_DIR}/jobs/weekly-planning.sh >> ${SCRIPT_DIR}/logs/cron-weekly.log 2>&1
# Monthly strategy 1st of month 10 AM
0 10 1 * * ${SCRIPT_DIR}/jobs/monthly-strategy.sh >> ${SCRIPT_DIR}/logs/cron-monthly.log 2>&1
# GitHub polling (configurable via POLL_INTERVAL_MINUTES, default 2)
*/${POLL_INTERVAL_MINUTES:-2} * * * * ${SCRIPT_DIR}/bin/poll-github.sh >> ${SCRIPT_DIR}/logs/cron-poll.log 2>&1
# Weekly security scan Sunday 6 AM
0 6 * * 0 ${SCRIPT_DIR}/bin/run-agent.sh --job-name weekly-security-scan --prompt-file ${SCRIPT_DIR}/prompts/weekly-security-scan.txt --budget \${MAX_BUDGET_SECURITY_SCAN:-15} --allowed-tools Read,Glob,Grep,Bash --timeout 1800 --notify slack >> ${SCRIPT_DIR}/logs/cron-security.log 2>&1
# Daily health digest at 8:05 AM
5 8 * * * cd ${SCRIPT_DIR} && node bin/zapat status --slack >> ${SCRIPT_DIR}/logs/cron-digest.log 2>&1
# Log rotation weekly Sunday 3 AM
0 3 * * 0 cd ${SCRIPT_DIR} && node bin/zapat logs rotate >> ${SCRIPT_DIR}/logs/cron-rotation.log 2>&1
# Health check every 30 minutes with auto-fix
*/30 * * * * cd ${SCRIPT_DIR} && node bin/zapat health --auto-fix >> ${SCRIPT_DIR}/logs/cron-health.log 2>&1
# --- End Zapat ---"

echo "$NEW_CRON" | crontab -
log_info "Crontab installed (8 entries)"

# --- Step 9: Dashboard Server ---
echo "[8/9] Starting dashboard server..."
DASHBOARD_PORT=${DASHBOARD_PORT:-8080}
DASHBOARD_HOST=${DASHBOARD_HOST:-127.0.0.1}
DASHBOARD_DIR="${SCRIPT_DIR}/dashboard"
DASHBOARD_PID_FILE="${SCRIPT_DIR}/state/dashboard.pid"
DASHBOARD_LOG="${SCRIPT_DIR}/logs/dashboard.log"

# Kill any existing dashboard server
if [[ -f "$DASHBOARD_PID_FILE" ]]; then
    OLD_PID=$(cat "$DASHBOARD_PID_FILE" 2>/dev/null)
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$DASHBOARD_PID_FILE"
fi
if lsof -ti:"${DASHBOARD_PORT}" &>/dev/null; then
    kill "$(lsof -ti:"${DASHBOARD_PORT}")" 2>/dev/null || true
    sleep 1
fi

# Start dashboard as a background process
if [[ -d "$DASHBOARD_DIR/.next" ]]; then
    cd "$DASHBOARD_DIR"
    AUTOMATION_DIR="$SCRIPT_DIR" nohup npx next start -H "$DASHBOARD_HOST" -p "$DASHBOARD_PORT" \
        >> "$DASHBOARD_LOG" 2>&1 &
    echo $! > "$DASHBOARD_PID_FILE"
    cd "$SCRIPT_DIR"
    log_info "Dashboard server started on ${DASHBOARD_HOST}:${DASHBOARD_PORT} (PID: $(cat "$DASHBOARD_PID_FILE"))"
else
    log_warn "Dashboard not built yet — run: cd $DASHBOARD_DIR && npm run build"
fi

# --- Notify ---
if [[ -n "${SLACK_WEBHOOK_URL:-}" && "$SLACK_WEBHOOK_URL" != *"YOUR"* ]]; then
    "$SCRIPT_DIR/bin/notify.sh" \
        --slack \
        --message "Agent automation started on $(hostname) at $(date '+%Y-%m-%d %H:%M:%S'). All systems operational. Repos pulled: $PULL_SUCCESS, Cron jobs: 8." \
        --job-name "startup" \
        --status success || log_warn "Slack notification failed (webhook may not be configured yet)"
fi

# --- Summary ---
echo ""
echo "============================================"
echo "  Startup Complete"
echo "============================================"
echo ""
echo "  tmux session:  zapat"
echo "  Repos pulled:  $PULL_SUCCESS / $((PULL_SUCCESS + PULL_FAIL))"
echo "  Cron jobs:     8 installed"
echo "  Dashboard:     http://$(hostname):${DASHBOARD_PORT:-8080}"
# Build dynamic state file summary
if [[ $ISSUES_SEEDED -ge 0 || $PRS_SEEDED -ge 0 ]]; then
    SEED_PARTS=""
    [[ $ISSUES_SEEDED -ge 0 ]] && SEED_PARTS="${ISSUES_SEEDED} issues"
    [[ $PRS_SEEDED -ge 0 ]] && SEED_PARTS="${SEED_PARTS:+${SEED_PARTS}, }${PRS_SEEDED} PRs"
    if [[ "$FORCE_SEED" == "true" ]]; then
        echo "  State files:   re-seeded (${SEED_PARTS})"
    else
        echo "  State files:   seeded (${SEED_PARTS})"
    fi
else
    echo "  State files:   already initialized"
fi
echo ""
echo "  Verify cron:   crontab -l"
echo "  View logs:     ls ${SCRIPT_DIR}/logs/"
echo "  Manual test:   ${SCRIPT_DIR}/jobs/daily-standup.sh"
echo ""
echo "  To attach to tmux: tmux attach -t zapat"
echo ""
