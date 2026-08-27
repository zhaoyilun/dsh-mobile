/**
 * Mobile app-shell assembly plugin for DSH 0.1.1+.
 *
 * It replaces the desktop ui-layout as the 'root' occupant: the mobile frame
 * registers into the built-in root slot with a lower priority (-1) and
 * declares the same top-level child seats (conversation, sidebar, details,
 * shell.overlay), so the rest of the client composition (conversation, tools,
 * approvals, plan/goal/model seats) keeps working unchanged. Because the
 * desktop layout is deliberately not loaded, this assembly also provides the
 * minimal `ctx.layout` face ui-conversation expects.
 */
import type { Context } from '@deepseek-ai/cordis'
import type { HostObservable, TranslateNS } from '@deepseek-ai/dsh-client-ui-slots'
import type { SessionId } from '@deepseek-ai/dsh-client-runtime/client'
import type { WorkspaceId } from '@deepseek-ai/dsh-api-remotes/client'
import type {} from '@deepseek-ai/dsh-api-remotes/client'
import type {} from '@deepseek-ai/dsh-client-locale/client'
import type { ILayout } from '@deepseek-ai/dsh-client-ui-layout/client'
import type { GoalActionResult } from '@deepseek-ai/dsh-client-ui-goal/client'
import type { GoalRef } from '@deepseek-ai/dsh-goal/client'
import { MobileFrame } from './frame/MobileFrame.tsx'

/** Shell-owned pseudo entry id under which the mobile boot mounts this plugin. */
export const MOBILE_SHELL_ID = '@deepseek-ai/dsh-client-mobile-app-shell'

/** Injected business face of the mobile frame (root scope). */
export interface MobileFrameInjected {
  openSession: (id: SessionId) => void
  projection: (sessionId: SessionId, key: string) => HostObservable<unknown> | undefined
  goal: {
    t: TranslateNS<'goal'>
    refOf: (sessionId: SessionId) => GoalRef | undefined
    onEdit: (sessionId: SessionId, objective: string) => Promise<GoalActionResult>
    onPause: (sessionId: SessionId) => Promise<GoalActionResult>
    onResume: (sessionId: SessionId) => Promise<GoalActionResult>
    onClear: (sessionId: SessionId) => Promise<GoalActionResult>
  }
  workspaces: {
    startSession: (workspaceId?: WorkspaceId) => void
  }
}

/** Cordis plugin name. */
export const name = 'mobile-app-shell'

/** Services required before mobile shell assembly. */
export const inject = ['slots', 'sessions', 'workspaces', 'locale', 'remote']

/** The no-goal result the CAS verbs return when the session has no projected goal. */
const NO_CURRENT_GOAL: GoalActionResult = {
  ok: false,
  error: { code: 'no-current-goal', message: 'no current goal to mutate', details: {} },
}

/** Mobile root children: same top-level seats the desktop frame declares. */
export const MOBILE_CHILDREN = {
  'sidebar': { kind: 'single', scope: 'root' },
  'conversation': { kind: 'single', scope: 'session-maybe' },
  'details': { kind: 'single', scope: 'session' },
  'shell.overlay': { kind: 'list', scope: 'root' },
} as const

export type MobileChildSlots = keyof typeof MOBILE_CHILDREN

/**
 * Mobile app-shell body: provide the minimal layout face and register the
 * mobile frame into 'root'. It shadows the (skipped) desktop frame; the
 * loader row for ui-layout is filtered out by the mobile boot so no child
 * declaration conflicts occur.
 * @param ctx - Client context.
 */
export function apply(ctx: Context): void {
  // A no-op layout face is enough: the mobile frame never renders the desktop
  // sidebar/details panels, while ui-conversation hooks into open/close APIs
  // only when users invoke desktop-only gestures.
  const layout: ILayout = {
    toggleSidebar() {},
    openDetails() {},
    closeDetails() {},
  }

  ctx.effect(() => {
    const disposeLayout = ctx.reflect.provide('layout', layout)
    const disposeRegistration = ctx.slots.register({
      name: 'root',
      priority: -1,
      registrant: 'dsh-client-mobile',
      children: MOBILE_CHILDREN,
      inject: (): MobileFrameInjected => {
        const sessions = ctx.sessions
        const t = ctx.locale.bind('goal')
        const workspaces = ctx.workspaces
        const refOf = (sessionId: SessionId): GoalRef | undefined => {
          const face = sessions.binding(sessionId)?.session.projections.faceOf('goal')
          const snapshot = face?.getSnapshot() as { goal: GoalRef } | null | undefined
          if (snapshot == null) return undefined
          return snapshot.goal
        }
        return {
          openSession: (id) => { sessions.open(id) },
          projection: (sessionId, key) =>
            sessions.binding(sessionId)?.session.projections.faceOf(key),
          goal: {
            t,
            refOf,
            onEdit: async (sessionId, objective) => {
              const ref = refOf(sessionId)
              if (ref === undefined) return NO_CURRENT_GOAL
              return await ctx.remote.goals.edit(sessionId, ref, { objective })
            },
            onPause: async (sessionId) => {
              const ref = refOf(sessionId)
              if (ref === undefined) return NO_CURRENT_GOAL
              return await ctx.remote.goals.pause(sessionId, ref)
            },
            onResume: async (sessionId) => {
              const ref = refOf(sessionId)
              if (ref === undefined) return NO_CURRENT_GOAL
              return await ctx.remote.goals.resume(sessionId, ref)
            },
            onClear: async (sessionId) => {
              const ref = refOf(sessionId)
              if (ref === undefined) return NO_CURRENT_GOAL
              return await ctx.remote.goals.clear(sessionId, ref)
            },
          },
          workspaces: {
            startSession: (workspaceId) => { workspaces.startSession(workspaceId) },
          },
        }
      },
    }, MobileFrame)
    return () => {
      disposeRegistration()
      void disposeLayout()
    }
  }, 'mobile-shell: layout + root registration')
}
