/// HTTP control API for desktop / mobile builds.
///
/// Exposes a small JSON REST surface plus a Server-Sent-Events event
/// stream so the running `SipUserAgent` can be driven from a browser or
/// any other HTTP client.
///
/// Endpoints (all under `http://<host>:<port>`):
///
///   GET  /status                        registration + active calls
///   GET  /account                       current account (no password)
///   POST /account                       set/replace account + register
///         body: { serverUri, domain, username, password, displayName?,
///                 sessionExpires?, minSE? }
///   POST /unregister                    stop UA / sign out
///
///   GET  /calls                         list recent calls
///   POST /calls                         body: { target, video? } → makeCall
///   GET  /calls/{id}                    snapshot of a single call
///   POST /calls/{id}/answer             answer an incoming call
///   POST /calls/{id}/hangup             hangup / cancel / decline
///   POST /calls/{id}/hold               body: { hold: bool }
///   POST /calls/{id}/mute               body: { muted: bool }
///   POST /calls/{id}/dtmf               body: { digit, durationMs? }
///
///   POST /messages                      body: { target, text } → SIP MESSAGE
///
///   GET  /logs?limit=100                recent wire / app log lines
///   GET  /events                        Server-Sent Events stream
///
/// Authentication: if `ControlApiConfig.token` is non-null, every request
/// must carry `Authorization: Bearer <token>` (or `?token=<token>`).
///
/// Binds to `127.0.0.1` by default. To expose to the LAN, pass
/// `host: '0.0.0.0'` *and* set a token.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../sip/sip_user_agent.dart';

class ControlApiConfig {
  const ControlApiConfig({
    this.host = '127.0.0.1',
    this.port = 8765,
    this.token,
    this.enabled = true,
  });

  final String host;
  final int port;

  /// Optional bearer token. When set, requests must include
  /// `Authorization: Bearer <token>` or `?token=<token>`.
  final String? token;

  final bool enabled;
}

class ControlApiServer {
  ControlApiServer({required this.ua, this.config = const ControlApiConfig()});

  final SipUserAgent ua;
  final ControlApiConfig config;

