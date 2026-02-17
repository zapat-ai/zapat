import { writeFileSync, readdirSync, existsSync } from 'fs';
import { join } from 'path';
import { execSync } from 'child_process';
import { createServer } from 'http';
import { getAutomationDir, getRepos } from '../lib/config.mjs';
import { readMetrics, ensureDataDir } from '../lib/metrics.mjs';
import { exec } from '../lib/exec.mjs';

export function registerDashboardCommand(program) {
  program
    .command('dashboard')
    .description('Generate and optionally serve the pipeline dashboard')
    .option('--serve [port]', 'Start Next.js production server (default: 3000)')
    .option('--dev', 'Start Next.js dev server')
    .option('--static', 'Generate static HTML dashboard (legacy)')
    .action(runDashboard);
}

function runDashboard(opts) {
  const dashboardDir = join(getAutomationDir(), 'dashboard');
  const automationEnv = { ...process.env, AUTOMATION_DIR: getAutomationDir() };

  if (opts.dev) {
    const devPort = parseInt(process.env.DASHBOARD_PORT) || 3000;
    if (devPort < 1 || devPort > 65535) {
      console.error(`Invalid DASHBOARD_PORT: ${devPort}. Must be 1-65535.`);
      process.exitCode = 1;
      return;
    }
    console.log(`Starting Next.js dev server on port ${devPort}...`);
    execSync(`npm run dev -- -H 127.0.0.1 -p ${devPort}`, { cwd: dashboardDir, stdio: 'inherit', env: automationEnv });
    return;
  }

  if (opts.serve !== undefined && !opts.static) {
    const port = parseInt(opts.serve) || parseInt(process.env.DASHBOARD_PORT) || 3000;
    if (port < 1 || port > 65535) {
      console.error(`Invalid port: ${port}. Must be 1-65535.`);
      process.exitCode = 1;
      return;
    }
    console.log(`Starting Next.js production server on port ${port}...`);
    execSync(`npm run start -- -H 127.0.0.1 -p ${port}`, { cwd: dashboardDir, stdio: 'inherit', env: automationEnv });
    return;
  }

  // Default / --static: generate static HTML
  ensureDataDir();
  const html = generateDashboard();
  const outPath = join(getAutomationDir(), 'data', 'dashboard.html');
  writeFileSync(outPath, html);
  console.log(`Dashboard written to ${outPath}`);
}

const CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes
let cachedHtml = null;
let cacheTime = 0;

function serveDashboard(port) {
  const server = createServer((req, res) => {
    if (req.url === '/' || req.url === '/index.html') {
      const now = Date.now();
      if (!cachedHtml || (now - cacheTime) > CACHE_TTL_MS) {
        cachedHtml = generateDashboard();
        cacheTime = now;
      }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(cachedHtml);
    } else {
      res.writeHead(404);
      res.end('Not found');
    }
  });

  server.listen(port, '127.0.0.1', () => {
    console.log(`Dashboard server running at http://127.0.0.1:${port} (cache TTL: 5m)`);
  });
}

function getGitHubItems() {
  const repos = getRepos();
  const items = [];

  for (const { repo } of repos) {
    const prJson = exec(`gh pr list --repo "${repo}" --json number,title,labels,state,url,createdAt --state open --limit 50`);
    if (prJson) {
      try {
        for (const pr of JSON.parse(prJson)) {
          const labelNames = (pr.labels || []).map(l => l.name);
          if (labelNames.some(l => ['zapat-review', 'agent-work', 'zapat-rework', 'agent', 'zapat-implementing', 'zapat-testing', 'zapat-triaging'].includes(l))) {
            items.push({ type: 'pr', repo, number: pr.number, title: pr.title, labels: labelNames, url: pr.url, stage: classifyPrStage(labelNames) });
          }
        }
      } catch { /* skip */ }
    }

    const issueJson = exec(`gh issue list --repo "${repo}" --json number,title,labels,state,url,createdAt --state open --limit 50`);
    if (issueJson) {
      try {
        for (const issue of JSON.parse(issueJson)) {
          const labelNames = (issue.labels || []).map(l => l.name);
          if (labelNames.some(l => ['agent', 'agent-work', 'agent-research', 'triaged', 'zapat-triaging', 'zapat-researching', 'zapat-implementing'].includes(l))) {
            items.push({ type: 'issue', repo, number: issue.number, title: issue.title, labels: labelNames, url: issue.url, stage: classifyIssueStage(labelNames) });
          }
        }
      } catch { /* skip */ }
    }
  }

  return items;
}

