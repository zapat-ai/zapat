/**
 * Format program graph as plain text for terminal output.
 */
export function formatPlainText(graph) {
  if (graph.error) return `Error: ${graph.error}`;

  if (!graph.subIssues || graph.subIssues.length === 0) {
    return `Program Status: ${graph.parent.title} (#${graph.parent.number})\n${'='.repeat(60)}\n\nNo sub-issues found for this issue.\nThis issue may not be a program parent, or sub-issues haven't been created yet.`;
  }

  const lines = [];
  const p = graph.progress;

  lines.push(`Program Status: ${graph.parent.title} (#${graph.parent.number})`);
  lines.push('='.repeat(60));
  lines.push(`Phase: ${graph.phase.toUpperCase()} | Progress: ${p.issues.done}/${p.issues.total} sub-issues done, ${p.prs.merged}/${p.prs.total} PRs merged (${p.percent}%)`);
  lines.push('');

  // Progress bar
  const barLen = 30;
  const filled = Math.round(barLen * p.percent / 100);
  const bar = '#'.repeat(filled) + '-'.repeat(barLen - filled);
  lines.push(`  [${bar}] ${p.percent}%`);
  lines.push('');

  // Sub-Issues
  lines.push('Sub-Issues:');
  for (const issue of graph.subIssues) {
    const check = issue.state === 'CLOSED' ? 'x' : ' ';
    const statusParts = [];
    if (issue.pipelineStatus?.status === 'running') statusParts.push('running');
    if (issue.tmuxSession) statusParts.push('ACTIVE');
    const statusStr = statusParts.length > 0 ? ` [${statusParts.join(', ')}]` : '';

    lines.push(`  [${check}] #${issue.number}: ${issue.title} (${issue.state.toLowerCase()})${statusStr}`);

    if (issue.dependencies.length > 0) {
      lines.push(`        Blocked by: ${issue.dependencies.map(d => `#${d}`).join(', ')}`);
    }

    for (const pr of issue.linkedPRs) {
      const prStatus = pr.merged ? 'MERGED' : pr.state;
      const extra = pr.reviewDecision === 'CHANGES_REQUESTED' ? ' (rework needed)' :
                    pr.reviewDecision === 'APPROVED' ? ' (approved)' : '';
      lines.push(`        PR #${pr.number}: ${prStatus}${extra}`);
    }

    if (issue.labels.includes('human-only')) {
      lines.push('        human-only');
    }
  }
  lines.push('');

  // Dependency Chain
  if (graph.graph && graph.graph.edges.length > 0) {
    lines.push('Dependency Chain:');
    for (const edge of graph.graph.edges) {
      lines.push(`  #${edge.from} --> #${edge.to}`);
    }
    // Independent issues
    const depIssues = new Set([...graph.graph.edges.map(e => e.from), ...graph.graph.edges.map(e => e.to)]);
    const independent = graph.graph.nodes.filter(n => !depIssues.has(n));
    for (const n of independent) {
      lines.push(`  #${n} (independent)`);
    }
    if (graph.graph.criticalPath.length > 0) {
      lines.push(`  Critical path: ${graph.graph.criticalPath.map(n => `#${n}`).join(' -> ')}`);
    }
    lines.push('');
  }

  // Blockers
  if (graph.blockers.length > 0) {
    lines.push('Blockers:');
    for (const b of graph.blockers) {
      lines.push(`  [${b.type}] ${b.message}`);
    }
    lines.push('');
  }

  // Active Work
  if (graph.activeWork.length > 0) {
    lines.push('Active Work:');
    for (const w of graph.activeWork) {
      const session = w.session ? ` (tmux: ${w.session})` : '';
      lines.push(`  #${w.issue}: ${w.title}${session}`);
    }
    lines.push('');
  }

  // ETAs
  if (graph.etas) {
    lines.push('ETAs:');
    const parts = [];
    if (graph.etas.avgImplementation !== null) parts.push(`Avg implementation: ${graph.etas.avgImplementation} min`);
    if (graph.etas.avgReview !== null) parts.push(`Avg review: ${graph.etas.avgReview} min`);
    if (parts.length > 0) lines.push(`  ${parts.join(' | ')}`);
    lines.push(`  Remaining: ${graph.etas.remainingIssues} issues, ${graph.etas.openPRs} open PRs`);
    if (graph.etas.estimatedMinutes !== null) {
      lines.push(`  Estimated: ~${graph.etas.estimatedMinutes} min remaining (${graph.etas.confidence} confidence)`);
    }
    lines.push('');
  }

  // Next Steps
  if (graph.nextSteps.length > 0) {
    lines.push('Next Steps:');
    graph.nextSteps.forEach((step, i) => {
      lines.push(`  ${i + 1}. ${step}`);
    });
  }

  return lines.join('\n');
}

/**
 * Format program graph as JSON.
 */
export function formatJSON(graph) {
  return JSON.stringify(graph, null, 2);
}

/**
 * Format program graph for Slack (mrkdwn).
 */
export function formatSlack(graph) {
  if (graph.error) return `:x: Error: ${graph.error}`;

  if (!graph.subIssues || graph.subIssues.length === 0) {
    return `:clipboard: *Program Status: ${graph.parent.title} (#${graph.parent.number})*\n\nNo sub-issues found.`;
  }

  const lines = [];
  const p = graph.progress;

  lines.push(`:clipboard: *Program Status: ${graph.parent.title} (#${graph.parent.number})*`);
  lines.push(`*Phase:* ${graph.phase.toUpperCase()} | *Progress:* ${p.percent}% (${p.issues.done}/${p.issues.total} issues, ${p.prs.merged}/${p.prs.total} PRs)`);
  lines.push('');

  for (const issue of graph.subIssues) {
    const emoji = issue.state === 'CLOSED' ? ':white_check_mark:' :
                  issue.tmuxSession ? ':arrows_counterclockwise:' :
                  issue.labels.includes('human-only') ? ':raising_hand:' : ':radio_button:';
    lines.push(`${emoji} #${issue.number}: ${issue.title}`);
  }

  if (graph.blockers.length > 0) {
    lines.push('');
    lines.push('*Blockers:*');
    for (const b of graph.blockers) {
      lines.push(`:warning: ${b.message}`);
    }
  }

  if (graph.nextSteps.length > 0) {
    lines.push('');
    lines.push('*Next Steps:*');
    graph.nextSteps.slice(0, 3).forEach(step => {
      lines.push(`:arrow_right: ${step}`);
    });
  }

  return lines.join('\n');
}

/**
 * Format program graph as GitHub-flavored markdown.
 * Includes a sentinel comment for idempotent updates.
 */
export function formatGitHub(graph) {
  if (graph.error) return `<!-- zapat-program-status: error -->\n**Error:** ${graph.error}`;

  const num = graph.parent.number;

  if (!graph.subIssues || graph.subIssues.length === 0) {
    return `<!-- zapat-program-status: ${num} -->\n## Program Status\n\nNo sub-issues found for this issue.`;
  }

  const lines = [];
  const p = graph.progress;

  lines.push(`<!-- zapat-program-status: ${num} -->`);
  lines.push(`## Program Status`);
  lines.push('');

  // Progress bar (unicode blocks)
  const barLen = 20;
  const filled = Math.round(barLen * p.percent / 100);
  const bar = '\u2588'.repeat(filled) + '\u2591'.repeat(barLen - filled);
  lines.push(`**Phase:** ${graph.phase.toUpperCase()} | **Progress:** ${p.percent}%`);
  lines.push(`\`${bar}\` ${p.issues.done}/${p.issues.total} issues done, ${p.prs.merged}/${p.prs.total} PRs merged`);
  lines.push('');

  // Sub-issues table
  lines.push('| Issue | Title | Status | PR | Blocked By |');
  lines.push('|-------|-------|--------|-----|------------|');
  for (const issue of graph.subIssues) {
    const status = issue.state === 'CLOSED' ? ':white_check_mark: Done' :
                   issue.tmuxSession ? ':arrows_counterclockwise: Active' :
                   issue.labels.includes('human-only') ? ':bust_in_silhouette: Human' :
                   issue.pipelineStatus?.status === 'running' ? ':gear: Running' :
                   ':radio_button: Open';
    const prLinks = issue.linkedPRs.map(pr => {
      const prState = pr.merged ? ':purple_circle: Merged' :
                      pr.reviewDecision === 'CHANGES_REQUESTED' ? ':red_circle: Rework' :
                      pr.reviewDecision === 'APPROVED' ? ':green_circle: Approved' :
                      ':yellow_circle: Open';
      return `#${pr.number} (${prState})`;
    }).join(', ') || '-';
    const deps = issue.dependencies.map(d => `#${d}`).join(', ') || '-';
    lines.push(`| #${issue.number} | ${issue.title} | ${status} | ${prLinks} | ${deps} |`);
  }
  lines.push('');

  // Blockers
  if (graph.blockers.length > 0) {
    lines.push('### Blockers');
    for (const b of graph.blockers) {
      lines.push(`- :warning: **${b.type}**: ${b.message}`);
    }
    lines.push('');
  }

  // Active work
  if (graph.activeWork.length > 0) {
    lines.push('### Active Work');
    for (const w of graph.activeWork) {
      lines.push(`- :gear: #${w.issue}: ${w.title}`);
    }
    lines.push('');
  }

  // ETAs
  if (graph.etas && graph.etas.estimatedMinutes !== null) {
    lines.push(`### ETAs`);
    lines.push(`- Estimated: ~${graph.etas.estimatedMinutes} min remaining (${graph.etas.confidence} confidence)`);
    lines.push(`- Remaining: ${graph.etas.remainingIssues} issues, ${graph.etas.openPRs} open PRs`);
    lines.push('');
  }

  // Next steps
  if (graph.nextSteps.length > 0) {
    lines.push('### Next Steps');
    graph.nextSteps.forEach((step, i) => {
      lines.push(`${i + 1}. ${step}`);
    });
    lines.push('');
  }

  lines.push(`---`);
  lines.push(`*Updated: ${new Date().toISOString()} by zapat*`);

  return lines.join('\n');
}
