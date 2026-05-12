/// No-op [SipFileLogger] used on platforms without `dart:io` (web).
///
/// Web builds have no file system access from Dart — every call is a
/// silent no-op. Set up an alternative sink (e.g. `console.log`) at a
/// higher layer if you need wire logs in the browser.
library;

import 'sip_file_logger.dart';
import 'sip_message.dart';

class SipFileLoggerImpl implements SipFileLogger {
  SipFileLoggerImpl(this.path);

  @override
  final String path;

  @override
  void open() {}

  @override
  void log(String direction, SipMessage msg) {}

  @override
  void note(String line) {}

  @override
  Future<void> close() async {}
}
