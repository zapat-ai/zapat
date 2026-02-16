import { cn } from '@/lib/utils'
import { KanbanCard } from '@/components/KanbanCard'
import type { PipelineItem } from '@/lib/types'

const headerColors: Record<string, string> = {
  blue: 'text-blue-600 dark:text-blue-400',
  yellow: 'text-amber-600 dark:text-amber-400',
  cyan: 'text-cyan-600 dark:text-cyan-400',
  green: 'text-emerald-600 dark:text-emerald-400',
}

export function KanbanColumn({
  title,
  color = 'blue',
  items,
  stageId,
}: {
  title: string
  color?: string
  items: PipelineItem[]
  stageId: string
}) {
  return (
    <div className="rounded-lg bg-zinc-100 p-3 dark:bg-zinc-800/30">
      <h4
        className={cn(
          'mb-3 border-b border-zinc-200 pb-2 text-xs font-semibold uppercase dark:border-zinc-700',
          headerColors[color] || 'text-zinc-600 dark:text-zinc-400',
        )}
      >
        {title} ({items.length})
      </h4>
      <div className="space-y-2">
        {items.length === 0 ? (
          <p className="py-4 text-center text-xs text-zinc-400 dark:text-zinc-500">
            No items
          </p>
        ) : (
          items.map((item) => (
            <KanbanCard
              key={`${item.type}-${item.repo}-${item.number}`}
              type={item.type}
              number={item.number}
              title={item.title}
              repo={item.repo}
              url={item.url}
              subStage={item.subStage}
              stage={stageId}
            />
          ))
        )}
      </div>
    </div>
  )
}
