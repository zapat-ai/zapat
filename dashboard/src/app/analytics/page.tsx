'use client'

import { Suspense, useEffect } from 'react'
import { SuccessChart } from '@/components/SuccessChart'
import { StatCard } from '@/components/StatCard'
import { StatsGrid } from '@/components/StatsGrid'
import { Skeleton } from '@/components/ui/skeleton'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { usePolling } from '@/hooks/usePolling'
import { useProject } from '@/hooks/useProject'
import { pipelineConfig } from '../../../pipeline.config'
import type { ChartDataPoint, MetricEntry } from '@/lib/types'

function AnalyticsContent() {
  const { project, projectName } = useProject()
  const projectParam = project ? `&project=${encodeURIComponent(project)}` : ''

  useEffect(() => {
    document.title = project ? `Analytics - ${projectName}` : 'Analytics - Zapat'
  }, [project, projectName])

  const { data: chart14, isLoading: chart14Loading } = usePolling<{ chartData: ChartDataPoint[] }>({
    url: `/api/metrics?days=14&chart=true${projectParam}`,
    interval: pipelineConfig.refreshInterval,
  })

  const { data: chart30, isLoading: chart30Loading } = usePolling<{ chartData: ChartDataPoint[] }>({
    url: `/api/metrics?days=30&chart=true${projectParam}`,
    interval: pipelineConfig.refreshInterval,
  })

  const { data: metricsData, isLoading: metricsLoading } = usePolling<{ metrics: MetricEntry[] }>({
    url: `/api/metrics?days=30${projectParam}`,
    interval: pipelineConfig.refreshInterval,
  })

  const metrics = metricsData?.metrics || []
  const totalJobs = metrics.length
  const successJobs = metrics.filter((m) => m.status === 'success').length
  const failureJobs = metrics.filter((m) => m.status === 'failure').length
  const overallRate = totalJobs > 0 ? Math.round((successJobs / totalJobs) * 100) : 0

  // Job type breakdown
  const jobTypes: Record<string, { total: number; success: number }> = {}
  for (const m of metrics) {
    const key = m.job || 'unknown'
    if (!jobTypes[key]) jobTypes[key] = { total: 0, success: 0 }
    jobTypes[key].total++
    if (m.status === 'success') jobTypes[key].success++
  }

  // Repo breakdown
  const repoCounts: Record<string, number> = {}
  for (const m of metrics) {
    const key = m.repo ? m.repo.split('/').pop()! : 'unknown'
    repoCounts[key] = (repoCounts[key] || 0) + 1
  }

  return (
    <div className="space-y-8 py-8">
      <div>
        <h1 className="text-2xl font-bold text-zinc-900 dark:text-white">
          Analytics
        </h1>
        <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          Pipeline performance trends and breakdowns (30 days)
        </p>
      </div>

      <StatsGrid>
        <StatCard label="Total Jobs" value={totalJobs} subtitle="last 30 days" loading={metricsLoading} />
        <StatCard label="Success" value={successJobs} subtitle="completed successfully" loading={metricsLoading} />
        <StatCard label="Failures" value={failureJobs} subtitle="jobs failed" loading={metricsLoading} />
        <StatCard
          label="Success Rate"
          value={`${overallRate}%`}
          indicator={metricsLoading ? undefined : overallRate >= 80 ? 'ok' : overallRate >= 50 ? 'warning' : 'error'}
          loading={metricsLoading}
        />
      </StatsGrid>

      <Card className="border-0 bg-zinc-50 shadow-none dark:bg-zinc-800/50">
        <CardContent className="p-6">
          <SuccessChart data={chart14?.chartData || []} title="14-Day Success Rate" loading={chart14Loading} />
        </CardContent>
      </Card>

      <Card className="border-0 bg-zinc-50 shadow-none dark:bg-zinc-800/50">
        <CardContent className="p-6">
          <SuccessChart data={chart30?.chartData || []} title="30-Day Success Rate" loading={chart30Loading} />
        </CardContent>
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card className="border-0 bg-zinc-50 shadow-none dark:bg-zinc-800/50">
          <CardHeader>
            <CardTitle className="text-sm">Job Type Breakdown</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="space-y-3">
              {metricsLoading ? (
                Array.from({ length: 4 }).map((_, i) => (
                  <div key={i} className="flex items-center justify-between">
                    <Skeleton className="h-4 w-24" />
                    <Skeleton className="h-4 w-20" />
                  </div>
                ))
              ) : Object.keys(jobTypes).length === 0 ? (
                <p className="text-sm text-zinc-400">No data</p>
              ) : (
                Object.entries(jobTypes)
                  .sort(([, a], [, b]) => b.total - a.total)
                  .map(([name, { total, success }]) => (
                    <div key={name} className="flex items-center justify-between">
                      <span className="text-sm text-zinc-700 dark:text-zinc-300">
                        {name}
                      </span>
                      <span className="text-sm text-zinc-500 dark:text-zinc-400">
                        {success}/{total} ({total > 0 ? Math.round((success / total) * 100) : 0}%)
                      </span>
                    </div>
                  ))
              )}
            </div>
          </CardContent>
        </Card>

        <Card className="border-0 bg-zinc-50 shadow-none dark:bg-zinc-800/50">
          <CardHeader>
            <CardTitle className="text-sm">Repo Breakdown</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="space-y-3">
              {metricsLoading ? (
                Array.from({ length: 3 }).map((_, i) => (
                  <div key={i} className="flex items-center justify-between">
                    <Skeleton className="h-4 w-28" />
                    <Skeleton className="h-4 w-16" />
                  </div>
                ))
              ) : Object.keys(repoCounts).length === 0 ? (
                <p className="text-sm text-zinc-400">No data</p>
              ) : (
                Object.entries(repoCounts)
                  .sort(([, a], [, b]) => b - a)
                  .map(([name, count]) => (
                    <div key={name} className="flex items-center justify-between">
                      <span className="text-sm text-zinc-700 dark:text-zinc-300">
                        {name}
                      </span>
                      <span className="text-sm text-zinc-500 dark:text-zinc-400">
                        {count} job{count !== 1 ? 's' : ''}
                      </span>
                    </div>
                  ))
              )}
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}

export default function AnalyticsPage() {
  return (
    <Suspense>
      <AnalyticsContent />
    </Suspense>
  )
}
