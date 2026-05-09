import 'package:flutter/material.dart';

import '../bp_palette.dart';

/// Browser-Phone style row of three call-action buttons used at the
/// bottom of the dialer:
///
///   * Video call — disabled in this UA (no video media yet).
///   * Audio call — primary green dial button.
///   * Send message — quick MESSAGE without placing a call.
///
/// All buttons honour [enabled]; when `false` they render at reduced
/// opacity and ignore taps. The video button always stays disabled
/// since the SIP UA in this project doesn't yet negotiate video.
class DialerActionRow extends StatelessWidget {
  const DialerActionRow({
    super.key,
    required this.enabled,
    required this.onAudioCall,
    required this.onMessage,
    this.onVideoCall,
  });

  final bool enabled;
  final VoidCallback? onAudioCall;
  final VoidCallback? onMessage;

  /// Pass `null` to render the video button as permanently disabled.
  final VoidCallback? onVideoCall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bp = Theme.of(context).bp;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _DialerCircle(
          icon: Icons.videocam,
          color: bp.dial,
          size: 56,
          tooltip: 'Video call (not supported)',
          onTap: enabled ? onVideoCall : null,
        ),
        _DialerCircle(
          icon: Icons.call,
          color: bp.dial,
          size: 72,
          tooltip: 'Audio call',
          onTap: enabled ? onAudioCall : null,
        ),
        _DialerCircle(
          icon: Icons.chat_bubble,
          color: scheme.primary,
          size: 56,
          tooltip: 'Send message',
          onTap: enabled ? onMessage : null,
        ),
      ],
    );
  }
}

class _DialerCircle extends StatelessWidget {
  const _DialerCircle({
    required this.icon,
    required this.color,
    required this.size,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final double size;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: disabled ? 0.4 : 1,
        child: SizedBox(
          width: size,
          height: size,
          child: Material(
            color: color,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            elevation: disabled ? 0 : 3,
            child: InkWell(
              onTap: onTap,
              child: Center(
                child: Icon(icon, color: Colors.white, size: size * 0.42),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
