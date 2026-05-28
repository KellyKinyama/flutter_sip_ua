/// Pure-Dart SIP user agent.
///
/// Implements the subset of RFC 3261 needed to interoperate with the
/// dart-pbx server (see ../../../../lib/handlers/requests_handlers.dart):
///
///   * Transports: WebSocket (ws/wss) **and** UDP (RFC 3261 §18.1).
///     Selected automatically from the account's `serverUri` scheme.
///   * REGISTER with MD5 / qop=auth digest, expires negotiation, refresh.
///   * OPTIONS keep-alive (and answering inbound OPTIONS qualifies).
///   * MESSAGE (out-of-dialog).
///   * INVITE / 200 OK / ACK / BYE / CANCEL with a real G.711/RTP media
///     session (mic capture + μ-law/A-law encode + RTP send via the
///     pure-Dart packetizer under `audio/`).
///   * RFC 4028 Session Timers: Session-Expires / Min-SE negotiation,
///     re-INVITE refresh at half-interval (when refresher = uac),
///     hard-timeout BYE when refresher = uas and no refresh arrives,
///     422 Session Interval Too Small handling.
library;

import 'dart:async';
import 'dart:math';

import 'package:uuid/uuid.dart';

import 'audio/audio_sink.dart';
import 'audio/media_session_platform.dart';
import 'digest.dart';
import 'is_web.dart' if (dart.library.io) 'is_web_io.dart';
import 'local_ip.dart' if (dart.library.io) 'local_ip_io.dart' as local_ip;
import 'sdp.dart';
import 'sdp_log.dart' if (dart.library.io) 'sdp_log_io.dart' as sdp_log;
import 'sip_file_logger.dart';
import 'sip_message.dart';
import 'transport.dart';
import 'video/video_codec.dart';
import 'video/video_session_platform.dart';

/// User-visible registration state.
enum RegistrationState { unregistered, registering, registered, failed }

/// User-visible call lifecycle.
enum CallState {
  idle,
  outgoingRinging, // INVITE sent, waiting for 180/200
  incomingRinging, // INVITE received, awaiting answer/decline
  active, // 200 OK / ACK exchanged
  ended, // BYE / CANCEL / failure
}

/// Snapshot of an in-flight or finished call exposed to the UI.
class SipCall {
  SipCall({
    required this.id,
    required this.remoteParty,
    required this.outgoing,
    this.state = CallState.idle,
    this.startedAt,
    this.endedAt,
  });

  final String id;
  final String remoteParty;
  final bool outgoing;
  CallState state;
  DateTime? startedAt;
  DateTime? endedAt;

  /// True while the call is locally or remotely on hold. Mirrors the
  /// internal context held flag and is updated before [_emitCall] so the
  /// UI sees the change reactively.
  bool held = false;
}

class SipAccount {
  const SipAccount({
    required this.username,
    required this.password,
    required this.domain,
    required this.serverUri,
    this.displayName,
    this.sessionExpires = 1800,
    this.minSE = 90,
  });

  final String username;
  final String password;
  final String domain;

  /// Where to connect. Schemes:
  ///  * `ws://host:port`  — plain WebSocket
  ///  * `wss://host:port` — TLS WebSocket
  ///  * `sip:host:port`   — UDP (default port 5060)
  final Uri serverUri;

  final String? displayName;

  /// RFC 4028 desired session interval (seconds).
  final int sessionExpires;

  /// RFC 4028 minimum session interval we will accept.
  final int minSE;

  String get aor => 'sip:$username@$domain';

  /// Backwards-compatible alias for older code that used `wsUri`.
  Uri get wsUri => serverUri;
}

class SipTextMessage {
  SipTextMessage({
    required this.from,
    required this.body,
    required this.receivedAt,
    this.to = '',
    this.outgoing = false,
  });
  final String from;
  final String to;
  final String body;
  final DateTime receivedAt;
  final bool outgoing;

  /// The remote party for this message regardless of direction. Useful when
  /// grouping messages into a per-buddy thread.
  String get peer => outgoing ? to : from;
}

class SipUserAgent {
  SipUserAgent({
    Random? rng,
    AudioSink Function(void Function(String) log)? audioSinkFactory,
    String? publicMediaAddress,
    RtpPacketTap? rtpPacketTap,
  }) : _rng = rng ?? Random.secure(),
       _digest = DigestClient(),
       _audioSinkFactory = audioSinkFactory,
       _publicMediaAddress = publicMediaAddress,
       _rtpPacketTap = rtpPacketTap;

  final Random _rng;
  final DigestClient _digest;
  final AudioSink Function(void Function(String) log)? _audioSinkFactory;
  final _uuid = const Uuid();

  /// Optional override for the host advertised in `c=` / `o=` of every
  /// SDP we emit. Useful when this client sits behind NAT or in a
  /// container where the socket-local IP isn't reachable by the peer.
  /// When null, falls back to the SIP transport's local host.
  final String? _publicMediaAddress;

  /// Cached non-loopback IPv4 of this host, discovered once the transport
  /// connects. Used by [_mediaLocalHost] when the transport itself can't
  /// tell us our local address (the WebSocket transports report the peer's
  /// host as `localHost`, which would otherwise end up in our SDP).
  String? _discoveredLocalIp;

  /// Optional RTP/RTCP packet tap. See [RtpPacketTap].
  final RtpPacketTap? _rtpPacketTap;

  /// Optional sink that records every wire-format SIP message to disk.
  /// Set with [attachFileLogger] before calling [start] for full coverage.
  SipFileLogger? _fileLogger;

  /// Dedicated SDP-only debug log at a fixed path. Opened in [start]
  /// (truncated each launch) so an out-of-band reader can always find
  /// the latest negotiation at the same filename — no need to chase a
  /// new timestamped path every run.
  sdp_log.SdpLog? _sdpLog;

  SipAccount? _account;
  SipTransport? _transport;
  StreamSubscription<SipMessage>? _msgSub;
  StreamSubscription<TransportState>? _stateSub;
  Timer? _registerTimer;
  Timer? _keepAliveTimer;

  // Registration bookkeeping.
  String? _regCallId;
  String _regFromTag = '';
  int _regCseq = 0;
  int _registrationExpires = 600;
  int _registerAttempts = 0;
  DigestChallenge? _pendingChallenge;

  final Map<String, _CallContext> _calls = {};

  final _registrationCtl = StreamController<RegistrationState>.broadcast();
  final _callCtl = StreamController<SipCall>.broadcast();
  final _messageCtl = StreamController<SipTextMessage>.broadcast();
  final _logCtl = StreamController<String>.broadcast();

  Stream<RegistrationState> get registrationStream => _registrationCtl.stream;
  Stream<SipCall> get callStream => _callCtl.stream;
  Stream<SipTextMessage> get messageStream => _messageCtl.stream;
  Stream<String> get logStream => _logCtl.stream;

  RegistrationState _regState = RegistrationState.unregistered;
  RegistrationState get registrationState => _regState;
  SipAccount? get account => _account;

  /// Snapshot of the call with [callId], or `null` if no such call is
  /// active. Lets the UI seed itself synchronously instead of waiting for
  /// the next [callStream] emission (which broadcast semantics don't
  /// replay).
  SipCall? callById(String callId) => _calls[callId]?.call;

  /// Attach a wire-format file logger. Every subsequent inbound/outbound
  /// SIP message is written to [logger]'s file verbatim.
  void attachFileLogger(SipFileLogger logger) {
    _fileLogger = logger;
    _log('file logger: writing wire dump to ${logger.path}');
  }

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  Future<void> start(SipAccount account) async {
    await stop();
    _account = account;
    try {
      _sdpLog = sdp_log.openSdpLog();
      final p = _sdpLog?.path;
      if (p != null) _log('sdp log: writing SDP exchanges to $p');
    } catch (e) {
      _log('sdp log: failed to open: $e');
      _sdpLog = null;
    }
    final transport = SipTransport.forUri(account.serverUri);
    _transport = transport;
    _stateSub = transport.state.listen(_onTransportState);
    _msgSub = transport.messages.listen(_onMessage);
    await transport.connect();
    // Resolve a real local IPv4 in the background — used to populate
    // SDP c=/o= lines for WS/WSS transports that don't know our own host.
    // ignore: discarded_futures
    _refreshLocalIp();
    _register(expires: _registrationExpires);
  }

