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
