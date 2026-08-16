// @vitest-environment jsdom
/**
 * Mobile shell component tests: the session-list drawer rows, and the
 * frame-slot fixture proving the "one composition, two shells" mechanism —
 * under the SAME slot graph (a desktop frame registered into 'root' declaring
 * the desktop seats), rendering 'mobile-frame' shows the ChatGPT-style mobile
 * shell (conversation home, session-list drawer, pushed pages) and the
 * desktop 'root' content never appears. The SlotMap keys are declared locally
 * (the test program must not double-merge the mobile package's own
 * declarations); the mobile components are imported directly from src.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { act, cleanup, fireEvent, render, within } from '@testing-library/react'

/** Posts received by the mocked Flutter `DshNotify` JavaScript channel. */
let dshNoticePosts: Array<{ title?: unknown; body?: unknown; sessionId?: unknown }> = []

beforeEach(() => {
  // The frame persists its page/drawer into browser history; reset the
  // jsdom history before each test so one fixture cannot restore another
  // fixture's pushed page state.
  window.history.replaceState(null, '')
  // The shell forwards notifications through the native `DshNotify` channel.
  dshNoticePosts = []
  window.DshNotify = { postMessage: (message) => { dshNoticePosts.push(JSON.parse(message) as typeof dshNoticePosts[number]) } }
})

afterEach(() => {
  cleanup()
  delete window.DshNotify
})
import { SlotCore, type PropsRenderSlots, type SlotRendererHost } from '@deepseek-ai/dsh-client-ui-slots'
import { createSlotRenderer } from '@deepseek-ai/dsh-client-web-react'
import type { WorkspaceId } from '@deepseek-ai/dsh-api-remotes/client'
import type { SessionId, SessionListState, WorkspaceListState } from '@deepseek-ai/dsh-client-runtime/client'
// Type-only: pulls the desktop seat merges (root/sidebar/conversation/details/shell.overlay) and the mobile 'mobile-frame' merge into this program — the aggregate already declares them.
import type {} from '@deepseek-ai/dsh-client-ui-layout/client'
import type {} from '../src/slots.ts'
import type { MobileFrameInjected } from '../src/app-shell.ts'
import { MobileFrame } from '../src/frame/MobileFrame.tsx'
import { GoalPage } from '../src/frame/pages/GoalPage.tsx'
import { PlanPage } from '../src/frame/pages/PlanPage.tsx'
import { SessionListPage, relativeTime } from '../src/frame/pages/SessionListPage.tsx'
import { SettingsPage } from '../src/frame/pages/SettingsPage.tsx'

/** Minimal live source for the sessions.list standard feed. */
function makeListSource(initial: SessionListState): {
  getSnapshot: () => SessionListState
  subscribe: (fn: () => void) => () => void
  set: (next: SessionListState) => void
} {
  let value = initial
  const listeners = new Set<() => void>()
  return {
    getSnapshot: () => value,
    subscribe: (fn: () => void) => { listeners.add(fn); return () => { listeners.delete(fn) } },
    set: (next) => { value = next; for (const fn of [...listeners]) fn() },
  }
}
/** Minimal live source for the workspaces.list standard feed. */
function makeWorkspacesSource(initial: WorkspaceListState): {
  getSnapshot: () => WorkspaceListState
  subscribe: (fn: () => void) => () => void
  set: (next: WorkspaceListState) => void
} {
  let value = initial
  const listeners = new Set<() => void>()
  return {
    getSnapshot: () => value,
    subscribe: (fn: () => void) => { listeners.add(fn); return () => { listeners.delete(fn) } },
    set: (next) => { value = next; for (const fn of [...listeners]) fn() },
  }
}

/** Default empty workspace feed. */
function emptyWorkspacesState(): WorkspaceListState {
  return {
    items: [],
    archivedSessionIds: [],
    state: 'idle',
    phase: 'ready',
    error: null,
    baselinesReady: true,
    recentWorkspaceId: undefined,
  }
}

/** Bare selector hook over a workspaces stub (casts match the test-only seam). */
function workspacesHook(source: ReturnType<typeof makeWorkspacesSource>) {
  return (sel: (s: WorkspaceListState) => unknown): unknown => sel(source.getSnapshot())
}

