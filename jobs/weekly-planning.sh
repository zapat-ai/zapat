#!/usr/bin/env bash
# Zapat - Weekly Planning
# Runs Monday at 9 AM via cron

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env

while IFS= read -r project_slug; do
    [[ -z "$project_slug" ]] && continue
    "$SCRIPT_DIR/bin/run-agent.sh" \
        --job-name "weekly-planning" \
        --prompt-file "$SCRIPT_DIR/prompts/weekly-planning.txt" \
        --budget "${MAX_BUDGET_WEEKLY_PLANNING:-15}" \
        --allowed-tools "Bash,Read,Glob,Grep" \
        --notify slack \
        --timeout "${TIMEOUT_WEEKLY_PLANNING:-900}" \
        --project "$project_slug"
done < <(read_projects)
