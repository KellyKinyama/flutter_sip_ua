/// UDP transport stub used on platforms without `dart:io` (web).
///
/// Any attempt to construct a UDP-based SIP transport fails fast with a
/// clear error so the UA can fall back to WS / WSS.
library;

import 'transport.dart';

SipTransport createUdpTransport({
  required String remoteHost,
  required int remotePort,
}) {
  throw UnsupportedError(
    'UDP SIP transport is not supported on this platform. '
    'Use a ws:// or wss:// server URI instead.',
  );
}
