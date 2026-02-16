import { NextResponse } from 'next/server'
import { getActiveItems } from '@/lib/data'

export const dynamic = 'force-dynamic'

export async function GET() {
  try {
    const items = getActiveItems()
    return NextResponse.json({ items })
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message || 'Failed to fetch items' },
      { status: 500 },
    )
  }
}
