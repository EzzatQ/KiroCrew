import { afterEach, beforeAll, describe, expect, it } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import SegmentedControl from '../components/SegmentedControl'

const SEGMENTS = [
  { key: 'a', label: 'List' },
  { key: 'b', label: 'Calendar' },
]

beforeAll(() => {
  ;(globalThis as unknown as { ResizeObserver: unknown }).ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
})
afterEach(cleanup)

describe('SegmentedControl tabs mode', () => {
  it('announces a tablist of tabs with aria-selected', () => {
    render(<SegmentedControl segments={SEGMENTS} value="b" onChange={() => {}} ariaLabel="View" collapse={false} tabs />)
    expect(screen.getByRole('tablist', { name: 'View' })).toBeInTheDocument()
    expect(screen.getByRole('tab', { name: 'Calendar' })).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByRole('tab', { name: 'List' })).toHaveAttribute('aria-selected', 'false')
    expect(screen.queryByRole('radio')).toBeNull()
  })

  it('stays a radiogroup by default', () => {
    render(<SegmentedControl segments={SEGMENTS} value="a" onChange={() => {}} ariaLabel="View" collapse={false} />)
    expect(screen.getByRole('radiogroup')).toBeInTheDocument()
    expect(screen.getByRole('radio', { name: 'List' })).toHaveAttribute('aria-checked', 'true')
  })
})
