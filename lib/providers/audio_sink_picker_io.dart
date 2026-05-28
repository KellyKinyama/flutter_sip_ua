/// Native picker for the playback [AudioSink].
library;

import 'dart:io';

import '../sip/audio/audio_sink.dart';
import '../sip/audio/pcm_audio_sink.dart';
import '../sip/audio/windows_audio_sink.dart';

AudioSink pickPlaybackSink({required void Function(String) onLog}) {
  if (Platform.isWindows) {
    return WindowsAudioSink(onLog: onLog);
  }
  return PcmAudioSink(onLog: onLog);
}
