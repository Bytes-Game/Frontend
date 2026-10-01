import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

/// Audio and video calls.
///
/// The sound and the picture go straight from one phone to the other
/// (WebRTC). The server only introduces the two phones: before they can
/// find each other they swap a description of what each can send and the
/// network addresses each can be reached at, and they swap those through
/// the live connection the app already keeps open for chat.
///
/// This class is the whole conversation between the two phones, step by
/// step:
///
///   caller                              the person called
///   ──────                              ─────────────────
///   start()      ── call_offer ──►      incoming: their screen rings
///                ◄── call_ringing ──
///                ◄── call_answer ──     accept()
///   both swap call_ice (network addresses) until the line is up
///   hangUp()     ── call_end ──►        the call ends on both phones
///
/// The microphone, camera and network live behind [CallMedia], so every
/// step here can be tested without a phone. The real one is
/// WebRtcCallMedia.
class CallService extends ChangeNotifier {
  CallService({
    required Stream<Map<String, dynamic>> events,
    required bool Function(Map<String, dynamic>) send,
    required CallMedia Function() media,
    required Future<({List<Map<String, dynamic>> servers, bool relay})>
        Function()
        iceServers,
    this.ringFor = const Duration(seconds: 45),
    this.connectFor = const Duration(seconds: 25),
    this.reconnectFor = const Duration(seconds: 12),
    this.endedFor = const Duration(milliseconds: 1800),
  })  : _send = send,
        _newMedia = media,
        _iceServers = iceServers {
    _sub = events.listen(_onEvent);
  }

  final bool Function(Map<String, dynamic>) _send;
  final CallMedia Function() _newMedia;
  final Future<({List<Map<String, dynamic>> servers, bool relay})> Function()
      _iceServers;
  StreamSubscription<Map<String, dynamic>>? _sub;

  /// How long a call rings before it counts as unanswered.
  final Duration ringFor;

  /// How long picking up may take to become a working line.
  final Duration connectFor;

  /// How long a line that dropped mid-call gets to come back.
  final Duration reconnectFor;

  /// How long the "Call ended" screen stays before it closes.
  final Duration endedFor;

  CallPhase _phase = CallPhase.idle;
  CallPhase get phase => _phase;

  /// Something is happening: ringing, connecting, talking, or just ended.
  bool get active => _phase != CallPhase.idle;

  /// On a call or about to be: a second call gets "busy".
  bool get busy => _phase != CallPhase.idle && _phase != CallPhase.ended;

  CallPeer? _peer;
  CallPeer? get peer => _peer;

  String? _callId;
  bool _video = false;
  bool get video => _video;

  bool _muted = false;
  bool get muted => _muted;
  bool _cameraOn = true;
  bool get cameraOn => _cameraOn;
  bool _speaker = false;
  bool get speaker => _speaker;

  /// The line dropped and is trying to come back.
  bool _reconnecting = false;
  bool get reconnecting => _reconnecting;

  /// Whether the server has a relay for networks that block direct calls.
  bool _relay = false;

  DateTime? _connectedAt;
  DateTime? get connectedAt => _connectedAt;

  CallEnd? _ended;
  CallEnd? get ended => _ended;

  /// How long the call has been connected.
  Duration get talked => _connectedAt == null
      ? Duration.zero
      : DateTime.now().difference(_connectedAt!);

  CallMedia? _media;
  CallMedia? get media => _media;

  String? _offerSdp;
  bool _remoteSet = false;
  bool _described = false;
  final List<Map<String, dynamic>> _theirAddresses = [];
  final List<Map<String, dynamic>> _ourAddresses = [];
  Timer? _timer;

  // ───────────────────────────── calling ─────────────────────────────

  /// Rings [to]. Nothing happens when already on a call.
  Future<void> start(CallPeer to, {required bool video}) async {
    if (busy) return;
    _begin(to, video: video, id: const Uuid().v4());
    _set(CallPhase.calling);
    final media = await _openMedia();
    if (media == null) return;
    final String sdp;
    try {
      sdp = await media.createOffer();
    } catch (e) {
      debugPrint('[call] could not describe this phone for the call: $e');
      if (_media == media) _finish(CallEnd.failed);
      return;
    }
    if (_media != media || _phase != CallPhase.calling) return;
    if (!_signal('call_offer', {
      'video': video,
      'sdp': sdp,
      'sdpType': 'offer',
    })) {
      _finish(CallEnd.offline);
      return;
    }
    _describedNow();
    _timer = Timer(ringFor, () {
      if (_phase == CallPhase.calling || _phase == CallPhase.ringing) {
        _finish(CallEnd.noAnswer, tell: 'missed');
      }
    });
  }

