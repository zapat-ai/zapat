'use client'

import Link from 'next/link'
import { Suspense } from 'react'
import { cn } from '@/lib/utils'

import { Logo } from '@/components/Logo'
import { ProjectSelector } from '@/components/ProjectSelector'
import {
  MobileNavigation,
  useMobileNavigationStore,
} from '@/components/MobileNavigation'
import { ThemeToggle } from '@/components/ThemeToggle'

export function Header({ className }: { className?: string }) {
  const { isOpen: mobileNavIsOpen } = useMobileNavigationStore()

  return (
    <div
      className={cn(
        className,
        'fixed inset-x-0 top-0 z-50 flex h-14 items-center justify-between gap-12 px-4 transition sm:px-6 lg:left-72 lg:z-30 lg:px-8 xl:left-80',
        'backdrop-blur-sm bg-white/80 dark:bg-zinc-900/80',
        mobileNavIsOpen && 'bg-white dark:bg-zinc-900',
      )}
    >
      <div
        className={cn(
          'absolute inset-x-0 top-full h-px transition',
          'bg-zinc-900/10 dark:bg-white/10',
        )}
      />
      <div className="flex items-center gap-5 lg:hidden">
        <MobileNavigation />
        <Link href="/" aria-label="Home">
          <Logo className="h-6" />
        </Link>
      </div>
      <div className="hidden items-center gap-3 lg:flex">
        <Suspense>
          <ProjectSelector />
        </Suspense>
      </div>
      <div className="flex items-center gap-5">
        <Suspense>
          <ProjectSelector className="lg:hidden rounded-lg border border-zinc-200 bg-zinc-50 p-0.5 dark:border-zinc-700 dark:bg-zinc-800/50" />
        </Suspense>
        <div aria-hidden="true" className="h-6 w-px bg-zinc-300 dark:bg-zinc-600 lg:hidden" />
        <ThemeToggle />
      </div>
    </div>
  )
}
