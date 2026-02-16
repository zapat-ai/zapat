'use client'

import { KanbanBoard } from '@/components/KanbanBoard'
import { Skeleton } from '@/components/ui/skeleton'
import { usePolling } from '@/hooks/usePolling'
import { pipelineConfig } from '../../../pipeline.config'
import type { PipelineItem } from '@/lib/types'

export default function BoardPage() {
  const { data, isLoading } = usePolling<{ items: PipelineItem[] }>({
    url: '/api/items',
    interval: pipelineConfig.refreshInterval,
  })

  const items = data?.items || []

  return (
    <div className="space-y-6 py-8">
      <div>
        <h1 className="text-2xl font-bold text-zinc-900 dark:text-white">
          Board
        </h1>
        <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          {isLoading ? (
            <Skeleton className="mt-0.5 inline-block h-4 w-40" />
          ) : (
            <>{items.length} active item{items.length !== 1 ? 's' : ''} across all stages</>
          )}
        </p>
      </div>

      <KanbanBoard items={items} stages={pipelineConfig.stages} loading={isLoading} />
    </div>
  )
}
