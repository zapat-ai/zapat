#!/usr/bin/env bash
# Zapat - Monthly Strategy
# Runs 1st of month at 10 AM via cron

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env

while IFS= read -r project_slug; do
    [[ -z "$project_slug" ]] && continue
    "$SCRIPT_DIR/bin/run-agent.sh" \
        --job-name "monthly-strategy" \
        --prompt-file "$SCRIPT_DIR/prompts/monthly-strategy.txt" \
        --budget "${MAX_BUDGET_MONTHLY_STRATEGY:-25}" \
        --allowed-tools "Bash,Read,Glob,Grep,WebSearch" \
        --notify slack \
        --timeout "${TIMEOUT_MONTHLY_STRATEGY:-1200}" \
        --model "${CLAUDE_UTILITY_MODEL:-claude-haiku-4-5-20251001}" \
        --project "$project_slug"
done < <(read_projects)
