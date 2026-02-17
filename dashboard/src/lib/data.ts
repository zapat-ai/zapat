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

function isValidProjectSlug(slug: string): boolean {
  return /^[a-zA-Z0-9_-]+$/.test(slug)
}

function getProjectConfigDir(slug: string): string {
  const root = getAutomationDir()
  if (
    slug === 'default'
    && !existsSync(join(root, 'config', 'default'))
    && existsSync(join(root, 'config', 'repos.conf'))
  ) {
    return join(root, 'config')
  }
  return join(root, 'config', slug)
}

function getRepos(project?: string): Array<{ repo: string; localPath: string; type: string }> {
  if (project && !isValidProjectSlug(project)) return []
  let confPath: string
  if (project) {
    confPath = join(getProjectConfigDir(project), 'repos.conf')
  } else {
    confPath = join(getAutomationDir(), 'config', 'repos.conf')
  }
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

function classifyPrStage(labels: string[]): { stage: string; subStage: string } {
  if (labels.includes('zapat-rework')) return { stage: 'review', subStage: 'rework' }
  if (labels.includes('zapat-testing')) return { stage: 'review', subStage: 'testing' }
  if (labels.includes('zapat-review')) return { stage: 'review', subStage: 'in review' }
  return { stage: 'review', subStage: 'pr open' }
}

function classifyIssueStage(labels: string[]): { stage: string; subStage: string } {
  if (labels.includes('zapat-implementing')) return { stage: 'working', subStage: 'implementing' }
  if (labels.includes('zapat-researching')) return { stage: 'working', subStage: 'researching' }
  if (labels.includes('zapat-triaging')) return { stage: 'queued', subStage: 'triaging' }
  if (labels.includes('triaged')) return { stage: 'queued', subStage: 'triaged' }
  if (labels.includes('agent-work')) return { stage: 'queued', subStage: 'queued' }
  if (labels.includes('agent-research')) return { stage: 'queued', subStage: 'research' }
  if (labels.includes('agent')) return { stage: 'queued', subStage: 'new' }
  return { stage: 'queued', subStage: 'new' }
}

export function getActiveItems(project?: string): PipelineItem[] {
  const repos = getRepos(project)
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
            const { stage, subStage } = classifyPrStage(labelNames)
            items.push({
              type: 'pr',
              repo,
              number: pr.number,
              title: pr.title,
              labels: labelNames,
              url: pr.url,
              stage,
              subStage,
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
            const { stage, subStage } = classifyIssueStage(labelNames)
            items.push({
              type: 'issue',
              repo,
              number: issue.number,
              title: issue.title,
              labels: labelNames,
              url: issue.url,
              stage,
              subStage,
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

export function getCompletedItems(project?: string): PipelineItem[] {
  const repos = getRepos(project)
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
            stage: 'done',
            subStage: 'merged',
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
            stage: 'done',
            subStage: 'closed',
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

export function getMetricsData(days: number = 14, project?: string): MetricEntry[] {
  if (project && !isValidProjectSlug(project)) return []
  const metrics = readMetrics({ days })
  if (!project) return metrics
  const projectRepos = getRepos(project).map((r) => r.repo)
  return metrics.filter((m) => projectRepos.includes(m.repo))
}

export function getChartData(days: number = 14, project?: string): ChartDataPoint[] {
  const allMetrics = getMetricsData(days, project)
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

// Health checks are system-wide (tmux, slots, gh auth) — not project-scoped.
// The project param is accepted for API consistency but unused.
export function getHealthChecks(_project?: string): HealthCheck[] {
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

  // Check stuck panes
  const tmuxSessionExists = checks.some(c => c.name === 'tmux-session' && c.status === 'ok')
  if (tmuxSessionExists) {
    const windowsOutput = exec('tmux list-windows -t zapat -F "#{window_name}" 2>/dev/null')
    if (windowsOutput) {
      const windows = windowsOutput.split('\n').filter(Boolean)
      let stuckPanes: string[] = []
      const ratePattern = /Switch to extra|Rate limit|rate_limit|429|Too Many Requests|Retry after/
      const permPattern = /Allow|Deny|permission|Do you want to|approve this/
      const fatalPattern = /FATAL|OOM|out of memory|Segmentation fault|core dumped|panic:|SIGKILL/

      for (const win of windows) {
        const panesOutput = exec(`tmux list-panes -t "zapat:${win}" -F "#{pane_index}" 2>/dev/null`)
        if (!panesOutput) continue
        for (const paneIdx of panesOutput.split('\n').filter(Boolean)) {
          const content = exec(`tmux capture-pane -t "zapat:${win}.${paneIdx}" -p 2>/dev/null`)
          if (!content) continue
          if (ratePattern.test(content)) {
            stuckPanes.push(`${win}.${paneIdx}: rate limit`)
          } else if (permPattern.test(content)) {
            stuckPanes.push(`${win}.${paneIdx}: permission prompt`)
          } else if (fatalPattern.test(content)) {
            stuckPanes.push(`${win}.${paneIdx}: fatal error`)
          }
        }
      }

      if (stuckPanes.length === 0) {
        const totalPanes = windows.reduce((sum, win) => {
          const p = exec(`tmux list-panes -t "zapat:${win}" -F "#{pane_index}" 2>/dev/null`)
          return sum + (p ? p.split('\n').filter(Boolean).length : 0)
        }, 0)
        checks.push({
          name: 'stuck-panes',
          status: 'ok',
          message: `Scanned ${totalPanes} pane(s) across ${windows.length} window(s), none stuck`,
        })
      } else {
        checks.push({
          name: 'stuck-panes',
          status: 'error',
          message: `${stuckPanes.length} stuck pane(s): ${stuckPanes.join('; ')}`,
        })
      }
    } else {
      checks.push({ name: 'stuck-panes', status: 'ok', message: 'No tmux windows to scan' })
    }
  } else {
    checks.push({ name: 'stuck-panes', status: 'ok', message: 'tmux session not running' })
  }

  // Check orphaned worktrees
  const worktreeDir = join(getAutomationDir(), 'worktrees')
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

export function getSystemStatus(project?: string): SystemStatus {
  const automationDir = getAutomationDir()
  const checks = getHealthChecks(project)

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

export function getProjectList(): Array<{ slug: string; name: string }> {
  const confPath = join(getAutomationDir(), 'config', 'projects.conf')

  // Tier 1: explicit manifest
  if (existsSync(confPath)) {
    return readFileSync(confPath, 'utf-8').split('\n')
      .filter(l => l.trim() && !l.startsWith('#'))
      .map(l => {
        const parts = l.split('\t')
        return { slug: parts[0].trim(), name: (parts[1] || parts[0]).trim() }
      })
  }

  // Tier 2: scan config/*/ for dirs containing repos.conf
  const configDir = join(getAutomationDir(), 'config')
  if (existsSync(configDir)) {
    try {
      const dirs = readdirSync(configDir)
        .filter(f => {
          const full = join(configDir, f)
          return statSync(full).isDirectory() && existsSync(join(full, 'repos.conf'))
        })
      if (dirs.length > 0) {
        return dirs.map(slug => ({ slug, name: slug }))
      }
    } catch { /* ignore */ }
  }

  // Tier 3: legacy single-project
  if (existsSync(join(getAutomationDir(), 'config', 'repos.conf'))) {
    return [{ slug: 'default', name: 'Default Project' }]
  }

  return []
}
