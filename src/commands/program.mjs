import { discoverProgram } from '../lib/program-discovery.mjs';
import { formatPlainText, formatJSON, formatSlack, formatGitHub } from '../lib/program-format.mjs';
import { exec } from '../lib/exec.mjs';
import { getRepos } from '../lib/config.mjs';
import { writeFileSync, unlinkSync } from 'fs';

export function registerProgramCommand(program) {
  program
    .command('program')
    .description('Show program-level status for a parent issue and all its sub-issues')
    .argument('<issue-number>', 'Parent issue number')
    .option('--repo <repo>', 'Repository (owner/repo) — auto-detected if project has 1 repo')
    .option('--json', 'Output as JSON')
    .option('--slack', 'Output formatted for Slack')
    .option('--post', 'Post/update status comment on the GitHub issue')
    .action(runProgram);
}

async function runProgram(issueNumber, opts, cmd) {
  const projectFilter = cmd?.parent?.opts()?.project || undefined;

  // Resolve repo
  let repo = opts.repo;
  if (!repo) {
    const repos = getRepos(projectFilter);
    if (repos.length === 0) {
      console.error('Error: No repos configured. Use --repo to specify one.');
      process.exit(1);
    }
    if (repos.length === 1) {
      repo = repos[0].repo;
    } else {
      const repoList = repos.map(r => `  ${r.repo}`).join('\n');
      console.error(`Error: Multiple repos found. Specify one with --repo:\n${repoList}`);
      process.exit(1);
    }
  }

  const graph = await discoverProgram(repo, issueNumber);

  if (opts.json) {
    console.log(formatJSON(graph));
    return;
  }

  if (opts.slack) {
    console.log(formatSlack(graph));
    return;
  }

  if (opts.post) {
    const body = formatGitHub(graph);
    const tmpFile = `/tmp/zapat-program-status-${Date.now()}.md`;

    try {
      writeFileSync(tmpFile, body);

      // Search for existing sentinel comment
      const sentinel = `<!-- zapat-program-status: ${issueNumber} -->`;
      const commentsJson = exec(`gh api repos/${repo}/issues/${issueNumber}/comments --jq '[.[] | {id, body}]'`, { timeout: 15000 });
      let existingCommentId = null;

      if (commentsJson) {
        try {
          const comments = JSON.parse(commentsJson);
          for (const c of comments) {
            if (c.body && c.body.includes(sentinel)) {
              existingCommentId = c.id;
              break;
            }
          }
        } catch { /* skip */ }
      }

      if (existingCommentId) {
        // Update existing comment
        exec(`gh api repos/${repo}/issues/comments/${existingCommentId} -X PATCH -F body=@${tmpFile}`, { timeout: 15000 });
        console.log(`Updated program status comment on #${issueNumber}`);
      } else {
        // Create new comment
        exec(`gh issue comment ${issueNumber} --repo ${repo} --body-file ${tmpFile}`, { timeout: 15000 });
        console.log(`Posted program status comment on #${issueNumber}`);
      }
    } finally {
      try { unlinkSync(tmpFile); } catch { /* skip */ }
    }
    return;
  }

  // Default: plain text
  console.log(formatPlainText(graph));
}
