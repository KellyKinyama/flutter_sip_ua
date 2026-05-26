# flutter_sip_ua

Pure-Dart SIP user agent and Flutter client for the dart-pbx server. The UI is
modelled on [InnovateAsterisk Browser-Phone](https://github.com/InnovateAsterisk/Browser-Phone)
with a Riverpod-driven state layer and a modular widget tree.

**Repository:** <https://github.com/KellyKinyama/flutter_sip_ua>

## Features

- Pure-Dart SIP signalling stack (`lib/sip/`) — registration, calls, MESSAGE,
  digest auth, SDP, RTP/RTCP helpers.
- Pure-Dart media path — G.711 codec, RTP packetizer, jitter buffer. No
  `flutter_webrtc`, no libwebrtc binary.
- Multiple transports out of the box: **WS/WSS**, **UDP**, and optional
  **RTP-over-QUIC datagrams** (`pure_dart_quic`).
- Riverpod-based state management (`lib/providers/sip_providers.dart`).
- Browser-Phone-style UI:
  - Two-pane shell with buddy sidebar + active stream.
  - Modular call screen (`lib/ui/widgets/call/`).
  - Dialer sheet, message composer, transfer sheet.
- Light **and** dark themes that mirror `phone.light.css` / `phone.dark.css`.
  Theme choice is persisted via SharedPreferences and toggled from the sidebar
  toolbar (system → light → dark).
- **HTTP control API** (desktop only) — drive the running UA from a browser or
  any HTTP client. See [docs/control_api.md](docs/control_api.md) and the
  ready-to-open browser console at
  [examples/control_api/index.html](examples/control_api/index.html).

## Why not `dart-sip-ua` + `flutter_webrtc`?

[`dart-sip-ua`](https://github.com/cloudwebrtc/dart-sip-ua) is a JsSIP port that
delegates all media to [`flutter_webrtc`](https://github.com/flutter-webrtc/flutter-webrtc),
which bundles **libwebrtc** — roughly 10M lines of C++ extracted from Chromium,
shipped as tens of megabytes of native binaries per platform. `flutter_sip_ua`
keeps the entire stack — signalling, transport, RTP, codecs — in **pure Dart**,
targeting the same capability surface as
[`dart-webrtc`](https://github.com/flutter-webrtc/dart-webrtc) without the
native dependency.

| | `dart-sip-ua` + `flutter_webrtc` | `flutter_sip_ua` |
| --- | --- | --- |
| Language end-to-end | Dart + ~10M LOC C++ (libwebrtc) | Pure Dart |
| Binary footprint | Tens of MB of native libs per ABI/platform | Kilobytes |
| Native toolchain | NDK / CocoaPods / MSVC / depot_tools | None |
| Web support | Browser's WebRTC (different impl) | Same Dart code |
| Transports | WS / WSS only | WS / WSS / UDP / QUIC datagrams (TCP/TLS/SCTP pluggable) |
| Memory safety | C++ attack surface | Dart, memory-safe |
| Debuggability | RTC_LOG + Chromium source | Set a breakpoint |

### Transports beyond WebSockets

`dart-sip-ua` is effectively WebSocket-only — a browser-era constraint
inherited from JsSIP. `flutter_sip_ua` ships:

- **WS / WSS** via `web_socket_channel` (works on `dart:io` and web).
- **UDP** via `RawDatagramSocket` (`lib/sip/transport_udp_io.dart`) — talk
  directly to Asterisk / FreeSWITCH / Kamailio on `:5060` with no WS gateway.
- **RTP-over-QUIC datagrams** via `pure_dart_quic` — multiplexed,
  congestion-controlled, NAT/firewall-friendly.
- A pluggable transport interface so **TCP**, **TLS**, **SCTP**, or
  **WebTransport** can be added without native plugin work.

### Current state vs. roadmap

Today: G.711 audio, RTP/RTCP, jitter buffer, SIP REGISTER / INVITE / MESSAGE,
RFC 2617 digest, WS/WSS/UDP, optional QUIC datagrams.

Planned (pure-Dart parity with `dart-webrtc`): ICE / STUN / TURN, DTLS-SRTP,
Opus, video codecs (VP8 / H.264), data channels, AEC / AGC.

`dart-sip-ua` + `flutter_webrtc` is more battle-tested *today* because it
inherits everything from libwebrtc. `flutter_sip_ua` is the better fit when you
want a small, auditable, web-friendly client that speaks to a real SIP server
without dragging a Chromium-derived binary into your app.

## Getting started

```sh
flutter pub get
flutter run -d windows   # or chrome / android / ios / linux / macos
```

Tests:

```sh
flutter test
```

## Project layout

```
lib/
  main.dart
  providers/sip_providers.dart   # Riverpod facade over the SIP UA + UI state
  providers/control_api_provider.dart  # Owns the embedded HTTP control server
  control_api/                   # JSON REST + SSE wrapper around SipUserAgent
  sip/                           # Pure-Dart SIP UA, SDP, transport, audio/video
  ui/
    theme.dart                   # Light/dark ThemeData built from BP palette
    bp_palette.dart              # Browser-Phone color tokens + ThemeExtension
    home_page.dart               # Two-pane shell + dialer sheet
    call_page.dart               # Slim call orchestrator
    widgets/
      buddy_sidebar.dart         # Left rail incl. theme toggle
      dial_pad.dart
      dialer_action_row.dart
      call/                      # Modular call UI pieces
```

## Links

- Source: <https://github.com/KellyKinyama/flutter_sip_ua>
- Issues: <https://github.com/KellyKinyama/flutter_sip_ua/issues>
- Browser-Phone reference: <https://github.com/InnovateAsterisk/Browser-Phone>
