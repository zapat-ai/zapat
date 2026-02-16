import { execSync } from 'child_process'
import { readFileSync, existsSync, readdirSync, statSync } from 'fs'
import { join } from 'path'
import type {
  PipelineItem,
  MetricEntry,
  HealthCheck,
  SystemStatus,
  ChartDataPoint,
} from './types'

function getAutomationDir(): string {
  return process.env.AUTOMATION_DIR || join(process.cwd(), '..')
}

function exec(cmd: string): string | null {
  try {
    return execSync(cmd, {
      encoding: 'utf-8',
      timeout: 30000,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim()
  } catch {
    return null
  }
}

function execFull(cmd: string): { stdout: string; stderr: string; exitCode: number } {
  try {
    const stdout = execSync(cmd, {
      encoding: 'utf-8',
      timeout: 30000,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim()
    return { stdout, stderr: '', exitCode: 0 }
  } catch (err: any) {
    return {
      stdout: (err.stdout || '').trim(),
      stderr: (err.stderr || '').trim(),
      exitCode: err.status ?? 1,
    }
  }
}

function getRepos(): Array<{ repo: string; localPath: string; type: string }> {
  const confPath = join(getAutomationDir(), 'config', 'repos.conf')
  const repos: Array<{ repo: string; localPath: string; type: string }> = []

  if (!existsSync(confPath)) return repos

  const lines = readFileSync(confPath, 'utf-8').split('\n')
  for (const line of lines) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue
    const parts = trimmed.split('\t')
    if (parts.length >= 3) {
      repos.push({
        repo: parts[0].trim(),
        localPath: parts[1].trim(),
        type: parts[2].trim(),
      })
    }
  }

  return repos
}

function readMetrics(opts: { days?: number } = {}): MetricEntry[] {
  const metricsPath = join(getAutomationDir(), 'data', 'metrics.jsonl')
  if (!existsSync(metricsPath)) return []

  const lines = readFileSync(metricsPath, 'utf-8').split('\n').filter(Boolean)
  let entries: MetricEntry[] = []

  for (const line of lines) {
    try {
      entries.push(JSON.parse(line))
    } catch {
      // Skip malformed lines
    }
  }

  if (opts.days) {
    const cutoff = Date.now() - opts.days * 24 * 60 * 60 * 1000
    entries = entries.filter((e) => new Date(e.timestamp).getTime() >= cutoff)
  }

  return entries
}

function classifyPrStage(labels: string[]): string {
  if (labels.includes('zapat-rework')) return 'rework'
  if (labels.includes('zapat-review')) return 'review'
  return 'in-progress'
}

function classifyIssueStage(labels: string[]): string {
  if (labels.includes('zapat-implementing')) return 'in-progress'
  if (labels.includes('zapat-researching')) return 'in-progress'
  if (labels.includes('zapat-triaging')) return 'triaging'
  if (labels.includes('triaged')) return 'triaged'
  if (labels.includes('agent-work')) return 'in-progress'
  if (labels.includes('agent-research')) return 'research'
  if (labels.includes('agent')) return 'triaged'
  return 'new'
}

export function getActiveItems(): PipelineItem[] {
  const repos = getRepos()
  const items: PipelineItem[] = []

  for (const { repo } of repos) {
    const prJson = exec(
      `gh pr list --repo "${repo}" --json number,title,labels,state,url,createdAt --state open --limit 50`,
    )
    if (prJson) {
      try {
        for (const pr of JSON.parse(prJson)) {
          const labelNames = (pr.labels || []).map((l: any) => l.name)
          if (
            labelNames.some((l: string) =>
              ['zapat-review', 'agent-work', 'zapat-rework', 'agent', 'zapat-implementing', 'zapat-testing', 'zapat-triaging'].includes(l),
            )
          ) {
            items.push({
              type: 'pr',
              repo,
              number: pr.number,
              title: pr.title,
              labels: labelNames,
              url: pr.url,
              stage: classifyPrStage(labelNames),
              createdAt: pr.createdAt,
            })
          }
        }
      } catch {
        /* skip */
      }
    }

    const issueJson = exec(
      `gh issue list --repo "${repo}" --json number,title,labels,state,url,createdAt --state open --limit 50`,
    )
    if (issueJson) {
      try {
        for (const issue of JSON.parse(issueJson)) {
          const labelNames = (issue.labels || []).map((l: any) => l.name)
          if (
            labelNames.some((l: string) =>
              ['agent', 'agent-work', 'agent-research', 'triaged', 'zapat-triaging', 'zapat-researching', 'zapat-implementing'].includes(l),
            )
          ) {
            items.push({
              type: 'issue',
              repo,
              number: issue.number,
              title: issue.title,
              labels: labelNames,
              url: issue.url,
              stage: classifyIssueStage(labelNames),
              createdAt: issue.createdAt,
            })
          }
        }
      } catch {
        /* skip */
      }
    }
  }

  return items
}

export function getCompletedItems(): PipelineItem[] {
  const repos = getRepos()
  const items: PipelineItem[] = []

  for (const { repo } of repos) {
    const prJson = exec(
      `gh pr list --repo "${repo}" --json number,title,labels,url,mergedAt,headRefName --state merged --limit 20`,
    )
    if (prJson) {
      try {
        for (const pr of JSON.parse(prJson)) {
          if (!pr.headRefName || !pr.headRefName.startsWith('agent/')) continue
          items.push({
            type: 'pr',
            repo,
            number: pr.number,
            title: pr.title,
            labels: [],
            url: pr.url,
            stage: 'completed',
            completedAt: pr.mergedAt,
          })
        }
      } catch {
        /* skip */
      }
    }

    const issueJson = exec(
      `gh issue list --repo "${repo}" --json number,title,labels,url,closedAt --state closed --limit 20`,
    )
    if (issueJson) {
      try {
        for (const issue of JSON.parse(issueJson)) {
          const labelNames = (issue.labels || []).map((l: any) => l.name)
          if (!labelNames.some((l: string) => ['agent-work', 'agent-research'].includes(l)))
            continue
          items.push({
            type: 'issue',
            repo,
            number: issue.number,
            title: issue.title,
            labels: labelNames,
            url: issue.url,
            stage: 'completed',
            completedAt: issue.closedAt,
          })
        }
      } catch {
        /* skip */
      }
    }
  }

  items.sort((a, b) => (b.completedAt || '').localeCompare(a.completedAt || ''))
  return items.slice(0, 25)
}

export function getMetricsData(days: number = 14): MetricEntry[] {
  return readMetrics({ days })
}

export function getChartData(days: number = 14): ChartDataPoint[] {
  const allMetrics = readMetrics({ days })
  const chartData: ChartDataPoint[] = []

  for (let i = days - 1; i >= 0; i--) {
    const date = new Date()
    date.setDate(date.getDate() - i)
    const dayStr = date.toISOString().split('T')[0]
    const dayMetrics = allMetrics.filter(
      (m) => m.timestamp && m.timestamp.startsWith(dayStr),
    )
    const total = dayMetrics.length
    const success = dayMetrics.filter((m) => m.status === 'success').length
    const rate = total > 0 ? Math.round((success / total) * 100) : 0
    chartData.push({ date: dayStr, total, success, rate })
  }

  return chartData
}

export function getHealthChecks(): HealthCheck[] {
  const checks: HealthCheck[] = []
  const automationDir = getAutomationDir()

  // Check tmux session
  const sessionCheck = execFull('tmux has-session -t zapat')
  if (sessionCheck.exitCode === 0) {
    checks.push({ name: 'tmux-session', status: 'ok', message: 'Session exists' })
  } else {
    checks.push({
      name: 'tmux-session',
      status: 'error',
      message: 'Session not found',
    })
  }

  // Check stale slots
  const slotDir = join(automationDir, 'state', 'agent-work-slots')
  if (existsSync(slotDir)) {
    const files = readdirSync(slotDir).filter((f) => f.endsWith('.pid'))
    let staleCount = 0
    for (const f of files) {
      try {
        const pid = readFileSync(join(slotDir, f), 'utf-8').trim()
        if (pid) {
          const check = execFull(`kill -0 ${pid}`)
          if (check.exitCode !== 0) staleCount++
        } else {
          staleCount++
        }
      } catch {
        staleCount++
      }
    }
    if (staleCount === 0) {
      checks.push({
        name: 'stale-slots',
        status: 'ok',
        message: `${files.length} active slot(s), none stale`,
      })
    } else {
      checks.push({
        name: 'stale-slots',
        status: 'error',
        message: `${staleCount} stale slot(s)`,
      })
    }
  } else {
    checks.push({ name: 'stale-slots', status: 'ok', message: 'No slot directory' })
  }

  // Check gh auth
  const ghCheck = execFull('gh auth status')
  if (ghCheck.exitCode === 0) {
    checks.push({ name: 'gh-auth', status: 'ok', message: 'GitHub CLI authenticated' })
  } else {
    checks.push({ name: 'gh-auth', status: 'error', message: 'GitHub CLI not authenticated' })
  }

  // Check failed items
  const itemsDir = join(automationDir, 'state', 'items')
  if (existsSync(itemsDir)) {
    const files = readdirSync(itemsDir)
    const failed = files.filter((f) => f.includes('failed') || f.includes('abandoned'))
    if (failed.length === 0) {
      checks.push({ name: 'failed-items', status: 'ok', message: 'No failed items' })
    } else if (failed.length > 3) {
      checks.push({
        name: 'failed-items',
        status: 'error',
        message: `${failed.length} failed/abandoned items`,
      })
    } else {
      checks.push({
        name: 'failed-items',
        status: 'ok',
        message: `${failed.length} failed item(s) (below threshold)`,
      })
    }
  } else {
    checks.push({ name: 'failed-items', status: 'ok', message: 'No items directory' })
  }

  // Check orphaned worktrees
  const worktreeDir = '/tmp/agent-worktrees'
  if (existsSync(worktreeDir)) {
    try {
      const entries = readdirSync(worktreeDir)
      const twoHoursAgo = Date.now() - 2 * 60 * 60 * 1000
      let orphanCount = 0
      for (const entry of entries) {
        try {
          const stat = statSync(join(worktreeDir, entry))
          if (stat.isDirectory() && stat.mtimeMs < twoHoursAgo) orphanCount++
        } catch {
          /* ignore */
        }
      }
      if (orphanCount === 0) {
        checks.push({
          name: 'orphaned-worktrees',
          status: 'ok',
          message: `${entries.length} worktree(s), none orphaned`,
        })
      } else {
        checks.push({
          name: 'orphaned-worktrees',
          status: 'error',
          message: `${orphanCount} orphaned worktree(s) older than 2h`,
        })
      }
    } catch {
      checks.push({
        name: 'orphaned-worktrees',
        status: 'ok',
        message: 'Cannot read worktree directory',
      })
    }
  } else {
    checks.push({
      name: 'orphaned-worktrees',
      status: 'ok',
      message: 'No worktree directory',
    })
  }

  return checks
}

export function getSystemStatus(): SystemStatus {
  const automationDir = getAutomationDir()
  const checks = getHealthChecks()

  const sessionCheck = execFull('tmux has-session -t zapat')
  const sessionExists = sessionCheck.exitCode === 0

  const windowCountStr = exec('tmux list-windows -t zapat 2>/dev/null | wc -l')
  const windowCount = windowCountStr ? parseInt(windowCountStr.trim()) : 0

  const slotDir = join(automationDir, 'state', 'agent-work-slots')
  let activeSlots = 0
  if (existsSync(slotDir)) {
    try {
      activeSlots = readdirSync(slotDir).filter((f) => f.endsWith('.pid')).length
    } catch {
      /* ignore */
    }
  }

  return {
    healthy: !checks.some((c) => c.status === 'error'),
    sessionExists,
    windowCount,
    activeSlots,
    maxSlots: 10,
    checks,
  }
}