  Future<void> _refreshLocalIp() async {
    try {
      final acc = _account;
      final u = acc?.serverUri;
      _sdpLog?.writeln('');
      _sdpLog?.writeln('--- local IPv4 discovery ---');
      final ip = await local_ip.discoverLocalIpv4(
        targetHost: u?.host,
        targetPort: (u != null && u.hasPort) ? u.port : 0,
        debug: (line) {
          _log('media: $line');
          _sdpLog?.writeln('# $line');
        },
      );
      if (ip != null && ip.isNotEmpty) {
        _discoveredLocalIp = ip;
        _log(
          'media: discovered local IPv4 $ip for SDP c=/o= (route to ${u?.host ?? "?"})',
        );
        _sdpLog?.writeln('# media: discovered local IPv4 $ip');
      } else {
        _log(
          'media: WARN could not discover a local IPv4; SDP will use loopback',
        );
        _sdpLog?.writeln('# media: WARN no local IPv4 discovered');
      }
    } catch (_) {
      /* best effort */
    }
  }

  Future<void> stop() async {
    _registerTimer?.cancel();
    _registerTimer = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    for (final ctx in _calls.values.toList()) {
      ctx.cancelTimers();
    }
    if (_transport != null &&
        _account != null &&
        _regState == RegistrationState.registered) {
      try {
        _register(expires: 0);
      } catch (_) {}
    }
    await _msgSub?.cancel();
    await _stateSub?.cancel();
    await _transport?.close();
    _msgSub = null;
    _stateSub = null;
    _transport = null;
    final sdpLog = _sdpLog;
    _sdpLog = null;
    if (sdpLog != null) {
      try {
        await sdpLog.close();
      } catch (_) {}
    }
    _setRegState(RegistrationState.unregistered);
  }

  // ===========================================================================
  // Public actions
  // ===========================================================================

  Future<SipCall?> makeCall(
    String target, {
    bool withVideo = false,
    VideoEncoder? videoEncoder,
    VideoDecoder? videoDecoder,
  }) async {
    final acc = _account;
    final tx = _transport;
    if (acc == null || tx == null || !tx.isConnected) return null;
    if (isWeb) {
      _log(
        'makeCall: rejected — RTP media (UDP) is not supported on web. '
        'Outgoing audio/video calls require a native build.',
      );
      return null;
    }
    final targetUri = _normaliseTarget(target, acc.domain);
    final callId = _uuid.v4();
    final fromTag = _shortTag();
    final branch = _branch();
    final cseq = _nextCseq();

    // Bind a local RTP port and put it in our SDP offer.
    final media = MediaSession(
      sink: _audioSinkFactory?.call(_mediaLogSink),
      packetTap: _rtpPacketTap,
    );
    final rtpPort = await media.bindLocalPort();

    VideoSession? video;
    int? videoPort;
    if (withVideo) {
      video = VideoSession(encoder: videoEncoder, decoder: videoDecoder);
      videoPort = await video.bindLocalPort();
    }

    final sdpSid = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final body = video == null
        ? buildG711Offer(
            username: acc.username,
            localHost: _mediaLocalHost(),
            localPort: rtpPort,
            rtcpPort: media.localRtcpPort,
            sessionId: sdpSid,
            sessionVersion: sdpSid,
          )
        : buildAvOffer(
            username: acc.username,
            localHost: _mediaLocalHost(),
            audioPort: rtpPort,
            videoPort: videoPort,
            audioRtcpPort: media.localRtcpPort,
            sessionId: sdpSid,
            sessionVersion: sdpSid,
          );

    final extra = <String, String>{
      'Content-Type': 'application/sdp',
      // RFC 4028: advertise session timer support and propose interval.
      'Supported': 'timer',
      'Session-Expires': '${acc.sessionExpires};refresher=uac',
      'Min-SE': '${acc.minSE}',
    };
    final invite = _buildRequest(
      method: 'INVITE',
      requestUri: targetUri,
      callId: callId,
      fromTag: fromTag,
      cseq: cseq,
      branch: branch,
      target: targetUri,
      account: acc,
      extra: extra,
      body: body,
    );

    final ctx = _CallContext(
      call: SipCall(
        id: callId,
        remoteParty: targetUri,
        outgoing: true,
        state: CallState.outgoingRinging,
        startedAt: DateTime.now(),
      ),
      localTag: fromTag,
      cseq: cseq,
      lastInvite: invite,
      branch: branch,
      proposedSE: acc.sessionExpires,
      minSE: acc.minSE,
      sdpSessionId: sdpSid,
    );
    ctx.media = media;
    ctx.video = video;
    _calls[callId] = ctx;
    _emitCall(ctx.call);
    _send(invite);
    return ctx.call;
  }

  /// Toggle whether mic input is dropped on the wire for [callId]. Returns
  /// the new muted state, or `null` if the call isn't active.
  bool? setMuted(String callId, bool muted) {
    final media = _calls[callId]?.media;
    if (media == null) return null;
    media.muted = muted;
    return media.muted;
  }

  /// Convenience: returns whether [callId] is currently muted, or `null`
  /// if the call has no active media.
  bool? isMuted(String callId) => _calls[callId]?.media?.muted;

  /// Place [callId] on hold (or resume it). Sends a re-INVITE with
  /// `a=sendonly` (hold) or `a=sendrecv` (resume). The local mic is also
  /// muted while held so we don't keep streaming audio after the peer
  /// stops listening. Returns the new held state, or `null` if the call
  /// isn't active.
  bool? setHold(String callId, bool hold) {
    final ctx = _calls[callId];
    if (ctx == null) return null;
    if (ctx.call.state != CallState.active) return null;
    if (ctx.held == hold) return ctx.held;
    ctx.held = hold;
    ctx.call.held = hold;
    final media = ctx.media;
    if (media != null) media.muted = hold;
    _sendReinvite(ctx);
    _emitCall(ctx.call);
    return ctx.held;
  }

  /// Whether [callId] is currently on hold.
  bool? isHeld(String callId) => _calls[callId]?.held;

  void hangup(String callId) {
    final ctx = _calls[callId];
    if (ctx == null) return;
    final acc = _account;
    if (acc == null) return;

    if (ctx.call.state == CallState.outgoingRinging) {
      final cancel = _buildRequest(
        method: 'CANCEL',
        requestUri: ctx.call.remoteParty,
        callId: callId,
        fromTag: ctx.localTag,
        cseq: ctx.cseq,
        branch: ctx.branch,
        target: ctx.call.remoteParty,
        account: acc,
        toTag: ctx.remoteTag,
      );
      cancel.setHeader('CSeq', '${ctx.cseq} CANCEL');
      _send(cancel);
    } else if (ctx.call.state == CallState.incomingRinging) {
      _respondToInvite(ctx, code: 603, reason: 'Decline');
    } else if (ctx.call.state == CallState.active) {
      final cseq = _nextCseq();
      final bye = _buildRequest(
        method: 'BYE',
        requestUri: ctx.remoteContact ?? ctx.call.remoteParty,
        callId: callId,
        fromTag: ctx.localTag,
        cseq: cseq,
        branch: _branch(),
        target: ctx.remoteContact ?? ctx.call.remoteParty,
        account: acc,
        toTag: ctx.remoteTag,
      );
      _send(bye);
    }
    _markEnded(ctx);
  }

