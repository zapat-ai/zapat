import { NextResponse } from 'next/server'
import { getMetricsData, getChartData } from '@/lib/data'

export const dynamic = 'force-dynamic'

export async function GET(request: Request) {
  try {
    const { searchParams } = new URL(request.url)
    const days = parseInt(searchParams.get('days') || '14')
    const chart = searchParams.get('chart') === 'true'

    if (chart) {
      const chartData = getChartData(days)
      return NextResponse.json({ chartData })
    }

    const metrics = getMetricsData(days)
    return NextResponse.json({ metrics })
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message || 'Failed to fetch metrics' },
      { status: 500 },
    )
  }
}
