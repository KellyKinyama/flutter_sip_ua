/// `dart:io` implementation of [RtpQuicSession] backed by
/// `package:pure_dart_quic`.
///
/// Architecture
/// ------------
///   * A single `RawDatagramSocket` carries QUIC packets to/from the peer.
///   * A [_HookedQuicSession] subclass overrides
///     [QuicSession.handleWebTransportDatagram] so each inbound DATAGRAM
///     is reparsed (varint quarter-stream-id prefix + payload) and pushed
///     onto the public [incoming] stream as raw RTP bytes.
///   * [connect] sends a `ClientHello`, drives the read loop, then waits
///     until `applicationSecretsDerived` is true (TLS done) and an active
///     WebTransport session id is set, before completing.
///   * [send] wraps a single RTP packet in a WebTransport DATAGRAM bound
///     to the negotiated session id.
///
/// The pure_dart_quic stack is research-grade — handshakes against
/// stricter HTTP/3 servers may need tweaks. This file is deliberately
/// thin so the moving parts stay in the upstream package.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pure_dart_quic/connection/client/quic_session3.dart';
import 'package:pure_dart_quic/constants.dart' as pdq;

import 'rtp_quic_session.dart';

export 'rtp_quic_session.dart';

class RtpQuicSessionImpl implements RtpQuicSession {
  RtpQuicSessionImpl({
    required this.remoteHost,
    required this.remotePort,
    this.authority = 'localhost',
    this.path = '/rtp',
  });

  /// Peer host (IP or DNS name).
  final String remoteHost;

  /// Peer UDP port.
  final int remotePort;

  /// `:authority` header used in the WebTransport CONNECT.
  final String authority;

  /// `:path` for the WebTransport CONNECT (e.g. `/rtp`).
  final String path;

  RawDatagramSocket? _socket;
  _HookedQuicSession? _session;
  StreamSubscription<RawSocketEvent>? _sub;
  InternetAddress? _remoteAddr;
  int? _wtSessionId;

  final _stateCtl = StreamController<RtpQuicState>.broadcast();
  final _incomingCtl = StreamController<Uint8List>.broadcast();

  @override
  Stream<RtpQuicState> get state => _stateCtl.stream;
  @override
  Stream<Uint8List> get incoming => _incomingCtl.stream;
  @override
  bool get isConnected => _wtSessionId != null;

  @override
  Future<void> connect({Duration timeout = const Duration(seconds: 10)}) async {
    if (isConnected) return;
    _stateCtl.add(RtpQuicState.connecting);

    try {
      _remoteAddr = await _resolve(remoteHost);
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket = sock;

      final dcid = _randomCid(8);
      final session = _HookedQuicSession(
        dcid,
        sock,
        onWebTransportData: (sessionId, data) {
          // Only surface datagrams for the WT session we own.
          final ours = _wtSessionId;
          if (ours != null && sessionId != ours) return;
          if (data.isEmpty) return;
          _incomingCtl.add(Uint8List.fromList(data));
        },
      );
      _session = session;

      _sub = sock.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final dg = sock.receive();
        if (dg == null) return;
        for (final pkt in pdq.splitCoalescedPackets(dg.data)) {
          try {
            session.handleQuicPacket(pkt);
          } catch (_) {
            // Tolerate parse errors during early handshake stages.
          }
        }
      });

      session.sendClientHello(
        address: _remoteAddr!,
        port: remotePort,
        authority: authority,
      );

      // Once TLS 1.3 application secrets are installed, open the
      // WebTransport CONNECT stream.
      final deadline = DateTime.now().add(timeout);
      while (!session.applicationSecretsDerived) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('QUIC handshake timed out');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      _wtSessionId = session.openWebTransportSession(
        path,
        authority: authority,
        address: _remoteAddr,
        port: remotePort,
      );

      // Wait for the server to accept the WT CONNECT. The upstream
      // session marks the id as "active" once it sees a 200.
      while (session.activeWebTransportSessionId == null) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('WebTransport CONNECT timed out');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      _stateCtl.add(RtpQuicState.connected);
    } catch (e) {
      _stateCtl.add(RtpQuicState.failed);
      await close();
      rethrow;
    }
  }

  @override
  void send(Uint8List rtpPacket) {
    final session = _session;
    final id = _wtSessionId;
    final addr = _remoteAddr;
    if (session == null || id == null || addr == null) return;
    session.sendWebTransportDatagram(
      id,
      rtpPacket,
      address: addr,
      port: remotePort,
    );
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
    _session = null;
    _wtSessionId = null;
    _stateCtl.add(RtpQuicState.closed);
    await _incomingCtl.close();
    await _stateCtl.close();
  }

  static final Random _rng = Random.secure();

  static Uint8List _randomCid(int len) {
    final bytes = Uint8List(len);
    for (var i = 0; i < len; i++) {
      bytes[i] = _rng.nextInt(256);
    }
    return bytes;
  }

  static Future<InternetAddress> _resolve(String host) async {
    try {
      return InternetAddress(host);
    } catch (_) {
      final lookup = await InternetAddress.lookup(host);
      if (lookup.isEmpty) {
        throw const SocketException('Cannot resolve remote host');
      }
      return lookup.first;
    }
  }
}

/// Subclass of [QuicSession] that re-parses each inbound WebTransport
/// DATAGRAM so callers can consume the payload via a stream instead of
/// the upstream package's `print()`-only path.
class _HookedQuicSession extends QuicSession {
  _HookedQuicSession(
    super.dcid,
    super.socket, {
    required this.onWebTransportData,
  });

  /// Called with `(streamId, rtpPayload)` for each inbound DATAGRAM.
  final void Function(int streamId, Uint8List data) onWebTransportData;

  @override
  void handleWebTransportDatagram(Uint8List datagramPayload) {
    // WebTransport DATAGRAM framing (draft-ietf-webtrans-http3): a QUIC
    // varint "quarter stream id" followed by the application payload. The
    // CONNECT stream id is `quarter_stream_id * 4`.
    final v = _readVarint(datagramPayload, 0);
    if (v == null) return;
    final streamId = v.value * 4;
    final payload = Uint8List.sublistView(datagramPayload, v.bytesRead);
    try {
      onWebTransportData(streamId, payload);
    } catch (_) {
      /* never let an app-level handler crash the QUIC read loop */
    }
  }
}

class _Varint {
  const _Varint(this.value, this.bytesRead);
  final int value;
  final int bytesRead;
}

/// Decode a QUIC variable-length integer (RFC 9000 §16).
_Varint? _readVarint(Uint8List data, int offset) {
  if (offset >= data.length) return null;
  final first = data[offset];
  final lenLog2 = (first & 0xC0) >> 6;
  final length = 1 << lenLog2;
  if (offset + length > data.length) return null;
  var value = first & 0x3F;
  for (var i = 1; i < length; i++) {
    value = (value << 8) | data[offset + i];
  }
  return _Varint(value, length);
}
