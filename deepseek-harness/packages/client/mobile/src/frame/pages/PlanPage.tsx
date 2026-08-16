/**
 * Mobile plan page: a lightweight status card over the session's plan
 * projection plus desktop guidance, pushed over the conversation home with a
 * back bar. Plan mode itself is conversation-integrated (entered with /plan,
 * its status chip renders in the composer tool row inside the embedded
 * conversation column), and the desktop plan chip is not exported for import —
 * so this page degrades to status + guidance rather than reimplementing the
 * plan surface.
 */
import { useSyncExternalStore } from 'react'
import type { SessionListState } from '@deepseek-ai/dsh-client-runtime/client'
import type { SnapshotSelectorHook } from '@deepseek-ai/dsh-client-ui-slots'
import type { PlanProjection } from '@deepseek-ai/dsh-plan-mode/client'
import type { MobileFrameInjected } from '../../app-shell.ts'
import { PageBackBar } from '../PageBackBar.tsx'
import css from './PlanPage.module.css'

const NOOP_SUBSCRIBE = (): (() => void) => () => {}

/** Props: the sessions hook, the projection face resolver, and the back callback. */
export interface PlanPageProps {
  useSessions: SnapshotSelectorHook<SessionListState>
  projection: MobileFrameInjected['projection']
  onBack: () => void
}

/** The mobile plan page (see module doc). */
export function PlanPage({ useSessions, projection, onBack }: PlanPageProps) {
  const current = useSessions(state => state.current)
  const face = current === undefined ? undefined : projection(current, 'plan')
  const plan = useSyncExternalStore(
    face?.subscribe ?? NOOP_SUBSCRIBE,
    () => (face?.getSnapshot() as PlanProjection | undefined),
  )
  return (
    <div className={css.page}>
      <PageBackBar title="计划" onBack={onBack} />
      {current === undefined || plan === undefined
        ? <p className={css.hint}>打开一个会话后，在这里查看它的计划模式状态。</p>
        : (
          <div className={css.card}>
            <span className={css.status} data-active={plan.active || undefined}>
              {plan.active ? '计划模式已开启' : '计划模式已关闭'}
            </span>
            {plan.pending && <p className={css.pending}>正在切换…</p>}
            <p className={css.hint}>计划模式在会话内通过 /plan 命令开启与关闭，状态芯片显示在输入条上。</p>
          </div>
        )}
    </div>
  )
}
