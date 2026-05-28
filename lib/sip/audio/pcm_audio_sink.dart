/// Cross-platform [AudioSink] that pushes decoded PCM into
/// `flutter_pcm_sound`. Works on Windows / macOS / Linux / Android / iOS.
///
/// The plugin is a process-wide singleton, so only one [PcmAudioSink]
/// should be active at a time. [close] releases the platform engine.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import 'audio_sink.dart';

/// Optional diagnostic callback so callers can surface setup / feed
/// failures through their existing logger (the agent wires this into the
/// SIP wire log).
typedef PcmAudioSinkLogger = void Function(String line);

class PcmAudioSink implements AudioSink {
  PcmAudioSink({this.sampleRate = 8000, PcmAudioSinkLogger? onLog})
    : _onLog = onLog;

  /// 8000 for narrowband G.711, the only codec we negotiate.
  final int sampleRate;
  final PcmAudioSinkLogger? _onLog;

  bool _setup = false;
  bool _closed = false;
  Future<void>? _setupFuture;
  bool _firstFrameLogged = false;
  int _setupFailures = 0;

  Future<void> _ensureSetup() {
    if (_closed) return Future.value();
    if (_setup) return Future.value();
    return _setupFuture ??= _doSetup();
  }

  Future<void> _doSetup() async {
    try {
      await FlutterPcmSound.setLogLevel(LogLevel.error);
      await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
      // Ask the engine to keep at least 320 samples (40 ms) buffered.
      await FlutterPcmSound.setFeedThreshold(320);
      _setup = true;
      _log('pcm-sink: engine ready (rate=$sampleRate Hz mono)');
    } catch (e, st) {
      // Clear the cached future so the next frame can retry; otherwise a
      // single transient failure (e.g. ringer hasn't released the engine
      // yet) would mute the entire call.
      _setupFuture = null;
      _setupFailures++;
      _log('pcm-sink ERROR: setup failed (#$_setupFailures): $e');
      if (kDebugMode && _setupFailures == 1) {
        // ignore: avoid_print
        print('[pcm-sink] setup failed: $e\n$st');
      }
      rethrow;
    }
  }

  @override
  void play(PcmFrame frame) {
    if (_closed) return;
    // Fire-and-forget: the network event loop must not await audio I/O.
    _enqueue(frame);
  }

  Future<void> _enqueue(PcmFrame frame) async {
    try {
      await _ensureSetup();
      if (_closed) return;
      await FlutterPcmSound.feed(
        PcmArrayInt16(bytes: frame.pcm.buffer.asByteData()),
      );
      if (!_firstFrameLogged) {
        _firstFrameLogged = true;
        _log('pcm-sink: first frame played (${frame.pcm.length} samples)');
      }
    } catch (e) {
      _log('pcm-sink ERROR: feed failed: $e');
    }
  }

  void _log(String line) {
    try {
      _onLog?.call(line);
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
  }
}
