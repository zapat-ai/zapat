# Pipeline Health Check

Run a quick health check on the Zapat pipeline and report results conversationally.

## Locate Zapat

First, find the Zapat installation:

```bash
if [ -n "$ZAPAT_HOME" ] && [ -d "$ZAPAT_HOME" ]; then
  echo "FOUND:$ZAPAT_HOME"
elif [ -d "$HOME/.zapat" ]; then
  echo "FOUND:$HOME/.zapat"
elif [ -f "./bin/zapat" ] && [ -f "./package.json" ] && grep -q '"name": "zapat"' ./package.json 2>/dev/null; then
  echo "FOUND:$(pwd)"
else
  echo "NOT_FOUND"
fi
```

If NOT_FOUND, tell the user: "Zapat isn't installed yet. Run `/zapat:setup` first to set it up."

Set `ZAPAT_HOME` to the found path. All paths below are relative to `$ZAPAT_HOME`.

## Steps

1. Run pipeline status:
   ```bash
   $ZAPAT_HOME/bin/zapat status
   ```
   Summarize the output: how many active sessions, recent job success rate, any items in progress.

2. Run health checks:
   ```bash
   $ZAPAT_HOME/bin/zapat health
   ```
   Summarize each check result. For any failures, explain what the issue means in plain language.

3. If any health checks failed, suggest fixes:
   - **tmux-session** failed: "The tmux session is missing. Run `$ZAPAT_HOME/bin/startup.sh` to recreate it."
   - **orphaned-worktrees**: "There are leftover git worktrees from crashed sessions. Run `$ZAPAT_HOME/bin/zapat health --auto-fix` to clean them up."
   - **stale-slots**: "Some agent slot files are stale (the process died). Run `$ZAPAT_HOME/bin/zapat health --auto-fix` to reclaim them."
   - **gh-auth** failed: "GitHub CLI is not authenticated. Run `gh auth login` to fix."
   - **failed-items**: "Some items failed processing. Check the logs with `ls -lt $ZAPAT_HOME/logs/` and review the most recent failure."
   - **cron-job** missing: "The cron job is not installed. Run `$ZAPAT_HOME/bin/startup.sh` to set it up."

4. If all checks pass, say something like:
   "Pipeline is healthy. All checks passed. [N] sessions active, [X]% success rate over the last 24 hours."

5. Ask if they want to run auto-fix for any issues:
   ```bash
   $ZAPAT_HOME/bin/zapat health --auto-fix
   ```
