// control-api-client.js
//
// Tiny browser/ES-module client for the flutter_sip_ua Control API.
// Maintains a live, reactive view of the agent's state by subscribing
// to the `/ws` WebSocket feed, and offers thin REST helpers for the
// imperative endpoints (register, dial, hangup, ...).
//
// Usage:
//   import { ControlApiClient } from './control-api-client.js';
//
//   const api = new ControlApiClient({
//     baseUrl: 'http://127.0.0.1:8765',
//     token:   '',                 // optional bearer
//   });
//
//   api.on('change', (state) => render(state));
//   api.on('call',   (call)  => console.log('call event', call));
//   api.on('message',(msg)   => console.log('SIP MESSAGE', msg));
//   api.on('log',    (line)  => console.debug('[ua]', line));
//   api.on('open',   ()      => console.info('ws open'));
//   api.on('close',  (info)  => console.warn('ws closed', info));
//
//   api.connect();
//   await api.register({ serverUri, domain, username, password });
//   await api.placeCall('200');
//
// State shape (`api.state`):
//   {
//     connected:    boolean,
//     registration: 'unregistered' | 'registering' | 'registered' | 'failed' | ...,
//     account:      { username, domain, serverUri, displayName? } | null,
//     calls:        Map<id, CallSnapshot>,
//     messages:     [{ from, to, body, outgoing, receivedAt }, ...],
//   }

export class ControlApiClient extends EventTarget {
  constructor({
    baseUrl = 'http://127.0.0.1:8765',
    token = '',
    autoReconnect = true,
    reconnectDelayMs = 1500,
    maxReconnectDelayMs = 15000,
    maxMessages = 200,
  } = {}) {
    super();
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.token = token || '';
    this.autoReconnect = autoReconnect;
    this.reconnectDelayMs = reconnectDelayMs;
    this.maxReconnectDelayMs = maxReconnectDelayMs;
    this.maxMessages = maxMessages;

    this._ws = null;
    this._reconnectAttempt = 0;
    this._stopped = false;

    this.state = {
      connected: false,
      registration: 'unknown',
      account: null,
      calls: new Map(),
      messages: [],
    };
  }

  // ---------------------------------------------------------------- listeners
  // Convenience wrappers around EventTarget so callers can write
  //   api.on('call', fn) / api.off('call', fn)
  // instead of addEventListener/removeEventListener with CustomEvent.detail.
  on(type, fn) {
    const wrapped = (e) => fn(e.detail, e);
    fn.__wrapped__ = wrapped;
    this.addEventListener(type, wrapped);
    return this;
  }
  off(type, fn) {
    this.removeEventListener(type, fn.__wrapped__ || fn);
    return this;
  }
  _emit(type, detail) {
    this.dispatchEvent(new CustomEvent(type, { detail }));
  }
  _emitChange() {
    this._emit('change', this.state);
  }

  // ----------------------------------------------------------------- WS feed
  connect() {
    this._stopped = false;
    this._openSocket();
  }

  disconnect() {
    this._stopped = true;
    if (this._ws) {
      try { this._ws.close(1000, 'client closing'); } catch (_) {}
    }
    this._ws = null;
  }

  _wsUrl() {
    const u = new URL(this.baseUrl);
    u.protocol = u.protocol === 'https:' ? 'wss:' : 'ws:';
    u.pathname = (u.pathname.replace(/\/+$/, '') + '/ws') || '/ws';
    if (this.token) u.searchParams.set('token', this.token);
    return u.toString();
  }

  _openSocket() {
    if (this._ws) return;
    let ws;
    try {
      ws = new WebSocket(this._wsUrl());
    } catch (err) {
      this._scheduleReconnect(err);
      return;
    }
    this._ws = ws;

    ws.addEventListener('open', () => {
      this._reconnectAttempt = 0;
      this.state.connected = true;
      this._emit('open');
      this._emitChange();
    });

    ws.addEventListener('message', (evt) => {
      let frame;
      try {
        frame = JSON.parse(evt.data);
      } catch (err) {
        this._emit('error', { kind: 'parse', error: err, raw: evt.data });
        return;
      }
      this._handleFrame(frame);
    });

    ws.addEventListener('close', (evt) => {
      this._ws = null;
      this.state.connected = false;
      this._emit('close', { code: evt.code, reason: evt.reason });
      this._emitChange();
      if (this.autoReconnect && !this._stopped) {
        this._scheduleReconnect();
      }
    });

    ws.addEventListener('error', (err) => {
      this._emit('error', { kind: 'socket', error: err });
      // 'close' will fire next; reconnect is handled there.
    });
  }

