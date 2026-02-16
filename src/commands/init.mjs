import { existsSync, mkdirSync, copyFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import { getAutomationDir, getProjects } from '../lib/config.mjs';

export function registerInitCommand(program) {
  program
    .command('init <slug>')
    .description('Initialize a new project')
    .action(runInit);
}

function runInit(slug) {
  // Validate slug format
  if (!/^[a-z0-9][a-z0-9-]*$/.test(slug)) {
    console.error(`Error: Invalid project slug '${slug}'. Use lowercase letters, digits, and hyphens.`);
    process.exit(1);
  }

  const root = getAutomationDir();
  const projectDir = join(root, 'config', slug);

  if (existsSync(projectDir)) {
    console.error(`Error: Project directory already exists: ${projectDir}`);
    process.exit(1);
  }

  mkdirSync(projectDir, { recursive: true });

  // repos.conf
  const reposExample = join(root, 'config', 'repos.conf.example');
  if (existsSync(reposExample)) {
    copyFileSync(reposExample, join(projectDir, 'repos.conf'));
  } else {
    writeFileSync(join(projectDir, 'repos.conf'),
`# Zapat — Repository Configuration
# Format: owner/repo<TAB>local_path<TAB>type
# Types: backend, web, ios, mobile, extension, marketing, other
#
# Examples:
# your-org/backend\t/home/you/code/backend\tbackend
# your-org/web-app\t/home/you/code/web-app\tweb
`);
  }

  // agents.conf
  const agentsExample = join(root, 'config', 'agents.conf.example');
  if (existsSync(agentsExample)) {
    copyFileSync(agentsExample, join(projectDir, 'agents.conf'));
  } else {
    writeFileSync(join(projectDir, 'agents.conf'),
`# Zapat — Agent Team Configuration
builder=engineer
security=security-reviewer
product=product-manager
ux=ux-reviewer
`);
  }

  // project-context.txt
  const ctxExample = join(root, 'config', 'project-context.example.txt');
  if (existsSync(ctxExample)) {
    copyFileSync(ctxExample, join(projectDir, 'project-context.txt'));
  } else {
    writeFileSync(join(projectDir, 'project-context.txt'),
`# Project Context for ${slug}
# Describe your system architecture here.
# This is injected into agent prompts as {{PROJECT_CONTEXT}}.
`);
  }

  // project.env
  writeFileSync(join(projectDir, 'project.env'),
`# Project-specific environment overrides for ${slug}
# Variables here override the global .env for this project only.
# Example:
# CLAUDE_MODEL=claude-sonnet-4-5-20250929
# AUTO_MERGE_ENABLED=false
`);

  console.log(`Project '${slug}' initialized at ${projectDir}`);
  console.log('');
  console.log('Next steps:');
  console.log(`  1. Edit ${join(projectDir, 'repos.conf')} — add your repositories`);
  console.log(`  2. Edit ${join(projectDir, 'project-context.txt')} — describe your architecture`);
  console.log(`  3. (Optional) Edit ${join(projectDir, 'agents.conf')} — customize agent roles`);
  console.log(`  4. (Optional) Edit ${join(projectDir, 'project.env')} — override env vars`);
  console.log('');
  console.log('Then run: zapat projects');
}
