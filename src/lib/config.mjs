import { readFileSync, readdirSync, existsSync, statSync } from 'fs';
import { join } from 'path';

let cachedConfig = null;
let cachedRepos = null;
let cachedProjects = null;

/**
 * Get the automation directory root.
 */
export function getAutomationDir() {
  return process.env.AUTOMATION_DIR || join(process.cwd());
}

/**
 * Parse a simple .env file (key=value, skipping comments and blanks).
 * Does NOT override existing process.env values.
 */
export function getConfig() {
  if (cachedConfig) return cachedConfig;

  const envPath = join(getAutomationDir(), '.env');
  const config = {};

  if (existsSync(envPath)) {
    const lines = readFileSync(envPath, 'utf-8').split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx === -1) continue;
      const key = trimmed.slice(0, eqIdx).trim();
      let value = trimmed.slice(eqIdx + 1).trim();
      // Strip surrounding quotes
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      config[key] = value;
    }
  }

  cachedConfig = config;
  return config;
}

/**
 * Get the list of configured projects.
 * Three-tier discovery: projects.conf → directory scan → legacy single-project.
 * Returns array of { slug, name, enabled }.
 */
export function getProjects() {
  if (cachedProjects) return cachedProjects;

  const root = getAutomationDir();
  const confPath = join(root, 'config', 'projects.conf');

  // Tier 1: explicit manifest
  if (existsSync(confPath)) {
    cachedProjects = readFileSync(confPath, 'utf-8').split('\n')
      .filter(l => l.trim() && !l.startsWith('#'))
      .map(l => {
        const [slug, name, enabled] = l.split('\t');
        return {
          slug: slug.trim(),
          name: (name || slug).trim(),
          enabled: (enabled || 'true').trim() === 'true'
        };
      })
      .filter(p => p.enabled);
    return cachedProjects;
  }

  // Tier 2: scan config/*/ for dirs containing repos.conf
  const configDir = join(root, 'config');
  if (existsSync(configDir)) {
    try {
      const dirs = readdirSync(configDir)
        .filter(f => {
          const full = join(configDir, f);
          return statSync(full).isDirectory()
            && existsSync(join(full, 'repos.conf'));
        });
      if (dirs.length > 0) {
        cachedProjects = dirs.map(slug => ({ slug, name: slug, enabled: true }));
        return cachedProjects;
      }
    } catch {
      // Ignore read errors
    }
  }

  // Tier 3: legacy single-project
  if (existsSync(join(root, 'config', 'repos.conf'))) {
    cachedProjects = [{ slug: 'default', name: 'Default Project', enabled: true }];
    return cachedProjects;
  }

  cachedProjects = [];
  return cachedProjects;
}

/**
 * Get the config directory for a project.
 * Legacy: "default" with no config/default/ dir → top-level config/
 */
export function getProjectConfigDir(slug) {
  const root = getAutomationDir();

  if (slug === 'default'
    && !existsSync(join(root, 'config', 'default'))
    && existsSync(join(root, 'config', 'repos.conf'))) {
    return join(root, 'config');
  }

  return join(root, 'config', slug);
}

/**
 * Read repos for a specific project.
 * Returns array of { repo, localPath, type }.
 */
export function getProjectRepos(slug) {
  const configDir = getProjectConfigDir(slug);
  const confPath = join(configDir, 'repos.conf');
  const repos = [];

  if (!existsSync(confPath)) return repos;

  const lines = readFileSync(confPath, 'utf-8').split('\n');
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const parts = trimmed.split('\t');
    if (parts.length >= 3) {
      repos.push({
        repo: parts[0].trim(),
        localPath: parts[1].trim(),
        type: parts[2].trim()
      });
    }
  }

  return repos;
}

/**
 * Read repos, optionally filtered by project slug.
 * If slug given, returns repos for that project.
 * If no slug, returns all repos across all projects.
 * Backward-compatible: single-project works identically to before.
 */
export function getRepos(slug) {
  // If a specific slug is given, use it
  if (slug) return getProjectRepos(slug);

  // Check cache for "all repos" case
  if (cachedRepos) return cachedRepos;

  const projects = getProjects();
  if (projects.length === 0) {
    cachedRepos = [];
    return cachedRepos;
  }

  // Single project: return its repos directly
  if (projects.length === 1) {
    cachedRepos = getProjectRepos(projects[0].slug);
    return cachedRepos;
  }

  // Multiple projects: aggregate with project field
  const all = [];
  for (const p of projects) {
    for (const repo of getProjectRepos(p.slug)) {
      all.push({ ...repo, project: p.slug });
    }
  }
  cachedRepos = all;
  return cachedRepos;
}

/**
 * Get a config value with fallback.
 */
export function getConfigValue(key, fallback = '') {
  const config = getConfig();
  return config[key] || process.env[key] || fallback;
}
