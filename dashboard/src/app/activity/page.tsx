'use client'

import { Suspense } from 'react'
import { useSearchParams } from 'next/navigation'
import { ActivityTable } from '@/components/ActivityTable'
import { Card, CardContent } from '@/components/ui/card'
import { usePolling } from '@/hooks/usePolling'
import { pipelineConfig } from '../../../pipeline.config'
import type { MetricEntry } from '@/lib/types'

function ActivityContent() {
  const searchParams = useSearchParams()
  const project = searchParams.get('project')
  const projectParam = project ? `&project=${encodeURIComponent(project)}` : ''

  const { data, isLoading } = usePolling<{ metrics: MetricEntry[] }>({
    url: `/api/metrics?days=7${projectParam}`,
    interval: pipelineConfig.refreshInterval,
  })

  const metrics = data?.metrics || []
  const sorted = [...metrics].reverse().slice(0, 50)

  return (
    <div className="space-y-6 py-8">
      <div>
        <h1 className="text-2xl font-bold text-zinc-900 dark:text-white">
          Activity
        </h1>
        <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          Recent pipeline jobs (last 7 days)
        </p>
      </div>

      <Card className="border-0 bg-zinc-50 shadow-none dark:bg-zinc-800/50">
        <CardContent className="p-6">
          <ActivityTable metrics={sorted} loading={isLoading} />
        </CardContent>
      </Card>
    </div>
  )
}

export default function ActivityPage() {
  return (
    <Suspense>
      <ActivityContent />
    </Suspense>
  )
}
