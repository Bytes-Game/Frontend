// Stand-ins for the parts of a call that need a real phone: the
// microphone, camera and direct line (CallMedia), the live connection
// (a WebSocketService that records what it sends), and the ring.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:myapp/services/call_service.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/widgets/call_host.dart';

/// A pretend microphone, camera and line. Records every step it is asked
/// to take, in order.
class FakeCallMedia implements CallMedia {
  final List<String> steps = [];
  final List<Map<String, dynamic>> theirAddresses = [];
  bool deny = false;
  bool closed = false;

  /// Whether the other phone's description has been used yet. A real
  /// phone refuses their addresses before that, so this one does too.
  bool _theirsKnown = false;
  bool? muted;
  bool? cameraOn;
  bool? speaker;
  void Function(Map<String, dynamic>)? onCandidate;
  void Function(CallLink)? onLink;
  final _remoteVideo = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get remoteVideo => _remoteVideo;

  /// Their picture arrives.
  void theirPictureArrives() => _remoteVideo.value = true;

  @override
  Future<void> open({required bool video}) async {
    steps.add('open video=$video');
    if (deny) throw const CallMediaDenied();
  }

  @override
  Future<void> connect(
    List<Map<String, dynamic>> iceServers, {
    required void Function(Map<String, dynamic>) onCandidate,
    required void Function(CallLink) onLink,
  }) async {
    steps.add('connect via ${iceServers.length}');
    this.onCandidate = onCandidate;
    this.onLink = onLink;
  }

  @override
  Future<String> createOffer() async {
    steps.add('offer');
    // A real phone finds its first address while describing itself, before
    // the offer has gone anywhere.
    onCandidate?.call({'candidate': 'mine-1', 'sdpMid': '0', 'sdpMLineIndex': 0});
    return 'OFFER-SDP';
  }

  @override
  Future<String> createAnswer(String offer) async {
    steps.add('answer $offer');
    _theirsKnown = true;
    onCandidate?.call({'candidate': 'mine-1', 'sdpMid': '0', 'sdpMLineIndex': 0});
    return 'ANSWER-SDP';
  }

  @override
  Future<void> acceptAnswer(String answer) async {
    steps.add('accept $answer');
    _theirsKnown = true;
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> address) async {
    if (!_theirsKnown) {
      throw StateError('an address before their description: refused');
    }
    theirAddresses.add(address);
  }

  @override
  void setMuted(bool muted) => this.muted = muted;

  @override
  void setCameraOn(bool on) => cameraOn = on;

  @override
  Future<void> switchCamera() async => steps.add('flip');

  @override
  Future<void> setSpeaker(bool on) async => speaker = on;

  @override
  Widget localView() => const ColoredBox(
        key: ValueKey('fake_local_view'),
        color: Colors.green,
        child: SizedBox.expand(),
      );

  @override
  Widget remoteView() => const ColoredBox(
        key: ValueKey('fake_remote_view'),
        color: Colors.blue,
        child: SizedBox.expand(),
      );

  @override
  Future<void> close() async {
    closed = true;
    steps.add('close');
  }
}

/// A live connection that is never opened: what arrives is handed in with
/// debugReceive, and what is sent is kept in [sent].
class RecordingSocket extends WebSocketService {
  RecordingSocket() : super('', '');

  final List<Map<String, dynamic>> sent = [];
  bool online = true;

  @override
  bool send(Map<String, dynamic> event) {
    if (!online) return false;
    sent.add(Map.of(event));
    return true;
  }

  List<Map<String, dynamic>> sentOf(String type) =>
      [for (final e in sent) if (e['type'] == type) e];
}

class SilentSounds implements CallSounds {
  final List<String> played = [];

  @override
  Future<void> ring() async => played.add('ring');

  @override
  Future<void> ringback() async => played.add('ringback');

  @override
  Future<void> stop() async => played.add('stop');
}

/// A CallService on [socket], making a fresh FakeCallMedia for each call
/// and keeping them in [made].
CallService fakeCalls(
  RecordingSocket socket, {
  List<FakeCallMedia>? made,
  bool deny = false,
}) {
  return CallService(
    events: socket.events,
    send: socket.send,
    media: () {
      final m = FakeCallMedia()..deny = deny;
      made?.add(m);
      return m;
    },
    iceServers: () async => (
      servers: [
        {
          'urls': ['stun:x'],
        },
      ],
      relay: false,
    ),
  );
}
