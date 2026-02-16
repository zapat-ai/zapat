import { cn } from '@/lib/utils'
import { Card, CardContent } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import type { HealthCheck } from '@/lib/types'

const statusConfig: Record<string, { variant: 'success' | 'destructive' | 'warning'; dot: string; bg: string }> = {
  ok: {
    variant: 'success',
    dot: 'bg-emerald-500',
    bg: 'bg-emerald-50 border-emerald-200 dark:bg-emerald-500/10 dark:border-emerald-500/20',
  },
  error: {
    variant: 'destructive',
    dot: 'bg-red-500',
    bg: 'bg-red-50 border-red-200 dark:bg-red-500/10 dark:border-red-500/20',
  },
  fixed: {
    variant: 'warning',
    dot: 'bg-amber-500',
    bg: 'bg-amber-50 border-amber-200 dark:bg-amber-500/10 dark:border-amber-500/20',
  },
}

export function HealthStatus({ checks, loading }: { checks: HealthCheck[]; loading?: boolean }) {
  if (loading) {
    return (
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {Array.from({ length: 6 }).map((_, i) => (
          <Card key={i} className="border-0 bg-zinc-100 shadow-none dark:bg-zinc-800/30">
            <CardContent className="p-5">
              <div className="flex items-center gap-3">
                <Skeleton className="h-3 w-3 rounded-full" />
                <Skeleton className="h-4 w-28" />
              </div>
              <Skeleton className="mt-3 h-4 w-full" />
              <Skeleton className="mt-2 h-3 w-12" />
            </CardContent>
          </Card>
        ))}
      </div>
    )
  }

  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {checks.map((check) => {
        const config = statusConfig[check.status] || statusConfig.ok

        return (
          <Card
            key={check.name}
            className={cn('shadow-none', config.bg)}
          >
            <CardContent className="p-5">
              <div className="flex items-center gap-3">
                <span className={cn('h-3 w-3 rounded-full', config.dot)} />
                <h4 className="text-sm font-semibold text-zinc-900 dark:text-white">
                  {check.name}
                </h4>
              </div>
              <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-300">
                {check.message}
              </p>
              <Badge variant={config.variant} className="mt-2">
                {check.status}
              </Badge>
            </CardContent>
          </Card>
        )
      })}
      {checks.length === 0 && (
        <p className="col-span-full py-8 text-center text-sm text-zinc-400 dark:text-zinc-500">
          No health check data
        </p>
      )}
    </div>
  )
}
