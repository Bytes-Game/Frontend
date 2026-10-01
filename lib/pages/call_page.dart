import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/services/call_service.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// The call screen.
///
///   * Ringing: their picture in the middle with rings rippling out of it,
///     over a slowly drifting glow. On a video call, your own camera fills
///     the screen behind, the way it does on FaceTime.
///   * Somebody calling you: Decline and Accept, the Accept button gently
///     bobbing.
///   * Talking: on a video call they fill the screen and you sit in a small
///     window you can drag to any corner (double-tap it to flip camera).
///     The buttons hide after a few seconds; tap to bring them back.
///   * The buttons sit on frosted glass: speaker, camera, mute, flip, end.
///
/// The screen closes itself when the call is over.
class CallPage extends StatefulWidget {
  final CallService call;
  const CallPage({super.key, required this.call});

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> with TickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();
  Timer? _clock;
  Timer? _hide;
  bool _controls = true;
  bool _popped = false;

  /// Where your own picture sits during a video call.
  Alignment _corner = Alignment.topRight;
  Offset? _dragAt;

  CallService get call => widget.call;

  @override
  void initState() {
    super.initState();
    call.addListener(_changed);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && call.phase == CallPhase.connected) setState(() {});
    });
  }

  @override
  void dispose() {
    call.removeListener(_changed);
    _drift.dispose();
    _pulse.dispose();
    _clock?.cancel();
    _hide?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (call.phase == CallPhase.idle) {
      if (!_popped) {
        _popped = true;
        // pop, not maybePop: maybePop asks the back-button guard below,
        // which was built while the call was still on and would say no —
        // and the screen stayed up after every call.
        final route = ModalRoute.of(context);
        final nav = Navigator.of(context);
        if (route == null) return;
        if (route.isCurrent) {
          nav.pop();
        } else {
          nav.removeRoute(route);
        }
      }
      return;
    }
    if (call.phase == CallPhase.connected && call.video) _scheduleHide();
    setState(() {});
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted && call.phase == CallPhase.connected && call.video) {
        setState(() => _controls = false);
      }
    });
  }

  void _tapScreen() {
    setState(() => _controls = true);
    if (call.phase == CallPhase.connected && call.video) _scheduleHide();
  }

  String get _status {
    if (call.reconnecting) return 'Reconnecting…';
    switch (call.phase) {
      case CallPhase.calling:
        return 'Calling…';
      case CallPhase.ringing:
        return 'Ringing…';
      case CallPhase.incoming:
        return call.video ? 'Incoming video call' : 'Incoming call';
      case CallPhase.connecting:
        return 'Connecting…';
      case CallPhase.connected:
        return formatTalked(call.talked);
      case CallPhase.ended:
        return call.endedLabel();
      case CallPhase.idle:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = call.media;
    final phase = call.phase;
    final name = call.peer?.username ?? '';
    final ringing = phase == CallPhase.calling ||
        phase == CallPhase.ringing ||
        phase == CallPhase.incoming;

    return PopScope(
      // Back does not end a call by accident: the red button does.
      canPop: phase == CallPhase.idle,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _tapScreen,
            child: ValueListenableBuilder<bool>(
              valueListenable: media?.remoteVideo ?? _noVideo,
              builder: (context, theirPicture, _) {
                final showThem = call.video &&
                    theirPicture &&
                    media != null &&
                    phase == CallPhase.connected;
                final showMeBig = call.video &&
                    media != null &&
                    call.cameraOn &&
                    !showThem &&
                    phase != CallPhase.ended;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    _Backdrop(drift: _drift, name: name),
                    if (showThem)
                      KeyedSubtree(
                        key: const ValueKey('their_video'),
                        child: media.remoteView(),
                      ),
                    if (showMeBig) ...[
                      KeyedSubtree(
                        key: const ValueKey('my_video_full'),
                        child: media.localView(),
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0x99000000),
                              Color(0x22000000),
                              Color(0xAA000000),
                            ],
                          ),
                        ),
                      ),
                    ],
                    if (!showThem)
                      _Who(
                        name: name,
                        status: _status,
                        pulse: _pulse,
                        ringing: ringing,
                        ended: phase == CallPhase.ended,
                      ),
                    if (showThem) ...[
                      _TopShade(visible: _controls),
                      _TalkingHeader(
                        name: name,
                        status: _status,
                        visible: _controls,
                      ),
                      _myWindow(media),
                    ],
                    _encryptedNote(),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: AnimatedSlide(
                        offset: _controls || !showThem
                            ? Offset.zero
                            : const Offset(0, 1.2),
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        child: AnimatedOpacity(
                          opacity: phase == CallPhase.ended ? 0 : 1,
                          duration: const Duration(milliseconds: 220),
                          child: SafeArea(
                            top: false,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  20, 0, 20, 22),
                              child: phase == CallPhase.incoming
                                  ? _IncomingButtons(call: call)
                                  : _CallButtons(call: call),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  static final _noVideo = ValueNotifier<bool>(false);

  Widget _encryptedNote() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: AnimatedOpacity(
          opacity: _controls ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_rounded,
                    size: 12, color: Colors.white.withValues(alpha: 0.6)),
                const SizedBox(width: 5),
                Text(
                  'End-to-end encrypted',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Your own picture in a small window, dragged to whichever corner it is
  /// let go nearest.
  Widget _myWindow(CallMedia media) {
    const w = 104.0, h = 152.0;
    final size = MediaQuery.of(context).size;
    final pad = MediaQuery.of(context).padding;
    final drag = _dragAt;
    final Widget window = GestureDetector(
      key: const ValueKey('my_window'),
      onDoubleTap: call.switchCamera,
      onPanUpdate: (d) {
        final start = drag ??
            Offset(
              _corner.x < 0 ? 16 : size.width - w - 16,
              _corner.y < 0 ? pad.top + 56 : size.height - h - 150,
            );
        setState(() => _dragAt = start + d.delta);
      },
      onPanEnd: (_) {
        final at = _dragAt;
        if (at == null) return;
        setState(() {
          _corner = Alignment(
            at.dx + w / 2 < size.width / 2 ? -1 : 1,
            at.dy + h / 2 < size.height / 2 ? -1 : 1,
          );
          _dragAt = null;
        });
      },
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
          boxShadow: const [
            BoxShadow(color: Color(0x80000000), blurRadius: 24, offset: Offset(0, 10)),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: call.cameraOn
            ? media.localView()
            : Container(
                color: const Color(0xFF1C1C1E),
                alignment: Alignment.center,
                child: const Icon(Icons.videocam_off_rounded,
                    color: Colors.white54),
              ),
      ),
    );
    if (drag != null) {
      return Positioned(left: drag.dx, top: drag.dy, child: window);
    }
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutBack,
      left: _corner.x < 0 ? 16 : size.width - w - 16,
      top: _corner.y < 0 ? pad.top + 56 : size.height - h - 150,
      child: window,
    );
  }
}

/// A slowly drifting glow behind everything: two soft lights orbiting in
/// the dark, tinted by who is on the call.
class _Backdrop extends StatelessWidget {
  final Animation<double> drift;
  final String name;
  const _Backdrop({required this.drift, required this.name});

  static const _tints = [
    Color(0xFF0A84FF),
    Color(0xFF5E5CE6),
    Color(0xFF30D158),
    Color(0xFFFF375F),
    Color(0xFF64D2FF),
    Color(0xFFFF9F0A),
  ];

  @override
  Widget build(BuildContext context) {
    final seed = name.codeUnits.fold<int>(0, (a, c) => a + c);
    final a = _tints[seed % _tints.length];
    final b = _tints[(seed + 2) % _tints.length];
    return AnimatedBuilder(
      animation: drift,
      builder: (_, _) {
        final t = drift.value * 2 * math.pi;
        return DecoratedBox(
          decoration: const BoxDecoration(color: Color(0xFF050507)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _glow(a, Alignment(0.7 * math.cos(t), -0.5 + 0.35 * math.sin(t))),
              _glow(b, Alignment(-0.7 * math.cos(t + 1.7), 0.55 + 0.3 * math.sin(t * 1.3))),
            ],
          ),
        );
      },
    );
  }

  Widget _glow(Color c, Alignment at) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: at,
            radius: 0.95,
            colors: [c.withValues(alpha: 0.42), c.withValues(alpha: 0)],
          ),
        ),
      );
}

