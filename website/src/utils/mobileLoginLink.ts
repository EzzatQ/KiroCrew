import { api } from '../api/client'
import { parseErrorCode } from './errorReport'

/** Machine-readable code from a mint error's JSON body. */
export const linkErrorCode = (error: unknown): string | undefined =>
  typeof error === 'object' && error !== null && 'body' in error
    ? parseErrorCode(typeof error.body === 'string' ? error.body : undefined)
    : undefined

/**
 * Mint a sign-in link with pair intent: the phone that opens it signs in AND may approve
 * its own pairing request. Only the host owner may ask for it; any other session gets the
 * plain sign-in link. Shared by the phone dialog and Settings > Security.
 */
export async function mintMobileLoginLink(sessionKey?: string) {
  try {
    return await api.mobileLoginLink(sessionKey, true)
  } catch (error) {
    if (linkErrorCode(error) !== 'owner_only') throw error
    return api.mobileLoginLink(sessionKey)
  }
}
