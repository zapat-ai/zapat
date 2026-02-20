#!/usr/bin/env node
// tests/check-consistency.mjs
// Cross-file consistency checker for Zapat.
// Validates label strings, dashboard parity, env defaults, file paths, and prompt placeholders.
// Run: node tests/check-consistency.mjs

import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT = join(__dirname, '..');

let failures = 0;
let passes = 0;

function check(name, condition, message) {
  if (condition) {
    passes++;
  } else {
    failures++;
    console.log(`  FAIL: ${name} — ${message}`);
  }
}

function readFile(relPath) {
  return readFileSync(join(ROOT, relPath), 'utf-8');
}

function fileExists(relPath) {
  return existsSync(join(ROOT, relPath));
}

function setsEqual(a, b) {
  if (a.size !== b.size) return false;
  for (const item of a) {
    if (!b.has(item)) return false;
  }
  return true;
}

// Returns true if label looks like a pipeline label (not a CSS class, directory, etc.)
function isPipelineLabel(label) {
  const pipelinePatterns = [
    /^agent$/,
    /^agent-work$/,
    /^agent-research$/,
    /^agent-write-tests$/,
    /^hold$/,
    /^human-only$/,
    /^triaged$/,
    /^needs-rebase$/,
    /^zapat-/,
  ];
  return pipelinePatterns.some(p => p.test(label));
}

// ─────────────────────────────────────────────────────────────────────────────
// 1a. Label Consistency
// ─────────────────────────────────────────────────────────────────────────────
console.log('\n1a. Label Consistency');

// Extract canonical labels from setup-labels.sh (parse the LABELS array)
// Each label line looks like: "labelname|COLOR|description"
const setupLabelsContent = readFile('bin/setup-labels.sh');
const canonicalLabels = new Set();
for (const line of setupLabelsContent.split('\n')) {
  const match = line.match(/^\s*"([a-zA-Z0-9_-]+)\|[A-Fa-f0-9]+\|/);
  if (match) {
    canonicalLabels.add(match[1]);
  }
}

check('setup-labels.sh has labels', canonicalLabels.size > 10,
  `Expected 10+ labels, found ${canonicalLabels.size}`);

// Known external labels — not created by setup-labels.sh but referenced validly
const knownExternalLabels = new Set([
  'triaged',   // Applied by triage agent, not pre-created
]);

const allValidLabels = new Set([...canonicalLabels, ...knownExternalLabels]);

// Extract pipeline labels from dashboard.mjs
const dashboardMjs = readFile('src/commands/dashboard.mjs');
const dashboardLabels = new Set();
for (const match of dashboardMjs.matchAll(/'([a-z][a-z0-9-]*)'/g)) {
  if (isPipelineLabel(match[1])) {
    dashboardLabels.add(match[1]);
  }
}

for (const label of dashboardLabels) {
  check(`dashboard.mjs label "${label}" exists in setup-labels.sh`,
    allValidLabels.has(label),
    `Label "${label}" used in dashboard.mjs but not in setup-labels.sh`);
}

// Extract pipeline labels from data.ts
const dataTs = readFile('dashboard/src/lib/data.ts');
const dataTsLabels = new Set();
for (const match of dataTs.matchAll(/'([a-z][a-z0-9-]*)'/g)) {
  if (isPipelineLabel(match[1])) {
    dataTsLabels.add(match[1]);
  }
}

for (const label of dataTsLabels) {
  check(`data.ts label "${label}" exists in setup-labels.sh`,
    allValidLabels.has(label),
    `Label "${label}" used in data.ts but not in setup-labels.sh`);
}

// Extract labels from poll-github.sh (--label, --add-label, --remove-label flags)
const pollGithub = readFile('bin/poll-github.sh');
const pollLabels = new Set();
for (const match of pollGithub.matchAll(/--(?:add-|remove-)?label\s+"([^"]+)"/g)) {
  pollLabels.add(match[1]);
}

for (const label of pollLabels) {
  check(`poll-github.sh label "${label}" exists in setup-labels.sh`,
    allValidLabels.has(label),
    `Label "${label}" used in poll-github.sh but not in setup-labels.sh`);
}

