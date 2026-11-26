import { useEffect } from 'react'
import { TerminalTabsView } from '../components/BottomTerminalPanel'
import { closeBottomTerminal, openBottomTerminal, useBottomTerminal } from '../hooks/useBottomTerminal'

/**
 * `/terminal` as a real page, for a phone (`shell/routes.tsx` `TerminalRoute`).
 *
 * The docked panel is the Terminal on desktop. On a phone it has no room beside
 * a chat, so the route hosts the same tabbed view the popout window uses,
 * filling the page: tabs, rename, close and every shell live in the shared
 * store, so a session opened here is the one the dock shows on a wider screen.
 *
 * The dock itself stays closed while this page is up, so two views never hold
 * sockets to one PTY. Unlike the popout window it does not register as a popout:
 * it is the main window. Its "Return" control follows the popout's fallback and
 * leaves for the main dashboard view.
 */
export default function TerminalPage() {
  const { tabs } = useBottomTerminal()
  // `openBottomTerminal` mints the first tab, then the dock is put away again.
  useEffect(() => {
    if (tabs.length === 0) openBottomTerminal()
    closeBottomTerminal()
  }, [tabs.length])
  return (
    <div data-testid="terminal-page" className="flex-1 min-h-0 w-full flex flex-col bg-bg">
      <TerminalTabsView variant="popout" />
    </div>
  )
}