function sid(id: string): SessionId {
  return id as SessionId
}

function listState(ids: SessionId[], current: SessionId | undefined): SessionListState {
  const byId: Record<string, SessionListState['byId'][SessionId]> = {}
  for (const id of ids) {
    byId[id] = {
      id,
      displayTitle: `会话 ${id}`,
      title: `会话 ${id}`,
      cwd: '/workspace',
      blank: false,
      running: false,
      updatedAt: 1_700_000_000_000,
    }
  }
  return { ids: [...ids], byId, current, phase: 'ready', subagentsByParent: {}, jobsBySession: {}, currentAddress: undefined }
}

/** Passthrough host over the real core (store/session projection seats unused here). */
function hostOver(core: SlotCore, sessionsList: ReturnType<typeof makeListSource>): SlotRendererHost {
  const absentInfo = { sessionId: undefined, hooks: {}, props: {} }
  return {
    subscribe: (key, fn) => core.subscribe(key, fn),
    getVersion: key => core.getVersion(key),
    entriesOf: key => core.entries(key),
    entriesOfSlot: key => core.entriesOfSlot(key),
    reportEntryError: (key, entry, error, info) => { core.reportEntryError(key, entry, error, info) },
    specOf: key => core.specDynamic(key),
    isLive: entry => core.isLive(entry),
    storeOf: () => undefined,
    sessions: {
      list: sessionsList,
      provideInfo: { getSnapshot: () => absentInfo, subscribe: () => () => {} },
    },
    workspaces: {
      list: { getSnapshot: () => ({ items: [], phase: 'pending' }), subscribe: () => () => {} },
    },
  }
}

/**
 * Stubbed mobile frame inject face: openSession writes the list source's
 * `current`; workspaces come from a live stub feed and startSession records
 * the requested workspace.
 */
function stubInjected(
  list: ReturnType<typeof makeListSource>,
  workspaces: ReturnType<typeof makeWorkspacesSource> = makeWorkspacesSource(emptyWorkspacesState()),
  startedSessions: WorkspaceId[] = [],
): MobileFrameInjected {
  return {
    openSession: (id) => { list.set({ ...list.getSnapshot(), current: id }) },
    projection: () => undefined,
    goal: {
      t: key => key,
      refOf: () => undefined,
      onEdit: async () => ({ ok: false, error: { code: 'x', message: 'x', details: {} } }),
      onPause: async () => ({ ok: false, error: { code: 'x', message: 'x', details: {} } }),
      onResume: async () => ({ ok: false, error: { code: 'x', message: 'x', details: {} } }),
      onClear: async () => ({ ok: false, error: { code: 'x', message: 'x', details: {} } }),
    },
    workspaces: {
      useWorkspaces: (selector) => selector(workspaces.getSnapshot()),
      startSession: (workspaceId) => { if (workspaceId !== undefined) startedSessions.push(workspaceId) },
    },
  }
}

/** Desktop frame stub: registered into 'root', declaring the desktop seats; must never render in the mobile shell. */
function DesktopFrame(_props: PropsRenderSlots<'sidebar' | 'conversation' | 'details' | 'shell.overlay'>) {
  return <div data-desktop-frame>DESKTOP-FRAME</div>
}

/** Mobile declarant stub mirroring the app-shell declarant: declares 'mobile-frame', renders nothing. */
function MobileDeclarant(_props: PropsRenderSlots<'mobile-frame'>): null {
  return null
}

/** Register the desktop frame into 'root' (declaring the desktop seats) plus a conversation occupant stub. */
function registerDesktop(core: SlotCore): void {
  core.register({
    name: 'root',
    children: {
      'sidebar': { kind: 'single', scope: 'root' },
      'conversation': { kind: 'single', scope: 'session-maybe' },
      'details': { kind: 'single', scope: 'session' },
      'shell.overlay': { kind: 'list', scope: 'root' },
    },
  }, DesktopFrame)
  core.register({ name: 'conversation' }, () => <div data-conversation-stub>CONV-CONTENT</div>)
}

