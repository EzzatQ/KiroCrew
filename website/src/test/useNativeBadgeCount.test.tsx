// The native badge (desktop dock, iOS shell) follows the bell's unread count from
// an app-level hook, so it keeps updating when no header is drawn.
import { act, renderHook } from '@testing-library/react'
import { Provider } from 'react-redux'
import type { ReactNode } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { useNativeBadgeCount } from '../shell/platform/useNativeBadgeCount'
import { addNotification, ackNotificationByTs } from '../store/notificationsSlice'
import type { Notification } from '../types'
import { createTestStore } from './helpers'

const note = (ts: string, extra: Partial<Notification> = {}): Notification => ({
  ts, title: ts, body: '', ...extra,
} as Notification)

function setup() {
  const store = createTestStore()
  const setBadgeCount = vi.fn()
  ;(window as Window & { electronAPI?: unknown }).electronAPI = { setBadgeCount }
  const wrapper = ({ children }: { children: ReactNode }) => <Provider store={store}>{children}</Provider>
  const hook = renderHook(() => useNativeBadgeCount(), { wrapper })
  return { store, setBadgeCount, ...hook }
}

describe('useNativeBadgeCount', () => {
  afterEach(() => { delete (window as Window & { electronAPI?: unknown }).electronAPI })

  it('sends the unread attention count, once per change, without any header mounted', () => {
    const { store, setBadgeCount } = setup()
    expect(setBadgeCount).toHaveBeenLastCalledWith(0)
    act(() => { store.dispatch(addNotification(note('1'))) })
    act(() => { store.dispatch(addNotification(note('2'))) })
    expect(setBadgeCount).toHaveBeenLastCalledWith(2)
    expect(setBadgeCount.mock.calls.map(c => c[0])).toEqual([0, 1, 2])
  })

  it('skips passive and silenced rows and resets to 0 when the last one is acked', () => {
    const { store, setBadgeCount } = setup()
    act(() => {
      store.dispatch(addNotification(note('p', { priority: 'passive' })))
      store.dispatch(addNotification(note('s', { silenced: true })))
      store.dispatch(addNotification(note('a')))
    })
    expect(setBadgeCount).toHaveBeenLastCalledWith(1)
    act(() => { store.dispatch(ackNotificationByTs('a')) })
    expect(setBadgeCount).toHaveBeenLastCalledWith(0)
  })

  it('resets the badge to 0 on unmount, and is a no-op without a bridge', () => {
    const { store, setBadgeCount, unmount } = setup()
    act(() => { store.dispatch(addNotification(note('1'))) })
    unmount()
    expect(setBadgeCount).toHaveBeenLastCalledWith(0)
    delete (window as Window & { electronAPI?: unknown }).electronAPI
    expect(() => renderHook(() => useNativeBadgeCount(), { wrapper: ({ children }: { children: ReactNode }) => <Provider store={store}>{children}</Provider> })).not.toThrow()
  })
})
