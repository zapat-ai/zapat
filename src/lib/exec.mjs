import { execSync } from 'child_process';

/**
 * Run a shell command and return stdout, or null on failure.
 */
export function exec(cmd, opts = {}) {
  try {
    return execSync(cmd, {
      encoding: 'utf-8',
      timeout: opts.timeout || 30000,
      stdio: ['pipe', 'pipe', 'pipe'],
      ...opts
    }).trim();
  } catch (err) {
    if (opts.throwOnError) throw err;
    return null;
  }
}

/**
 * Run a shell command and return { stdout, stderr, exitCode }.
 */
export function execFull(cmd, opts = {}) {
  try {
    const stdout = execSync(cmd, {
      encoding: 'utf-8',
      timeout: opts.timeout || 30000,
      stdio: ['pipe', 'pipe', 'pipe'],
      ...opts
    }).trim();
    return { stdout, stderr: '', exitCode: 0 };
  } catch (err) {
    return {
      stdout: (err.stdout || '').trim(),
      stderr: (err.stderr || '').trim(),
      exitCode: err.status ?? 1
    };
  }
}