/** Register the mobile declarant + the real MobileFrame with a stubbed inject face. */
function registerMobile(
  core: SlotCore,
  list: ReturnType<typeof makeListSource>,
  workspaces: ReturnType<typeof makeWorkspacesSource>,
  startedSessions: WorkspaceId[],
): void {
  core.register({
    name: 'shell.overlay',
    id: 'mobile-frame-declarant',
    children: { 'mobile-frame': { kind: 'single', scope: 'root' } },
  }, MobileDeclarant)
  core.register({
    name: 'mobile-frame',
    inject: () => stubInjected(list, workspaces, startedSessions),
  }, MobileFrame)
}

/** Render the mobile shell fixture over a desktop root + live list/workspace sources. */
function renderMobile(
  list: ReturnType<typeof makeListSource>,
  workspaces: ReturnType<typeof makeWorkspacesSource> = makeWorkspacesSource(emptyWorkspacesState()),
) {
  const core = new SlotCore()
  const startedSessions: WorkspaceId[] = []
  registerDesktop(core)
  registerMobile(core, list, workspaces, startedSessions)
  const renderer = createSlotRenderer({ rootKey: 'mobile-frame' })
  return { core, list, workspaces, startedSessions, view: render(<>{renderer.renderRoot(hostOver(core, list), {})}</>) }
}

/** The drawer root element of a rendered shell. */
function drawerRoot(view: ReturnType<typeof render>): HTMLElement {
  const el = view.container.querySelector('[data-drawer-root]')
  if (el === null) throw new Error('drawer root missing')
  return el as HTMLElement
}

/** The drawer panel element of a rendered shell. */
function drawer(view: ReturnType<typeof render>): HTMLElement {
  const el = view.container.querySelector('[data-drawer]')
  if (el === null) throw new Error('drawer missing')
  return el as HTMLElement
}

describe('relative time labels', () => {
  it('formats ChatGPT-style relative labels deterministically', () => {
    const now = new Date(2026, 0, 15, 12, 0, 0).getTime()
    expect(relativeTime(now - 30_000, now)).toBe('刚刚')
    expect(relativeTime(now - 5 * 60_000, now)).toBe('5分钟前')
    expect(relativeTime(new Date(2026, 0, 14, 9, 0, 0).getTime(), now)).toBe('昨天')
    expect(relativeTime(new Date(2026, 0, 12, 9, 0, 0).getTime(), now))
      .toBe(new Date(2026, 0, 12).toLocaleDateString('zh-CN', { weekday: 'short' }))
    expect(relativeTime(new Date(2023, 10, 15, 9, 0, 0).getTime(), now)).toBe('11月15日')
  })

  it('shows the clock for same-day timestamps older than an hour', () => {
    const now = new Date(2026, 0, 15, 12, 0, 0).getTime()
    expect(relativeTime(now - 2 * 60 * 60_000, now)).toMatch(/^\d{1,2}:\d{2}$/)
  })
})

