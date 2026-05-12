/// `dart:io` UDP implementation of [SipTransport].
///
/// RFC 3261 §18 — one SIP message per datagram, framed by UTF-8.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sip_message.dart';
import 'transport.dart';

SipTransport createUdpTransport({
  required String remoteHost,
  required int remotePort,
}) => SipUdpTransport(remoteHost: remoteHost, remotePort: remotePort);

class SipUdpTransport implements SipTransport {
  SipUdpTransport({
    required this.remoteHost,
    required this.remotePort,
    this.localBind,
    this.localBindPort = 0,
  });

  final String remoteHost;
  final int remotePort;
  final String? localBind;
  final int localBindPort;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  InternetAddress? _remoteAddr;
  String? _resolvedLocalHost;

  final _stateCtl = StreamController<TransportState>.broadcast();
  final _messageCtl = StreamController<SipMessage>.broadcast();

  @override
  Stream<TransportState> get state => _stateCtl.stream;
  @override
  Stream<SipMessage> get messages => _messageCtl.stream;
  @override
  bool get isConnected => _socket != null;
  @override
  String get protocol => 'UDP';

  @override
  String get localHost {
    final s = _socket;
    if (s == null) return localBind ?? '0.0.0.0';
    // Prefer the address resolved at connect time. The socket itself reports
    // 0.0.0.0 when bound to anyIPv4, which is unroutable in Contact/Via and
    // is rejected by Asterisk with 403 Forbidden.
    final resolved = _resolvedLocalHost;
    if (resolved != null && resolved.isNotEmpty) return resolved;
    final a = s.address.address;
    if (a == '0.0.0.0' || a == '::') return localBind ?? a;
    return a;
  }

  @override
  int get localPort => _socket?.port ?? localBindPort;

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    _stateCtl.add(TransportState.connecting);
    try {
      final bind = localBind == null
          ? InternetAddress.anyIPv4
          : InternetAddress(localBind!);
      _socket = await RawDatagramSocket.bind(bind, localBindPort);
      try {
        _remoteAddr = InternetAddress(remoteHost);
      } catch (_) {
        final list = await InternetAddress.lookup(remoteHost);
        if (list.isEmpty) {
          throw const SocketException('Cannot resolve remote host');
        }
        _remoteAddr = list.first;
      }
      _resolvedLocalHost = await _discoverLocalAddress(_remoteAddr!);
      _sub = _socket!.listen(_onEvent);
      _stateCtl.add(TransportState.connected);
    } catch (_) {
      _stateCtl.add(TransportState.disconnected);
      rethrow;
    }
  }

  /// Pick a usable local IPv4 to advertise in Via/Contact. When the remote
  /// is loopback we must reply on loopback as well; otherwise fall back to
  /// the first non-loopback IPv4 interface (best-effort — no route table
  /// access from pure Dart).
  static Future<String> _discoverLocalAddress(InternetAddress remote) async {
    if (remote.isLoopback) return remote.address;
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        for (final a in iface.addresses) {
          if (a.type == InternetAddressType.IPv4 && !a.isLoopback) {
            return a.address;
          }
        }
      }
    } catch (_) {
      /* fall through */
    }
    return remote.isLoopback ? '127.0.0.1' : '0.0.0.0';
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
    _remoteAddr = null;
    _resolvedLocalHost = null;
    _stateCtl.add(TransportState.disconnected);
  }

  @override
  void send(SipMessage message) => sendRaw(message.encode());

  @override
  void sendRaw(String raw) {
    final s = _socket;
    final r = _remoteAddr;
    if (s == null || r == null) throw StateError('transport not connected');
    s.send(utf8.encode(raw), r, remotePort);
  }

  void _onEvent(RawSocketEvent ev) {
    if (ev != RawSocketEvent.read) return;
    final s = _socket;
    if (s == null) return;
    final dg = s.receive();
    if (dg == null) return;
    try {
      final raw = utf8.decode(dg.data, allowMalformed: true);
      if (raw.trim().isEmpty) return;
      _messageCtl.add(SipMessage.parse(raw));
    } catch (_) {
      /* drop malformed datagram */
    }
  }
}
