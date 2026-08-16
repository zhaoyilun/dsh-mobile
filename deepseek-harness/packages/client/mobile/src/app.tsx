/**
 * Real-UI assembly closure, invoked by the mobile app-shell plugin once its
 * inject set is active: the whole mobile tree hangs off the mobile 'mobile-frame'
 * slot (the frame registers there and composes the pages internally). The
 * desktop 'root' slot is never rendered — the desktop frame registered into it
 * stays inert. This mirrors the desktop shell's app.tsx; the render entry is
 * the only divergence. The browser-title projection is a minimal local
 * equivalent of the desktop shell's DocumentTitle (which is not exported from
 * the web package's bundle entry, so it cannot be imported here).
 */
import { useEffect, useRef } from 'react'
import type { ReactNode } from 'react'
import type { Context } from '@deepseek-ai/cordis'
import { bindSnapshotSelector } from '@deepseek-ai/dsh-client-web-react'
// Type-only: pulls the mobile SlotMap merge ('mobile-frame') into this program.
import type {} from './slots.ts'

/** Assembly inputs: the active mobile app-shell plugin ctx (slots/sessions/layout services provided). */
export interface AssemblyDeps {
  /** Client context with the assembly's inject set active. */
  ctx: Context
}

/** Project the selected session's durable title into the document title (restored on unmount). */
function MobileDocumentTitle({ title }: { title: string | undefined }): null {
  const original = useRef(document.title)
  useEffect(() => {
    document.title = title === undefined ? original.current : `${title} — ${original.current}`
    return () => { document.title = original.current }
  }, [title])
  return null
}

/**
 * Build the renderApp factory the mobile app-shell plugin provides to AppRoot.
 * @param deps - assembly inputs.
 * @returns factory producing the real mobile UI tree (called once per AppRoot render after settled).
 */
export function buildMobileRenderApp(deps: AssemblyDeps): () => ReactNode {
  const { ctx } = deps
  const sessions = ctx.get('sessions')
  if (sessions === undefined) throw new Error('mobile shell assembly: sessions service unavailable')
  const useSessions = bindSnapshotSelector(sessions.list)
  const SessionDocumentTitle = (): ReactNode => {
    const title = useSessions((state) => {
      const id = state.current
      return id === undefined ? undefined : state.byId[id]?.title
    })
    return <MobileDocumentTitle title={title} />
  }
  return () => (
    <>
      <SessionDocumentTitle />
      {ctx.slots.renderSlot('mobile-frame', {})}
    </>
  )
}
