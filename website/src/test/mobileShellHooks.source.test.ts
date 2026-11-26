/**
 * What the iOS shell's UI test reads: stable ids on the header, sessions and
 * message menus, and a real 44px box (`mc-touch-min`) on the controls it taps.
 * Source-text assertions, like touchHitArea.test.ts: jsdom evaluates neither
 * media queries nor layout, so the class and id on each control is the contract.
 */
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'

const src = (rel: string) => readFileSync(path.resolve(__dirname, '..', rel), 'utf8')

describe('testids for the phone UI test', () => {
  it.each([
    ['shell/topbar/shellHeader.tsx', 'data-testid="shell-notifications-bell"'],
    ['pages/chat/ChatHeaderMenu.tsx', 'data-testid="session-options"'],
    ['pages/chat-sidebar/SidebarHeader.tsx', 'data-testid="sessions-panel-menu"'],
    ['pages/chat/AssistantMessage.tsx', 'data-testid="message-actions-menu"'],
    ['pages/chat/UserMessage.tsx', 'data-testid="message-actions-menu"'],
  ])('%s carries %s', (file, id) => {
    expect(src(file)).toContain(id)
  })

  it('keeps the existing ids the new ones sit beside', () => {
    expect(src('pages/chat/page/MobileTopBar.tsx')).toContain('data-testid="mobile-topbar-more"')
    expect(src('shell/topbar/shellHeader.tsx')).toContain('data-testid="mobile-topbar-nav-toggle"')
    expect(src('pages/chat/AssistantMessage.tsx')).toContain('data-testid="assistant-more-actions"')
    expect(src('pages/chat/UserMessage.tsx')).toContain('data-testid="user-more-actions"')
  })
})

describe('mc-touch-min on the controls the UI test taps', () => {
  it.each([
    ['shell/topbar/shellHeader.tsx', 2],
    ['pages/chat/page/MobileTopBar.tsx', 1],
    ['pages/chat-sidebar/SidebarHeader.tsx', 3],
    ['pages/chat-sidebar/SessionRow.tsx', 1],
    ['pages/chat-sidebar/folderBlocks.tsx', 2],
    ['components/chat-input/ContextShelf.tsx', 4],
    ['components/notifications/NotificationCard.tsx', 1],
    ['components/QueueStack.tsx', 4],
  ])('%s has at least %i', (file, n) => {
    expect(src(file).split('mc-touch-min ').length - 1).toBeGreaterThanOrEqual(n)
  })

  it('makes the message action cells 44x44 on touch', () => {
    const cls = src('utils/touchActions.ts')
    expect(cls).toContain('[@media(hover:none)]:[&_button]:h-11')
    expect(cls).toContain('[@media(hover:none)]:[&_button]:w-11')
  })
})

describe('text cut-offs on a phone', () => {
  it('chat tables keep a readable column width on a coarse pointer, so they scroll instead of one word per line', () => {
    const t = src('components/markdown/MarkdownTable.tsx')
    expect(t).toContain('[@media(pointer:coarse)]:[&_td]:min-w-[7rem]')
    expect(t).toContain('[@media(pointer:coarse)]:[&_th]:min-w-[7rem]')
  })

  it('the composer placeholder uses the short key on a phone', () => {
    expect(src('components/ChatInput.tsx')).toMatch(/isMobile\s*\?\s*'components\.chatInput\.message_placeholder_crewmate'/)
  })

  it('the bell badge sits inside the 44px bell box on a coarse pointer', () => {
    expect(src('shell/topbar/shellHeader.tsx')).toContain('[@media(pointer:coarse)]:right-0.5')
  })
})

describe('notification sheet on a phone', () => {
  it('paints its own opaque column and drops the blurred scrim', () => {
    const s = src('shell/notifications/notificationSheet.tsx')
    expect(s).toContain("isMobile ? 'w-full bg-bg'")
    expect(s).toMatch(/backdrop-blur-\[2px\] max-md:hidden/)
  })
})

describe('landscape phone', () => {
  it('caps the composer textarea at 35vh on a short landscape screen', () => {
    expect(src('components/ChatInput.tsx')).toContain('[@media(orientation:landscape)_and_(max-height:500px)]:max-h-[35vh]')
  })
})

describe('drawer foot', () => {
  it('caps the desktop-form rail foot on a phone too', () => {
    expect(src('shell/nav/navRail.tsx')).toContain("isMobile ? ' max-h-[40dvh] overflow-y-auto'")
  })
})

describe('Schedule on a phone', () => {
  it('hides the red Delete until armed and arms it from the row menu', () => {
    const s = src('pages/SchedulePage.tsx')
    expect(s).toContain('(!isMobile || confirmDeleteId === j.id || isDeleting(j.id)) && <Btn')
    expect(s).toContain('onArmDelete={isMobile ? () => armDelete(j.id) : undefined}')
  })
})

describe('app-level wiring the iOS shell relies on', () => {
  it('appShell.tsx calls useNativeBadgeCount(), or the iOS badge silently dies', () => {
    const s = src('shell/appShell.tsx')
    expect(s).toContain("import { useNativeBadgeCount } from './platform/useNativeBadgeCount'")
    expect(s).toMatch(/^\s*useNativeBadgeCount\(\)\s*$/m)
  })

  it('App.tsx shows the signed-out page from the native auth hook', () => {
    const s = src('App.tsx')
    expect(s).toContain('useNativeSignedOut(authRequired)')
    expect(s).toContain('{nativeSignedOut && <SignedOutPage />}')
  })

  it('hides the terminal-text session banner inside the shell', () => {
    expect(src('styles/scrollbars-and-touch-hit.css')).toContain('html.kc-native #mc-session-expired { display: none; }')
  })
})

describe('phone composer', () => {
  const c = () => src('components/ChatInput.tsx')

  it('is gated on the phone hook, so the desktop row is the old code', () => {
    expect(c()).toContain('const phoneComposer = usePhoneComposer()')
    expect(c()).toContain('inlineToolbarWhileFitsProp || phoneComposer')
    expect(c()).toContain('touchInput && collapsible && !phoneComposer')
  })

  it('swaps the mic and Send on whether the box holds anything', () => {
    expect(c()).toContain('const phoneHidesMic = phoneComposer && phoneHasContent && !phoneVoiceActive')
    expect(c()).toContain('const phoneHidesSend = phoneComposer && !!onVoiceToggle && !phoneHasContent && !phoneVoiceActive')
    expect(c()).toContain('!typingLocked && !phoneHidesMic')
  })

  it('keeps the held-send and hold-to-talk paths', () => {
    expect(c()).toContain('|| holdSend || optimizing')
    expect(c()).toContain('voiceHoldMode || voiceRecording || transcribeInFlight')
  })

  it('folds the chips and the shelf behind the Options row of the "+" menu', () => {
    expect(c()).toContain("phoneComposer && !phoneChipsOpen ? ' hidden'")
    expect(c()).toContain('(!phoneComposer || phoneChipsOpen) &&')
    expect(c()).toContain('phoneOptionsMenuRow(')
  })

  it('gives "+", mic and Send a 44px box', () => {
    expect(c()).toContain('touchMin={phoneComposer}')
    expect(src('components/chat-input/attach.tsx')).toContain("touchMin ? 'mc-touch-min '")
    expect(src('components/chat-input/VoiceControls.tsx')).toContain("touchMin ? 'mc-touch-min '")
    expect(c()).toContain("phoneComposer ? 'mc-touch-min '")
  })
})
