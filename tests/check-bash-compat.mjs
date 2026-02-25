#!/usr/bin/env node
// Bash 3.2 Compatibility Check
// macOS ships bash 3.2 which lacks features added in bash 4+.
// This test catches usage of bash 4+ features in shell scripts
// that `bash -n` (syntax check) won't flag.

import { readdirSync, readFileSync } from 'fs';
import { join } from 'path';

const ROOT = join(import.meta.dirname, '..');
const DIRS = ['bin', 'lib', 'triggers', 'jobs'];

// Patterns that work syntactically in bash 3.2 but fail at runtime
const FORBIDDEN = [
  {
    pattern: /\bdeclare\s+-A\b/,
    name: 'declare -A (associative arrays)',
    fix: 'Use file-based cache or parallel indexed arrays',
  },
  {
    pattern: /\breadarray\b/,
    name: 'readarray / mapfile',
    fix: 'Use while IFS= read -r loop instead',
  },
  {
    pattern: /\bmapfile\b/,
    name: 'mapfile',
    fix: 'Use while IFS= read -r loop instead',
  },
  {
    pattern: /\$\{![a-zA-Z_]+\[@\]\}/,
    name: '${!array[@]} (associative key iteration)',
    fix: 'Use file-based approach or separate key tracking',
  },
  {
    pattern: /\bcoproc\b/,
    name: 'coproc',
    fix: 'Use named pipes or temp files',
  },
  {
    pattern: /;&|;;&/,
    name: ';& or ;;& (case fall-through)',
    fix: 'Use separate case patterns or if/elif chains',
  },
];

let passed = 0;
let failed = 0;
const failures = [];

console.log('\nBash 3.2 Compatibility Check');
console.log('(macOS ships bash 3.2 — no bash 4+ features allowed)\n');

for (const dir of DIRS) {
  let files;
  try {
    files = readdirSync(join(ROOT, dir)).filter(f => f.endsWith('.sh'));
  } catch {
    continue;
  }

  for (const file of files) {
    const filepath = join(ROOT, dir, file);
    const content = readFileSync(filepath, 'utf-8');
    const lines = content.split('\n');
    let fileClean = true;

    for (const rule of FORBIDDEN) {
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        // Skip comments
        if (line.trimStart().startsWith('#')) continue;
        if (rule.pattern.test(line)) {
          fileClean = false;
          failed++;
          const loc = `${dir}/${file}:${i + 1}`;
          failures.push({ loc, rule: rule.name, fix: rule.fix, line: line.trim() });
          console.log(`not ok - ${loc}: ${rule.name}`);
          console.log(`         ${line.trim()}`);
          console.log(`         Fix: ${rule.fix}`);
        }
      }
    }

    if (fileClean) {
      passed++;
    }
  }
}

console.log(`\n============================================================`);
console.log(`Results: ${passed} file(s) clean, ${failed} violation(s) found`);
console.log(`============================================================\n`);

if (failed > 0) {
  process.exit(1);
}
