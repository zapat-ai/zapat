import { NextResponse } from 'next/server'
import { getMetricsData, getChartData } from '@/lib/data'

export const dynamic = 'force-dynamic'

const VALID_SLUG = /^[a-zA-Z0-9_-]+$/

export async function GET(request: Request) {
  try {
    const { searchParams } = new URL(request.url)
    const days = parseInt(searchParams.get('days') || '14')
    const chart = searchParams.get('chart') === 'true'
    const project = searchParams.get('project') || undefined
    if (project && !VALID_SLUG.test(project)) {
      return NextResponse.json({ error: 'Invalid project slug' }, { status: 400 })
    }

    if (chart) {
      const chartData = getChartData(days, project)
      return NextResponse.json({ chartData })
    }

    const metrics = getMetricsData(days, project)
    return NextResponse.json({ metrics })
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message || 'Failed to fetch metrics' },
      { status: 500 },
    )
  }
}