  Future<void> answer(
    String callId, {
    VideoEncoder? videoEncoder,
    VideoDecoder? videoDecoder,
  }) async {
    final ctx = _calls[callId];
    if (ctx == null || ctx.call.state != CallState.incomingRinging) return;
    final acc = _account;
    if (acc == null) return;
    if (isWeb) {
      _log(
        'answer: rejected — RTP media (UDP) is not supported on web. '
        'Answering audio/video calls requires a native build.',
      );
      return;
    }

    // Bind RTP socket and parse the peer's offer so we know where to send.
    final media = MediaSession(
      sink: _audioSinkFactory?.call(_mediaLogSink),
      packetTap: _rtpPacketTap,
    );
    final rtpPort = await media.bindLocalPort();
    ctx.media = media;
    final offer = parseSdp(ctx.lastInvite.body);
    final remoteAudio = offer.audio;
    final remoteVideo = offer.video;
    if (remoteAudio != null) {
      ctx.negotiatedAudioCodec = remoteAudio.codec;
      ctx.negotiatedDtmfPt = remoteAudio.telephoneEventPt;
      ctx.negotiatedDtmfRange = remoteAudio.telephoneEventRange;
    }

    VideoSession? video;
    int? videoPort;
    if (remoteVideo != null) {
      video = VideoSession(encoder: videoEncoder, decoder: videoDecoder);
      videoPort = await video.bindLocalPort();
      ctx.video = video;
    }

    final answerSdp = video == null
        ? (remoteAudio == null
              ? buildG711Offer(
                  username: acc.username,
                  localHost: _mediaLocalHost(),
                  localPort: rtpPort,
                  rtcpPort: media.localRtcpPort,
                  sessionId: ctx.sdpSessionId,
                  sessionVersion: ctx.bumpSdpVersion(),
                )
              : buildG711Answer(
                  username: acc.username,
                  localHost: _mediaLocalHost(),
                  localPort: rtpPort,
                  remoteOffer: remoteAudio,
                  rtcpPort: media.localRtcpPort,
                  sessionId: ctx.sdpSessionId,
                  sessionVersion: ctx.bumpSdpVersion(),
                ))
        : buildAvOffer(
            username: acc.username,
            localHost: _mediaLocalHost(),
            audioPort: rtpPort,
            videoPort: videoPort,
            audioRtcpPort: media.localRtcpPort,
            audioPreferred: remoteAudio?.codec ?? G711Variant.pcmu,
            audioSecond: null,
            telephoneEventPt: remoteAudio?.telephoneEventPt,
            telephoneEventRange: remoteAudio?.telephoneEventRange ?? '0-15',
            videoPayloadType: remoteVideo!.payloadType,
            videoCodec: remoteVideo.codec,
            sessionId: ctx.sdpSessionId,
            sessionVersion: ctx.bumpSdpVersion(),
          );

    // RFC 4028: if the peer asked for timers, accept and choose refresher.
    final extra = <String, String>{};
    if (ctx.proposedSE != null) {
      // If peer didn't pin a refresher, take the role ourselves (uas).
      ctx.refresher ??= 'uas';
      extra['Require'] = 'timer';
      extra['Session-Expires'] = '${ctx.proposedSE};refresher=${ctx.refresher}';
    }
    _respondToInvite(
      ctx,
      code: 200,
      reason: 'OK',
      sdp: answerSdp,
      extra: extra,
    );
    ctx.call.state = CallState.active;
    _emitCall(ctx.call);
    _armSessionTimers(ctx);
    if (remoteAudio != null) {
      try {
        final ep = remoteAudio.toEndpoint();
        final line =
            'media(answer): localRtp=${_mediaLocalHost()}:$rtpPort '
            '-> remoteRtp=${ep.host}:${ep.port} codec=${ep.codec.name}';
        _log(line);
        _sdpLog?.writeln('# $line');
        await media.start(ep);
        _startRtpStatsLogger(ctx);
      } catch (e) {
        _log('media: failed to start: $e');
      }
    }
    if (video != null && remoteVideo != null) {
      try {
        await video.start(VideoEndpoint.fromSdp(remoteVideo));
      } catch (e) {
        _log('video: failed to start: $e');
      }
    }
  }

  /// Send an RFC 4733 DTMF digit on an active call. No-op if the call
  /// isn't active or DTMF wasn't negotiated.
  Future<void> sendDtmf(
    String callId,
    String digit, {
    Duration duration = const Duration(milliseconds: 200),
  }) async {
    final ctx = _calls[callId];
    if (ctx == null || ctx.call.state != CallState.active) return;
    final media = ctx.media;
    if (media == null) return;
    try {
      await media.sendDtmf(digit, duration: duration);
    } catch (e) {
      _log('dtmf: $e');
    }
  }

  void sendMessage(String target, String text) {
    final acc = _account;
    if (acc == null) return;
    final targetUri = _normaliseTarget(target, acc.domain);
    final callId = _uuid.v4();
    final msg = _buildRequest(
      method: 'MESSAGE',
      requestUri: targetUri,
      callId: callId,
      fromTag: _shortTag(),
      cseq: _nextCseq(),
      branch: _branch(),
      target: targetUri,
      account: acc,
      extra: {'Content-Type': 'text/plain'},
      body: text,
    );
    _send(msg);
    // Echo the outbound message into the message stream so that UIs which
    // render two-sided threads can show the sent line immediately.
    _messageCtl.add(
      SipTextMessage(
        from: acc.aor,
        to: targetUri,
        body: text,
        receivedAt: DateTime.now(),
        outgoing: true,
      ),
    );
  }

  /// Blind-transfer the active call [callId] to [target] using an
  /// in-dialog REFER (RFC 3515). The peer should answer `202 Accepted`
  /// and then drive a new INVITE to [target] on its own; subsequent
  /// NOTIFY traffic is acknowledged but not surfaced to the UI.
  ///
  /// Returns `false` if the call isn't currently active.
  bool transferBlind(String callId, String target) {
    final ctx = _calls[callId];
    final acc = _account;
    if (ctx == null || acc == null) return false;
    if (ctx.call.state != CallState.active) return false;
    final targetUri = _normaliseTarget(target, acc.domain);
    _sendRefer(ctx: ctx, acc: acc, referTo: '<$targetUri>');
    _log('transfer (blind): ${ctx.call.id} -> $targetUri');
    return true;
  }

  /// Attended (consultative) transfer: ask the peer of [callId] to
  /// replace its leg with the already-established consultation call
  /// [replaceCallId] via RFC 3891 `Replaces`. Both calls must be active
  /// (typically the consultation call was put on hold first).
  ///
  /// Returns `false` if either call isn't active.
  bool transferAttended(String callId, String replaceCallId) {
    final ctx = _calls[callId];
    final replace = _calls[replaceCallId];
    final acc = _account;
    if (ctx == null || replace == null || acc == null) return false;
    if (ctx.call.state != CallState.active) return false;
    if (replace.call.state != CallState.active) return false;
    final remoteTag = replace.remoteTag;
    if (remoteTag == null) return false;
    final newTarget = replace.remoteContact ?? replace.call.remoteParty;
    // Replaces parameter goes inside the URI, semicolons must be escaped.
    final replaces = Uri.encodeComponent(
      '${replace.call.id};to-tag=$remoteTag;from-tag=${replace.localTag}',
    );
    _sendRefer(ctx: ctx, acc: acc, referTo: '<$newTarget?Replaces=$replaces>');
    _log(
      'transfer (attended): $callId replaced by $replaceCallId -> $newTarget',
    );
    return true;
  }

  void _sendRefer({
    required _CallContext ctx,
    required SipAccount acc,
    required String referTo,
  }) {
    final cseq = _nextCseq();
    final dlgTarget = ctx.remoteContact ?? ctx.call.remoteParty;
    final refer = _buildRequest(
      method: 'REFER',
      requestUri: dlgTarget,
      callId: ctx.call.id,
      fromTag: ctx.localTag,
      cseq: cseq,
      branch: _branch(),
      target: dlgTarget,
      account: acc,
      toTag: ctx.remoteTag,
      extra: {'Refer-To': referTo, 'Referred-By': '<${acc.aor}>'},
    );
    ctx.cseq = cseq;
    _send(refer);
  }

  // ===========================================================================
  // Inbound dispatch
  // ===========================================================================

