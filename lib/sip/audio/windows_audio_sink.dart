/// Windows playback [AudioSink] built on the Win32 WinMM `waveOut*` APIs
/// via `dart:ffi`. Used because `flutter_pcm_sound` only ships
/// android / ios / macos backends.
///
/// Design:
///   * One `HWAVEOUT` opened at [WAVE_FORMAT_PCM], 16-bit signed, mono,
///     at the negotiated sample rate.
///   * A ring of pre-allocated `WAVEHDR`s lets the OS queue ~N frames
///     ahead while we keep writing without per-frame allocations.
///   * `play()` is fire-and-forget: when no header slot is free we drop
///     the frame instead of blocking the network loop.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'audio_sink.dart';

// ---------------------------------------------------------------------------
// Win32 struct + function bindings.
// ---------------------------------------------------------------------------

const int _waveFormatPcm = 1;
const int _whdrDone = 0x00000001;
const int _whdrPrepared = 0x00000002;
const int _callbackNull = 0;
const int _mmsysErrNoError = 0;

final class _WaveFormatEx extends Struct {
  @Uint16()
  external int wFormatTag;
  @Uint16()
  external int nChannels;
  @Uint32()
  external int nSamplesPerSec;
  @Uint32()
  external int nAvgBytesPerSec;
  @Uint16()
  external int nBlockAlign;
  @Uint16()
  external int wBitsPerSample;
  @Uint16()
  external int cbSize;
}

final class _WaveHdr extends Struct {
  external Pointer<Uint8> lpData;
  @Uint32()
  external int dwBufferLength;
  @Uint32()
  external int dwBytesRecorded;
  @IntPtr()
  external int dwUser;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int dwLoops;
  external Pointer<_WaveHdr> lpNext;
  @IntPtr()
  external int reserved;
}

typedef _WaveOutOpenNative =
    Uint32 Function(
      Pointer<IntPtr> phwo,
      Uint32 uDeviceId,
      Pointer<_WaveFormatEx> pwfx,
      IntPtr dwCallback,
      IntPtr dwInstance,
      Uint32 fdwOpen,
    );
typedef _WaveOutOpenDart =
    int Function(
      Pointer<IntPtr> phwo,
      int uDeviceId,
      Pointer<_WaveFormatEx> pwfx,
      int dwCallback,
      int dwInstance,
      int fdwOpen,
    );

typedef _WaveOutHdrNative =
    Uint32 Function(IntPtr hwo, Pointer<_WaveHdr> pwh, Uint32 cbwh);
typedef _WaveOutHdrDart =
    int Function(int hwo, Pointer<_WaveHdr> pwh, int cbwh);

typedef _WaveOutCloseNative = Uint32 Function(IntPtr hwo);
typedef _WaveOutCloseDart = int Function(int hwo);

typedef _WaveOutResetNative = Uint32 Function(IntPtr hwo);
typedef _WaveOutResetDart = int Function(int hwo);

// ---------------------------------------------------------------------------

typedef WindowsAudioSinkLogger = void Function(String line);

class WindowsAudioSink implements AudioSink {
  WindowsAudioSink({
    this.sampleRate = 8000,
    this.bufferFrames = 8,
    this.frameSamples = 160,
    WindowsAudioSinkLogger? onLog,
  }) : _onLog = onLog;

  /// 8000 Hz for narrowband G.711.
  final int sampleRate;

  /// Number of WAVEHDR slots queued ahead. 8 × 20 ms = ~160 ms of latency
  /// budget, which is plenty for steady playout without starving.
  final int bufferFrames;

  /// Samples per playout frame. 160 = 20 ms at 8 kHz, matches G.711.
  final int frameSamples;

  final WindowsAudioSinkLogger? _onLog;

  late final DynamicLibrary _winmm;
  late final _WaveOutOpenDart _waveOutOpen;
  late final _WaveOutHdrDart _waveOutPrepareHeader;
  late final _WaveOutHdrDart _waveOutWrite;
  late final _WaveOutHdrDart _waveOutUnprepareHeader;
  late final _WaveOutCloseDart _waveOutClose;
  late final _WaveOutResetDart _waveOutReset;

  int _hwo = 0; // HWAVEOUT
  final List<Pointer<_WaveHdr>> _headers = [];
  final List<Pointer<Uint8>> _buffers = [];
  int _next = 0;
  bool _setup = false;
  bool _closed = false;
  bool _firstFrameLogged = false;
  int _dropped = 0;
  Timer? _dropReporter;

  void _log(String line) {
    try {
      _onLog?.call(line);
    } catch (_) {}
  }

  void _bindWinmm() {
    _winmm = DynamicLibrary.open('winmm.dll');
    _waveOutOpen = _winmm.lookupFunction<_WaveOutOpenNative, _WaveOutOpenDart>(
      'waveOutOpen',
    );
    _waveOutPrepareHeader = _winmm
        .lookupFunction<_WaveOutHdrNative, _WaveOutHdrDart>(
          'waveOutPrepareHeader',
        );
    _waveOutWrite = _winmm.lookupFunction<_WaveOutHdrNative, _WaveOutHdrDart>(
      'waveOutWrite',
    );
    _waveOutUnprepareHeader = _winmm
        .lookupFunction<_WaveOutHdrNative, _WaveOutHdrDart>(
          'waveOutUnprepareHeader',
        );
    _waveOutClose = _winmm
        .lookupFunction<_WaveOutCloseNative, _WaveOutCloseDart>('waveOutClose');
    _waveOutReset = _winmm
        .lookupFunction<_WaveOutResetNative, _WaveOutResetDart>('waveOutReset');
  }

