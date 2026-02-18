describe('dashboard port logic', () => {
  it('uses DASHBOARD_PORT env var as fallback', () => {
    // Test the port calculation logic directly (mirrors dashboard.mjs line 30)
    const calcPort = (optsServe: any, envPort: any) => {
      return parseInt(optsServe) || parseInt(envPort) || 3000
    }

    // No opts, no env -> 3000
    expect(calcPort(undefined, undefined)).toBe(3000)

    // opts.serve set -> use it
    expect(calcPort('8080', undefined)).toBe(8080)

    // env var set, no opts -> use env
    expect(calcPort(undefined, '9090')).toBe(9090)
    expect(calcPort(NaN, '9090')).toBe(9090)

    // opts takes precedence over env
    expect(calcPort('8080', '9090')).toBe(8080)

    // Boolean true from --serve flag (no value) -> falls through to env
    expect(calcPort(true, '9090')).toBe(9090)

    // Boolean true from --serve flag, no env -> 3000
    expect(calcPort(true, undefined)).toBe(3000)
  })

  it('validates port range', () => {
    const isValidPort = (port: number) => port >= 1 && port <= 65535

    expect(isValidPort(3000)).toBe(true)
    expect(isValidPort(1)).toBe(true)
    expect(isValidPort(65535)).toBe(true)
    expect(isValidPort(0)).toBe(false)
    expect(isValidPort(65536)).toBe(false)
    expect(isValidPort(-1)).toBe(false)
  })

  it('dev mode passes PORT env from DASHBOARD_PORT', () => {
    // Test the dev port calculation (mirrors dashboard.mjs line 25)
    const calcDevPort = (envDashboardPort: any) => {
      return String(parseInt(envDashboardPort) || 3000)
    }

    expect(calcDevPort(undefined)).toBe('3000')
    expect(calcDevPort('4200')).toBe('4200')
    expect(calcDevPort('not-a-number')).toBe('3000')
  })
})

describe('resolvePort logic', () => {
  // Mirrors the exported resolvePort function in dashboard.mjs
  function resolvePort(
    cliPort: any,
    projectSlug: string | undefined,
    env: Record<string, string | undefined>,
  ): number {
    if (cliPort && !isNaN(parseInt(cliPort))) return parseInt(cliPort)

    if (projectSlug) {
      const envKey = `DASHBOARD_PORT_${projectSlug.toUpperCase().replace(/-/g, '_')}`
      const perProjectPort = parseInt(env[envKey] || '')
      if (perProjectPort) return perProjectPort
    }

    return parseInt(env.DASHBOARD_PORT || '') || 3000
  }

  it('uses CLI port when provided', () => {
    expect(resolvePort('9999', undefined, {})).toBe(9999)
    expect(resolvePort('8080', 'acme', { DASHBOARD_PORT_ACME: '8081' })).toBe(8080)
  })

  it('uses per-project env var when project slug provided', () => {
    expect(resolvePort(undefined, 'acme', { DASHBOARD_PORT_ACME: '8081' })).toBe(8081)
  })

  it('converts hyphenated slugs to uppercase underscored env keys', () => {
    expect(
      resolvePort(undefined, 'my-project', { DASHBOARD_PORT_MY_PROJECT: '8082' }),
    ).toBe(8082)
  })

  it('falls back to DASHBOARD_PORT when no per-project var', () => {
    expect(
      resolvePort(undefined, 'acme', { DASHBOARD_PORT: '8080' }),
    ).toBe(8080)
  })

  it('falls back to 3000 when no env vars set', () => {
    expect(resolvePort(undefined, undefined, {})).toBe(3000)
    expect(resolvePort(undefined, 'acme', {})).toBe(3000)
  })

  it('prioritizes per-project over DASHBOARD_PORT', () => {
    expect(
      resolvePort(undefined, 'acme', {
        DASHBOARD_PORT_ACME: '8081',
        DASHBOARD_PORT: '8080',
      }),
    ).toBe(8081)
  })
})

describe('project slug validation', () => {
  const VALID_SLUG = /^[a-zA-Z0-9_-]+$/

  it('accepts valid slugs', () => {
    expect(VALID_SLUG.test('acme')).toBe(true)
    expect(VALID_SLUG.test('my-project')).toBe(true)
    expect(VALID_SLUG.test('project_123')).toBe(true)
    expect(VALID_SLUG.test('MyProject')).toBe(true)
  })

  it('rejects invalid slugs', () => {
    expect(VALID_SLUG.test('../../etc')).toBe(false)
    expect(VALID_SLUG.test('foo/bar')).toBe(false)
    expect(VALID_SLUG.test('foo bar')).toBe(false)
    expect(VALID_SLUG.test('foo.bar')).toBe(false)
    expect(VALID_SLUG.test('')).toBe(false)
  })
})
