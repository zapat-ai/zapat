import { NextResponse } from 'next/server'
import { getSystemStatus } from '@/lib/data'

export const dynamic = 'force-dynamic'

export async function GET() {
  try {
    const status = getSystemStatus()
    return NextResponse.json(status)
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message || 'Failed to fetch health status' },
      { status: 500 },
    )
  }
}
