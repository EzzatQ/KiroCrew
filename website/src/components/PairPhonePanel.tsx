/**
 * The pairing controls: requests waiting for an answer, and a box to type a code. Shared
 * by Settings -> Security -> Devices and the "Use Kiro Crew on your phone" dialog. A
 * request the phone just made is listed with its code, who asks (the device's own name,
 * not verified, and where it came from) and the time left, for one press of Approve or
 * Deny. A `?user_code=` link only fills the box and never answers.
 */
import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  api,
  type DeviceApproval,
  type DeviceRequest,
  type PendingDeviceRequest,
} from '../api/client'
import { Btn, Input } from './ui'
import ErrorNotice from './ErrorNotice'

/** Shared with the Security rail summary: one cached read. */
export const DEVICE_GRANTS_QUERY_KEY = ['device-grants'] as const
const PENDING_DEVICES_QUERY_KEY = ['device-pending'] as const
const PENDING_POLL_MS = 5000

/** Whole seconds left until `expiresAt` (unix seconds), counted down once a second. */
function useSecondsLeft(expiresAt: number): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(id)
  }, [])
  return Math.max(0, Math.ceil(expiresAt - now / 1000))
}

function PendingRow({
  request,
  busy,
  onAnswer,
}: {
  request: PendingDeviceRequest
  busy: boolean
  onAnswer: (code: string, approve: boolean) => void
}) {
  const { t } = useTranslation()
  const left = useSecondsLeft(request.expires_at)
  return (
    <li className="flex flex-wrap items-center justify-between gap-3 py-2">
      <div className="min-w-0">
        <div className="truncate text-sm font-medium">{request.device_name}</div>
        <div className="text-xs text-muted">{t('pages.settings.securityPanel.devices.request_unverified')}</div>
        <div className="mt-1 text-xs text-muted">
          <span className="font-mono">{request.user_code}</span>
          {' · '}
          {t('pages.settings.securityPanel.devices.pending_details', {
            source: request.via_tunnel || !request.source_ip
              ? t('pages.settings.securityPanel.devices.via_tunnel')
              : request.source_ip,
            left,
          })}
        </div>
      </div>
      <div className="flex gap-3">
        <Btn type="button" primary disabled={busy || left === 0} onClick={() => onAnswer(request.user_code, true)}>
          {t('pages.settings.securityPanel.devices.approve')}
        </Btn>
        <Btn type="button" disabled={busy || left === 0} onClick={() => onAnswer(request.user_code, false)}>
          {t('pages.settings.securityPanel.devices.deny')}
        </Btn>
      </div>
    </li>
  )
}

/** `?user_code=` is what the device's verification link carries. */
function initialCode(): string {
  if (typeof window === 'undefined') return ''
  return new URLSearchParams(window.location.search).get('user_code') ?? ''
}

/**
 * The pairing controls: requests waiting for an answer, and a box to type a code.
 * Shared by Settings -> Security -> Devices and the "Use Kiro Crew on your phone"
 * dialog. `hideWhenUnavailable` drops it when the waiting list cannot be read (a
 * teammate session: the owner routes refuse it), so the dialog shows no dead box.
 */
