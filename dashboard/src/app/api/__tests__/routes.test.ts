// Mock the data module
jest.mock('@/lib/data', () => ({
  getActiveItems: jest.fn((project?: string) => {
    if (project === 'acme') return [{ type: 'pr', repo: 'org/acme', number: 1, title: 'Test PR', labels: [], url: '', stage: 'review' }]
    return [
      { type: 'pr', repo: 'org/acme', number: 1, title: 'Test PR', labels: [], url: '', stage: 'review' },
      { type: 'issue', repo: 'org/beta', number: 2, title: 'Test Issue', labels: [], url: '', stage: 'queued' },
    ]
  }),
  getCompletedItems: jest.fn((project?: string) => {
    if (project === 'acme') return [{ type: 'pr', repo: 'org/acme', number: 3, title: 'Done', labels: [], url: '', stage: 'done' }]
    return [
      { type: 'pr', repo: 'org/acme', number: 3, title: 'Done', labels: [], url: '', stage: 'done' },
      { type: 'issue', repo: 'org/beta', number: 4, title: 'Done2', labels: [], url: '', stage: 'done' },
    ]
  }),
  getMetricsData: jest.fn((days: number, project?: string) => {
    if (project === 'acme') return [{ timestamp: '2024-01-01', job: 'build', repo: 'org/acme', status: 'success' }]
    return [
      { timestamp: '2024-01-01', job: 'build', repo: 'org/acme', status: 'success' },
      { timestamp: '2024-01-01', job: 'test', repo: 'org/beta', status: 'failure' },
    ]
  }),
  getChartData: jest.fn((days: number, project?: string) => [
    { date: '2024-01-01', total: 1, success: 1, rate: 100 },
  ]),
  getSystemStatus: jest.fn((project?: string) => ({
    healthy: true,
    sessionExists: true,
    windowCount: 2,
    activeSlots: 1,
    maxSlots: 10,
    checks: [],
  })),
  getProjectList: jest.fn(() => [
    { slug: 'acme', name: 'Acme Corp' },
    { slug: 'beta', name: 'Beta' },
  ]),
}))

// Mock pipeline.config
jest.mock('../../../../pipeline.config', () => ({
  pipelineConfig: {
    name: 'Test Pipeline',
    refreshInterval: 30000,
    stages: [],
  },
}), { virtual: true })

import { getActiveItems, getCompletedItems, getMetricsData, getChartData, getSystemStatus, getProjectList } from '@/lib/data'

describe('API Route: /api/items', () => {
  it('calls data functions without project when no param', async () => {
    const { GET } = await import('../items/route')
    const request = new Request('http://localhost/api/items')
    const response = await GET(request)
    const json = await response.json()

    expect(getActiveItems).toHaveBeenCalledWith(undefined)
    expect(json.items).toBeDefined()
    expect(json.items.length).toBeGreaterThan(0)
  })

  it('passes project param to data functions', async () => {
    const { GET } = await import('../items/route')
    const request = new Request('http://localhost/api/items?project=acme')
    const response = await GET(request)
    const json = await response.json()

    expect(getActiveItems).toHaveBeenCalledWith('acme')
    expect(getCompletedItems).toHaveBeenCalledWith('acme')
    expect(json.items).toBeDefined()
  })
})

describe('API Route: /api/metrics', () => {
  it('returns metrics without project filter', async () => {
    const { GET } = await import('../metrics/route')
    const request = new Request('http://localhost/api/metrics?days=7')
    const response = await GET(request)
    const json = await response.json()

    expect(getMetricsData).toHaveBeenCalledWith(7, undefined)
    expect(json.metrics).toBeDefined()
  })

  it('passes project param for metrics', async () => {
    const { GET } = await import('../metrics/route')
    const request = new Request('http://localhost/api/metrics?days=7&project=acme')
    const response = await GET(request)
    const json = await response.json()

    expect(getMetricsData).toHaveBeenCalledWith(7, 'acme')
  })

  it('returns chart data when chart=true', async () => {
    const { GET } = await import('../metrics/route')
    const request = new Request('http://localhost/api/metrics?days=14&chart=true&project=acme')
    const response = await GET(request)
    const json = await response.json()

    expect(getChartData).toHaveBeenCalledWith(14, 'acme')
    expect(json.chartData).toBeDefined()
  })
})

describe('API Route: /api/completed', () => {
  it('returns completed items without project filter', async () => {
    const { GET } = await import('../completed/route')
    const request = new Request('http://localhost/api/completed')
    const response = await GET(request)
    const json = await response.json()

    expect(getCompletedItems).toHaveBeenCalledWith(undefined)
    expect(json.items).toBeDefined()
  })

  it('passes project param', async () => {
    const { GET } = await import('../completed/route')
    const request = new Request('http://localhost/api/completed?project=acme')
    const response = await GET(request)
    const json = await response.json()

    expect(getCompletedItems).toHaveBeenCalledWith('acme')
  })
})

describe('API Route: /api/health', () => {
  it('returns system status without project filter', async () => {
    const { GET } = await import('../health/route')
    const request = new Request('http://localhost/api/health')
    const response = await GET(request)
    const json = await response.json()

    expect(getSystemStatus).toHaveBeenCalledWith(undefined)
    expect(json.healthy).toBe(true)
  })

  it('passes project param', async () => {
    const { GET } = await import('../health/route')
    const request = new Request('http://localhost/api/health?project=acme')
    await GET(request)

    expect(getSystemStatus).toHaveBeenCalledWith('acme')
  })
})

describe('API Route: /api/config', () => {
  it('includes projects list', async () => {
    const { GET } = await import('../config/route')
    const response = await GET()
    const json = await response.json()

    expect(json.projects).toBeDefined()
    expect(json.projects).toEqual([
      { slug: 'acme', name: 'Acme Corp' },
      { slug: 'beta', name: 'Beta' },
    ])
    expect(json.name).toBe('Test Pipeline')
  })
})
