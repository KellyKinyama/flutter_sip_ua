/// Platform facade for [RtpQuicSession]. Re-exports the native
/// `dart:io`-backed implementation when available, otherwise the web stub.
library;

export 'rtp_quic_session_stub.dart'
    if (dart.library.io) 'rtp_quic_session_io.dart';
