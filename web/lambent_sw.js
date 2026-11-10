// The web app's connection to its PC (docs/REMOTE_ACCESS.md in the Lambent repository, "The web app"). A server's address is t/<tunnel id>/ under this
// page, so the app's own requests, images and video need nothing special. This hands each one to the page, which holds the WebRTC connection a worker
// can't, and passes the answer back as an ordinary response. Anything else goes to the network as usual.
const PREFIX = new URL('t/', self.registration.scope).pathname;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin || !url.pathname.startsWith(PREFIX)) return;
  event.respondWith(tunnel(event, url));
});

async function page(event) {
  const own = event.clientId ? await self.clients.get(event.clientId) : null;
  if (own && own.type === 'window') return own;
  const windows = await self.clients.matchAll({ type: 'window' });
  return windows[0];
}

async function tunnel(event, url) {
  const request = event.request;
  const rest = url.pathname.slice(PREFIX.length);
  const slash = rest.indexOf('/');
  const id = slash < 0 ? rest : rest.slice(0, slash);
  const path = (slash < 0 ? '/' : rest.slice(slash)) + url.search;
  const client = await page(event);
  if (!client) return new Response('The page holding the connection has closed.', { status: 503 });
  const body = ['GET', 'HEAD'].includes(request.method) ? null : await request.arrayBuffer();
  const { port1, port2 } = new MessageChannel();
  const headers = [...request.headers.entries()];
  client.postMessage({ type: 'lambent-fetch', id, path, method: request.method, headers, body }, body ? [port2, body] : [port2]);
  return new Promise((resolve) => {
    let controller;
    const queue = [];
    let ended = false;
    // The reader is waiting: the next chunk goes straight to it, since nothing else would ask again.
    let wanted = false;
    const finish = () => {
      if (ended && !queue.length && controller) {
        try { controller.close(); } catch (_) {}
        port1.close();
      }
    };
    const stream = new ReadableStream({
      start(c) { controller = c; },
      pull() {
        const next = queue.shift();
        if (next) {
          controller.enqueue(new Uint8Array(next));
          port1.postMessage({ taken: next.byteLength });
        } else {
          wanted = true;
        }
        finish();
      },
      cancel() {
        port1.postMessage({ cancel: true });
        port1.close();
      },
    }, { highWaterMark: 0 });
    request.signal.addEventListener('abort', () => {
      port1.postMessage({ cancel: true });
      try { controller.error(new DOMException('Aborted', 'AbortError')); } catch (_) {}
      port1.close();
    });
    port1.onmessage = ({ data }) => {
      if (data.head) {
        const empty = [101, 204, 205, 304].includes(data.head.status) || request.method === 'HEAD';
        resolve(new Response(empty ? null : stream, { status: data.head.status, headers: data.head.headers }));
      } else if (data.chunk) {
        if (wanted) {
          wanted = false;
          controller.enqueue(new Uint8Array(data.chunk));
          port1.postMessage({ taken: data.chunk.byteLength });
        } else {
          queue.push(data.chunk);
        }
      } else if (data.end) {
        ended = true;
        finish();
      } else if (data.error) {
        resolve(new Response(data.error, { status: 502 }));
        try { controller.error(new Error(data.error)); } catch (_) {}
        port1.close();
      }
    };
  });
}
