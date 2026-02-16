import { NextResponse } from 'next/server'
import { getCompletedItems } from '@/lib/data'

export const dynamic = 'force-dynamic'

export async function GET() {
  try {
    const items = getCompletedItems()
    return NextResponse.json({ items })
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message || 'Failed to fetch completed items' },
      { status: 500 },
    )
  }
}