  void _onTransportState(TransportState s) {
    _log('transport: $s');
    _fileLogger?.note('transport: $s');
    switch (s) {
      case TransportState.connecting:
        _setRegState(RegistrationState.registering);
        break;
      case TransportState.connected:
        _scheduleKeepAlive();
        break;
      case TransportState.disconnected:
        _keepAliveTimer?.cancel();
        _keepAliveTimer = null;
        _setRegState(RegistrationState.unregistered);
        break;
    }
  }

  void _onMessage(SipMessage msg) {
    _fileLogger?.log('IN ', msg);
    _log(
      '<-- ${msg.isResponse ? "${msg.statusCode} ${msg.reasonPhrase}" : "${msg.method} ${msg.requestUri}"}',
    );
    _logSdpIfPresent('IN', msg);
    if (msg.isResponse) {
      // Surface the server's reason on failure so the user/dev can read why
      // a call was rejected (e.g. Asterisk's 488 'SDP not acceptable').
      final code = msg.statusCode ?? 0;
      if (code >= 300) {
        final warning = msg.header('Warning');
        if (warning != null) _log('    Warning: $warning');
        final body = msg.body.trim();
        if (body.isNotEmpty) {
          for (final line in body.split('\n')) {
            final t = line.trimRight();
            if (t.isNotEmpty) _log('    | $t');
          }
        }
      }
      _onResponse(msg);
    } else {
      _onRequest(msg);
    }
  }

  void _onResponse(SipMessage msg) {
    final cseqMethod = msg.cseqMethod;
    final code = msg.statusCode!;
    final callId = msg.callId;

    if (cseqMethod == 'REGISTER' && callId == _regCallId) {
      _onRegisterResponse(msg);
      return;
    }
    if (callId == null) return;
    final ctx = _calls[callId];
    if (ctx == null) return;

    if (cseqMethod == 'INVITE') {
      if (msg.toTag != null) ctx.remoteTag = msg.toTag;
      if (code >= 100 && code < 200) {
        if (code != 100) {
          ctx.call.state = CallState.outgoingRinging;
          _emitCall(ctx.call);
        }
      } else if (code >= 200 && code < 300) {
        ctx.remoteContact = _firstContactUri(msg) ?? ctx.remoteContact;
        _absorbSessionExpires(ctx, msg, weAreUac: true);
        _sendAck(ctx, msg);
        final wasRefresh = ctx.call.state == CallState.active;
        ctx.call.state = CallState.active;
        _emitCall(ctx.call);
        if (!wasRefresh) {
          _armSessionTimers(ctx);
          // Start mic + RTP from the peer's answer SDP.
          final answer = parseSdp(msg.body);
          final remoteAudio = answer.audio;
          final remoteVideo = answer.video;
          if (remoteAudio != null) {
            ctx.negotiatedAudioCodec = remoteAudio.codec;
            ctx.negotiatedDtmfPt = remoteAudio.telephoneEventPt;
            ctx.negotiatedDtmfRange = remoteAudio.telephoneEventRange;
          }
          final media = ctx.media;
          if (media != null && remoteAudio != null) {
            final ep = remoteAudio.toEndpoint();
            final line =
                'media(invite-200): localRtp=${_mediaLocalHost()}:${media.localPort} '
                '-> remoteRtp=${ep.host}:${ep.port} codec=${ep.codec.name}';
            _log(line);
            _sdpLog?.writeln('# $line');
            media.start(ep).catchError((e) {
              _log('media: failed to start: $e');
            });
            _startRtpStatsLogger(ctx);
          }
          final video = ctx.video;
          if (video != null && remoteVideo != null) {
            video.start(VideoEndpoint.fromSdp(remoteVideo)).catchError((e) {
              _log('video: failed to start: $e');
            });
          }
        } else {
          // Re-arm after a successful refresh.
          _armSessionTimers(ctx);
        }
      } else if (code == 401 || code == 407) {
        _retryInviteWithAuth(ctx, msg);
      } else if (code == 422) {
        // Session Interval Too Small — bump Min-SE and resend INVITE.
        _retryInviteWith422(ctx, msg);
      } else {
        _markEnded(ctx);
      }
    } else if (cseqMethod == 'BYE' || cseqMethod == 'CANCEL') {
      _markEnded(ctx);
    }
  }

  void _onRequest(SipMessage msg) {
    final method = msg.method!.toUpperCase();
    switch (method) {
      case 'OPTIONS':
        _send(_buildResponseFor(msg, 200, 'OK'));
        return;
      case 'INVITE':
        _onInboundInvite(msg);
        return;
      case 'ACK':
        return;
      case 'BYE':
        _send(_buildResponseFor(msg, 200, 'OK'));
        final ctx = _calls[msg.callId];
        if (ctx != null) _markEnded(ctx);
        return;
      case 'CANCEL':
        _send(_buildResponseFor(msg, 200, 'OK'));
        final ctx = _calls[msg.callId];
        if (ctx != null && ctx.call.state == CallState.incomingRinging) {
          _respondToInvite(ctx, code: 487, reason: 'Request Terminated');
          _markEnded(ctx);
        }
        return;
      case 'UPDATE':
        // Honour an UPDATE-style session refresh (RFC 4028 §11) by echoing
        // the negotiated Session-Expires.
        final ctx = _calls[msg.callId];
        if (ctx == null) {
          _send(_buildResponseFor(msg, 481, 'Call/Transaction Does Not Exist'));
          return;
        }
        _absorbSessionExpiresFromRequest(ctx, msg);
        final extra = <String, String>{};
        if (ctx.negotiatedSE != null) {
          extra['Session-Expires'] =
              '${ctx.negotiatedSE};refresher=${ctx.refresher ?? 'uac'}';
          extra['Require'] = 'timer';
        }
        _send(
          _buildResponseFor(
            msg,
            200,
            'OK',
            addToTag: ctx.localTag,
            extra: extra,
          ),
        );
        _armSessionTimers(ctx);
        return;
      case 'MESSAGE':
        _send(_buildResponseFor(msg, 200, 'OK'));
        final from = extractUri(msg.header('From') ?? '');
        _messageCtl.add(
          SipTextMessage(
            from: from,
            body: msg.body,
            receivedAt: DateTime.now(),
          ),
        );
        return;
      case 'NOTIFY':
      case 'INFO':
        _send(_buildResponseFor(msg, 200, 'OK'));
        return;
      case 'REFER':
        // Accept the REFER but don't yet drive a new INVITE — the
        // referrer expects a 202 + NOTIFYs. We acknowledge here so the
        // dialog stays alive, then emit a log line so API consumers can
        // react via /events.
        final ctx = _calls[msg.callId];
        if (ctx == null) {
          _send(_buildResponseFor(msg, 481, 'Call/Transaction Does Not Exist'));
          return;
        }
        _send(_buildResponseFor(msg, 202, 'Accepted', addToTag: ctx.localTag));
        final referTo = msg.header('Refer-To') ?? '';
        _log('refer: ${ctx.call.id} <- $referTo');
        return;
      default:
        _send(_buildResponseFor(msg, 405, 'Method Not Allowed'));
    }
  }

