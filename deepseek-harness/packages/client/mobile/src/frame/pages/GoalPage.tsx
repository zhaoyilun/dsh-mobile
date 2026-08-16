/**
 * Mobile goal page: reuses the desktop goal strip (ui-goal's GoalBar — the
 * one conversation feature exported as an importable component) over the
 * session's projected goal, composed per current session into GoalBarActions.
 * Goal creation stays on the /goal command (desktop behavior preserved); the
 * page reads the current session's 'goal' projection through the injected
 * projection face, bound with useSyncExternalStore (the mobile pages are
 * root-scope, so the framework's session-scope useProjection seat is not
 * available; the sanctioned bindSnapshotSelector cannot follow a changing
 * per-session source).
 */
import { useSyncExternalStore } from 'react'
import type { SessionId, SessionListState } from '@deepseek-ai/dsh-client-runtime/client'
import type { SnapshotSelectorHook } from '@deepseek-ai/dsh-client-ui-slots'
import { GoalBar, type GoalBarActions } from '@deepseek-ai/dsh-client-ui-goal/client'
import type { GoalProjection } from '@deepseek-ai/dsh-goal/client'
import type { MobileFrameInjected } from '../../app-shell.ts'
import { PageBackBar } from '../PageBackBar.tsx'
import css from './GoalPage.module.css'

const NOOP_SUBSCRIBE = (): (() => void) => () => {}

/** Props: the sessions hook, the projection face resolver, the goal verbs, and the back callback. */
export interface GoalPageProps {
  useSessions: SnapshotSelectorHook<SessionListState>
  projection: MobileFrameInjected['projection']
  goal: MobileFrameInjected['goal']
  onBack: () => void
}

/** Compose the session-scoped GoalBarActions from the session-agnostic verbs. */
function actionsFor(sessionId: SessionId, goal: MobileFrameInjected['goal']): GoalBarActions {
  return {
    onEdit: (objective) => goal.onEdit(sessionId, objective),
    onPause: () => goal.onPause(sessionId),
    onResume: () => goal.onResume(sessionId),
    onClear: () => goal.onClear(sessionId),
  }
}

/** The mobile goal page (see module doc). */
export function GoalPage({ useSessions, projection, goal, onBack }: GoalPageProps) {
  const current = useSessions(state => state.current)
  const face = current === undefined ? undefined : projection(current, 'goal')
  const projectionValue = useSyncExternalStore(
    face?.subscribe ?? NOOP_SUBSCRIBE,
    () => (face?.getSnapshot() as GoalProjection | null | undefined),
  )
  const goalValue = projectionValue === undefined
    ? undefined
    : projectionValue === null
      ? null
      : projectionValue.goal

  return (
    <div className={css.page}>
      <PageBackBar title="目标" onBack={onBack} />
      {current === undefined || face === undefined
        ? <p className={css.hint}>打开一个会话后，在这里查看和管理它的目标。</p>
        : (
          <div className={css.body}>
            <GoalBar
              goal={goalValue}
              t={goal.t}
              {...actionsFor(current, goal)}
            />
            <p className={css.hint}>目标条也会显示在会话输入框上方；创建目标请在电脑端使用 /goal 命令。</p>
          </div>
        )}
    </div>
  )
}