  /// Picks up a ringing call.
  Future<void> accept() async {
    if (_phase != CallPhase.incoming) return;
    _timer?.cancel();
    _set(CallPhase.connecting);
    final media = await _openMedia();
    if (media == null) return;
    final String sdp;
    try {
      sdp = await media.createAnswer(_offerSdp ?? '');
    } catch (e) {
      debugPrint('[call] could not answer the call: $e');
      if (_media == media) _finish(CallEnd.failed, tell: 'failed');
      return;
    }
    if (_media != media || _phase != CallPhase.connecting) return;
    await _remoteDescribed();
    if (!_signal('call_answer', {'sdp': sdp, 'sdpType': 'answer'})) {
      _finish(CallEnd.offline);
      return;
    }
    _describedNow();
    _waitForLine();
  }

  /// Turns down a ringing call.
  void decline() {
    if (_phase != CallPhase.incoming) return;
    _signal('call_decline');
    _finish(CallEnd.declinedByMe);
  }

  /// Ends the call, whatever stage it is at.
  void hangUp() {
    switch (_phase) {
      case CallPhase.incoming:
        decline();
      case CallPhase.calling:
      case CallPhase.ringing:
        // Nobody picked up: they get a missed call.
        _finish(CallEnd.cancelled, tell: 'missed');
      case CallPhase.connecting:
      case CallPhase.connected:
        _finish(CallEnd.hungUp, tell: 'hangup');
      case CallPhase.idle:
      case CallPhase.ended:
        break;
    }
  }

  void toggleMute() {
    _muted = !_muted;
    _media?.setMuted(_muted);
    notifyListeners();
  }

  void toggleCamera() {
    if (!_video) return;
    _cameraOn = !_cameraOn;
    _media?.setCameraOn(_cameraOn);
    notifyListeners();
  }

  void toggleSpeaker() {
    _speaker = !_speaker;
    // ignore: discarded_futures
    _media?.setSpeaker(_speaker);
    notifyListeners();
  }

  Future<void> switchCamera() async {
    if (!_video) return;
    await _media?.switchCamera();
  }

  // ─────────────────────────── what arrives ──────────────────────────

  void _onEvent(Map<String, dynamic> ev) {
    final type = ev['type'];
    if (type is! String || !type.startsWith('call_')) return;
    if (type == 'call_offer') {
      _incoming(ev);
      return;
    }
    // Everything else belongs to one call, and only the current one counts.
    if (ev['callId'] != _callId || _callId == null) return;
    switch (type) {
      case 'call_ringing':
        if (_phase == CallPhase.calling) _set(CallPhase.ringing);
      case 'call_answer':
        // ignore: discarded_futures
        _answered(ev['sdp'] as String? ?? '');
      case 'call_ice':
        // ignore: discarded_futures
        _theirAddress(ev);
      case 'call_decline':
        if (busy) _finish(CallEnd.declined);
      case 'call_busy':
        if (busy) _finish(CallEnd.busy);
      case 'call_unavailable':
        if (busy) _finish(CallEnd.unavailable);
      case 'call_end':
        if (_phase == CallPhase.incoming) {
          _finish(CallEnd.missed);
        } else if (busy) {
          _finish(ev['reason'] == 'failed' ? CallEnd.failed : CallEnd.hungUp);
        }
    }
  }

  void _incoming(Map<String, dynamic> ev) {
    final from = ev['from'] as String? ?? '';
    final id = ev['callId'] as String? ?? '';
    if (from.isEmpty || id.isEmpty) return;
    if (busy) {
      // Already on a call. Said to the caller so they are not left ringing.
      _send({'type': 'call_busy', 'to': from, 'callId': id});
      return;
    }
    _begin(
      CallPeer(id: from, username: ev['fromUsername'] as String? ?? ''),
      video: ev['video'] == true,
      id: id,
    );
    _offerSdp = ev['sdp'] as String? ?? '';
    _set(CallPhase.incoming);
    _signal('call_ringing');
    _timer = Timer(ringFor, () {
      if (_phase == CallPhase.incoming) _finish(CallEnd.missed);
    });
  }

