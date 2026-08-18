/**
 * Mobile frame: registered into the mobile 'mobile-frame' slot — the mobile
 * shell's render-tree root (the desktop shell renders 'root'). Composes the
 * ChatGPT-style mobile layout: the conversation home fills the viewport (the
 * desktop 'conversation' column embedded through the renderer's declared-slot
 * outlet, wrapped in a menu/title/new-chat top bar), the session list lives in
 * a left drawer (opened via the menu button or a left-edge rightward swipe),
 * and the plan/goal/settings pages push over the home. Pure component: live
 * data arrives through the standard useSessions hook and the injected face;
 * nothing here reads ctx.
 *
 * New-chat degradation: creating a session is desktop-only machinery — the
 * outward ISessions face (what `ctx.sessions` exposes) has no create method
 * (SessionRuntime.create is off the interface), and the desktop New Session
 * flow routes through the workspaces service, which the mobile shell does not
 * wire. The ✚ button therefore opens the session list instead of minting a
 * blank session.
 */
import { useEffect, useRef, useState } from 'react'
import type { ReactNode, TouchEvent as ReactTouchEvent } from 'react'
import type { SessionId, SessionListState } from '@deepseek-ai/dsh-client-runtime/client'
import type { WorkspaceId } from '@deepseek-ai/dsh-api-remotes/client'
import type { PropsRuntime, SnapshotSelectorHook } from '@deepseek-ai/dsh-client-ui-slots'
import type { MobileFrameInjected } from '../app-shell.ts'
import { SessionListPage } from './pages/SessionListPage.tsx'
import { ConversationPage } from './pages/ConversationPage.tsx'
import { GoalPage } from './pages/GoalPage.tsx'
import { PlanPage } from './pages/PlanPage.tsx'
import { SettingsPage } from './pages/SettingsPage.tsx'
import css from './MobileFrame.module.css'

/** The useSessions standard hook narrowed to the session list snapshot. */
export type UseSessions = SnapshotSelectorHook<SessionListState>

/** Full composed props: root-scope standard kit + the injected business face. */
export type MobileFrameProps = PropsRuntime<'mobile-frame'> & MobileFrameInjected

/** Pushed pages reachable from the drawer footer; 'conversation' is the home. */
type Page = 'conversation' | 'plan' | 'goal' | 'settings'

/** One browser-history state slot owned by the mobile frame. */
interface FrameSnapshot {
  page: Page
  drawerOpen: boolean
}

const PAGES: readonly Page[] = ['conversation', 'plan', 'goal', 'settings']

/** The drawer footer: only Settings is top-level; plan/goal are explained and opened from Settings. */
const DRAWER_PAGES: ReadonlyArray<{ page: 'settings'; label: string }> = [
  { page: 'settings', label: '设置' },
]

/** Home snapshot factory; a fresh object per call so React never bails on identity. */
function homeSnapshot(): FrameSnapshot {
  return { page: 'conversation', drawerOpen: false }
}

/** Accept only history states this frame wrote; anything else falls back home. */
function readFrameSnapshot(value: unknown): FrameSnapshot | undefined {
  if (value === null || typeof value !== 'object') return undefined
  const { page, drawerOpen } = value as { page?: unknown; drawerOpen?: unknown }
  if (page === undefined || !PAGES.includes(page as Page)) return undefined
  return { page: page as Page, drawerOpen: drawerOpen === true }
}

function sameSnapshot(a: FrameSnapshot, b: FrameSnapshot): boolean {
  return a.page === b.page && a.drawerOpen === b.drawerOpen
}

/** One pending/terminal session event forwarded to the system notification bar. */
interface Notice {
  sessionId?: SessionId
  title: string
  body: string
}

const PENDING_NOTICE: Readonly<Record<string, { label: string }>> = {
  approval: { label: '需要审批' },
  question: { label: '需要回答' },
  'plan-review': { label: '计划待审' },
}

/** Native bridge injected by the Flutter shell (`DshNotify` JavaScript channel). */
declare global {
  interface Window {
    DshNotify?: { postMessage(message: string): void }
    /** Flutter shell bridge: openSettings / refresh. */
    DshShell?: { postMessage(message: string): void }
  }
}

/**
 * Notifications live in the OS notification bar, never as in-app banners.
 * Android WebView goes through `DshNotify`; other browsers fall back to the
 * Web Notification API when permission was already granted.
 */
function emitSystemNotification(notice: Notice): void {
  const payload = JSON.stringify({
    title: notice.title,
    body: notice.body,
    sessionId: notice.sessionId,
  })
  const bridge = window.DshNotify
  if (bridge !== undefined) {
    try {
      bridge.postMessage(payload)
      return
    } catch {
      // Fall through to the browser fallback if the bridge is broken.
    }
  }
  try {
    if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
      new Notification(notice.title, { body: notice.body })
    }
  } catch {
    // Notification permission is denied or WebKit does not support it.
  }
}

