import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'package:myapp/services/api_service.dart';

export 'package:myapp/models/chat_preview.dart';

/// Photo and voice messages: everything the chat screen needs that is not
/// drawing — picking or taking a photo, recording a voice note, uploading
/// either, and playing a voice note back.
///
/// How one is sent: the app asks the server for a place to put the file
/// (always in the sender's own chat folder), uploads the file straight to
/// storage, then sends the message with the file's address. The server
/// refuses an address that is not in the sender's own folder.
///
/// Each phone-facing part (the photo picker, the recorder, the player) sits
/// behind a small class with a stand-in for tests, the same way push
/// notifications do.
class ChatMedia {
  ChatMedia._();
  static final instance = ChatMedia._();

  PhotoSource photos = DevicePhotoSource();
  VoiceRecorder Function() recorder = DeviceVoiceRecorder.new;
  VoicePlayer Function() player = DeviceVoicePlayer.new;

  /// Where a recording is written before it is uploaded.
  Future<Directory> Function() directory = getTemporaryDirectory;

  /// A photo's size in pixels (see [photoSize]).
  Future<ui.Size?> Function(File) measure = photoSize;

  /// A voice note is at most two minutes; recording stops there.
  static const maxVoice = Duration(minutes: 2);

  /// The loudness levels kept for a voice note's bubble.
  static const waveformBars = 48;

  /// Uploads [file] as a "photo" or "voice" and answers its address, or
  /// null when it did not go. [onProgress] hears 0 to 1 as it goes.
  Future<String?> upload(
    File file,
    String kind, {
    void Function(double)? onProgress,
  }) async {
    final slot = await ApiService.chatMediaSlot(kind);
    if (slot == null) return null;
    final uploadUrl = '${slot['uploadUrl'] ?? ''}';
    final publicUrl = '${slot['publicUrl'] ?? ''}';
    if (uploadUrl.isEmpty || publicUrl.isEmpty) {
      debugPrint('[chat] the server gave no place to upload a $kind');
      return null;
    }
    try {
      final length = await file.length();
      final req = http.StreamedRequest('PUT', Uri.parse(uploadUrl));
      req.headers['Content-Type'] =
          '${slot['contentType'] ?? 'application/octet-stream'}';
      // Never changes once uploaded: every phone and the CDN may keep it.
      req.headers['Cache-Control'] = 'public, max-age=31536000, immutable';
      req.contentLength = length;
      var sent = 0;
      file.openRead().listen(
        (chunk) {
          req.sink.add(chunk);
          sent += chunk.length;
          if (length > 0) onProgress?.call(sent / length);
        },
        onDone: req.sink.close,
        onError: (Object e) {
          req.sink.addError(e);
          req.sink.close();
        },
      );
      // Straight to storage, without the app's sign-in: the address is
      // already signed, and storage refuses a second kind of sign-in.
      final res = await ApiService.httpClient.send(req);
      await res.stream.drain<void>();
      if (res.statusCode != 200 && res.statusCode != 201) {
        debugPrint('[chat] storage refused the $kind: ${res.statusCode}');
        return null;
      }
      onProgress?.call(1);
      return publicUrl;
    } catch (e) {
      debugPrint('[chat] the $kind did not upload: $e');
      return null;
    }
  }

  @visibleForTesting
  void debugReset() {
    photos = DevicePhotoSource();
    recorder = DeviceVoiceRecorder.new;
    player = DeviceVoicePlayer.new;
    directory = getTemporaryDirectory;
    measure = photoSize;
  }
}

/// "0:07", "1:42".
String voiceClock(Duration d) {
  final s = d.inSeconds.clamp(0, 59 * 60 + 59);
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Turns a recorder's loudness (dBFS: 0 is the loudest, -160 silence) into
/// a bar height from 0 to 100. Speech mostly sits between -45 and -5.
int levelFromDb(double db) {
  if (db.isNaN) return 0;
  return (((db + 50) / 45).clamp(0.0, 1.0) * 100).round();
}

/// Squeezes or stretches [levels] to exactly [bars] bars, keeping the
/// loudest of each stretch so short shouts still show.
List<int> fitWaveform(List<int> levels, int bars) {
  if (levels.isEmpty) return List.filled(bars, 0);
  final out = <int>[];
  for (var i = 0; i < bars; i++) {
    final from = (i * levels.length / bars).floor();
    final to = (((i + 1) * levels.length / bars).ceil()).clamp(
      from + 1,
      levels.length,
    );
    var top = 0;
    for (var j = from; j < to; j++) {
      if (levels[j] > top) top = levels[j];
    }
    out.add(top);
  }
  return out;
}

/// A photo's width and height in pixels, so its bubble has the right shape
/// before the picture arrives on the other phone.
Future<ui.Size?> photoSize(File file) async {
  try {
    final codec = await ui.instantiateImageCodec(await file.readAsBytes());
    final frame = await codec.getNextFrame();
    final size = ui.Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
    frame.image.dispose();
    codec.dispose();
    return size;
  } catch (e) {
    debugPrint('[chat] could not read the photo: $e');
    return null;
  }
}

// ── The phone's camera and photos ─────────────────────────────────────────

abstract class PhotoSource {
  /// A photo taken with the camera ([camera] true) or chosen from the
  /// phone's photos. Null when the person backed out.
  Future<File?> pick({required bool camera});
}

class DevicePhotoSource implements PhotoSource {
  final _picker = ImagePicker();

  @override
  Future<File?> pick({required bool camera}) async {
    try {
      // Shrunk to at most 1600 pixels on the long side and saved as a
      // JPEG: sharp on any phone, and a few hundred KB instead of several MB.
      final x = await _picker.pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 82,
      );
      return x == null ? null : File(x.path);
    } catch (e) {
      debugPrint('[chat] could not get a photo: $e');
      return null;
    }
  }
}

