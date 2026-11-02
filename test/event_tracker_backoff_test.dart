// The activity reporter (EventTracker) when the server cannot be reached.
//
// A phone log showed it failing about 150 times in seven minutes while the
// app sat in the background with no network: a try every five seconds, and
// another with every new event once ten were waiting. Now it waits longer
// after each failure, up to five minutes, and goes back to normal once a
// send works.
//
// Time here is the test's own clock, so forty minutes pass in moments. The
// reporter ticks every five seconds of it.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';

void main() {
  late int now; // seconds of the test's clock since the test began
  late List<int> sentAt; // when each upload reached the server
  late bool serverUp;
  Completer<void>? hold; // while set, the server does not answer

  setUp(() {
    now = 0;
    sentAt = [];
    serverUp = false;
    hold = null;
    ApiService.useClient(MockClient((req) async {
      if (req.url.path.endsWith('/api/v1/events/batch')) {
        sentAt.add(now);
        final slow = hold;
        if (slow != null) await slow.future;
        return http.Response('', serverUp ? 200 : 503);
      }
      return http.Response('{}', 200);
    }));
  });
  tearDown(() {
    EventTracker.instance.dispose();
    ApiService.useClient(http.Client());
  });

  int sends() => sentAt.length;

  void event() => EventTracker.instance
      .track(eventType: 'tap', contentId: 'x', contentType: 'ui');

  /// Somebody signs in, at second 0.
  void signIn() {
    EventTracker.instance.dispose();
    EventTracker.instance.init('7');
  }

  /// Signs out with the server answering, so nothing is left queued or on
  /// its way. The tracker is shared by every test here, and a send still
  /// going when the next test starts would skew that test's count.
  Future<void> signOut(WidgetTester t) async {
    serverUp = true;
    hold?.complete();
    hold = null;
    EventTracker.instance.dispose();
    await t.pump();
  }

  /// [seconds] of the test's clock, and whatever that sets off.
  Future<void> wait(WidgetTester t, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      now++;
      await t.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('a server that cannot be reached is tried less and less often',
      (t) async {
    signIn();
    event();

    await wait(t, 5);
    expect(sends(), 1, reason: 'the first tick sends');
    await wait(t, 5);
    expect(sends(), 1, reason: 'after one failure: one tick sat out');
    await wait(t, 5);
    expect(sends(), 2);
    await wait(t, 10);
    expect(sends(), 2, reason: 'after two: two ticks sat out');
    await wait(t, 5);
    expect(sends(), 3);
    await wait(t, 20);
    expect(sends(), 3, reason: 'after three: four ticks sat out');
    await wait(t, 5);
    expect(sends(), 4, reason: 'four tries in 55 seconds, where it was 11');

    // New events while it waits do not set off a try, even with plenty
    // waiting (the failed ones are back in the queue).
    for (var i = 0; i < 15; i++) {
      event();
    }
    await t.pump();
    expect(sends(), 4);

    // The server is back: the next try works, and from then on it is
    // every tick again.
    serverUp = true;
    await wait(t, 45);
    expect(sends(), 5, reason: 'after four failures: eight ticks sat out');
    event();
    await wait(t, 5);
    expect(sends(), 6, reason: 'working again: the next tick sends');

    // And the count starts over: down again, the first failure sits out
    // one tick, not sixteen.
    serverUp = false;
    event();
    await wait(t, 5);
    expect(sends(), 7);
    await wait(t, 10);
    expect(sends(), 8, reason: 'counted from one again');

    await signOut(t);
  });

  testWidgets(
      'the gaps between tries stop growing at five minutes, and forty '
      'minutes offline is a few lines in the log, not hundreds', (t) async {
    final said = <String>[];
    final before = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.startsWith('[events]')) {
        said.add(message);
      }
    };
    try {
      signIn();
      event();
      await wait(t, 40 * 60);
    } finally {
      debugPrint = before;
    }

    final gaps = [
      for (var i = 1; i < sentAt.length; i++) sentAt[i] - sentAt[i - 1]
    ];
    expect(gaps, [10, 15, 25, 45, 85, 165, 305, 305, 305, 305, 305, 305]);
    expect(sends(), 13, reason: 'it was a try every five seconds: 480');

    expect(said, hasLength(8),
        reason: 'one line each while the wait grows (7), then hourly');
    expect(said.first, contains('first try'));
    expect(said.first, contains('trying again in 10s'));
    expect(said[6], contains('trying again in 305s'));
    expect(said.last, contains('12 tries in a row'));

    await signOut(t);
  });

  testWidgets('never two sends at once, while a slow server answers',
      (t) async {
    serverUp = true;
    hold = Completer<void>();
    signIn();
    event();
    await wait(t, 5);
    expect(sends(), 1);

    // The server takes twenty seconds to answer (one waking up took 20 to
    // 33 in the phone log). Events keep coming, enough to fill a batch
    // twice, and four ticks pass.
    for (var s = 0; s < 20; s++) {
      event();
      await wait(t, 1);
    }
    expect(sends(), 1, reason: 'still waiting for the first answer');

    hold!.complete();
    hold = null;
    await wait(t, 5);
    expect(sends(), 2, reason: 'what came meanwhile goes in the next one');

    await signOut(t);
  });

  testWidgets(
      'leaving the app tries at once, even during a wait, and if that '
      'works the wait is over', (t) async {
    signIn();
    event();
    await wait(t, 15);
    expect(sends(), 2, reason: 'failed twice: two ticks to sit out');

    serverUp = true;
    EventTracker.instance.trackAppBackground();
    await t.pump();
    expect(sends(), 3, reason: 'the last chance to send, so it does');

    event();
    await wait(t, 5);
    expect(sends(), 4, reason: 'it worked, so no more sitting out');

    await signOut(t);
  });

  testWidgets('the next person to sign in starts with no wait', (t) async {
    signIn();
    event();
    await wait(t, 15);
    expect(sends(), 2);

    // Signing out makes one last try, which fails too.
    EventTracker.instance.dispose();
    await t.pump();
    expect(sends(), 3);

    EventTracker.instance.init('8');
    event();
    await wait(t, 5);
    expect(sends(), 4, reason: "the next person's first tick sends");

    await signOut(t);
  });
}