/// Their picture, name and what is happening, in the middle of the screen.
class _Who extends StatelessWidget {
  final String name;
  final String status;
  final Animation<double> pulse;
  final bool ringing;
  final bool ended;

  const _Who({
    required this.name,
    required this.status,
    required this.pulse,
    required this.ringing,
    required this.ended,
  });

  @override
  Widget build(BuildContext context) {
    const size = 128.0;
    return SafeArea(
      child: Align(
        alignment: const Alignment(0, -0.42),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: size * 2.2,
              height: size * 2.2,
              child: AnimatedBuilder(
                animation: pulse,
                builder: (_, child) {
                  final v = pulse.value;
                  // Floats a little, as if held up on the screen.
                  final float = math.sin(v * 2 * math.pi) * 4;
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      if (ringing)
                        for (var i = 0; i < 3; i++) _ripple((v + i / 3) % 1, size),
                      Transform.translate(
                        offset: Offset(0, ringing ? float : 0),
                        child: child,
                      ),
                    ],
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.primary.withValues(alpha: 0.35),
                        blurRadius: 40,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: ArenaAvatar(name: name, size: size),
                ),
              ),
            ),
            Text(
              name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: Text(
                status,
                key: ValueKey(status.contains(':') ? 'clock' : status),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: ended
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.72),
                  fontSize: 16,
                  fontWeight: ended ? FontWeight.w600 : FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ripple(double v, double size) {
    return Opacity(
      opacity: (1 - v) * 0.5,
      child: Container(
        width: size * (1 + v * 1.1),
        height: size * (1 + v * 1.1),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.8),
            width: 1.5,
          ),
        ),
      ),
    );
  }
}

