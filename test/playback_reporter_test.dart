import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/services/playback_reporter.dart';

/// The reporter's job is to tell us about videos that would not play. Its
/// other job — the one that is easy to forget and expensive to get wrong — is
/// to stop talking before it spends the whole monthly error budget on a single
/// bad batch of uploads.
void main() {
  setUp(() => PlaybackReporter.instance.resetForTest());
  tearDown(() => PlaybackReporter.instance.resetForTest());

  test('reports a failure', () {
    PlaybackReporter.instance.reportPlaybackFailure(
      videoUrl: 'https://cdn.example.com/u/1/abc/720p.mp4',
      error: 'MediaCodecVideoRenderer error',
    );
    expect(PlaybackReporter.instance.sentCount, 1);
  });

  test('stops reporting once the per-session cap is reached', () {
    // A feed full of broken videos would otherwise fire this on every swipe.
    // The free error-reporting tier allows roughly 5,000 events a month, so
    // one bad afternoon could leave us blind for the rest of it.
    for (var i = 0; i < 50; i++) {
      PlaybackReporter.instance.reportPlaybackFailure(
        videoUrl: 'https://cdn.example.com/broken$i.mp4',
        error: 'boom',
      );
    }
    expect(
      PlaybackReporter.instance.sentCount,
      PlaybackReporter.maxReportsPerSessionForTest,
      reason: 'the cap did not hold — one bad feed can spend the whole budget',
    );
  });

  test('the cap still lets the first failures through', () {
    // Going quiet is only acceptable because the news has already been sent.
    // A cap of zero would be silent, which is the same as not having this.
    expect(PlaybackReporter.maxReportsPerSessionForTest, greaterThan(0));

    PlaybackReporter.instance.reportPlaybackFailure(
      videoUrl: 'https://cdn.example.com/first.mp4',
    );
    expect(PlaybackReporter.instance.sentCount, 1);
  });

  test('recovered and unrecovered failures are both counted', () {
    PlaybackReporter.instance.reportPlaybackFailure(
      videoUrl: 'https://cdn.example.com/a.m3u8',
      recovered: true,
    );
    PlaybackReporter.instance.reportPlaybackFailure(
      videoUrl: 'https://cdn.example.com/b.mp4',
      recovered: false,
    );
    expect(PlaybackReporter.instance.sentCount, 2);
  });

  group('what gets described', () {
    test('tells adaptive streaming apart from a plain file', () {
      // The two fail for different reasons and are fixed in different places,
      // so a report that cannot tell them apart is much less useful.
      expect(PlaybackReporter.describeSourceForTest('https://x/y/master.m3u8'),
          'hls');
      expect(PlaybackReporter.describeSourceForTest('https://x/y/720p.mp4'),
          'mp4');
      expect(
          PlaybackReporter.describeSourceForTest('http://127.0.0.1:41234/m/ab'),
          'proxy');
    });

    test('keeps the host and drops the path', () {
      // The host says which storage was involved, which is a real question
      // when failures cluster. The path identifies one person's upload, which
      // is not needed to fix anything.
      expect(
        PlaybackReporter.describeHostForTest(
            'https://pub-abc123.r2.dev/u/42/secret-id/720p.mp4'),
        'pub-abc123.r2.dev',
      );
    });

    test('survives a url it cannot parse', () {
      expect(PlaybackReporter.describeHostForTest(''), 'unknown');
      expect(PlaybackReporter.describeHostForTest('not a url'), 'unknown');
    });
  });
}
