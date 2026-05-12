/// No-op stub for [VideoSession] used on platforms without `dart:io`
/// (e.g. web). Constructing it throws [UnsupportedError].
library;

import 'video_codec.dart';
import 'video_types.dart';

export 'video_types.dart';

class VideoSession {
  VideoSession({
    VideoEncoder? encoder,
    VideoDecoder? decoder,
    String? cname,
    int maxPayloadSize = 1200,
  }) {
    throw UnsupportedError(
      'VideoSession (UDP RTP) is not supported on this platform. '
      'Video is only available on native targets with dart:io.',
    );
  }

  int get localPort => 0;
  int get localRtcpPort => 0;

  Future<int> bindLocalPort({String bindAddress = '0.0.0.0'}) async => 0;
  Future<void> start(VideoEndpoint remote) async {}
  Future<void> stop() async {}
}
