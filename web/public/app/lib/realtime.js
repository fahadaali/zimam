// Realtime sync (api/DEVELOPMENT.md, «المزامنة اللحظية»): a WebSocket on which the server only
// says "something you can see changed" ({"type":"changed","seq":N}). The app then reloads what it
// shows from the REST API, which stays the source of truth; a missed message costs only freshness.
//
// Browsers cannot send the session token on a WebSocket, so each connection first asks for a
// single-use ticket (POST /v1/realtime/ticket). The socket closes while the tab stays hidden and
// reopens, with a refresh for what was missed, when the tab is seen again.

const PING_EVERY = 30_000; // keeps proxies from closing an idle socket; the server answers "pong"
const HIDDEN_GRACE = 30_000; // a quick tab switch keeps the socket
const MAX_DELAY = 60_000;
/** The server closes a socket with this code when its session ends (sign-out, account deletion). */
export const SIGNED_OUT = 4001;

/** Wait before reconnect attempt `n` (1, 2, …): doubling from about a second up to a minute, jittered. */
export function backoffDelay(attempt, random = Math.random) {
  const ceiling = Math.min(MAX_DELAY, 1000 * 2 ** Math.max(0, attempt - 1));
  return Math.round(ceiling / 2 + (random() * ceiling) / 2);
}

/** The socket URL for an API base URL (https → wss) and a ticket. */
export function realtimeUrl(apiBase, ticket) {
  const url = new URL("/v1/realtime", apiBase);
  url.protocol = url.protocol === "http:" ? "ws:" : "wss:";
  url.searchParams.set("ticket", ticket);
  return url.toString();
}

/** The seq of a "changed" message, or null for anything else ("pong", unknown types). */
export function changedSeq(data) {
  if (typeof data !== "string" || !data.startsWith("{")) return null;
  try {
    const message = JSON.parse(data);
    return message?.type === "changed" && Number.isInteger(message.seq) ? message.seq : null;
  } catch {
    return null;
  }
}

/**
 * Keeps one socket open while started and the tab is visible. `onChange(seq)` is called for each
 * "changed" message, and with null after a reconnect or a server-side sign-out (time to reload).
 * `getTicket()` resolves to `{ ticket }`; a 401 from it stops the channel (the API client already
 * returns to sign-in).
 */
export function createRealtime({ getTicket, urlFor, onChange }) {
  let wanted = false;
  let socket = null;
  let connecting = false;
  let generation = 0; // bumps on every disconnect, so a ticket that arrives late is dropped
  let attempt = 0;
  let connectedBefore = false;
  let retryTimer;
  let pingTimer;
  let hiddenTimer;
  let listening = false;

  async function connect() {
    if (!wanted || socket || connecting || document.hidden) return;
    clearTimeout(retryTimer);
    connecting = true;
    const current = ++generation;
    let ticket;
    try {
      ({ ticket } = await getTicket());
    } catch (error) {
      connecting = false;
      if (error?.status === 401) wanted = false;
      else if (current === generation) retry();
      return;
    }
    connecting = false;
    if (current !== generation || !wanted || document.hidden) return;

    let ws;
    try {
      ws = new WebSocket(urlFor(ticket));
    } catch {
      retry();
      return;
    }
    socket = ws;
    ws.addEventListener("open", () => {
      attempt = 0;
      clearInterval(pingTimer);
      pingTimer = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) ws.send("ping");
      }, PING_EVERY);
      // Whatever changed while the socket was down was never announced.
      if (connectedBefore) onChange(null);
      connectedBefore = true;
    });
    ws.addEventListener("message", (event) => {
      const seq = changedSeq(event.data);
      if (seq !== null) onChange(seq);
    });
    ws.addEventListener("close", (event) => {
      if (socket !== ws) return;
      socket = null;
      clearInterval(pingTimer);
      if (event.code === SIGNED_OUT) {
        // Signed out elsewhere: the reload meets a 401, which returns to sign-in.
        wanted = false;
        onChange(null);
        return;
      }
      if (wanted && !document.hidden) retry();
    });
  }

  function retry() {
    clearTimeout(retryTimer);
    attempt += 1;
    retryTimer = setTimeout(connect, backoffDelay(attempt));
  }

  function disconnect() {
    generation += 1;
    connecting = false;
    clearTimeout(retryTimer);
    clearTimeout(hiddenTimer);
    clearInterval(pingTimer);
    const ws = socket;
    socket = null;
    if (ws && ws.readyState <= WebSocket.OPEN) ws.close(1000, "bye");
  }

  function reconnectNow() {
    if (!wanted || socket || connecting) return;
    attempt = 0;
    connect();
  }

  function onVisibility() {
    if (!wanted) return;
    if (document.hidden) {
      clearTimeout(hiddenTimer);
      hiddenTimer = setTimeout(disconnect, HIDDEN_GRACE);
    } else {
      clearTimeout(hiddenTimer);
      reconnectNow();
    }
  }

  return {
    start() {
      if (!listening) {
        listening = true;
        document.addEventListener("visibilitychange", onVisibility);
        window.addEventListener("online", reconnectNow);
      }
      if (wanted) return;
      wanted = true;
      connectedBefore = false;
      attempt = 0;
      connect();
    },
    stop() {
      wanted = false;
      disconnect();
    },
  };
}
