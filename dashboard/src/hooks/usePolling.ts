'use client'

import { useCallback, useEffect, useRef, useState } from 'react'

interface UsePollingOptions {
  url: string
  interval?: number
  enabled?: boolean
}

interface UsePollingResult<T> {
  data: T | null
  isLoading: boolean
  error: string | null
  lastUpdated: Date | null
  refresh: () => void
}

export function usePolling<T = any>({
  url,
  interval = 60_000,
  enabled = true,
}: UsePollingOptions): UsePollingResult<T> {
  let [data, setData] = useState<T | null>(null)
  let [isLoading, setIsLoading] = useState(true)
  let [error, setError] = useState<string | null>(null)
  let [lastUpdated, setLastUpdated] = useState<Date | null>(null)
  let intervalRef = useRef<NodeJS.Timeout | null>(null)

  let fetchData = useCallback(async () => {
    try {
      let res = await fetch(url)
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      let json = await res.json()
      setData(json)
      setError(null)
      setLastUpdated(new Date())
    } catch (err: any) {
      setError(err.message || 'Failed to fetch')
    } finally {
      setIsLoading(false)
    }
  }, [url])

  useEffect(() => {
    if (!enabled) return

    fetchData()

    intervalRef.current = setInterval(fetchData, interval)
    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current)
    }
  }, [fetchData, interval, enabled])

  return { data, isLoading, error, lastUpdated, refresh: fetchData }
}
