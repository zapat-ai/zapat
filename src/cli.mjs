import { Command } from 'commander';
import { registerStatusCommand } from './commands/status.mjs';
import { registerHealthCommand } from './commands/health.mjs';
import { registerMetricsCommand } from './commands/metrics.mjs';
import { registerDashboardCommand } from './commands/dashboard.mjs';
import { registerLogsCommand } from './commands/logs.mjs';
import { registerRiskCommand } from './commands/risk.mjs';
import { registerProjectsCommand } from './commands/projects.mjs';
import { registerInitCommand } from './commands/init.mjs';
import { registerStartCommand } from './commands/start.mjs';
import { registerStopCommand } from './commands/stop.mjs';
import { registerProgramCommand } from './commands/program.mjs';

export function createCli() {
  const program = new Command();

  program
    .name('zapat')
    .description('Zapat — autonomous dev pipeline CLI')
    .version('1.0.0')
    .option('-p, --project <slug>', 'Target a specific project (omit for all)');

  registerProjectsCommand(program);
  registerInitCommand(program);
  registerStatusCommand(program);
  registerHealthCommand(program);
  registerMetricsCommand(program);
  registerDashboardCommand(program);
  registerLogsCommand(program);
  registerRiskCommand(program);
  registerStartCommand(program);
  registerStopCommand(program);
  registerProgramCommand(program);

  return program;
}
