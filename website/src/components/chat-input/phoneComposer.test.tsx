import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, screen } from '@testing-library/react'

const gate = vi.hoisted(() => ({ narrow: false, touch: false, phone: true }))
vi.mock('../../hooks/useIsMobile', () => ({ useIsMobile: () => gate.narrow }))
vi.mock('../../hooks/useIsTouchDevice', () => ({ useIsTouchDevice: () => gate.touch }))
vi.mock('./phoneComposer', async (orig) => {
  const real = await orig<typeof import('./phoneComposer')>()
  return { ...real, usePhoneComposer: () => (gate.phone ? true : real.usePhoneComposer()) }
})

import { usePhoneChipsOpen, usePhoneComposer } from './phoneComposer'
import { renderWithProviders } from '../../test/helpers'
import ChatInput from '../ChatInput'
import { ComposerVoiceSliceOverride } from '../../chat-core/composer/Composer'

describe('usePhoneComposer gate', () => {
  beforeEach(() => { gate.phone = false })
  it.each([
    [true, true, true],
    [true, false, false],
    [false, true, false],
    [false, false, false],
  ])('narrow=%s touch=%s -> %s', (narrow, touch, want) => {
    gate.narrow = narrow
    gate.touch = touch
    expect(renderHook(() => usePhoneComposer()).result.current).toBe(want)
  })
})

describe('usePhoneChipsOpen', () => {
  it('stays folded until something asks', () => {
    const { result } = renderHook(() => usePhoneChipsOpen(true, false, 0))
    expect(result.current[0]).toBe(false)
  })
  it('unfolds when the trust picker signal bumps (open request)', () => {
    const { result, rerender } = renderHook(({ s }) => usePhoneChipsOpen(true, false, s), { initialProps: { s: 0 } })
    rerender({ s: 1 })
    expect(result.current[0]).toBe(true)
  })
  it('unfolds for forceOpen (trust nudge) and ignores it off a phone', () => {
    expect(renderHook(() => usePhoneChipsOpen(true, true)).result.current[0]).toBe(true)
    expect(renderHook(() => usePhoneChipsOpen(false, true, 0)).result.current[0]).toBe(false)
  })
  it('the user can fold it again after a signal', () => {
    const { result, rerender } = renderHook(({ s }) => usePhoneChipsOpen(true, false, s), { initialProps: { s: 0 } })
    rerender({ s: 1 })
    act(() => result.current[1]())
    expect(result.current[0]).toBe(false)
    rerender({ s: 1 })
    expect(result.current[0]).toBe(false)
  })
})

describe('phone composer mic <-> send swap', () => {
  beforeEach(() => { gate.phone = true })
  const voice = { onVoiceToggle: vi.fn(), onVoiceCancel: vi.fn(), onVoicePrewarm: vi.fn() }
  const props = { onChange: vi.fn(), onSend: vi.fn() }
  const draw = (value: string) => renderWithProviders(<ComposerVoiceSliceOverride inputProps={voice}><ChatInput {...props} value={value} /></ComposerVoiceSliceOverride>)
  it('empty box: mic, no Send', () => {
    draw("")
    expect(screen.queryByRole('button', { name: /^send$/i })).toBeNull()
    expect(screen.getByTestId('composer-phone-chips')).toBeInTheDocument()
    expect(document.querySelector('[aria-label*="oice" i], [aria-label*="ictat" i], [aria-label*="mic" i]')).not.toBeNull()
  })
  it('text in the box: Send, no mic', () => {
    draw("hello")
    expect(screen.getByRole('button', { name: /^send$/i })).toBeInTheDocument()
    expect(document.querySelector('[aria-label*="oice" i], [aria-label*="ictat" i], [aria-label*="mic" i]')).toBeNull()
  })
})
