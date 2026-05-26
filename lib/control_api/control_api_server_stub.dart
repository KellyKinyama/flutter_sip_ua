/// Web stub. The HTTP control API is only available on native (desktop /
/// mobile) builds — `dart:io`'s `HttpServer` is not available on the web,
/// and exposing a browser to localhost wouldn't serve the use case.
library;

import '../sip/sip_user_agent.dart';

class ControlApiConfig {
  const ControlApiConfig({
    this.host = '127.0.0.1',
    this.port = 8765,
    this.token,
    this.enabled = false,
  });
  final String host;
  final int port;
  final String? token;
  final bool enabled;
}

class ControlApiServer {
  ControlApiServer({
    required this.ua,
    this.config = const ControlApiConfig(),
  });

  final SipUserAgent ua;
  final ControlApiConfig config;

  bool get isRunning => false;
  Uri? get boundUri => null;

  Future<void> start() async {}
  Future<void> stop() async {}
}
