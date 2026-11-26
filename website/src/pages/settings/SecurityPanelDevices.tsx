/**
 * Settings -> Security -> Devices: pair a phone and revoke a paired one. A request the
 * phone just made is listed with its code, who asks (the device's own name, not
 * verified, and where it came from) and the time left, for one press of Approve or Deny.
 * The owner can also type a code, look it up and answer; a `?user_code=` link only
 * fills that box and never answers. One of the sections `SecurityPanel.tsx` composes.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Smartphone } from 'lucide-react'
import { api, type DeviceGrant } from '../../api/client'
import { Btn, Card, CardTitle } from '../../components/ui'
import ErrorNotice from '../../components/ErrorNotice'
import { DEVICE_GRANTS_QUERY_KEY, PairPhonePanel } from '../../components/PairPhonePanel'
import { useConfirm } from '../../components/ConfirmDialog'
import { fmtDateTime } from '../../i18n/format'

export { DEVICE_GRANTS_QUERY_KEY }

export function DevicesCard() {
  const { t } = useTranslation()
  const qc = useQueryClient()
  const { confirm, confirmDialog } = useConfirm()
  const grants = useQuery<DeviceGrant[]>({
    queryKey: DEVICE_GRANTS_QUERY_KEY,
    queryFn: api.deviceGrants,
  })
  const revoke = useMutation({
    mutationFn: (id: string) => api.revokeDevice(id),
    onSettled: () => void qc.invalidateQueries({ queryKey: DEVICE_GRANTS_QUERY_KEY }),
  })
  const askRevoke = async (grant: DeviceGrant) => {
    const ok = await confirm({
      title: t('pages.settings.securityPanel.devices.revoke_confirm', { name: grant.app.name }),
      confirmLabel: t('pages.settings.securityPanel.devices.revoke'),
    })
    if (ok) revoke.mutate(grant.id)
  }

  return (
    <div className="space-y-4">
      <Card>
        <CardTitle>
          <Smartphone className="lucide-inline" aria-hidden="true" />
          {t('pages.settings.securityPanel.devices.pair_title')}
        </CardTitle>
        <p className="mt-2 text-sm leading-relaxed text-muted">
          {t('pages.settings.securityPanel.devices.pair_intro')}
        </p>
        <PairPhonePanel />
      </Card>

      <Card>
        <CardTitle>{t('pages.settings.securityPanel.devices.paired_title')}</CardTitle>
        {grants.isError && (
          <ErrorNotice className="mt-3" message={t('pages.settings.securityPanel.devices.list_failed')} />
        )}
        {grants.data?.length === 0 && (
          <p className="mt-2 text-sm text-muted">{t('pages.settings.securityPanel.devices.none')}</p>
        )}
        <ul className="mt-2 divide-y divide-border">
          {(grants.data ?? []).map(grant => (
            <li key={grant.id} className="flex flex-wrap items-center justify-between gap-3 py-2">
              <div className="min-w-0">
                <div className="truncate text-sm font-medium">{grant.app.name}</div>
                <div className="text-xs text-muted">
                  {t('pages.settings.securityPanel.devices.paired_on', {
                    when: fmtDateTime(grant.created_at * 1000),
                  })}
                  {' · '}
                  {grant.last_used_at
                    ? t('pages.settings.securityPanel.devices.last_used', {
                        when: fmtDateTime(grant.last_used_at * 1000),
                        ip: grant.last_ip || t('pages.settings.securityPanel.devices.via_tunnel'),
                      })
                    : t('pages.settings.securityPanel.devices.never_used')}
                </div>
              </div>
              <Btn type="button" disabled={revoke.isPending} onClick={() => void askRevoke(grant)}>
                {t('pages.settings.securityPanel.devices.revoke')}
              </Btn>
            </li>
          ))}
        </ul>
        {revoke.isError && (
          <ErrorNotice className="mt-3" message={t('pages.settings.securityPanel.devices.revoke_failed')} />
        )}
      </Card>
      {confirmDialog}
    </div>
  )
}
