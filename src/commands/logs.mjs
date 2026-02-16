import { readdirSync, statSync, existsSync, renameSync, unlinkSync, readFileSync, writeFileSync } from 'fs';
import { join, basename } from 'path';
import { createGzip } from 'zlib';
import { createReadStream, createWriteStream } from 'fs';
import { pipeline } from 'stream/promises';
import { getAutomationDir } from '../lib/config.mjs';

export function registerLogsCommand(program) {
  const logs = program
    .command('logs')
    .description('Log management utilities');

  logs
    .command('rotate')
    .description('Rotate and compress old log and metric files')
    .option('--dry-run', 'Show what would be done without doing it')
    .action(runRotate);
}

async function runRotate(opts) {
  const automationDir = getAutomationDir();
  const logsDir = join(automationDir, 'logs');
  const dataDir = join(automationDir, 'data');
  const dryRun = opts.dryRun;

  let actions = 0;

  // 1. Compress cron log files in logs/ older than 7 days
  if (existsSync(logsDir)) {
    const sevenDaysAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
    const thirtyDaysAgo = Date.now() - 30 * 24 * 60 * 60 * 1000;
    const fourteenDaysAgo = Date.now() - 14 * 24 * 60 * 60 * 1000;

    const files = readdirSync(logsDir);

    for (const file of files) {
      const fullPath = join(logsDir, file);
      let stat;
      try { stat = statSync(fullPath); } catch { continue; }
      if (!stat.isFile()) continue;

      // Delete compressed logs older than 30 days
      if (file.endsWith('.gz') && stat.mtimeMs < thirtyDaysAgo) {
        console.log(`${dryRun ? '[dry-run] ' : ''}Delete old archive: ${file}`);
        if (!dryRun) {
          try { unlinkSync(fullPath); actions++; } catch (e) { console.error(`  Failed: ${e.message}`); }
        }
        continue;
      }

      // Compress plain log files older than 7 days
      if (file.endsWith('.log') && stat.mtimeMs < sevenDaysAgo) {
        console.log(`${dryRun ? '[dry-run] ' : ''}Compress: ${file}`);
        if (!dryRun) {
          try {
            await gzipFile(fullPath, fullPath + '.gz');
            unlinkSync(fullPath);
            actions++;
          } catch (e) { console.error(`  Failed: ${e.message}`); }
        }
        continue;
      }

      // Clean orphaned job logs older than 14 days (pattern: jobname-timestamp.log)
      if (file.match(/^.+-\d{4}-\d{2}-\d{2}-.+\.log$/) && stat.mtimeMs < fourteenDaysAgo) {
        console.log(`${dryRun ? '[dry-run] ' : ''}Delete orphaned: ${file}`);
        if (!dryRun) {
          try { unlinkSync(fullPath); actions++; } catch (e) { console.error(`  Failed: ${e.message}`); }
        }
      }
    }

    // Rotate logs/structured.jsonl if older than 7 days
    const structuredLog = join(logsDir, 'structured.jsonl');
    if (existsSync(structuredLog)) {
      const stat = statSync(structuredLog);
      if (stat.mtimeMs < sevenDaysAgo) {
        const dateStr = new Date(stat.mtimeMs).toISOString().split('T')[0];
        const archiveName = `structured-${dateStr}.jsonl.gz`;
        console.log(`${dryRun ? '[dry-run] ' : ''}Rotate structured.jsonl -> ${archiveName}`);
        if (!dryRun) {
          try {
            await gzipFile(structuredLog, join(logsDir, archiveName));
            unlinkSync(structuredLog);
            actions++;
          } catch (e) { console.error(`  Failed: ${e.message}`); }
        }
      }
    }
  }

  // 2. Rotate data/metrics.jsonl if older than 30 days
  if (existsSync(dataDir)) {
    const metricsPath = join(dataDir, 'metrics.jsonl');
    if (existsSync(metricsPath)) {
      const stat = statSync(metricsPath);
      const thirtyDaysAgo = Date.now() - 30 * 24 * 60 * 60 * 1000;
      if (stat.mtimeMs < thirtyDaysAgo) {
        const dateObj = new Date(stat.mtimeMs);
        const monthStr = `${dateObj.getFullYear()}-${String(dateObj.getMonth() + 1).padStart(2, '0')}`;
        const archiveName = `metrics-${monthStr}.jsonl.gz`;
        console.log(`${dryRun ? '[dry-run] ' : ''}Rotate metrics.jsonl -> ${archiveName}`);
        if (!dryRun) {
          try {
            await gzipFile(metricsPath, join(dataDir, archiveName));
            unlinkSync(metricsPath);
            actions++;
          } catch (e) { console.error(`  Failed: ${e.message}`); }
        }
      }
    }
  }

  if (actions > 0) {
    console.log(`\nCompleted ${actions} rotation action(s).`);
  } else if (!dryRun) {
    console.log('Nothing to rotate.');
  }
}

async function gzipFile(inputPath, outputPath) {
  const gzip = createGzip();
  const source = createReadStream(inputPath);
  const destination = createWriteStream(outputPath);
  await pipeline(source, gzip, destination);
}
