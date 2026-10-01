import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:myapp/services/call_service.dart';

/// The real microphone, camera and direct line for a call, through WebRTC.
///
/// Everything this does is a call into the phone itself, so it is the one
/// part of calling the tests cannot run; CallService, which decides what to
/// do and when, is tested with a stand-in for this.
class WebRtcCallMedia implements CallMedia {
  RTCPeerConnection? _pc;
  MediaStream? _local;
  final _localView = RTCVideoRenderer();
  final _remoteView = RTCVideoRenderer();
  bool _viewsReady = false;
  bool _video = false;
  bool _closed = false;
  final _remoteVideo = ValueNotifier<bool>(false);

  @override
  ValueListenable<bool> get remoteVideo => _remoteVideo;

  @override
  Future<void> open({required bool video}) async {
    _video = video;
    final asked = [Permission.microphone, if (video) Permission.camera];
    final answers = await asked.request();
    if (answers.values.any((s) => !s.isGranted)) {
      throw const CallMediaDenied();
    }
    await _localView.initialize();
    await _remoteView.initialize();
    _viewsReady = true;
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
              'frameRate': {'ideal': 30},
            }
          : false,
    });
    _localView.srcObject = _local;
  }

  @override
  Future<void> connect(
    List<Map<String, dynamic>> iceServers, {
    required void Function(Map<String, dynamic> address) onCandidate,
    required void Function(CallLink link) onLink,
  }) async {
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    final local = _local;
    if (local != null) {
      for (final track in local.getTracks()) {
        await pc.addTrack(track, local);
      }
    }
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      onCandidate({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
    pc.onTrack = (e) {
      if (e.streams.isNotEmpty) _remoteView.srcObject = e.streams.first;
      if (e.track.kind == 'video') _remoteVideo.value = true;
    };
    pc.onIceConnectionState = (state) {
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          onLink(CallLink.up);
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          onLink(CallLink.lost);
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          onLink(CallLink.failed);
        default:
          break;
      }
    };
  }

  RTCPeerConnection get _line {
    final pc = _pc;
    if (pc == null) throw StateError('the call line is not set up');
    return pc;
  }

  @override
  Future<String> createOffer() async {
    final offer = await _line.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': _video,
    });
    await _line.setLocalDescription(offer);
    return offer.sdp ?? '';
  }

  @override
  Future<String> createAnswer(String offer) async {
    await _line.setRemoteDescription(RTCSessionDescription(offer, 'offer'));
    final answer = await _line.createAnswer();
    await _line.setLocalDescription(answer);
    return answer.sdp ?? '';
  }

  @override
  Future<void> acceptAnswer(String answer) =>
      _line.setRemoteDescription(RTCSessionDescription(answer, 'answer'));

  @override
  Future<void> addCandidate(Map<String, dynamic> a) => _line.addCandidate(
        RTCIceCandidate(
          a['candidate'] as String?,
          a['sdpMid'] as String?,
          (a['sdpMLineIndex'] as num?)?.toInt(),
        ),
      );

  @override
  void setMuted(bool muted) {
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
  }

  @override
  void setCameraOn(bool on) {
    for (final t in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = on;
    }
  }

  @override
  Future<void> switchCamera() async {
    final tracks = _local?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  @override
  Future<void> setSpeaker(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (e) {
      debugPrint('[call] could not switch the speaker: $e');
    }
  }

  @override
  Widget localView() => RTCVideoView(
        _localView,
        mirror: true,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      );

  @override
  Widget remoteView() => RTCVideoView(
        _remoteView,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      for (final t in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _local?.dispose();
      await _pc?.close();
      if (_viewsReady) {
        _localView.srcObject = null;
        _remoteView.srcObject = null;
        await _localView.dispose();
        await _remoteView.dispose();
      }
    } catch (e) {
      debugPrint('[call] closing the call left something open: $e');
    }
  }
}
