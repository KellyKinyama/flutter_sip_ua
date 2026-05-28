/// Platform-specific picker for the playback [AudioSink].
///
/// On web this is a no-op stub that just delegates to [PcmAudioSink]
/// (which throws on construction — web has no media path). On native
/// targets [pickPlaybackSink] returns a Windows-specific FFI sink on
/// Windows and [PcmAudioSink] elsewhere.
library;

import '../sip/audio/audio_sink.dart';
import '../sip/audio/pcm_audio_sink.dart';

AudioSink pickPlaybackSink({required void Function(String) onLog}) =>
    PcmAudioSink(onLog: onLog);
