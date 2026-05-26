/// Public entry point for the HTTP control API. On the web, this resolves
/// to a no-op stub; on `dart:io` platforms (desktop / mobile) it resolves
/// to the real `HttpServer`-backed implementation.
library;

export 'control_api_server_stub.dart'
    if (dart.library.io) 'control_api_server_io.dart';