// ── Recording ─────────────────────────────────────────────────────────────

abstract class VoiceRecorder {
  /// Asks for the microphone if it has not been allowed yet.
  Future<bool> allowed();
  Future<void> start(String path);

  /// Loudness while recording, a few times a second, in dBFS.
  Stream<double> levels();

  /// Stops and answers the file, or null when nothing was recorded.
  Future<String?> stop();

  /// Stops and throws the recording away.
  Future<void> cancel();
  Future<void> dispose();
}

class DeviceVoiceRecorder implements VoiceRecorder {
  final _rec = AudioRecorder();

  @override
  Future<bool> allowed() async {
    try {
      return await _rec.hasPermission();
    } catch (e) {
      debugPrint('[chat] could not ask for the microphone: $e');
      return false;
    }
  }

  @override
  Future<void> start(String path) => _rec.start(
    // AAC in an .m4a: small (about 0.5 MB a minute), and plays on
    // every phone.
    const RecordConfig(
      encoder: AudioEncoder.aacLc,
      bitRate: 64000,
      sampleRate: 44100,
      numChannels: 1,
      autoGain: true,
      echoCancel: true,
      noiseSuppress: true,
    ),
    path: path,
  );

  @override
  Stream<double> levels() => _rec
      .onAmplitudeChanged(const Duration(milliseconds: 100))
      .map((a) => a.current);

  @override
  Future<String?> stop() => _rec.stop();

  @override
  Future<void> cancel() => _rec.cancel();

  @override
  Future<void> dispose() => _rec.dispose();
}

// ── Playing ───────────────────────────────────────────────────────────────

abstract class VoicePlayer {
  Future<void> play(String url);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration to);
  Future<void> setSpeed(double speed);
  Stream<Duration> get position;

  /// Fires when it plays to the end.
  Stream<void> get finished;
  Future<void> dispose();
}

class DeviceVoicePlayer implements VoicePlayer {
  final _p = AudioPlayer();

  @override
  Future<void> play(String url) => url.startsWith('/')
      ? _p.play(DeviceFileSource(url))
      : _p.play(UrlSource(url));

  @override
  Future<void> pause() => _p.pause();

  @override
  Future<void> resume() => _p.resume();

  @override
  Future<void> seek(Duration to) => _p.seek(to);

  @override
  Future<void> setSpeed(double speed) => _p.setPlaybackRate(speed);

  @override
  Stream<Duration> get position => _p.onPositionChanged;

  @override
  Stream<void> get finished => _p.onPlayerComplete;

  @override
  Future<void> dispose() => _p.dispose();
}

/// Only one voice note plays at a time: starting one stops whichever was
/// playing, the way every chat app behaves.
class VoicePlayback extends ChangeNotifier {
  VoicePlayback._();
  static final instance = VoicePlayback._();

  VoicePlayer? _player;
  StreamSubscription<Duration>? _pos;
  StreamSubscription<void>? _end;

  /// The message playing (or paused part way), by its address.
  String? current;
  bool playing = false;
  Duration position = Duration.zero;
  double speed = 1;

  Future<void> toggle(String url) async {
    if (current == url) {
      playing ? await _player?.pause() : await _player?.resume();
      playing = !playing;
      notifyListeners();
      return;
    }
    await stop();
    final p = ChatMedia.instance.player();
    _player = p;
    current = url;
    position = Duration.zero;
    playing = true;
    notifyListeners();
    _pos = p.position.listen((d) {
      position = d;
      notifyListeners();
    });
    _end = p.finished.listen((_) {
      playing = false;
      position = Duration.zero;
      current = null;
      notifyListeners();
    });
    try {
      await p.setSpeed(speed);
      await p.play(url);
    } catch (e) {
      debugPrint('[chat] a voice message would not play: $e');
      await stop();
    }
  }

  /// 1×, 1.5×, 2×, then back to 1×.
  Future<void> nextSpeed() async {
    speed = speed == 1 ? 1.5 : (speed == 1.5 ? 2 : 1);
    await _player?.setSpeed(speed);
    notifyListeners();
  }

  Future<void> stop() async {
    // Not waited on: nothing depends on the listeners having finished.
    // ignore: discarded_futures
    _pos?.cancel();
    // ignore: discarded_futures
    _end?.cancel();
    final p = _player;
    _player = null;
    _pos = null;
    _end = null;
    current = null;
    playing = false;
    position = Duration.zero;
    if (p != null) await p.dispose();
    notifyListeners();
  }
}
