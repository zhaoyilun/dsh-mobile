/**
 * Mobile session list (drawer content): rows grouped by Workspace (the same
 * accounting the desktop sidebar shows), then a trailing "未分组" bucket for
 * sessions no workspace accounts. Rows keep the ChatGPT-style shape — title,
 * light relative time, running dot, current highlight. Filtering keeps the
 * desktop workspace tree's visibility rule — subagent children stay under
 * their parent session's conversation view, blank sessions stay hidden unless
 * they are the currently open one.
 */
import { useState, type ReactNode } from 'react'
import type { SessionId, SessionSummary, WorkspaceListState } from '@deepseek-ai/dsh-client-runtime/client'
import type { SnapshotSelectorHook } from '@deepseek-ai/dsh-client-ui-slots'
import type { WorkspaceId } from '@deepseek-ai/dsh-api-remotes/client'
import type { UseSessions } from '../MobileFrame.tsx'
import css from './SessionListPage.module.css'

/** Props: the sessions and workspaces hooks, plus row tap and workspace new-session actions. */
export interface SessionListPageProps {
  useSessions: UseSessions
  useWorkspaces: SnapshotSelectorHook<WorkspaceListState>
  /** Open the tapped session (the frame also switches to the conversation home). */
  onSelect: (id: SessionId) => void
  /** Reuse/create the blank session in this workspace (mobile-new-session action). */
  onStartSession: (workspaceId: WorkspaceId) => void
}

/**
 * The sessions worth a top-level row, mirroring the desktop workspace tree's
 * visibility rule: subagent children live under their parent session's
 * conversation view (SubagentCatalog), not in the list, and blank sessions
 * stay hidden unless they are the currently open one.
 */
function rowVisible(session: SessionSummary, current: SessionId | undefined): boolean {
  return session.origin !== 'subagent' && (!session.blank || session.id === current)
}

/** The minute unit, as ms. */
const MINUTE_MS = 60_000

/** The day unit, as ms. */
const DAY_MS = 24 * 60 * MINUTE_MS

/**
 * Format an update timestamp as a ChatGPT-style relative label: 刚刚,
 * N分钟前, clock time today, 昨天, weekday this week, then 8月12日 style.
 * The month/day fallback is assembled by hand — zh-CN numeric month/day
 * formats as "11/15" in this ICU build, not the 8月12日 the design calls for.
 * @param updatedAt - the session's last-update epoch ms.
 * @param now - the reference now (injectable for deterministic tests).
 * @returns the short relative label.
 */
export function relativeTime(updatedAt: number, now: number = Date.now()): string {
  const elapsed = Math.max(0, now - updatedAt)
  if (elapsed < MINUTE_MS) return '刚刚'
  if (elapsed < 60 * MINUTE_MS) return `${Math.floor(elapsed / MINUTE_MS)}分钟前`
  const updated = new Date(updatedAt)
  const today = new Date(now)
  const dayStart = (date: Date): number => new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
  const days = Math.round((dayStart(today) - dayStart(updated)) / DAY_MS)
  if (days <= 0) return updated.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })
  if (days === 1) return '昨天'
  if (days < 7) return updated.toLocaleDateString('zh-CN', { weekday: 'short' })
  return `${updated.getMonth() + 1}月${updated.getDate()}日`
}

