/**
 * Package-owned invariant companion for `@deepseek-ai/dsh-client-mobile`.
 * @module @deepseek-ai/dsh-client-mobile/invariant
 */

/* jscpd:ignore-start */
import type { Context } from '@deepseek-ai/cordis'
import type { InvariantInstaller } from '@deepseek-ai/dsh-invariants'

const PACKAGE_NAME = '@deepseek-ai/dsh-client-mobile'

/** Cordis companion plugin name. */
export const name = 'client-mobile-invariant'
/** Service required before the companion can reserve package ownership. */
export const inject = ['invariants']

/**
 * No runtime invariant: the mobile vite-entry shell — boot glue, the frame
 * slot registration, and presentation pages with no cordis events and no
 * cross-plugin mutable state. The mobile-frame-inert / desktop-root-inert
 * relationship is asserted by the package's component fixture against the real
 * slot registry (render 'mobile-frame', assert the desktop 'root' content
 * stays absent).
 */
const install: InvariantInstaller = () => {}

/**
 * Register this package's invariant companion.
 * @param ctx - Cordis context carrying the invariant service.
 * @returns the installed registration's disposer after setup succeeds.
 */
export const apply = (ctx: Context): Promise<() => void> =>
  Promise.resolve(ctx.invariants.register(PACKAGE_NAME, install))
/* jscpd:ignore-end */
