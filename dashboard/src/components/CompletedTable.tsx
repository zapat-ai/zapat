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
import type { PipelineItem } from '@/lib/types'
import { useEffect, useState } from 'react'

function ClientDate({ date }: { date: string }) {
  const [text, setText] = useState('')
  useEffect(() => {
    setText(new Date(date).toLocaleDateString())
  }, [date])
  return <>{text}</>
}

export function CompletedTable({ items, loading }: { items: PipelineItem[]; loading?: boolean }) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Date</TableHead>
          <TableHead>Item</TableHead>
          <TableHead>Title</TableHead>
          <TableHead>Repo</TableHead>
          <TableHead>Status</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {loading ? (
          Array.from({ length: 5 }).map((_, i) => (
            <TableRow key={i}>
              <TableCell><Skeleton className="h-4 w-20" /></TableCell>
              <TableCell><Skeleton className="h-4 w-14" /></TableCell>
              <TableCell><Skeleton className="h-4 w-48" /></TableCell>
              <TableCell><Skeleton className="h-4 w-24" /></TableCell>
              <TableCell><Skeleton className="h-5 w-16 rounded-full" /></TableCell>
            </TableRow>
          ))
        ) : items.length === 0 ? (
          <TableRow>
            <TableCell
              colSpan={5}
              className="h-24 text-center text-zinc-400 dark:text-zinc-500"
            >
              No completed items
            </TableCell>
          </TableRow>
        ) : (
          items.map((item, i) => {
            const repoShort = item.repo.split('/').pop()
            const prefix = item.type === 'pr' ? 'PR' : '#'
            const hasTime = !!item.completedAt
            const typeLabel = item.type === 'pr' ? 'Merged' : 'Closed'
            const badgeColor = item.type === 'pr' ? 'merged' : 'closed'

            return (
              <TableRow key={i}>
                <TableCell className="text-zinc-600 dark:text-zinc-300">
                  {hasTime ? <ClientDate date={item.completedAt!} /> : '-'}
                </TableCell>
                <TableCell>
                  <a
                    href={item.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="font-medium text-emerald-600 hover:text-emerald-500 dark:text-emerald-400"
                  >
                    {prefix}
                    {item.number}
                  </a>
                </TableCell>
                <TableCell className="text-zinc-900 dark:text-white">
                  {item.title.slice(0, 70)}
                </TableCell>
                <TableCell className="text-zinc-600 dark:text-zinc-300">
                  {repoShort}
                </TableCell>
                <TableCell>
                  <Badge color={badgeColor}>{typeLabel}</Badge>
                </TableCell>
              </TableRow>
            )
          })
        )}
      </TableBody>
    </Table>
  )
}
