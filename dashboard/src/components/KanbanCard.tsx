import { cn } from '@/lib/utils'
import { Card, CardContent } from '@/components/ui/card'

interface KanbanCardProps {
  type: 'pr' | 'issue'
  number: number
  title: string
  repo: string
  url: string
  labels?: string[]
  stage?: string
}

const stageBorderColors: Record<string, string> = {
  triaged: 'border-l-blue-500',
  'in-progress': 'border-l-amber-500',
  'pr-open': 'border-l-purple-500',
  review: 'border-l-cyan-500',
  rework: 'border-l-red-500',
}

export function KanbanCard({
  type,
  number,
  title,
  repo,
  url,
  stage,
}: KanbanCardProps) {
  const repoShort = repo.split('/').pop()
  const prefix = type === 'pr' ? 'PR' : '#'

  return (
    <Card
      className={cn(
        'border-0 border-l-[3px] shadow-sm',
        stage ? stageBorderColors[stage] || 'border-l-zinc-300' : 'border-l-zinc-300',
      )}
    >
      <CardContent className="p-3">
        <a
          href={url}
          target="_blank"
          rel="noopener noreferrer"
          className="text-sm font-medium text-zinc-900 hover:text-emerald-600 dark:text-white dark:hover:text-emerald-400"
        >
          {prefix}
          {number}
        </a>
        <p className="mt-1 text-xs text-zinc-600 dark:text-zinc-300 line-clamp-2">
          {title}
        </p>
        <p className="mt-2 text-[0.7rem] text-zinc-400 dark:text-zinc-500">
          {repoShort}
        </p>
      </CardContent>
    </Card>
  )
}
