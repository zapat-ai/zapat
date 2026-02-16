# Pipeline Health Check

Run a quick health check on the Zapat pipeline and report results conversationally.

## Steps

1. Run pipeline status:
   ```bash
   bin/zapat status
   ```
   Summarize the output: how many active sessions, recent job success rate, any items in progress.

2. Run health checks:
   ```bash
   bin/zapat health
   ```
   Summarize each check result. For any failures, explain what the issue means in plain language.

3. If any health checks failed, suggest fixes:
   - **tmux-session** failed: "The tmux session is missing. Run `bin/startup.sh` to recreate it."
   - **orphaned-worktrees**: "There are leftover git worktrees from crashed sessions. Run `bin/zapat health --auto-fix` to clean them up."
   - **stale-slots**: "Some agent slot files are stale (the process died). Run `bin/zapat health --auto-fix` to reclaim them."
   - **gh-auth** failed: "GitHub CLI is not authenticated. Run `gh auth login` to fix."
   - **failed-items**: "Some items failed processing. Check the logs with `ls -lt logs/` and review the most recent failure."
   - **cron-job** missing: "The cron job is not installed. Run `bin/startup.sh` to set it up."

4. If all checks pass, say something like:
   "Pipeline is healthy. All checks passed. [N] sessions active, [X]% success rate over the last 24 hours."

5. Ask if they want to run auto-fix for any issues:
   ```bash
   bin/zapat health --auto-fix
   ```
