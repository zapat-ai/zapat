import { readMetrics, recordMetric } from '../lib/metrics.mjs';

export function registerMetricsCommand(program) {
  const metrics = program
    .command('metrics')
    .description('Record and query pipeline metrics');

  metrics
    .command('record')
    .description('Record a metric entry')
    .argument('<json>', 'JSON string with metric data')
    .action(runRecord);

  metrics
    .command('query')
    .description('Query recorded metrics')
    .option('--days <n>', 'Filter to last N days', '7')
    .option('--job <name>', 'Filter by job name')
    .option('--status <status>', 'Filter by status (success/failure)')
    .option('--last-hour', 'Only show entries from the last hour')
    .option('--summary', 'Show summary statistics instead of raw data')
    .action(runQuery);
}

function runRecord(jsonStr) {
  let entry;
  try {
    entry = JSON.parse(jsonStr);
  } catch (err) {
    console.error(`Invalid JSON: ${err.message}`);
    process.exitCode = 1;
    return;
  }

  try {
    const recorded = recordMetric(entry);
    console.log(JSON.stringify(recorded));
  } catch (err) {
    console.error(`Failed to record metric: ${err.message}`);
    process.exitCode = 1;
  }
}

function runQuery(opts) {
  const filters = {
    days: parseInt(opts.days) || 7,
    job: opts.job,
    status: opts.status,
    lastHour: opts.lastHour
  };

  const entries = readMetrics(filters);

  if (opts.summary) {
    const total = entries.length;
    const success = entries.filter(e => e.status === 'success').length;
    const failure = entries.filter(e => e.status === 'failure').length;
    const other = total - success - failure;

    const durations = entries.filter(e => e.duration_s > 0).map(e => e.duration_s);
    const avgDuration = durations.length > 0
      ? Math.round(durations.reduce((a, b) => a + b, 0) / durations.length)
      : 0;

    // Jobs by type
    const jobCounts = {};
    for (const e of entries) {
      jobCounts[e.job] = (jobCounts[e.job] || 0) + 1;
    }

    // Repos
    const repoCounts = {};
    for (const e of entries) {
      if (e.repo) repoCounts[e.repo] = (repoCounts[e.repo] || 0) + 1;
    }

    console.log(JSON.stringify({
      period: `${filters.days} days`,
      total,
      success,
      failure,
      other,
      successRate: total > 0 ? `${Math.round((success / total) * 100)}%` : '0%',
      avgDurationSeconds: avgDuration,
      byJob: jobCounts,
      byRepo: repoCounts
    }, null, 2));
    return;
  }

  console.log(JSON.stringify(entries, null, 2));
}
