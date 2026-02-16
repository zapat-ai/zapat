import { cn } from '@/lib/utils'
import { Card, CardContent } from '@/components/ui/card'

interface KanbanCardProps {
  type: 'pr' | 'issue'
  number: number
  title: string
  repo: string
  url: string
  subStage?: string
  stage?: string
}

const stageBorderColors: Record<string, string> = {
  queued: 'border-l-blue-500',
  working: 'border-l-amber-500',
  review: 'border-l-cyan-500',
  done: 'border-l-emerald-500',
}

const subStageBadgeColors: Record<string, string> = {
  triaging: 'bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300',
  triaged: 'bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300',
  queued: 'bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300',
  new: 'bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300',
  research: 'bg-indigo-100 text-indigo-700 dark:bg-indigo-900/40 dark:text-indigo-300',
  researching: 'bg-indigo-100 text-indigo-700 dark:bg-indigo-900/40 dark:text-indigo-300',
  implementing: 'bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300',
  'pr open': 'bg-purple-100 text-purple-700 dark:bg-purple-900/40 dark:text-purple-300',
  'in review': 'bg-cyan-100 text-cyan-700 dark:bg-cyan-900/40 dark:text-cyan-300',
  testing: 'bg-teal-100 text-teal-700 dark:bg-teal-900/40 dark:text-teal-300',
  rework: 'bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300',
  merged: 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-300',
  closed: 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-300',
}

export function KanbanCard({
  type,
  number,
  title,
  repo,
  url,
  subStage,
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
        <div className="flex items-center justify-between gap-2">
          <a
            href={url}
            target="_blank"
            rel="noopener noreferrer"
            className="text-sm font-medium text-zinc-900 hover:text-emerald-600 dark:text-white dark:hover:text-emerald-400"
          >
            {prefix}
            {number}
          </a>
          {subStage && (
            <span
              className={cn(
                'inline-flex shrink-0 rounded-full px-1.5 py-0.5 text-[0.6rem] font-medium leading-none',
                subStageBadgeColors[subStage] || 'bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300',
              )}
            >
              {subStage}
            </span>
          )}
        </div>
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
