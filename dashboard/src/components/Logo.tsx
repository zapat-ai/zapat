import { cn } from '@/lib/utils'

function ZapatIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      className={className}
    >
      <rect x="3" y="3" width="18" height="18" rx="4" className="fill-emerald-500" />
      <path d="M7 7h10L7 17h10" stroke="white" strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

export function Logo({ className }: { className?: string }) {
  return (
    <div className={cn('flex items-center gap-2', className)}>
      <ZapatIcon className="h-6 w-6" />
      <span className="text-base font-semibold text-zinc-900 dark:text-white">
        Zapat
      </span>
    </div>
  )
}