class _TopShade extends StatelessWidget {
  final bool visible;
  const _TopShade({required this.visible});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        child: const Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: 160,
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Name and time at the top while they fill the screen.
class _TalkingHeader extends StatelessWidget {
  final String name;
  final String status;
  final bool visible;
  const _TalkingHeader({
    required this.name,
    required this.status,
    required this.visible,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 220),
          child: Padding(
            padding: const EdgeInsets.only(top: 30),
            child: Column(
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 14,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Frosted glass behind the buttons.
class _Glass extends StatelessWidget {
  final Widget child;
  const _Glass({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(34),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(34),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _CallButtons extends StatelessWidget {
  final CallService call;
  const _CallButtons({required this.call});

  @override
  Widget build(BuildContext context) {
    return _Glass(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _RoundButton(
            icon: call.speaker ? Icons.volume_up_rounded : Icons.volume_down_rounded,
            label: 'Speaker',
            on: call.speaker,
            onTap: call.toggleSpeaker,
          ),
          if (call.video)
            _RoundButton(
              icon: call.cameraOn
                  ? Icons.videocam_rounded
                  : Icons.videocam_off_rounded,
              label: 'Camera',
              on: !call.cameraOn,
              onTap: call.toggleCamera,
            ),
          _RoundButton(
            icon: call.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: call.muted ? 'Unmute' : 'Mute',
            on: call.muted,
            onTap: call.toggleMute,
          ),
          if (call.video)
            _RoundButton(
              icon: Icons.cameraswitch_rounded,
              label: 'Flip',
              onTap: call.switchCamera,
            ),
          _RoundButton(
            icon: Icons.call_end_rounded,
            label: 'End',
            color: AppTheme.error,
            onTap: call.hangUp,
          ),
        ],
      ),
    );
  }
}

class _IncomingButtons extends StatefulWidget {
  final CallService call;
  const _IncomingButtons({required this.call});

  @override
  State<_IncomingButtons> createState() => _IncomingButtonsState();
}

class _IncomingButtonsState extends State<_IncomingButtons>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 26),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _RoundButton(
            icon: Icons.call_end_rounded,
            label: 'Decline',
            color: AppTheme.error,
            size: 74,
            onTap: call.decline,
          ),
          AnimatedBuilder(
            animation: _bob,
            builder: (_, child) => Transform.translate(
              offset: Offset(0, -6 * Curves.easeInOut.transform(_bob.value)),
              child: child,
            ),
            child: _RoundButton(
              icon: call.video ? Icons.videocam_rounded : Icons.call_rounded,
              label: 'Accept',
              color: AppTheme.success,
              size: 74,
              glow: true,
              onTap: call.accept,
            ),
          ),
        ],
      ),
    );
  }
}

/// A round call button with its name under it. [on] fills it white, the
/// way a switched-on control looks on an iPhone call.
class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool on;
  final Color? color;
  final double size;
  final bool glow;

  const _RoundButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.on = false,
    this.color,
    this.size = 58,
    this.glow = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (on ? Colors.white : Colors.white.withValues(alpha: 0.16));
    final fg = color != null ? Colors.white : (on ? Colors.black : Colors.white);
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Pressable(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: bg,
                  boxShadow: [
                    if (glow)
                      BoxShadow(
                        color: bg.withValues(alpha: 0.55),
                        blurRadius: 28,
                        spreadRadius: 2,
                      ),
                  ],
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: fg, size: size * 0.44),
              ),
              const SizedBox(height: 7),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
