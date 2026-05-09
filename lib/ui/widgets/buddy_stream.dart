import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/sip_providers.dart';
import '../../sip/sip_user_agent.dart';
import 'status_chip.dart';

/// Browser-Phone style "buddy stream": a per-peer header with call/message
/// actions, an interleaved timeline of messages and call events, and a
/// composer at the bottom.
class BuddyStream extends ConsumerStatefulWidget {
  const BuddyStream({
    super.key,
    required this.peer,
    required this.canCall,
    required this.onCall,
    this.onClose,
  });

  final String peer;
  final bool canCall;
  final void Function(String party) onCall;
  final VoidCallback? onClose;

  @override
  ConsumerState<BuddyStream> createState() => _BuddyStreamState();
}

class _BuddyStreamState extends ConsumerState<BuddyStream> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    ref.read(sipUserAgentProvider).sendMessage(widget.peer, text);
    _composer.clear();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final messages = ref.watch(threadProvider(widget.peer));
    final calls = ref.watch(peerCallsProvider(widget.peer));
    final timeline = _buildTimeline(messages, calls);
    final canSend = widget.canCall && _composer.text.trim().isNotEmpty;

    return Column(
      children: [
        _StreamHeader(
          peer: widget.peer,
          canCall: widget.canCall,
          onCall: () => widget.onCall(widget.peer),
          onClose: widget.onClose,
        ),
        const Divider(height: 1),
        Expanded(
          child: timeline.isEmpty
              ? _EmptyThread(peer: widget.peer)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  itemCount: timeline.length,
                  itemBuilder: (_, i) => _TimelineEntry(item: timeline[i]),
                ),
        ),
        const Divider(height: 1),
        Container(
          color: scheme.surfaceContainerLow,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: SafeArea(
            top: false,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _composer,
                    minLines: 1,
                    maxLines: 5,
                    enabled: widget.canCall,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Write a message…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: canSend ? _send : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  child: const Icon(Icons.send, size: 20),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _StreamHeader extends StatelessWidget {
  const _StreamHeader({
    required this.peer,
    required this.canCall,
    required this.onCall,
    required this.onClose,
  });
  final String peer;
  final bool canCall;
  final VoidCallback onCall;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    var bare = peer.startsWith('sip:') ? peer.substring(4) : peer;
    final at = bare.indexOf('@');
    final name = at > 0 ? bare.substring(0, at) : bare;
    final host = at > 0 ? bare.substring(at + 1) : '';
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          if (onClose != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: IconButton(
                tooltip: 'Back',
                onPressed: onClose,
                icon: const Icon(Icons.arrow_back),
              ),
            ),
          PartyAvatar(party: peer, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (host.isNotEmpty)
                  Text(
                    host,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Audio call',
            onPressed: canCall ? onCall : null,
            icon: const Icon(Icons.call),
            color: scheme.primary,
          ),
          IconButton(
            tooltip: 'Video call (coming soon)',
            onPressed: null,
            icon: const Icon(Icons.videocam_outlined),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Interleaved timeline
// ---------------------------------------------------------------------------

abstract class _TimelineItem {
  DateTime get when;
}

class _MsgItem extends _TimelineItem {
  _MsgItem(this.message);
  final SipTextMessage message;
  @override
  DateTime get when => message.receivedAt;
}

class _CallItem extends _TimelineItem {
  _CallItem(this.call);
  final SipCall call;
  @override
  DateTime get when => call.startedAt ?? call.endedAt ?? DateTime.now();
}

List<_TimelineItem> _buildTimeline(
  List<SipTextMessage> messages,
  List<SipCall> calls,
) {
  final items = <_TimelineItem>[
    ...messages.map(_MsgItem.new),
    ...calls.map(_CallItem.new),
  ];
  items.sort((a, b) => a.when.compareTo(b.when));
  return items;
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({required this.item});
  final _TimelineItem item;

  @override
  Widget build(BuildContext context) {
    if (item is _MsgItem) {
      return _MessageBubble(message: (item as _MsgItem).message);
    }
    return _CallEvent(call: (item as _CallItem).call);
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});
  final SipTextMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final outgoing = message.outgoing;
    final bg = outgoing ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = outgoing ? scheme.onPrimary : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: outgoing
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(outgoing ? 16 : 4),
                  bottomRight: Radius.circular(outgoing ? 4 : 16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.body,
                    style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _fmt(message.receivedAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: fg.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _CallEvent extends StatelessWidget {
  const _CallEvent({required this.call});
  final SipCall call;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final outgoing = call.outgoing;
    final missed =
        !outgoing && call.state == CallState.ended && call.startedAt == null;
    final IconData icon = outgoing
        ? Icons.call_made
        : (missed ? Icons.call_missed : Icons.call_received);
    final color = missed ? scheme.error : scheme.primary;
    final label = outgoing
        ? 'Outgoing call'
        : (missed ? 'Missed call' : 'Incoming call');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Text(
                  '$label · ${_fmt(call.startedAt ?? call.endedAt ?? DateTime.now())}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _EmptyThread extends StatelessWidget {
  const _EmptyThread({required this.peer});
  final String peer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PartyAvatar(party: peer, size: 88),
            const SizedBox(height: 12),
            Text(
              'No history with this buddy yet',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Send a message or place a call to get started.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
