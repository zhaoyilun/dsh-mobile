/**
 * Mobile app-shell assembly plugin. Its pseudo package id exists only in the
 * shell registry; there is no npm package behind it (the desktop kernel's
 * app-shell pattern). The assembly installs the renderer configured to
 * dispatch 'mobile-frame' instead of 'root' — the mechanism that keeps the
 * desktop frame registered into 'root' inert — declares and registers the
 * mobile frame, and provides the ctx.appShell face AppRoot renders once the
 * boot settles.
 */
import type { ReactNode } from 'react'
import type { Context } from '@deepseek-ai/cordis'
import type { HostObservable, PropsRenderSlots, SnapshotSelectorHook, TranslateNS } from '@deepseek-ai/dsh-client-ui-slots'
import type { SessionId, WorkspaceListState } from '@deepseek-ai/dsh-client-runtime/client'
// Type-only: pulls the api-remotes Context merge (ctx.remote) and its WorkspaceId type.
import type { WorkspaceId } from '@deepseek-ai/dsh-api-remotes/client'
import type {} from '@deepseek-ai/dsh-api-remotes/client'
// Type-only: pulls the locale Context merge (ctx.locale) into this program.
import type {} from '@deepseek-ai/dsh-client-locale/client'
// Type-only: pulls the ui-layout SlotMap merge ('shell.overlay', declared by
// the desktop frame in the shared composition) that the mobile declarant rides.
import type {} from '@deepseek-ai/dsh-client-ui-layout/client'
// Type-only: pulls the ui-goal client entry — its GoalActionResult type and
// the `goal` LocaleNamespaceMap merge the bound translator is typed against.
import type { GoalActionResult } from '@deepseek-ai/dsh-client-ui-goal/client'
import type { GoalRef } from '@deepseek-ai/dsh-goal/client'
import { bindSnapshotSelector, createSlotRenderer } from '@deepseek-ai/dsh-client-web-react'
import { buildMobileRenderApp } from './app.tsx'
import { MobileFrame } from './frame/MobileFrame.tsx'

/** Shell-owned pseudo entry id under which the mobile boot mounts this plugin. */
export const MOBILE_SHELL_ID = '@deepseek-ai/dsh-client-mobile-app-shell'

/** The assembled-UI face AppRoot renders once the boot settles (same contract as the desktop shell). */
export interface AppShellService {
  /** Build (once) and render the real UI tree. */
  renderApp: () => ReactNode
}

declare module '@deepseek-ai/cordis' {
  interface Context {
    /** The shell assembly face, provided by the mobile app-shell entry once its inject set is active. */
    appShell: AppShellService
  }
}

/** Injected business face of the mobile frame (root scope — callbacks capture ctx, pages pass session ids). */
export interface MobileFrameInjected {
  /** Select a session as current (the embedded conversation column follows it). */
  openSession: (id: SessionId) => void
  /**
   * Resolve a session's projection face by key (the framework's per-session
   * projection store; pages bind it with useSyncExternalStore because the
   * mobile pages are root-scope and the framework useProjection seat is
   * session-scope).
   * @param sessionId - the target session.
   * @param key - the projection key ('goal', 'plan', ...).
   * @returns the observable face, or undefined while the session has none.
   */
  projection: (sessionId: SessionId, key: string) => HostObservable<unknown> | undefined
  /** Goal mutation verbs plus the goal-locale translator (the goal page composes GoalBarActions per current session). */
  goal: {
    /** Translate the goal dock's copy (the ui-goal dictionary is registered by its plugin in the shared composition). */
    t: TranslateNS<'goal'>
    /** CAS ref of the session's current projected goal, read at verb call time. */
    refOf: (sessionId: SessionId) => GoalRef | undefined
    /** Replace the current goal's objective. */
    onEdit: (sessionId: SessionId, objective: string) => Promise<GoalActionResult>
    /** Pause an active goal. */
    onPause: (sessionId: SessionId) => Promise<GoalActionResult>
    /** Resume a paused goal. */
    onResume: (sessionId: SessionId) => Promise<GoalActionResult>
    /** Clear the current goal (tombstone). */
    onClear: (sessionId: SessionId) => Promise<GoalActionResult>
  }
    /** Workspace list/actions for grouping the drawer and starting sessions in a workspace. */
    workspaces: {
      /** The standard workspace-list hook (bindSnapshotSelector over ctx.workspaces.list). */
      useWorkspaces: SnapshotSelectorHook<WorkspaceListState>
      /** Start (reuse or create) the blank session for a workspace and open it. */
      startSession: (workspaceId?: WorkspaceId) => void
    }
}

/** Cordis plugin name. */
export const name = 'mobile-app-shell'

/** Services required before shell assembly. The layout service stays injected even though the frame never renders it — ui-conversation needs ctx.layout to activate. */
export const inject = ['slots', 'sessions', 'workspaces', 'layout', 'locale', 'remote']

/** The no-goal result the CAS verbs return when the session has no projected goal. */
const NO_CURRENT_GOAL: GoalActionResult = {
  ok: false,
  error: { code: 'no-current-goal', message: 'no current goal to mutate', details: {} },
}

/**
 * Declarant entry riding the additive 'shell.overlay' list slot: it declares
 * the 'mobile-frame' child hole (declaring is claiming) and renders nothing.
 * The renderSlot prop is declared (the children table demands it) but unused —
 * the frame, not this declarant, composes the mobile tree.
 */
function MobileFrameDeclarant(_props: PropsRenderSlots<'mobile-frame'>): null {
  return null
}

/**
 * Installs the mobile renderer and exposes the assembled mobile application.
 * @param ctx - Plugin context.
 */
export function apply(ctx: Context): void {
  // The renderer install is shell territory (web-react is shell-bundled);
  // it lands here, on the entry whose inject set guarantees ctx.slots exists.
  ctx.slots.install(createSlotRenderer({ rootKey: 'mobile-frame' }))

  // Declare the mobile frame hole and register the frame. The declarant rides
  // the additive 'shell.overlay' list slot (declared by the desktop frame,
  // which is always in the shared composition) and declares 'mobile-frame' as
  // its child; the frame then registers into it. Both contributions die
  // together when the assembly fiber unloads.
  ctx.slots.inject('shell.overlay', function* () {
    yield ctx.slots.register({
      name: 'shell.overlay',
      id: 'mobile-frame-declarant',
      registrant: 'dsh-client-mobile',
      children: { 'mobile-frame': { kind: 'single', scope: 'root' } },
    }, MobileFrameDeclarant)
    yield ctx.slots.register({
      name: 'mobile-frame',
      registrant: 'dsh-client-mobile',
      inject: (): MobileFrameInjected => {
        const sessions = ctx.sessions
        const t = ctx.locale.bind('goal')
          const workspaces = ctx.workspaces
          const useWorkspaces = bindSnapshotSelector(workspaces.list)
        const refOf = (sessionId: SessionId): GoalRef | undefined => {
          const face = sessions.binding(sessionId)?.session.projections.faceOf('goal')
          const projection = face?.getSnapshot() as { goal: GoalRef } | null | undefined
          if (projection == null) return undefined
          return projection.goal
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
              useWorkspaces,
              startSession: (workspaceId) => { workspaces.startSession(workspaceId) },
            },
        }
      },
    }, MobileFrame)
  })

  // Assemble once on first render: the closure must be identity-stable
  // across AppRoot re-renders.
  let renderApp: (() => ReactNode) | undefined
  ctx.reflect.provide('appShell', {
    renderApp: (): ReactNode => {
      renderApp ??= buildMobileRenderApp({ ctx })
      return renderApp()
    },
  })
}
