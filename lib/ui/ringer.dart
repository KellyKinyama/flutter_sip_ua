/// Public entry point for the incoming-call ringer. Resolves to a real
/// `flutter_pcm_sound`-backed implementation on native builds and to a
/// no-op stub on the web.
library;

export 'ringer_stub.dart' if (dart.library.io) 'ringer_io.dart';
