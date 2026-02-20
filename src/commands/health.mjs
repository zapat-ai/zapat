import { readdirSync, readFileSync, existsSync, statSync, unlinkSync, rmdirSync, writeFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { getAutomationDir, getConfigValue, getRepos } from '../lib/config.mjs';
import { exec, execFull } from '../lib/exec.mjs';

export function registerHealthCommand(program) {
  program
    .command('health')
    .description('Check pipeline health and detect issues')
    .option('--auto-fix', 'Automatically fix detected issues')
    .option('--slack', 'Output formatted for Slack')
    .option('--json', 'Output as JSON')
    .action(runHealth);
}

function runHealth(opts, cmd) {
  const projectFilter = cmd?.parent?.opts()?.project || undefined;
  const checks = [];

  checks.push(checkTmuxSession(opts.autoFix));
  checks.push(checkOrphanedWindows(opts.autoFix));
  checks.push(checkStuckPanes(opts.autoFix));
  checks.push(checkStaleSlots(opts.autoFix));
  checks.push(checkOrphanedWorktrees(opts.autoFix));
  checks.push(checkGhAuth());
  checks.push(checkAgentTeamsSetting(opts.autoFix));
  checks.push(checkFailedItems(projectFilter));

  const hasIssues = checks.some(c => c.status !== 'ok');
  const hasUnfixed = checks.some(c => c.status === 'error');

  const result = {
    healthy: !hasUnfixed,
    checks,
    summary: hasUnfixed
      ? `${checks.filter(c => c.status === 'error').length} issue(s) found`
      : hasIssues
        ? 'All issues auto-fixed'
        : 'All checks passed'
  };

  if (opts.json) {
    console.log(JSON.stringify(result, null, 2));
  } else if (opts.slack) {
    const icon = result.healthy ? ':white_check_mark:' : ':rotating_light:';
    const lines = [`${icon} *Health Check: ${result.summary}*`];
    for (const c of checks) {
      const emoji = c.status === 'ok' ? ':white_check_mark:' : c.status === 'fixed' ? ':wrench:' : c.status === 'warn' ? ':warning:' : ':x:';
      lines.push(`${emoji} ${c.name}: ${c.message}`);
    }
    console.log(lines.join('\n'));
  } else {
    console.log(`Health: ${result.summary}`);
    console.log('');
    for (const c of checks) {
      const icon = c.status === 'ok' ? '[ok]' : c.status === 'fixed' ? '[FIXED]' : c.status === 'warn' ? '[WARN]' : '[FAIL]';
      console.log(`  ${icon} ${c.name}: ${c.message}`);
    }
  }

  process.exitCode = hasUnfixed ? 1 : 0;
}

function checkTmuxSession(autoFix) {
  const result = exec('tmux has-session -t zapat 2>&1');
  const exists = exec('tmux has-session -t zapat') !== null;

  // tmux has-session returns 0 if session exists; exec returns null on non-zero exit
  const sessionCheck = execFull('tmux has-session -t zapat');

  if (sessionCheck.exitCode === 0) {
    return { name: 'tmux-session', status: 'ok', message: 'Session exists' };
  }

  if (autoFix) {
    const fix = exec('tmux new-session -d -s zapat -n control');
    if (fix !== null) {
      return { name: 'tmux-session', status: 'fixed', message: 'Session recreated' };
    }
  }

  return { name: 'tmux-session', status: 'error', message: 'Session not found. Run startup.sh or use --auto-fix.' };
}

function checkOrphanedWindows(autoFix) {
  const windowList = exec('tmux list-windows -t zapat -F "#{window_index}:#{window_name}:#{window_activity}"');
  if (!windowList) {
    return { name: 'orphaned-windows', status: 'ok', message: 'No tmux session to check' };
  }

  // Default timeout is 30 min (1800s), consider orphaned at 1.5x
  const timeout = parseInt(getConfigValue('TIMEOUT_IMPLEMENT', '1800'));
  const orphanThreshold = timeout * 1.5;
  const now = Math.floor(Date.now() / 1000);

  const windows = windowList.split('\n').filter(Boolean);
  const orphaned = [];

  for (const line of windows) {
    const [index, name, lastActivity] = line.split(':');
    // Skip the control window
    if (name === 'control') continue;

    const activityTs = parseInt(lastActivity);
    if (activityTs && (now - activityTs) > orphanThreshold) {
      orphaned.push({ index: parseInt(index), name, idleSeconds: now - activityTs });
    }
  }

  if (orphaned.length === 0) {
    return { name: 'orphaned-windows', status: 'ok', message: 'No orphaned windows' };
  }

  if (autoFix) {
    let killed = 0;
    for (const w of orphaned) {
      const result = exec(`tmux kill-window -t zapat:${w.index}`);
      if (result !== null) killed++;
    }
    return { name: 'orphaned-windows', status: 'fixed', message: `Killed ${killed} orphaned window(s)` };
  }

  return {
    name: 'orphaned-windows',
    status: 'error',
    message: `${orphaned.length} orphaned window(s): ${orphaned.map(w => w.name).join(', ')}`
  };
}

function checkStuckPanes(autoFix) {
  // Patterns mirrored from lib/tmux-helpers.sh PANE_PATTERN_* constants
  const PATTERN_PERMISSION = /Allow once|Allow always|Do you want to allow|Do you want to (create|make|proceed|run|write|edit)|wants to use the .* tool|approve this action|Waiting for team lead approval/;
  const PATTERN_RATE_LIMIT = /Switch to extra|Rate limit|rate_limit|429|Too Many Requests|Retry after/;
  const PATTERN_ACCOUNT_LIMIT = /out of extra usage|resets [0-9]|usage limit|plan limit|You've reached/;
  const PATTERN_FATAL = /FATAL|OOM|out of memory|Segmentation fault|core dumped|panic:|SIGKILL/;

  const paneList = exec('tmux list-panes -a -t zapat -F "#{window_name}.#{pane_index}" 2>/dev/null');
  if (!paneList) {
    return { name: 'stuck-panes', status: 'ok', message: 'No panes to check' };
  }

  const panes = paneList.split('\n').filter(Boolean);
  const stuck = [];

  for (const paneId of panes) {
    // Skip the control/bash window
    const windowName = paneId.split('.')[0];
    if (windowName === 'bash' || windowName === 'control') continue;

    const content = exec(`tmux capture-pane -t "zapat:${paneId}" -p -l 50 2>/dev/null`);
    if (!content) continue;

    let issue = null;
    if (PATTERN_PERMISSION.test(content)) issue = 'permission prompt';
    else if (PATTERN_RATE_LIMIT.test(content)) issue = 'rate limit';
    else if (PATTERN_ACCOUNT_LIMIT.test(content)) issue = 'account limit';
    else if (PATTERN_FATAL.test(content)) issue = 'fatal error';

    if (issue) {
      stuck.push({ paneId, issue });
    }
  }

  if (stuck.length === 0) {
    return { name: 'stuck-panes', status: 'ok', message: 'No stuck panes' };
  }

  if (autoFix) {
    // Kill the windows containing stuck panes
    const killedWindows = new Set();
    for (const s of stuck) {
      const windowName = s.paneId.split('.')[0];
      if (!killedWindows.has(windowName)) {
        exec(`tmux kill-window -t "zapat:${windowName}" 2>/dev/null`);
        killedWindows.add(windowName);
      }
    }
    return { name: 'stuck-panes', status: 'fixed', message: `Killed ${killedWindows.size} window(s) with ${stuck.length} stuck pane(s)` };
  }

  const details = stuck.map(s => `${s.paneId}: ${s.issue}`).join('; ');
  return {
    name: 'stuck-panes',
    status: 'error',
    message: `${stuck.length} stuck pane(s): ${details}`
  };
}

function checkStaleSlots(autoFix) {
  const slotDir = join(getAutomationDir(), 'state', 'agent-work-slots');
  if (!existsSync(slotDir)) {
    return { name: 'stale-slots', status: 'ok', message: 'No slot directory' };
  }

  const files = readdirSync(slotDir).filter(f => f.endsWith('.pid'));
  const stale = [];

  for (const f of files) {
    const filepath = join(slotDir, f);
    try {
      const pid = readFileSync(filepath, 'utf-8').trim();
      if (pid) {
        const check = execFull(`kill -0 ${pid}`);
        if (check.exitCode !== 0) {
          stale.push({ file: f, pid });
        }
      } else {
        stale.push({ file: f, pid: 'empty' });
      }
    } catch {
      stale.push({ file: f, pid: 'unreadable' });
    }
  }

  if (stale.length === 0) {
    return { name: 'stale-slots', status: 'ok', message: `${files.length} active slot(s), none stale` };
  }

  if (autoFix) {
    for (const s of stale) {
      try { unlinkSync(join(slotDir, s.file)); } catch { /* ignore */ }
    }
    return { name: 'stale-slots', status: 'fixed', message: `Cleaned ${stale.length} stale slot(s)` };
  }

  return {
    name: 'stale-slots',
    status: 'error',
    message: `${stale.length} stale slot(s): ${stale.map(s => `${s.file}(pid:${s.pid})`).join(', ')}`
  };
}

function checkOrphanedWorktrees(autoFix) {
  const worktreeDir = join(getAutomationDir(), 'worktrees');
  if (!existsSync(worktreeDir)) {
    return { name: 'orphaned-worktrees', status: 'ok', message: 'No worktree directory' };
  }

  let entries;
  try {
    entries = readdirSync(worktreeDir);
  } catch {
    return { name: 'orphaned-worktrees', status: 'ok', message: 'Cannot read worktree directory' };
  }

  const twoHoursAgo = Date.now() - 2 * 60 * 60 * 1000;
  const orphaned = [];

  for (const entry of entries) {
    const fullPath = join(worktreeDir, entry);
    try {
      const stat = statSync(fullPath);
      if (stat.isDirectory() && stat.mtimeMs < twoHoursAgo) {
        orphaned.push(entry);
      }
    } catch { /* ignore */ }
  }

  if (orphaned.length === 0) {
    return { name: 'orphaned-worktrees', status: 'ok', message: `${entries.length} worktree(s), none orphaned` };
  }

  if (autoFix) {
    let removed = 0;
    for (const dir of orphaned) {
      const result = exec(`rm -rf "${join(worktreeDir, dir)}"`);
      if (result !== null) removed++;
    }
    // Prune git worktree references in all repos across all projects
    for (const r of getRepos()) {
      if (r.localPath && existsSync(r.localPath)) {
        exec(`git -C "${r.localPath}" worktree prune 2>/dev/null`);
      }
    }
    return { name: 'orphaned-worktrees', status: 'fixed', message: `Removed ${removed} orphaned worktree(s)` };
  }

  return {
    name: 'orphaned-worktrees',
    status: 'error',
    message: `${orphaned.length} orphaned worktree(s) older than 2h`
  };
}

function checkGhAuth() {
  const result = execFull('gh auth status');
  if (result.exitCode === 0) {
    return { name: 'gh-auth', status: 'ok', message: 'GitHub CLI authenticated' };
  }

  return {
    name: 'gh-auth',
    status: 'error',
    message: 'GitHub CLI not authenticated. Run: gh auth login'
  };
}

function checkAgentTeamsSetting(autoFix) {
  const settingsPath = join(homedir(), '.claude', 'settings.json');

  if (!existsSync(settingsPath)) {
    if (autoFix) {
      try {
        const settings = { env: { CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1' } };
        const dir = join(homedir(), '.claude');
        if (!existsSync(dir)) { exec(`mkdir -p "${dir}"`); }
        writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
        return { name: 'agent-teams', status: 'fixed', message: 'Created settings.json with agent teams enabled' };
      } catch {
        return { name: 'agent-teams', status: 'warn', message: 'Settings file not found. Agent teams may not work.' };
      }
    }
    return { name: 'agent-teams', status: 'warn', message: 'Settings file not found at ~/.claude/settings.json. Agent teams may not work.' };
  }

  try {
    const settings = JSON.parse(readFileSync(settingsPath, 'utf-8'));
    const value = settings?.env?.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS;

    if (value === '1') {
      return { name: 'agent-teams', status: 'ok', message: 'Agent teams enabled in Claude Code settings' };
    }

    if (autoFix) {
      if (!settings.env) settings.env = {};
      settings.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = '1';
      writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
      return { name: 'agent-teams', status: 'fixed', message: 'Enabled agent teams in Claude Code settings' };
    }

    return {
      name: 'agent-teams',
      status: 'warn',
      message: 'Agent teams not enabled. Run with --auto-fix or add "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } to ~/.claude/settings.json'
    };
  } catch {
    return { name: 'agent-teams', status: 'warn', message: 'Could not parse ~/.claude/settings.json' };
  }
}

function checkFailedItems(projectFilter) {
  const itemsDir = join(getAutomationDir(), 'state', 'items');
  if (!existsSync(itemsDir)) {
    return { name: 'failed-items', status: 'ok', message: 'No items directory' };
  }

  let files = readdirSync(itemsDir).filter(f => f.endsWith('.json'));

  // Filter by project if specified
  if (projectFilter) {
    files = files.filter(f => {
      try {
        const data = JSON.parse(readFileSync(join(itemsDir, f), 'utf-8'));
        return (data.project || 'default') === projectFilter;
      } catch {
        return f.startsWith(`${projectFilter}--`) || (!f.includes('--') && projectFilter === 'default');
      }
    });
  }

  const failed = files.filter(f => {
    try {
      const data = JSON.parse(readFileSync(join(itemsDir, f), 'utf-8'));
      return data.status === 'failed' || data.status === 'abandoned';
    } catch {
      return f.includes('failed') || f.includes('abandoned');
    }
  });

  if (failed.length === 0) {
    return { name: 'failed-items', status: 'ok', message: 'No failed items' };
  }

  if (failed.length > 3) {
    return {
      name: 'failed-items',
      status: 'error',
      message: `${failed.length} failed/abandoned items (threshold: 3). Review state/items/ for stuck work.`
    };
  }

  return {
    name: 'failed-items',
    status: 'ok',
    message: `${failed.length} failed item(s) (below threshold)`
  };
}