describe('session list page', () => {
  it('hides subagent children and non-current blank sessions, keeping the desktop visibility rule', () => {
    const base = listState([sid('main'), sid('child'), sid('draft'), sid('open')], sid('main'))
    base.byId[sid('child')] = { ...base.byId[sid('child')]!, origin: 'subagent' as const, parentId: sid('main') }
    base.byId[sid('draft')] = { ...base.byId[sid('draft')]!, blank: true }
    base.byId[sid('open')] = { ...base.byId[sid('open')]!, blank: true }
    // 'open' is the current session, so it stays visible despite being blank.
    const state = { ...base, current: sid('open') }
    const list = makeListSource(state)
    const hook = (sel: (s: SessionListState) => unknown): unknown => sel(list.getSnapshot())
    const view = render(<SessionListPage useSessions={hook as never} useWorkspaces={workspacesHook(makeWorkspacesSource(emptyWorkspacesState())) as never} onStartSession={() => {}} onSelect={() => {}} />)
    const html = view.container.textContent ?? ''
    expect(html).toContain('会话 main')
    expect(html).toContain('会话 open')
    expect(html).not.toContain('会话 child')
    expect(html).not.toContain('会话 draft')
    // Rows carry only title + relative time: no cwd, no descendant count.
    expect(html).not.toContain('/workspace')
    expect(html).not.toContain('子代理')
  })

  it('renders the session list with the current session highlighted and forwards taps', () => {
    const list = makeListSource(listState([sid('s1'), sid('s2')], sid('s1')))
    const hook = (sel: (s: SessionListState) => unknown): unknown => sel(list.getSnapshot())
    let picked: SessionId | undefined
    const view = render(<SessionListPage useSessions={hook as never} useWorkspaces={workspacesHook(makeWorkspacesSource(emptyWorkspacesState())) as never} onStartSession={() => {}} onSelect={(id) => { picked = id }} />)
    expect(view.container.textContent).toContain('会话 s1')
    expect(view.container.textContent).toContain('会话 s2')
    const currentRow = view.container.querySelector('[data-current]')
    expect(currentRow?.textContent).toContain('会话 s1')
    fireEvent.click(view.getByText('会话 s2'))
    expect(picked).toBe('s2')
    view.unmount()
  })

  it('shows the loading hint while the list is pending', () => {
    const list = makeListSource({ ...listState([], undefined), phase: 'pending' as const })
    const hook = (sel: (s: SessionListState) => unknown): unknown => sel(list.getSnapshot())
    const view = render(<SessionListPage useSessions={hook as never} useWorkspaces={workspacesHook(makeWorkspacesSource(emptyWorkspacesState())) as never} onStartSession={() => {}} onSelect={() => {}} />)
    expect(view.container.textContent).toContain('正在加载会话')
    view.unmount()
  })

  it('marks a running session with a status dot', () => {
    const state = listState([sid('s1')], undefined)
    state.byId[sid('s1')] = { ...state.byId[sid('s1')]!, running: true }
    const list = makeListSource(state)
    const hook = (sel: (s: SessionListState) => unknown): unknown => sel(list.getSnapshot())
    const view = render(<SessionListPage useSessions={hook as never} useWorkspaces={workspacesHook(makeWorkspacesSource(emptyWorkspacesState())) as never} onStartSession={() => {}} onSelect={() => {}} />)
    expect(view.getByLabelText('进行中')).toBeDefined()
    view.unmount()
  })

  it('shows the empty hint once the list is ready with no sessions', () => {
    const list = makeListSource(listState([], undefined))
    const hook = (sel: (s: SessionListState) => unknown): unknown => sel(list.getSnapshot())
    const view = render(<SessionListPage useSessions={hook as never} useWorkspaces={workspacesHook(makeWorkspacesSource(emptyWorkspacesState())) as never} onStartSession={() => {}} onSelect={() => {}} />)
    expect(view.container.textContent).toContain('还没有会话')
    view.unmount()
  })
})

