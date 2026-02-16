import { cn } from '@/lib/utils'
import { Card, CardContent } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'

export function StatCard({
  label,
  value,
  subtitle,
  indicator,
  loading,
}: {
  label: string
  value: string | number
  subtitle?: string
  indicator?: 'ok' | 'error' | 'warning'
  loading?: boolean
}) {
  return (
    <Card className="border-0 bg-zinc-50 shadow-none dark:bg-zinc-800/50">
      <CardContent className="p-6">
        <p className="text-sm font-medium text-zinc-500 dark:text-zinc-400">
          {label}
        </p>
        <p className="mt-2 flex items-center gap-2">
          {loading ? (
            <Skeleton className="h-9 w-20" />
          ) : (
            <>
              {indicator && (
                <span
                  className={cn('inline-block h-2.5 w-2.5 rounded-full', {
                    'bg-emerald-500': indicator === 'ok',
                    'bg-red-500': indicator === 'error',
                    'bg-amber-500': indicator === 'warning',
                  })}
                />
              )}
              <span className="text-3xl font-semibold tracking-tight text-zinc-900 dark:text-white">
                {value}
              </span>
            </>
          )}
        </p>
        {loading ? (
          <Skeleton className="mt-2 h-4 w-24" />
        ) : subtitle ? (
          <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
            {subtitle}
          </p>
        ) : null}
      </CardContent>
    </Card>
  )
}
