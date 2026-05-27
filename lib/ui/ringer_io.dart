/// Incoming-call ringer.
///
/// Generates a classic North-American "ringback" cadence (440 Hz + 480 Hz
/// dual tone, 2 s on / 4 s off) on the fly and feeds it into
/// `flutter_pcm_sound`. The plugin is a process-wide singleton, so the
/// ringer fully releases the engine in [stop] — the per-call
/// `PcmAudioSink` will re-`setup` it when the user answers.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

class Ringer {
  Ringer({this.sampleRate = 8000});

  final int sampleRate;

  // Cadence: 2 s tone, 4 s silence (US ringback).
  static const _toneOnMs = 2000;
  static const _toneOffMs = 4000;

  // Generate audio in ~100 ms chunks so we can stop quickly.
  static const _chunkMs = 100;

  bool _playing = false;
  bool _setup = false;
  Timer? _pump;
  int _elapsedMs = 0;

  bool get isPlaying => _playing;

  Future<void> start() async {
    if (_playing) return;
    _playing = true;
    _elapsedMs = 0;
    try {
      await FlutterPcmSound.setLogLevel(LogLevel.error);
      await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
      await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 10); // ~100 ms
      _setup = true;
    } catch (_) {
      _playing = false;
      return;
    }
    // Pre-buffer two chunks so playback starts immediately.
    _feedChunk();
    _feedChunk();
    _pump = Timer.periodic(const Duration(milliseconds: _chunkMs), (_) {
      if (!_playing) return;
      _feedChunk();
    });
  }

  Future<void> stop() async {
    if (!_playing && !_setup) return;
    _playing = false;
    _pump?.cancel();
    _pump = null;
    if (_setup) {
      _setup = false;
      try {
        await FlutterPcmSound.release();
      } catch (_) {}
    }
  }

  void _feedChunk() {
    final samples = (sampleRate * _chunkMs) ~/ 1000;
    final pcm = Int16List(samples);
    final cyclePos = _elapsedMs % (_toneOnMs + _toneOffMs);
    final inTone = cyclePos < _toneOnMs;
    if (inTone) {
      // 440 Hz + 480 Hz, each at ~0.25 amplitude => combined peak ~0.5.
      const a1 = 0.25;
      const a2 = 0.25;
      final w1 = 2 * math.pi * 440 / sampleRate;
      final w2 = 2 * math.pi * 480 / sampleRate;
      final startSample = (_elapsedMs * sampleRate) ~/ 1000;
      for (var i = 0; i < samples; i++) {
        final n = startSample + i;
        final v = a1 * math.sin(w1 * n) + a2 * math.sin(w2 * n);
        pcm[i] = (v * 32767).toInt().clamp(-32768, 32767);
      }
    } // else: silence (already zero-initialised).
    _elapsedMs += _chunkMs;
    try {
      FlutterPcmSound.feed(
        PcmArrayInt16(bytes: pcm.buffer.asByteData()),
      );
    } catch (_) {
      // Drop a frame rather than poison the ring loop.
    }
  }
}
