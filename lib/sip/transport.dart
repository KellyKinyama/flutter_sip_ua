/// SIP transports.
///
/// Pluggable implementations:
///
///  * [SipWebSocketTransport] — `ws://` / `wss://` (Sec-WebSocket-Protocol: sip).
///    Works on every platform Flutter supports, including web.
///  * `SipUdpTransport` — RFC 3261 §18 UDP, one datagram per message.
///    Native only (`dart:io`); throws on web.
///  * `SipTcpTransport` — RFC 3261 §18 TCP stream, Content-Length framed.
///    Native only; `useTls: true` for SIPS / transport=tls.
///
/// All expose the same [SipTransport] surface so the user agent doesn't
/// care which one it talks over.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'sip_message.dart';

import 'transport_udp_stub.dart'
    if (dart.library.io) 'transport_udp_io.dart'
    as udp;

import 'transport_tcp_stub.dart'
    if (dart.library.io) 'transport_tcp_io.dart'
    as tcp;

enum TransportState { disconnected, connecting, connected }

abstract class SipTransport {
  Stream<TransportState> get state;
  Stream<SipMessage> get messages;
  bool get isConnected;

  /// Upper-case transport token used in Via / Contact (`WS`, `WSS`, `UDP`).
  String get protocol;

  /// Public host the UA should advertise in Via/Contact.
  String get localHost;

  /// Public port. Returns 0 to mean "omit".
  int get localPort;

  Future<void> connect();
  Future<void> close();

  void send(SipMessage message);

  /// Raw send used for RFC 5626 CRLF keep-alives over WS.
  void sendRaw(String raw);

  /// Build the right transport for [serverUri].
  ///
  ///   * ws:// / wss://                    → WebSocket (cross-platform)
  ///   * sips:host:port                    → TLS/TCP (native only)
  ///   * sip:host:port;transport=tls       → TLS/TCP (native only)
  ///   * sip:host:port;transport=tcp       → plain TCP (native only)
  ///   * sip:host:port  (default / ;transport=udp) → UDP (native only)
  static SipTransport forUri(Uri serverUri) {
    final scheme = serverUri.scheme.toLowerCase();

    if (scheme == 'ws' || scheme == 'wss') {
      return SipWebSocketTransport(uri: serverUri);
    }

    if (scheme == 'sips') {
      final host = _sipHost(serverUri);
      final port = _sipPort(serverUri, 5061);
      return tcp.createTcpTransport(
          remoteHost: host, remotePort: port, useTls: true);
    }

    if (scheme == 'sip' || scheme.isEmpty) {
      final host = _sipHost(serverUri);
      final transport = _sipTransportParam(serverUri);
      if (transport == 'tls') {
        final port = _sipPort(serverUri, 5061);
        return tcp.createTcpTransport(
            remoteHost: host, remotePort: port, useTls: true);
      }
      if (transport == 'tcp') {
        final port = _sipPort(serverUri, 5060);
        return tcp.createTcpTransport(
            remoteHost: host, remotePort: port, useTls: false);
      }
      final port = _sipPort(serverUri, 5060);
      return udp.createUdpTransport(remoteHost: host, remotePort: port);
    }

    throw UnsupportedError('Unsupported SIP transport scheme: $scheme');
  }

  // --- SIP URI helpers -------------------------------------------------------
  // Dart parses `sip:host:port;params` as scheme=sip, path=host:port;params.
  // These helpers extract the pieces from either form.

  static String _sipHost(Uri uri) {
    if (uri.host.isNotEmpty) return uri.host;
    final base = uri.path.split(';').first;
    final colon = base.lastIndexOf(':');
    return colon < 0 ? base : base.substring(0, colon);
  }

  static int _sipPort(Uri uri, int fallback) {
    if (uri.hasPort) return uri.port;
    final base = uri.path.split(';').first;
    final colon = base.lastIndexOf(':');
    if (colon < 0) return fallback;
    return int.tryParse(base.substring(colon + 1)) ?? fallback;
  }

  static String? _sipTransportParam(Uri uri) {
    // Params appear after `;` in the path for authority-less SIP URIs.
    final parts = uri.path.split(';');
    for (final part in parts.skip(1)) {
      final kv = part.split('=');
      if (kv.length == 2 &&
          kv[0].trim().toLowerCase() == 'transport') {
        return kv[1].trim().toLowerCase();
      }
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// WebSocket transport (cross-platform; works on native and web).
// ---------------------------------------------------------------------------

class SipWebSocketTransport implements SipTransport {
  SipWebSocketTransport({required this.uri});

  final Uri uri;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _stateCtl = StreamController<TransportState>.broadcast();
  final _messageCtl = StreamController<SipMessage>.broadcast();

  @override
  Stream<TransportState> get state => _stateCtl.stream;
  @override
  Stream<SipMessage> get messages => _messageCtl.stream;
  @override
  bool get isConnected => _channel != null;
  @override
  String get protocol => uri.scheme.toUpperCase();
  @override
  String get localHost => uri.host;
  @override
  int get localPort => uri.hasPort ? uri.port : 0;

  @override
  Future<void> connect() async {
    if (_channel != null) return;
    _stateCtl.add(TransportState.connecting);
    try {
      // Use the cross-platform constructor so this file is web-safe.
      _channel = WebSocketChannel.connect(uri, protocols: const ['sip']);
      await _channel!.ready;
      _sub = _channel!.stream.listen(
        _onData,
        onError: (_) => _stateCtl.add(TransportState.disconnected),
        onDone: () {
          _channel = null;
          _stateCtl.add(TransportState.disconnected);
        },
        cancelOnError: false,
      );
      _stateCtl.add(TransportState.connected);
    } catch (_) {
      _stateCtl.add(TransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
    _stateCtl.add(TransportState.disconnected);
  }

  @override
  void send(SipMessage message) => sendRaw(message.encode());

  @override
  void sendRaw(String raw) {
    final ch = _channel;
    if (ch == null) throw StateError('transport not connected');
    ch.sink.add(raw);
  }

  void _onData(dynamic data) {
    try {
      final raw = data is String ? data : utf8.decode(data as List<int>);
      if (raw.trim().isEmpty) return;
      _messageCtl.add(SipMessage.parse(raw));
    } catch (_) {
      /* drop malformed */
    }
  }
}
