// Calls, step by step, between two pretend phones.
//
// Everything a call does that is not the microphone, camera or network is
// in CallService, and that is what these drive: what gets sent to the other
// phone and when, what is held back until it can be used, and how every way
// a call can end is told and shown. Only the phone's own parts are faked
// (support/call_fakes.dart).

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/call_service.dart';

import 'support/call_fakes.dart';

const maya = CallPeer(id: '7', username: 'maya');

void main() {
  late RecordingSocket socket;
  late List<FakeCallMedia> made;
  late CallService calls;

  void open() {
    socket = RecordingSocket();
    made = [];
    calls = fakeCalls(socket, made: made);
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.pump();
    }
  }

  void arrive(Map<String, dynamic> ev) => socket.debugReceive(ev);

  String callId() => socket.sentOf('call_offer').single['callId'] as String;

  Future<void> close(WidgetTester t) async {
    await t.pump(const Duration(seconds: 3));
    calls.dispose();
    socket.dispose();
  }

  group('calling somebody', () {
    testWidgets('the offer goes out with this phone\'s description, and '
        'addresses found before it wait for it', (t) async {
      open();
      await calls.start(maya, video: true);
      await settle(t);

      expect(calls.phase, CallPhase.calling);
      expect(made.single.steps, ['open video=true', 'connect via 1', 'offer']);
      final offer = socket.sentOf('call_offer').single;
      expect(offer['to'], '7');
      expect(offer['video'], true);
      expect(offer['sdp'], 'OFFER-SDP');
      // The address found while describing went out AFTER the offer. Sent
      // first, it would reach a phone that has not heard of the call.
      expect(socket.sent.map((e) => e['type']).toList(),
          ['call_offer', 'call_ice']);
      expect(socket.sentOf('call_ice').single['callId'], offer['callId']);
      await close(t);
    });

    testWidgets('ringing, answered, connected, hung up', (t) async {
      open();
      await calls.start(maya, video: false);
      await settle(t);
      final id = callId();

      arrive({'type': 'call_ringing', 'callId': id, 'from': '7'});
      await settle(t);
      expect(calls.phase, CallPhase.ringing);

      // Their addresses can arrive before their answer has been used.
      arrive({'type': 'call_ice', 'callId': id, 'candidate': 'theirs-1'});
      arrive({'type': 'call_answer', 'callId': id, 'sdp': 'ANSWER-SDP'});
      await settle(t);
      expect(calls.phase, CallPhase.connecting);
      expect(made.single.steps.last, 'accept ANSWER-SDP');
      expect(made.single.theirAddresses.map((a) => a['candidate']),
          ['theirs-1'],
          reason: 'an address that came early was dropped');

      made.single.onLink!(CallLink.up);
      await settle(t);
      expect(calls.phase, CallPhase.connected);
      expect(calls.connectedAt, isNotNull);

      calls.hangUp();
      await settle(t);
      expect(socket.sentOf('call_end').single['reason'], 'hangup');
      expect(made.single.closed, isTrue);
      expect(calls.phase, CallPhase.ended);
      expect(calls.endedLabel(), startsWith('Call ended · 0:0'));

      await t.pump(calls.endedFor);
      expect(calls.phase, CallPhase.idle);
      await close(t);
    });

    testWidgets('nobody answers: the call gives up and they get a missed call',
        (t) async {
      open();
      await calls.start(maya, video: false);
      await settle(t);
      await t.pump(calls.ringFor);
      expect(calls.phase, CallPhase.ended);
      expect(calls.endedLabel(), 'No answer');
      expect(socket.sentOf('call_end').single['reason'], 'missed');
      await close(t);
    });

    testWidgets('hanging up before they answer is a missed call for them',
        (t) async {
      open();
      await calls.start(maya, video: false);
      await settle(t);
      calls.hangUp();
      await settle(t);
      expect(socket.sentOf('call_end').single['reason'], 'missed');
      expect(calls.endedLabel(), 'Call cancelled');
      await close(t);
    });

    for (final (type, label) in [
      ('call_decline', 'maya declined'),
      ('call_busy', 'maya is on another call'),
      ('call_unavailable', 'maya is not available right now'),
    ]) {
      testWidgets('$type ends it: "$label"', (t) async {
        open();
        await calls.start(maya, video: false);
        await settle(t);
        arrive({'type': type, 'callId': callId(), 'from': '7'});
        await settle(t);
        expect(calls.phase, CallPhase.ended);
        expect(calls.endedLabel(), label);
        expect(made.single.closed, isTrue);
        // Nothing is said back: they already know.
        expect(socket.sentOf('call_end'), isEmpty);
        await close(t);
      });
    }

    testWidgets('a refused microphone ends it before anything is sent',
        (t) async {
      socket = RecordingSocket();
      made = [];
      calls = fakeCalls(socket, made: made, deny: true);
      await calls.start(maya, video: true);
      await settle(t);
      expect(calls.phase, CallPhase.ended);
      expect(calls.endedLabel(), 'Allow the camera and microphone to call');
      expect(socket.sent, isEmpty);
      await close(t);
    });

    testWidgets('no connection: "You\'re offline"', (t) async {
      open();
      socket.online = false;
      await calls.start(maya, video: false);
      await settle(t);
      expect(calls.endedLabel(), "You're offline");
      await close(t);
    });

    testWidgets('signals for some other call are ignored', (t) async {
      open();
      await calls.start(maya, video: false);
      await settle(t);
      arrive({'type': 'call_decline', 'callId': 'not-this-one', 'from': '7'});
      await settle(t);
      expect(calls.phase, CallPhase.calling);
      // And the real one is not.
      arrive({'type': 'call_decline', 'callId': callId(), 'from': '7'});
      await settle(t);
      expect(calls.phase, CallPhase.ended);
      await close(t);
    });

    testWidgets('a line that drops gets a moment to come back, then ends',
        (t) async {
      open();
      await calls.start(maya, video: false);
      await settle(t);
      arrive({'type': 'call_answer', 'callId': callId(), 'sdp': 'A'});
      await settle(t);
      final media = made.single;
      media.onLink!(CallLink.up);
      media.onLink!(CallLink.lost);
      await settle(t);
      expect(calls.reconnecting, isTrue);
      media.onLink!(CallLink.up);
      await settle(t);
      expect(calls.reconnecting, isFalse);
      await t.pump(calls.reconnectFor * 2);
      expect(calls.phase, CallPhase.connected, reason: 'it came back');

      media.onLink!(CallLink.lost);
      await t.pump(calls.reconnectFor);
      expect(calls.phase, CallPhase.ended);
      expect(socket.sentOf('call_end').single['reason'], 'failed');
      await close(t);
    });

    testWidgets('mute, camera and speaker reach the phone', (t) async {
      open();
      await calls.start(maya, video: true);
      await settle(t);
      final media = made.single;
      expect(media.speaker, isTrue, reason: 'video calls start on speaker');
      calls.toggleMute();
      calls.toggleCamera();
      calls.toggleSpeaker();
      await calls.switchCamera();
      expect(media.muted, isTrue);
      expect(media.cameraOn, isFalse);
      expect(media.speaker, isFalse);
      expect(media.steps.last, 'flip');
      await close(t);
    });
  });

  group('being called', () {
    Map<String, dynamic> offer({String id = 'c1', bool video = true}) => {
          'type': 'call_offer',
          'callId': id,
          'from': '7',
          'fromUsername': 'maya',
          'video': video,
          'sdp': 'OFFER-SDP',
        };

    testWidgets('it rings, and the caller is told it is ringing', (t) async {
      open();
      arrive(offer());
      await settle(t);
      expect(calls.phase, CallPhase.incoming);
      expect(calls.peer?.username, 'maya');
      expect(calls.video, isTrue);
      expect(socket.sentOf('call_ringing').single,
          {'type': 'call_ringing', 'to': '7', 'callId': 'c1'});
      expect(made, isEmpty, reason: 'nothing is opened until they pick up');
      await close(t);
    });

    testWidgets('picking up answers, using addresses that came while ringing',
        (t) async {
      open();
      arrive(offer());
      arrive({'type': 'call_ice', 'callId': 'c1', 'candidate': 'theirs-1'});
      await settle(t);
      await calls.accept();
      await settle(t);
      final media = made.single;
      expect(media.steps, ['open video=true', 'connect via 1', 'answer OFFER-SDP']);
      expect(media.theirAddresses.map((a) => a['candidate']), ['theirs-1']);
      final answer = socket.sentOf('call_answer').single;
      expect(answer['sdp'], 'ANSWER-SDP');
      expect(answer['to'], '7');
      // This phone's own address goes after the answer, not before.
      final types = socket.sent.map((e) => e['type']).toList();
      expect(types.indexOf('call_ice'), greaterThan(types.indexOf('call_answer')));
      expect(calls.phase, CallPhase.connecting);
      await close(t);
    });

    testWidgets('declining says so', (t) async {
      open();
      arrive(offer());
      await settle(t);
      calls.decline();
      await settle(t);
      expect(socket.sentOf('call_decline').single['callId'], 'c1');
      expect(calls.endedLabel(), 'Call declined');
      await close(t);
    });

    testWidgets('they hang up while it rings: a missed call', (t) async {
      open();
      arrive(offer());
      await settle(t);
      arrive({'type': 'call_end', 'callId': 'c1', 'from': '7', 'reason': 'missed'});
      await settle(t);
      expect(calls.endedLabel(), 'Missed call');
      await close(t);
    });

    testWidgets('a second call while on one is told "busy"', (t) async {
      open();
      arrive(offer());
      await settle(t);
      arrive({...offer(id: 'c2'), 'from': '9', 'fromUsername': 'sam'});
      await settle(t);
      expect(socket.sentOf('call_busy').single,
          {'type': 'call_busy', 'to': '9', 'callId': 'c2'});
      expect(calls.peer?.username, 'maya', reason: 'the first call carries on');
      await close(t);
    });

    testWidgets('a call nobody picks up stops ringing', (t) async {
      open();
      arrive(offer());
      await settle(t);
      await t.pump(calls.ringFor);
      expect(calls.phase, CallPhase.ended);
      expect(calls.endedLabel(), 'Missed call');
      await close(t);
    });
  });
}
