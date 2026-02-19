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
    defaultProject: 'acme',
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

describe('API Route slug validation (path traversal)', () => {
  it('rejects path traversal in /api/items', async () => {
    const { GET } = await import('../items/route')
    const response = await GET(new Request('http://localhost/api/items?project=../../etc'))
    expect(response.status).toBe(400)
    const json = await response.json()
    expect(json.error).toBe('Invalid project slug')
  })

  it('rejects path traversal in /api/metrics', async () => {
    const { GET } = await import('../metrics/route')
    const response = await GET(new Request('http://localhost/api/metrics?project=../secret'))
    expect(response.status).toBe(400)
  })

  it('rejects path traversal in /api/completed', async () => {
    const { GET } = await import('../completed/route')
    const response = await GET(new Request('http://localhost/api/completed?project=foo/bar'))
    expect(response.status).toBe(400)
  })

  it('rejects path traversal in /api/health', async () => {
    const { GET } = await import('../health/route')
    const response = await GET(new Request('http://localhost/api/health?project=foo.bar'))
    expect(response.status).toBe(400)
  })

  it('accepts valid slugs with hyphens and underscores', async () => {
    const { GET } = await import('../items/route')
    const response = await GET(new Request('http://localhost/api/items?project=my-project_123'))
    expect(response.status).toBe(200)
  })
})

describe('API Route error sanitization', () => {
  it('does not leak error details from /api/items', async () => {
    ;(getActiveItems as jest.Mock).mockImplementationOnce(() => { throw new Error('ENOENT: /tmp/secret/path') })
    const { GET } = await import('../items/route')
    const response = await GET(new Request('http://localhost/api/items'))
    expect(response.status).toBe(500)
    const json = await response.json()
    expect(json.error).toBe('Internal server error')
    expect(json.error).not.toContain('ENOENT')
  })

  it('does not leak error details from /api/metrics', async () => {
    ;(getMetricsData as jest.Mock).mockImplementationOnce(() => { throw new Error('permission denied /etc/passwd') })
    const { GET } = await import('../metrics/route')
    const response = await GET(new Request('http://localhost/api/metrics?days=7'))
    expect(response.status).toBe(500)
    const json = await response.json()
    expect(json.error).toBe('Internal server error')
  })

  it('does not leak error details from /api/health', async () => {
    ;(getSystemStatus as jest.Mock).mockImplementationOnce(() => { throw new Error('cannot read /var/run/secret') })
    const { GET } = await import('../health/route')
    const response = await GET(new Request('http://localhost/api/health'))
    expect(response.status).toBe(500)
    const json = await response.json()
    expect(json.error).toBe('Internal server error')
  })

  it('does not leak error details from /api/completed', async () => {
    ;(getCompletedItems as jest.Mock).mockImplementationOnce(() => { throw new Error('spawn gh ENOENT') })
    const { GET } = await import('../completed/route')
    const response = await GET(new Request('http://localhost/api/completed'))
    expect(response.status).toBe(500)
    const json = await response.json()
    expect(json.error).toBe('Internal server error')
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

  it('includes defaultProject from pipeline config', async () => {
    const { GET } = await import('../config/route')
    const response = await GET()
    const json = await response.json()

    expect(json.defaultProject).toBe('acme')
  })
})
