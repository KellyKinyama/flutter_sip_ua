/// Platform facade for [VideoSession].
///
/// On native targets re-exports the `dart:io`-backed implementation from
/// `video_session.dart`. On web (no `dart:io`) re-exports the stub from
/// `video_session_stub.dart`.
library;

export 'video_session_stub.dart' if (dart.library.io) 'video_session.dart';
