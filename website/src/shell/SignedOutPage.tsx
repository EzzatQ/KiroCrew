import { useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { requestNativeSignIn } from './platform/nativeAuth'

/**
 * What the iOS shell shows when the gateway refuses this device's session. No
 * terminal text and no offline banner: the only action is the shell's own sign-in.
 */
export function SignedOutPage() {
  const { t } = useTranslation()
  const page = useRef<HTMLDivElement>(null)
  const button = useRef<HTMLButtonElement>(null)
  useEffect(() => {
    button.current?.focus()
    // Screen readers must not reach the app this page covers: mark every
    // sibling on the way up to <body> inert, and put it back on unmount.
    const marked: Element[] = []
    for (let node: Element | null = page.current; node && node !== document.body; node = node.parentElement) {
      for (const sib of Array.from(node.parentElement?.children ?? [])) {
        if (sib !== node && !sib.hasAttribute('inert')) { sib.setAttribute('inert', ''); marked.push(sib) }
      }
    }
    return () => { for (const el of marked) el.removeAttribute('inert') }
  }, [])
  return (
    <div ref={page} data-testid="signed-out-page" role="alert" className="fixed inset-0 z-[2000] flex flex-col items-center justify-center gap-4 bg-bg px-8 text-center">
      <h2 className="text-[18px] font-semibold text-text">{t('app.signed_out_title')}</h2>
      <p className="text-[14px] text-muted">{t('app.signed_out_body')}</p>
      <button
        ref={button}
        type="button"
        data-testid="signed-out-signin"
        onClick={() => { requestNativeSignIn() }}
        className="mc-touch-min primary rounded-full bg-accent px-6 text-[15px] font-medium text-accent-fg border-none cursor-pointer"
      >
        {t('app.signed_out_signin')}
      </button>
    </div>
  )
}
