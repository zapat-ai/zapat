import { readFileSync, existsSync, appendFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { getAutomationDir } from './config.mjs';

/**
 * Get the path to the metrics JSONL file.
 */
export function getMetricsPath() {
  return join(getAutomationDir(), 'data', 'metrics.jsonl');
}

/**
 * Ensure the data directory exists.
 */
export function ensureDataDir() {
  const dataDir = join(getAutomationDir(), 'data');
  mkdirSync(dataDir, { recursive: true });
  return dataDir;
}

/**
 * Read all metrics entries, optionally filtered.
 * @param {Object} opts
 * @param {number} opts.days - Only include entries from the last N days
 * @param {string} opts.job - Filter by job name
 * @param {string} opts.status - Filter by status
 * @param {boolean} opts.lastHour - Only include entries from the last hour
 * @returns {Array<Object>}
 */
export function readMetrics(opts = {}) {
  const metricsPath = getMetricsPath();
  if (!existsSync(metricsPath)) return [];

  const lines = readFileSync(metricsPath, 'utf-8').split('\n').filter(Boolean);
  let entries = [];

  for (const line of lines) {
    try {
      entries.push(JSON.parse(line));
    } catch {
      // Skip malformed lines
    }
  }

  const now = Date.now();

  if (opts.days) {
    const cutoff = now - opts.days * 24 * 60 * 60 * 1000;
    entries = entries.filter(e => new Date(e.timestamp).getTime() >= cutoff);
  }

  if (opts.lastHour) {
    const cutoff = now - 60 * 60 * 1000;
    entries = entries.filter(e => new Date(e.timestamp).getTime() >= cutoff);
  }

  if (opts.job) {
    entries = entries.filter(e => e.job === opts.job);
  }

  if (opts.status) {
    entries = entries.filter(e => e.status === opts.status);
  }

  if (opts.project) {
    entries = entries.filter(e => (e.project || 'default') === opts.project);
  }

  return entries;
}

/**
 * Append a metric entry to data/metrics.jsonl.
 */
export function recordMetric(entry) {
  ensureDataDir();
  const metricsPath = getMetricsPath();

  // Validate required fields
  const required = ['job', 'status'];
  for (const field of required) {
    if (!entry[field]) {
      throw new Error(`Missing required field: ${field}`);
    }
  }

  const record = {
    timestamp: entry.timestamp || new Date().toISOString(),
    project: entry.project || 'default',
    job: entry.job,
    repo: entry.repo || '',
    item: entry.item || '',
    exit_code: entry.exit_code ?? 0,
    start: entry.start || '',
    end: entry.end || '',
    duration_s: entry.duration_s ?? 0,
    status: entry.status
  };

  appendFileSync(metricsPath, JSON.stringify(record) + '\n');
  return record;
}
