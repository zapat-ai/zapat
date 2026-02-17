'use client'

import { useProject } from '@/hooks/useProject'
import { cn } from '@/lib/utils'
import { ChevronDown } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'

export function ProjectSelector({ className }: { className?: string }) {
  const { project, projectName, projects, setProject } = useProject()
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [])

  // Don't show selector if there's only one project (or none)
  if (projects.length <= 1) {
    return null
  }

  return (
    <div ref={ref} className={cn('relative', className)}>
      <button
        onClick={() => setOpen(!open)}
        className={cn(
          'flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-sm font-medium transition',
          'text-zinc-600 hover:text-zinc-900 hover:bg-zinc-100',
          'dark:text-zinc-400 dark:hover:text-white dark:hover:bg-zinc-800',
          open && 'bg-zinc-100 dark:bg-zinc-800',
        )}
      >
        <span className="max-w-[160px] truncate">{projectName}</span>
        <ChevronDown className={cn('h-3.5 w-3.5 transition', open && 'rotate-180')} />
      </button>

      {open && (
        <div className="absolute left-0 top-full z-50 mt-1 min-w-[180px] rounded-lg border border-zinc-200 bg-white py-1 shadow-lg dark:border-zinc-700 dark:bg-zinc-800">
          <button
            onClick={() => { setProject(undefined); setOpen(false) }}
            className={cn(
              'flex w-full items-center px-3 py-2 text-left text-sm transition',
              !project
                ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-400'
                : 'text-zinc-600 hover:bg-zinc-50 dark:text-zinc-300 dark:hover:bg-zinc-700/50',
            )}
          >
            All Projects
          </button>
          {projects.map((p) => (
            <button
              key={p.slug}
              onClick={() => { setProject(p.slug); setOpen(false) }}
              className={cn(
                'flex w-full items-center px-3 py-2 text-left text-sm transition',
                project === p.slug
                  ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-400'
                  : 'text-zinc-600 hover:bg-zinc-50 dark:text-zinc-300 dark:hover:bg-zinc-700/50',
              )}
            >
              {p.name}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
