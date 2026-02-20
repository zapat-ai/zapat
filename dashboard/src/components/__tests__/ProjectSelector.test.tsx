/**
 * @jest-environment jsdom
 */
import React from 'react'
import { render, screen, fireEvent } from '@testing-library/react'
import '@testing-library/jest-dom'
import { ProjectSelector } from '../ProjectSelector'

// jsdom doesn't implement scrollIntoView
Element.prototype.scrollIntoView = jest.fn()

const mockSetProject = jest.fn()
const mockUseProject = jest.fn()

jest.mock('@/hooks/useProject', () => ({
  useProject: (...args: any[]) => mockUseProject(...args),
}))

beforeEach(() => {
  jest.clearAllMocks()
  mockUseProject.mockReturnValue({
    project: undefined,
    projectName: 'All Projects',
    projects: [
      { slug: 'alpha', name: 'Alpha' },
      { slug: 'beta', name: 'Beta' },
    ],
    setProject: mockSetProject,
    isLoading: false,
  })
})

describe('ProjectSelector', () => {
  it('renders the selector button with current project name', () => {
    render(<ProjectSelector />)
    expect(screen.getByRole('button', { name: /Project: All Projects/i })).toBeInTheDocument()
  })

  it('dropdown anchors right on mobile and left on desktop', () => {
    render(<ProjectSelector />)

    fireEvent.click(screen.getByRole('button', { name: /Project: All Projects/i }))

    const listbox = screen.getByRole('listbox')
    expect(listbox).toHaveClass('right-0')
    expect(listbox).toHaveClass('lg:left-0')
    expect(listbox).toHaveClass('lg:right-auto')
  })

  it('dropdown does not use bare left-0 (only lg:left-0)', () => {
    render(<ProjectSelector />)

    fireEvent.click(screen.getByRole('button', { name: /Project: All Projects/i }))

    const listbox = screen.getByRole('listbox')
    const classes = listbox.className.split(/\s+/)

    expect(classes).not.toContain('left-0')
    expect(classes).toContain('lg:left-0')
  })

  it('shows static label (no dropdown) when there is only one project', () => {
    mockUseProject.mockReturnValue({
      project: undefined,
      projectName: 'All Projects',
      projects: [{ slug: 'only', name: 'Only Project' }],
      setProject: mockSetProject,
      isLoading: false,
    })

    render(<ProjectSelector />)
    // Should render the project name as a static label, not a dropdown button
    expect(screen.getByText('Only Project')).toBeInTheDocument()
    expect(screen.queryByRole('button')).toBeNull()
  })

  it('renders nothing when there are zero projects', () => {
    mockUseProject.mockReturnValue({
      project: undefined,
      projectName: 'All Projects',
      projects: [],
      setProject: mockSetProject,
      isLoading: false,
    })

    const { container } = render(<ProjectSelector />)
    expect(container.firstChild).toBeNull()
  })
})
