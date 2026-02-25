# COE: Ghost Window — Triage Job Silently Dropped

**Date:** 2026-02-24
**Severity:** P3 — Single job silently dropped, no user-facing impact, required manual reset
**Duration:** ~70 minutes (20:00 dispatch → 21:11 manual reset)
**Impact:** Issue soapnoteaicom/CdkSOAPNoteAIRepoV2#128 was not triaged. Item stuck in limbo — not failed, not retried.

---

## Summary

A triage job for issue #128 was dispatched to a tmux window, but the `claude` process inside the window exited immediately. Because tmux destroys command-bearing windows when their process exits, the window vanished within seconds. The trigger script then crashed on `tmux send-keys` to the now-dead window, but the EXIT trap swallowed the error code — leaving the item state as `"running"` instead of `"failed"`. The poller skipped it on subsequent cycles (already processed), and the 45-minute stale-item timeout never fired because the pipeline was restarted before it could trigger. The item was stuck until manually reset.

---

## Timeline

| Time (local) | Event |
|------|-------|
| 19:58:28 | `zapat` tmux session created (fresh start via `startup.sh`) |
| 20:00:44 | Poller finds issue #128, creates item state as `"pending"` |
| 20:00:45 | `on-new-issue.sh` dispatched for triage, item set to `"running"` |
| 20:00:48 | Readonly worktree created at `~/.zapat/worktrees/CdkSOAPNoteAIRepoV2-triage-128` |
| 20:00:49 | `tmux new-window` succeeds — window `triage-CdkSOAPNoteAIRepoV2-128` created |
| 20:00:49 | Sleep fallback path entered (5-second wait) |
| ~20:00:50 | `claude` process inside window exits immediately — tmux destroys the window |
| ~20:00:54 | `tmux send-keys` fails: `can't find window: triage-CdkSOAPNoteAIRepoV2-128` |
| ~20:00:54 | `set -e` kills the trigger script. EXIT trap runs. |
| ~20:00:54 | Trap calls `cleanup_readonly_worktree` (succeeds, rc=0), then `cleanup_on_exit "" "$ITEM_STATE_FILE" 0` — item NOT marked failed because rc=0 |
| 20:02–20:08 | Subsequent poll cycles skip #128 (already in processed items) |
| 21:11:18 | Manual reset of item state to `"pending"` |

---

## 5 Whys

### Why 1: Why was issue #128 not triaged?
The triage tmux window died immediately after creation, and the pipeline never retried the job.

### Why 2: Why did the tmux window die immediately?
`tmux new-window -t session -n name "$cmd"` ties the window lifecycle to the command. Claude showed a "Do you trust this folder?" dialog with "Yes, I trust this folder" as the default (option 1). The sleep fallback sent `Down` then `Enter` — which moved to option 2 ("No, exit") and confirmed it, killing Claude. There was also **no existence check** after window creation.

### Why 3: Why didn't the trigger script detect the failure and mark the item as failed?
Two compounding bugs in the EXIT trap at `on-new-issue.sh:91-94`:

1. **Lost exit code:** The trap runs `cleanup_readonly_worktree` first (which succeeds, rc=0), then passes `$?` (now 0) to `cleanup_on_exit`. The original non-zero exit code from `set -e` is lost.
2. **Lost slot file:** The trap passes `""` instead of `$SLOT_FILE`, so the slot isn't released (relies on stale-slot cleanup with a 12-minute delay).

### Why 4: Why didn't the retry mechanism pick it up?
The item state stayed `"running"` (not `"failed"` with a retry timer). The poller's `should_process_item` only retries items with status `"failed"` and an expired `next_retry_after`. A `"running"` item is skipped unless it exceeds `STALE_RUNNING_MINUTES` (45 min default) — but the pipeline hadn't been running long enough for that to trigger.

