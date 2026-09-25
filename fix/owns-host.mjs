/**
 * Reverse-proxy companion for a containerized `dsh web`.
 *
 * Two jobs, both of them things the stock composition cannot do once the GUI is
 * reached through an external authority instead of 127.0.0.1:
 *
 * 1. Remote Settings must stay writable. `isLoopback` is a client-side value
 *    (packages/client/connection/src/client/index.ts: `isLoopback:
 *    transport?.ownsHost === true || …`), and the two consumers that matter —
 *    ui-settings (`persistence = isLoopback ? 'host' : 'memory'`) and
 *    ui-settings-general — turn every describe/mutate into a no-op under
 *    'memory'. There is NO server-side loopback gate on the settings RPC
 *    (verified live: `settings/describe` over the public Host answers
 *    `{writable:true}`, and a write reaches the business rules). The supported
 *    seam is the same `webserver/index-inject` event upstream's own client
 *    plugins publish globals through. `ownsHost` is the documented flag for a
 *    shell that owns its transport; the served page reads only `loadBundle` and
 *    `streamBaseUrl` off this global, and this plugin supplies neither, so
 *    bundling and streaming are untouched.
 *
 * 2. The operator must be able to open the GUI. Upstream prints
 *    `http://127.0.0.1:<port>/?token=…`, which is unreachable through the
 *    proxy, and the launch token rotates on every start. `authenticatedUrl` is
 *    public API on the connection service; pointing it at $DSH_PUBLIC_HOST
 *    prints the URL that actually works.
 */

/** Service name of the browser-connection owner that mints the launch token. */
const CONNECTION_SERVICE = 'connection'

/** Environment variable naming the external authority, e.g. `dsh.example.com`. */
const PUBLIC_HOST_ENV = 'DSH_PUBLIC_HOST'

/**
 * Publish the transport flag on every index render.
 * @param ctx - plugin context carrying the web server service.
 */
export function apply(ctx) {
  ctx.on('webserver/index-inject', (table) => {
    table.push({ kind: 'global', name: '__DSH_TRANSPORT__', value: { ownsHost: true } })
  })

  const publicHost = process.env[PUBLIC_HOST_ENV]?.trim()
  if (!publicHost) return

  let announced = false
  ctx.inject([CONNECTION_SERVICE], (connectionCtx) => {
    if (announced) return
    announced = true
    const url = connectionCtx[CONNECTION_SERVICE].authenticatedUrl(`https://${publicHost}/`)
    // console.log, not ctx.logger: upstream prints this same line that way
    // (packages/bundle/web-app/src/index.ts), and logger.info is below the
    // default level, so it never reaches `docker logs`.
    console.log(`dsh web (proxy): ${url}`)
  })
}
