import { KanbanColumn } from '@/components/KanbanColumn'
import { Skeleton } from '@/components/ui/skeleton'
import type { PipelineItem, StageConfig } from '@/lib/types'

export function KanbanBoard({
  items,
  stages,
  loading,
}: {
  items: PipelineItem[]
  stages: StageConfig[]
  loading?: boolean
}) {
  if (loading) {
    return (
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
        {stages.map((stage) => (
          <div key={stage.id} className="rounded-lg bg-zinc-100 p-3 dark:bg-zinc-800/30">
            <Skeleton className="mb-3 h-4 w-20" />
            <div className="space-y-2">
              <Skeleton className="h-20 w-full rounded-lg" />
              <Skeleton className="h-20 w-full rounded-lg" />
            </div>
          </div>
        ))}
      </div>
    )
  }

  return (
    <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
      {stages.map((stage) => (
        <KanbanColumn
          key={stage.id}
          title={stage.label}
          color={stage.color}
          stageId={stage.id}
          items={items.filter((item) => item.stage === stage.id)}
        />
      ))}
    </div>
  )
}
