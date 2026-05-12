/// SIP transports.
///
/// Two pluggable implementations:
///
///  * [SipWebSocketTransport] — `ws://` / `wss://` to the dart-pbx WS server
///    (Sec-WebSocket-Protocol: sip). Works on every platform Flutter
///    supports, including web.
///  * `SipUdpTransport`       — RFC 3261 §18 UDP, one datagram per message.
///    Provided by `transport_udp_io.dart` on platforms that have
///    `dart:io`; on web the factory throws [UnsupportedError].
///
/// Both expose the same surface ([SipTransport]) so the user agent doesn't
/// care which one it talks over.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'sip_message.dart';

// UDP transport lives in `transport_udp_io.dart` on native, where
// `dart:io` is available. On web (no `dart:io`) the stub variant kicks in
// and any attempt to construct a UDP transport throws.
import 'transport_udp_stub.dart'
    if (dart.library.io) 'transport_udp_io.dart'
    as udp;

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
  ///   * ws://host:port  -> [SipWebSocketTransport]
  ///   * wss://host:port -> [SipWebSocketTransport]
  ///   * sip:host:port   -> UDP transport (native only — throws on web)
  static SipTransport forUri(Uri serverUri) {
    final scheme = serverUri.scheme.toLowerCase();
    if (scheme == 'ws' || scheme == 'wss') {
      return SipWebSocketTransport(uri: serverUri);
    }
    if (scheme == 'sip' || scheme.isEmpty) {
      final host = serverUri.host.isEmpty ? serverUri.path : serverUri.host;
      final port = serverUri.hasPort ? serverUri.port : 5060;
      return udp.createUdpTransport(remoteHost: host, remotePort: port);
    }
    throw UnsupportedError('Unsupported SIP transport scheme: $scheme');
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
