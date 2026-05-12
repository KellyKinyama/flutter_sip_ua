/// `dart:io` implementation of [SipFileLogger].
library;

import 'dart:async';
import 'dart:io';

import 'sip_file_logger.dart';
import 'sip_message.dart';

class SipFileLoggerImpl implements SipFileLogger {
  SipFileLoggerImpl(this.path);

  @override
  final String path;

  IOSink? _sink;

  @override
  void open() {
    if (_sink != null) return;
    final f = File(path);
    f.parent.createSync(recursive: true);
    _sink = f.openWrite(mode: FileMode.append);
    _sink!
      ..writeln()
      ..writeln(
        '################################################################',
      )
      ..writeln('# session start  ${DateTime.now().toIso8601String()}')
      ..writeln('# pid            $pid')
      ..writeln(
        '################################################################',
      );
  }

  @override
  void log(String direction, SipMessage msg) {
    final s = _sink;
    if (s == null) return;
    final summary = msg.isResponse
        ? '${msg.statusCode} ${msg.reasonPhrase}'
        : '${msg.method} ${msg.requestUri}';
    s
      ..writeln()
      ..writeln(
        '----- ${DateTime.now().toIso8601String()}  $direction  $summary -----',
      )
      ..write(msg.encode());
  }

  @override
  void note(String line) {
    final s = _sink;
    if (s == null) return;
    s.writeln('# ${DateTime.now().toIso8601String()}  $line');
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