  Future<void> _answered(String sdp) async {
    if (_phase != CallPhase.calling && _phase != CallPhase.ringing) return;
    _timer?.cancel();
    _set(CallPhase.connecting);
    final media = _media;
    if (media == null) return;
    try {
      await media.acceptAnswer(sdp);
    } catch (e) {
      debugPrint('[call] could not use their answer: $e');
      if (_media == media) _finish(CallEnd.failed, tell: 'failed');
      return;
    }
    if (_media != media) return;
    await _remoteDescribed();
    _waitForLine();
  }

  /// One of their network addresses. Kept until this phone knows what the
  /// other is sending, because an address cannot be used before that.
  Future<void> _theirAddress(Map<String, dynamic> ev) async {
    final address = {
      'candidate': ev['candidate'],
      'sdpMid': ev['sdpMid'],
      'sdpMLineIndex': ev['sdpMLineIndex'],
    };
    final media = _media;
    if (!_remoteSet || media == null) {
      _theirAddresses.add(address);
      return;
    }
    await _addAddress(media, address);
  }

  Future<void> _addAddress(CallMedia media, Map<String, dynamic> a) async {
    try {
      await media.addCandidate(a);
    } catch (e) {
      // One unusable address is normal: there are usually several.
      debugPrint('[call] skipped one of their network addresses: $e');
    }
  }

  // ───────────────────────────── the line ────────────────────────────

  void _onLink(CallLink link) {
    if (!busy) return;
    switch (link) {
      case CallLink.up:
        _timer?.cancel();
        _reconnecting = false;
        _connectedAt ??= DateTime.now();
        _set(CallPhase.connected);
      case CallLink.lost:
        if (_phase != CallPhase.connected) return;
        _reconnecting = true;
        notifyListeners();
        _timer?.cancel();
        _timer = Timer(reconnectFor, () {
          if (_reconnecting) _finish(CallEnd.failed, tell: 'failed');
        });
      case CallLink.failed:
        _finish(CallEnd.failed, tell: 'failed');
    }
  }

  void _waitForLine() {
    _timer?.cancel();
    _timer = Timer(connectFor, () {
      if (_phase == CallPhase.connecting) {
        _finish(CallEnd.failed, tell: 'failed');
      }
    });
  }

  // ──────────────────────────── plumbing ─────────────────────────────

  void _begin(CallPeer to, {required bool video, required String id}) {
    _timer?.cancel();
    _peer = to;
    _callId = id;
    _video = video;
    _muted = false;
    _cameraOn = true;
    // Video calls are held away from the ear; audio calls to it.
    _speaker = video;
    _reconnecting = false;
    _connectedAt = null;
    _ended = null;
    _offerSdp = null;
    _remoteSet = false;
    _described = false;
    _theirAddresses.clear();
    _ourAddresses.clear();
  }

  /// Opens the microphone (and camera) and gets ready to connect. Null, with
  /// the call ended, when that is refused or fails.
  Future<CallMedia?> _openMedia() async {
    final media = _newMedia();
    _media = media;
    try {
      await media.open(video: _video);
    } on CallMediaDenied {
      if (_media == media) {
        _finish(CallEnd.noPermission,
            tell: _phase == CallPhase.connecting ? 'failed' : null);
      }
      return null;
    } catch (e) {
      debugPrint('[call] could not open the microphone or camera: $e');
      if (_media == media) {
        _finish(CallEnd.failed,
            tell: _phase == CallPhase.connecting ? 'failed' : null);
      }
      return null;
    }
    if (_media != media) return null; // hung up while it opened
    final ice = await _iceServers();
    _relay = ice.relay;
    if (_media != media) return null;
    try {
      await media.connect(
        ice.servers,
        onCandidate: _ourAddress,
        onLink: _onLink,
      );
    } catch (e) {
      debugPrint('[call] could not set up the connection: $e');
      if (_media == media) _finish(CallEnd.failed);
      return null;
    }
    await media.setSpeaker(_speaker);
    return _media == media ? media : null;
  }

  /// One of this phone's network addresses. Held until the other phone has
  /// heard about the call: sent before that, it would arrive for a call
  /// they do not know about yet and be dropped.
  void _ourAddress(Map<String, dynamic> address) {
    if (!_described) {
      _ourAddresses.add(address);
      return;
    }
    _signal('call_ice', address);
  }

  void _describedNow() {
    _described = true;
    for (final a in _ourAddresses) {
      _signal('call_ice', a);
    }
    _ourAddresses.clear();
  }

