/// `dart:io` implementation of [SdpLog].
///
/// Writes to a *fixed* path (truncated on each launch) so that an
/// out-of-band reader (e.g. the dev assistant) can always find the
/// most recent SDP exchange at the same location without having to
/// be told a new timestamped filename every run.
library;

import 'dart:io';

abstract class SdpLog {
  void writeln(String line);
  Future<void> close();
  String? get path;
}

SdpLog openSdpLog() => _IoSdpLog._open();

String sdpLogPath() =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_sip_ua'
    '${Platform.pathSeparator}latest-sdp.log';

class _IoSdpLog implements SdpLog {
  _IoSdpLog._(this._sink, this.path);

  @override
  final String path;
  IOSink? _sink;

  factory _IoSdpLog._open() {
    final p = sdpLogPath();
    final f = File(p);
    f.parent.createSync(recursive: true);
    final sink = f.openWrite(mode: FileMode.write);
    sink
      ..writeln(
        '################################################################',
      )
      ..writeln('# sdp log opened ${DateTime.now().toIso8601String()}')
      ..writeln('# pid            $pid')
      ..writeln(
        '################################################################',
      );
    return _IoSdpLog._(sink, p);
  }

  @override
  void writeln(String line) {
    final s = _sink;
    if (s == null) return;
    s.writeln(line);
  }

  @override
  Future<void> close() async {
    final s = _sink;
    _sink = null;
    if (s == null) return;
    try {
      await s.flush();
    } catch (_) {}
    try {
      await s.close();
    } catch (_) {}
  }
}
