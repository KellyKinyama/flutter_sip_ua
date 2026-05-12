/// Platform facade for [MediaSession].
///
/// On native targets re-exports the `dart:io`-backed implementation from
/// `media_session.dart`. On web (no `dart:io`) re-exports the stub from
/// `media_session_stub.dart` so the rest of the app still compiles.
library;

export 'media_session_stub.dart' if (dart.library.io) 'media_session.dart';
