import { NextResponse } from 'next/server'
import { getActiveItems, getCompletedItems } from '@/lib/data'

export const dynamic = 'force-dynamic'

export async function GET(request: Request) {
  try {
    const { searchParams } = new URL(request.url)
    const project = searchParams.get('project') || undefined
    const active = getActiveItems(project)
    const completed = getCompletedItems(project).slice(0, 5)
    return NextResponse.json({ items: [...active, ...completed] })
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message || 'Failed to fetch items' },
      { status: 500 },
    )
  }
}
