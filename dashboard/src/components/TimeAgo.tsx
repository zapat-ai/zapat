'use client'

import { useEffect, useState } from 'react'

function formatTimeAgo(dateStr: string): string {
  const date = new Date(dateStr)
  const now = new Date()
  const diffMs = now.getTime() - date.getTime()
  const diffSec = Math.floor(diffMs / 1000)
  const diffMin = Math.floor(diffSec / 60)
  const diffHr = Math.floor(diffMin / 60)
  const diffDay = Math.floor(diffHr / 24)

  if (diffSec < 60) return 'just now'
  if (diffMin < 60) return `${diffMin}m ago`
  if (diffHr < 24) return `${diffHr}h ago`
  if (diffDay < 7) return `${diffDay}d ago`
  return date.toLocaleDateString()
}

export function TimeAgo({ date }: { date: string }) {
  let [text, setText] = useState<string | null>(null)

  useEffect(() => {
    setText(formatTimeAgo(date))
    let interval = setInterval(() => setText(formatTimeAgo(date)), 60_000)
    return () => clearInterval(interval)
  }, [date])

  return (
    <time
      dateTime={date}
      suppressHydrationWarning
      className="text-zinc-500 dark:text-zinc-400"
    >
      {text ?? ''}
    </time>
  )
}
