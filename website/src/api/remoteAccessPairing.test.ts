import { describe, expect, it, vi } from 'vitest'
import { createRemoteAccessEndpoints } from './client/remoteAccess'
import type { ClientTransport } from './client/transport'

function endpoints(body: unknown) {
  const response = { ok: true, json: async () => body } as Response
  const post = vi.fn(async () => response)
  const get = vi.fn(async () => response)
  const transport = {
    get,
    post,
    put: vi.fn(),
    del: vi.fn(),
    j: (r: Response) => r.json(),
  } as unknown as ClientTransport
  return { api: createRemoteAccessEndpoints(transport).mobileAccess, get, post }
}

describe('pairing endpoints', () => {
  it('asks for a pairing link only when told to', async () => {
    const { api, post } = endpoints({ url: 'u', expires_in: 1 })
    await api.mobileLoginLink('dashboard:ui')
    await api.mobileLoginLink('dashboard:ui', true)
    expect(post).toHaveBeenNthCalledWith(1, '/api/auth/mobile-link', undefined, 'dashboard:ui')
    expect(post).toHaveBeenNthCalledWith(2, '/api/auth/mobile-link', { pair: true }, 'dashboard:ui')
  })

  it('lists the waiting pairing requests without a code', async () => {
    const { api, get } = endpoints({ data: [{ user_code: 'BCDF-GHJK' }] })
    expect(await api.pendingDevices()).toEqual([{ user_code: 'BCDF-GHJK' }])
    expect(get).toHaveBeenCalledWith('/v1/crew/owner/device-approvals')
  })
})
