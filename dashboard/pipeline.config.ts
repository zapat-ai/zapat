import type { PipelineConfig } from './src/lib/types'

export const pipelineConfig: PipelineConfig = {
  name: 'Agent Pipeline',
  refreshInterval: 60_000,
  stages: [
    { id: 'triaged', label: 'Triaged', color: 'blue' },
    { id: 'in-progress', label: 'In Progress', color: 'yellow' },
    { id: 'pr-open', label: 'PR Open', color: 'purple' },
    { id: 'review', label: 'Review', color: 'cyan' },
    { id: 'rework', label: 'Rework', color: 'red' },
  ],
  dataSources: {
    automationDir: process.env.AUTOMATION_DIR || process.cwd(),
    metricsFile: 'data/metrics.jsonl',
    reposConfig: 'config/repos.conf',
  },
}
