'use client'

import { StatCard } from '@/components/StatCard'
import { StatsGrid } from '@/components/StatsGrid'
import { KanbanBoard } from '@/components/KanbanBoard'
import { SuccessChart } from '@/components/SuccessChart'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { usePolling } from '@/hooks/usePolling'
import { pipelineConfig } from '../../pipeline.config'
import type { PipelineItem, ChartDataPoint, SystemStatus } from '@/lib/types'

export default function OverviewPage() {
  const { data: itemsData, isLoading: itemsLoading } = usePolling<{ items: PipelineItem[] }>({
    url: '/api/items',
    interval: pipelineConfig.refreshInterval,
  })

  const { data: metricsData, isLoading: metricsLoading } = usePolling<{ metrics: any[] }>({
    url: '/api/metrics?days=7',
    interval: pipelineConfig.refreshInterval,
  })

  const { data: chartData, isLoading: chartLoading } = usePolling<{ chartData: ChartDataPoint[] }>({
    url: '/api/metrics?days=14&chart=true',
    interval: pipelineConfig.refreshInterval,
  })

  const { data: healthData, isLoading: healthLoading } = usePolling<SystemStatus>({
    url: '/api/health',
    interval: pipelineConfig.refreshInterval,
  })

  const { data: completedData, isLoading: completedLoading } = usePolling<{ items: PipelineItem[] }>({
    url: '/api/completed',
    interval: pipelineConfig.refreshInterval,
  })

  const items = itemsData?.items || []
  const metrics = metricsData?.metrics || []
  const chart = chartData?.chartData || []
  const completed = completedData?.items || []

  const recentMetrics = metrics.filter((m) => {
    const ts = new Date(m.timestamp).getTime()
    return ts >= Date.now() - 24 * 60 * 60 * 1000
  })
  const successCount = recentMetrics.filter((m) => m.status === 'success').length
  const failureCount = recentMetrics.filter((m) => m.status === 'failure').length
  const weekTotal = metrics.length
  const weekSuccess = metrics.filter((m: any) => m.status === 'success').length
  const weekRate = weekTotal > 0 ? Math.round((weekSuccess / weekTotal) * 100) + '%' : 'N/A'

  return (
    <div className="space-y-8 py-8">
      <div>
        <h1 className="text-2xl font-bold text-zinc-900 dark:text-white">
          Pipeline Overview
        </h1>
        <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          Real-time pipeline status and metrics
        </p>
      </div>

      <StatsGrid>
        <StatCard
          label="System Health"
          value={healthData?.healthy ? 'Healthy' : healthData ? 'Issues' : '-'}
          indicator={healthData?.healthy ? 'ok' : healthData ? 'error' : undefined}
          subtitle={healthLoading ? undefined : `${healthData?.windowCount || 0} tmux window(s)`}
          loading={healthLoading}
        />
        <StatCard
          label="Slot Usage"
          value={`${healthData?.activeSlots || 0}/${healthData?.maxSlots || 10}`}
          subtitle="active agent slots"
          loading={healthLoading}
        />
        <StatCard
          label="Jobs (24h)"
          value={recentMetrics.length}
          subtitle={`${successCount} success, ${failureCount} failure`}
          loading={metricsLoading}
        />
        <StatCard
          label="7d Success Rate"
          value={weekRate}
          subtitle={`${weekTotal} jobs total`}
          loading={metricsLoading}
        />
        <StatCard
          label="Completed"
          value={completed.length}
          subtitle="merged PRs + closed issues"
          loading={completedLoading}
        />
      </StatsGrid>

      <Card className="border-0 bg-zinc-50 shadow-none dark:bg-zinc-800/50">
        <CardHeader>
          <CardTitle className="text-base">Kanban Board</CardTitle>
        </CardHeader>
        <CardContent>
          <KanbanBoard items={items} stages={pipelineConfig.stages} loading={itemsLoading} />
        </CardContent>
      </Card>

      <Card className="border-0 bg-zinc-50 shadow-none dark:bg-zinc-800/50">
        <CardContent className="p-6">
          <SuccessChart data={chart} loading={chartLoading} />
        </CardContent>
      </Card>
    </div>
  )
}