/** Open the drawer from a rightward swipe STARTING IN THE MIDDLE BAND of the
 * screen (25%–75% width). The system back gesture owns the left edge, so the
 * gesture deliberately ignores the outer edges. */
function isMiddleRightSwipe(
  startX: number, startY: number, endX: number, endY: number,
): boolean {
  const width = globalThis.innerWidth
  const middleStart = width * 0.25
  const middleEnd = width * 0.75
  const dx = endX - startX
  const dy = endY - startY
  return startX >= middleStart && startX <= middleEnd && dx > 56 && Math.abs(dy) < dx * 0.7
}

/** The mobile frame (see module doc). */
export function MobileFrame({ useSessions, openSession, projection, goal, workspaces }: MobileFrameProps) {
  const [frame, setFrame] = useState<FrameSnapshot>(() => readFrameSnapshot(history.state) ?? homeSnapshot())
  const { page, drawerOpen } = frame
  const current = useSessions(state => state.current)
  const sessionsState = useSessions(s => s)
  const noticedKeys = useRef(new Set<string>())
  const noticesInitialized = useRef(false)
  // Swipe origin for the middle-band drawer gesture (left/right screen edges are left to the OS).
  const swipeStart = useRef<{ x: number; y: number } | null>(null)

  const pushNotice = (notice: Notice): void => {
    emitSystemNotification(notice)
  }

  // Watch session summary transitions for approval/questions and completion,
  // plus per-session job status transitions. The first snapshot records
  // terminal states silently (they are history), but still surfaces anything
  // currently waiting for the user.
  useEffect(() => {
    const nextKeys = new Set<string>()
    for (const id of sessionsState.ids) {
      const session = sessionsState.byId[id]
      if (session === undefined) continue
      const title = session.displayTitle

      if (session.pendingInteraction !== undefined) {
        const pending = PENDING_NOTICE[session.pendingInteraction]
        const key = `${id}:${session.pendingInteraction}`
        nextKeys.add(key)
        if (pending !== undefined && !noticedKeys.current.has(key)) {
          pushNotice({ sessionId: id, title, body: pending.label })
        }
      }

      const doneKey = `${id}:completed`
      if (session.completed === true) {
        nextKeys.add(doneKey)
        if (!noticedKeys.current.has(doneKey)) {
          pushNotice({ sessionId: id, title, body: '任务完成' })
        }
      }

      for (const job of sessionsState.jobsBySession[id] ?? []) {
        if (job.status === 'running' || job.status === 'stopping') continue
        const key = `${id}:job:${job.id}:${job.status}`
        nextKeys.add(key)
        if (noticesInitialized.current && !noticedKeys.current.has(key)) {
          const body = job.status === 'completed' ? '任务完成' : `任务结束:${job.status}`
          pushNotice({ sessionId: id, title, body: `${job.label} · ${body}` })
        }
      }
    }

    if (!noticesInitialized.current) {
      noticesInitialized.current = true
    }
    noticedKeys.current = nextKeys
  }, [sessionsState])

  // True while a popstate (or a UI close that calls history.back()) is being
  // applied; the frame-sync effect must not push a duplicate history entry.
  const applyingPop = useRef(false)
  // The initial frame belongs to the entry already loaded by the browser
  // (or is replaceState'd onto it); only subsequent transitions push.
  const historyReady = useRef(false)

  useEffect(() => {
    if (!historyReady.current) {
      if (readFrameSnapshot(history.state) === undefined) {
        history.replaceState(frame, '')
      }
      historyReady.current = true
      return
    }
    if (applyingPop.current) {
      applyingPop.current = false
      return
    }
    history.pushState(frame, '')
  }, [frame])

  useEffect(() => {
    const onPopState = (event: PopStateEvent): void => {
      applyingPop.current = true
      setFrame(prev => {
        const next = readFrameSnapshot(event.state) ?? homeSnapshot()
        return sameSnapshot(prev, next) ? prev : next
      })
    }
    window.addEventListener('popstate', onPopState)
    return () => { window.removeEventListener('popstate', onPopState) }
  }, [])

  /** Push a UI transition onto the history stack. */
  const pushFrame = (next: FrameSnapshot): void => {
    setFrame(prev => sameSnapshot(prev, next) ? prev : next)
  }

  /**
   * UI close/back actions mirror the platform back gesture: update the screen
   * immediately, mark the pop so the sync effect stays quiet, then consume
   * the history entry. `history.back()` is async; the popstate listener owns
   * the authoritative second application of the same state.
   */
  const popFrame = (next: FrameSnapshot): void => {
    applyingPop.current = true
    setFrame(prev => sameSnapshot(prev, next) ? prev : next)
    history.back()
  }

  const selectSession = (id: SessionId): void => {
    openSession(id)
    pushFrame(homeSnapshot())
  }

  const toggleDrawer = (): void => {
    if (drawerOpen) {
      popFrame({ ...frame, drawerOpen: false })
    } else {
      pushFrame({ ...frame, drawerOpen: true })
    }
  }

  const openDrawer = (): void => {
    pushFrame({ ...frame, drawerOpen: true })
  }

  const closeDrawer = (): void => {
    if (drawerOpen) {
      popFrame({ ...frame, drawerOpen: false })
    }
  }

  const pushPage = (next: Page): void => {
    pushFrame({ page: next, drawerOpen: false })
  }

  const backToConversation = (): void => {
    if (page !== 'conversation') {
      popFrame({ ...frame, page: 'conversation' })
    }
  }

  const startSessionInWorkspace = (workspaceId: WorkspaceId): void => {
    workspaces.startSession(workspaceId)
    closeDrawer()
  }

  const handleTouchStart = (event: ReactTouchEvent<HTMLDivElement>): void => {
    const touch = event.touches[0]
    /* v8 ignore next -- spec: a touchstart always carries at least one touch. */
    if (touch === undefined) return
    swipeStart.current = { x: touch.clientX, y: touch.clientY }
  }

  const handleTouchEnd = (event: ReactTouchEvent<HTMLDivElement>): void => {
    const origin = swipeStart.current
    swipeStart.current = null
    /* v8 ignore next -- a touchend without a recorded touchstart. */
    if (origin === null) return
    const touch = event.changedTouches[0]
    /* v8 ignore next -- spec: a touchend always carries at least one changed touch. */
    if (touch === undefined) return
    if (isMiddleRightSwipe(origin.x, origin.y, touch.clientX, touch.clientY)) {
      openDrawer()
    }
  }

  let home: ReactNode
  if (page === 'plan') {
    home = <PlanPage useSessions={useSessions} projection={projection} onBack={backToConversation} />
  } else if (page === 'goal') {
    home = <GoalPage useSessions={useSessions} projection={projection} goal={goal} onBack={backToConversation} />
  } else if (page === 'settings') {
    home = (
      <SettingsPage
        useSessions={useSessions}
        workspaces={workspaces}
        onOpenPlan={() => { pushPage('plan') }}
        onOpenGoal={() => { pushPage('goal') }}
        onBack={backToConversation}
      />
    )
  } else if (current === undefined) {
    home = (
      <div className={css.empty}>
        <p className={css.emptyTitle}>选择或新建一个会话开始</p>
        <button type="button" className={css.emptyButton} onClick={openDrawer}>
          打开会话列表
        </button>
      </div>
    )
  } else {
    home = (
      <div className={css.conversationWrap}>
        <ConversationPage sessionId={current} useSessions={useSessions} />
        <button
          type="button"
          className={css.floatingMenu}
          onClick={toggleDrawer}
          aria-label="打开会话列表"
        >
          ≡
        </button>
        <button
          type="button"
          className={css.floatingRefresh}
          onClick={() => {
            try {
              // Flutter 壳负责清缓存后重新加载 /m/;浏览器里退化为 location.reload。
              window.DshShell?.postMessage('refresh')
              return
            } catch {
              // fall through to the browser reload below.
            }
            window.location.reload()
          }}
          aria-label="强制刷新"
        >
          ⟳
        </button>
      </div>
    )
  }

  return (
    <div
      className={css.frame}
      data-mobile-shell
      onTouchStart={handleTouchStart}
      onTouchEnd={handleTouchEnd}
      onTouchCancel={() => { swipeStart.current = null }}
    >
      <main className={css.content}>{home}</main>
      <div className={css.drawerRoot} data-drawer-root data-open={drawerOpen || undefined} aria-hidden={!drawerOpen}>
        <div className={css.mask} data-drawer-mask onClick={closeDrawer} />
        <aside className={css.drawer} data-drawer role="dialog" aria-label="会话列表">
          <SessionListPage
            useSessions={useSessions}
            useWorkspaces={workspaces.useWorkspaces}
            onSelect={selectSession}
            onStartSession={startSessionInWorkspace}
          />
          <footer className={css.drawerFooter}>
            {DRAWER_PAGES.map(entry => (
              <button
                key={entry.page}
                type="button"
                className={css.footerItem}
                onClick={() => { pushPage(entry.page) }}
              >
                {entry.label}
              </button>
            ))}
          </footer>
        </aside>
      </div>
    </div>
  )
}