  _scheduleReconnect(err) {
    if (this._stopped) return;
    const attempt = ++this._reconnectAttempt;
    const delay = Math.min(
      this.reconnectDelayMs * Math.pow(1.5, attempt - 1),
      this.maxReconnectDelayMs,
    );
    if (err) this._emit('error', { kind: 'open', error: err });
    setTimeout(() => this._openSocket(), delay);
  }

  // ------------------------------------------------------------- frame intake
  _handleFrame(frame) {
    const { event, data } = frame || {};
    switch (event) {
      case 'hello': {
        // Initial snapshot. Seed registration + account from /status.
        const status = data?.status || {};
        this.state.registration = status.registration ?? this.state.registration;
        this.state.account = status.account ?? this.state.account;
        this._emit('hello', data);
        this._emitChange();
        return;
      }
      case 'registration': {
        this.state.registration = data?.state ?? 'unknown';
        this._emit('registration', this.state.registration);
        this._emitChange();
        return;
      }
      case 'call': {
        const call = data;
        if (!call?.id) return;
        if (call.state === 'ended') {
          // Keep ended calls visible briefly so the UI can show them, but
          // mark them. Consumers can prune as they like.
          this.state.calls.set(call.id, call);
        } else {
          this.state.calls.set(call.id, call);
        }
        this._emit('call', call);
        this._emitChange();
        return;
      }
      case 'message': {
        this.state.messages.push(data);
        if (this.state.messages.length > this.maxMessages) {
          this.state.messages.splice(0, this.state.messages.length - this.maxMessages);
        }
        this._emit('message', data);
        this._emitChange();
        return;
      }
      case 'log': {
        this._emit('log', data?.line ?? '');
        return;
      }
      default:
        this._emit('frame', frame);
    }
  }

  // Helpers --------------------------------------------------------
  /** Drop a call from local state (does NOT hang it up — use hangup()). */
  pruneCall(id) {
    if (this.state.calls.delete(id)) this._emitChange();
  }
  /** Drop every call whose state is 'ended'. */
  pruneEndedCalls() {
    let changed = false;
    for (const [id, c] of this.state.calls) {
      if (c.state === 'ended') { this.state.calls.delete(id); changed = true; }
    }
    if (changed) this._emitChange();
  }
  /** Live calls (anything not 'ended'). */
  liveCalls() {
    return [...this.state.calls.values()].filter((c) => c.state !== 'ended');
  }

  // -------------------------------------------------------------- REST plumbing
  async _fetch(path, { method = 'GET', body } = {}) {
    const headers = { Accept: 'application/json' };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (this.token) headers['Authorization'] = `Bearer ${this.token}`;
    const res = await fetch(`${this.baseUrl}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    let data = null;
    const text = await res.text();
    if (text) {
      try { data = JSON.parse(text); } catch { data = text; }
    }
    if (!res.ok) {
      const err = new Error(
        (data && data.error) || `HTTP ${res.status} ${res.statusText}`,
      );
      err.status = res.status;
      err.data = data;
      throw err;
    }
    return data;
  }

  // ---- REST shortcuts (mirror docs/control_api.md) ---------------------
  status()                                  { return this._fetch('/status'); }
  account()                                 { return this._fetch('/account'); }
  register(payload)                         { return this._fetch('/account',  { method: 'POST', body: payload }); }
  unregister()                              { return this._fetch('/unregister', { method: 'POST' }); }
  listCalls()                               { return this._fetch('/calls'); }
  placeCall(target, { video = false } = {}) { return this._fetch('/calls',    { method: 'POST', body: { target, video } }); }
  answer(id)                                { return this._fetch(`/calls/${encodeURIComponent(id)}/answer`, { method: 'POST' }); }
  hangup(id)                                { return this._fetch(`/calls/${encodeURIComponent(id)}/hangup`, { method: 'POST' }); }
  hold(id, hold)                            { return this._fetch(`/calls/${encodeURIComponent(id)}/hold`,   { method: 'POST', body: { hold } }); }
  mute(id, muted)                           { return this._fetch(`/calls/${encodeURIComponent(id)}/mute`,   { method: 'POST', body: { muted } }); }
  dtmf(id, digit, durationMs)               {
    const body = { digit };
    if (durationMs !== undefined) body.durationMs = durationMs;
    return this._fetch(`/calls/${encodeURIComponent(id)}/dtmf`, { method: 'POST', body });
  }
  transferBlind(id, target)                 { return this._fetch(`/calls/${encodeURIComponent(id)}/transfer`, { method: 'POST', body: { target } }); }
  transferAttended(id, replaceCallId)       { return this._fetch(`/calls/${encodeURIComponent(id)}/transfer`, { method: 'POST', body: { replaceCallId } }); }
  sendMessage(target, text)                 { return this._fetch('/messages', { method: 'POST', body: { target, text } }); }
}
