// Asking the chip how many videos it will decode at once.
//
// The app keeps several open so a swipe lands on one already playing. How
// many it MAY keep is a property of the chip, not of memory, and nothing
// tells the app up front — it used to assume four for every phone and find
// out it was wrong only when a request was refused or a decoder was taken
// back mid-playback, which the viewer sees as a frozen video.
//
// This file covers the reading itself: which codec's number binds, what a
// nonsense answer does, and that startup actually asks. What the app then
// DOES with the number is adaptive_working_set_test.dart.
//
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/decoder_budget.dart';
import 'package:myapp/services/device_capabilities.dart';
import 'package:myapp/services/reel_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DecoderBudget b;

  setUp(() {
    b = DecoderBudget.instance;
    b.debugReset();
    // The test host is not Android; the seam is what lets the asking be
    // tested at all.
    DecoderBudget.canAsk = () => true;
    ReelDiagnostics.instance.debugReset();
  });

  tearDown(() {
    b.debugReset();
    DecoderBudget.canAsk = () => false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('devf/device_media'), null);
  });

  group('telling the chip apart from the software fallback', () {
    test("Android's own decoders are software", () {
      // Named by convention: Codec2 generation, and the one before it.
      expect(DecoderBudget.isSoftware('c2.android.avc.decoder'), isTrue);
      expect(DecoderBudget.isSoftware('OMX.google.h264.decoder'), isTrue);
      expect(DecoderBudget.isSoftware('OMX.qcom.video.decoder.avc.sw'), isTrue);
    });

    test("the vendor's are the hardware", () {
      expect(DecoderBudget.isSoftware('c2.mtk.avc.decoder'), isFalse);
      expect(DecoderBudget.isSoftware('OMX.qcom.video.decoder.avc'), isFalse);
      expect(DecoderBudget.isSoftware('c2.exynos.avc.decoder'), isFalse);
    });

    test('case does not decide it', () {
      expect(DecoderBudget.isSoftware('C2.Android.Avc.Decoder'), isTrue);
    });
  });

  group('which reading actually binds', () {
    test('the chip, not the software fallback', () {
      // The software one reports a generous number because it is limited by
      // the processor rather than fixed hardware — and it is far too slow
      // for this feed. Counting it reports that generosity as though the
      // chip had it, which is the opposite of useful on a cheap phone.
      b.debugSet({'c2.mtk.avc.decoder': 14, 'c2.android.avc.decoder': 32});
      expect(b.hardwareBudget, 14);
    });

    test('the smallest, when a phone carries several of the chip\'s', () {
      // Every hardware decoder shares the same silicon. The one that gives
      // up first is the one that decides.
      b.debugSet({
        'c2.mtk.avc.decoder': 14,
        'OMX.MTK.VIDEO.DECODER.AVC': 6,
        'c2.android.avc.decoder': 32,
      });
      expect(b.hardwareBudget, 6);
    });

    test('nothing read means no opinion', () {
      expect(b.hardwareBudget, isNull,
          reason: 'a made-up number here would decide how many videos a '
              'phone keeps open');
    });

    test('software only means no opinion either', () {
      b.debugSet({'c2.android.avc.decoder': 32});
      expect(b.hardwareBudget, isNull);
    });

    test('a zero or negative reading is not an opinion', () {
      // Some devices report 0 for a codec they will not really run.
      b.debugSet({'c2.mtk.avc.decoder': 0, 'OMX.MTK.VIDEO.DECODER.AVC': 8});
      expect(b.hardwareBudget, 8,
          reason: 'a nonsense reading became the number the whole app sized '
              'itself by');
    });
  });

  group('it reaches the log', () {
    test('every reading, and which one binds', () {
      b.debugSet({'c2.mtk.avc.decoder': 14, 'c2.android.avc.decoder': 32});
      final s = b.summary();
      expect(s, contains('c2.mtk.avc.decoder=14'));
      expect(s, contains('c2.android.avc.decoder(sw)=32'),
          reason: 'the software one has to be in the log AND marked, or the '
              'next person reads 32 as what this phone can do');
      expect(s, contains('hardware=14'));
    });

    test('and nothing at all when nothing was read', () {
      expect(b.summary(), isEmpty,
          reason: 'a platform that cannot answer should not carry a row of '
              'nothing through the one line that gets read');
    });

    test('the reel summary carries it', () {
      b.debugSet({'c2.mtk.avc.decoder': 14});
      ReelDiagnostics.instance.recordProxiedStart();
      expect(ReelDiagnostics.instance.summary(), contains('hardware=14'),
          reason: 'this is the ceiling every other number in that line is '
              'operating under');
    });

    test('and is silent in that line too when there is nothing to say', () {
      ReelDiagnostics.instance.recordProxiedStart();
      expect(ReelDiagnostics.instance.summary(), isNot(contains('decoders{')));
    });
  });

  _startupAsksTests();

  group('asking the phone', () {
    test('a platform that has no answer is never asked', () async {
      DecoderBudget.canAsk = () => false;
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), (call) async {
        calls++;
        return <String, int>{};
      });
      await b.probe();
      expect(calls, 0);
      expect(b.probed, isTrue,
          reason: 'not asking still counts as asked, or every caller tries '
              'again for ever');
    });

    Future<void> answerWith(Object? reply) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), (call) async {
        expect(call.method, 'videoDecoderInstances');
        return reply;
      });
      await b.probe();
    }

    test('a real answer is kept', () async {
      await answerWith(<String, int>{'c2.mtk.avc.decoder': 14});
      expect(b.hardwareBudget, 14);
    });

    test('an empty answer leaves the app as it was', () async {
      await answerWith(<String, int>{});
      expect(b.instancesByCodec, isEmpty);
      expect(b.hardwareBudget, isNull);
    });

    test('a phone that throws leaves the app as it was', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), (call) async {
        throw PlatformException(code: 'NOPE');
      });
      await b.probe();
      expect(b.hardwareBudget, isNull,
          reason: 'a launch must not fail over a number that is only a hint');
    });

    test('asking twice only asks once', () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), (call) async {
        calls++;
        return <String, int>{'c2.mtk.avc.decoder': 14};
      });
      await b.probe();
      await b.probe();
      expect(calls, 1);
    });
  });
}

// Startup has to actually ask. The reading is worthless if nothing calls
// for it, and "there is a probe method" is not the same as "the app runs
// it" — which is exactly the kind of gap that only shows up as a log line
// that never appears.
void _startupAsksTests() {
  group('startup asks the phone', () {
    setUp(() {
      DecoderBudget.instance.debugReset();
      DeviceCapabilities.instance.debugResetProbe();
      DecoderBudget.canAsk = () => true;
    });

    tearDown(() {
      DecoderBudget.instance.debugReset();
      DecoderBudget.canAsk = () => false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), null);
    });

    test('the device probe reads the decoder budget too', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), (call) async {
        return <String, int>{'c2.mtk.avc.decoder': 11};
      });

      await DeviceCapabilities.instance.probe();

      expect(DecoderBudget.instance.hardwareBudget, 11,
          reason: 'nothing at startup asks, so the number never reaches a '
              'log and the whole reading is decoration');
    });
  });
}
