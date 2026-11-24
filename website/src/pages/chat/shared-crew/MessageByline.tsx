/** The sender of a user message in a shared session, from the server's
 *  `meta.author` stamp. The viewer's own messages carry no label and keep the
 *  filled bubble; a message anyone else wrote, the session creator included, is
 *  outlined (`OtherSenderBubble`), drawn on the start side with the agent's
 *  replies (UserMessage), and named once per run of that person's messages, so
 *  a filled message on the end side is always the reader's own. Until the
 *  viewer read answers nobody stands in for the viewer: every stamped message
 *  is named, the reader's own included (`bylineSelfId`). Bylines follow the
 *  same mode gate as the session list: a
 *  personal Crew, one that cannot attribute, or one whose mode is not known yet
 *  shows none. A bubble is stricter: while the mode is not known a stamped
 *  message is drawn apart, unnamed, once the viewer is known not to be its
 *  sender. A message an app sent is the one exception: it always names the
 *  app, by its display name (`AppSenderByline`). */
import { useContext, useSyncExternalStore, type ReactNode } from 'react'
import { ReactReduxContext } from 'react-redux'
import { useQuery } from '@tanstack/react-query'
import { api } from '../../../api/client'
import { appDisplayName } from '../../../components/appstore/appManifest'
import { appSender, bylineFor, bylineSelfId, messageAuthor, principalName } from '../../../api/sharedCrewUi'
import { useSharedCrewViewer, useTeamAttributionState } from '../../../hooks/sharedCrew/useSharedCrew'
import type { PublicPrincipal } from '../../../api/sharedCrew'
import { parseSessionSeed, seedSender, type SeedRow, type SeedSender } from '../../../lib/crewSeed'
import { readRelay } from '../sessionRelay'
import { i18nT } from '../../../i18n/t'

const noSubscribe = () => () => {}

function SenderLine({ name }: { name: string }) {
  return (
    <div className="text-[12px] leading-5 text-muted mb-0.5 px-1 truncate max-w-full" data-testid="message-byline">
      {name}
    </div>
  )
}

/** Who a stamped message is drawn as. `sender` is the person it belongs to
 *  when that is not the reader, or `null` when it is the reader's own or the
 *  Crew is known not to attribute. `named` is whether the Crew is known to
 *  attribute. While that is not known yet (`useTeamAttributionState` is
 *  `null`) the viewer rule still decides `sender` once the viewer is known, so
 *  a teammate's message is drawn apart rather than as the reader's own, and no
 *  name shows until the Crew is known to attribute. With neither known nothing
 *  is drawn apart: a personal Crew stamps its operator's sends too, and they
 *  must not be drawn as someone else's while (or because) both reads have no
 *  answer.
 *  shortcut: in that both-unknown window a teammate's message is drawn as the
 *  reader's own; closing it needs the viewer known before the first paint. */
function otherSender(author: PublicPrincipal, team: boolean | null, viewer: PublicPrincipal | null | undefined): { sender: PublicPrincipal | null; named: boolean } {
  const selfId = bylineSelfId(viewer)
  const decided = team === true || (team === null && selfId !== '')
  return { sender: decided ? bylineFor(author, selfId) : null, named: team === true }
}

function useOtherSender(author: PublicPrincipal): { sender: PublicPrincipal | null; named: boolean } {
  const team = useTeamAttributionState()
  const viewer = useSharedCrewViewer()
  return otherSender(author, team, viewer.data)
}

function AuthoredBy({ author }: { author: PublicPrincipal }) {
  const { sender, named } = useOtherSender(author)
  if (!sender || !named) return null
  return <SenderLine name={principalName(sender) || i18nT('sharedCrew.unattributed')} />
}

/** The installed app's display name for *id*, or *id* until the app list arrives.
 *  Reads the shared `['apps']` query, and only for a row an app sent. A failed
 *  read leaves the id; the composer dock reports that failure once per chat
 *  (`useSessionControls` reads the same query), so a row repeats nothing. */
function useAppName(id: string): string {
  const { data: apps } = useQuery({
    queryKey: ['apps'],
    queryFn: () => api.listApps(),
    enabled: !!id,
    staleTime: 60_000,
  })
  const app = id ? (apps ?? []).find(a => a.name === id) : undefined
  return (app && appDisplayName(app)) || id
}

function AppSenderLine({ id }: { id: string }) {
  const name = useAppName(id)
  return (
    <div className="text-[12px] leading-5 text-muted mb-0.5 pr-1 truncate max-w-full" data-testid="message-app-sender">
      {name ? i18nT('components.mcpApp.from_app', { app: name }) : i18nT('sharedCrew.sent_by_an_app')}
    </div>
  )
}

/** An app's send is labelled in every Crew mode and on every branch of the user
 *  row, a steered answer included: an app holding a session grant writes into the
 *  owner's own chats, so without the label its message reads as the owner's own
 *  typing. Draws nothing for a row no app sent. */
export function AppSenderByline({ meta }: { meta?: Record<string, unknown> }) {
  const app = appSender(meta)
  return app ? <AppSenderLine id={app.name} /> : null
}

/** `continuesRun`: the message above is the same person's
 *  (`continuesAuthorRun`), so the name is said once per run of messages. An
 *  app's label is not part of a run: it shows on every row an app sent. */
