'use client'

import Link from 'next/link'
import { usePathname, useSearchParams } from 'next/navigation'
import { cn } from '@/lib/utils'

interface NavGroup {
  title: string
  links: Array<{
    title: string
    href: string
  }>
}

function NavLink({
  href,
  children,
  active = false,
}: {
  href: string
  children: React.ReactNode
  active?: boolean
}) {
  return (
    <Link
      href={href}
      aria-current={active ? 'page' : undefined}
      className={cn(
        'flex justify-between gap-2 py-1 pr-3 pl-4 text-sm transition',
        active
          ? 'text-zinc-900 dark:text-white'
          : 'text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-white',
      )}
    >
      <span className="truncate">{children}</span>
    </Link>
  )
}

function NavigationGroup({
  group,
  className,
}: {
  group: NavGroup
  className?: string
}) {
  const pathname = usePathname()
  const searchParams = useSearchParams()
  const projectParam = searchParams.get('project')

  return (
    <li className={cn('relative mt-6', className)}>
      <h2 className="text-xs font-semibold text-zinc-900 dark:text-white">
        {group.title}
      </h2>
      <div className="relative mt-3 pl-2">
        <div className="absolute inset-y-0 left-2 w-px bg-zinc-900/10 dark:bg-white/5" />
        <ul role="list" className="border-l border-transparent">
          {group.links.map((link) => {
            const isActive = link.href === pathname
            const href = projectParam
              ? `${link.href}?project=${encodeURIComponent(projectParam)}`
              : link.href
            return (
              <li key={link.href} className="relative">
                {isActive && (
                  <div className="absolute left-0 h-6 w-px bg-emerald-500" style={{ top: 4 }} />
                )}
                <NavLink href={href} active={isActive}>
                  {link.title}
                </NavLink>
              </li>
            )
          })}
        </ul>
      </div>
    </li>
  )
}

export const navigation: Array<NavGroup> = [
  {
    title: 'Dashboard',
    links: [
      { title: 'Overview', href: '/' },
      { title: 'Board', href: '/board' },
      { title: 'Activity', href: '/activity' },
      { title: 'Completed', href: '/completed' },
    ],
  },
  {
    title: 'System',
    links: [
      { title: 'Health', href: '/health' },
      { title: 'Analytics', href: '/analytics' },
    ],
  },
]

export function Navigation(props: React.ComponentPropsWithoutRef<'nav'>) {
  return (
    <nav {...props}>
      <ul role="list">
        {navigation.map((group, groupIndex) => (
          <NavigationGroup
            key={group.title}
            group={group}
            className={groupIndex === 0 ? 'md:mt-0' : ''}
          />
        ))}
      </ul>
    </nav>
  )
}
