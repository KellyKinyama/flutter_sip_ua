/// `dart:io` TCP and TLS implementation of [SipTransport].
///
/// RFC 3261 §18.4 — messages are framed on the stream by Content-Length.
/// `useTls: true` uses [SecureSocket] (SIPS / transport=tls).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sip_message.dart';
import 'transport.dart';

SipTransport createTcpTransport({
  required String remoteHost,
  required int remotePort,
  required bool useTls,
}) => SipTcpTransport(
      remoteHost: remoteHost,
      remotePort: remotePort,
      useTls: useTls,
    );

class SipTcpTransport implements SipTransport {
  SipTcpTransport({
    required this.remoteHost,
    required this.remotePort,
    required this.useTls,
  });

  final String remoteHost;
  final int remotePort;
  final bool useTls;

  Socket? _socket;
  StreamSubscription<List<int>>? _sub;
  String? _resolvedLocalHost;
  final List<int> _buf = [];

  final _stateCtl = StreamController<TransportState>.broadcast();
  final _messageCtl = StreamController<SipMessage>.broadcast();

  @override
  Stream<TransportState> get state => _stateCtl.stream;
  @override
  Stream<SipMessage> get messages => _messageCtl.stream;
  @override
  bool get isConnected => _socket != null;
  @override
  String get protocol => useTls ? 'TLS' : 'TCP';
  @override
  String get localHost => _resolvedLocalHost ?? '0.0.0.0';
  @override
  int get localPort => _socket?.port ?? 0;

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    _stateCtl.add(TransportState.connecting);
    try {
      final Socket sock;
      if (useTls) {
        sock = await SecureSocket.connect(
          remoteHost,
          remotePort,
          // Allow self-signed certificates common in enterprise SIP deployments.
          onBadCertificate: (_) => true,
        );
      } else {
        sock = await Socket.connect(remoteHost, remotePort);
      }
      _socket = sock;
      _resolvedLocalHost = await _discoverLocalAddress(sock.address);
      _sub = sock.listen(
        _onData,
        onError: (_) => _stateCtl.add(TransportState.disconnected),
        onDone: () {
          _socket = null;
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
    } catch (_) {}
    return '0.0.0.0';
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await _socket?.close();
    _socket = null;
    _buf.clear();
    _stateCtl.add(TransportState.disconnected);
  }

  @override
  void send(SipMessage message) => sendRaw(message.encode());

  @override
  void sendRaw(String raw) {
    final s = _socket;
    if (s == null) throw StateError('transport not connected');
    s.add(utf8.encode(raw));
  }

  void _onData(List<int> data) {
    _buf.addAll(data);
    _parseMessages();
  }

  // RFC 3261 §18.4 — locate \r\n\r\n, read Content-Length bytes after it.
  void _parseMessages() {
    while (true) {
      // Find end-of-headers marker.
      int headerEnd = -1;
      for (int i = 0; i < _buf.length - 3; i++) {
        if (_buf[i] == 0x0D &&
            _buf[i + 1] == 0x0A &&
            _buf[i + 2] == 0x0D &&
            _buf[i + 3] == 0x0A) {
          headerEnd = i + 4;
          break;
        }
      }
      if (headerEnd < 0) return;

      final headerStr =
          utf8.decode(_buf.sublist(0, headerEnd), allowMalformed: true);
      final clMatch =
          RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false)
              .firstMatch(headerStr);
      final contentLength =
          clMatch != null ? int.parse(clMatch.group(1)!) : 0;

      final total = headerEnd + contentLength;
      if (_buf.length < total) return;

      try {
        final msgStr =
            utf8.decode(_buf.sublist(0, total), allowMalformed: true);
        if (msgStr.trim().isNotEmpty) {
          _messageCtl.add(SipMessage.parse(msgStr));
        }
      } catch (_) {
        // drop malformed
      }
      _buf.removeRange(0, total);
    }
  }
}
