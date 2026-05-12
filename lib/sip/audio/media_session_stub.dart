/// No-op stub for [MediaSession] used on platforms without `dart:io`
/// (e.g. web). Constructing it throws [UnsupportedError] so callers that
/// forget to gate media setup behind a platform check fail loudly.
library;

import 'audio_sink.dart';
import 'rtp_types.dart';

export 'rtp_types.dart';

class MediaSession {
  MediaSession({
    String? cname,
    AudioSink? sink,
    int jitterTargetFrames = 3,
    int jitterMaxFrames = 12,
    RtpPacketTap? packetTap,
    int packetTapHead = 5,
    int packetTapEvery = 250,
  }) {
    throw UnsupportedError(
      'MediaSession (UDP RTP) is not supported on this platform. '
      'Media is only available on native targets with dart:io.',
    );
  }

  bool muted = false;

  int get localPort => 0;
  int get localRtcpPort => 0;

  Future<int> bindLocalPort({String bindAddress = '0.0.0.0'}) async => 0;

  Future<void> start(RtpEndpoint remote) async {}

  Future<void> stop() async {}

  Future<void> sendDtmf(
    String digit, {
    Duration duration = const Duration(milliseconds: 200),
    int volume = 10,
  }) async {}
}
