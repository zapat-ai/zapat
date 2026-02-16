#!/usr/bin/env bash
# Zapat - Daily Standup
# Runs Mon-Fri at 8 AM via cron

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env

while IFS= read -r project_slug; do
    [[ -z "$project_slug" ]] && continue
    "$SCRIPT_DIR/bin/run-agent.sh" \
        --job-name "daily-standup" \
        --prompt-file "$SCRIPT_DIR/prompts/daily-standup.txt" \
        --budget "${MAX_BUDGET_DAILY_STANDUP:-5}" \
        --allowed-tools "Bash,Read,Glob,Grep" \
        --notify slack \
        --timeout "${TIMEOUT_DAILY_STANDUP:-600}" \
        --project "$project_slug"
done < <(read_projects)