### Why 5: Why does the sleep fallback path have no window-alive guard?
The sleep fallback (`TMUX_USE_SLEEP_FALLBACK=1`) was a legacy code path that predates the dynamic `wait_for_tmux_content` approach. It was never hardened because it was considered temporary. However, it is still the active path when the fallback flag is set, and it has **zero error handling** between window creation and key-sending.

---

## Root Causes

| # | Cause | Location | Type |
|---|-------|----------|------|
| # | Cause | Location | Type |
|---|-------|----------|------|
| 1 | **`Down` keystroke selects "No, exit" in trust dialog** | `lib/tmux-helpers.sh:96` (sleep fallback) and `:130,:141` (dynamic path) | Bug — "Yes" is already the default; `Down` moves to "No, exit" |
| 2 | **No window-alive check after `tmux new-window`** | `lib/tmux-helpers.sh:80-87` | Missing validation |
| 3 | **EXIT trap loses original exit code** | `triggers/on-new-issue.sh:91-94` | Bug — `$?` captures worktree cleanup rc, not the triggering error |
| 4 | **EXIT trap drops `$SLOT_FILE` reference** | `triggers/on-new-issue.sh:93` | Bug — passes `""` instead of `$SLOT_FILE` |
| 5 | **Sleep fallback path has no error handling** | `lib/tmux-helpers.sh:83-96` | Tech debt — legacy path never hardened |

---

## Remediation

### Immediate (prevent recurrence)

1. **Add window-alive guard in `launch_claude_session`** — After `tmux new-window`, sleep 1s and verify the window exists with `tmux has-window`. If dead, log the failure and return 1.

   ```bash
   # After line 81 in tmux-helpers.sh
   sleep 1
   if ! tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qF "$window"; then
       log_error "Window '$window' died immediately after creation — claude process likely failed to start"
       return 1
   fi
   ```

2. **Fix the EXIT trap to preserve exit code** — Capture `$?` before running cleanup commands.

   ```bash
   # on-new-issue.sh line 91
   trap '
       _exit_rc=$?
       [[ -n "${READONLY_WORKTREE:-}" ]] && cleanup_readonly_worktree "$REPO_PATH" "$READONLY_WORKTREE"
       cleanup_on_exit "$SLOT_FILE" "$ITEM_STATE_FILE" $_exit_rc
   ' EXIT
   ```

3. **Same trap fix needed in all trigger scripts** — Audit `on-work-issue.sh`, `on-new-pr.sh`, `on-rework.sh`, `on-test.sh` for the same pattern.

### Medium-term (defense in depth)

4. **Use `remain-on-exit` for tmux windows** — Set `tmux set-window-option remain-on-exit on` so dead windows persist for post-mortem inspection instead of vanishing.

5. **Reduce `STALE_RUNNING_MINUTES` for triage jobs** — Triage should complete in <10 min. A dedicated stale timeout of 15 min for triage would have caught this sooner.

6. **Add a structured log entry on window death** — Emit a metrics event (`job_launch_failed`) to `data/metrics.jsonl` so the dashboard can track launch failures.

---

## Affected Trigger Scripts (same trap bug)

All trigger scripts that override the initial EXIT trap are potentially affected:

- `triggers/on-new-issue.sh:91`
- `triggers/on-work-issue.sh` (check for similar pattern)
- `triggers/on-new-pr.sh` (check for similar pattern)
- `triggers/on-rework.sh` (check for similar pattern)
- `triggers/on-test.sh` (check for similar pattern)

---

## Lessons Learned

1. **tmux command-bearing windows are ephemeral** — Never assume a `tmux new-window "cmd"` window survives. Always verify.
2. **EXIT traps must preserve `$?` first** — Any cleanup before `$?` is read will overwrite the original exit code.
3. **Legacy code paths need the same hardening as primary paths** — The sleep fallback was "temporary" but still active and less robust.
4. **Silent failures are worse than loud failures** — This item sat in limbo for 70 minutes. A clear "FAILED" state with a retry timer would have self-healed.
