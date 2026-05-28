/// Web stub for [discoverLocalIpv4]. The browser can't enumerate network
/// interfaces so we never have a useful answer here.
library;

Future<String?> discoverLocalIpv4({
  String? targetHost,
  int targetPort = 0,
  void Function(String line)? debug,
}) async => null;