  void _onInboundInvite(SipMessage msg) {
    final callId = msg.callId;
    if (callId == null) return;

    // Re-INVITE within an existing dialog: treat as a session refresh.
    final existing = _calls[callId];
    if (existing != null && existing.call.state == CallState.active) {
      _absorbSessionExpiresFromRequest(existing, msg);

      // Detect peer-initiated hold/resume from the offer's media direction.
      // RFC 3264 §8.4: peer's `a=sendonly` / `a=inactive` puts us on hold.
      final offered = parseSdpAudio(msg.body);
      if (offered != null) {
        final wasHeld = existing.held;
        final peerHolds =
            offered.direction == SdpDirection.sendonly ||
            offered.direction == SdpDirection.inactive;
        if (peerHolds != wasHeld) {
          existing.held = peerHolds;
          existing.call.held = peerHolds;
          // Stop sending audio while the peer holds us; resume on unhold.
          existing.media?.muted = peerHolds;
          _emitCall(existing.call);
        }
      }

      final extra = <String, String>{};
      if (existing.negotiatedSE != null) {
        extra['Session-Expires'] =
            '${existing.negotiatedSE};refresher=${existing.refresher ?? 'uac'}';
        extra['Require'] = 'timer';
      }
      final acc = _account;
      _send(
        _buildResponseFor(
          msg,
          200,
          'OK',
          addToTag: existing.localTag,
          sdp: acc == null
              ? null
              : _buildAnswerSdpForCall(existing, acc, offered),
          extra: extra,
        ),
      );
      existing.lastInvite = msg;
      _armSessionTimers(existing);
      return;
    }
    if (existing != null) return;

    _send(_buildResponseFor(msg, 100, 'Trying'));
    final localTag = _shortTag();

    // Pre-screen Session-Expires so we can reject early with 422 if needed.
    final acc = _account;
    final wantedMin = acc?.minSE ?? 90;
    final hdr = msg.header('Session-Expires') ?? msg.header('x');
    int? proposedSE;
    String? refresher;
    if (hdr != null) {
      final parsed = _parseSessionExpires(hdr);
      proposedSE = parsed.expires;
      refresher = parsed.refresher;
      if (proposedSE != null && proposedSE < wantedMin) {
        _send(
          _buildResponseFor(
            msg,
            422,
            'Session Interval Too Small',
            extra: {'Min-SE': '$wantedMin'},
          ),
        );
        return;
      }
    }

    final ringing = _buildResponseFor(msg, 180, 'Ringing', addToTag: localTag);
    _send(ringing);

    final from = extractUri(msg.header('From') ?? '');
    final ctx = _CallContext(
      call: SipCall(
        id: callId,
        remoteParty: from,
        outgoing: false,
        state: CallState.incomingRinging,
        startedAt: DateTime.now(),
      ),
      localTag: localTag,
      cseq: msg.cseqNumber ?? 0,
      lastInvite: msg,
      branch: _branch(),
      proposedSE: proposedSE,
      minSE: wantedMin,
    );
    ctx.refresher = refresher;
    ctx.remoteTag = msg.fromTag;
    ctx.remoteContact = _firstContactUri(msg);
    _calls[callId] = ctx;
    _emitCall(ctx.call);
  }

  // ===========================================================================
  // Session timers (RFC 4028)
  // ===========================================================================

  void _absorbSessionExpires(
    _CallContext ctx,
    SipMessage msg, {
    required bool weAreUac,
  }) {
    final hdr = msg.header('Session-Expires') ?? msg.header('x');
    if (hdr == null) {
      ctx.negotiatedSE = null;
      ctx.refresher = null;
      return;
    }
    final parsed = _parseSessionExpires(hdr);
    if (parsed.expires == null) return;
    ctx.negotiatedSE = parsed.expires;
    ctx.refresher = parsed.refresher ?? (weAreUac ? 'uac' : 'uas');
  }

  void _absorbSessionExpiresFromRequest(_CallContext ctx, SipMessage req) {
    final hdr = req.header('Session-Expires') ?? req.header('x');
    if (hdr == null) return;
    final parsed = _parseSessionExpires(hdr);
    if (parsed.expires != null) ctx.negotiatedSE = parsed.expires;
    if (parsed.refresher != null) ctx.refresher = parsed.refresher;
  }

  _SessionExpires _parseSessionExpires(String value) {
    final parts = value.split(';');
    final expires = int.tryParse(parts.first.trim());
    String? refresher;
    for (var i = 1; i < parts.length; i++) {
      final p = parts[i].trim();
      if (p.toLowerCase().startsWith('refresher=')) {
        refresher = p.substring('refresher='.length).trim().toLowerCase();
      }
    }
    return _SessionExpires(expires: expires, refresher: refresher);
  }

  void _armSessionTimers(_CallContext ctx) {
    ctx.cancelTimers();
    final se = ctx.negotiatedSE;
    if (se == null) return;
    if (ctx.refresher == 'uac') {
      // Refresh at half-interval.
      final delay = Duration(seconds: (se / 2).floor().clamp(1, 1 << 30));
      ctx.refreshTimer = Timer(delay, () => _sendRefreshInvite(ctx));
      _log('session-timer: will refresh ${ctx.call.id} in ${delay.inSeconds}s');
    } else {
      // Peer refreshes; arm a hard timeout after full interval (+ small grace).
      final delay = Duration(seconds: se + 32);
      ctx.expiryTimer = Timer(delay, () {
        _log(
          'session-timer: peer missed refresh, sending BYE on ${ctx.call.id}',
        );
        hangup(ctx.call.id);
      });
    }
  }

  void _sendRefreshInvite(_CallContext ctx) {
    final acc = _account;
    if (acc == null) return;
    if (ctx.call.state != CallState.active) return;
    final newCseq = _nextCseq();
    final newBranch = _branch();
    final target = ctx.remoteContact ?? ctx.call.remoteParty;
    final extra = <String, String>{
      'Content-Type': 'application/sdp',
      'Supported': 'timer',
      'Session-Expires':
          '${ctx.negotiatedSE ?? acc.sessionExpires};refresher=uac',
      'Min-SE': '${ctx.minSE ?? acc.minSE}',
    };
    final invite = _buildRequest(
      method: 'INVITE',
      requestUri: target,
      callId: ctx.call.id,
      fromTag: ctx.localTag,
      cseq: newCseq,
      branch: newBranch,
      target: target,
      account: acc,
      toTag: ctx.remoteTag,
      extra: extra,
      body: _buildOfferSdpForCall(ctx, acc),
    );
    ctx.cseq = newCseq;
    ctx.branch = newBranch;
    ctx.lastInvite = invite;
    _send(invite);
  }

  /// Send a re-INVITE that re-negotiates the media direction (used for
  /// hold/resume). Reuses the existing dialog and the bound RTP port.
  void _sendReinvite(_CallContext ctx) {
    final acc = _account;
    if (acc == null) return;
    final newCseq = _nextCseq();
    final newBranch = _branch();
    final target = ctx.remoteContact ?? ctx.call.remoteParty;
    final extra = <String, String>{
      'Content-Type': 'application/sdp',
      if (ctx.negotiatedSE != null) ...{
        'Supported': 'timer',
        'Session-Expires':
            '${ctx.negotiatedSE};refresher=${ctx.refresher ?? 'uac'}',
        'Min-SE': '${ctx.minSE ?? acc.minSE}',
      },
    };
    final invite = _buildRequest(
      method: 'INVITE',
      requestUri: target,
      callId: ctx.call.id,
      fromTag: ctx.localTag,
      cseq: newCseq,
      branch: newBranch,
      target: target,
      account: acc,
      toTag: ctx.remoteTag,
      extra: extra,
      body: _buildOfferSdpForCall(ctx, acc),
    );
    ctx.cseq = newCseq;
    ctx.branch = newBranch;
    ctx.lastInvite = invite;
    _send(invite);
  }

  void _retryInviteWith422(_CallContext ctx, SipMessage resp) {
    final acc = _account;
    if (acc == null) return;
    final minHdr = resp.header('Min-SE');
    final newMin = int.tryParse(minHdr ?? '') ?? (ctx.minSE ?? 90) * 2;
    ctx.minSE = newMin;
    final newSE = newMin > (ctx.proposedSE ?? acc.sessionExpires)
        ? newMin
        : (ctx.proposedSE ?? acc.sessionExpires);
    ctx.proposedSE = newSE;

    // ACK the 422 first.
    _sendAck(ctx, resp);

    final newCseq = _nextCseq();
    final newBranch = _branch();
    final extra = <String, String>{
      'Content-Type': 'application/sdp',
      'Supported': 'timer',
      'Session-Expires': '$newSE;refresher=uac',
      'Min-SE': '$newMin',
    };
    final invite = _buildRequest(
      method: 'INVITE',
      requestUri: ctx.call.remoteParty,
      callId: ctx.call.id,
      fromTag: ctx.localTag,
      cseq: newCseq,
      branch: newBranch,
      target: ctx.call.remoteParty,
      account: acc,
      extra: extra,
      body: _buildOfferSdpForCall(ctx, acc),
    );
    ctx.cseq = newCseq;
    ctx.branch = newBranch;
    ctx.lastInvite = invite;
    _send(invite);
  }

