'use client'

import { HealthStatus } from '@/components/HealthStatus'
import { StatCard } from '@/components/StatCard'
import { StatsGrid } from '@/components/StatsGrid'
import { usePolling } from '@/hooks/usePolling'
import { pipelineConfig } from '../../../pipeline.config'
import type { SystemStatus } from '@/lib/types'

export default function HealthPage() {
  let { data, isLoading } = usePolling<SystemStatus>({
    url: '/api/health',
    interval: pipelineConfig.refreshInterval,
  })

  return (
    <div className="space-y-8 py-8">
      <div>
        <h1 className="text-2xl font-bold text-zinc-900 dark:text-white">
          System Health
        </h1>
        <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          Pipeline infrastructure status and diagnostics
        </p>
      </div>

      <StatsGrid>
        <StatCard
          label="Overall"
          value={data?.healthy ? 'Healthy' : data ? 'Issues Detected' : '-'}
          indicator={data?.healthy ? 'ok' : data ? 'error' : undefined}
          loading={isLoading}
        />
        <StatCard
          label="tmux Session"
          value={data?.sessionExists ? 'Active' : data ? 'Down' : '-'}
          indicator={data?.sessionExists ? 'ok' : data ? 'error' : undefined}
          subtitle={isLoading ? undefined : `${data?.windowCount || 0} window(s)`}
          loading={isLoading}
        />
        <StatCard
          label="Agent Slots"
          value={data ? `${data.activeSlots}/${data.maxSlots}` : '-'}
          subtitle="active / max"
          loading={isLoading}
        />
      </StatsGrid>

      <div>
        <h2 className="mb-4 text-base font-semibold text-zinc-900 dark:text-white">
          Health Checks
        </h2>
        <HealthStatus checks={data?.checks || []} loading={isLoading} />
      </div>
    </div>
  )
}
