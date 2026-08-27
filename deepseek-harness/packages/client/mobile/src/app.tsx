/**
 * Mobile real-UI assembly: the whole mobile tree is the built-in root slot,
 * occupied by MobileFrame (registered by the mobile app-shell). This mirrors
 * the upstream ui-renderer app.tsx but keeps the assembly in the mobile shell
 * package.
 */
import type { ReactNode } from 'react'
import type { Context } from '@deepseek-ai/cordis'

/** Assembly inputs. */
export interface AssemblyDeps {
  ctx: Context
}

/** Build the mobile render factory for the root slot. */
export function buildMobileRenderApp(deps: AssemblyDeps): () => ReactNode {
  const { ctx } = deps
  return () => ctx.slots.renderSlot('root', {})
}
