# Control API

The desktop builds of `flutter_sip_ua` ship with an embedded HTTP control
server so the running `SipUserAgent` can be driven by any HTTP client — a
browser SPA, a CLI tool, a home-automation rule, or another service. The
server is implemented in [lib/control_api/control_api_server_io.dart](../lib/control_api/control_api_server_io.dart)
and managed by [lib/providers/control_api_provider.dart](../lib/providers/control_api_provider.dart).

On web it resolves to a no-op stub via conditional imports, so cross-platform
builds keep compiling.

## Enabling / configuring

The server auto-starts on Windows, macOS and Linux and binds to
`http://127.0.0.1:8765` by default. To change host, port, or add a bearer
token, override `controlApiConfigProvider` at app start:

```dart
runApp(
  ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      controlApiConfigProvider.overrideWithValue(
        const ControlApiConfig(
          host: '0.0.0.0',          // expose on LAN — set a token!
          port: 8765,
          token: 'change-me-please',
        ),
      ),
    ],
    child: const FlutterSipUaApp(),
  ),
);
```

To force-enable on mobile or force-disable on desktop, override
`controlApiEnabledProvider` the same way.

## Authentication

If `ControlApiConfig.token` is set, every request must include it as either:

- `Authorization: Bearer <token>` header, or
- `?token=<token>` query parameter (handy for `EventSource`, which can't
  set custom headers).

Without a token configured, the server accepts any localhost request.
**Do not bind to `0.0.0.0` without a token.**

## REST endpoints

All bodies and responses are JSON. CORS preflight is handled so a browser
SPA on another origin can call the API directly.

| Method | Path                       | Body                                              | Description                                    |
|-------:|----------------------------|---------------------------------------------------|------------------------------------------------|
| GET    | `/status`                  | —                                                 | Registration state + current account snapshot. |
| GET    | `/account`                 | —                                                 | Active account (no password).                  |
| POST   | `/account`                 | `{serverUri, domain, username, password, displayName?, sessionExpires?, minSE?}` | Start UA + register. Persisted to `SharedPreferences`, so the agent re-registers automatically after restart. |
| POST   | `/unregister`              | —                                                 | Stop UA / sign out. Also clears the persisted credentials.            |
| GET    | `/calls`                   | —                                                 | List of recent calls (see notes below).        |
| POST   | `/calls`                   | `{target, video?}`                                | Place a call. Returns the new call snapshot.   |
| GET    | `/calls/{id}`              | —                                                 | Snapshot of a single call.                     |
| POST   | `/calls/{id}/answer`       | —                                                 | Answer an incoming call.                       |
| POST   | `/calls/{id}/hangup`       | —                                                 | Hangup / cancel / decline.                     |
| POST   | `/calls/{id}/hold`         | `{hold: bool}`                                    | Hold or resume.                                |
| POST   | `/calls/{id}/mute`         | `{muted: bool}`                                   | Mute or unmute the mic.                        |
| POST   | `/calls/{id}/dtmf`         | `{digit, durationMs?}`                            | Send an RFC 4733 DTMF digit.                   |
| POST   | `/calls/{id}/transfer`     | `{target}` *or* `{replaceCallId}`                 | Blind transfer (`target`) or attended transfer (`replaceCallId` = an already-active consultation call). Sends an in-dialog `REFER`. |
| POST   | `/messages`                | `{target, text}`                                  | Send a SIP MESSAGE.                            |
| GET    | `/logs`                    | —                                                 | Recent log lines (subscribe to `/events` or `/ws` for a live tail). |
| GET    | `/events`                  | — (SSE)                                           | Server-Sent Events stream of `registration`, `call`, `message`, `log`. |
| GET    | `/ws`                      | — (WebSocket upgrade)                             | WebSocket feed of the same events plus an initial `hello` snapshot. |

### Call transfer

`POST /calls/{id}/transfer` sends an in-dialog SIP `REFER` to the peer of
`{id}`:

- **Blind**: `{"target": "300"}` — the peer accepts (`202`) and dials
  `300` itself; your call typically ends when the peer hangs up after
  the new call is established.