function getCompletedItems() {
  const repos = getRepos();
  const items = [];

  for (const { repo } of repos) {
    // Recently merged PRs from agent branches
    const prJson = exec(`gh pr list --repo "${repo}" --json number,title,labels,url,mergedAt,headRefName --state merged --limit 20`);
    if (prJson) {
      try {
        for (const pr of JSON.parse(prJson)) {
          if (!pr.headRefName || !pr.headRefName.startsWith('agent/')) continue;
          items.push({ type: 'pr', repo, number: pr.number, title: pr.title, url: pr.url, completedAt: pr.mergedAt });
        }
      } catch { /* skip */ }
    }

    // Recently closed issues with agent-work label
    const issueJson = exec(`gh issue list --repo "${repo}" --json number,title,labels,url,closedAt --state closed --limit 20`);
    if (issueJson) {
      try {
        for (const issue of JSON.parse(issueJson)) {
          const labelNames = (issue.labels || []).map(l => l.name);
          if (!labelNames.some(l => ['agent-work', 'agent-research'].includes(l))) continue;
          items.push({ type: 'issue', repo, number: issue.number, title: issue.title, url: issue.url, completedAt: issue.closedAt });
        }
      } catch { /* skip */ }
    }
  }

  // Sort by completion date, most recent first
  items.sort((a, b) => (b.completedAt || '').localeCompare(a.completedAt || ''));
  return items.slice(0, 25);
}

function classifyPrStage(labels) {
  if (labels.includes('zapat-rework')) return 'rework';
  if (labels.includes('zapat-testing')) return 'testing';
  if (labels.includes('zapat-review')) return 'review';
  return 'in-progress';
}

function classifyIssueStage(labels) {
  if (labels.includes('zapat-implementing')) return 'in-progress';
  if (labels.includes('zapat-researching')) return 'in-progress';
  if (labels.includes('zapat-triaging')) return 'triaging';
  if (labels.includes('triaged')) return 'triaged';
  if (labels.includes('agent-work')) return 'in-progress';
  if (labels.includes('agent-research')) return 'research';
  if (labels.includes('agent')) return 'triaged';
  return 'new';
}