  // ===========================================================================
  // REGISTER
  // ===========================================================================

  void _register({required int expires}) {
    final acc = _account;
    final tx = _transport;
    if (acc == null || tx == null) return;
    _regCallId ??= _uuid.v4();
    if (_regFromTag.isEmpty) _regFromTag = _shortTag();
    _regCseq++;
    _registerAttempts = 0;
    _setRegState(
      expires == 0
          ? RegistrationState.unregistered
          : RegistrationState.registering,
    );
    _send(_buildRegister(acc, expires: expires));
  }

  SipMessage _buildRegister(SipAccount acc, {required int expires}) {
    final registrarUri = 'sip:${acc.domain}';
    final req = _buildRequest(
      method: 'REGISTER',
      requestUri: registrarUri,
      callId: _regCallId!,
      fromTag: _regFromTag,
      cseq: _regCseq,
      branch: _branch(),
      target: acc.aor,
      account: acc,
      extra: {
        'Expires': '$expires',
        'Allow':
            'INVITE, ACK, CANCEL, BYE, MESSAGE, OPTIONS, NOTIFY, INFO, UPDATE, REFER',
        'Supported': 'timer, replaces',
      },
    );
    final challenge = _pendingChallenge;
    if (challenge != null) {
      final auth = _digest.authorize(
        challenge: challenge,
        username: acc.username,
        password: acc.password,
        method: 'REGISTER',
        uri: registrarUri,
      );
      req.setHeader('Authorization', 'Digest $auth');
    }
    return req;
  }

  void _onRegisterResponse(SipMessage msg) {
    final code = msg.statusCode!;
    if (code == 401 || code == 407) {
      if (_registerAttempts >= 2) {
        _setRegState(RegistrationState.failed);
        return;
      }
      _registerAttempts++;
      final hdr =
          msg.header(code == 401 ? 'WWW-Authenticate' : 'Proxy-Authenticate') ??
          '';
      _pendingChallenge = DigestChallenge.fromParams(parseAuthHeader(hdr));
      final acc = _account;
      if (acc == null) return;
      _regCseq++;
      _send(_buildRegister(acc, expires: _registrationExpires));
      return;
    }
    if (code >= 200 && code < 300) {
      final contact = msg.header('Contact');
      int? granted;
      if (contact != null) {
        final m = RegExp(
          r'expires=(\d+)',
          caseSensitive: false,
        ).firstMatch(contact);
        if (m != null) granted = int.tryParse(m.group(1)!);
      }
      granted ??= int.tryParse(msg.header('Expires') ?? '');
      if (granted != null && granted > 0) {
        _registrationExpires = granted;
        final refreshIn = (granted * 0.8).floor();
        _registerTimer?.cancel();
        _registerTimer = Timer(
          Duration(seconds: refreshIn),
          () => _register(expires: _registrationExpires),
        );
        _setRegState(RegistrationState.registered);
      } else {
        _setRegState(RegistrationState.unregistered);
      }
      return;
    }
    if (code >= 400) {
      _setRegState(RegistrationState.failed);
    }
  }

  // ===========================================================================
  // Builders
  // ===========================================================================

  SipMessage _buildRequest({
    required String method,
    required String requestUri,
    required String callId,
    required String fromTag,
    required int cseq,
    required String branch,
    required String target,
    required SipAccount account,
    String? toTag,
    Map<String, String>? extra,
    String body = '',
  }) {
    final tx = _transport!;
    final scheme = tx.protocol; // WS / WSS / UDP
    final localHost = _localContactHost();
    final fromDisplay = account.displayName == null
        ? ''
        : '"${account.displayName}" ';
    final toUri = method == 'REGISTER' ? account.aor : target;
    final toLine = toTag == null ? '<$toUri>' : '<$toUri>;tag=$toTag';
    final headers = <MapEntry<String, String>>[
      MapEntry('Via', 'SIP/2.0/$scheme $localHost;branch=$branch;rport'),
      MapEntry('Max-Forwards', '70'),
      MapEntry('From', '$fromDisplay<${account.aor}>;tag=$fromTag'),
      MapEntry('To', toLine),
      MapEntry('Call-ID', callId),
      MapEntry('CSeq', '$cseq $method'),
      MapEntry(
        'Contact',
        '<sip:${account.username}@$localHost;transport=$scheme>',
      ),
      const MapEntry('User-Agent', 'flutter_sip_ua/1.0 (pure-dart)'),
    ];
    if (extra != null) {
      extra.forEach((k, v) => headers.add(MapEntry(k, v)));
    }
    return SipMessage.request(method, requestUri, headers: headers, body: body);
  }

  SipMessage _buildResponseFor(
    SipMessage req,
    int code,
    String reason, {
    String? addToTag,
    String? sdp,
    Map<String, String>? extra,
  }) {
    final headers = <MapEntry<String, String>>[];
    for (final h in req.headers) {
      final k = h.key.toLowerCase();
      if (k == 'via' ||
          k == 'from' ||
          k == 'call-id' ||
          k == 'cseq' ||
          k == 'record-route') {
        headers.add(h);
      } else if (k == 'to') {
        var v = h.value;
        if (addToTag != null && _paramOfHeader(v, 'tag') == null) {
          v = '$v;tag=$addToTag';
        }
        headers.add(MapEntry(h.key, v));
      }
    }
    final acc = _account;
    if (acc != null && _transport != null) {
      final scheme = _transport!.protocol;
      final localHost = _localContactHost();
      headers.add(
        MapEntry(
          'Contact',
          '<sip:${acc.username}@$localHost;transport=$scheme>',
        ),
      );
    }
    headers.add(const MapEntry('User-Agent', 'flutter_sip_ua/1.0'));
    if (extra != null) {
      extra.forEach((k, v) => headers.add(MapEntry(k, v)));
    }
    final body = sdp ?? '';
    if (sdp != null) {
      headers.add(const MapEntry('Content-Type', 'application/sdp'));
    }
    return SipMessage.response(
      code: code,
      reason: reason,
      headers: headers,
      body: body,
    );
  }

  void _respondToInvite(
    _CallContext ctx, {
    required int code,
    required String reason,
    String? sdp,
    Map<String, String>? extra,
  }) {
    final resp = _buildResponseFor(
      ctx.lastInvite,
      code,
      reason,
      addToTag: ctx.localTag,
      sdp: sdp,
      extra: extra,
    );
    _send(resp);
  }

  void _sendAck(_CallContext ctx, SipMessage resp) {
    final acc = _account;
    if (acc == null) return;
    final code = resp.statusCode ?? 0;
    final isTwoXx = code >= 200 && code < 300;
    // RFC 3261 §17.1.1.3: ACK to a non-2xx final response is part of the
    // INVITE *server* transaction and MUST reuse the INVITE's branch and
    // Request-URI. RFC 3261 §13.2.2.4: ACK to a 2xx is a new transaction,
    // gets a fresh branch, and is sent to the remote target (Contact).
    final target = isTwoXx
        ? (ctx.remoteContact ?? ctx.call.remoteParty)
        : ctx.call.remoteParty;
    final branch = isTwoXx ? _branch() : ctx.branch;
    final ack = _buildRequest(
      method: 'ACK',
      requestUri: target,
      callId: ctx.call.id,
      fromTag: ctx.localTag,
      cseq: ctx.cseq,
      branch: branch,
      target: target,
      account: acc,
      toTag: resp.toTag ?? ctx.remoteTag,
    );
    _send(ack);
  }

