/// Web stub for [RtpQuicSession]. RTP-over-QUIC requires UDP sockets,
/// which `dart:html`-based web builds cannot provide.
library;

import 'dart:async';
import 'dart:typed_data';

import 'rtp_quic_session.dart';

export 'rtp_quic_session.dart';

class RtpQuicSessionImpl implements RtpQuicSession {
  RtpQuicSessionImpl({
    required String remoteHost,
    required int remotePort,
    String authority = 'localhost',
    String path = '/rtp',
  }) {
    throw UnsupportedError(
      'RTP-over-QUIC is not supported on this platform. '
      'It requires dart:io UDP sockets, which the web target lacks.',
    );
  }

  @override
  Stream<RtpQuicState> get state => const Stream.empty();

  @override
  Stream<Uint8List> get incoming => const Stream.empty();

  @override
  bool get isConnected => false;

  @override
  Future<void> connect({
    Duration timeout = const Duration(seconds: 10),
  }) async {}

  @override
  void send(Uint8List rtpPacket) {}

  @override
  Future<void> close() async {}
}
