/// Web stub for the SDP debug log. No-op everywhere except dart:io.
library;

abstract class SdpLog {
  void writeln(String line);
  Future<void> close();
  String? get path;
}

SdpLog openSdpLog() => _NoopSdpLog();

class _NoopSdpLog implements SdpLog {
  @override
  String? get path => null;
  @override
  void writeln(String line) {}
  @override
  Future<void> close() async {}
}
