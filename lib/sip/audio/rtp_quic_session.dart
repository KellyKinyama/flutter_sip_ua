/// Public surface for RTP-over-QUIC support.
///
/// On native targets (`dart:io`), the real implementation in
/// [rtp_quic_session_io.dart] runs RTP packets through a WebTransport
/// DATAGRAM session opened over QUIC, courtesy of `package:pure_dart_quic`.
///
/// On web, where `dart:io` (and the underlying `RawDatagramSocket`) is
/// unavailable, the constructor throws [UnsupportedError]. SIP signalling
/// over WSS continues to work; only the RTP/QUIC side channel is gated.
///
/// This file is intentionally small — call sites should import it and
/// let the conditional-import facade pick the right implementation.
library;

import 'dart:async';
import 'dart:typed_data';

/// Connection state for [RtpQuicSession].
enum RtpQuicState { idle, connecting, connected, closed, failed }

/// Outbound RTP-over-QUIC pipe. Use [send] to push RTP packets and
/// [incoming] to consume packets arriving from the peer. The exact framing
/// is one RTP packet per WebTransport DATAGRAM (RFC 9221 over HTTP/3
/// WebTransport datagrams), so a peer that speaks the same scheme will
/// see byte-for-byte RTP just as it would over UDP.
abstract class RtpQuicSession {
  /// Current state. Pushed by the implementation as the QUIC + TLS 1.3 +
  /// HTTP/3 + WebTransport bring-up progresses.
  Stream<RtpQuicState> get state;

  /// Inbound RTP packets (one event per WebTransport DATAGRAM).
  Stream<Uint8List> get incoming;

  /// True once a WebTransport session is open and ready to ferry RTP.
  bool get isConnected;

  /// Establish the QUIC connection and open the WebTransport session.
  ///
  /// Throws on handshake failure or timeout. Idempotent.
  Future<void> connect({Duration timeout = const Duration(seconds: 10)});

  /// Send a single RTP packet.
  ///
  /// Silently no-ops if the session is not yet connected.
  void send(Uint8List rtpPacket);

  /// Tear everything down. Always safe to call.
  Future<void> close();
}
