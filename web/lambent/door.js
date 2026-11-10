// The page's half of the connection to a PC: see lambent_sw.js. Pairing and the WebRTC offer go over iroh through a relay (lambent_web.js), which proves
// both keys, and requests then go over a direct data channel. Frames, both ways: u32 request id, u8 kind, payload (remote/web_door.rs in the Lambent repository).
(() => {
  const KEY = 'lambent.door.key';
  const NAMES = { HEAD: 0, BODY: 1, END: 2, ERROR: 3, CANCEL: 4, CREDIT: 5 };
  const CHUNK = 60 * 1024;
  const ICE = [{ urls: 'stun:stun.l.google.com:19302' }, { urls: 'stun:stun.cloudflare.com:3478' }];
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  let opening;
  function door() {
    opening ??= (async () => {
      const bindings = await import(new URL('lambent_web.js', document.baseURI + 'lambent/').href);
      await bindings.default();
      let key = localStorage.getItem(KEY);
      if (!key) {
        key = bindings.newKey();
        localStorage.setItem(KEY, key);
      }
      return bindings.Door.open(key);
    })();
    opening.catch(() => { opening = undefined; });
    return opening;
  }

  let worker;
  function serviceWorker() {
    worker ??= (async () => {
      await navigator.serviceWorker.register('lambent_sw.js', { scope: './' });
      await navigator.serviceWorker.ready;
      if (!navigator.serviceWorker.controller) {
        await Promise.race([new Promise((resolve) => navigator.serviceWorker.addEventListener('controllerchange', resolve, { once: true })), wait(4000)]);
      }
    })();
    worker.catch(() => { worker = undefined; });
    return worker;
  }

  function frame(id, kind, payload) {
    const bytes = new Uint8Array(5 + (payload ? payload.byteLength : 0));
    new DataView(bytes.buffer).setUint32(0, id);
    bytes[4] = kind;
    if (payload) bytes.set(new Uint8Array(payload.buffer ?? payload, payload.byteOffset ?? 0, payload.byteLength), 5);
    return bytes;
  }

  // Sets up `pc`, sending its whole offer at once: `send` carries it to the PC and returns the answer.
  async function negotiate(pc, send) {
    await pc.setLocalDescription(await pc.createOffer());
    if (pc.iceGatheringState !== 'complete') {
      await Promise.race([new Promise((resolve) => pc.addEventListener('icegatheringstatechange', () => { if (pc.iceGatheringState === 'complete') resolve(); })), wait(1500)]);
    }
    const answer = await send(JSON.stringify(pc.localDescription));
    await pc.setRemoteDescription(JSON.parse(answer));
  }

  // One question to a PC that may not know this browser, over a connection of its own. No STUN: only a LAN path can answer it.
  async function lobby(id, message) {
    const iroh = await door();
    const pc = new RTCPeerConnection({ iceServers: [] });
    try {
      const channel = pc.createDataChannel('http', { ordered: true });
      channel.binaryType = 'arraybuffer';
      const answered = new Promise((resolve, reject) => {
        channel.onmessage = ({ data }) => resolve(JSON.parse(decoder.decode(new Uint8Array(data, 5))));
        channel.onclose = () => reject(new Error('The PC closed the connection.'));
        channel.onopen = () => channel.send(frame(1, NAMES.HEAD, encoder.encode(JSON.stringify(message))));
      });
      const asked = negotiate(pc, (offer) => iroh.lobbyOffer(id, offer)).then(() => answered);
      answered.catch(() => {});
      asked.catch(() => {});
      return await Promise.race([asked, wait(12000).then(() => { throw new Error('The PC could not be reached on this network.'); })]);
    } finally {
      pc.close();
    }
  }

  const connections = new Map();

  // `?stats` on the page's address shows where a connection's time goes: the route, this page's own delays, or the player.
  const counts = { received: 0, taken: 0 };
  function findVideo(root = document) {
    const direct = root.querySelector('video');
    if (direct) return direct;
    for (const element of root.querySelectorAll('*')) {
      if (element.shadowRoot) {
        const inner = findVideo(element.shadowRoot);
        if (inner) return inner;
      }
    }
    return null;
  }
  function showStats() {
    const box = document.createElement('div');
    box.style.cssText = 'position:fixed;top:0;left:0;z-index:2147483647;pointer-events:none;background:rgba(0,0,0,.8);color:#7f7;font:12px/1.35 monospace;padding:6px;white-space:pre';
    document.documentElement.appendChild(box);
    let lag = 0;
    let beat = performance.now();
    setInterval(() => {
      const now = performance.now();
      lag = Math.max(lag, now - beat - 100);
      beat = now;
    }, 100);
    let last = { ...counts };
    let lastDropped = 0;
    setInterval(async () => {
      const lines = [];
      lines.push(`in ${((counts.received - last.received) * 8 / 1e6).toFixed(1)} Mbit/s  player took ${((counts.taken - last.taken) * 8 / 1e6).toFixed(1)}  waiting ${((counts.received - counts.taken) / 1e6).toFixed(1)} MB`);
      lines.push(`page lag ${Math.round(lag)} ms`);
      last = { ...counts };
      lag = 0;
      for (const connection of connections.values()) {
        if (!connection.pc) continue;
        const stats = await connection.pc.getStats();
        for (const entry of stats.values()) {
          if (entry.type === 'candidate-pair' && entry.nominated) {
            const local = stats.get(entry.localCandidateId);
            const remote = stats.get(entry.remoteCandidateId);
            lines.push(`${local?.candidateType} ${local?.networkType ?? ''} -> ${remote?.candidateType}  rtt ${Math.round((entry.currentRoundTripTime ?? 0) * 1000)} ms`);
          }
        }
      }
      const video = findVideo();
      if (video) {
        const quality = video.getVideoPlaybackQuality?.();
        const dropped = quality?.droppedVideoFrames ?? 0;
        const ranges = video.buffered;
        const ahead = ranges.length ? ranges.end(ranges.length - 1) - video.currentTime : 0;
        lines.push(`video ${video.videoWidth}x${video.videoHeight}  ahead ${ahead.toFixed(1)} s  state ${video.readyState}${video.paused ? ' paused' : ''}`);
        lines.push(`frames ${quality?.totalVideoFrames ?? '?'}  dropped ${dropped} (+${dropped - lastDropped})`);
        lastDropped = dropped;
      } else {
        lines.push('no video element');
      }
      lines.push(`screen ${screen.width}x${screen.height} @${devicePixelRatio}  hdr screen ${matchMedia('(dynamic-range: high)').matches}`);
      box.textContent = lines.join('\n');
    }, 1000);
  }
  if (new URLSearchParams(location.search).has('stats')) {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', showStats);
    else showStats();
  }

  class Connection {
    constructor(id) {
      this.id = id;
      this.next = 1;
      this.requests = new Map();
      this.route = 'connecting';
    }

    open() {
      this.opened ??= this.connect();
      this.opened.catch(() => { this.opened = undefined; });
      return this.opened;
    }

    async connect() {
      const iroh = await door();
      const pc = new RTCPeerConnection({ iceServers: ICE });
      const channel = pc.createDataChannel('http', { ordered: true });
      channel.binaryType = 'arraybuffer';
      this.pc = pc;
      this.channel = channel;
      channel.onmessage = ({ data }) => this.received(data);
      const closed = () => {
        if (this.channel !== channel) return;
        this.opened = undefined;
        this.channel = undefined;
        this.route = 'connecting';
        for (const port of this.requests.values()) port.postMessage({ error: 'The connection to the PC closed.' });
        this.requests.clear();
        pc.close();
      };
      channel.onclose = closed;
      pc.oniceconnectionstatechange = () => {
        if (['failed', 'closed'].includes(pc.iceConnectionState)) closed();
      };
      await negotiate(pc, (offer) => iroh.offer(this.id, offer));
      await Promise.race([
        new Promise((resolve) => channel.addEventListener('open', resolve, { once: true })),
        wait(20000).then(() => { throw new Error('No direct connection to the PC could be made.'); }),
      ]);
      await this.findRoute();
    }

    async findRoute() {
      for (const stats of (await this.pc.getStats()).values()) {
        if (stats.type === 'candidate-pair' && stats.nominated) {
          const remote = (await this.pc.getStats()).get(stats.remoteCandidateId);
          this.route = remote && remote.candidateType === 'host' ? 'home' : 'direct';
          return;
        }
      }
    }

    received(data) {
      counts.received += data.byteLength;
      const view = new DataView(data);
      const id = view.getUint32(0);
      const kind = view.getUint8(4);
      const port = this.requests.get(id);
      if (!port) return;
      if (kind === NAMES.HEAD) {
        const head = JSON.parse(decoder.decode(new Uint8Array(data, 5)));
        port.postMessage({ head });
      } else if (kind === NAMES.BODY) {
        const chunk = data.slice(5);
        port.postMessage({ chunk }, [chunk]);
      } else {
        port.postMessage(kind === NAMES.END ? { end: true } : { error: decoder.decode(new Uint8Array(data, 5)) });
        this.requests.delete(id);
      }
    }

    async fetch({ path, method, headers, body }, port) {
      await this.open();
      const id = this.next++;
      this.requests.set(id, port);
      port.onmessage = ({ data }) => {
        if (data.cancel) {
          this.requests.delete(id);
          if (this.channel) this.channel.send(frame(id, NAMES.CANCEL));
        } else if (data.taken && this.channel) {
          counts.taken += data.taken;
          const bytes = new Uint8Array(4);
          new DataView(bytes.buffer).setUint32(0, data.taken);
          this.channel.send(frame(id, NAMES.CREDIT, bytes));
        }
      };
      const channel = this.channel;
      channel.send(frame(id, NAMES.HEAD, encoder.encode(JSON.stringify({ method, url: path, headers }))));
      for (let at = 0; body && at < body.byteLength; at += CHUNK) {
        while (channel.bufferedAmount > 8 * 1024 * 1024) await wait(10);
        channel.send(frame(id, NAMES.BODY, new Uint8Array(body, at, Math.min(CHUNK, body.byteLength - at))));
      }
      channel.send(frame(id, NAMES.END));
    }
  }

  function connection(id) {
    if (!connections.has(id)) connections.set(id, new Connection(id));
    return connections.get(id);
  }

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.addEventListener('message', ({ data, ports }) => {
      if (data?.type !== 'lambent-fetch') return;
      connection(data.id).fetch(data, ports[0]).catch((error) => ports[0].postMessage({ error: String(error.message ?? error) }));
    });
  }

  window.LambentDoor = {
    available: () => 'serviceWorker' in navigator && 'RTCPeerConnection' in window && window.isSecureContext,
    start: () => serviceWorker(),
    pair: async (id, token, name, kind) => {
      await serviceWorker();
      await (await door()).pair(id, token, name, kind);
    },
    // The PCs that are on this browser's network, as JSON: [{id, name}]. The service only knows which share its public address.
    nearby: async () => {
      let pcs = [];
      try {
        const answer = await fetch('/api/v1/nearby', { cache: 'no-store' });
        if (answer.ok) pcs = (await answer.json()).pcs ?? [];
      } catch (_) {}
      const found = await Promise.all(pcs.map(async (id) => {
        try {
          const reply = await lobby(id, {});
          return reply.ok ? { id, name: reply.name } : null;
        } catch (_) {
          return null;
        }
      }));
      return JSON.stringify(found.filter(Boolean));
    },
    join: async (id, name, kind) => {
      await serviceWorker();
      const reply = await lobby(id, { join: { name, kind } });
      if (!reply.ok) throw new Error(reply.error ?? 'The PC refused this browser.');
    },
    route: (id) => connections.get(id)?.route ?? 'connecting',
    connect: async (id) => {
      await serviceWorker();
      await connection(id).open();
    },
  };
})();
