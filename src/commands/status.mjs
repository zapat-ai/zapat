import { readdirSync, readFileSync, existsSync, statSync } from 'fs';
import { join } from 'path';
import { getAutomationDir, getConfigValue, getProjects } from '../lib/config.mjs';
import { readMetrics } from '../lib/metrics.mjs';
import { exec } from '../lib/exec.mjs';

export function registerStatusCommand(program) {
  program
    .command('status')
    .description('Show pipeline status overview')
    .option('--json', 'Output as JSON')
    .option('--slack', 'Output formatted for Slack')
    .option('--brief', 'One-line summary')
    .action(runStatus);
}

function getTmuxWindows() {
  const result = exec('tmux list-windows -t zapat -F "#{window_index}:#{window_name}:#{window_active}"');
  if (!result) return [];
  return result.split('\n').filter(Boolean).map(line => {
    const [index, name, active] = line.split(':');
    return { index: parseInt(index), name, active: active === '1' };
  });
}

function getSlotUsage() {
  const dir = join(getAutomationDir(), 'state', 'agent-work-slots');
  if (!existsSync(dir)) return { active: 0, max: 10, slots: [] };

  const max = parseInt(getConfigValue('MAX_CONCURRENT_WORK', '10'));
  const files = readdirSync(dir).filter(f => f.endsWith('.pid'));
  return { active: files.length, max, slots: files };
}

function getLastPollTime() {
  const lockPath = join(getAutomationDir(), 'state', 'poll.lock');
  if (existsSync(lockPath)) {
    const stat = statSync(lockPath);
    return { running: true, since: stat.mtime.toISOString() };
  }

  // Check cron log for last poll
  const logsDir = join(getAutomationDir(), 'logs');
  if (!existsSync(logsDir)) return { running: false, lastRun: null };

  const logFiles = readdirSync(logsDir)
    .filter(f => f.startsWith('github-poll'))
    .sort()
    .reverse();

  if (logFiles.length > 0) {
    const stat = statSync(join(logsDir, logFiles[0]));
    return { running: false, lastRun: stat.mtime.toISOString() };
  }

  return { running: false, lastRun: null };
}

function getPendingRetries(projectFilter) {
  const itemsDir = join(getAutomationDir(), 'state', 'items');
  if (!existsSync(itemsDir)) return { retry: 0, failed: 0 };

  let files = readdirSync(itemsDir).filter(f => f.endsWith('.json'));

  // Filter by project if specified
  if (projectFilter) {
    files = files.filter(f => {
      try {
        const data = JSON.parse(readFileSync(join(itemsDir, f), 'utf-8'));
        return (data.project || 'default') === projectFilter;
      } catch {
        // Filename-based fallback: project-prefixed files start with "slug--"
        return f.startsWith(`${projectFilter}--`) || (!f.includes('--') && projectFilter === 'default');
      }
    });
  }

  let retry = 0;
  let failed = 0;
  for (const f of files) {
    try {
      const data = JSON.parse(readFileSync(join(itemsDir, f), 'utf-8'));
      if (data.status === 'retry') retry++;
      if (data.status === 'failed' || data.status === 'abandoned') failed++;
    } catch {
      // Fallback to filename check
      if (f.includes('retry')) retry++;
      if (f.includes('failed') || f.includes('abandoned')) failed++;
    }
  }
  return { retry, failed };
}

