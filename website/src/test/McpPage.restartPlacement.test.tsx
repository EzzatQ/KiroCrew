// Apply & Restart ends running turns, so on a phone it sits after the server
// list instead of in the page header where a thumb lands first.
import { screen } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { renderWithProviders } from './helpers'
import McpPage from '../pages/McpPage'

let mobile = false
vi.mock('../hooks/useIsMobile', () => ({ useIsMobile: () => mobile }))
vi.mock('../components/RestartButton', () => ({ default: () => <button data-testid="restart-button">Apply &amp; Restart</button> }))
vi.mock('../pages/overview/McpTab', () => ({ default: () => <div data-testid="mcp-tab" /> }))
vi.mock('../pages/settings/McpManagement', () => ({ McpManagement: () => <div data-testid="mcp-management" /> }))

beforeEach(() => { mobile = false })

describe('McpPage restart placement', () => {
  it('desktop: the restart sits in the page header', async () => {
    renderWithProviders(<McpPage />)
    expect(screen.getByTestId('restart-button')).toBeInTheDocument()
    expect(screen.queryByTestId('mcp-restart-foot')).toBeNull()
  })

  it('phone: the restart follows the server list, once', async () => {
    mobile = true
    renderWithProviders(<McpPage />)
    const foot = screen.getByTestId('mcp-restart-foot')
    expect(screen.getAllByTestId('restart-button')).toHaveLength(1)
    expect(foot).toContainElement(screen.getByTestId('restart-button'))
    expect(await screen.findByTestId('mcp-management')).toBeInTheDocument()
    expect(screen.getByTestId('mcp-management').compareDocumentPosition(foot) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })
})