function generateDashboard() {
  // Gather all data upfront
  let ghItems = [];
  let completedItems = [];
  try { ghItems = getGitHubItems(); } catch { /* skip if gh unavailable */ }
  try { completedItems = getCompletedItems(); } catch { /* skip if gh unavailable */ }

  const allMetrics = readMetrics({ days: 14 });
  const recentMetrics = readMetrics({ days: 1 });
  const weekMetrics = readMetrics({ days: 7 });
  const last50 = allMetrics.slice(-50).reverse();
  const failures = allMetrics.filter(m => m.status === 'failure').slice(-10).reverse();

  // System health
  const tmuxResult = exec('tmux has-session -t zapat 2>/dev/null && echo ok || echo fail');
  const sessionExists = tmuxResult && tmuxResult.trim() === 'ok';
  const windowCountStr = exec('tmux list-windows -t zapat 2>/dev/null | wc -l');
  const windowCount = windowCountStr ? parseInt(windowCountStr.trim()) : 0;

  const slotDir = join(getAutomationDir(), 'state', 'agent-work-slots');
  let activeSlots = 0;
  if (existsSync(slotDir)) {
    try {
      activeSlots = readdirSync(slotDir).filter(f => f.endsWith('.pid')).length;
    } catch { /* ignore */ }
  }

  // 14-day chart data
  const chartData = [];
  for (let i = 13; i >= 0; i--) {
    const date = new Date();
    date.setDate(date.getDate() - i);
    const dayStr = date.toISOString().split('T')[0];
    const dayMetrics = allMetrics.filter(m => m.timestamp && m.timestamp.startsWith(dayStr));
    const total = dayMetrics.length;
    const success = dayMetrics.filter(m => m.status === 'success').length;
    const rate = total > 0 ? Math.round((success / total) * 100) : 0;
    chartData.push({ date: dayStr, total, success, rate });
  }

  // Kanban
  const kanban = {
    triaged: ghItems.filter(i => i.stage === 'triaged'),
    inProgress: ghItems.filter(i => i.stage === 'in-progress'),
    prOpen: ghItems.filter(i => i.stage === 'pr-open'),
    review: ghItems.filter(i => i.stage === 'review'),
    rework: ghItems.filter(i => i.stage === 'rework'),
  };

  // Pre-compute stats
  const healthColor = sessionExists ? '#22c55e' : '#ef4444';
  const healthLabel = sessionExists ? 'Healthy' : 'Down';
  const recentSuccess = recentMetrics.filter(m => m.status === 'success').length;
  const recentFailure = recentMetrics.filter(m => m.status === 'failure').length;
  const weekTotal = weekMetrics.length;
  const weekSuccess = weekMetrics.filter(m => m.status === 'success').length;
  const weekRate = weekTotal > 0 ? Math.round((weekSuccess / weekTotal) * 100) + '%' : 'N/A';
  const slotPct = activeSlots * 10;
  const now = new Date().toISOString();

  // Build chart bars
  const chartBarsHtml = chartData.map(d => {
    const height = Math.max(d.rate, 2);
    const color = d.rate >= 80 ? '#22c55e' : d.rate >= 50 ? '#eab308' : d.total === 0 ? '#334155' : '#ef4444';
    const label = d.date.slice(5);
    const pctLabel = d.total > 0 ? d.rate + '%' : '';
    return `<div class="chart-bar">
            <span class="pct">${pctLabel}</span>
            <div class="bar" style="height:${height}%;background:${color}" title="${d.date}: ${d.success}/${d.total}"></div>
            <span class="label">${label}</span>
          </div>`;
  }).join('\n        ');

  // Build job rows
  const jobRowsHtml = last50.map(m => {
    const time = m.timestamp ? new Date(m.timestamp).toLocaleString() : '-';
    const badgeClass = m.status === 'success' ? 'badge-success' : m.status === 'failure' ? 'badge-failure' : 'badge-other';
    const dur = m.duration_s ? `${m.duration_s}s` : '-';
    const repoShort = m.repo ? m.repo.split('/').pop() : '-';
    return `<tr><td>${esc(time)}</td><td>${esc(m.job || '-')}</td><td>${esc(repoShort)}</td><td><span class="badge ${badgeClass}">${esc(m.status || '-')}</span></td><td>${dur}</td></tr>`;
  }).join('\n        ');

  // Build failure rows
  const failureRowsHtml = failures.map(m => {
    const time = m.timestamp ? new Date(m.timestamp).toLocaleString() : '-';
    const repoShort = m.repo ? m.repo.split('/').pop() : '-';
    return `<tr><td>${esc(time)}</td><td>${esc(m.job || '-')}</td><td>${esc(repoShort)}</td><td>${esc(m.item || '-')}</td><td>${m.exit_code ?? '-'}</td></tr>`;
  }).join('\n        ');

  const failureSection = failures.length > 0 ? `
  <div class="section">
    <h2>Recent Failures</h2>
    <table>
      <thead><tr><th>Time</th><th>Job</th><th>Repo</th><th>Item</th><th>Exit Code</th></tr></thead>
      <tbody>
        ${failureRowsHtml}
      </tbody>
    </table>
  </div>` : '';

  // Build completed items rows
  const completedRowsHtml = completedItems.map(i => {
    const repoShort = i.repo.split('/').pop();
    const prefix = i.type === 'pr' ? 'PR' : '#';
    const time = i.completedAt ? new Date(i.completedAt).toLocaleDateString() : '-';
    const typeLabel = i.type === 'pr' ? 'Merged' : 'Closed';
    const badgeClass = i.type === 'pr' ? 'badge-success' : 'badge-completed';
    return `<tr><td>${esc(time)}</td><td><a href="${esc(i.url)}" target="_blank" style="color:#60a5fa;text-decoration:none">${prefix}${i.number}</a></td><td>${esc(i.title.slice(0, 70))}</td><td>${esc(repoShort)}</td><td><span class="badge ${badgeClass}">${typeLabel}</span></td></tr>`;
  }).join('\n        ');

  const completedSection = completedItems.length > 0 ? `
  <div class="section">
    <h2>Completed Work (${completedItems.length})</h2>
    <table>
      <thead><tr><th>Date</th><th>Item</th><th>Title</th><th>Repo</th><th>Status</th></tr></thead>
      <tbody>
        ${completedRowsHtml}
      </tbody>
    </table>
  </div>` : '';

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="300">
<title>Agent Pipeline Dashboard</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #e2e8f0; }
  .container { max-width: 1400px; margin: 0 auto; padding: 24px; }
  header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; }
  header h1 { font-size: 24px; font-weight: 600; }
  header .ts { font-size: 13px; color: #94a3b8; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 24px; }
  .card { background: #1e293b; border-radius: 12px; padding: 20px; }
  .card h3 { font-size: 13px; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 8px; }
  .card .value { font-size: 28px; font-weight: 700; }
  .card .sub { font-size: 13px; color: #94a3b8; margin-top: 4px; }
  .section { background: #1e293b; border-radius: 12px; padding: 20px; margin-bottom: 24px; }
  .section h2 { font-size: 16px; font-weight: 600; margin-bottom: 16px; }
  .kanban { display: grid; grid-template-columns: repeat(5, 1fr); gap: 12px; }
  .kanban-col { background: #0f172a; border-radius: 8px; padding: 12px; min-height: 120px; }
  .kanban-col h4 { font-size: 12px; color: #94a3b8; text-transform: uppercase; margin-bottom: 8px; padding-bottom: 8px; border-bottom: 1px solid #334155; }
  .kanban-item { background: #1e293b; border-radius: 6px; padding: 8px 10px; margin-bottom: 6px; font-size: 12px; border-left: 3px solid #3b82f6; }
  .kanban-item .repo { color: #94a3b8; font-size: 11px; }
  .kanban-item a { color: #60a5fa; text-decoration: none; }
  .kanban-item a:hover { text-decoration: underline; }
  .chart-container { padding: 12px 0; }
  .chart { display: flex; align-items: flex-end; gap: 6px; height: 120px; }
  .chart-bar { flex: 1; display: flex; flex-direction: column; align-items: center; }
  .chart-bar .bar { width: 100%; border-radius: 4px 4px 0 0; min-height: 2px; }
  .chart-bar .label { font-size: 10px; color: #64748b; margin-top: 4px; writing-mode: vertical-rl; text-orientation: mixed; }
  .chart-bar .pct { font-size: 10px; color: #94a3b8; margin-bottom: 2px; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; font-size: 12px; color: #94a3b8; text-transform: uppercase; padding: 8px 12px; border-bottom: 1px solid #334155; }
  td { padding: 8px 12px; font-size: 13px; border-bottom: 1px solid #0f172a; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 11px; font-weight: 600; }
  .badge-success { background: #166534; color: #4ade80; }
  .badge-failure { background: #7f1d1d; color: #f87171; }
  .badge-other { background: #3b3b1f; color: #facc15; }
  .badge-completed { background: #1e3a5f; color: #60a5fa; }
  .health-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 6px; }
  .slot-bar { height: 8px; background: #334155; border-radius: 4px; overflow: hidden; margin-top: 6px; }
  .slot-bar-fill { height: 100%; background: #3b82f6; border-radius: 4px; }
  @media (max-width: 900px) { .kanban { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>Agent Pipeline Dashboard</h1>
    <span class="ts">Generated: ${now}</span>
  </header>

  <div class="grid">
    <div class="card">
      <h3>System Health</h3>
      <div class="value"><span class="health-dot" style="background:${healthColor}"></span>${healthLabel}</div>
      <div class="sub">${windowCount} tmux window(s)</div>
    </div>
    <div class="card">
      <h3>Slot Usage</h3>
      <div class="value">${activeSlots}/10</div>
      <div class="slot-bar"><div class="slot-bar-fill" style="width:${slotPct}%"></div></div>
    </div>
    <div class="card">
      <h3>Jobs (24h)</h3>
      <div class="value">${recentMetrics.length}</div>
      <div class="sub">${recentSuccess} success, ${recentFailure} failure</div>
    </div>
    <div class="card">
      <h3>7d Success Rate</h3>
      <div class="value">${weekRate}</div>
      <div class="sub">${weekTotal} jobs total</div>
    </div>
    <div class="card">
      <h3>Completed</h3>
      <div class="value">${completedItems.length}</div>
      <div class="sub">merged PRs + closed issues</div>
    </div>
  </div>

  <div class="section">
    <h2>Kanban Board</h2>
    <div class="kanban">
      ${renderKanbanCol('Triaged', kanban.triaged)}
      ${renderKanbanCol('In Progress', kanban.inProgress)}
      ${renderKanbanCol('PR Open', kanban.prOpen)}
      ${renderKanbanCol('Review', kanban.review)}
      ${renderKanbanCol('Rework', kanban.rework)}
    </div>
  </div>

  <div class="section">
    <h2>14-Day Success Rate</h2>
    <div class="chart-container">
      <div class="chart">
        ${chartBarsHtml}
      </div>
    </div>
  </div>

  <div class="section">
    <h2>Recent Jobs</h2>
    <table>
      <thead><tr><th>Time</th><th>Job</th><th>Repo</th><th>Status</th><th>Duration</th></tr></thead>
      <tbody>
        ${jobRowsHtml}
      </tbody>
    </table>
  </div>

  ${completedSection}

  ${failureSection}

</div>
</body>
</html>`;
}

function renderKanbanCol(title, items) {
  if (!items || items.length === 0) {
    return `<div class="kanban-col">
      <h4>${title} (0)</h4>
      <div style="color:#475569;font-size:12px;padding:8px">No items</div>
    </div>`;
  }

  const itemsHtml = items.map(i => {
    const repoShort = i.repo.split('/').pop();
    const prefix = i.type === 'pr' ? 'PR' : '#';
    return `<div class="kanban-item">
          <a href="${esc(i.url)}" target="_blank">${prefix}${i.number}</a> ${esc(i.title.slice(0, 60))}
          <div class="repo">${esc(repoShort)}</div>
        </div>`;
  }).join('\n      ');

  return `<div class="kanban-col">
      <h4>${title} (${items.length})</h4>
      ${itemsHtml}
    </div>`;
}

function esc(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