export function MessageByline({ meta, continuesRun = false }: { meta?: Record<string, unknown>; slotKey?: string; continuesRun?: boolean }) {
  if (appSender(meta)) return <AppSenderByline meta={meta} />
  const author = messageAuthor(meta)
  if (!author || continuesRun) return null
  return <AuthoredBy author={author} />
}

function SpeakerHeadingText({ text }: { text: string }) {
  return <h2 className="sr-only">{text}</h2>
}

function AuthorSpeakerHeading({ author }: { author: PublicPrincipal }) {
  const { sender } = useOtherSender(author)
  const text = sender
    ? principalName(sender) || i18nT('sharedCrew.unattributed')
    : i18nT('pages.chat.userMessage.speaker_heading')
  return <SpeakerHeadingText text={text} />
}

function AppSpeakerHeading({ id }: { id: string }) {
  const name = useAppName(id)
  return <SpeakerHeadingText text={name || i18nT('sharedCrew.sent_by_an_app')} />
}

/** The offscreen heading that opens a user-role message, naming who is
 *  speaking. It follows the byline's rule, so a screen reader hears the same
 *  speaker the visible byline names: the app for a row an app sent, the
 *  teammate for a message someone else wrote, and "You" for the viewer's own. */
export function SpeakerHeading({ meta, relayedFrom }: {
  meta?: Record<string, unknown>
  slotKey?: string
  /** The sender `UserMessage` shows above a message another session delivered
   *  (its "From …" line); that row names that sender, never "You". */
  relayedFrom?: string
}) {
  const app = appSender(meta)
  if (app) return <AppSpeakerHeading id={app.name} />
  if (relayedFrom) return <SpeakerHeadingText text={relayedFrom} />
  const author = messageAuthor(meta)
  if (!author) return <SpeakerHeadingText text={i18nT('pages.chat.userMessage.speaker_heading')} />
  return <AuthorSpeakerHeading author={author} />
}

/** The speaker and ownership `SpeakerHeading` resolves for a user-role row,
 *  for both the live-region wording and own-send detection. The same rules and
 *  reads as the heading keep the offscreen copy aligned with what H navigation
 *  lands on: an app, a relayed session, a teammate, or "You" for the viewer's
 *  own row. */
export function useUserRowSpeaker(
  meta: Record<string, unknown> | undefined,
  slotKey?: string,
  content?: string,
  sessions?: ReadonlyMap<string, string>,
): { speaker: string; own: boolean } {
  const app = appSender(meta)
  const appName = useAppName(app?.name ?? '')
  const author = messageAuthor(meta)
  const team = useTeamAttributionState()
  const viewer = useSharedCrewViewer(!!author)
  // A message another session delivered uses the same relayedFrom value as
  // SpeakerHeading: the linked session title when the host can open it, then
  // the sender role from the seed or relay record.
  const relay = readRelay(meta)
  const seed = content === undefined ? null : parseSessionSeed(content, meta)
  const seedFrom = useSeedSender(relay?.senderKey ?? seed?.sender, slotKey)
  const senderTitle = relay && sessions ? sessions.get(relay.senderKey) : undefined
  const relayedFrom = senderTitle || seedFrom
  if (app) return { speaker: appName || i18nT('sharedCrew.sent_by_an_app'), own: false }
  if ((relay || seed) && relayedFrom) return { speaker: relayedFrom, own: false }
  const sender = author ? otherSender(author, team, viewer.data).sender : null
  if (sender) return { speaker: principalName(sender) || i18nT('sharedCrew.unattributed'), own: false }
  return { speaker: i18nT('pages.chat.userMessage.speaker_heading'), own: true }
}

/**
 * Who a delivered message is from, by role (`seedSenderKey`), SUBSCRIBED to the
 * store when one is mounted, so a bubble drawn before the slots frame arrives is
 * relabelled when it does. Without a store the label is generic.
 */
export function useSeedSender(sender: string | undefined, slotKey: string | undefined): string {
  const redux = useContext(ReactReduxContext)
  const subscribe = redux ? redux.store.subscribe : noSubscribe
  const role = useSyncExternalStore<SeedSender | ''>(subscribe, () => {
    if (!sender) return ''
    const rows = ((redux?.store.getState() as { dashboard?: { slots?: SeedRow[] } } | undefined)?.dashboard?.slots) ?? []
    return seedSender(rows, sender, slotKey)
  })
  if (role === 'conductor') return i18nT('pages.chat.userMessage.seed_from_conductor')
  if (role === 'worker') return i18nT('pages.chat.userMessage.seed_from_worker')
  return role ? i18nT('pages.chat.userMessage.seed_from_session') : ''
}

function OtherSenderTone({ author, children }: { author: PublicPrincipal; children: (other: boolean) => ReactNode }) {
  return <>{children(useOtherSender(author).sender !== null)}</>
}

/** Hands `children` whether this message is someone else's, by the byline's
 *  own rule, so the bubble that is named is the bubble drawn apart. A message
 *  with no author stamp runs no Shared Crew query. */
export function OtherSenderBubble({ meta, children }: { meta?: Record<string, unknown>; slotKey?: string; children: (other: boolean) => ReactNode }) {
  const author = messageAuthor(meta)
  if (!author) return <>{children(false)}</>
  return <OtherSenderTone author={author}>{children}</OtherSenderTone>
}
