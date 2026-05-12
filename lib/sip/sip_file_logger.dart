/// Append-only SIP wire-format logger.
///
/// This file declares only the public interface and a [SipFileLogger.new]
/// factory that resolves to the right implementation for the current
/// platform via conditional imports:
///
///   * `sip_file_logger_io.dart`   — real `dart:io`-based logger.
///   * `sip_file_logger_stub.dart` — no-op on platforms without `dart:io`
///     (e.g. web).
library;

import 'sip_message.dart';

import 'sip_file_logger_stub.dart'
    if (dart.library.io) 'sip_file_logger_io.dart'
    as impl;

/// Wire-format logger. One file per launch on native; a no-op shim on web.
abstract class SipFileLogger {
  /// Construct the platform-default logger. On web returns a no-op
  /// implementation that ignores [path].
  factory SipFileLogger(String path) = impl.SipFileLoggerImpl;

  /// Absolute path to the log file. May be empty on no-op web logger.
  String get path;

  /// Open (or create) the log target. Safe to call more than once.
  void open();

  /// Log a parsed message we just sent (`OUT`) or received (`IN`).
  void log(String direction, SipMessage msg);

  /// Log a free-form line (transport state changes, errors, ...).
  void note(String line);

  /// Flush and close.
  Future<void> close();
}
