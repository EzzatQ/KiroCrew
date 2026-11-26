import { render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import ExecutionsView from './ExecutionsView'

const { cronHistoryAll } = vi.hoisted(() => ({ cronHistoryAll: vi.fn() }))

vi.mock('../api/client', () => ({
  api: {
    crons: vi.fn().mockResolvedValue({ jobs: [{ id: 'j1' }] }),
    cronHistoryAll,
    cronRunDetail: vi.fn(),
  },
}))

// Tailwind's `max-sm:hidden` is a media query that happy-dom does not evaluate, so
// the class on each cell is the contract: the wide columns drop below `sm`, and the
// same facts fold into the Job and Timestamp cells so nothing is lost on a phone.
describe('ExecutionsView on a phone', () => {
  it('drops Duration, Trigger and Summary columns below sm and folds them under the name and time', async () => {
    cronHistoryAll.mockResolvedValue({
      runs: [{
        job_id: 'j1', job_name: 'Job One', run_id: 'r1', started_at: 1_700_000_000_000,
        duration_ms: 125_400, status: 'success', trigger: 'schedule', summary: 'Sent the weekly digest',
      }],
    })
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <ExecutionsView />
      </QueryClientProvider>,
    )
    await screen.findByText('Job One')
    const cells = [...document.querySelectorAll('tbody td')]
    expect(cells).toHaveLength(6)
    for (const i of [3, 4, 5]) expect(cells[i].className).toContain('max-sm:hidden')
    for (const i of [0, 1, 2]) expect(cells[i].className).not.toContain('max-sm:hidden')
    expect([...document.querySelectorAll('thead th')].filter(h => h.className.includes('max-sm:hidden'))).toHaveLength(3)
    expect(screen.getByTestId('execution-meta-compact').textContent).toBe('2m 5s · schedule')
    expect(screen.getByTestId('execution-summary-compact').textContent).toBe('Sent the weekly digest')
  })
})