// ─────────────────────────────────────────────────────────────────────────────
// 1b. Dashboard Parity
// ─────────────────────────────────────────────────────────────────────────────
console.log('\n1b. Dashboard Parity (dashboard.mjs vs data.ts)');

// Extract labels checked inside a classify function
function extractClassifyLabels(content, funcName) {
  const labels = new Set();
  const funcRegex = new RegExp(
    `function ${funcName}\\b[^{]*\\{([\\s\\S]*?)\\n\\}`, 'm'
  );
  const funcMatch = content.match(funcRegex);
  if (funcMatch) {
    for (const m of funcMatch[1].matchAll(/includes\(['"]([^'"]+)['"]\)/g)) {
      labels.add(m[1]);
    }
  }
  return labels;
}

const mjsPrLabels = extractClassifyLabels(dashboardMjs, 'classifyPrStage');
const tsPrLabels = extractClassifyLabels(dataTs, 'classifyPrStage');

check('classifyPrStage handles same labels',
  setsEqual(mjsPrLabels, tsPrLabels),
  `dashboard.mjs: {${[...mjsPrLabels].join(', ')}} vs data.ts: {${[...tsPrLabels].join(', ')}}`);

const mjsIssueLabels = extractClassifyLabels(dashboardMjs, 'classifyIssueStage');
const tsIssueLabels = extractClassifyLabels(dataTs, 'classifyIssueStage');

check('classifyIssueStage handles same labels',
  setsEqual(mjsIssueLabels, tsIssueLabels),
  `dashboard.mjs: {${[...mjsIssueLabels].join(', ')}} vs data.ts: {${[...tsIssueLabels].join(', ')}}`);

// Extract the label filter arrays used in PR and issue processing blocks.
// The pattern is: labelNames.some(l => ['label1', 'label2', ...].includes(l))
// We find the first .some() filter after the JSON.parse of prJson or issueJson.
function extractFilterArray(content, varPrefix) {
  const labels = new Set();
  const lines = content.split('\n');

  // Find the PR or issue processing block by looking for JSON.parse(varPrefix)
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].includes(`JSON.parse(${varPrefix})`)) continue;

    // Look forward for the .some filter with an array
    for (let j = i + 1; j < Math.min(i + 15, lines.length); j++) {
      if (!lines[j].includes('.some')) continue;

      // Found the filter — extract labels from the array on this and following lines
      for (let k = j; k < Math.min(j + 5, lines.length); k++) {
        for (const m of lines[k].matchAll(/'([a-z][a-z0-9-]*)'/g)) {
          if (isPipelineLabel(m[1])) labels.add(m[1]);
        }
        // Stop at the end of the .includes() call
        if (lines[k].includes('.includes(l)') || lines[k].includes('.includes(l)')) break;
      }
      break;
    }
    break; // Only match the first occurrence
  }
  return labels;
}

const mjsPrFilter = extractFilterArray(dashboardMjs, 'prJson');
const tsPrFilter = extractFilterArray(dataTs, 'prJson');

check('PR filter labels match between dashboard.mjs and data.ts',
  setsEqual(mjsPrFilter, tsPrFilter),
  `dashboard.mjs: {${[...mjsPrFilter].join(', ')}} vs data.ts: {${[...tsPrFilter].join(', ')}}`);

const mjsIssueFilter = extractFilterArray(dashboardMjs, 'issueJson');
const tsIssueFilter = extractFilterArray(dataTs, 'issueJson');

check('Issue filter labels match between dashboard.mjs and data.ts',
  setsEqual(mjsIssueFilter, tsIssueFilter),
  `dashboard.mjs: {${[...mjsIssueFilter].join(', ')}} vs data.ts: {${[...tsIssueFilter].join(', ')}}`);

// ─────────────────────────────────────────────────────────────────────────────
// 1c. Environment Variable Consistency
// ─────────────────────────────────────────────────────────────────────────────
console.log('\n1c. Environment Variable Defaults');

const envExample = readFile('.env.example');
const startupSh = readFile('bin/startup.sh');

