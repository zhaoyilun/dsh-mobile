/**
 * Mobile shell slot declarations: the mobile frame's render-tree root hole.
 * The desktop shell renders the built-in 'root' slot (occupied by ui-layout's
 * AppFrame, which declares the desktop column seats); the mobile shell renders
 * 'mobile-frame' instead, so the desktop frame registered into 'root' stays
 * inert — one client composition, two shells. The runtime declaration happens
 * through the mobile app-shell assembly's register children table (declaring
 * is claiming, exactly like the desktop frame); this module only merges the
 * type.
 */

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface SlotMap {
    /**
     * The mobile shell's render-tree root hole (the one slot the mobile shell
     * renders; the desktop shell renders the built-in 'root'). OCCUPIED by
     * the mobile package's MobileFrame, which composes the ChatGPT-style
     * mobile layout — conversation home with the embedded desktop
     * 'conversation' column, the session list in a left drawer, and the
     * plan/goal/settings pushed pages.
     */
    'mobile-frame': { kind: 'single'; scope: 'root'; owner: MobileFrameOwnerProps }
  }
}

/** Mobile frame owner share: the shell supplies nothing — the frame is inject-assembled. */
export interface MobileFrameOwnerProps { children?: never }
