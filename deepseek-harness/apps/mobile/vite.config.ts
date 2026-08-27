import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import type { Plugin } from 'vite'
import react from '@vitejs/plugin-react'

const src = (rel: string): string => fileURLToPath(new URL(rel, import.meta.url))
const STANDALONE_ERROR = 'apps/mobile is not a standalone application: bare Vite cannot inject window.__DSH_BOOT__. '
  + 'From a repository checkout, run `pnpm dsh web` and open http://<host>:<port>/m; '
  + 'an installed package uses `dsh web` the same way.'

/** Fail before a Vite dev or preview server can expose the boot-manifest-free shell. */
function rejectStandaloneServe(): Plugin {
  return {
    name: 'dsh-reject-standalone-mobile-serve',
    config(_config, env) {
      if (env.command === 'serve') throw new Error(STANDALONE_ERROR)
    },
  }
}

/**
 * Vendor-chunk membership, by exact npm package name — the heavy render
 * families (math, highlight, markdown) that change only on dependency bumps.
 * Identical to apps/web: the mobile shell embeds the same ui-primitives
 * markdown/math machinery through the shared platform words.
 */
const VENDOR_PACKAGES: ReadonlySet<string> = new Set([
  'katex',
  'shiki',
  'mdast-util-from-markdown',
  'mdast-util-gfm',
  'mdast-util-math',
  'micromark-core-commonmark',
  'micromark-extension-gfm',
  'micromark-extension-math',
  'micromark-factory-space',
  'micromark-util-character',
  'micromark-util-classify-character',
  'micromark-util-sanitize-uri',
  'micromark-util-symbol',
  'micromark-util-types',
])

/** Boot grammars statically imported by ui-primitives' highlight.ts (same set as apps/web). */
const BOOT_GRAMMAR_FILES: readonly string[] = [
  'dist/typescript.mjs',
  'dist/shellscript.mjs',
  'dist/json.mjs',
]

/** Font asset extensions routed to assets/fonts/ (KaTeX's woff2/woff/ttf faces). */
const FONT_EXTENSIONS: readonly string[] = ['.woff2', '.woff', '.ttf']

/** npm package name of a resolved module id: the segment after the last `node_modules/`. */
function npmPackageOf(id: string): string | undefined {
  const parts = id.split('/node_modules/')
  if (parts.length === 1) return undefined
  const [first, second] = parts[parts.length - 1].split('/')
  if (first.startsWith('.')) return undefined
  if (first.startsWith('@')) return second === undefined ? undefined : `${first}/${second}`
  return first
}

export default defineConfig({
  // The dist is served under /m by dsh web's frontend-static prefix row:
  // every built asset URL must carry the /m prefix or the mounted shell 404s.
  base: '/m/',
  plugins: [rejectStandaloneServe(), react()],
  build: {
    sourcemap: true,
    rollupOptions: {
      output: {
        chunkFileNames(chunk): string {
          if (chunk.name === 'index' || chunk.name === 'vendor') return 'assets/[name]-[hash].js'
          const isLangChunk = chunk.moduleIds.some(id => id.includes('/node_modules/@shikijs/langs/'))
          return isLangChunk ? 'assets/langs/[name]-[hash].js' : 'assets/[name]-[hash].js'
        },
        assetFileNames(asset): string {
          const fileName = asset.names[0] ?? ''
          const isFont = FONT_EXTENSIONS.some(ext => fileName.endsWith(ext))
          return isFont ? 'assets/fonts/[name]-[hash][extname]' : 'assets/[name]-[hash][extname]'
        },
        manualChunks(id: string): string | undefined {
          const pkg = npmPackageOf(id)
          if (pkg === undefined) return undefined
          if (pkg === '@shikijs/langs') {
            return BOOT_GRAMMAR_FILES.some(file => id.endsWith(`/${file}`)) ? 'vendor' : undefined
          }
          return VENDOR_PACKAGES.has(pkg) ? 'vendor' : undefined
        },
      },
    },
  },
  resolve: {
    // Workspace packages resolve to SOURCE (identical rationale to apps/web):
    // package.json exports point at lib for Node/type consumers, but the
    // browser bundle must compile src directly so CSS rides vite's pipeline.
    // The mobile shell is the only shell-side import; plugin packages arrive
    // as runtime bundles through the client module system — except the goal
    // strip, which the mobile goal page imports as a component (the brief's
    // sanctioned "import then wrap" path), so it is aliased to src too.
    alias: [
      { find: /^node:module$/, replacement: src('./src/node-module-stub.ts') },
      { find: /^@deepseek-ai\/cordis$/, replacement: src('../../vendor/cordis/src/index.ts') },
      { find: /^@deepseek-ai\/cordis-plugin-loader$/, replacement: src('../../vendor/loader/src/index.ts') },
      { find: /^@deepseek-ai\/cosmokit$/, replacement: src('../../vendor/cosmokit/src/index.ts') },
      { find: /^@deepseek-ai\/dsh-client-mobile$/, replacement: src('../../packages/client/mobile/src/boot.tsx') },
      // The mobile shell consumes the web shell as a LIBRARY (boot kernel
      // pieces: AppRoot, loader-status, seed table), so the package root maps
      // to the web library entry — not its boot entry like apps/web does.
      { find: /^@deepseek-ai\/dsh-client-web$/, replacement: src('../../packages/client/web/src/index.ts') },
      { find: /^@deepseek-ai\/dsh-client-ui-slots$/, replacement: src('../../packages/client/ui-slots/src/index.ts') },
      { find: /^@deepseek-ai\/dsh-client-ui-primitives$/, replacement: src('../../packages/client/ui-primitives/src/index.ts') },
      { find: /^@deepseek-ai\/dsh-client-ui-attachment$/, replacement: src('../../packages/client/ui-attachment/src/index.ts') },
      { find: /^@deepseek-ai\/dsh-client-schema-form$/, replacement: src('../../packages/client/schema-form/src/index.ts') },
      { find: /^@deepseek-ai\/dsh-client-ui-goal\/client$/, replacement: src('../../packages/client/ui-goal/src/client/index.ts') },
      { find: /^@deepseek-ai\/dsh-client-modules\/client$/, replacement: src('../../packages/client/modules/src/client/index.ts') },
    ],
  },
  define: {
    'process.versions.node': '"0.0.0"',
    'process.execArgv': '[]',
    'process.env.CORDIS_SHARED': 'undefined',
  },
})
