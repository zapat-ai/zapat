import { getProjects, getProjectRepos } from '../lib/config.mjs';

export function registerProjectsCommand(program) {
  program
    .command('projects')
    .description('List configured projects')
    .option('--json', 'Output as JSON')
    .action(runProjects);
}

function runProjects(opts) {
  const projects = getProjects();

  if (projects.length === 0) {
    console.log('No projects configured.');
    console.log('');
    console.log('To add a project, create config/<slug>/repos.conf');
    return;
  }

  if (opts.json) {
    const data = projects.map(p => ({
      ...p,
      repos: getProjectRepos(p.slug).length
    }));
    console.log(JSON.stringify(data, null, 2));
    return;
  }

  console.log('Projects');
  console.log('========');
  console.log('');

  for (const p of projects) {
    const repos = getProjectRepos(p.slug);
    const status = p.enabled ? 'enabled' : 'disabled';
    console.log(`  ${p.slug.padEnd(20)} ${repos.length} repos   ${status}`);

    for (const r of repos) {
      console.log(`    - ${r.repo} (${r.type})`);
    }
    console.log('');
  }
}
