/// Stub ringer — used on the web build, where the desktop PCM playback
/// plugin isn't available. All methods are no-ops.
library;

class Ringer {
  Future<void> start() async {}
  Future<void> stop() async {}
  bool get isPlaying => false;
}
