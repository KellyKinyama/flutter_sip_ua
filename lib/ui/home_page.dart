import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/sip_providers.dart';
import '../sip/sip_user_agent.dart';
import 'call_page.dart';
import 'login_page.dart';
import 'widgets/buddy_sidebar.dart';
import 'widgets/buddy_stream.dart';
import 'widgets/dial_pad.dart';
import 'widgets/welcome_pane.dart';

/// Browser-Phone style two-pane home: a buddy sidebar plus a content area
/// that shows either a welcome pane or the selected buddy's stream.
///
/// The dial pad and the SIP wire log are surfaced as overlays (a modal
/// sheet for the dialer; the log is opened in a full-screen route).
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static const double _wideBreakpoint = 900;
  bool _restoreScheduled = false;
  bool _streamRoutePushed = false;

  @override
  Widget build(BuildContext context) {
    if (!_restoreScheduled) {
      _restoreScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAccount());
    }

    final reg =
        ref.watch(registrationStateProvider).value ??
        RegistrationState.unregistered;
    final account =
        ref.watch(accountProvider) ?? ref.read(sipUserAgentProvider).account;
    final selected = ref.watch(selectedBuddyProvider);
    final canCall = reg == RegistrationState.registered;
    final isWide = MediaQuery.of(context).size.width >= _wideBreakpoint;

    // Push the call page when a new call needs UI.
    ref.listen<AsyncValue<SipCall>>(callEventsProvider, (_, next) {
      next.whenData(_maybeNavigateToCall);
    });

    final sidebar = BuddySidebar(
      account: account,
      regState: reg,
      onOpenDialer: _openDialer,
      onOpenLog: _openLog,
      onEditAccount: _openLogin,
      onSignOut: _signOut,
    );

    if (isWide) {
      _streamRoutePushed = false;
      final content = selected == null
          ? WelcomePane(
              account: account,
              regState: reg,
              onOpenDialer: _openDialer,
              onOpenLog: _openLog,
            )
          : BuddyStream(
              key: ValueKey(selected),
              peer: selected,
              canCall: canCall,
              onCall: _placeCall,
            );
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              SizedBox(width: 320, child: sidebar),
              VerticalDivider(
                width: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(child: content),
            ],
          ),
        ),
      );
    }

    // Narrow layout: the sidebar fills the screen; selecting a buddy
    // pushes the stream as its own route so the system back gesture
    // clears the selection.
    if (selected != null && !_streamRoutePushed) {
      _streamRoutePushed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final peer = selected;
        Navigator.of(context)
            .push(
              MaterialPageRoute(
                settings: const RouteSettings(name: 'stream'),
                builder: (_) => Scaffold(
                  body: SafeArea(
                    child: BuddyStream(
                      peer: peer,
                      canCall: canCall,
                      onCall: _placeCall,
                      onClose: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
              ),
            )
            .then((_) {
              if (!mounted) return;
              _streamRoutePushed = false;
              ref.read(selectedBuddyProvider.notifier).clear();
            });
      });
    }

    return Scaffold(body: SafeArea(child: sidebar));
  }

  // ---------------------------------------------------------------------------
  // Account lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _restoreAccount() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final account = readPersistedAccount(prefs);
    if (account == null) {
      _openLogin();
      return;
    }
    ref.read(accountProvider.notifier).set(account);
    await ref.read(sipUserAgentProvider).start(account);
  }

  Future<void> _openLogin() async {
    if (!mounted) return;
    final initial =
        ref.read(accountProvider) ?? ref.read(sipUserAgentProvider).account;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoginPage(
          initial: initial,
          onSubmit: (acc) async {
            final ua = ref.read(sipUserAgentProvider);
            final prefs = ref.read(sharedPreferencesProvider);
            await ua.start(acc);
            await persistAccount(prefs, acc);
            ref.read(accountProvider.notifier).set(acc);
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  Future<void> _signOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'This clears the saved account credentials and unregisters from the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(sipUserAgentProvider).stop();
    } catch (_) {
      /* best-effort */
    }
    await clearPersistedAccount(ref.read(sharedPreferencesProvider));
    ref.read(accountProvider.notifier).set(null);
    ref.read(callsProvider.notifier).clear();
    ref.read(messagesProvider.notifier).clear();
    ref.read(unreadProvider.notifier).clearAll();
    ref.read(selectedBuddyProvider.notifier).clear();
    if (!mounted) return;
    _openLogin();
  }

  // ---------------------------------------------------------------------------
  // Calls
  // ---------------------------------------------------------------------------

  void _placeCall(String target) {
    final t = target.trim();
    if (t.isEmpty) return;
    if (!ref.read(isRegisteredProvider)) return;
    ref.read(sipUserAgentProvider).makeCall(t);
  }

  void _maybeNavigateToCall(SipCall call) {
    if (call.state != CallState.incomingRinging &&
        call.state != CallState.outgoingRinging &&
        call.state != CallState.active) {
      return;
    }
    if (ModalRoute.of(context)?.settings.name == 'call') return;
    Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'call'),
        builder: (_) => CallPage(callId: call.id),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Dialer overlay
  // ---------------------------------------------------------------------------

  Future<void> _openDialer() async {
    final canCall = ref.read(isRegisteredProvider);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.85,
              ),
              child: _DialerSheet(
                canCall: canCall,
                onCall: (target) {
                  Navigator.of(ctx).pop();
                  _placeCall(target);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Log overlay
  // ---------------------------------------------------------------------------

  void _openLog() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const _LogPage()));
  }
}

