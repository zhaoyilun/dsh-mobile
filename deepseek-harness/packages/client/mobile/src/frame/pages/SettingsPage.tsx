/**
 * Mobile settings page: the small but complete phone surface — connection,
 * server/workspace/session identity, entry points for the session-scoped plan
 * and goal pages, and about/version. Server and phone-pass editing remain in
 * the Flutter shell's own Settings page (the shell owns credentials).
 */
import type { SessionListState, WorkspaceListState } from '@deepseek-ai/dsh-client-runtime/client'
import type { SnapshotSelectorHook } from '@deepseek-ai/dsh-client-ui-slots'
import type { MobileFrameInjected } from '../../app-shell.ts'
import { PageBackBar } from '../PageBackBar.tsx'
import css from './SettingsPage.module.css'

declare global {
  /** Injected by the Flutter WebView shell; absent in ordinary browsers. */
  var DshShell: { postMessage(message: string): void } | undefined
}

/** Props: sessions, workspaces, plan/goal navigation, and the back callback. */
export interface SettingsPageProps {
  useSessions: SnapshotSelectorHook<SessionListState>
  useWorkspaces: SnapshotSelectorHook<WorkspaceListState>
  onOpenPlan: () => void
  onOpenGoal: () => void
  onBack: () => void
}

/** The mobile settings page (see module doc). */
export function SettingsPage({
  useSessions,
  useWorkspaces,
  onOpenPlan,
  onOpenGoal,
  onBack,
}: SettingsPageProps) {
  const phase = useSessions(state => state.phase)
  const currentSession = useSessions(state => state.current)
  const sessionTitle = useSessions(state =>
    state.current === undefined ? undefined : state.byId[state.current]?.displayTitle)
  const workspace = useWorkspaces(state => {
    if (currentSession === undefined) return undefined
    return state.items.find(item => item.sessionIds.includes(currentSession))
  })
  const connected = phase === 'ready'
  return (
    <div className={css.page}>
      <PageBackBar title="设置" onBack={onBack} />
      <div className={css.card}>
        <div className={css.row}>
          <span className={css.rowLabel}>连接状态</span>
          <span className={css.rowValue} data-connected={connected || undefined}>
            {connected ? '已连接' : '连接中…'}
          </span>
        </div>
        <div className={css.row}>
          <span className={css.rowLabel}>当前设备</span>
          <span className={css.rowValue}>{(globalThis as { __DSH_DEVICE__?: string }).__DSH_DEVICE__ ?? '手机'}</span>
        </div>
        <div className={css.row}>
          <span className={css.rowLabel}>服务器</span>
          {/* v8 ignore start -- browsers and jsdom always define location; the fallback covers non-DOM hosts only. */}
          <span className={css.rowValue}>{globalThis.location?.origin ?? '未知'}</span>
          {/* v8 ignore stop */}
        </div>
        <div className={css.row}>
          <span className={css.rowLabel}>当前工作区</span>
          <span className={css.rowValue}>{workspace?.title || '未分组'}</span>
        </div>
        <div className={css.row}>
          <span className={css.rowLabel}>当前会话</span>
          <span className={css.rowValue}>{sessionTitle ?? '未选择'}</span>
        </div>
      </div>

      <div className={css.card}>
        <button type="button" className={css.action} onClick={onOpenPlan}>
          <span className={css.actionText}>
            <span className={css.actionTitle}>计划模式</span>
            <span className={css.actionHint}>查看当前会话是否处于计划模式;用 /plan 命令开关</span>
          </span>
          <span className={css.chevron}>›</span>
        </button>
        <button type="button" className={css.action} onClick={onOpenGoal}>
          <span className={css.actionText}>
            <span className={css.actionTitle}>目标</span>
            <span className={css.actionHint}>查看、暂停或恢复当前会话的目标;用 /goal 命令创建</span>
          </span>
          <span className={css.chevron}>›</span>
        </button>
      </div>

      <div className={css.card}>
        <div className={css.row}>
          <span className={css.rowLabel}>版本</span>
          <span className={css.rowValue}>DSH Mobile</span>
        </div>
        <button
          type="button"
          className={css.action}
          onClick={() => { globalThis.DshShell?.postMessage('openDevices') }}
        >
          <span className={css.actionText}>
            <span className={css.actionTitle}>设备管理</span>
            <span className={css.actionHint}>切换 Mac / Windows / Linux 设备</span>
          </span>
          <span className={css.chevron}>›</span>
        </button>
        <button
          type="button"
          className={css.action}
          onClick={() => { globalThis.DshShell?.postMessage('openSettings') }}
        >
          <span className={css.actionText}>
            <span className={css.actionTitle}>服务器与口令</span>
            <span className={css.actionHint}>打开 App 设置修改</span>
          </span>
          <span className={css.chevron}>›</span>
        </button>
      </div>

      <p className={css.about}>
        DeepSeek Harness 手机端。会话列表按工作区分组;新建会话点工作区标题旁的 ✚。
      </p>
    </div>
  )
}
