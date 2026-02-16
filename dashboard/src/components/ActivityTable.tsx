'use client'

import { Badge } from '@/components/Badge'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import type { MetricEntry } from '@/lib/types'
import { useEffect, useState } from 'react'

function ClientDate({ date, format }: { date: string; format: 'locale' | 'date' }) {
  const [text, setText] = useState('')
  useEffect(() => {
    setText(format === 'date'
      ? new Date(date).toLocaleDateString()
      : new Date(date).toLocaleString()
    )
  }, [date, format])
  return <>{text}</>
}

export function ActivityTable({ metrics, loading }: { metrics: MetricEntry[]; loading?: boolean }) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Time</TableHead>
          <TableHead>Job</TableHead>
          <TableHead>Repo</TableHead>
          <TableHead>Status</TableHead>
          <TableHead>Duration</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {loading ? (
          Array.from({ length: 5 }).map((_, i) => (
            <TableRow key={i}>
              <TableCell><Skeleton className="h-4 w-32" /></TableCell>
              <TableCell><Skeleton className="h-4 w-20" /></TableCell>
              <TableCell><Skeleton className="h-4 w-24" /></TableCell>
              <TableCell><Skeleton className="h-5 w-16 rounded-full" /></TableCell>
              <TableCell><Skeleton className="h-4 w-12" /></TableCell>
            </TableRow>
          ))
        ) : metrics.length === 0 ? (
          <TableRow>
            <TableCell
              colSpan={5}
              className="h-24 text-center text-zinc-400 dark:text-zinc-500"
            >
              No activity data
            </TableCell>
          </TableRow>
        ) : (
          metrics.map((m, i) => {
            const hasTime = !!m.timestamp
            const repoShort = m.repo ? m.repo.split('/').pop() : '-'
            const dur = m.duration_s ? `${m.duration_s}s` : '-'

            return (
              <TableRow key={i}>
                <TableCell className="text-zinc-600 dark:text-zinc-300">
                  {hasTime ? <ClientDate date={m.timestamp!} format="locale" /> : '-'}
                </TableCell>
                <TableCell className="font-medium text-zinc-900 dark:text-white">
                  {m.job || '-'}
                </TableCell>
                <TableCell className="text-zinc-600 dark:text-zinc-300">
                  {repoShort}
                </TableCell>
                <TableCell>
                  <Badge color={m.status === 'success' ? 'success' : m.status === 'failure' ? 'failure' : 'default'}>
                    {m.status || '-'}
                  </Badge>
                </TableCell>
                <TableCell className="text-zinc-600 dark:text-zinc-300">
                  {dur}
                </TableCell>
              </TableRow>
            )
          })
        )}
      </TableBody>
    </Table>
  )
}