  Future<void> _remoteDescribed() async {
    _remoteSet = true;
    final media = _media;
    if (media == null) return;
    final queued = List.of(_theirAddresses);
    _theirAddresses.clear();
    for (final a in queued) {
      await _addAddress(media, a);
    }
  }

  bool _signal(String type, [Map<String, dynamic> extra = const {}]) {
    final peer = _peer;
    final id = _callId;
    if (peer == null || id == null) return false;
    return _send({'type': type, 'to': peer.id, 'callId': id, ...extra});
  }

  void _set(CallPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  /// Ends the call here, telling the other phone [tell] as the reason when
  /// given, and leaves "Call ended" up for [endedFor].
  void _finish(CallEnd why, {String? tell}) {
    if (_phase == CallPhase.idle || _phase == CallPhase.ended) return;
    if (tell != null) _signal('call_end', {'reason': tell});
    _timer?.cancel();
    final media = _media;
    _media = null;
    // ignore: discarded_futures
    media?.close();
    _reconnecting = false;
    _ended = why;
    _set(CallPhase.ended);
    _timer = Timer(endedFor, () {
      if (_phase != CallPhase.ended) return;
      _callId = null;
      _set(CallPhase.idle);
    });
  }

  /// What the screen says about how the call ended.
  String endedLabel() {
    final name = _peer?.username ?? '';
    final took = _connectedAt == null ? '' : ' · ${formatTalked(talked)}';
    switch (_ended) {
      case CallEnd.hungUp:
        return 'Call ended$took';
      case CallEnd.cancelled:
        return 'Call cancelled';
      case CallEnd.declined:
        return '$name declined';
      case CallEnd.declinedByMe:
        return 'Call declined';
      case CallEnd.busy:
        return '$name is on another call';
      case CallEnd.unavailable:
        return '$name is not available right now';
      case CallEnd.noAnswer:
        return 'No answer';
      case CallEnd.missed:
        return 'Missed call';
      case CallEnd.offline:
        return "You're offline";
      case CallEnd.noPermission:
        return _video
            ? 'Allow the camera and microphone to call'
            : 'Allow the microphone to call';
      case CallEnd.failed:
        return _relay
            ? "Couldn't connect the call"
            : "Couldn't connect. One of your networks may be blocking calls";
      case null:
        return 'Call ended';
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    // ignore: discarded_futures
    _sub?.cancel();
    final media = _media;
    _media = null;
    // ignore: discarded_futures
    media?.close();
    super.dispose();
  }
}

/// "0:07", "12:40", "1:02:09".
String formatTalked(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

enum CallPhase {
  idle,

  /// This phone is calling; the other has not said it is ringing yet.
  calling,

  /// It is ringing on their screen.
  ringing,

  /// Somebody is calling this phone.
  incoming,

  /// Picked up; the two phones are finding each other.
  connecting,

  /// Talking.
  connected,

  /// Over; "Call ended" is on screen for a moment.
  ended,
}

enum CallEnd {
  hungUp,
  cancelled,
  declined,
  declinedByMe,
  busy,
  unavailable,
  noAnswer,
  missed,
  offline,
  noPermission,
  failed,
}

/// The state of the direct line between the two phones.
enum CallLink { up, lost, failed }

class CallPeer {
  final String id;
  final String username;
  const CallPeer({required this.id, required this.username});
}

/// The microphone or camera was refused.
class CallMediaDenied implements Exception {
  const CallMediaDenied();
}

/// The phone's side of a call: microphone, camera, and the direct line.
abstract class CallMedia {
  /// Opens the microphone, and the camera when [video]. Throws
  /// [CallMediaDenied] when either is refused.
  Future<void> open({required bool video});

  /// Gets ready to connect, through [iceServers].
  Future<void> connect(
    List<Map<String, dynamic>> iceServers, {
    required void Function(Map<String, dynamic> address) onCandidate,
    required void Function(CallLink link) onLink,
  });

  /// This phone's description, to start a call.
  Future<String> createOffer();

  /// This phone's description in answer to [offer].
  Future<String> createAnswer(String offer);

  /// Uses the other phone's answer.
  Future<void> acceptAnswer(String answer);

  /// One of the other phone's network addresses.
  Future<void> addCandidate(Map<String, dynamic> address);

  void setMuted(bool muted);
  void setCameraOn(bool on);
  Future<void> switchCamera();
  Future<void> setSpeaker(bool on);

  /// Whether the other phone's picture has arrived.
  ValueListenable<bool> get remoteVideo;

  Widget localView();
  Widget remoteView();

  Future<void> close();
}