function runStatus(opts, cmd) {
  const projectFilter = cmd?.parent?.opts()?.project || undefined;
  const windows = getTmuxWindows();
  const slots = getSlotUsage();
  const poll = getLastPollTime();
  const pendingRetries = getPendingRetries(projectFilter);

  // Recent metrics (24h), optionally filtered by project
  const metricsFilter = { days: 1 };
  if (projectFilter) metricsFilter.project = projectFilter;
  const recent = readMetrics(metricsFilter);
  const successCount = recent.filter(m => m.status === 'success').length;
  const failureCount = recent.filter(m => m.status === 'failure').length;

  // 7-day success rate
  const weekFilter = { days: 7 };
  if (projectFilter) weekFilter.project = projectFilter;
  const week = readMetrics(weekFilter);
  const weekTotal = week.length;
  const weekSuccess = week.filter(m => m.status === 'success').length;
  const successRate = weekTotal > 0 ? Math.round((weekSuccess / weekTotal) * 100) : 0;

  const status = {
    ...(projectFilter ? { project: projectFilter } : {}),
    tmux: {
      sessionExists: windows.length > 0,
      windows: windows.length,
      windowList: windows
    },
    slots: {
      active: slots.active,
      max: slots.max,
      utilization: `${slots.active}/${slots.max}`
    },
    poll: poll,
    last24h: {
      total: recent.length,
      success: successCount,
      failure: failureCount
    },
    weeklySuccessRate: `${successRate}%`,
    weeklyTotal: weekTotal,
    pendingRetries: pendingRetries.retry,
    failedItems: pendingRetries.failed
  };

  if (opts.json) {
    console.log(JSON.stringify(status, null, 2));
    return;
  }

  if (opts.brief) {
    const tmuxStatus = status.tmux.sessionExists ? 'UP' : 'DOWN';
    console.log(`[${tmuxStatus}] slots:${slots.active}/${slots.max} 24h:${successCount}ok/${failureCount}fail 7d:${successRate}% retries:${pendingRetries.retry} failed:${pendingRetries.failed}`);
    return;
  }

  if (opts.slack) {
    const tmuxEmoji = status.tmux.sessionExists ? ':white_check_mark:' : ':x:';
    const lines = [
      `*Pipeline Status*`,
      `${tmuxEmoji} tmux: ${status.tmux.sessionExists ? 'running' : 'DOWN'} (${windows.length} windows)`,
      `:gear: Slots: ${slots.active}/${slots.max}`,
      `:chart_with_upwards_trend: 24h: ${successCount} success, ${failureCount} failure`,
      `:bar_chart: 7-day success rate: ${successRate}% (${weekTotal} jobs)`,
    ];
    if (pendingRetries.retry > 0) lines.push(`:repeat: Pending retries: ${pendingRetries.retry}`);
    if (pendingRetries.failed > 0) lines.push(`:warning: Failed items: ${pendingRetries.failed}`);
    console.log(lines.join('\n'));
    return;
  }

  // Human-readable default
  if (projectFilter) {
    console.log(`Pipeline Status [project: ${projectFilter}]`);
    console.log('='.repeat(20 + projectFilter.length));
  } else {
    console.log('Pipeline Status');
    console.log('===============');
  }
  console.log('');

  console.log(`tmux session:  ${status.tmux.sessionExists ? 'running' : 'NOT RUNNING'}`);
  console.log(`  windows:     ${windows.length}`);
  if (windows.length > 0) {
    for (const w of windows) {
      console.log(`    ${w.index}: ${w.name}${w.active ? ' (active)' : ''}`);
    }
  }
  console.log('');

  console.log(`Slot usage:    ${slots.active}/${slots.max}`);
  console.log('');

  if (poll.running) {
    console.log(`Poll:          running since ${poll.since}`);
  } else if (poll.lastRun) {
    const ago = timeSince(new Date(poll.lastRun));
    console.log(`Last poll:     ${ago} ago`);
  } else {
    console.log('Last poll:     unknown');
  }
  console.log('');

  console.log('Last 24 hours:');
  console.log(`  Total jobs:  ${recent.length}`);
  console.log(`  Success:     ${successCount}`);
  console.log(`  Failure:     ${failureCount}`);
  console.log('');

  console.log(`7-day success: ${successRate}% (${weekSuccess}/${weekTotal})`);
  console.log('');

  if (pendingRetries.retry > 0 || pendingRetries.failed > 0) {
    console.log('Attention:');
    if (pendingRetries.retry > 0) console.log(`  Pending retries: ${pendingRetries.retry}`);
    if (pendingRetries.failed > 0) console.log(`  Failed items:    ${pendingRetries.failed}`);
    console.log('');
  }

  // Show recent jobs
  if (recent.length > 0) {
    console.log('Recent jobs (last 24h):');
    const last10 = recent.slice(-10).reverse();
    for (const m of last10) {
      const time = new Date(m.timestamp).toLocaleTimeString();
      const dur = m.duration_s ? `${m.duration_s}s` : '-';
      const icon = m.status === 'success' ? '+' : m.status === 'failure' ? 'x' : '?';
      const proj = !projectFilter && m.project && m.project !== 'default' ? ` [${m.project}]` : '';
      console.log(`  [${icon}] ${time}  ${m.job}  ${m.repo || ''}  ${dur}${proj}`);
    }
  }

  // Per-project breakdown (when showing all projects)
  if (!projectFilter) {
    const projects = getProjects();
    if (projects.length > 1) {
      console.log('');
      console.log('Per-project (24h):');
      for (const p of projects) {
        const pMetrics = readMetrics({ days: 1, project: p.slug });
        const pSuccess = pMetrics.filter(m => m.status === 'success').length;
        const pFail = pMetrics.filter(m => m.status === 'failure').length;
        const pRetries = getPendingRetries(p.slug);
        const parts = [`${pSuccess} ok`, `${pFail} fail`];
        if (pRetries.retry > 0) parts.push(`${pRetries.retry} retry`);
        console.log(`  ${p.slug.padEnd(20)} ${parts.join(', ')}`);
      }
    }
  }
}

function timeSince(date) {
  const seconds = Math.floor((Date.now() - date.getTime()) / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ${minutes % 60}m`;
  const days = Math.floor(hours / 24);
  return `${days}d ${hours % 24}h`;
}