// ---------------------------------------------------------------------------
// Dialer sheet
// ---------------------------------------------------------------------------

class _DialerSheet extends StatefulWidget {
  const _DialerSheet({required this.canCall, required this.onCall});
  final bool canCall;
  final void Function(String target) onCall;

  @override
  State<_DialerSheet> createState() => _DialerSheetState();
}

class _DialerSheetState extends State<_DialerSheet> {
  final TextEditingController _dial = TextEditingController();

  @override
  void dispose() {
    _dial.dispose();
    super.dispose();
  }

  void _append(String d) {
    final c = _dial;
    final sel = c.selection;
    if (sel.isValid && sel.start >= 0) {
      final newText = c.text.replaceRange(sel.start, sel.end, d);
      c.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + d.length),
      );
    } else {
      c.text += d;
    }
    setState(() {});
  }

  void _backspace() {
    final c = _dial;
    if (c.text.isEmpty) return;
    final sel = c.selection;
    if (sel.isValid && sel.start > 0) {
      final start = sel.start;
      final end = sel.end;
      if (start == end) {
        c.value = TextEditingValue(
          text: c.text.replaceRange(start - 1, end, ''),
          selection: TextSelection.collapsed(offset: start - 1),
        );
      } else {
        c.value = TextEditingValue(
          text: c.text.replaceRange(start, end, ''),
          selection: TextSelection.collapsed(offset: start),
        );
      }
    } else {
      c.text = c.text.substring(0, c.text.length - 1);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = widget.canCall && _dial.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _dial,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.2,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Extension or sip:',
                    border: InputBorder.none,
                    filled: false,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              IconButton(
                tooltip: 'Backspace',
                onPressed: _dial.text.isEmpty ? null : _backspace,
                onLongPress: () {
                  _dial.clear();
                  setState(() {});
                },
                icon: const Icon(Icons.backspace_outlined),
              ),
            ],
          ),
          const SizedBox(height: 16),
          DialPad(onKey: _append, onLongZero: () => _append('+')),
          const SizedBox(height: 20),
          SizedBox(
            width: 72,
            height: 72,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: ready
                    ? Colors.green.shade600
                    : theme.disabledColor,
                foregroundColor: Colors.white,
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
              ),
              onPressed: ready ? () => widget.onCall(_dial.text.trim()) : null,
              child: const Icon(Icons.call, size: 32),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Log page
// ---------------------------------------------------------------------------

class _LogPage extends ConsumerWidget {
  const _LogPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final log = ref.watch(logsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('SIP wire log · ${log.length}'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            onPressed: log.isEmpty
                ? null
                : () {
                    Clipboard.setData(
                      ClipboardData(text: log.reversed.join('\n')),
                    );
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('Log copied')));
                  },
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: log.isEmpty
                ? null
                : () => ref.read(logsProvider.notifier).clear(),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: log.isEmpty
          ? Center(
              child: Text(
                'Log is empty',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: log.length,
              itemBuilder: (_, i) => SelectableText(
                log[i],
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
    );
  }
}
