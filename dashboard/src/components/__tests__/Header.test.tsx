/**
 * @jest-environment jsdom
 */
import React from 'react'
import { render, screen } from '@testing-library/react'
import '@testing-library/jest-dom'
import { Header } from '../Header'

// Mock child components to isolate Header tests
jest.mock('next/link', () => ({
  __esModule: true,
  default: ({ children, ...props }: any) => <a {...props}>{children}</a>,
}))

jest.mock('../Logo', () => ({
  Logo: ({ className }: any) => <div data-testid="logo" className={className} />,
}))

jest.mock('../MobileNavigation', () => ({
  MobileNavigation: () => <div data-testid="mobile-nav" />,
  useMobileNavigationStore: () => ({ isOpen: false }),
}))

jest.mock('../ThemeToggle', () => ({
  ThemeToggle: () => <div data-testid="theme-toggle" />,
}))

jest.mock('../ProjectSelector', () => ({
  ProjectSelector: ({ className }: any) => (
    <div data-testid="project-selector" className={className} />
  ),
}))

describe('Header', () => {
  it('renders a vertical divider between ProjectSelector and ThemeToggle on mobile', () => {
    const { container } = render(<Header />)

    // Find the decorative divider
    const divider = container.querySelector('[aria-hidden="true"]')
    expect(divider).toBeInTheDocument()
    expect(divider).toHaveClass('h-5', 'w-px', 'lg:hidden')
    expect(divider).toHaveClass('bg-zinc-300')
    expect(divider).toHaveClass('dark:bg-zinc-600')
  })

  it('divider is positioned between mobile ProjectSelector and ThemeToggle', () => {
    const { container } = render(<Header />)

    const divider = container.querySelector('[aria-hidden="true"]')
    expect(divider).toBeTruthy()

    // Verify ordering: ProjectSelector -> divider -> ThemeToggle
    const themeToggle = screen.getByTestId('theme-toggle')

    // The divider's parent contains the right-side controls
    const parent = divider!.parentElement!
    const children = Array.from(parent.children)
    const dividerIdx = children.indexOf(divider as Element)
    const themeIdx = children.indexOf(themeToggle)

    expect(dividerIdx).toBeGreaterThan(-1)
    expect(themeIdx).toBe(dividerIdx + 1)
  })

  it('divider is hidden on desktop (lg:hidden)', () => {
    const { container } = render(<Header />)

    const divider = container.querySelector('[aria-hidden="true"]')
    expect(divider).toHaveClass('lg:hidden')
  })
})
