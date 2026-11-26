import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { __resetNativeSignInForTests, isNativeShell, requestNativeSignIn, useNativeSignedOut } from './nativeAuth'

const post = vi.fn()

function setBridge(on: boolean) {
  document.documentElement.classList.toggle('kc-native', on)
  ;(window as unknown as { webkit?: unknown }).webkit = on ? { messageHandlers: { kirocrewAuth: { postMessage: post } } } : undefined
}

function Probe({ auth }: { auth: boolean }) {
  const show = useNativeSignedOut(auth)
  return <div data-testid="probe">{String(show)}</div>
}

beforeEach(() => { post.mockClear(); __resetNativeSignInForTests() })
afterEach(() => setBridge(false))

describe('native sign-in hand-off', () => {
  it('does nothing in a browser: no class, no postMessage, no page', () => {
    setBridge(false)
    expect(isNativeShell()).toBe(false)
    render(<Probe auth />)
    expect(screen.getByTestId('probe').textContent).toBe('false')
    expect(requestNativeSignIn()).toBe(false)
    expect(post).not.toHaveBeenCalled()
  })

  it('posts signin once per load and shows the page while auth is refused', () => {
    setBridge(true)
    const { rerender } = render(<Probe auth={false} />)
    expect(post).not.toHaveBeenCalled()
    rerender(<Probe auth />)
    rerender(<Probe auth={false} />)
    rerender(<Probe auth />)
    expect(screen.getByTestId('probe').textContent).toBe('true')
    expect(post).toHaveBeenCalledTimes(1)
    expect(post).toHaveBeenCalledWith({ type: 'signin' })
  })

  it('posts once across two separate mounts (module guard)', () => {
    setBridge(true)
    vi.useFakeTimers({ toFake: ['Date'] })
    try {
      const a = render(<Probe auth />)
      a.unmount()
      vi.setSystemTime(Date.now() + 60_000) // past the tap back-off, so only the guard can stop a repost
      render(<Probe auth />)
      expect(post).toHaveBeenCalledTimes(1)
    } finally { vi.useRealTimers() }
  })

  it('backs off a repeated tap', () => {
    setBridge(true)
    expect(requestNativeSignIn(1000)).toBe(true)
    expect(requestNativeSignIn(1500)).toBe(false)
    expect(requestNativeSignIn(5000)).toBe(true)
    expect(post).toHaveBeenCalledTimes(2)
  })
})

describe('SignedOutPage', () => {
  it('has no terminal text and its button asks the shell', async () => {
    setBridge(true)
    const { SignedOutPage } = await import('../SignedOutPage')
    render(<SignedOutPage />)
    expect(document.body.textContent).not.toMatch(/kirocrew token|terminal|gateway/i)
    fireEvent.click(screen.getByTestId('signed-out-signin'))
    expect(post).toHaveBeenCalledTimes(1)
  })

  it('moves focus to Sign in and makes the app behind inert until it goes', async () => {
    setBridge(true)
    const { SignedOutPage } = await import('../SignedOutPage')
    const app = document.createElement('div')
    document.body.appendChild(app)
    const { unmount } = render(<SignedOutPage />)
    expect(document.activeElement).toBe(screen.getByTestId('signed-out-signin'))
    expect(app.hasAttribute('inert')).toBe(true)
    expect(screen.getByTestId('signed-out-page').closest('[inert]')).toBeNull()
    expect(document.querySelector('h1')).toBeNull()
    unmount()
    expect(app.hasAttribute('inert')).toBe(false)
    app.remove()
  })
})
