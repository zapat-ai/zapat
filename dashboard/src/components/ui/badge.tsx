import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

const badgeVariants = cva(
  'inline-flex items-center rounded-md px-2 py-1 text-xs font-medium ring-1 ring-inset transition-colors',
  {
    variants: {
      variant: {
        default: 'bg-zinc-100 text-zinc-600 ring-zinc-200 dark:bg-zinc-800 dark:text-zinc-400 dark:ring-zinc-700',
        success: 'bg-emerald-400/10 text-emerald-600 ring-emerald-400/30 dark:text-emerald-400',
        destructive: 'bg-red-400/10 text-red-600 ring-red-400/30 dark:text-red-400',
        warning: 'bg-amber-400/10 text-amber-600 ring-amber-400/30 dark:text-amber-400',
        purple: 'bg-purple-400/10 text-purple-600 ring-purple-400/30 dark:text-purple-400',
        sky: 'bg-sky-400/10 text-sky-600 ring-sky-400/30 dark:text-sky-400',
      },
    },
    defaultVariants: {
      variant: 'default',
    },
  },
)

export interface BadgeProps
  extends React.HTMLAttributes<HTMLSpanElement>,
    VariantProps<typeof badgeVariants> {}

function Badge({ className, variant, ...props }: BadgeProps) {
  return <span className={cn(badgeVariants({ variant }), className)} {...props} />
}

export { Badge, badgeVariants }