- **Attended**: first place a consultation call with `POST /calls`, then
  call this endpoint on the *original* call with
  `{"replaceCallId": "<consultation-call-id>"}`. The peer is asked
  (RFC 3891 `Replaces`) to swap its leg with the consultation call.

A `409` response means one of the calls isn't currently active.

### Call object

```json
{
  "id": "9b1e…",
  "remoteParty": "sip:200@pbx.example.com",
  "outgoing": true,
  "state": "active",         // idle | outgoingRinging | incomingRinging | active | ended
  "held": false,
  "startedAt": "2026-05-27T10:14:23.001Z",
  "endedAt": null
}
```

### SSE event format

`/events` emits one of four event types. Each `data:` line is a JSON object:

| event          | data shape                                    |
|----------------|-----------------------------------------------|
| `registration` | `{ "state": "registered" }`                   |
| `call`         | a call object (see above)                     |
| `message`      | `{ from, to, body, outgoing, receivedAt }`    |
| `log`          | `{ "line": "..." }`                           |

A `: ka` comment line is emitted every 15 s as a keep-alive.

### WebSocket feed (`/ws`)

For clients that prefer a duplex transport (or need to run somewhere that
doesn't speak SSE well), `/ws` upgrades the connection to a WebSocket and
emits the same events — each frame is a JSON envelope:

```json
{ "event": "call", "data": { "id": "...", "state": "active", ... } }
```

The first frame after upgrade is always a snapshot so a fresh client
doesn't need to call `/status` separately:

```json
{
  "event": "hello",
  "data": {
    "name": "flutter_sip_ua control api",
    "version": 1,
    "status": { "registration": "registered", "account": { ... } }
  }
}
```

The server pings every 20 s, so reverse proxies see traffic on idle
connections. Inbound frames are currently ignored — use the REST
endpoints to drive the UA.

Auth works the same way as for the REST endpoints: send
`Authorization: Bearer <token>` on the upgrade request, or append
`?token=<token>` to the URL (most browser `WebSocket` constructors can't
set custom headers).

## Quick smoke test (curl)

```bash
# Status
curl -s http://127.0.0.1:8765/status


# Register
curl -s -X POST http://127.0.0.1:8765/account \
  -H 'Content-Type: application/json' \
  -d '{
        "serverUri": "wss://pbx.example.com:7443",
        "domain":    "pbx.example.com",
        "username":  "1001",
        "password":  "secret"
      }'

# Place a call
curl -s -X POST http://127.0.0.1:8765/calls \
  -H 'Content-Type: application/json' \
  -d '{"target": "200"}'

# Hangup
curl -s -X POST http://127.0.0.1:8765/calls/<id>/hangup

# Live events (SSE)
curl -N http://127.0.0.1:8765/events

# Live events (WebSocket, via `websocat`)
websocat ws://127.0.0.1:8765/ws
```

## Browser example

A self-contained HTML + vanilla-JS console lives at
[examples/control_api/index.html](../examples/control_api/index.html). Open
it in any browser while the desktop app is running.

## Postman collection

A Postman v2.1 collection covering every endpoint ships at
[docs/control_api.postman_collection.json](control_api.postman_collection.json),
along with a matching environment at
[docs/control_api.postman_environment.json](control_api.postman_environment.json).

To use it:

1. In Postman, **Import → Files** and pick both JSON files.
2. Select the **flutter_sip_ua — local desktop** environment in the top-right.
3. (Optional) Set the `token` variable if you configured one in
   `ControlApiConfig`. When left empty, the collection automatically drops
   the `Authorization` header via its pre-request script.
4. Run **Account → POST /account (register)** to sign in, then
   **Calls → POST /calls (make call)** — its test script writes the new
   call's id into the `callId` collection variable so the per-call
   endpoints (`answer`, `hangup`, `hold`, `mute`, `dtmf`) work without
   manual copy/paste.

The `GET /events` request is included for completeness, but Postman
buffers the response — use a browser, `curl -N`, or the example console
to watch the SSE stream live.

