import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../sip/sip_user_agent.dart';
import '../../bp_palette.dart';
import '../status_chip.dart';

/// Browser-Phone style call wallpaper:
///   * `.CallColorUnderlay` — a state-tinted radial gradient.
///   * `.CallPictureUnderlay` — a heavily blurred copy of the buddy
///     avatar washed at low opacity.
///
/// Pulled out so the call screen orchestrator stays focused on flow.
class CallBackdrop extends StatelessWidget {
  const CallBackdrop({super.key, required this.state, this.party});

  final CallState state;
  final String? party;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bp = Theme.of(context).bp;

    final accent = switch (state) {
      CallState.active => bp.activeCall,
      CallState.ended => bp.hangup,
      CallState.incomingRinging => bp.presenceRinging,
      CallState.outgoingRinging => scheme.primary,
      CallState.idle => scheme.primary,
    };

    final gradient = RadialGradient(
      center: Alignment.topCenter,
      radius: 1.4,
      colors: [
        Color.lerp(accent, scheme.surface, 0.35) ?? scheme.surface,
        scheme.surface,
      ],
    );

    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(decoration: BoxDecoration(gradient: gradient)),
        ),
        if (party != null)
          Positioned.fill(
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60),
              child: Opacity(
                opacity: 0.25,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: PartyAvatar(party: party!, size: 360),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
