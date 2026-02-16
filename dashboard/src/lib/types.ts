export interface StageConfig {
  id: string
  label: string
  color: string
}

export interface PipelineConfig {
  name: string
  refreshInterval: number
  stages: StageConfig[]
  dataSources: {
    automationDir: string
    metricsFile: string
    reposConfig: string
  }
}

export interface PipelineItem {
  type: 'pr' | 'issue'
  repo: string
  number: number
  title: string
  labels: string[]
  url: string
  stage: string
  createdAt?: string
  completedAt?: string
}

export interface MetricEntry {
  timestamp: string
  job: string
  repo: string
  item: string
  exit_code: number
  start: string
  end: string
  duration_s: number
  status: 'success' | 'failure' | string
}

export interface HealthCheck {
  name: string
  status: 'ok' | 'error' | 'fixed'
  message: string
}

export interface SystemStatus {
  healthy: boolean
  sessionExists: boolean
  windowCount: number
  activeSlots: number
  maxSlots: number
  checks: HealthCheck[]
}

export interface ChartDataPoint {
  date: string
  total: number
  success: number
  rate: number
}