  void _retryInviteWithAuth(_CallContext ctx, SipMessage challenge) {
    if (ctx.authAttempts >= 2) {
      _markEnded(ctx);
      return;
    }
    ctx.authAttempts++;
    final acc = _account;
    if (acc == null) return;
    final code = challenge.statusCode!;
    final hdr = challenge.header(
      code == 401 ? 'WWW-Authenticate' : 'Proxy-Authenticate',
    );
    if (hdr == null) {
      _markEnded(ctx);
      return;
    }
    _sendAck(ctx, challenge);

    final newCseq = _nextCseq();
    final newBranch = _branch();
    final ch = DigestChallenge.fromParams(parseAuthHeader(hdr));
    final auth = _digest.authorize(
      challenge: ch,
      username: acc.username,
      password: acc.password,
      method: 'INVITE',
      uri: ctx.call.remoteParty,
    );
    final extra = <String, String>{
      'Content-Type': 'application/sdp',
      'Supported': 'timer',
      'Session-Expires':
          '${ctx.proposedSE ?? acc.sessionExpires};refresher=uac',
      'Min-SE': '${ctx.minSE ?? acc.minSE}',
      code == 401 ? 'Authorization' : 'Proxy-Authorization': 'Digest $auth',
    };
    final invite = _buildRequest(
      method: 'INVITE',
      requestUri: ctx.call.remoteParty,
      callId: ctx.call.id,
      fromTag: ctx.localTag,
      cseq: newCseq,
      branch: newBranch,
      target: ctx.call.remoteParty,
      account: acc,
      extra: extra,
      body: _buildOfferSdpForCall(ctx, acc),
    );
    ctx.cseq = newCseq;
    ctx.branch = newBranch;
    ctx.lastInvite = invite;
    _send(invite);
  }

  // ===========================================================================
  // Misc
  // ===========================================================================

  String _localContactHost() {
    final tx = _transport!;
    final host = tx.localHost;
    final port = tx.localPort;
    return port == 0 ? host : '$host:$port';
  }

  String _normaliseTarget(String target, String defaultDomain) {
    final t = target.trim();
    if (t.startsWith('sip:') || t.startsWith('sips:')) return t;
    if (t.contains('@')) return 'sip:$t';
    return 'sip:$t@$defaultDomain';
  }

  String _branch() => 'z9hG4bK${_uuid.v4().replaceAll('-', '')}';

  String _shortTag() {
    final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  int _nextCseq() => DateTime.now().millisecondsSinceEpoch & 0x3fffffff;

  String _buildOfferSdp(SipAccount acc) {
    // Backwards-compatible offer used when no MediaSession is bound
    // (re-INVITE refresh paths). Real port/codec come from MediaSession
    // when one exists.
    return buildG711Offer(
      username: acc.username,
      localHost: _mediaLocalHost(),
      localPort: 0,
    );
  }

  /// Hold-aware variant: uses the call's bound RTP port if available and
  /// flips `a=sendonly` while the call is on hold so the peer knows to
  /// stop sending audio.
  String _buildOfferSdpForCall(_CallContext ctx, SipAccount acc) {
    final media = ctx.media;
    final port = media?.localPort ?? 0;
    final rtcp = media?.localRtcpPort;
    return buildG711Offer(
      username: acc.username,
      localHost: _mediaLocalHost(),
      localPort: port,
      rtcpPort: rtcp,
      direction: ctx.held ? SdpDirection.sendonly : SdpDirection.sendrecv,
      sessionId: ctx.sdpSessionId,
      sessionVersion: ctx.bumpSdpVersion(),
    );
  }

  /// Build the SDP body for a 200 OK to a peer-sent (re-)INVITE.
  ///
  /// RFC 3264 \u00a78: a re-INVITE answer must stay within what was already
  /// negotiated; it is **not** a fresh offer. We pick the codec from the
  /// new offer if it intersects with the previously-agreed codec, else
  /// fall back to the new offer's first codec, else fall back to the
  /// cached one. The bound RTP port and direction (hold/active) come from
  /// the call context, same as outbound offers.
  String _buildAnswerSdpForCall(
    _CallContext ctx,
    SipAccount acc,
    SdpAudio? newOffer,
  ) {
    final media = ctx.media;
    final port = media?.localPort ?? 0;
    final rtcp = media?.localRtcpPort;
    final direction = ctx.held ? SdpDirection.sendonly : SdpDirection.sendrecv;

    SdpAudio? answerOffer = newOffer;
    if (answerOffer == null && ctx.negotiatedAudioCodec != null) {
      // Re-INVITE without an offer body: synthesise one from cached state
      // so the answer stays consistent with the original negotiation.
      answerOffer = SdpAudio(
        host: _mediaLocalHost(),
        port: port,
        codec: ctx.negotiatedAudioCodec!,
        telephoneEventPt: ctx.negotiatedDtmfPt,
        telephoneEventRange: ctx.negotiatedDtmfRange,
      );
    }
    if (answerOffer == null) {
      // No offer and nothing cached \u2014 must be the very first response and
      // we have no codec context. Fall back to a full G.711 offer so the
      // call doesn't stall, even though strictly this isn't an answer.
      return buildG711Offer(
        username: acc.username,
        localHost: _mediaLocalHost(),
        localPort: port,
        rtcpPort: rtcp,
        direction: direction,
        sessionId: ctx.sdpSessionId,
        sessionVersion: ctx.bumpSdpVersion(),
      );
    }
    // Update cached negotiation so subsequent re-INVITEs stay in sync.
    ctx.negotiatedAudioCodec = answerOffer.codec;
    ctx.negotiatedDtmfPt = answerOffer.telephoneEventPt;
    ctx.negotiatedDtmfRange = answerOffer.telephoneEventRange;
    return buildG711Answer(
      username: acc.username,
      localHost: _mediaLocalHost(),
      localPort: port,
      remoteOffer: answerOffer,
      rtcpPort: rtcp,
      direction: direction,
      sessionId: ctx.sdpSessionId,
      sessionVersion: ctx.bumpSdpVersion(),
    );
  }

  /// Best-effort "public" host to put in `c=` / `o=`. Prefers an explicit
  /// override; otherwise the SIP transport's local host. Refuses to emit
  /// `0.0.0.0` / `::` which most SBCs interpret as hold-equivalent —
  /// falls back to loopback in that case so the call at least connects on
  /// a single host while the operator notices the warning.
  String _mediaLocalHost() {
    final override = _publicMediaAddress?.trim();
    if (override != null && override.isNotEmpty) return override;
    final tx = _transport;
    // WebSocket transports report the *remote* host as `localHost`
    // (it's just `uri.host`). Using that in SDP makes the PBX send RTP
    // back to itself, which is why early calls were dead silent. Prefer
    // a discovered local IPv4 whenever the transport is WS/WSS, or when
    // the transport's host is unspecified.
    final discovered = _discoveredLocalIp;
    if (tx == null) return discovered ?? '127.0.0.1';
    final proto = tx.protocol.toUpperCase();
    if (proto == 'WS' || proto == 'WSS') {
      if (discovered != null && discovered.isNotEmpty) return discovered;
      _log(
        'sdp: WS/WSS transport has no usable local IP; falling back to 127.0.0.1 '
        '— set publicMediaAddress for real deployments',
      );
      return '127.0.0.1';
    }
    final h = tx.localHost;
    if (h.isEmpty || h == '0.0.0.0' || h == '::') {
      if (discovered != null && discovered.isNotEmpty) return discovered;
      _log(
        'sdp: transport local host is unspecified ($h); '
        'falling back to 127.0.0.1 — set publicMediaAddress for real deployments',
      );
      return '127.0.0.1';
    }
    // The UDP socket on Windows often binds to a virtual adapter
    // (e.g. VirtualBox host-only 192.168.56.x) even when the real LAN
    // NIC is reachable. If we have a discovered IP that looks more like
    // a real LAN address than the transport's, prefer it.
    if (discovered != null && discovered.isNotEmpty && discovered != h) {
      if (_isVirtualLikeIp(h) && !_isVirtualLikeIp(discovered)) {
        _log(
          'sdp: transport local host $h looks virtual; using discovered $discovered for SDP',
        );
        _sdpLog?.writeln(
          '# sdp: overriding transport host $h with discovered $discovered',
        );
        return discovered;
      }
    }
    return h;
  }

  /// True for IPs in subnets that are essentially always synthetic on
  /// developer Windows boxes (VirtualBox host-only, APIPA).
  static bool _isVirtualLikeIp(String ipv4) {
    final parts = ipv4.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    final c = int.tryParse(parts[2]);
    if (a == null || b == null || c == null) return false;
    if (a == 192 && b == 168 && c == 56) return true;
    if (a == 169 && b == 254) return true;
    return false;
  }

  String? _firstContactUri(SipMessage msg) {
    final c = msg.header('Contact') ?? msg.header('m');
    if (c == null) return null;
    return extractUri(c);
  }

  void _scheduleKeepAlive() {
    _keepAliveTimer?.cancel();
    final tx = _transport;
    if (tx == null) return;
    // Only WS variants need RFC 5626 CRLF keep-alives.
    if (tx.protocol != 'WS' && tx.protocol != 'WSS') return;
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (tx.isConnected) {
        try {
          tx.sendRaw('\r\n\r\n');
        } catch (_) {}
      }
    });
  }

  void _send(SipMessage msg) {
    _fileLogger?.log('OUT', msg);
    _log(
      '--> ${msg.isResponse ? "${msg.statusCode} ${msg.reasonPhrase}" : "${msg.method} ${msg.requestUri}"}',
    );
    _logSdpIfPresent('OUT', msg);
    _transport?.send(msg);
  }

  /// Emit a concise summary plus the verbatim SDP body to the in-memory
  /// log stream whenever [msg] carries `application/sdp`. The wire-format
  /// file logger already captures the full message; this duplicates the
  /// SDP onto the UI/event log so call setup can be diagnosed without
  /// opening the wire file.
  void _logSdpIfPresent(String direction, SipMessage msg) {
    final body = msg.body;
    if (body.isEmpty) return;
    final ct = (msg.header('Content-Type') ?? msg.header('c') ?? '').trim();
    if (!ct.toLowerCase().contains('application/sdp')) return;

    // One-liner summary that's easy to grep for.
    String summary;
    try {
      final parsed = parseSdp(body);
      final a = parsed.audio;
      final v = parsed.video;
      final parts = <String>[];
      if (a != null) {
        parts.add(
          'audio=${a.host}:${a.port} codec=${a.codec.name} dir=${a.direction.name}',
        );
      }
      if (v != null) {
        parts.add('video=${v.host}:${v.port} pt=${v.payloadType}');
      }
      summary = parts.isEmpty ? 'no m= lines parsed' : parts.join(' | ');
    } catch (e) {
      summary = 'parse error: $e';
    }
    _log('sdp($direction): $summary');
    _sdpLog?.writeln('');
    _sdpLog?.writeln(
      '===== ${DateTime.now().toIso8601String()}  $direction  '
      '${msg.isResponse ? "${msg.statusCode} ${msg.reasonPhrase}" : "${msg.method} ${msg.requestUri}"}  '
      'Call-ID=${msg.callId ?? "?"}  CSeq=${msg.cseqMethod ?? "?"} =====',
    );
    _sdpLog?.writeln('# summary: $summary');
    for (final line in body.split(RegExp(r'\r?\n'))) {
      final t = line.trimRight();
      if (t.isNotEmpty) {
        _log('  sdp($direction)| $t');
        _sdpLog?.writeln(t);
      }
    }
  }

  void _markEnded(_CallContext ctx) {
    ctx.cancelTimers();
    final media = ctx.media;
    ctx.media = null;
    if (media != null) {
      media.stop();
    }
    final video = ctx.video;
    ctx.video = null;
    if (video != null) {
      video.stop();
    }
    ctx.call.state = CallState.ended;
    ctx.call.endedAt = DateTime.now();
    _emitCall(ctx.call);
    _calls.remove(ctx.call.id);
  }

  void _emitCall(SipCall call) => _callCtl.add(call);

  void _setRegState(RegistrationState s) {
    if (_regState == s) return;
    _regState = s;
    _registrationCtl.add(s);
  }

  void _log(String line) => _logCtl.add(line);

  /// Sink passed to media-layer components (audio sink, etc.) so their
  /// diagnostics land in both the wire log and the SDP log.
  void _mediaLogSink(String line) {
    _log(line);
    _sdpLog?.writeln('# $line');
  }

  /// Start a 2-second periodic logger that writes RTP send/receive counts
  /// for [ctx] into the SDP log file. Lets us tell, after a test call,
  /// whether packets actually flowed in either direction.
  void _startRtpStatsLogger(_CallContext ctx) {
    ctx.rtpStatsTimer?.cancel();
    final start = DateTime.now();
    ctx.rtpStatsTimer = Timer.periodic(const Duration(seconds: 2), (t) {
      final media = ctx.media;
      if (media == null || ctx.call.state != CallState.active) {
        t.cancel();
        return;
      }
      final s = media.stats;
      final js = media.jitterStats;
      final elapsed = DateTime.now().difference(start).inSeconds;
      final line =
          'rtp[t+${elapsed}s] call=${ctx.call.id} '
          'tx=${s.sentPackets} rx=${s.receivedPackets} '
          'played=${js.played} buffered=${js.buffered} '
          'lateDrops=${js.lateDrops} overflow=${js.overflowDrops} '
          'remoteSsrc=${s.remoteSsrc ?? "?"} '
          'jitter=${s.jitter} lost=${s.cumulativeLost}';
      _log(line);
      _sdpLog?.writeln('# $line');
    });
  }
}

