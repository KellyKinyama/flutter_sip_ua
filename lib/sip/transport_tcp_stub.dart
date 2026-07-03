import 'transport.dart';

SipTransport createTcpTransport({
  required String remoteHost,
  required int remotePort,
  required bool useTls,
}) => throw UnsupportedError(
      'TCP/TLS SIP transport is not supported on this platform',
    );