export function PairPhonePanel({
  hideWhenUnavailable = false,
  heading,
}: {
  hideWhenUnavailable?: boolean
  heading?: string
}) {
  const { t } = useTranslation()
  const qc = useQueryClient()
  const [code, setCode] = useState(initialCode)
  const [answered, setAnswered] = useState<DeviceApproval | null>(null)
  const [request, setRequest] = useState<DeviceRequest | null>(null)
  // Polled while it is open: the phone asks seconds after the owner opens it.
  const pending = useQuery<PendingDeviceRequest[]>({
    queryKey: PENDING_DEVICES_QUERY_KEY,
    queryFn: api.pendingDevices,
    refetchInterval: PENDING_POLL_MS,
  })

  const lookup = useMutation({
    mutationFn: () => api.lookupDevice(code.trim()),
    onSuccess: setRequest,
  })
  const answer = useMutation({
    mutationFn: ({ userCode, approve }: { userCode: string; approve: boolean }) =>
      api.approveDevice(userCode.trim(), approve),
    onSuccess: (result, vars) => {
      setAnswered(result)
      // The typed box is cleared only when the typed code was the one answered.
      if (vars.userCode.trim().toUpperCase() === code.trim().toUpperCase()) {
        setRequest(null)
        setCode('')
      }
    },
    // Approved, denied or gone (a 404 means someone else answered): both lists re-read.
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: DEVICE_GRANTS_QUERY_KEY })
      void qc.invalidateQueries({ queryKey: PENDING_DEVICES_QUERY_KEY })
    },
  })
  if (hideWhenUnavailable && pending.isError) return null

  return (
    <>
      {heading && <div className="text-sm font-medium">{heading}</div>}
      {(pending.data?.length ?? 0) > 0 && (
        <div className="mt-3">
          <div className="text-sm font-medium">{t('pages.settings.securityPanel.devices.pending_title')}</div>
          <ul className="divide-y divide-border" aria-label={t('pages.settings.securityPanel.devices.pending_title')}>
            {(pending.data ?? []).map(item => (
              <PendingRow
                key={item.user_code}
                request={item}
                busy={answer.isPending}
                onAnswer={(userCode, approve) => answer.mutate({ userCode, approve })}
              />
            ))}
          </ul>
        </div>
      )}
      {pending.data?.length === 0 && (
        <p className="mt-3 text-sm text-muted">{t('pages.settings.securityPanel.devices.pending_none')}</p>
      )}
      <form
        className="mt-3 flex flex-wrap items-center gap-3"
        onSubmit={event => {
          // Enter in the box looks the code up, like the button.
          event.preventDefault()
          if (code.trim() && !lookup.isPending) lookup.mutate()
        }}
      >
        <label className="sr-only" htmlFor="device-user-code">
          {t('pages.settings.securityPanel.devices.code_label')}
        </label>
        <Input
          id="device-user-code"
          className="font-mono uppercase"
          value={code}
          maxLength={9}
          autoComplete="off"
          onChange={event => {
            // A stale request or answer would read as a fact about the next code typed.
            setAnswered(null)
            setRequest(null)
            lookup.reset()
            setCode(event.target.value)
          }}
        />
        <Btn type="submit" primary disabled={!code.trim() || lookup.isPending}>
          {t('pages.settings.securityPanel.devices.look_up')}
        </Btn>
      </form>
      {request && (
        <div className="mt-3 rounded border border-border p-3 text-sm" role="group" aria-label={t('pages.settings.securityPanel.devices.request_title')}>
          <div className="font-medium">{request.device_name}</div>
          <div className="text-xs text-muted">{t('pages.settings.securityPanel.devices.request_unverified')}</div>
          <div className="mt-2 text-xs text-muted">
            {t('pages.settings.securityPanel.devices.request_details', {
              client: request.client_id,
              source: request.via_tunnel || !request.source_ip
                ? t('pages.settings.securityPanel.devices.via_tunnel')
                : request.source_ip,
              age: request.age,
              left: request.expires_in,
            })}
          </div>
          <div className="mt-3 flex gap-3">
            <Btn type="button" primary disabled={answer.isPending} onClick={() => answer.mutate({ userCode: code, approve: true })}>
              {t('pages.settings.securityPanel.devices.approve')}
            </Btn>
            <Btn type="button" disabled={answer.isPending} onClick={() => answer.mutate({ userCode: code, approve: false })}>
              {t('pages.settings.securityPanel.devices.deny')}
            </Btn>
          </div>
        </div>
      )}
      {answered && (
        <p className="mt-3 text-sm" role="status">
          {t(
            answered.status === 'approved'
              ? 'pages.settings.securityPanel.devices.approved_note'
              : 'pages.settings.securityPanel.devices.denied_note',
            { name: answered.device_name, ip: answered.source_ip || '-' },
          )}
        </p>
      )}
      {(lookup.isError || answer.isError) && (
        <ErrorNotice
          className="mt-3"
          message={t('pages.settings.securityPanel.devices.answer_failed')}
        />
      )}
    </>
  )
}
