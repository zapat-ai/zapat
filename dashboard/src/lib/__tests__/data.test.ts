import { join } from 'path'

// Mock child_process before importing data module
jest.mock('child_process', () => ({
  execSync: jest.fn(() => ''),
}))

// We'll mock fs per-test
const mockExistsSync = jest.fn()
const mockReadFileSync = jest.fn()
const mockReaddirSync = jest.fn()
const mockStatSync = jest.fn()

jest.mock('fs', () => ({
  existsSync: (...args: any[]) => mockExistsSync(...args),
  readFileSync: (...args: any[]) => mockReadFileSync(...args),
  readdirSync: (...args: any[]) => mockReaddirSync(...args),
  statSync: (...args: any[]) => mockStatSync(...args),
}))

// Set AUTOMATION_DIR before importing
process.env.AUTOMATION_DIR = '/tmp/test-automation'

import {
  getProjectList,
  getActiveItems,
  getCompletedItems,
  getMetricsData,
  getChartData,
  getHealthChecks,
} from '../data'

beforeEach(() => {
  jest.clearAllMocks()
})

describe('getProjectList', () => {
  it('returns projects from projects.conf (Tier 1)', () => {
    mockExistsSync.mockImplementation((p: string) =>
      p === join('/tmp/test-automation', 'config', 'projects.conf'),
    )
    mockReadFileSync.mockReturnValue('acme\tAcme Corp\nbeta\tBeta Project\n')

    const result = getProjectList()
    expect(result).toEqual([
      { slug: 'acme', name: 'Acme Corp' },
      { slug: 'beta', name: 'Beta Project' },
    ])
  })

  it('skips comments and blank lines in projects.conf', () => {
    mockExistsSync.mockImplementation((p: string) =>
      p === join('/tmp/test-automation', 'config', 'projects.conf'),
    )
    mockReadFileSync.mockReturnValue('# comment\n\nacme\tAcme\n')

    const result = getProjectList()
    expect(result).toEqual([{ slug: 'acme', name: 'Acme' }])
  })

  it('uses slug as name when no tab-separated name (Tier 1)', () => {
    mockExistsSync.mockImplementation((p: string) =>
      p === join('/tmp/test-automation', 'config', 'projects.conf'),
    )
    mockReadFileSync.mockReturnValue('myproject\n')

    const result = getProjectList()
    expect(result).toEqual([{ slug: 'myproject', name: 'myproject' }])
  })

  it('scans config dirs for repos.conf (Tier 2)', () => {
    const configDir = join('/tmp/test-automation', 'config')
    mockExistsSync.mockImplementation((p: string) => {
      if (p === join(configDir, 'projects.conf')) return false
      if (p === configDir) return true
      if (p === join(configDir, 'proj-a', 'repos.conf')) return true
      if (p === join(configDir, 'proj-b', 'repos.conf')) return true
      return false
    })
    mockReaddirSync.mockReturnValue(['proj-a', 'proj-b'])
    mockStatSync.mockReturnValue({ isDirectory: () => true })

    const result = getProjectList()
    expect(result).toEqual([
      { slug: 'proj-a', name: 'proj-a' },
      { slug: 'proj-b', name: 'proj-b' },
    ])
  })

  it('falls back to legacy single project (Tier 3)', () => {
    const configDir = join('/tmp/test-automation', 'config')
    mockExistsSync.mockImplementation((p: string) => {
      if (p === join(configDir, 'projects.conf')) return false
      if (p === configDir) return true
      if (p === join(configDir, 'repos.conf')) return true
      return false
    })
    mockReaddirSync.mockReturnValue([])

    const result = getProjectList()
    expect(result).toEqual([{ slug: 'default', name: 'Default Project' }])
  })

  it('returns empty when nothing exists', () => {
    mockExistsSync.mockReturnValue(false)

    const result = getProjectList()
    expect(result).toEqual([])
  })
})

describe('slug validation (path traversal prevention)', () => {
  it('rejects slugs with path traversal characters', () => {
    mockExistsSync.mockReturnValue(false)

    // All these should return empty due to invalid slug
    expect(getActiveItems('../../etc')).toEqual([])
    expect(getCompletedItems('../secret')).toEqual([])
    expect(getMetricsData(14, '../../etc')).toEqual([])
  })

  it('rejects slugs with special characters', () => {
    mockExistsSync.mockReturnValue(false)

    expect(getActiveItems('foo/bar')).toEqual([])
    expect(getActiveItems('foo bar')).toEqual([])
    expect(getActiveItems('foo.bar')).toEqual([])
  })

  it('accepts valid slugs', () => {
    mockExistsSync.mockReturnValue(false)

    // These should not throw — they'll return [] because config doesn't exist
    expect(getActiveItems('my-project')).toEqual([])
    expect(getActiveItems('project_123')).toEqual([])
    expect(getActiveItems('MyProject')).toEqual([])
  })
})

