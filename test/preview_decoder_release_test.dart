// A phone has a handful of video decoders. This page was holding sixteen.
//
// ROOT CAUSE, counted from a 57,000-line device log rather than guessed:
//
//   video decoders created over the session : 112
//   PEAK alive at the same time             :  16
//   still alive at the end                  :  15
//
// The feed's pool is capped at FOUR, deliberately — that is what the screen
// needs and what the hardware is comfortable with. The search grid had no cap
// at all: a tile that stopped being the active preview called pause(), which
// stops playback and keeps the decoder. The controller was only let go when
// the WIDGET was disposed, and a grid keeps tiles alive well past the edge of
// the screen. Every tile that ever took a turn kept a decoder.
//
// What sixteen looks like, in the same log:
//
//   71  "codec sleep"  — the chip powering down a decoder it thinks is idle
//    9  "Decoder failed: c2.mtk.avc.decoder" — one refusing to wake again
//   75% of decoders rendering slower than 100ms a frame (30fps is 33ms)
//   25% of decoders rendering slower than THREE SECONDS a frame
//
// They were starving each other. And the failures were not confined to this
// page: two of the videos that failed in the feed and fell back to HLS were
// ordinary H.264 High files with nothing wrong with them.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

void main() {
  final src = File('lib/pages/search_page.dart').readAsStringSync();

  group('a preview that is not playing holds no decoder', () {
    test('deactivating releases, it does not merely pause', () {
      final body = bodyOf(src, 'void _onCoordinatorChanged()');
      expect(body, contains('_releasePlayer()'),
          reason: 'pause() stops playback and keeps the decoder, so every '
              'tile that ever took a turn holds one for as long as the grid '
              'keeps the tile alive');
      expect(body, isNot(contains('_controller?.pause()')),
          reason: 'back to pausing, which is the leak');
    });

    test('releasing actually disposes the controller', () {
      final body = bodyOf(src, 'void _releasePlayer()');
      expect(body, contains('c.dispose()'),
          reason: 'nulling the reference without disposing leaks the '
              'decoder AND makes it unreachable to dispose later');
      expect(body, contains('_controller = null'));
    });

    test('and detaches its listener first', () {
      // A listener left on a disposed controller fires against dead state.
      final body = bodyOf(src, 'void _releasePlayer()');
      final removeAt = body.indexOf('removeListener');
      final disposeAt = body.indexOf('c.dispose()');
      expect(removeAt, greaterThan(-1), reason: 'listener never detached');
      expect(removeAt, lessThan(disposeAt),
          reason: 'detach before dispose, or the listener can fire on a '
              'controller that is already gone');
    });

    test('releasing twice is harmless', () {
      // _onCoordinatorChanged can fire again before a rebuild.
      final body = bodyOf(src, 'void _releasePlayer()');
      expect(body, contains('if (c == null) return;'),
          reason: 'a second release would dispose an already-disposed '
              'controller, which throws');
    });

    test('the tile can take another turn afterwards', () {
      // Release is only safe because the play path rebuilds from nothing.
      final body = bodyOf(src, 'Future<void> _ensurePlayerAndPlay()');
      expect(body, contains('if (_controller == null) {'),
          reason: 'after a release the controller is null, so the play path '
              'has to be able to build a fresh one');
      final release = bodyOf(src, 'void _releasePlayer()');
      expect(release, contains('_completionReported = false'),
          reason: 'the new player starts a new pass; a stale completion flag '
              'would stop the coordinator ever advancing past this tile');
    });
  });

  group('how many decoders the grid can hold', () {
    test('one at a time, because one plays at a time', () {
      // The coordinator guarantees a single active tile, so a single
      // decoder covers the whole grid. This is the property that makes
      // releasing correct rather than merely cheaper.
      final coord = bodyOf(src, 'void _setActive(');
      expect(coord.isNotEmpty, isTrue);
      final body = bodyOf(src, 'void _onCoordinatorChanged()');
      expect(body, contains('final shouldBeActive = widget.coordinator.activeId == _id;'),
          reason: 'if more than one tile could be active, releasing on '
              'deactivate would still leave several decoders alive');
    });
  });
}