/** The mobile session list (see module doc). */
export function SessionListPage({
  useSessions,
  useWorkspaces,
  onSelect,
  onStartSession,
}: SessionListPageProps) {
  const state = useSessions(s => s)
  const workspaces = useWorkspaces(s => s)
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(() => new Set())
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set())

  const toggleGroup = (key: string): void => {
    setCollapsed(prev => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  const toggleExpanded = (key: string): void => {
    setExpanded(prev => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  const visible = (id: SessionId): boolean => {
    const session = state.byId[id]
    return session !== undefined && rowVisible(session, state.current)
  }

  /** 按最近一次对话时间倒序;同时间用 session id 保证顺序稳定。 */
  const byLatestConversation = (ids: SessionId[]): SessionId[] => [...ids].sort((a, b) => {
    const aTime = state.byId[a]?.updatedAt ?? Number.NEGATIVE_INFINITY
    const bTime = state.byId[b]?.updatedAt ?? Number.NEGATIVE_INFINITY
    if (aTime !== bTime) return bTime - aTime
    return a < b ? -1 : 1
  })

  /** Default preview length; long groups expand on demand instead of scrolling inside the group. */
  const PREVIEW_COUNT = 5

  const previewIds = (key: string, ids: SessionId[]): SessionId[] => {
    if (collapsed.has(key)) return []
    return expanded.has(key) ? ids : ids.slice(0, PREVIEW_COUNT)
  }

  const renderGroupMore = (key: string, title: string, total: number): ReactNode => {
    if (total <= PREVIEW_COUNT) return null
    const isExpanded = expanded.has(key)
    return (
      <button
        type="button"
        className={css.groupMore}
        aria-label={`${isExpanded ? '收起' : '显示全部'} ${title}`}
        onClick={() => { toggleExpanded(key) }}
      >
        {isExpanded ? '收起' : `显示全部 ${total} 项`}
      </button>
    )
  }

  const accounted = new Set<string>()
  const groups = workspaces.items.map(workspace => {
    for (const id of workspace.sessionIds) accounted.add(id)
    return {
      key: workspace.workspaceId,
      title: workspace.title.trim() || workspace.path.split('/').filter(Boolean).pop() || '未命名工作区',
      ids: byLatestConversation(workspace.sessionIds.filter(visible)),
    }
  }).filter(group => group.ids.length > 0)

  const ungrouped = byLatestConversation(state.ids.filter(id => visible(id) && !accounted.has(id)))
  const totalRows = groups.reduce((sum, group) => sum + group.ids.length, 0) + ungrouped.length
  const empty = state.phase === 'ready' && totalRows === 0

  const renderRow = (id: SessionId): ReactNode => {
    const session: SessionSummary | undefined = state.byId[id]
    /* v8 ignore next -- the filter above already proved this row exists in the same snapshot. */
    if (session === undefined) return null
    const current = id === state.current
    return (
      <li key={id}>
        <button
          type="button"
          className={css.row}
          data-session-id={session.id}
          data-current={current || undefined}
          onClick={() => { onSelect(id) }}
        >
          {session.running && <span className={css.dot} aria-label="进行中" />}
          <span className={css.rowTitle}>{session.displayTitle}</span>
          <span className={css.time}>{relativeTime(session.updatedAt)}</span>
        </button>
      </li>
    )
  }

  return (
    <div className={css.page}>
      {state.phase === 'pending' && totalRows === 0 && <p className={css.hint}>正在加载会话…</p>}
      {empty && <p className={css.hint}>还没有会话。回到电脑端新建一个会话吧。</p>}
      <ul className={css.list}>
          {groups.map(group => (
            <li key={group.key} className={css.group}>
              <div className={css.groupHeader}>
                <button
                  type="button"
                  className={css.groupToggle}
                  aria-expanded={!collapsed.has(group.key)}
                  aria-label={`${collapsed.has(group.key) ? '展开' : '折叠'} ${group.title}`}
                  onClick={() => { toggleGroup(group.key) }}
                >
                  <span className={css.chevron} data-collapsed={collapsed.has(group.key) || undefined}>⌄</span>
                  <span className={css.groupTitle}>{group.title}</span>
                </button>
                <button
                  type="button"
                  className={css.groupNew}
                  aria-label={`在 ${group.title} 中新建会话`}
                  onClick={() => { onStartSession(group.key as WorkspaceId) }}
                >
                  ✚
                </button>
              </div>
              <div className={css.groupRows} data-collapsed={collapsed.has(group.key) || undefined}>
                <ul className={css.groupRowsList}>{previewIds(group.key, group.ids).map(renderRow)}</ul>
                {renderGroupMore(group.key, group.title, group.ids.length)}
              </div>
            </li>
          ))}
          {ungrouped.length > 0 && (
            <li className={css.group}>
              <div className={css.groupHeader}>
                <button
                  type="button"
                  className={css.groupToggle}
                  aria-expanded={!collapsed.has('__ungrouped__')}
                  aria-label={`${collapsed.has('__ungrouped__') ? '展开' : '折叠'} 未分组`}
                  onClick={() => { toggleGroup('__ungrouped__') }}
                >
                  <span className={css.chevron} data-collapsed={collapsed.has('__ungrouped__') || undefined}>⌄</span>
                  <span className={css.groupTitle}>未分组</span>
                </button>
              </div>
              <div className={css.groupRows} data-collapsed={collapsed.has('__ungrouped__') || undefined}>
                <ul className={css.groupRowsList}>{previewIds('__ungrouped__', ungrouped).map(renderRow)}</ul>
                {renderGroupMore('__ungrouped__', '未分组', ungrouped.length)}
              </div>
            </li>
          )}
      </ul>
    </div>
  )
}
