/**
 * The web app's command-line provider: it parses the `dsh --profile web` flag
 * family (`--host`, `--port`, `--trusted-host`) and its `--help`
 * text, then provides the immutable values as {@link WEB_STARTUP_SERVICE}.
 * Ordinary rows inject that service before reading it from lazy config.
 * @module @deepseek-ai/dsh-web-app/startup
 */

import { Command } from 'commander'
import type { Context } from '@deepseek-ai/cordis'
import { parseCmdline } from '@deepseek-ai/dsh-cmdline'

/** Stable Cordis plugin name. */
export const name = 'web-startup'

/** Services required before the flags can be resolved. */
export const inject = ['cmdlineArgs']

/** Service provided by this ordinary plugin and injected by flag-configured rows. */
export const WEB_STARTUP_SERVICE = 'webStartup'

/** What the web rows read from {@link WEB_STARTUP_SERVICE}. */
export interface WebStartupValues {
  /** `--host`, absent when the invocation did not name one. */
  host?: string
  /** `--port`, absent when the invocation did not name one. */
  port?: number
  /** Explicit `--trusted-host` authorities, in argument order. */
  trustedHosts: string[]
  /**
   * `--web-token`, falling back to `DSH_WEB_TOKEN`; absent when neither
   * names one (empty `DSH_WEB_TOKEN` counts as unset).
   */
  webToken?: string
}

/** The web flag family, as commander parsed it. */
interface WebOptions {
  host?: string
  port?: string
  trustedHost?: string[]
  webToken?: string
}

/**
 * This app's command: its flags, its description, and its help text.
 * @returns a fresh program, so one process can parse more than once (tests).
 */
function webCommand(): Command {
  return new Command()
    .name('dsh --profile web')
    .description('Serve the DeepSeek Harness browser UI.')
    .helpOption('-h, --help', 'show this help')
    .option('--host <host>', 'bind host; 0.0.0.0 (all interfaces) requires --web-token or DSH_WEB_TOKEN')
    .option('--port <port>', 'listen port; pass 0 to let the OS pick a free one')
    .option('--trusted-host <authority...>', 'extra authority the /api browser-trust fence accepts (host or host:port; repeatable)')
    .option('--web-token <token>', 'require this token from non-loopback clients and enable phone pairing (defaults to DSH_WEB_TOKEN)')
    .addHelpText('after', `
Examples:
  dsh --profile web                          serve on the composed host and port
  dsh --profile web --port 8080              serve on another port
  dsh --profile web --web-token secret       require the token and print the pairing QR
  dsh --profile web --host 0.0.0.0 --web-token secret   serve the phone over LAN with the pairing QR
`)
}

/**
 * Parse and provide the Web invocation as an ordinary Cordis service. The
 * command's action publishes the flags this invocation named; `--host 0.0.0.0`
 * without a configured token and a non-numeric `--port` are usage errors, so on
 * rejection (and on `--help`) nothing is provided. Binding all interfaces is
 * only accepted together with a web token, because the request guard installed
 * from that token is the only authentication on the exposed surface.
 * @param ctx - plugin context carrying the command line.
 */
export function apply(ctx: Context): void {
  const program = webCommand()
  program.action(() => {
    const options = program.opts<WebOptions>()
    // The CLI flag wins; the environment variable only supplies the default.
    const webToken = options.webToken ?? (process.env.DSH_WEB_TOKEN || undefined)
    if (options.host === '0.0.0.0' && webToken === undefined) {
      program.error('error: --host 0.0.0.0 requires authentication: pass --web-token <token> or set DSH_WEB_TOKEN before binding all interfaces')
    }
    if (options.port !== undefined && !/^\d+$/.test(options.port)) {
      program.error(`error: --port must be a number, got ${JSON.stringify(options.port)}`)
    }
    ctx.provide(WEB_STARTUP_SERVICE, {
      ...options.host !== undefined && { host: options.host },
      ...options.port !== undefined && { port: Number(options.port) },
      ...webToken !== undefined && { webToken },
      trustedHosts: options.trustedHost ?? [],
    } satisfies WebStartupValues)
  })
  parseCmdline(ctx, program)
}
