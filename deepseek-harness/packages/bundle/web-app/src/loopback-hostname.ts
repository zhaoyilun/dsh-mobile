/**
 * Whether a normalized URL hostname names the local loopback authority.
 * Copied from `@deepseek-ai/dsh-client-connection`'s internal
 * `src/loopback-hostname.ts` (that package does not re-export it from its
 * root); keep the two copies in sync.
 * @param hostname - WHATWG URL hostname (IPv6 literals retain brackets).
 * @returns true for localhost, IPv6 loopback, or any IPv4 address in 127/8.
 */
export function isLoopbackHostname(hostname: string): boolean {
  if (hostname === 'localhost' || hostname === '[::1]') return true
  const parts = hostname.split('.')
  return parts.length === 4
    && parts[0] === '127'
    && parts.every(part => /^\d{1,3}$/.test(part) && Number(part) <= 255)
}
