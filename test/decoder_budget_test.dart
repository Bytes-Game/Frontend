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
      // Counted per question rather than in total. One probe asks two things
      // — how many H.264 decoders, and whether there is an H.265 one — so a
      // bare total of 1 would only have meant "one of them is not being
      // asked at all", which is the opposite of what this is for.
      final calls = <String, int>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), (call) async {
        calls[call.method] = (calls[call.method] ?? 0) + 1;
        return <String, int>{'c2.mtk.avc.decoder': 14};
      });
      await b.probe();
      await b.probe();
      expect(calls['videoDecoderInstances'], 1);
      expect(calls['hevcDecoderInstances'], 1,
          reason: 'the H.265 question is never asked, so no phone is ever '
              'found to support it and the smaller files go unused');
    });

    test('the H.265 answer is read, and software does not count', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), (call) async {
        if (call.method == 'hevcDecoderInstances') {
          return <String, int>{
            'c2.qti.hevc.decoder': 6,
            'c2.android.hevc.decoder': 32,
          };
        }
        return <String, int>{'c2.mtk.avc.decoder': 14};
      });
      await b.probe();
      expect(b.hasHardwareHevc, isTrue,
          reason: 'the chip reported its own H.265 decoder and it was ignored');
      expect(b.summary(), contains('hevc=yes'));
    });

    test('a phone with only Android\'s software H.265 is treated as having none',
        () async {
      // It would decode a full-screen reel at a few frames a second while
      // emptying the battery — worse than the H.264 file it replaced, which
      // is the one thing this must never be.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), (call) async {
        if (call.method == 'hevcDecoderInstances') {
          return <String, int>{'c2.android.hevc.decoder': 32};
        }
        return <String, int>{'c2.mtk.avc.decoder': 14};
      });
      await b.probe();
      expect(b.hasHardwareHevc, isFalse);
      expect(b.summary(), contains('hevc=software-only'),
          reason: 'the log must say which of the two it was — "no H.265" and '
              '"software H.265 refused" look identical from the outside');
    });

    test('an old phone that answers nothing about H.265 keeps H.264', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), (call) async {
        if (call.method == 'hevcDecoderInstances') return <String, int>{};
        return <String, int>{'c2.mtk.avc.decoder': 14};
      });
      await b.probe();
      expect(b.hasHardwareHevc, isFalse);
      // And the H.264 reading it DID give still arrived. Losing both to one
      // unanswered question would drop the phone back to old defaults for a
      // reason nothing records.
      expect(b.hardwareBudget, 14);
    });

    test('the H.265 question failing does not lose the H.264 answer', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), (call) async {
        if (call.method == 'hevcDecoderInstances') {
          throw PlatformException(code: 'NOPE');
        }
        return <String, int>{'c2.mtk.avc.decoder': 14};
      });
      await b.probe();
      expect(b.hardwareBudget, 14,
          reason: 'one unanswered question must not cost the other answer');
      expect(b.hasHardwareHevc, isFalse);
    });
  });

  _iosHevcTests();
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

// ════════════════════════════════════════════════════════════════════════════
// iOS ANSWERS THE H.265 QUESTION WITHOUT A CHANNEL
// ════════════════════════════════════════════════════════════════════════════
//
// Android is thousands of chips from dozens of makers, so the only honest
// answer is to ask the chip. Apple makes both the chip and the rule about
// which ones run which iOS, so the answer is already known from the model.
//
// A9 (2015, iPhone 6s) is the first Apple chip that decodes H.265 in
// hardware. This app's minimum is iOS 13, which already rules out every
// iPhone older than that — so the model check matters mainly for iPad, where
// an iPad Air 2 runs iPadOS 13 on an A8X that cannot.

void _iosHevcTests() {
  group('which Apple devices can read H.265', () {
    test('iPhone 6s and later can', () {
      // iPhone8,1 is the 6s — the first with an A9.
      for (final m in ['iPhone8,1', 'iPhone12,1', 'iPhone14,2', 'iPhone17,3']) {
        expect(DecoderBudget.iosModelHasHevc(m), isTrue, reason: m);
      }
    });

    test('iPhone 6 and older cannot', () {
      // A8 and A7. These cannot run iOS 13 either, so in practice they never
      // reach this app — but answering yes for them would be wrong, and a
      // rule that is wrong at the edge is a rule nobody can trust in the
      // middle.
      for (final m in ['iPhone7,2', 'iPhone6,1', 'iPhone5,1']) {
        expect(DecoderBudget.iosModelHasHevc(m), isFalse, reason: m);
      }
    });

    test('the iPad that would otherwise get a black screen', () {
      // iPad Air 2 (iPad5,3) runs iPadOS 13 on an A8X with no hardware H.265.
      // An iPhone-shaped app runs on iPad unless somebody turns that off, so
      // this is the one real device this rule exists for.
      expect(DecoderBudget.iosModelHasHevc('iPad5,3'), isFalse);
      // iPad6,x is A9X and later.
      expect(DecoderBudget.iosModelHasHevc('iPad6,11'), isTrue);
      expect(DecoderBudget.iosModelHasHevc('iPad13,1'), isTrue);
    });

    test('anything it does not recognise answers no', () {
      // A simulator, an iPod, or a naming scheme that changes. No is the
      // behaviour iOS has today, so an unknown device is never worse off.
      for (final m in [null, '', 'x86_64', 'arm64', 'iPod9,1', 'iPhone', 'Watch6,1']) {
        expect(DecoderBudget.iosModelHasHevc(m), isFalse, reason: '$m');
      }
    });
  });

  group('the iOS answer reaches the picker', () {
    tearDown(() => DecoderBudget.instance.debugReset());

    test('a modern iPhone ends up marked as able to decode H.265', () async {
      final b = DecoderBudget.instance;
      b.debugReset();
      DecoderBudget.iosMachine = () async => 'iPhone14,2';
      // canAsk is false off Android; the iOS answer must not be lost to that
      // guard, which returns before the channel is ever used.
      DecoderBudget.canAsk = () => false;
      await b.probe();
      expect(b.hasHardwareHevc, isTrue,
          reason: 'the model said A15 and the app still refused H.265, so '
              'every iPhone keeps the bigger files for nothing');
      expect(b.summary(), contains('hevc=yes'),
          reason: 'and the log has to say so, or there is no way to tell '
              'from a device log which files an iPhone was served');
    });

    test('an old iPad is left exactly where it was', () async {
      final b = DecoderBudget.instance;
      b.debugReset();
      DecoderBudget.iosMachine = () async => 'iPad5,3';
      DecoderBudget.canAsk = () => false;
      await b.probe();
      expect(b.hasHardwareHevc, isFalse);
    });

    test('a device that will not say what it is answers no', () async {
      final b = DecoderBudget.instance;
      b.debugReset();
      DecoderBudget.iosMachine = () async => null;
      DecoderBudget.canAsk = () => false;
      await b.probe();
      expect(b.hasHardwareHevc, isFalse);
    });
  });
}
