/**
 * Reverse-proxy companion for a containerized `dsh web`: keeps the remote
 * Settings UI writable once the GUI is reached through an external authority
 * instead of 127.0.0.1.
 *
 * `isLoopback` is a client-side value
 * (packages/client/connection/src/client/index.ts: `isLoopback:
 * transport?.ownsHost === true || …`, unchanged through 0.2.2-rc.1), and the
 * settings UI keys off it: ui-settings-general builds its settings document
 * store only when it is true (0.2.2-rc.1 lib/client.js), so off loopback every
 * describe/mutate is a no-op. There is NO server-side loopback gate on the settings RPC (verified
 * live: `settings/describe` over the public Host answers `{writable:true}`, and
 * a write reaches the business rules). The supported seam is the same
 * `webserver/index-inject` event upstream's own client plugins publish globals
 * through. `ownsHost` is the documented flag for a shell that owns its
 * transport; the served page reads only `loadBundle` and `streamBaseUrl` off
 * this global, and this plugin supplies neither, so bundling and streaming are
 * untouched.
 *
 * The public login URL is upstream's job now: the entrypoint passes
 * `--public-url https://$DSH_PUBLIC_HOST/`, which prints the tokenized URL.
 */

/**
 * Publish the transport flag on every index render.
 * @param ctx - plugin context carrying the web server service.
 */
export function apply(ctx) {
  ctx.on('webserver/index-inject', (table) => {
    table.push({ kind: 'global', name: '__DSH_TRANSPORT__', value: { ownsHost: true } })
  })
}