class _CallContext {
  _CallContext({
    required this.call,
    required this.localTag,
    required this.cseq,
    required this.lastInvite,
    required this.branch,
    this.proposedSE,
    this.minSE,
    int? sdpSessionId,
  }) : sdpSessionId =
           sdpSessionId ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
       sdpVersion =
           sdpSessionId ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final SipCall call;
  final String localTag;
  String? remoteTag;
  String? remoteContact;
  int cseq;
  String branch;
  SipMessage lastInvite;
  int authAttempts = 0;

  /// Stable `o=` session id for the lifetime of this dialog (RFC 4566 §5.2).
  final int sdpSessionId;

  /// Monotonically incremented `o=` version. Bump via [bumpSdpVersion]
  /// before every outgoing offer/answer that re-describes the session.
  int sdpVersion;

  /// Returns the new version after incrementing.
  int bumpSdpVersion() => ++sdpVersion;

  /// Active media plane (mic capture + RTP socket). Null until the call is
  /// being set up, and again once it ends.
  MediaSession? media;

  /// Optional video plane; only present when the call is negotiated with
  /// `m=video`.
  VideoSession? video;

  /// True once a hold re-INVITE has been sent and 200-OK confirmed (or
  /// optimistically, while the re-INVITE is in flight).
  bool held = false;

  /// Codec we agreed to use after the initial offer/answer. Used when a
  /// peer-initiated re-INVITE arrives so we re-emit an answer that's a
  /// strict intersection (RFC 3264 §8) instead of a fresh full menu.
  G711Variant? negotiatedAudioCodec;

  /// Telephone-event PT and fmtp range carried alongside [negotiatedAudioCodec].
  int? negotiatedDtmfPt;
  String? negotiatedDtmfRange;

  // RFC 4028 state.
  int? proposedSE;
  int? negotiatedSE;
  int? minSE;
  String? refresher; // 'uac' | 'uas'
  Timer? refreshTimer;
  Timer? expiryTimer;
  Timer? rtpStatsTimer;

  void cancelTimers() {
    refreshTimer?.cancel();
    refreshTimer = null;
    expiryTimer?.cancel();
    expiryTimer = null;
    rtpStatsTimer?.cancel();
    rtpStatsTimer = null;
  }
}

class _SessionExpires {
  const _SessionExpires({this.expires, this.refresher});
  final int? expires;
  final String? refresher;
}

String? _paramOfHeader(String value, String name) {
  final lower = name.toLowerCase();
  for (final part in value.split(';')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    if (part.substring(0, eq).trim().toLowerCase() == lower) {
      return part.substring(eq + 1).trim();
    }
  }
  return null;
}