describe('frame slot fixture (one composition, two shells)', () => {
  it('shows the conversation home for the current session with no duplicate header bar', () => {
    const list = makeListSource(listState([sid('s1')], sid('s1')))
    const { view } = renderMobile(list)

    expect(view.container.querySelector('[data-mobile-shell]')).not.toBeNull()
    // The conversation column (desktop 'conversation' slot) is embedded whole.
    expect(view.container.textContent).toContain('CONV-CONTENT')
    // The old full-width mobile header is gone; a small floating drawer button remains.
    expect(view.container.querySelector('header')).toBeNull()
    expect(view.getByLabelText('打开会话列表')).toBeDefined()
    expect(view.queryByLabelText('新建会话')).toBeNull()
    // No bottom tab bar remains, and the desktop frame stays inert.
    expect(view.container.querySelector('[data-mobile-nav]')).toBeNull()
    expect(view.container.querySelector('[data-desktop-frame]')).toBeNull()
    expect(view.container.textContent).not.toContain('DESKTOP-FRAME')
    view.unmount()
  })

  it('shows the empty home when no session is current; the list button opens the drawer', () => {
    const list = makeListSource(listState([sid('s1'), sid('s2')], undefined))
    const { view } = renderMobile(list)

    expect(view.container.textContent).toContain('选择或新建一个会话开始')
    expect(view.container.textContent).not.toContain('CONV-CONTENT')
    fireEvent.click(view.getByText('打开会话列表'))
    expect(drawerRoot(view).getAttribute('data-open')).toBe('true')
    expect(within(drawer(view)).getByText('会话 s1')).toBeDefined()
    expect(within(drawer(view)).getByText('会话 s2')).toBeDefined()
    view.unmount()
  })

  it('tapping a drawer session opens its conversation and closes the drawer', () => {
    const list = makeListSource(listState([sid('s1')], undefined))
    const { view } = renderMobile(list)

    fireEvent.click(view.getByText('打开会话列表'))
    fireEvent.click(within(drawer(view)).getByText('会话 s1'))

    // openSession wrote the store's current; the home is now the conversation.
    expect(list.getSnapshot().current).toBe(sid('s1'))
    expect(view.container.textContent).toContain('CONV-CONTENT')
    expect(drawerRoot(view).getAttribute('data-open')).toBeNull()
    view.unmount()
  })

  it('the menu button toggles the drawer and the mask closes it', () => {
    const list = makeListSource(listState([sid('s1')], sid('s1')))
    const { view } = renderMobile(list)

    fireEvent.click(view.getByLabelText('打开会话列表'))
    expect(drawerRoot(view).getAttribute('data-open')).toBe('true')
    const mask = view.container.querySelector('[data-drawer-mask]')
    expect(mask).not.toBeNull()
    fireEvent.click(mask as Element)
    expect(drawerRoot(view).getAttribute('data-open')).toBeNull()
    view.unmount()
  })

  it('groups drawer sessions by workspace and starts a session from a workspace header', () => {
    const list = makeListSource(listState([sid('s1'), sid('s2'), sid('s3')], sid('s1')))
    const workspaces = makeWorkspacesSource({
      ...emptyWorkspacesState(),
      items: [
        { workspaceId: 'w1' as WorkspaceId, path: '/work/a', title: '工作区 A', sessionIds: [sid('s1'), sid('s2')], createdAt: '0', updatedAt: '0' },
      ],
    })
    const { view, startedSessions } = renderMobile(list, workspaces)

    fireEvent.click(view.getByLabelText('打开会话列表'))
    const panel = drawer(view)
    expect(within(panel).getByText('工作区 A')).toBeDefined()
    expect(within(panel).getByText('会话 s1')).toBeDefined()
    expect(within(panel).getByText('会话 s2')).toBeDefined()
    expect(within(panel).getByText('未分组')).toBeDefined()
    expect(within(panel).getByText('会话 s3')).toBeDefined()

    fireEvent.click(view.getByLabelText('在 工作区 A 中新建会话'))
    expect(startedSessions).toEqual(['w1'])
    view.unmount()
  })
    it('workspace groups collapse and expand from their header', () => {
      const list = makeListSource(listState([sid('s1'), sid('s2')], sid('s1')))
      const workspaces = makeWorkspacesSource({
        ...emptyWorkspacesState(),
        items: [
          { workspaceId: 'w1' as WorkspaceId, path: '/work/a', title: '工作区 A', sessionIds: [sid('s1'), sid('s2')], createdAt: '0', updatedAt: '0' },
        ],
      })
      const { view } = renderMobile(list, workspaces)

      fireEvent.click(view.getByLabelText('打开会话列表'))
      const panel = drawer(view)
      expect(within(panel).getByText('会话 s1')).toBeDefined()
      expect(within(panel).getByText('会话 s2')).toBeDefined()

      fireEvent.click(view.getByLabelText('折叠 工作区 A'))
      expect(view.getByLabelText('展开 工作区 A').getAttribute('aria-expanded')).toBe('false')

      fireEvent.click(view.getByLabelText('展开 工作区 A'))
      expect(view.getByLabelText('折叠 工作区 A').getAttribute('aria-expanded')).toBe('true')
      expect(within(panel).getByText('会话 s1')).toBeDefined()
      expect(within(panel).getByText('会话 s2')).toBeDefined()
      view.unmount()
    })

    it('previews five sessions per group and expands the rest in the outer drawer scroll', () => {
      const ids = [sid('s1'), sid('s2'), sid('s3'), sid('s4'), sid('s5'), sid('s6')]
      const list = makeListSource(listState(ids, sid('s1')))
      const workspaces = makeWorkspacesSource({
        ...emptyWorkspacesState(),
        items: [
          { workspaceId: 'w1' as WorkspaceId, path: '/work/a', title: '工作区 A', sessionIds: ids, createdAt: '0', updatedAt: '0' },
        ],
      })
      const { view } = renderMobile(list, workspaces)

      fireEvent.click(view.getByLabelText('打开会话列表'))
      const panel = drawer(view)
      for (const id of ids.slice(0, 5)) {
        expect(within(panel).getByText(`会话 ${id}`)).toBeDefined()
      }
      expect(within(panel).queryByText('会话 s6')).toBeNull()

      fireEvent.click(view.getByLabelText('显示全部 工作区 A'))
      expect(within(panel).getByText('会话 s6')).toBeDefined()

      fireEvent.click(view.getByLabelText('收起 工作区 A'))
      expect(within(panel).queryByText('会话 s6')).toBeNull()
      view.unmount()
    })

    it('notifies for a pending approval through the native system-notification bridge', () => {
      const state = listState([sid('s1')], sid('s1'))
      state.byId[sid('s1')] = { ...state.byId[sid('s1')]!, pendingInteraction: 'approval' }
      const list = makeListSource(state)
      const { view } = renderMobile(list)

      expect(dshNoticePosts).toEqual([{ title: '会话 s1', body: '需要审批', sessionId: sid('s1') }])
      // No in-app banner: the notification lives in the OS notification bar.
      expect(view.queryByText('需要审批')).toBeNull()
      view.unmount()
    })

    it('notifies through the system bar when an unselected session completes', async () => {
      const list = makeListSource(listState([sid('s1')], sid('s1')))
      const { view } = renderMobile(list)

      await act(async () => {
        const prev = list.getSnapshot()
        list.set({
          ...prev,
          byId: {
            ...prev.byId,
            [sid('s1')]: { ...prev.byId[sid('s1')]!, completed: true },
          },
        })
      })

      expect(dshNoticePosts).toEqual([{ title: '会话 s1', body: '任务完成', sessionId: sid('s1') }])
      expect(view.queryByText('任务完成')).toBeNull()
      view.unmount()
    })

    it('notifies through the system bar when a background job finishes', async () => {
      const list = makeListSource(listState([sid('s1')], sid('s1')))
      const { view } = renderMobile(list)

      await act(async () => {
        const prev = list.getSnapshot()
        list.set({
          ...prev,
          byId: {
            ...prev.byId,
            [sid('s1')]: { ...prev.byId[sid('s1')]!, running: true },
          },
          jobsBySession: {
            [sid('s1')]: [{ id: 'bash-1' as never, kind: 'bash', label: 'npm test', status: 'completed', startedAt: 1, finishedAt: 2 }],
          },
        })
      })

      expect(dshNoticePosts).toEqual([
        { title: '会话 s1', body: 'npm test · 任务完成', sessionId: sid('s1') },
      ])
      expect(view.queryByText(/npm test/)).toBeNull()
      view.unmount()
    })


  it('drawer footer opens settings; plan/goal are explained and opened from settings', () => {
    const list = makeListSource(listState([sid('s1')], sid('s1')))
    const { view } = renderMobile(list)

    fireEvent.click(view.getByLabelText('打开会话列表'))
    fireEvent.click(within(drawer(view)).getByText('设置'))
    expect(view.container.textContent).toContain('连接状态')
    expect(view.container.textContent).toContain('当前工作区')

    fireEvent.click(view.getByText('计划模式'))
    expect(view.container.textContent).toContain('打开一个会话后，在这里查看它的计划模式状态。')
    fireEvent.click(view.getByLabelText('返回'))
    expect(view.container.textContent).toContain('CONV-CONTENT')

    fireEvent.click(view.getByLabelText('打开会话列表'))
    fireEvent.click(within(drawer(view)).getByText('设置'))
    fireEvent.click(view.getByText('目标'))
    expect(view.container.textContent).toContain('打开一个会话后，在这里查看和管理它的目标。')
    fireEvent.click(view.getByLabelText('返回'))
    expect(view.container.textContent).toContain('CONV-CONTENT')
    view.unmount()
  })

  it('system back closes the drawer (history-backed navigation)', async () => {
    const list = makeListSource(listState([sid('s1')], sid('s1')))
    const { view } = renderMobile(list)

    fireEvent.click(view.getByLabelText('打开会话列表'))
    expect(drawerRoot(view).getAttribute('data-open')).toBe('true')

    await act(async () => {
      window.history.back()
      await new Promise(resolve => { setTimeout(resolve, 20) })
    })
    expect(drawerRoot(view).getAttribute('data-open')).toBeNull()
    expect(view.container.textContent).toContain('CONV-CONTENT')
    view.unmount()
  })

  it('system back returns from a pushed settings page to the conversation home', async () => {
    const list = makeListSource(listState([sid('s1')], sid('s1')))
    const { view } = renderMobile(list)

    fireEvent.click(view.getByLabelText('打开会话列表'))
    fireEvent.click(within(drawer(view)).getByText('设置'))
    expect(view.container.textContent).toContain('连接状态')
    expect(view.container.textContent).not.toContain('CONV-CONTENT')

    await act(async () => {
      window.history.back()
      await new Promise(resolve => { setTimeout(resolve, 20) })
    })
    expect(view.container.textContent).toContain('CONV-CONTENT')
    expect(view.container.textContent).not.toContain('连接状态')
    view.unmount()
  })

  it('renders the conversation column even when the current session has no list row', () => {
    const list = makeListSource({ ...listState([], undefined), current: sid('ghost') })
    const { view } = renderMobile(list)

    expect(view.getByLabelText('打开会话列表')).toBeDefined()
    expect(view.container.textContent).toContain('CONV-CONTENT')
    view.unmount()
  })

  it('ignores edge swipes and opens the drawer from a middle-band rightward swipe', () => {
    const list = makeListSource(listState([sid('s1')], sid('s1')))
    const { view } = renderMobile(list)
    const shell = view.container.querySelector('[data-mobile-shell]')
    expect(shell).not.toBeNull()

    // Left edge belongs to the OS back gesture: ignored by the shell.
    fireEvent.touchStart(shell as Element, { touches: [{ clientX: 10, clientY: 80 }] })
    fireEvent.touchEnd(shell as Element, { changedTouches: [{ clientX: 180, clientY: 84 }] })
    expect(drawerRoot(view).getAttribute('data-open')).toBeNull()

    // Middle of the screen opens the drawer.
    fireEvent.touchStart(shell as Element, { touches: [{ clientX: 512, clientY: 80 }] })
    fireEvent.touchEnd(shell as Element, { changedTouches: [{ clientX: 632, clientY: 84 }] })
    expect(drawerRoot(view).getAttribute('data-open')).toBe('true')
    view.unmount()
  })

  it('shows the connecting state in settings while the list is pending', () => {
    const list = makeListSource({ ...listState([], undefined), phase: 'pending' as const })
    const hook = (sel: (s: SessionListState) => unknown): unknown => sel(list.getSnapshot())
    const workspaces = makeWorkspacesSource(emptyWorkspacesState())
    const view = render(
      <SettingsPage
        useSessions={hook as never}
        workspaces={stubInjected(list, workspaces).workspaces}
        onOpenPlan={() => {}}
        onOpenGoal={() => {}}
        onBack={() => {}}
      />)
    expect(view.container.textContent).toContain('连接中')
    view.unmount()
  })

  it('renders the plan status card from a live projection face', () => {
    const state = listState([sid('s1')], sid('s1'))
    const list = makeListSource(state)
    const hook = (sel: (s: SessionListState) => unknown): unknown => sel(list.getSnapshot())
    const face = (value: { active: boolean; pending: boolean }): unknown => ({
      subscribe: () => () => {},
      getSnapshot: () => value,
    })
    const on = render(<PlanPage useSessions={hook as never} projection={() => face({ active: true, pending: false }) as never} onBack={() => {}} />)
    expect(on.container.textContent).toContain('计划模式已开启')
    expect(on.container.textContent).not.toContain('正在切换')
    on.unmount()
    const off = render(<PlanPage useSessions={hook as never} projection={() => face({ active: false, pending: true }) as never} onBack={() => {}} />)
    expect(off.container.textContent).toContain('计划模式已关闭')
    expect(off.container.textContent).toContain('正在切换')
    off.unmount()
  })

  it('renders the goal strip from a live projection face', async () => {
    const state = listState([sid('s1')], sid('s1'))
    const list = makeListSource(state)
    const hook = (sel: (s: SessionListState) => unknown): unknown => sel(list.getSnapshot())
    // The snapshot must be a stable reference: useSyncExternalStore re-renders
    // whenever getSnapshot returns a different object identity.
    const snapshot = {
      goal: { id: 'g1' as never, revision: 1, objective: 'ship it', phase: 'active' as const, maxGoalRounds: 3 },
      roundsStarted: 1,
      createdAt: 1,
      updatedAt: 1,
    }
    const projection = (): unknown => ({
      subscribe: () => () => {},
      getSnapshot: () => snapshot,
    })
    const view = render(<GoalPage useSessions={hook as never} projection={projection as never} goal={stubInjected(list).goal} onBack={() => {}} />)
    expect(view.container.textContent).toContain('ship it')
    // Drive the strip's icon actions through the composed verb closures.
    fireEvent.click(view.getByLabelText('action.edit'))
    fireEvent.change(view.getByLabelText('objective.aria'), { target: { value: 'new objective' } })
    fireEvent.click(view.getByLabelText('action.save'))
    await act(async () => {})
    fireEvent.click(view.getByLabelText('action.cancel'))
    fireEvent.click(view.getByLabelText('action.pause'))
    await act(async () => {})
    fireEvent.click(view.getByLabelText('action.clear'))
    await act(async () => {})
    view.unmount()

    // A null projection (cleared goal) renders the empty body hint.
    const nullProjection = (): unknown => ({
      subscribe: () => () => {},
      getSnapshot: () => null,
    })
    const cleared = render(<GoalPage useSessions={hook as never} projection={nullProjection as never} goal={stubInjected(list).goal} onBack={() => {}} />)
    expect(cleared.container.textContent).toContain('目标条也会显示在会话输入框上方')
    cleared.unmount()

    // A paused goal exposes the resume action (the remaining verb closure).
    const pausedSnapshot = {
      goal: { id: 'g1' as never, revision: 2, objective: 'ship it', phase: 'paused' as const, maxGoalRounds: 3 },
      roundsStarted: 1,
      createdAt: 1,
      updatedAt: 2,
    }
    const pausedProjection = (): unknown => ({
      subscribe: () => () => {},
      getSnapshot: () => pausedSnapshot,
    })
    const paused = render(<GoalPage useSessions={hook as never} projection={pausedProjection as never} goal={stubInjected(list).goal} onBack={() => {}} />)
    fireEvent.click(paused.getByLabelText('action.resume'))
    await act(async () => {})
    paused.unmount()
  })

  it('plan/goal pages show their hints when opened from settings with no session current', () => {
    const list = makeListSource(listState([], undefined))
    const { view } = renderMobile(list)

    fireEvent.click(view.getByText('打开会话列表'))
    fireEvent.click(within(drawer(view)).getByText('设置'))
    fireEvent.click(view.getByText('计划模式'))
    expect(view.container.textContent).toContain('打开一个会话后，在这里查看它的计划模式状态。')
    fireEvent.click(view.getByLabelText('返回'))

    fireEvent.click(view.getByText('打开会话列表'))
    fireEvent.click(within(drawer(view)).getByText('设置'))
    fireEvent.click(view.getByText('目标'))
    expect(view.container.textContent).toContain('打开一个会话后，在这里查看和管理它的目标。')
    view.unmount()
  })

  it('keeps the desktop root slot unrendered even when only the mobile frame is rendered (root stays inert)', async () => {
    const core = new SlotCore()
    const list = makeListSource(listState([sid('s1')], undefined))
    const workspaces = makeWorkspacesSource(emptyWorkspacesState())
    registerDesktop(core)
    registerMobile(core, list, workspaces, [])
    const renderer = createSlotRenderer({ rootKey: 'mobile-frame' })
    const view = render(<>{renderer.renderRoot(hostOver(core, list), {})}</>)
    // The desktop frame entry stays in the ledger but nothing renders it.
    expect(core.entriesOfSlot('root').length).toBe(1)
    // A mutation on a desktop seat does not leak into the mobile tree.
    await act(async () => { core.register({ name: 'sidebar' }, () => <div>desktop-sidebar</div>) })
    expect(view.container.querySelector('[data-mobile-shell]')).not.toBeNull()
    expect(view.container.textContent).not.toContain('desktop-sidebar')
    view.unmount()
  })
})
