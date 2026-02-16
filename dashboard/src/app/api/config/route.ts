import { NextResponse } from 'next/server'
import { pipelineConfig } from '../../../../pipeline.config'

export async function GET() {
  return NextResponse.json({
    name: pipelineConfig.name,
    refreshInterval: pipelineConfig.refreshInterval,
    stages: pipelineConfig.stages,
  })
}
