import { NextResponse } from 'next/server'
import { getCompletedItems } from '@/lib/data'

export const dynamic = 'force-dynamic'

export async function GET(request: Request) {
  try {
    const { searchParams } = new URL(request.url)
    const project = searchParams.get('project') || undefined
    const items = getCompletedItems(project)
    return NextResponse.json({ items })
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message || 'Failed to fetch completed items' },
      { status: 500 },
    )
  }
}
