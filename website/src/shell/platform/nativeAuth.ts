import { useEffect, useRef } from 'react'

/**
 * Hand-off to the iOS shell for signing in. The shell puts `kc-native` on
 * <html> and registers a `kirocrewAuth` script message handler; this side only
 * READS the class and posts to the handler. A browser has neither, so every
 * function here is a no-op there and the existing banner flow is untouched.
 */
type AuthHandler = { postMessage: (m: { type: 'signin' }) => void }

export function isNativeShell(): boolean {
  return typeof document !== 'undefined' && document.documentElement.classList.contains('kc-native')
}

function handler(): AuthHandler | null {
  const w = window as unknown as { webkit?: { messageHandlers?: { kirocrewAuth?: AuthHandler } } }
  return w.webkit?.messageHandlers?.kirocrewAuth ?? null
}

/** A manual tap may repeat, but not faster than this (a native sheet takes a moment to open). */
export const NATIVE_SIGNIN_MIN_GAP_MS = 3000
let lastPostAt = 0
let autoPosted = false

/** Ask the shell to open its sign-in. False when not native, no handler, or inside the back-off. */
export function requestNativeSignIn(now: number = Date.now()): boolean {
  if (!isNativeShell()) return false
  const h = handler()
  if (!h) return false
  if (lastPostAt && now - lastPostAt < NATIVE_SIGNIN_MIN_GAP_MS) return false
  lastPostAt = now
  try { h.postMessage({ type: 'signin' }) } catch { return false }
  return true
}

/** Test-only. */
export function __resetNativeSignInForTests(): void {
  lastPostAt = 0
  autoPosted = false
}

/**
 * True when the signed-out page should replace the app: inside the native shell
 * with the gateway having refused this session (401/403, including the 401
 * `stale_session_reauth`; client.ts raises `mc-auth-required` for both). Posts
 * `signin` once per page load; later attempts are the page's button.
 */
export function useNativeSignedOut(authRequired: boolean): boolean {
  const show = isNativeShell() && authRequired
  const posted = useRef(false)
  useEffect(() => {
    if (!show || posted.current || autoPosted) return
    posted.current = true
    autoPosted = true
    requestNativeSignIn()
  }, [show])
  return show
}
