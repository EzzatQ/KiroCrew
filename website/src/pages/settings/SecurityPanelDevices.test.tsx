import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { renderWithProviders } from '../../test/helpers'

vi.mock('../../api/client', () => ({
  api: {
    deviceGrants: vi.fn(),
    lookupDevice: vi.fn(),
    approveDevice: vi.fn(),
    revokeDevice: vi.fn(),
    pendingDevices: vi.fn(),
  },
}))

import { api } from '../../api/client'
import { DevicesCard } from './SecurityPanelDevices'

const mobile = api as unknown as Record<string, ReturnType<typeof vi.fn>>
const phone = {
  id: 'grt_abc',
  kind: 'device',
  app: { name: "Alex's iPhone" },
  created_at: 1_700_000_000,
  last_used_at: null,
  last_ip: '',
}

describe('DevicesCard', () => {
  beforeEach(() => mobile.pendingDevices.mockResolvedValue([]))
  afterEach(() => vi.resetAllMocks())

  it('lists paired devices with a revoke action', async () => {
    mobile.deviceGrants.mockResolvedValue([phone])
    mobile.revokeDevice.mockResolvedValue({ deleted: true })
    renderWithProviders(<DevicesCard />)
    expect(await screen.findByText("Alex's iPhone")).toBeInTheDocument()
    expect(screen.getByText(/not used yet/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Revoke' }))
    // The press only asks; nothing is revoked until the confirm names the device.
    expect(await screen.findByText("Revoke Alex's iPhone? It will be signed out right away.")).toBeInTheDocument()
    expect(mobile.revokeDevice).not.toHaveBeenCalled()
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Revoke' }))
    await waitFor(() => expect(mobile.revokeDevice).toHaveBeenCalledWith('grt_abc'))
    // The paired list is read again after the revoke.
    await waitFor(() => expect(mobile.deviceGrants.mock.calls.length).toBeGreaterThan(1))
  })

  it('does not revoke when the confirm is cancelled', async () => {
    mobile.deviceGrants.mockResolvedValue([phone])
    renderWithProviders(<DevicesCard />)
    fireEvent.click(await screen.findByRole('button', { name: 'Revoke' }))
    fireEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Cancel' }))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(mobile.revokeDevice).not.toHaveBeenCalled()
  })

  const waiting = {
    client_id: 'kirocrew-ios',
    device_name: "Alex's iPhone",
    source_ip: '192.168.1.50',
    via_tunnel: false,
    age: 5,
    expires_in: 295,
    expires_at: Math.floor(Date.now() / 1000) + 295,
    user_code: 'BCDF-GHJK',
  }

  it('lists a waiting request with its code and answers it in one press', async () => {
    mobile.deviceGrants.mockResolvedValue([])
    mobile.pendingDevices.mockResolvedValue([waiting])
    mobile.approveDevice.mockResolvedValue({
      status: 'approved',
      client_id: 'kirocrew-ios',
      device_name: "Alex's iPhone",
      source_ip: '192.168.1.50',
    })
    renderWithProviders(<DevicesCard />)
    expect(await screen.findByText('BCDF-GHJK')).toBeInTheDocument()
    expect(screen.getByText(/From 192.168.1.50. Expires in \d+ s/)).toBeInTheDocument()
    expect(mobile.approveDevice).not.toHaveBeenCalled()
    const row = screen.getByText('BCDF-GHJK').closest('li') as HTMLElement
    fireEvent.click(within(row).getByRole('button', { name: 'Approve' }))
    await waitFor(() => expect(mobile.approveDevice).toHaveBeenCalledWith('BCDF-GHJK', true))
    // Both lists are read again after the answer.
    await waitFor(() => expect(mobile.pendingDevices.mock.calls.length).toBeGreaterThan(1))
    await waitFor(() => expect(mobile.deviceGrants.mock.calls.length).toBeGreaterThan(1))
  })

  it('denies a waiting request from the list', async () => {
    mobile.deviceGrants.mockResolvedValue([])
    mobile.pendingDevices.mockResolvedValue([waiting])
    mobile.approveDevice.mockResolvedValue({ status: 'denied', client_id: 'kirocrew-ios', device_name: 'Phone', source_ip: '' })
    renderWithProviders(<DevicesCard />)
    const row = (await screen.findByText('BCDF-GHJK')).closest('li') as HTMLElement
    fireEvent.click(within(row).getByRole('button', { name: 'Deny' }))
    await waitFor(() => expect(mobile.approveDevice).toHaveBeenCalledWith('BCDF-GHJK', false))
  })

  it('counts down the time left and stops offering an expired request', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    try {
      mobile.deviceGrants.mockResolvedValue([])
      mobile.pendingDevices.mockResolvedValue([
        { ...waiting, expires_at: Math.floor(Date.now() / 1000) + 3 },
      ])
      renderWithProviders(<DevicesCard />)
      expect(await screen.findByText(/Expires in [23] s/)).toBeInTheDocument()
      await act(async () => {
        await vi.advanceTimersByTimeAsync(4000)
      })
      expect(screen.getByText(/Expires in 0 s/)).toBeInTheDocument()
      const row = screen.getByText('BCDF-GHJK').closest('li') as HTMLElement
      expect(within(row).getByRole('button', { name: 'Approve' })).toBeDisabled()
    } finally {
      vi.useRealTimers()
    }
  })

  it('says nothing is waiting when the list is empty', async () => {
    mobile.deviceGrants.mockResolvedValue([])
    renderWithProviders(<DevicesCard />)
    expect(await screen.findByText(/No pairing requests are waiting/)).toBeInTheDocument()
  })

  it('fills the box from ?user_code= and does not answer on its own', async () => {
    mobile.deviceGrants.mockResolvedValue([])
    window.history.pushState({}, '', '/settings/security/devices?user_code=BCDF-GHJK')
    try {
      renderWithProviders(<DevicesCard />)
      expect(await screen.findByLabelText('Pairing code')).toHaveValue('BCDF-GHJK')
      await screen.findByText('No paired devices.')
      expect(mobile.lookupDevice).not.toHaveBeenCalled()
      expect(mobile.approveDevice).not.toHaveBeenCalled()
    } finally {
      window.history.pushState({}, '', '/')
    }
  })

  it('looks the code up when Enter is pressed in the box', async () => {
    mobile.deviceGrants.mockResolvedValue([])
    mobile.lookupDevice.mockResolvedValue({ ...waiting })
    renderWithProviders(<DevicesCard />)
    const box = await screen.findByLabelText('Pairing code')
    fireEvent.change(box, { target: { value: 'BCDF-GHJK' } })
    fireEvent.submit(box.closest('form') as HTMLFormElement)
    await waitFor(() => expect(mobile.lookupDevice).toHaveBeenCalledWith('BCDF-GHJK'))
    expect(mobile.approveDevice).not.toHaveBeenCalled()
  })

  const asking = {
    client_id: 'kirocrew-ios',
    device_name: "Alex's iPhone",
    source_ip: '192.168.1.50',
    via_tunnel: false,
    age: 12,
    expires_in: 288,
  }

  it('shows who asks and approves only on an explicit click', async () => {
    mobile.deviceGrants.mockResolvedValue([])
    mobile.lookupDevice.mockResolvedValue(asking)
    mobile.approveDevice.mockResolvedValue({
      status: 'approved',
      client_id: 'kirocrew-ios',
      device_name: "Alex's iPhone",
      source_ip: '192.168.1.50',
    })
    renderWithProviders(<DevicesCard />)
    expect(await screen.findByText('No paired devices.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Look up' })).toBeDisabled()
    expect(screen.queryByRole('button', { name: 'Approve' })).not.toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Pairing code'), { target: { value: 'bcdf-ghjk' } })
    fireEvent.click(screen.getByRole('button', { name: 'Look up' }))
    await waitFor(() => expect(mobile.lookupDevice).toHaveBeenCalledWith('bcdf-ghjk'))
    expect(await screen.findByText("Alex's iPhone")).toBeInTheDocument()
    expect(screen.getByText(/not verified/)).toBeInTheDocument()
    expect(screen.getByText(/from 192.168.1.50/)).toBeInTheDocument()
    // Looking up never answers.
    expect(mobile.approveDevice).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Approve' }))
    await waitFor(() => expect(mobile.approveDevice).toHaveBeenCalledWith('bcdf-ghjk', true))
    expect(await screen.findByRole('status')).toHaveTextContent("Approved Alex's iPhone (from 192.168.1.50)")
  })

  it('denies a looked-up request', async () => {
    mobile.deviceGrants.mockResolvedValue([])
    mobile.lookupDevice.mockResolvedValue({ ...asking, source_ip: '', via_tunnel: true })
    mobile.approveDevice.mockResolvedValue({ status: 'denied', client_id: 'kirocrew-ios', device_name: 'Phone', source_ip: '' })
    renderWithProviders(<DevicesCard />)
    fireEvent.change(await screen.findByLabelText('Pairing code'), { target: { value: 'BCDF-GHJK' } })
    fireEvent.click(screen.getByRole('button', { name: 'Look up' }))
    expect(await screen.findByText(/from a tunnel/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Deny' }))
    await waitFor(() => expect(mobile.approveDevice).toHaveBeenCalledWith('BCDF-GHJK', false))
  })

  it('tells the owner when the code is unknown', async () => {
    mobile.deviceGrants.mockResolvedValue([])
    mobile.lookupDevice.mockRejectedValue(new Error('not found'))
    renderWithProviders(<DevicesCard />)
    fireEvent.change(await screen.findByLabelText('Pairing code'), { target: { value: 'BBBB-BBBB' } })
    fireEvent.click(screen.getByRole('button', { name: 'Look up' }))
    expect(await screen.findByText(/not found or has expired/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Approve' })).not.toBeInTheDocument()
  })
})
