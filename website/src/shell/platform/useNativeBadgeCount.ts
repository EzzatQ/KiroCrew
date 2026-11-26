import { useEffect } from 'react'
import { useAppSelector } from '../../store'
import type { Notification } from '../../types'
import { setNativeBadgeCount } from './electronBridge'

/**
 * Attention-worthy rows only (RFC Phase 3): passive and muted-channel
 * (silenced) rows are excluded, mirroring the backend's unread_count semantics.
 */
export const isUnackedAttention = (n: Notification): boolean => !n.acked && n.priority !== 'passive' && !n.silenced

/**
 * Mirrors the bell's unread count onto the native badge (desktop dock, iOS
 * shell). It lives at the app level, not on the bell, so a header that is not
 * drawn (a phone page that hides it, a popout) cannot freeze the badge. The
 * bridge is read at call time and is a no-op without `window.electronAPI`; the
 * iOS shell injects that object, so nothing here checks for Electron.
 */
export function useNativeBadgeCount(): void {
  const count = useAppSelector(s => s.notifications.items.filter(isUnackedAttention).length)
  useEffect(() => {
    setNativeBadgeCount(count)
  }, [count])
  useEffect(() => () => setNativeBadgeCount(0), [])
}
