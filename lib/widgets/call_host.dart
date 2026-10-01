import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'package:myapp/pages/call_page.dart';
import 'package:myapp/services/call_service.dart';
import 'package:myapp/services/video_player_service.dart';

/// Puts the call screen up whenever there is a call, wherever the person
/// is in the app: a call they start from a chat, and a call that rings
/// while they are watching reels.
///
/// It also does what a call needs from the rest of the app: the reel
/// playing underneath stops (and starts again afterwards if it was
/// playing), the phone rings and buzzes for an incoming call, and the
/// caller hears it ringing.
class CallHost extends StatefulWidget {
  final CallService call;
  final GlobalKey<NavigatorState> navigator;
  final CallSounds sounds;
  final Widget child;

  const CallHost({
    super.key,
    required this.call,
    required this.navigator,
    required this.sounds,
    required this.child,
  });

  @override
  State<CallHost> createState() => _CallHostState();
}

class _CallHostState extends State<CallHost> {
  bool _showing = false;
  bool _feedWasPlaying = false;
  CallPhase _last = CallPhase.idle;
  Timer? _buzz;

  @override
  void initState() {
    super.initState();
    widget.call.addListener(_changed);
  }

  @override
  void dispose() {
    widget.call.removeListener(_changed);
    _buzz?.cancel();
    // ignore: discarded_futures
    widget.sounds.stop();
    super.dispose();
  }

  void _changed() {
    final phase = widget.call.phase;
    if (phase == _last) return;
    final was = _last;
    _last = phase;

    if (was == CallPhase.idle) {
      // A call is starting: the reel underneath goes quiet.
      _feedWasPlaying = VideoPlayerService.instance.activeIsPlaying;
      VideoPlayerService.instance.pauseAll();
      _show();
    }
    _sound(phase);
    if (phase == CallPhase.idle && _feedWasPlaying) {
      _feedWasPlaying = false;
      // ignore: discarded_futures
      VideoPlayerService.instance.resumeActive();
    }
  }

  void _sound(CallPhase phase) {
    _buzz?.cancel();
    _buzz = null;
    switch (phase) {
      case CallPhase.incoming:
        // ignore: discarded_futures
        widget.sounds.ring();
        HapticFeedback.heavyImpact();
        _buzz = Timer.periodic(const Duration(milliseconds: 1400), (_) {
          HapticFeedback.heavyImpact();
        });
      case CallPhase.ringing:
        // ignore: discarded_futures
        widget.sounds.ringback();
      case CallPhase.calling:
        break; // quiet until it really rings at their end
      default:
        // ignore: discarded_futures
        widget.sounds.stop();
    }
  }

  void _show() {
    if (_showing) return;
    final nav = widget.navigator.currentState;
    if (nav == null) return;
    _showing = true;
    nav
        .push(
          PageRouteBuilder<void>(
            opaque: true,
            transitionDuration: const Duration(milliseconds: 420),
            reverseTransitionDuration: const Duration(milliseconds: 280),
            pageBuilder: (_, _, _) => CallPage(call: widget.call),
            transitionsBuilder: (_, anim, _, child) {
              final curved = CurvedAnimation(
                parent: anim,
                curve: Curves.easeOutCubic,
              );
              return FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween(begin: 1.08, end: 1.0).animate(curved),
                  child: child,
                ),
              );
            },
          ),
        )
        .then((_) => _showing = false);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The ring for an incoming call and the tone the caller hears.
abstract class CallSounds {
  Future<void> ring();
  Future<void> ringback();
  Future<void> stop();
}

/// The two sounds in assets/sounds, played on a loop.
class AssetCallSounds implements CallSounds {
  VideoPlayerController? _player;
  String? _playing;

  Future<void> _play(String asset, double volume) async {
    if (_playing == asset) return;
    await stop();
    _playing = asset;
    final player = VideoPlayerController.asset(
      asset,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _player = player;
    try {
      await player.initialize();
      if (_player != player) return;
      await player.setLooping(true);
      await player.setVolume(volume);
      await player.play();
    } catch (e) {
      debugPrint('[call] could not play $asset: $e');
    }
  }

  @override
  Future<void> ring() => _play('assets/sounds/ring.wav', 1.0);

  @override
  Future<void> ringback() => _play('assets/sounds/ringback.wav', 0.6);

  @override
  Future<void> stop() async {
    final player = _player;
    _player = null;
    _playing = null;
    if (player == null) return;
    try {
      await player.pause();
      await player.dispose();
    } catch (e) {
      debugPrint('[call] could not stop the ring: $e');
    }
  }
}
