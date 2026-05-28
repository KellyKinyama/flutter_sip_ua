/// Riverpod glue that owns the lifetime of the HTTP control API server.
///
/// The API is auto-started on desktop builds (Windows / macOS / Linux) and
/// stays a no-op on web / mobile, where exposing a localhost HTTP control
/// surface either isn't possible (web) or isn't useful (mobile, where the
/// process is typically backgrounded by the OS).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../control_api/control_api.dart';
import '../sip/is_web.dart' if (dart.library.io) '../sip/is_web_io.dart';
import 'sip_providers.dart';

/// Configuration for the embedded control API. Override in `ProviderScope`
/// to change the bind host/port or supply a bearer token.
final controlApiConfigProvider = Provider<ControlApiConfig>((ref) {
  return const ControlApiConfig();
});

/// Whether to start the API on this platform. Override in `ProviderScope`
/// to force-enable on mobile or force-disable on desktop.
final controlApiEnabledProvider = Provider<bool>((ref) {
  if (isWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
});

final controlApiServerProvider = Provider<ControlApiServer>((ref) {
  final ua = ref.watch(sipUserAgentProvider);
  final config = ref.watch(controlApiConfigProvider);
  final prefs = ref.watch(sharedPreferencesProvider);
  final server = ControlApiServer(
    ua: ua,
    config: config,
    // Mirror REST-driven credential changes into persisted prefs + the
    // accountProvider so the UI reflects them and they survive restart.
    onAccountSet: (acc) async {
      await persistAccount(prefs, acc);
      ref.read(accountProvider.notifier).set(acc);
    },
    onAccountCleared: () async {
      await clearPersistedAccount(prefs);
      ref.read(accountProvider.notifier).set(null);
    },
  );
  if (ref.watch(controlApiEnabledProvider)) {
    // Fire and forget: start asynchronously and log via the UA log stream
    // through stdout for visibility on desktop terminals.
    // ignore: discarded_futures
    server
        .start()
        .then((_) {
          if (kDebugMode) {
            // ignore: avoid_print
            print('[control-api] listening on ${server.boundUri}');
          }
        })
        .catchError((e) {
          if (kDebugMode) {
            // ignore: avoid_print
            print('[control-api] failed to start: $e');
          }
        });
  }
  ref.onDispose(() {
    // ignore: discarded_futures
    server.stop();
  });
  return server;
});
