import { useEffect, useRef, useState } from 'react'
import { SlidersHorizontal } from 'lucide-react'
import { useIsMobile } from '../../hooks/useIsMobile'
import { useIsTouchDevice } from '../../hooks/useIsTouchDevice'
import { i18nT } from '../../i18n/t'

/**
 * The phone composer: `[+] text [mic <-> send]` on one line. Narrow viewport AND
 * a touch pointer only, so a narrow desktop window and a tablet keep the desktop
 * row. The goal, trust, Conductor and AI chips and the agent / model shelf stay
 * mounted but folded away; the "+" menu's Options row unfolds them.
 */
export function usePhoneComposer(): boolean {
  const narrow = useIsMobile()
  const touch = useIsTouchDevice()
  return narrow && touch
}

/** Folded state of the chip rows. `forceOpen` unfolds them when something else
 *  (a slash command, the trust nudge) needs a control that lives in the row.
 *  `openSignal` is the trust picker's counter: every bump unfolds the row, so
 *  the picker it asks to open is mounted. */
export function usePhoneChipsOpen(phone: boolean, forceOpen: boolean, openSignal = 0): [boolean, () => void] {
  const [open, setOpen] = useState(false)
  const lastSignal = useRef(openSignal)
  useEffect(() => {
    const bumped = openSignal !== lastSignal.current
    lastSignal.current = openSignal
    if (phone && (forceOpen || bumped)) setOpen(true)
  }, [phone, forceOpen, openSignal])
  return [phone && open, () => setOpen(o => !o)]
}

/** The "+" menu row that unfolds or folds the chip rows. */
export function phoneOptionsMenuRow(open: boolean, onToggle: () => void) {
  return (
    <button
      type="button"
      data-testid="composer-phone-options-row"
      aria-expanded={open}
      onClick={onToggle}
      className="mc-touch-min w-full flex items-center gap-2.5 px-2 py-1.5 rounded-lg bg-transparent hover:bg-bg-hover transition-colors cursor-pointer text-left"
    >
      <SlidersHorizontal size={14} className="w-4 shrink-0 text-muted lucide-inline" />
      <div className="min-w-0">
        <div className="text-[12px] font-medium text-text">{open ? i18nT('components.chatInput.phone_options_hide') : i18nT('components.chatInput.phone_options')}</div>
        <div className="text-[11px] text-muted leading-snug">{i18nT('components.chatInput.phone_options_desc')}</div>
      </div>
    </button>
  )
}
