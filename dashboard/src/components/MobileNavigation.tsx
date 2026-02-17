'use client'

import { Suspense, createContext, useContext, useEffect, useRef } from 'react'
import { usePathname } from 'next/navigation'
import { create } from 'zustand'
import { Menu, X } from 'lucide-react'

import { Navigation } from '@/components/Navigation'

const IsInsideMobileNavigationContext = createContext(false)

export function useIsInsideMobileNavigation() {
  return useContext(IsInsideMobileNavigationContext)
}

export const useMobileNavigationStore = create<{
  isOpen: boolean
  open: () => void
  close: () => void
  toggle: () => void
}>()((set) => ({
  isOpen: false,
  open: () => set({ isOpen: true }),
  close: () => set({ isOpen: false }),
  toggle: () => set((state) => ({ isOpen: !state.isOpen })),
}))

function MobileNavigationPanel({
  isOpen,
  close,
}: {
  isOpen: boolean
  close: () => void
}) {
  const pathname = usePathname()
  const initialPathname = useRef(pathname).current

  useEffect(() => {
    if (pathname !== initialPathname) {
      close()
    }
  }, [pathname, close, initialPathname])

  if (!isOpen) return null

  return (
    <div className="fixed inset-0 z-50 lg:hidden">
      {/* Backdrop */}
      <div
        className="fixed inset-0 top-14 bg-zinc-400/20 backdrop-blur-sm dark:bg-black/40"
        onClick={close}
      />
      {/* Panel */}
      <div className="fixed top-14 bottom-0 left-0 w-full overflow-y-auto bg-white px-4 pt-6 pb-4 shadow-lg ring-1 ring-zinc-900/10 min-[416px]:max-w-sm sm:px-6 sm:pb-10 dark:bg-zinc-900 dark:ring-zinc-800">
        <Suspense>
          <Navigation />
        </Suspense>
      </div>
    </div>
  )
}

export function MobileNavigation() {
  const isInsideMobileNavigation = useIsInsideMobileNavigation()
  const { isOpen, toggle, close } = useMobileNavigationStore()
  const ToggleIcon = isOpen ? X : Menu

  return (
    <IsInsideMobileNavigationContext.Provider value={true}>
      <button
        type="button"
        className="relative flex h-6 w-6 items-center justify-center rounded-md transition hover:bg-zinc-900/5 dark:hover:bg-white/5"
        aria-label="Toggle navigation"
        onClick={toggle}
      >
        <ToggleIcon className="h-4 w-4 text-zinc-900 dark:text-white" />
      </button>
      {!isInsideMobileNavigation && (
        <MobileNavigationPanel isOpen={isOpen} close={close} />
      )}
    </IsInsideMobileNavigationContext.Provider>
  )
}
