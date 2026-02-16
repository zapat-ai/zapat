import { exec } from '../lib/exec.mjs';
import { getRepos } from '../lib/config.mjs';

export function registerRiskCommand(program) {
  program
    .command('risk')
    .description('Classify risk level of a pull request')
    .argument('<repo>', 'Repository (owner/repo)')
    .argument('<pr-number>', 'Pull request number')
    .option('--json', 'Output as JSON (default)')
    .action(runRisk);
}

const HIGH_RISK_PATTERNS = [
  /^.*auth\//i,
  /^.*iam/i,
  /^.*security/i,
  /^.*lambda.*handler/i,
  /^.*middleware\/auth/i,
  /^.*\.env/,
  /^.*secrets?/i,
  /^.*credentials/i,
  /^.*policy\.(json|yaml|yml|ts)$/i,
  /^.*schema.*\.(sql|prisma|ts)$/i,
  /^.*migration/i,
  /^.*cdk.*stack/i,
  /^.*permission/i,
  /^.*encrypt/i,
  /^.*token/i,
  /^.*session/i,
  /^.*password/i,
  /^.*Podfile(\.lock)?$/,
  /^.*package-lock\.json$/,
];

const MEDIUM_RISK_PATTERNS = [
  /^.*component/i,
  /^.*view/i,
  /^.*screen/i,
  /^.*page/i,
  /^.*api\//i,
  /^.*endpoint/i,
  /^.*service/i,
  /^.*model/i,
  /^.*controller/i,
  /^.*hook/i,
  /^.*store/i,
  /^.*reducer/i,
  /^.*util/i,
  /^.*helper/i,
  /^.*lib\//i,
  /^.*src\//i,
];

const LOW_RISK_PATTERNS = [
  /^.*readme/i,
  /^.*\.md$/i,
  /^.*changelog/i,
  /^.*docs?\//i,
  /^.*comment/i,
  /^.*test/i,
  /^.*spec/i,
  /^.*__tests__/i,
  /^.*\.test\./i,
  /^.*\.spec\./i,
  /^.*\.stories\./i,
  /^.*config\.(json|yaml|yml)$/i,
  /^.*\.prettierrc/i,
  /^.*\.eslintrc/i,
  /^.*tsconfig/i,
];

const REPO_RISK = {
  backend: 2,
  ios: 1,
  web: 1,
  extension: 1,
  'web-legacy': 0,
  marketing: 0,
};

function classifyFile(filepath) {
  for (const pat of HIGH_RISK_PATTERNS) {
    if (pat.test(filepath)) return 'high';
  }
  for (const pat of LOW_RISK_PATTERNS) {
    if (pat.test(filepath)) return 'low';
  }
  for (const pat of MEDIUM_RISK_PATTERNS) {
    if (pat.test(filepath)) return 'medium';
  }
  return 'medium';
}

function runRisk(repo, prNumber) {
  // Get PR details
  const prJson = exec(`gh pr view ${prNumber} --repo "${repo}" --json files,additions,deletions,labels,headRefName`);
  if (!prJson) {
    console.error(`Failed to fetch PR #${prNumber} from ${repo}`);
    process.exitCode = 1;
    return;
  }

  let pr;
  try {
    pr = JSON.parse(prJson);
  } catch (e) {
    console.error(`Failed to parse PR data: ${e.message}`);
    process.exitCode = 1;
    return;
  }

  const files = pr.files || [];
  const additions = pr.additions || 0;
  const deletions = pr.deletions || 0;
  const totalLines = additions + deletions;
  const labels = (pr.labels || []).map(l => l.name);
  const branch = pr.headRefName || '';

  const reasons = [];
  let score = 0;

  // Classify each file
  let highFiles = 0;
  let mediumFiles = 0;
  let lowFiles = 0;

  for (const file of files) {
    const path = file.path || file.filename || '';
    const risk = classifyFile(path);
    if (risk === 'high') {
      highFiles++;
      score += 3;
    } else if (risk === 'medium') {
      mediumFiles++;
      score += 1;
    } else {
      lowFiles++;
    }
  }

  if (highFiles > 0) {
    reasons.push(`${highFiles} high-risk file(s) (auth, security, schema, IAM, Lambda handlers)`);
  }

  // Lines changed factor
  if (totalLines > 500) {
    score += 3;
    reasons.push(`Large changeset: ${totalLines} lines changed (${additions}+/${deletions}-)`);
  } else if (totalLines > 200) {
    score += 1;
    reasons.push(`Medium changeset: ${totalLines} lines changed`);
  }

  // Repo type risk — look up across all projects
  let repoType = 'unknown';
  const allRepos = getRepos();
  const match = allRepos.find(r => r.repo === repo);
  if (match) {
    repoType = match.type || 'unknown';
  }

  const repoRisk = REPO_RISK[repoType] ?? 1;
  score += repoRisk;
  if (repoRisk >= 2) {
    reasons.push(`Backend/infrastructure repository (${repoType})`);
  }

  // Label modifiers
  if (labels.includes('breaking-change')) {
    score += 3;
    reasons.push('Has breaking-change label');
  }
  if (labels.includes('security')) {
    score += 2;
    reasons.push('Has security label');
  }
  if (labels.includes('hotfix')) {
    score += 1;
    reasons.push('Hotfix branch');
  }

  // Branch prefix
  if (branch.startsWith('hotfix/') || branch.startsWith('fix/')) {
    score += 1;
    reasons.push(`Branch prefix suggests fix: ${branch}`);
  }

  // Determine risk level
  let risk;
  if (score >= 8) {
    risk = 'high';
  } else if (score >= 4) {
    risk = 'medium';
  } else {
    risk = 'low';
  }

  if (reasons.length === 0) {
    reasons.push('Standard changes with no special risk factors');
  }

  const result = {
    risk,
    score,
    reasons,
    files_analyzed: files.length,
    additions,
    deletions,
    high_risk_files: highFiles,
    medium_risk_files: mediumFiles,
    low_risk_files: lowFiles
  };

  console.log(JSON.stringify(result, null, 2));
}