  bool _ensureSetup() {
    if (_setup) return true;
    if (_closed) return false;
    if (!Platform.isWindows) {
      _log('win-sink ERROR: WindowsAudioSink used on non-Windows platform');
      return false;
    }
    try {
      _bindWinmm();
      final fmt = calloc<_WaveFormatEx>();
      fmt.ref
        ..wFormatTag = _waveFormatPcm
        ..nChannels = 1
        ..nSamplesPerSec = sampleRate
        ..nAvgBytesPerSec = sampleRate * 2
        ..nBlockAlign = 2
        ..wBitsPerSample = 16
        ..cbSize = 0;
      final phwo = calloc<IntPtr>();
      try {
        // WAVE_MAPPER = 0xFFFFFFFF (default output device).
        final rc = _waveOutOpen(phwo, 0xFFFFFFFF, fmt, 0, 0, _callbackNull);
        if (rc != _mmsysErrNoError) {
          _log('win-sink ERROR: waveOutOpen failed rc=$rc');
          return false;
        }
        _hwo = phwo.value;
      } finally {
        calloc.free(phwo);
        calloc.free(fmt);
      }

      final bytesPerFrame = frameSamples * 2;
      for (var i = 0; i < bufferFrames; i++) {
        final hdr = calloc<_WaveHdr>();
        final buf = calloc<Uint8>(bytesPerFrame);
        hdr.ref
          ..lpData = buf
          ..dwBufferLength = bytesPerFrame
          ..dwBytesRecorded = 0
          ..dwUser = 0
          ..dwFlags =
              _whdrDone // mark as free initially
          ..dwLoops = 0
          ..lpNext = nullptr
          ..reserved = 0;
        _headers.add(hdr);
        _buffers.add(buf);
      }

      _setup = true;
      _log(
        'win-sink: engine ready (rate=$sampleRate Hz mono, '
        '${bufferFrames}x${frameSamples}-sample slots)',
      );
      // Periodic drop reporter so we notice starvation.
      _dropReporter = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_dropped > 0) {
          _log('win-sink: dropped $_dropped frames (no free slot)');
          _dropped = 0;
        }
      });
      return true;
    } catch (e) {
      _log('win-sink ERROR: setup failed: $e');
      return false;
    }
  }

  @override
  void play(PcmFrame frame) {
    if (_closed) return;
    if (!_ensureSetup()) return;

    // Find a header slot whose previous write has completed.
    Pointer<_WaveHdr>? slot;
    Pointer<Uint8>? buf;
    for (var i = 0; i < bufferFrames; i++) {
      final idx = (_next + i) % bufferFrames;
      final h = _headers[idx];
      if ((h.ref.dwFlags & _whdrDone) != 0) {
        slot = h;
        buf = _buffers[idx];
        _next = (idx + 1) % bufferFrames;
        break;
      }
    }
    if (slot == null || buf == null) {
      _dropped++;
      return;
    }

    // If previously prepared, unprepare before reusing.
    if ((slot.ref.dwFlags & _whdrPrepared) != 0) {
      _waveOutUnprepareHeader(_hwo, slot, sizeOf<_WaveHdr>());
    }

    // Copy samples. PcmFrame.pcm is Int16; treat its bytes as Uint8.
    final bytes = frame.pcm.buffer.asUint8List(
      frame.pcm.offsetInBytes,
      frame.pcm.lengthInBytes,
    );
    final n = bytes.length < frameSamples * 2 ? bytes.length : frameSamples * 2;
    for (var i = 0; i < n; i++) {
      buf[i] = bytes[i];
    }

    slot.ref
      ..dwBufferLength = n
      ..dwBytesRecorded = 0
      ..dwFlags = 0
      ..dwLoops = 0;

    var rc = _waveOutPrepareHeader(_hwo, slot, sizeOf<_WaveHdr>());
    if (rc != _mmsysErrNoError) {
      _log('win-sink ERROR: waveOutPrepareHeader rc=$rc');
      return;
    }
    rc = _waveOutWrite(_hwo, slot, sizeOf<_WaveHdr>());
    if (rc != _mmsysErrNoError) {
      _log('win-sink ERROR: waveOutWrite rc=$rc');
      _waveOutUnprepareHeader(_hwo, slot, sizeOf<_WaveHdr>());
      slot.ref.dwFlags = _whdrDone; // free it back
      return;
    }
    if (!_firstFrameLogged) {
      _firstFrameLogged = true;
      _log('win-sink: first frame queued ($n bytes)');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _dropReporter?.cancel();
    _dropReporter = null;
    if (!_setup) return;
    try {
      _waveOutReset(_hwo);
      for (final h in _headers) {
        if ((h.ref.dwFlags & _whdrPrepared) != 0) {
          _waveOutUnprepareHeader(_hwo, h, sizeOf<_WaveHdr>());
        }
      }
      _waveOutClose(_hwo);
    } catch (_) {}
    for (final b in _buffers) {
      calloc.free(b);
    }
    for (final h in _headers) {
      calloc.free(h);
    }
    _buffers.clear();
    _headers.clear();
    _hwo = 0;
    _setup = false;
  }
}
