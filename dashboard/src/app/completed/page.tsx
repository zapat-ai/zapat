'use client'

import { CompletedTable } from '@/components/CompletedTable'
import { Card, CardContent } from '@/components/ui/card'
import { usePolling } from '@/hooks/usePolling'
import { pipelineConfig } from '../../../pipeline.config'
import type { PipelineItem } from '@/lib/types'

export default function CompletedPage() {
  const { data, isLoading } = usePolling<{ items: PipelineItem[] }>({
    url: '/api/completed',
    interval: pipelineConfig.refreshInterval,
  })

  const items = data?.items || []

  return (
    <div className="space-y-6 py-8">
      <div>
        <h1 className="text-2xl font-bold text-zinc-900 dark:text-white">
          Completed
        </h1>
        <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          Recently merged PRs and closed issues
        </p>
      </div>

      <Card className="border-0 bg-zinc-50 shadow-none dark:bg-zinc-800/50">
        <CardContent className="p-6">
          <CompletedTable items={items} loading={isLoading} />
        </CardContent>
      </Card>
    </div>
  )
}
