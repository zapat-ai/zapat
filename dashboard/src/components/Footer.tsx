'use client'

import { Separator } from '@/components/ui/separator'

export function Footer() {
  return (
    <footer className="mx-auto w-full max-w-2xl space-y-10 pb-16 lg:max-w-5xl">
      <div className="flex flex-col items-center justify-between gap-5 pt-8 sm:flex-row">
        <Separator className="mb-4 sm:mb-0" />
      </div>
      <p className="text-center text-xs text-zinc-500 dark:text-zinc-400">
        Zapat &mdash; Pipeline Dashboard
      </p>
    </footer>
  )
}
