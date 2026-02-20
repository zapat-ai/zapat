import type { PipelineConfig } from './src/lib/types'

export const pipelineConfig: PipelineConfig = {
  name: 'Agent Pipeline',
  refreshInterval: 60_000,
  defaultProject: process.env.PROJECT_SLUG || undefined,
  stages: [
    { id: 'queued', label: 'Queued', color: 'blue' },
    { id: 'working', label: 'Working', color: 'yellow' },
    { id: 'review', label: 'Review', color: 'cyan' },
    { id: 'done', label: 'Done', color: 'green' },
  ],
  dataSources: {
    automationDir: process.env.AUTOMATION_DIR || process.cwd(),
    metricsFile: 'data/metrics.jsonl',
    reposConfig: 'config/repos.conf',
  },
}
