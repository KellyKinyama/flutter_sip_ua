/// Native (`dart:io`) log-path builder. Picks a temp directory per launch.
library;

import 'dart:io';

String buildLogPath() {
  final ts = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '-')
      .replaceAll('.', '-');
  final dir = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_sip_ua',
  );
  return '${dir.path}${Platform.pathSeparator}sip-$ts.log';
}