// Extract DASHBOARD_PORT from .env.example
const envPortMatch = envExample.match(/^DASHBOARD_PORT=(\d+)/m);
const envPort = envPortMatch ? envPortMatch[1] : null;

// Extract DASHBOARD_PORT default from startup.sh
const startupPortMatch = startupSh.match(/DASHBOARD_PORT=\$\{DASHBOARD_PORT:-(\d+)\}/);
const startupPort = startupPortMatch ? startupPortMatch[1] : null;

check('DASHBOARD_PORT default matches between .env.example and startup.sh',
  envPort && startupPort && envPort === startupPort,
  `.env.example: ${envPort}, startup.sh: ${startupPort}`);

// ─────────────────────────────────────────────────────────────────────────────
// 1d. File Path Verification
// ─────────────────────────────────────────────────────────────────────────────
console.log('\n1d. File/Directory Path Verification (README.md)');

const readmeContent = readFile('README.md');

// Extract top-level directory paths from the architecture tree in README.md.
// The tree block starts after "zapat/" and ends at "```".
// Directory lines are indented by 2 spaces: "  bin/              Description"
const archTreePaths = [];
let inArchTree = false;
for (const line of readmeContent.split('\n')) {
  if (line.trim() === 'zapat/') {
    inArchTree = true;
    continue;
  }
  if (inArchTree && /^```/.test(line)) {
    inArchTree = false;
    continue;
  }
  if (inArchTree) {
    const dirMatch = line.match(/^\s{2}(\w[\w-]*\/)\s/);
    if (dirMatch) {
      archTreePaths.push(dirMatch[1].replace(/\/$/, ''));
    }
  }
}

for (const dirPath of archTreePaths) {
  check(`README.md path "${dirPath}/" exists`,
    fileExists(dirPath),
    `Directory "${dirPath}" referenced in README.md architecture tree but doesn't exist`);
}

// ─────────────────────────────────────────────────────────────────────────────
// 1e. Prompt Placeholder Verification
// ─────────────────────────────────────────────────────────────────────────────
console.log('\n1e. Prompt Placeholder Verification');

// Auto-injected placeholders (from substitute_prompt in lib/common.sh)
const autoInjected = new Set([
  'REPO_MAP', 'BUILDER_AGENT', 'SECURITY_AGENT', 'PRODUCT_AGENT', 'UX_AGENT',
  'ORG_NAME', 'COMPLIANCE_RULES', 'PROJECT_CONTEXT', 'PROJECT_NAME',
  'SHARED_FOOTER',
  'SUBAGENT_MODEL'
]);

// Map of prompt template -> trigger script
const promptToTrigger = {
  'prompts/implement-issue.txt': 'triggers/on-work-issue.sh',
  'prompts/pr-review.txt': 'triggers/on-new-pr.sh',
  'prompts/issue-triage.txt': 'triggers/on-new-issue.sh',
  'prompts/rework-pr.txt': 'triggers/on-rework-pr.sh',
  'prompts/research-issue.txt': 'triggers/on-research-issue.sh',
  'prompts/write-tests.txt': 'triggers/on-write-tests.sh',
  'prompts/test-pr.txt': 'triggers/on-test-pr.sh',
};

// Include placeholders from the shared footer (appended by substitute_prompt)
const sharedFooterPath = 'prompts/_shared-footer.txt';
const sharedFooterPlaceholders = new Set();
if (fileExists(sharedFooterPath)) {
  const footerContent = readFile(sharedFooterPath);
  for (const match of footerContent.matchAll(/\{\{(\w+)\}\}/g)) {
    sharedFooterPlaceholders.add(match[1]);
  }
}

for (const [promptPath, triggerPath] of Object.entries(promptToTrigger)) {
  if (!fileExists(promptPath) || !fileExists(triggerPath)) continue;

  const promptContent = readFile(promptPath);
  const triggerContent = readFile(triggerPath);

  // Extract all {{PLACEHOLDER}} tokens from the prompt + shared footer
  const placeholders = new Set();
  for (const match of promptContent.matchAll(/\{\{(\w+)\}\}/g)) {
    placeholders.add(match[1]);
  }
  for (const ph of sharedFooterPlaceholders) {
    placeholders.add(ph);
  }

  // Extract variables passed via substitute_prompt "KEY=..." in the trigger.
  // The call spans multiple lines with backslash continuations.
  const triggerVars = new Set();
  const startIdx = triggerContent.indexOf('substitute_prompt');
  if (startIdx !== -1) {
    const callLines = [];
    for (const line of triggerContent.slice(startIdx).split('\n')) {
      callLines.push(line);
      if (!line.trimEnd().endsWith('\\')) break;
    }
    const callBlock = callLines.join('\n');
    for (const m of callBlock.matchAll(/"(\w+)=/g)) {
      triggerVars.add(m[1]);
    }
  }

  // Every placeholder should be either auto-injected or provided by the trigger
  const allProvided = new Set([...autoInjected, ...triggerVars]);
  const missing = [];
  for (const ph of placeholders) {
    if (!allProvided.has(ph)) {
      missing.push(ph);
    }
  }

  check(`${promptPath}: all placeholders provided`,
    missing.length === 0,
    `Missing: ${missing.join(', ')} (trigger provides: ${[...triggerVars].join(', ')})`);
}

// ─────────────────────────────────────────────────────────────────────────────
// 1f. Documentation label consistency
// ─────────────────────────────────────────────────────────────────────────────
console.log('\n1f. Documentation Label Consistency');

const userFacingLabels = [
  'agent', 'agent-work', 'agent-research', 'agent-write-tests', 'hold', 'human-only',
];
const statusLabels = [
  'zapat-triaging', 'zapat-implementing', 'zapat-review', 'zapat-testing',
  'zapat-rework', 'needs-rebase',
];

const claudeMd = readFile('CLAUDE.md');
const readmeMd = readFile('README.md');

const introMd = fileExists('docs/INTRODUCTION.md') ? readFile('docs/INTRODUCTION.md') : null;

for (const label of userFacingLabels) {
  check(`CLAUDE.md documents user label "${label}"`,
    claudeMd.includes(`\`${label}\``),
    `Label "${label}" missing from CLAUDE.md labels table`);
  check(`README.md documents user label "${label}"`,
    readmeMd.includes(`\`${label}\``),
    `Label "${label}" missing from README.md labels table`);
  if (introMd) {
    check(`INTRODUCTION.md documents user label "${label}"`,
      introMd.includes(`\`${label}\``),
      `Label "${label}" missing from docs/INTRODUCTION.md labels table`);
  }
}

for (const label of statusLabels) {
  check(`CLAUDE.md documents status label "${label}"`,
    claudeMd.includes(`\`${label}\``),
    `Status label "${label}" missing from CLAUDE.md labels table`);
}

// ─────────────────────────────────────────────────────────────────────────────
// 1g. Function name references in docs
// ─────────────────────────────────────────────────────────────────────────────
console.log('\n1g. Documentation Function References');

const commonSh = readFile('lib/common.sh');
const customizationMd = readFile('docs/customization.md');
const contributingMd = readFile('CONTRIBUTING.md');

const obsoleteFunctions = ['build_prompt', 'dispatch_trigger', 'has_label'];
for (const fn of obsoleteFunctions) {
  check(`docs/customization.md does not reference obsolete "${fn}"`,
    !customizationMd.includes(fn),
    `"${fn}" referenced in customization.md but doesn't exist in lib/common.sh`);
  check(`CONTRIBUTING.md does not reference obsolete "${fn}"`,
    !contributingMd.includes(fn),
    `"${fn}" referenced in CONTRIBUTING.md but doesn't exist in lib/common.sh`);
}

check('lib/common.sh defines substitute_prompt',
  commonSh.includes('substitute_prompt()'),
  'substitute_prompt function not found in lib/common.sh');

// ─────────────────────────────────────────────────────────────────────────────
// Summary
// ─────────────────────────────────────────────────────────────────────────────
console.log('\n' + '='.repeat(60));
console.log(`Results: ${passes} passed, ${failures} failed`);
console.log('='.repeat(60));

if (failures > 0) {
  process.exit(1);
}
