/// Wires the [Ringer] into Riverpod: it starts whenever any tracked call
/// is in the [CallState.incomingRinging] state and stops as soon as none
/// are. The ringer is fully released when stopped so the per-call
/// `PcmAudioSink` can take over the `flutter_pcm_sound` engine on answer.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sip/sip_user_agent.dart';
import '../ui/ringer.dart';
import 'sip_providers.dart';

final ringerProvider = Provider<Ringer>((ref) {
  final ringer = Ringer();
  ref.onDispose(() {
    // ignore: discarded_futures
    ringer.stop();
  });
  return ringer;
});

/// Pure-derived flag: true when any recent call is currently ringing in.
final hasIncomingRingingProvider = Provider<bool>((ref) {
  final calls = ref.watch(callsProvider).recents;
  for (final c in calls) {
    if (c.state == CallState.incomingRinging) return true;
  }
  return false;
});

/// Eagerly-created controller that toggles the ringer based on
/// [hasIncomingRingingProvider]. Read it once at app start (e.g. from the
/// root widget) so its `listen` subscription stays alive.
final ringerControllerProvider = Provider<void>((ref) {
  final ringer = ref.watch(ringerProvider);
  ref.listen<bool>(hasIncomingRingingProvider, (prev, next) {
    if (next && !(prev ?? false)) {
      // ignore: discarded_futures
      ringer.start();
    } else if (!next && (prev ?? false)) {
      // ignore: discarded_futures
      ringer.stop();
    }
  }, fireImmediately: true);
});
