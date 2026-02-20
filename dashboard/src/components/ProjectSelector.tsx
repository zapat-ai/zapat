'use client'

import { useProject } from '@/hooks/useProject'
import { cn } from '@/lib/utils'
import { Check, ChevronDown, Loader2 } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'

export function ProjectSelector({ className }: { className?: string }) {
  const { project, projectName, projects, setProject, isLoading } = useProject()
  const [open, setOpen] = useState(false)
  const [focusIndex, setFocusIndex] = useState(-1)
  const ref = useRef<HTMLDivElement>(null)
  const buttonRef = useRef<HTMLButtonElement>(null)
  const listRef = useRef<HTMLDivElement>(null)

  // "All Projects" + each project
  const options = [
    { slug: undefined as string | undefined, name: 'All Projects' },
    ...projects.map((p) => ({ slug: p.slug as string | undefined, name: p.name })),
  ]

  useEffect(() => {
    function handleOutsideInteraction(e: MouseEvent | TouchEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    document.addEventListener('mousedown', handleOutsideInteraction)
    document.addEventListener('touchstart', handleOutsideInteraction)
    return () => {
      document.removeEventListener('mousedown', handleOutsideInteraction)
      document.removeEventListener('touchstart', handleOutsideInteraction)
    }
  }, [])

  // Reset focus index when dropdown opens
  useEffect(() => {
    if (open) {
      const currentIdx = project
        ? options.findIndex((o) => o.slug === project)
        : 0
      setFocusIndex(currentIdx)
    }
  }, [open]) // eslint-disable-line react-hooks/exhaustive-deps

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (!open) {
        if (e.key === 'ArrowDown' || e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          setOpen(true)
          return
        }
        return
      }

      switch (e.key) {
        case 'ArrowDown':
          e.preventDefault()
          setFocusIndex((i) => Math.min(i + 1, options.length - 1))
          break
        case 'ArrowUp':
          e.preventDefault()
          setFocusIndex((i) => Math.max(i - 1, 0))
          break
        case 'Enter':
        case ' ':
          e.preventDefault()
          if (focusIndex >= 0 && focusIndex < options.length) {
            setProject(options[focusIndex].slug)
            setOpen(false)
            buttonRef.current?.focus()
          }
          break
        case 'Escape':
          e.preventDefault()
          setOpen(false)
          buttonRef.current?.focus()
          break
        case 'Tab':
          setOpen(false)
          break
        case 'Home':
          e.preventDefault()
          setFocusIndex(0)
          break
        case 'End':
          e.preventDefault()
          setFocusIndex(options.length - 1)
          break
      }
    },
    [open, focusIndex, options, setProject],
  )

  // Scroll focused option into view
  useEffect(() => {
    if (open && listRef.current && focusIndex >= 0) {
      const items = listRef.current.querySelectorAll('[role="option"]')
      items[focusIndex]?.scrollIntoView({ block: 'nearest' })
    }
  }, [focusIndex, open])

  // Show static label if there's only one project (same pill styling as dropdown trigger)
  if (!isLoading && projects.length <= 1) {
    const name = projects.length === 1 ? projects[0].name : null
    if (!name) return null
    return (
      <div className={cn('relative', className)}>
        <span
          className={cn(
            'flex items-center rounded-md px-2.5 py-1.5 text-sm font-medium',
            'text-zinc-600 dark:text-zinc-400',
          )}
        >
          <span className="max-w-[160px] truncate">{name}</span>
        </span>
      </div>
    )
  }

  if (isLoading) {
    return (
      <div className={cn('flex items-center gap-1.5 px-2.5 py-1.5', className)}>
        <Loader2 className="h-3.5 w-3.5 animate-spin text-zinc-400" />
        <span className="text-sm text-zinc-400">Loading...</span>
      </div>
    )
  }

  const listboxId = 'project-selector-listbox'

  return (
    <div ref={ref} className={cn('relative', className)} onKeyDown={handleKeyDown}>
      <button
        ref={buttonRef}
        onClick={() => setOpen(!open)}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? listboxId : undefined}
        aria-label={`Project: ${projectName}`}
        className={cn(
          'flex items-center gap-1.5 rounded-md px-2.5 py-2 text-sm font-medium transition',
          'border border-zinc-200 dark:border-zinc-700 lg:border-transparent',
          'text-zinc-600 hover:text-zinc-900 hover:bg-zinc-100',
          'dark:text-zinc-400 dark:hover:text-white dark:hover:bg-zinc-800',
          open && 'bg-zinc-100 dark:bg-zinc-800',
        )}
      >
        <span className="max-w-[160px] truncate">{projectName}</span>
        <ChevronDown className={cn('h-3.5 w-3.5 transition', open && 'rotate-180')} />
      </button>

      {open && (
        <div
          ref={listRef}
          id={listboxId}
          role="listbox"
          aria-label="Select project"
          aria-activedescendant={focusIndex >= 0 ? `project-option-${focusIndex}` : undefined}
          className="absolute right-0 lg:left-0 lg:right-auto top-full z-50 mt-1 min-w-[180px] max-h-[min(280px,calc(100dvh-4.5rem))] overflow-y-auto rounded-lg border border-zinc-200 bg-white py-1 shadow-lg dark:border-zinc-700 dark:bg-zinc-800"
        >
          {options.map((opt, idx) => {
            const isSelected = opt.slug === project || (!opt.slug && !project)
            return (
              <button
                key={opt.slug ?? '__all'}
                id={`project-option-${idx}`}
                role="option"
                aria-selected={isSelected}
                onClick={() => { setProject(opt.slug); setOpen(false); buttonRef.current?.focus() }}
                className={cn(
                  'flex w-full items-center gap-2 px-3 py-2 text-left text-sm transition',
                  isSelected
                    ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-400'
                    : 'text-zinc-600 hover:bg-zinc-50 dark:text-zinc-300 dark:hover:bg-zinc-700/50',
                  focusIndex === idx && 'ring-2 ring-inset ring-emerald-500',
                )}
              >
                <Check
                  className={cn(
                    'h-3.5 w-3.5 shrink-0',
                    isSelected ? 'opacity-100' : 'opacity-0',
                  )}
                />
                <span className="truncate">{opt.name}</span>
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}
