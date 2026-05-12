/// Pure-Dart RTP / codec types shared by signalling (SDP) and the
/// platform-specific media plane.
///
/// This file MUST NOT import `dart:io` so it can be used from web builds
/// where the audio MediaSession itself is unavailable.
library;

/// G.711 codec selection.
enum G711Variant {
  pcmu(0, 'PCMU'),
  pcma(8, 'PCMA');

  const G711Variant(this.payloadType, this.rtpmap);
  final int payloadType;
  final String rtpmap;

  static G711Variant? fromPayloadType(int pt) {
    for (final v in values) {
      if (v.payloadType == pt) return v;
    }
    return null;
  }
}

/// Negotiated remote media endpoint (parsed from SDP).
class RtpEndpoint {
  const RtpEndpoint({
    required this.host,
    required this.port,
    required this.codec,
    int? rtcpPort,
    this.telephoneEventPt,
  }) : rtcpPort = rtcpPort ?? port + 1;

  final String host;
  final int port;

  /// Where to send RTCP. Defaults to `port + 1` per RFC 3550 §11.
  final int rtcpPort;
  final G711Variant codec;

  /// PT to use for RFC 4733 DTMF, if the peer offered it.
  final int? telephoneEventPt;
}

/// Direction tag for [RtpPacketTap].
enum RtpFlow { rtpOut, rtpIn, rtcpOut, rtcpIn }

/// Diagnostic callback invoked once per RTP / RTCP datagram. Called with a
/// human-readable one-line dump (header fields, length — never the
/// payload bytes themselves) so the host can write to a log file.
typedef RtpPacketTap = void Function(RtpFlow flow, String summary);