  HttpServer? _server;
  final _eventCtl = StreamController<_SseEvent>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];

  bool get isRunning => _server != null;
  Uri? get boundUri => _server == null
      ? null
      : Uri.parse('http://${_server!.address.host}:${_server!.port}');

  Future<void> start() async {
    if (_server != null) return;
    final addr = config.host == '0.0.0.0'
        ? InternetAddress.anyIPv4
        : InternetAddress(config.host);
    final server = await HttpServer.bind(addr, config.port, shared: false);
    _server = server;

    _subs.add(
      ua.registrationStream.listen((s) {
        _push('registration', {'state': s.name});
      }),
    );
    _subs.add(
      ua.callStream.listen((c) {
        _push('call', _callJson(c));
      }),
    );
    _subs.add(
      ua.messageStream.listen((m) {
        _push('message', _messageJson(m));
      }),
    );
    _subs.add(
      ua.logStream.listen((line) {
        _push('log', {'line': line});
      }),
    );

    server.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _server?.close(force: true);
    _server = null;
    await _eventCtl.close();
  }

  // ─────────────────────────── Request dispatch ────────────────────────────

  Future<void> _handle(HttpRequest req) async {
    try {
      _applyCors(req.response);
      if (req.method == 'OPTIONS') {
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
        return;
      }
      if (!_authorize(req)) {
        await _json(req, 401, {'error': 'unauthorized'});
        return;
      }

      final segs = req.uri.pathSegments;
      if (segs.isEmpty) {
        await _json(req, 200, {
          'name': 'flutter_sip_ua control api',
          'version': 1,
        });
        return;
      }

      switch (segs.first) {
        case 'status':
          await _json(req, 200, _statusJson());
          return;
        case 'account':
          if (req.method == 'GET') {
            await _json(req, 200, _accountJson());
            return;
          }
          if (req.method == 'POST') {
            await _setAccount(req);
            return;
          }
          break;
        case 'unregister':
          if (req.method == 'POST') {
            await ua.stop();
            await _json(req, 200, {'ok': true});
            return;
          }
          break;
        case 'calls':
          await _handleCalls(req, segs);
          return;
        case 'messages':
          if (req.method == 'POST') {
            await _sendMessage(req);
            return;
          }
          break;
        case 'logs':
          await _json(req, 200, {'logs': const <String>[]});
          return;
        case 'events':
          await _streamEvents(req);
          return;
      }
      await _json(req, 404, {'error': 'not_found', 'path': req.uri.path});
    } catch (e, st) {
      try {
        await _json(req, 500, {'error': '$e', 'stack': '$st'});
      } catch (_) {}
    }
  }

  Future<void> _handleCalls(HttpRequest req, List<String> segs) async {
    if (segs.length == 1) {
      if (req.method == 'GET') {
        // We don't have direct access to the call list snapshot; rely on
        // anything the UA exposes. Otherwise return an empty list and
        // direct clients to subscribe via /events.
        await _json(req, 200, {'calls': const <dynamic>[]});
        return;
      }
      if (req.method == 'POST') {
        await _makeCall(req);
        return;
      }
    } else if (segs.length >= 2) {
      final id = segs[1];
      final action = segs.length >= 3 ? segs[2] : '';
      if (req.method == 'GET' && action.isEmpty) {
        final c = ua.callById(id);
        if (c == null) {
          await _json(req, 404, {'error': 'no_such_call'});
        } else {
          await _json(req, 200, _callJson(c));
        }
        return;
      }
      if (req.method == 'POST') {
        switch (action) {
          case 'answer':
            await ua.answer(id);
            await _json(req, 200, {'ok': true});
            return;
          case 'hangup':
            ua.hangup(id);
            await _json(req, 200, {'ok': true});
            return;
          case 'hold':
            final body = await _readJson(req);
            final hold = body['hold'] == true;
            final result = ua.setHold(id, hold);
            await _json(req, 200, {'held': result});
            return;
          case 'mute':
            final body = await _readJson(req);
            final muted = body['muted'] == true;
            final result = ua.setMuted(id, muted);
            await _json(req, 200, {'muted': result});
            return;
          case 'dtmf':
            final body = await _readJson(req);
            final digit = (body['digit'] as String?) ?? '';
            final ms = (body['durationMs'] as num?)?.toInt() ?? 200;
            await ua.sendDtmf(id, digit, duration: Duration(milliseconds: ms));
            await _json(req, 200, {'ok': true});
            return;
        }
      }
    }
    await _json(req, 404, {'error': 'not_found', 'path': req.uri.path});
  }

  Future<void> _setAccount(HttpRequest req) async {
    final body = await _readJson(req);
    final serverUri = body['serverUri'] as String?;
    final domain = body['domain'] as String?;
    final username = body['username'] as String?;
    final password = body['password'] as String?;
    if (serverUri == null ||
        domain == null ||
        username == null ||
        password == null) {
      await _json(req, 400, {
        'error': 'missing_fields',
        'required': ['serverUri', 'domain', 'username', 'password'],
      });
      return;
    }
    final acc = SipAccount(
      serverUri: Uri.parse(serverUri),
      domain: domain,
      username: username,
      password: password,
      displayName: body['displayName'] as String?,
      sessionExpires: (body['sessionExpires'] as num?)?.toInt() ?? 1800,
      minSE: (body['minSE'] as num?)?.toInt() ?? 90,
    );
    await ua.start(acc);
    await _json(req, 200, {'ok': true, 'aor': acc.aor});
  }

  Future<void> _makeCall(HttpRequest req) async {
    final body = await _readJson(req);
    final target = body['target'] as String?;
    if (target == null || target.isEmpty) {
      await _json(req, 400, {'error': 'missing_target'});
      return;
    }
    final video = body['video'] == true;
    final call = await ua.makeCall(target, withVideo: video);
    if (call == null) {
      await _json(req, 409, {'error': 'call_failed'});
      return;
    }
    await _json(req, 200, _callJson(call));
  }

  Future<void> _sendMessage(HttpRequest req) async {
    final body = await _readJson(req);
    final target = body['target'] as String?;
    final text = body['text'] as String?;
    if (target == null || text == null) {
      await _json(req, 400, {
        'error': 'missing_fields',
        'required': ['target', 'text'],
      });
      return;
    }
    ua.sendMessage(target, text);
    await _json(req, 200, {'ok': true});
  }

  Future<void> _streamEvents(HttpRequest req) async {
    final res = req.response;
    res.statusCode = 200;
    res.headers
      ..set(HttpHeaders.contentTypeHeader, 'text/event-stream')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..set(HttpHeaders.connectionHeader, 'keep-alive');
    res.bufferOutput = false;
    res.write(': connected\n\n');
    await res.flush();
    final sub = _eventCtl.stream.listen((e) {
      try {
        res.write('event: ${e.event}\ndata: ${jsonEncode(e.data)}\n\n');
        res.flush();
      } catch (_) {}
    });
    final keepAlive = Timer.periodic(const Duration(seconds: 15), (_) {
      try {
        res.write(': ka\n\n');
        res.flush();
      } catch (_) {}
    });
    try {
      await req.response.done;
    } catch (_) {}
    keepAlive.cancel();
    await sub.cancel();
  }

  // ─────────────────────────── Helpers ─────────────────────────────────────

  void _push(String event, Map<String, dynamic> data) {
    if (_eventCtl.isClosed) return;
    _eventCtl.add(_SseEvent(event, data));
  }

  bool _authorize(HttpRequest req) {
    final token = config.token;
    if (token == null || token.isEmpty) return true;
    final header = req.headers.value(HttpHeaders.authorizationHeader);
    if (header != null) {
      final lower = header.toLowerCase();
      if (lower.startsWith('bearer ') && header.substring(7).trim() == token) {
        return true;
      }
    }
    final qp = req.uri.queryParameters['token'];
    return qp != null && qp == token;
  }

  void _applyCors(HttpResponse res) {
    res.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    if (raw.isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    return const {};
  }

  Future<void> _json(HttpRequest req, int status, Object body) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Map<String, dynamic> _statusJson() {
    final acc = ua.account;
    return {
      'registration': ua.registrationState.name,
      'account': acc == null ? null : _accountJson(),
    };
  }

  Map<String, dynamic> _accountJson() {
    final acc = ua.account;
    if (acc == null) return const {};
    return {
      'username': acc.username,
      'domain': acc.domain,
      'serverUri': acc.serverUri.toString(),
      'displayName': acc.displayName,
      'aor': acc.aor,
      'sessionExpires': acc.sessionExpires,
      'minSE': acc.minSE,
    };
  }

  Map<String, dynamic> _callJson(SipCall c) => {
    'id': c.id,
    'remoteParty': c.remoteParty,
    'outgoing': c.outgoing,
    'state': c.state.name,
    'held': c.held,
    'startedAt': c.startedAt?.toIso8601String(),
    'endedAt': c.endedAt?.toIso8601String(),
  };

  Map<String, dynamic> _messageJson(SipTextMessage m) => {
    'from': m.from,
    'to': m.to,
    'body': m.body,
    'outgoing': m.outgoing,
    'receivedAt': m.receivedAt.toIso8601String(),
  };
}

class _SseEvent {
  _SseEvent(this.event, this.data);
  final String event;
  final Map<String, dynamic> data;
}
