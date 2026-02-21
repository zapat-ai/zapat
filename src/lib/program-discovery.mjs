import { readdirSync, readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { getAutomationDir, getConfigValue } from './config.mjs';
import { readMetrics } from './metrics.mjs';
import { exec } from './exec.mjs';

/**
 * Discover the full program graph for a parent issue.
 * Returns a ProgramGraph object with sub-issues, PRs, dependencies, progress, blockers, risks, ETAs, and next steps.
 */
export async function discoverProgram(repo, parentNumber) {
  const cache = new Map();

  // Fetch parent issue
  const parent = ghCached(cache, `issue-${parentNumber}`, () =>
    JSON.parse(exec(`gh issue view ${parentNumber} --repo ${repo} --json number,title,state,labels,body`, { timeout: 15000 }) || '{}')
  );

  if (!parent.number) {
    return { error: `Could not fetch issue #${parentNumber} from ${repo}`, parent: null, subIssues: [], prs: [], graph: null };
  }

  // Discover sub-issues using multi-strategy approach
  const subIssueNumbers = discoverSubIssues(cache, repo, parentNumber);

  if (subIssueNumbers.length === 0) {
    return {
      parent: { number: parent.number, title: parent.title, state: parent.state },
      subIssues: [],
      prs: [],
      graph: null,
      progress: { issues: { done: 0, total: 0 }, prs: { merged: 0, total: 0 }, percent: 0 },
      phase: 'unknown',
      blockers: [],
      risks: [],
      etas: null,
      nextSteps: [],
      activeWork: []
    };
  }

  // Fetch details for each sub-issue
  const subIssues = [];
  for (const num of subIssueNumbers) {
    const issue = ghCached(cache, `issue-${num}`, () =>
      JSON.parse(exec(`gh issue view ${num} --repo ${repo} --json number,title,state,labels,body`, { timeout: 15000 }) || '{}')
    );
    if (!issue.number) continue;

    const labels = (issue.labels || []).map(l => l.name);
    const deps = parseDependencies(issue.body || '');
    const linkedPRs = findLinkedPRs(cache, repo, num);
    const pipelineStatus = getLocalState(repo, num);
    const tmuxSession = findTmuxSession(num);

    subIssues.push({
      number: issue.number,
      title: issue.title,
      state: issue.state,
      labels,
      dependencies: deps,
      linkedPRs,
      pipelineStatus,
      tmuxSession
    });
  }

  // Collect all PRs
  const allPRs = [];
  const seenPRs = new Set();
  for (const si of subIssues) {
    for (const pr of si.linkedPRs) {
      if (!seenPRs.has(pr.number)) {
        seenPRs.add(pr.number);
        allPRs.push(pr);
      }
    }
  }

  // Compute aggregations
  const progress = computeProgress(subIssues, allPRs);
  const phase = computePhase(subIssues, allPRs);
  const depGraph = buildDependencyGraph(subIssues);
  const blockers = findBlockers(subIssues, allPRs);
  const risks = findRisks(subIssues, allPRs);
  const activeWork = findActiveWork(subIssues);
  const etas = computeETAs(subIssues, allPRs);
  const nextSteps = computeNextSteps(subIssues, allPRs);

  return {
    parent: { number: parent.number, title: parent.title, state: parent.state },
    subIssues,
    prs: allPRs,
    progress,
    phase,
    graph: depGraph,
    blockers,
    risks,
    activeWork,
    etas,
    nextSteps
  };
}

// --- Caching helper ---
function ghCached(cache, key, fn) {
  if (cache.has(key)) return cache.get(key);
  const result = fn();
  cache.set(key, result);
  return result;
}

// --- Sub-issue discovery (multi-strategy) ---
function discoverSubIssues(cache, repo, parentNumber) {
  const found = new Set();

  // Strategy 1: Machine-readable HTML comment
  const parentBody = ghCached(cache, `issue-${parentNumber}`, () =>
    JSON.parse(exec(`gh issue view ${parentNumber} --repo ${repo} --json number,title,state,labels,body`, { timeout: 15000 }) || '{}')
  ).body || '';

  const comments = ghCached(cache, `comments-${parentNumber}`, () =>
    JSON.parse(exec(`gh api repos/${repo}/issues/${parentNumber}/comments --jq '[.[].body]'`, { timeout: 15000 }) || '[]')
  );

  const allText = [parentBody, ...(Array.isArray(comments) ? comments : [])];

  for (const text of allText) {
    // Strategy 1: <!-- zapat-sub-issues: X,Y,Z -->
    const machineMatch = text.match(/<!-- zapat-sub-issues:\s*([\d,\s]+)\s*-->/);
    if (machineMatch) {
      machineMatch[1].split(',').map(s => s.trim()).filter(Boolean).forEach(n => found.add(parseInt(n)));
    }

    // Strategy 2: "Superseded by follow-up issues" pattern
    const supersededMatch = text.match(/Superseded by follow-up issues[^]*?(?:#(\d+))/g);
    if (supersededMatch) {
      for (const m of supersededMatch) {
        const nums = [...m.matchAll(/#(\d+)/g)];
        nums.forEach(n => found.add(parseInt(n[1])));
      }
    }
    // Also catch standalone "Superseded by..." lines with multiple issue refs
    const supersededLine = text.match(/[Ss]uperseded by[^]*?(?:#\d+(?:\s*,\s*#\d+)*)/);
    if (supersededLine) {
      const nums = [...supersededLine[0].matchAll(/#(\d+)/g)];
      nums.forEach(n => found.add(parseInt(n[1])));
    }

    // Strategy 3: Structured table rows |  #N  |
    const tableMatches = [...text.matchAll(/\|\s*#(\d+)\s*\|/g)];
    tableMatches.forEach(m => found.add(parseInt(m[1])));
  }

  // Strategy 4: Local state files with parent_issue
  const itemsDir = join(getAutomationDir(), 'state', 'items');
  if (existsSync(itemsDir)) {
    try {
      const files = readdirSync(itemsDir).filter(f => f.endsWith('.json'));
      for (const f of files) {
        try {
          const data = JSON.parse(readFileSync(join(itemsDir, f), 'utf-8'));
          if (data.parent_issue !== undefined && data.parent_issue !== null &&
              String(data.parent_issue) === String(parentNumber)) {
            found.add(parseInt(data.number));
          }
        } catch { /* skip */ }
      }
    } catch { /* skip */ }
  }

  // Strategy 5: Fallback — search recent issues referencing parent
  if (found.size === 0) {
    const recentIssues = exec(`gh issue list --repo ${repo} --state all --limit 50 --json number,body`, { timeout: 15000 });
    if (recentIssues) {
      try {
        const issues = JSON.parse(recentIssues);
        for (const iss of issues) {
          if (iss.number === parseInt(parentNumber)) continue;
          if (iss.body && iss.body.includes(`#${parentNumber}`)) {
            found.add(iss.number);
          }
        }
      } catch { /* skip */ }
    }
  }

  // Remove parent from results
  found.delete(parseInt(parentNumber));

  return [...found].sort((a, b) => a - b);
}

// --- Parse dependencies from issue body ---
function parseDependencies(body) {
  const deps = [];
  const match = body.match(/\*\*Blocked By:\*\*\s*([^\n]+)/);
  if (match) {
    const nums = [...match[1].matchAll(/#(\d+)/g)];
    nums.forEach(m => deps.push(parseInt(m[1])));
  }
  return deps;
}

// --- Find linked PRs for an issue ---
function findLinkedPRs(cache, repo, issueNumber) {
  const prs = [];
  const seenNums = new Set();

  // Search by branch convention: agent/issue-{NUM}-*
  const branchPRs = ghCached(cache, `prs-branch-${issueNumber}`, () => {
    const result = exec(`gh pr list --repo ${repo} --state all --json number,title,state,headRefName,url,reviewDecision,mergeable,mergedAt --limit 20`, { timeout: 15000 });
    return result ? JSON.parse(result) : [];
  });

  for (const pr of branchPRs) {
    if (pr.headRefName && pr.headRefName.includes(`issue-${issueNumber}`)) {
      if (!seenNums.has(pr.number)) {
        seenNums.add(pr.number);
        prs.push(formatPR(pr));
      }
    }
  }

  // Also check PR bodies for "Closes #N" / "Fixes #N"
  for (const pr of branchPRs) {
    if (seenNums.has(pr.number)) continue;
    // Fetch body separately only if needed
    const prDetail = ghCached(cache, `pr-detail-${pr.number}`, () => {
      const result = exec(`gh pr view ${pr.number} --repo ${repo} --json number,title,state,body,headRefName,reviewDecision,mergeable,mergedAt`, { timeout: 15000 });
      return result ? JSON.parse(result) : {};
    });
    if (prDetail.body && (
      prDetail.body.match(new RegExp(`[Cc]loses\\s+#${issueNumber}\\b`)) ||
      prDetail.body.match(new RegExp(`[Ff]ixes\\s+#${issueNumber}\\b`))
    )) {
      seenNums.add(pr.number);
      prs.push(formatPR({ ...pr, ...prDetail }));
    }
  }

  return prs;
}

function formatPR(pr) {
  return {
    number: pr.number,
    title: pr.title || '',
    state: pr.state || 'UNKNOWN',
    branch: pr.headRefName || '',
    reviewDecision: pr.reviewDecision || '',
    merged: !!pr.mergedAt
  };
}

// --- Get local pipeline state ---
function getLocalState(repo, number) {
  const itemsDir = join(getAutomationDir(), 'state', 'items');
  if (!existsSync(itemsDir)) return null;

  try {
    const files = readdirSync(itemsDir).filter(f => f.endsWith('.json'));
    for (const f of files) {
      if (f.includes(`_${number}.json`)) {
        return JSON.parse(readFileSync(join(itemsDir, f), 'utf-8'));
      }
    }
  } catch { /* skip */ }
  return null;
}

// --- Find active tmux session ---
function findTmuxSession(issueNumber) {
  const result = exec('tmux list-windows -t zapat -F "#{window_name}"');
  if (!result) return null;
  const windows = result.split('\n').filter(Boolean);
  const match = windows.find(w => w.includes(`${issueNumber}`));
  return match || null;
}

// --- Compute progress ---
function computeProgress(subIssues, prs) {
  const issuesDone = subIssues.filter(i => i.state === 'CLOSED').length;
  const issuesTotal = subIssues.length;
  const prsMerged = prs.filter(p => p.merged).length;
  const prsTotal = prs.length;

  const total = issuesTotal + prsTotal;
  const done = issuesDone + prsMerged;
  const percent = total > 0 ? Math.round((done / total) * 100) : 0;

  return {
    issues: { done: issuesDone, total: issuesTotal },
    prs: { merged: prsMerged, total: prsTotal },
    percent
  };
}

// --- Compute overall phase ---
function computePhase(subIssues, prs) {
  if (subIssues.length === 0) return 'unknown';
  if (subIssues.every(i => i.state === 'CLOSED') && prs.every(p => p.merged)) return 'done';

  const hasResearch = subIssues.some(i => i.labels.includes('agent-research') && i.state === 'OPEN');
  if (hasResearch && prs.length === 0) return 'research';

  const hasRework = prs.some(p => p.state === 'OPEN' && p.reviewDecision === 'CHANGES_REQUESTED');
  if (hasRework) return 'rework';

  const hasReview = prs.some(p => p.state === 'OPEN' && !p.merged && p.reviewDecision !== 'CHANGES_REQUESTED');
  if (hasReview) return 'review';

  return 'implementation';
}

// --- Build dependency graph ---
function buildDependencyGraph(subIssues) {
  const nodes = subIssues.map(i => i.number);
  const edges = [];

  for (const issue of subIssues) {
    for (const dep of issue.dependencies) {
      if (nodes.includes(dep)) {
        edges.push({ from: dep, to: issue.number });
      }
    }
  }

  // Find critical path (longest chain of open issues)
  const criticalPath = findCriticalPath(subIssues, edges);

  return { nodes, edges, criticalPath };
}

function findCriticalPath(subIssues, edges) {
  const openIssues = new Set(subIssues.filter(i => i.state === 'OPEN').map(i => i.number));
  const adjList = new Map();

  for (const n of openIssues) adjList.set(n, []);
  for (const e of edges) {
    if (openIssues.has(e.from) && openIssues.has(e.to)) {
      if (adjList.has(e.from)) adjList.get(e.from).push(e.to);
    }
  }

  let longestPath = [];
  for (const start of openIssues) {
    const path = dfs(start, adjList, new Set());
    if (path.length > longestPath.length) longestPath = path;
  }

  return longestPath;
}

function dfs(node, adjList, visited) {
  if (visited.has(node)) return [];
  visited.add(node);

  let longest = [node];
  for (const next of (adjList.get(node) || [])) {
    const path = dfs(next, adjList, new Set(visited));
    if (path.length + 1 > longest.length) {
      longest = [node, ...path];
    }
  }
  return longest;
}

// --- Find blockers ---
function findBlockers(subIssues, prs) {
  const blockers = [];

  for (const issue of subIssues) {
    // Blocked by open dependencies
    for (const dep of issue.dependencies) {
      const depIssue = subIssues.find(i => i.number === dep);
      if (depIssue && depIssue.state === 'OPEN') {
        blockers.push({
          type: 'dependency',
          issue: issue.number,
          blockedBy: dep,
          message: `#${issue.number} blocked by open #${dep}`
        });
      }
    }

    // Human-only label
    if (issue.labels.includes('human-only')) {
      blockers.push({
        type: 'human_decision',
        issue: issue.number,
        message: `#${issue.number} requires human decision`
      });
    }

    // Pipeline failures
    if (issue.pipelineStatus && (issue.pipelineStatus.status === 'failed' || issue.pipelineStatus.status === 'abandoned')) {
      blockers.push({
        type: 'pipeline_failure',
        issue: issue.number,
        message: `#${issue.number} pipeline ${issue.pipelineStatus.status}: ${issue.pipelineStatus.last_error || 'unknown error'}`
      });
    }
  }

  // Rework PRs
  for (const pr of prs) {
    if (pr.state === 'OPEN' && pr.reviewDecision === 'CHANGES_REQUESTED') {
      blockers.push({
        type: 'rework_needed',
        pr: pr.number,
        message: `PR #${pr.number} needs rework`
      });
    }
  }

  return blockers;
}

// --- Find risks ---
function findRisks(subIssues, prs) {
  const risks = [];

  for (const issue of subIssues) {
    // Repeated failures
    if (issue.pipelineStatus && issue.pipelineStatus.attempts >= 2) {
      risks.push({
        type: 'repeated_failures',
        issue: issue.number,
        attempts: issue.pipelineStatus.attempts,
        message: `#${issue.number} has ${issue.pipelineStatus.attempts} attempts`
      });
    }

    // Human-only items
    if (issue.labels.includes('human-only')) {
      risks.push({
        type: 'human_only',
        issue: issue.number,
        message: `#${issue.number} requires human input`
      });
    }
  }

  // Changes requested PRs
  for (const pr of prs) {
    if (pr.reviewDecision === 'CHANGES_REQUESTED') {
      risks.push({
        type: 'changes_requested',
        pr: pr.number,
        message: `PR #${pr.number} has changes requested`
      });
    }
  }

  // Capacity check
  const slotsDir = join(getAutomationDir(), 'state', 'agent-work-slots');
  if (existsSync(slotsDir)) {
    try {
      const max = parseInt(getConfigValue('MAX_CONCURRENT_WORK', '10'));
      const active = readdirSync(slotsDir).filter(f => f.endsWith('.pid')).length;
      if (max > 0 && (active / max) >= 0.8) {
        risks.push({
          type: 'capacity',
          active,
          max,
          message: `Slot usage at ${active}/${max} (${Math.round(active / max * 100)}%)`
        });
      }
    } catch { /* skip */ }
  }

  return risks;
}

// --- Find active work ---
function findActiveWork(subIssues) {
  const active = [];
  for (const issue of subIssues) {
    if (issue.tmuxSession) {
      active.push({
        issue: issue.number,
        title: issue.title,
        session: issue.tmuxSession
      });
    } else if (issue.pipelineStatus && issue.pipelineStatus.status === 'running') {
      active.push({
        issue: issue.number,
        title: issue.title,
        session: null
      });
    }
  }
  return active;
}

// --- Compute ETAs ---
function computeETAs(subIssues, prs) {
  try {
    const metrics = readMetrics({ days: 30 });
    if (metrics.length === 0) return null;

    const implMetrics = metrics.filter(m => m.job && m.job.includes('work') && m.status === 'success' && m.duration_s > 0);
    const reviewMetrics = metrics.filter(m => m.job && (m.job.includes('review') || m.job.includes('pr')) && m.status === 'success' && m.duration_s > 0);

    const avgImpl = implMetrics.length > 0 ? Math.round(implMetrics.reduce((s, m) => s + m.duration_s, 0) / implMetrics.length / 60) : null;
    const avgReview = reviewMetrics.length > 0 ? Math.round(reviewMetrics.reduce((s, m) => s + m.duration_s, 0) / reviewMetrics.length / 60) : null;

    const remainingIssues = subIssues.filter(i => i.state === 'OPEN').length;
    const openPRs = prs.filter(p => p.state === 'OPEN' && !p.merged).length;
    const maxConcurrent = parseInt(getConfigValue('MAX_CONCURRENT_WORK', '10'));
    const parallelism = Math.min(remainingIssues, maxConcurrent);

    let estimatedMinutes = null;
    let confidence = 'low';

    if (avgImpl !== null && remainingIssues > 0) {
      const implTime = parallelism > 0 ? Math.ceil(remainingIssues / parallelism) * avgImpl : remainingIssues * avgImpl;
      const reviewTime = avgReview !== null ? openPRs * avgReview : 0;
      estimatedMinutes = implTime + reviewTime;

      if (implMetrics.length >= 5 && reviewMetrics.length >= 3) confidence = 'high';
      else if (implMetrics.length >= 2) confidence = 'medium';
    }

    return {
      avgImplementation: avgImpl,
      avgReview: avgReview,
      remainingIssues,
      openPRs,
      estimatedMinutes,
      confidence
    };
  } catch {
    return null;
  }
}

// --- Compute next steps ---
function computeNextSteps(subIssues, prs) {
  const steps = [];

  // PRs awaiting review/merge
  for (const pr of prs) {
    if (pr.state === 'OPEN' && !pr.merged && pr.reviewDecision !== 'CHANGES_REQUESTED') {
      steps.push(`PR #${pr.number} awaiting review/merge`);
    }
  }

  // Unblocked issues ready for work
  const closedIssues = new Set(subIssues.filter(i => i.state === 'CLOSED').map(i => i.number));
  for (const issue of subIssues) {
    if (issue.state !== 'OPEN') continue;
    if (issue.labels.includes('human-only')) continue;
    const allDepsResolved = issue.dependencies.every(d => closedIssues.has(d));
    if (allDepsResolved && !issue.tmuxSession) {
      steps.push(`#${issue.number} is unblocked and ready for work`);
    }
  }

  // What unblocks when current work finishes
  for (const issue of subIssues) {
    if (issue.state !== 'OPEN') continue;
    if (!issue.tmuxSession && !(issue.pipelineStatus && issue.pipelineStatus.status === 'running')) continue;
    // Find what this issue blocks
    const blockedIssues = subIssues.filter(i =>
      i.state === 'OPEN' && i.dependencies.includes(issue.number)
    );
    if (blockedIssues.length > 0) {
      const blockedNums = blockedIssues.map(i => `#${i.number}`).join(', ');
      steps.push(`When #${issue.number} completes, it will unblock ${blockedNums}`);
    }
  }

  // Human decisions needed
  for (const issue of subIssues) {
    if (issue.labels.includes('human-only') && issue.state === 'OPEN') {
      steps.push(`Human decision needed on #${issue.number}`);
    }
  }

  return steps;
}
