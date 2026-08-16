/**
 * Mobile conversation home: the desktop 'conversation' column embedded whole,
 * with no extra mobile header. The column (ui-conversation's ConversationRoot —
 * message flow, tool cards, approval/question takeovers, plan/goal/model seats,
 * composer) already renders its own hero title/workspace row; the mobile frame
 * floats a small drawer button over it instead of duplicating that chrome.
 * The column is rendered through the renderer's declared-slot outlet: it is
 * DECLARED by the desktop frame, so the mobile frame cannot claim it as a
 * child — the outlet renders any declared slot without ownership. Narrow
 * screen adaptation stays in this package's CSS, scoped under
 * [data-mobile-shell].
 */
import type { SessionId, SessionListState } from '@deepseek-ai/dsh-client-runtime/client'
import type { SnapshotSelectorHook } from '@deepseek-ai/dsh-client-ui-slots'
import { DeclaredSlotOutlet } from '@deepseek-ai/dsh-client-web-react'
import css from './ConversationPage.module.css'

/** Props: the open session and the sessions hook. */
export interface ConversationPageProps {
  sessionId: SessionId
  useSessions: SnapshotSelectorHook<SessionListState>
}

/** The mobile conversation home (see module doc). */
export function ConversationPage({ sessionId, useSessions }: ConversationPageProps) {
  // The hook reference is kept for the component contract; the embedded column
  // itself owns session rendering. Passing it keeps future narrow-screen
  // adapters in this page able to read the session without prop drilling.
  void sessionId
  void useSessions
  return (
    <div className={css.page} data-mobile-conversation>
      <div className={css.column}>
        <DeclaredSlotOutlet slotKey="conversation" ownerProps={{}} />
      </div>
    </div>
  )
}

