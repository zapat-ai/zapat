import { cn } from '@/lib/utils'

const colorStyles: Record<string, string> = {
  emerald: 'text-emerald-600 dark:text-emerald-400',
  sky: 'text-sky-600 dark:text-sky-400',
  amber: 'text-amber-600 dark:text-amber-400',
  rose: 'text-red-600 dark:text-red-400',
  zinc: 'text-zinc-500 dark:text-zinc-400',
}

export function Tag({
  children,
  color = 'emerald',
}: {
  children: string
  color?: keyof typeof colorStyles
}) {
  return (
    <span
      className={cn(
        'inline-flex items-center rounded-md px-1.5 text-[0.625rem]/6 font-semibold font-mono ring-1 ring-inset ring-current/20',
        colorStyles[color] || colorStyles.emerald,
      )}
    >
      {children}
    </span>
  )
}
