import { cn } from '@/lib/utils'

function Skeleton({ className, ...props }: React.HTMLAttributes<HTMLSpanElement>) {
  return (
    <span
      className={cn('block animate-pulse rounded-md bg-zinc-200 dark:bg-zinc-700', className)}
      {...props}
    />
  )
}

export { Skeleton }
