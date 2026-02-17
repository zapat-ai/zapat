import { NextResponse } from 'next/server'
import { getSystemStatus } from '@/lib/data'

export const dynamic = 'force-dynamic'

const VALID_SLUG = /^[a-zA-Z0-9_-]+$/

export async function GET(request: Request) {
  try {
    const { searchParams } = new URL(request.url)
    const project = searchParams.get('project') || undefined
    if (project && !VALID_SLUG.test(project)) {
      return NextResponse.json({ error: 'Invalid project slug' }, { status: 400 })
    }
    const status = getSystemStatus(project)
    return NextResponse.json(status)
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message || 'Failed to fetch health status' },
      { status: 500 },
    )
  }
}
