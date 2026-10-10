// The song in the video editor plays alongside the video, instead of
// taking the phone's sound from it.
//
// WHY. A run logged it four times: press play, the video starts, the song
// starts, and the video pauses itself a tenth of a second later. Both
// players asked Android for the phone's sound, and Android takes it from
// whichever had it - so each knocked the other out, and the song was cut
// off too. The song now plays without asking.
//
// This runs the real song player (DeviceMusicPlayer) against a stand-in
// for the phone side, and reads what it sent.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/music_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('xyz.luan/audioplayers');
  const global = MethodChannel('xyz.luan/audioplayers.global');
  const events = EventChannel('xyz.luan/audioplayers/events/song');
  final sent = <MethodCall>[];

  setUp(() {
    sent.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MockStreamHandlerEventSink? phone;
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (_, sink) => phone = sink),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      sent.add(call);
      // The player waits for the phone to say a song is ready, and that a
      // jump has landed.
      if (call.method == 'setSourceUrl') {
        phone?.success({'event': 'audio.onPrepared', 'value': true});
      }
      if (call.method == 'seek') {
        phone?.success({'event': 'audio.onSeekComplete'});
      }
      return call.method == 'getDuration' || call.method == 'getCurrentPosition'
          ? 0
          : null;
    });
    messenger.setMockMethodCallHandler(global, (call) async => null);
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(global, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('it is the player the app uses, in the editor and the picker', () {
    // The wire from the editor to the setting below: a different player
    // here and the fix would never run.
    expect(MusicPlayer.create, same(DeviceMusicPlayer.new));
  });

  test(
    'plays without asking for the phone\'s sound, before it plays',
    () async {
      final player = DeviceMusicPlayer(AudioPlayer(playerId: 'song'));
      await player.play('/songs/one.mp3', loop: true);

      final methods = sent.map((c) => c.method).toList();
      final shared = methods.indexOf('setAudioContext');
      final starts = methods.indexOf('resume');
      expect(
        shared,
        greaterThan(-1),
        reason: 'the sound setting was never sent: $methods',
      );
      expect(
        starts,
        greaterThan(shared),
        reason: 'it has to be set before the song starts: $methods',
      );
      expect(
        (sent[shared].arguments as Map)['audioFocus'],
        AndroidAudioFocus.none.value,
        reason: "asks for nothing, so the video keeps the phone's sound",
      );

      // And only once, not on every play.
      await player.play('/songs/one.mp3', loop: true);
      expect(sent.where((c) => c.method == 'setAudioContext'), hasLength(1));
      await player.dispose();
    },
  );
}