describe('getRepos default project path logic', () => {
  it('uses top-level config/ for slug=default when no config/default/ dir', () => {
    const configDir = join('/tmp/test-automation', 'config')
    const topLevelConf = join(configDir, 'repos.conf')
    mockExistsSync.mockImplementation((p: string) => {
      // config/default/ does NOT exist, but config/repos.conf DOES
      if (p === join(configDir, 'default')) return false
      if (p === topLevelConf) return true
      return false
    })
    mockReadFileSync.mockReturnValue('org/repo\t/path\tnode\n')

    const result = getActiveItems('default')
    // Should have tried to read the top-level repos.conf
    expect(mockReadFileSync).toHaveBeenCalledWith(topLevelConf, 'utf-8')
  })

  it('uses config/default/ for slug=default when that dir exists', () => {
    const configDir = join('/tmp/test-automation', 'config')
    const defaultDirConf = join(configDir, 'default', 'repos.conf')
    mockExistsSync.mockImplementation((p: string) => {
      // config/default/ DOES exist
      if (p === join(configDir, 'default')) return true
      if (p === defaultDirConf) return true
      return false
    })
    mockReadFileSync.mockReturnValue('org/repo\t/path\tnode\n')

    const result = getActiveItems('default')
    // Should have tried to read config/default/repos.conf
    expect(mockReadFileSync).toHaveBeenCalledWith(defaultDirConf, 'utf-8')
  })
})

describe('getMetricsData', () => {
  it('returns all metrics when no project filter', () => {
    const metricsPath = join('/tmp/test-automation', 'data', 'metrics.jsonl')
    mockExistsSync.mockImplementation((p: string) => p === metricsPath)
    const now = new Date().toISOString()
    mockReadFileSync.mockReturnValue(
      `{"timestamp":"${now}","job":"build","repo":"org/repo-a","status":"success"}\n{"timestamp":"${now}","job":"test","repo":"org/repo-b","status":"failure"}\n`,
    )

    const result = getMetricsData(14)
    expect(result).toHaveLength(2)
  })

  it('filters metrics by project repos', () => {
    const metricsPath = join('/tmp/test-automation', 'data', 'metrics.jsonl')
    const confPath = join('/tmp/test-automation', 'config', 'myproj', 'repos.conf')
    mockExistsSync.mockImplementation((p: string) => {
      if (p === metricsPath) return true
      if (p === confPath) return true
      return false
    })
    const now = new Date().toISOString()
    mockReadFileSync.mockImplementation((p: string) => {
      if (p === metricsPath) {
        return `{"timestamp":"${now}","job":"build","repo":"org/repo-a","status":"success"}\n{"timestamp":"${now}","job":"test","repo":"org/repo-b","status":"failure"}\n`
      }
      if (p === confPath) {
        return 'org/repo-a\t/path/a\tnode\n'
      }
      return ''
    })

    const result = getMetricsData(14, 'myproj')
    expect(result).toHaveLength(1)
    expect(result[0].repo).toBe('org/repo-a')
  })
})

describe('getChartData', () => {
  it('returns array of ChartDataPoints', () => {
    mockExistsSync.mockReturnValue(false)

    const result = getChartData(7)
    expect(result).toHaveLength(7)
    for (const point of result) {
      expect(point).toHaveProperty('date')
      expect(point).toHaveProperty('total')
      expect(point).toHaveProperty('success')
      expect(point).toHaveProperty('rate')
    }
  })

  it('returns correct day count', () => {
    mockExistsSync.mockReturnValue(false)

    expect(getChartData(14)).toHaveLength(14)
    expect(getChartData(3)).toHaveLength(3)
  })
})

describe('getActiveItems', () => {
  it('returns empty array when no repos config', () => {
    mockExistsSync.mockReturnValue(false)

    const result = getActiveItems()
    expect(result).toEqual([])
  })

  it('passes project param to getRepos', () => {
    // With project=nonexistent, confPath won't exist
    mockExistsSync.mockReturnValue(false)

    const result = getActiveItems('nonexistent')
    expect(result).toEqual([])
  })
})

describe('getCompletedItems', () => {
  it('returns empty array when no repos config', () => {
    mockExistsSync.mockReturnValue(false)

    const result = getCompletedItems()
    expect(result).toEqual([])
  })
})

describe('getHealthChecks', () => {
  it('returns an array of health checks', () => {
    mockExistsSync.mockReturnValue(false)

    const result = getHealthChecks()
    expect(Array.isArray(result)).toBe(true)
    for (const check of result) {
      expect(check).toHaveProperty('name')
      expect(check).toHaveProperty('status')
      expect(check).toHaveProperty('message')
    }
  })
})
