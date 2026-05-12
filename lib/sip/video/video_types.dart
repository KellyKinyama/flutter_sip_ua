/// Web-safe video media types shared by signalling, the native impl, and
/// the web stub. No `dart:io`.
library;

import '../sdp.dart';

/// Negotiated remote video endpoint.
class VideoEndpoint {
  const VideoEndpoint({
    required this.host,
    required this.port,
    required this.payloadType,
    required this.codec,
    int? rtcpPort,
  }) : rtcpPort = rtcpPort ?? port + 1;

  final String host;
  final int port;
  final int rtcpPort;
  final int payloadType;
  final SdpVideoCodec codec;

  factory VideoEndpoint.fromSdp(SdpVideo s) => VideoEndpoint(
    host: s.host,
    port: s.port,
    payloadType: s.payloadType,
    codec: s.codec,
    rtcpPort: s.effectiveRtcpPort,
  );
}
