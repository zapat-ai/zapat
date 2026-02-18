'use client'

import { Suspense, useEffect } from 'react'
import { KanbanBoard } from '@/components/KanbanBoard'
import { Skeleton } from '@/components/ui/skeleton'
import { usePolling } from '@/hooks/usePolling'
import { useProject } from '@/hooks/useProject'
import { pipelineConfig } from '../../../pipeline.config'
import type { PipelineItem } from '@/lib/types'

function BoardContent() {
  const { project, projectName } = useProject()
  const projectQuery = project ? `?project=${encodeURIComponent(project)}` : ''

  useEffect(() => {
    document.title = project ? `Board - ${projectName}` : 'Board - Zapat'
  }, [project, projectName])

  const { data, isLoading } = usePolling<{ items: PipelineItem[] }>({
    url: `/api/items${projectQuery}`,
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

export default function BoardPage() {
  return (
    <Suspense>
      <BoardContent />
    </Suspense>
  )
}
