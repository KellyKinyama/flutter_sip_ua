# Control API — browser example

A single-file HTML + vanilla-JS console that drives the embedded HTTP
control API exposed by the desktop builds of `flutter_sip_ua`. No build
step, no dependencies.

## Use it

1. Run the desktop app (Windows / macOS / Linux). The control API auto-starts on
   `http://127.0.0.1:8765` (see [docs/control_api.md](../../docs/control_api.md)
   for how to change host / port / token).
2. Open [index.html](./index.html) in any browser — double-click works, or
   serve the folder if you prefer:

   ```bash
   python -m http.server -d examples/control_api 5500
   # then visit http://127.0.0.1:5500
   ```

3. Fill in the **Base URL** (default is fine for the same machine), click
   **Connect** to subscribe to the live event stream, then register your
   SIP account, dial, hold, mute, send DTMF or MESSAGEs — all driven over
   plain HTTP.

If you configured a bearer token in `ControlApiConfig`, paste it into the
**Bearer token** field; it is sent both as `Authorization: Bearer …` on
REST calls and as `?token=…` on the SSE subscription (the browser
`EventSource` can't set custom headers).

## What's inside

- A typed `api()` helper around `fetch` that handles auth + JSON.
- An `EventSource` subscription to `/events`, dispatching `registration`,
  `call`, `message`, and `log` events into the UI.
- A live list of active calls with per-call **Answer / Hangup / Hold /
  Mute / DTMF** buttons.

The whole client is ~250 lines in [index.html](./index.html); copy it
into your own SPA as a starting point.

## WebSocket version

If you'd rather use the duplex `/ws` feed (lower latency, no SSE
buffering issues behind some proxies), see:

- [control-api-client.js](./control-api-client.js) — a small,
  dependency-free ES module that opens the WebSocket, maintains a
  reactive `state` (`{ connected, registration, account, calls, messages }`),
  auto-reconnects with backoff, and exposes thin REST helpers
  (`register`, `placeCall`, `answer`, `hangup`, `hold`, `mute`, `dtmf`,
  `transferBlind`, `sendMessage`, …).
- [ws-demo.html](./ws-demo.html) — a single-page console that imports
  the module and re-renders the entire UI off the client's `change`
  event whenever a WS frame arrives.

Quick taste:

```js
import { ControlApiClient } from './control-api-client.js';

const api = new ControlApiClient({ baseUrl: 'http://127.0.0.1:8765' });
api.on('change', (state) => {
  console.log('registration:', state.registration);
  console.log('live calls:',   api.liveCalls());
});
api.connect();

await api.register({ serverUri, domain, username, password });
await api.placeCall('200');
```
