'use client'

import { Skeleton } from '@/components/ui/skeleton'
import type { ChartDataPoint } from '@/lib/types'
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  Cell,
} from 'recharts'

function getBarColor(d: ChartDataPoint): string {
  if (d.total === 0) return '#a1a1aa' // zinc-400
  if (d.rate >= 80) return '#10b981' // emerald-500
  if (d.rate >= 50) return '#f59e0b' // amber-500
  return '#ef4444' // red-500
}

export function SuccessChart({
  data,
  title = '14-Day Success Rate',
  loading,
}: {
  data: ChartDataPoint[]
  title?: string
  loading?: boolean
}) {
  if (loading) {
    return (
      <div>
        {title && (
          <h3 className="mb-4 text-sm font-semibold text-zinc-900 dark:text-white">
            {title}
          </h3>
        )}
        <Skeleton className="h-[180px] w-full rounded-lg" />
      </div>
    )
  }

  if (data.length === 0) {
    return (
      <div>
        {title && (
          <h3 className="mb-4 text-sm font-semibold text-zinc-900 dark:text-white">
            {title}
          </h3>
        )}
        <p className="py-8 text-center text-sm text-zinc-400 dark:text-zinc-500">
          No chart data
        </p>
      </div>
    )
  }

  const chartData = data.map((d) => ({
    ...d,
    label: d.date.slice(5),
  }))

  return (
    <div>
      {title && (
        <h3 className="mb-4 text-sm font-semibold text-zinc-900 dark:text-white">
          {title}
        </h3>
      )}
      <ResponsiveContainer width="100%" height={180}>
        <BarChart data={chartData} margin={{ top: 5, right: 5, bottom: 5, left: -20 }}>
          <XAxis
            dataKey="label"
            tick={{ fontSize: 10, fill: '#a1a1aa' }}
            tickLine={false}
            axisLine={false}
          />
          <YAxis
            tick={{ fontSize: 10, fill: '#a1a1aa' }}
            tickLine={false}
            axisLine={false}
            domain={[0, 100]}
            tickFormatter={(v) => `${v}%`}
          />
          <Tooltip
            contentStyle={{
              backgroundColor: '#18181b',
              border: '1px solid #3f3f46',
              borderRadius: '0.5rem',
              fontSize: '0.75rem',
              color: '#fafafa',
            }}
            formatter={(_value, _name, props) => {
              const point = (props as any).payload as ChartDataPoint
              return [`${point.success}/${point.total} (${point.rate}%)`, 'Success']
            }}
            labelFormatter={(label) => `Date: ${label}`}
          />
          <Bar dataKey="rate" radius={[4, 4, 0, 0]} maxBarSize={32}>
            {chartData.map((entry, index) => (
              <Cell key={index} fill={getBarColor(entry)} />
            ))}
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  )
}
