'use client'

import { useSearchParams, useRouter, usePathname } from 'next/navigation'
import { useCallback } from 'react'
import { usePolling } from './usePolling'

interface ProjectInfo {
  slug: string
  name: string
}

interface UseProjectResult {
  project: string | undefined
  projectName: string
  projects: ProjectInfo[]
  setProject: (slug: string | undefined) => void
  isLoading: boolean
}

export function useProject(): UseProjectResult {
  const searchParams = useSearchParams()
  const router = useRouter()
  const pathname = usePathname()

  const { data: configData, isLoading } = usePolling<{
    projects: ProjectInfo[]
  }>({
    url: '/api/config',
    interval: 300_000, // refresh project list every 5 min
  })

  const projects = configData?.projects || []
  const project = searchParams.get('project') || undefined

  const projectName = project
    ? projects.find((p) => p.slug === project)?.name || project
    : 'All Projects'

  const setProject = useCallback(
    (slug: string | undefined) => {
      const params = new URLSearchParams(searchParams.toString())
      if (slug) {
        params.set('project', slug)
      } else {
        params.delete('project')
      }
      const qs = params.toString()
      router.push(qs ? `${pathname}?${qs}` : pathname)
    },
    [searchParams, router, pathname],
  )

  return { project, projectName, projects, setProject, isLoading }
}
