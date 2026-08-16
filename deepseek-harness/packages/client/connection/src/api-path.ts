/**
 * The /api URL prefix — single source for both halves of the web transport.
 * The node half registers this prefix on the web server; both halves share the
 * event paths below for the browser WebSocket downlinks.
 */

/** Route prefix owning every api request (`/api` and `/api/<anything>`). */
export const API_PATH = '/api'

/** Browser mux-frame WebSocket pathname. */
export const MUX_EVENTS_PATH = `${API_PATH}/events.mux`

/** Browser host-frame WebSocket pathname. */
export const HOST_EVENTS_PATH = `${API_PATH}/events.host`

/**
 * One-time upgrade-ticket pathname: a cookie-authenticated GET mints a
 * single-use ticket the browser presents on the WebSocket handshake
 * (`?ticket=`). Android WebViews do not attach cookies to WebSocket
 * handshakes, so the upgrade needs a credential the page can carry in the URL;
 * fetch on the same origin still sends cookies everywhere, making the ticket
 * fetch the one transport that works across browsers and WebViews alike.
 */
export const WS_TICKET_PATH = '/ws-ticket'
