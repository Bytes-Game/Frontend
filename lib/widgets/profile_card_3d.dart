import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/battle_record_panel.dart'
    show LeagueEmblem, CountUp;
import 'package:myapp/widgets/league_badge.dart';

/// Shows [user]'s battle card floating over the screen, in 3D.
///
/// Opened by holding down on someone in Search. The card spins in, tilts as
/// the finger moves over it, and flips over when tapped: the front has the
/// league, rating and record; the back has the breakdown of their battles.
/// [onOpenProfile] is called after the card closes, from the "View profile"
/// button.
Future<void> showProfileCard3D(
  BuildContext context, {
  required UserModel user,
  VoidCallback? onOpenProfile,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      barrierLabel: 'Close ${user.username}\'s card',
      transitionDuration: const Duration(milliseconds: 520),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (ctx, anim, _) => ProfileCard3D(
        user: user,
        entrance: anim,
        onOpenProfile: onOpenProfile == null
            ? null
            : () {
                Navigator.of(ctx).pop();
                onOpenProfile();
              },
      ),
    ),
  );
}

/// The card itself. Public so a test can pump it on its own.
class ProfileCard3D extends StatefulWidget {
  final UserModel user;

  /// Drives the spin-in. Null shows the card already in place.
  final Animation<double>? entrance;
  final VoidCallback? onOpenProfile;

  const ProfileCard3D({
    super.key,
    required this.user,
    this.entrance,
    this.onOpenProfile,
  });

  @override
  State<ProfileCard3D> createState() => _ProfileCard3DState();
}

class _ProfileCard3DState extends State<ProfileCard3D>
    with TickerProviderStateMixin {
  BattleRecord? _record;

  // Tilt follows the finger; on release it springs back to flat.
  Offset _tilt = Offset.zero;
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  Offset _settleFrom = Offset.zero;

  // Tap flips the card over.
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  static const _maxTilt = 0.38;

  @override
  void initState() {
    super.initState();
    _settle.addListener(() {
      final t = Curves.elasticOut.transform(_settle.value);
      setState(() => _tilt = Offset.lerp(_settleFrom, Offset.zero, t)!);
    });
    _load();
  }

  Future<void> _load() async {
    final page = await ApiService.getUserBattles(
      userId: widget.user.id,
      tab: 'live',
      limit: 1,
    );
    if (mounted && page != null) setState(() => _record = page.record);
  }

  @override
  void dispose() {
    _settle.dispose();
    _flip.dispose();
    super.dispose();
  }

  BattleRecord get _shown =>
      _record ??
      BattleRecord(
        rating: widget.user.rating,
        league: widget.user.league,
        wins: widget.user.wins,
        losses: widget.user.losses,
        draws: widget.user.draws,
      );

  void _onDrag(DragUpdateDetails d, Size size) {
    _settle.stop();
    setState(() {
      _tilt = Offset(
        (_tilt.dx + d.delta.dy / size.height * 1.4).clamp(-_maxTilt, _maxTilt),
        (_tilt.dy - d.delta.dx / size.width * 1.4).clamp(-_maxTilt, _maxTilt),
      );
    });
  }

  void _onRelease() {
    _settleFrom = _tilt;
    _settle.forward(from: 0);
  }

  void _toggleFlip() {
    if (_flip.isAnimating) return;
    _flip.value < 0.5 ? _flip.forward() : _flip.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final cardW = math.min(size.width * 0.82, 340.0);
    final cardH = cardW * 1.38;
    final entrance = widget.entrance ?? const AlwaysStoppedAnimation(1.0);

    return Center(
      child: AnimatedBuilder(
        animation: Listenable.merge([entrance, _flip]),
        builder: (context, _) {
          final e = Curves.easeOutBack.transform(entrance.value.clamp(0, 1));
          final spin = (1 - entrance.value) * math.pi * 0.9;
          final flipAngle = _flip.value * math.pi;
          final showingBack = flipAngle > math.pi / 2;
          final m = Matrix4.identity()
            ..setEntry(3, 2, 0.0014)
            ..scaleByDouble(0.4 + 0.6 * e, 0.4 + 0.6 * e, 1.0, 1.0)
            ..rotateX(_tilt.dx)
            ..rotateY(_tilt.dy + spin + flipAngle);
          return Opacity(
            opacity: entrance.value.clamp(0.0, 1.0),
            child: Transform(
              alignment: Alignment.center,
              transform: m,
              child: GestureDetector(
                onPanUpdate: (d) => _onDrag(d, Size(cardW, cardH)),
                onPanEnd: (_) => _onRelease(),
                onTap: _toggleFlip,
                child: SizedBox(
                  width: cardW,
                  height: cardH,
                  child: showingBack
                      // The back is drawn mirrored so it reads the right way
                      // round once the card has turned over.
                      ? Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.rotationY(math.pi),
                          child: _Back(
                            user: widget.user,
                            record: _shown,
                            loaded: _record != null,
                          ),
                        )
                      : _Front(
                          user: widget.user,
                          record: _shown,
                          tilt: _tilt,
                          onOpenProfile: widget.onOpenProfile,
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  final String league;
  final Widget child;
  final Offset tilt;

  const _Shell({
    required this.league,
    required this.child,
    this.tilt = Offset.zero,
  });

  @override
  Widget build(BuildContext context) {
    final colors = LeagueBadge.gradientFor(league);
    // A sheen that slides across as the card tilts, like light on foil.
    final sheen = Alignment(-tilt.dy * 3, -tilt.dx * 3);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(colors.first, Colors.black, 0.35)!,
              Color.lerp(colors.last, Colors.black, 0.65)!,
            ],
          ),
          border: Border.all(
            color: colors.first.withValues(alpha: 0.8),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: colors.last.withValues(alpha: 0.5),
              blurRadius: 40,
              offset: Offset(tilt.dy * -40, 20 + tilt.dx * 40),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: sheen,
                      radius: 0.9,
                      colors: [
                        Colors.white.withValues(alpha: 0.22),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(padding: const EdgeInsets.all(20), child: child),
          ],
        ),
      ),
    );
  }
}

class _Front extends StatelessWidget {
  final UserModel user;
  final BattleRecord record;
  final Offset tilt;
  final VoidCallback? onOpenProfile;

  const _Front({
    required this.user,
    required this.record,
    required this.tilt,
    this.onOpenProfile,
  });

  @override
  Widget build(BuildContext context) {
    final step = LeagueStep.of(record.rating, decided: record.decided);
    const white = Colors.white;
    return _Shell(
      league: record.league,
      tilt: tilt,
      child: Column(
        children: [
          Row(
            children: [
              LeagueEmblem(league: record.league, size: 44),
              const SizedBox(width: 10),
              Text(
                record.league.toUpperCase(),
                style: const TextStyle(
                  color: white,
                  letterSpacing: 2.2,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.threed_rotation,
                color: Colors.white54,
                size: 18,
              ),
            ],
          ),
          const Spacer(),
          CircleAvatar(
            radius: 44,
            backgroundColor: white.withValues(alpha: 0.18),
            child: Text(
              user.username.isEmpty ? '?' : user.username[0].toUpperCase(),
              style: const TextStyle(
                color: white,
                fontSize: 38,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '@${user.username}',
            style: const TextStyle(
              color: white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              CountUp(
                value: record.rating,
                style: const TextStyle(
                  color: white,
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 6),
              const Text('rating', style: TextStyle(color: Colors.white70)),
            ],
          ),
          if (step.next != null && record.decided > 0)
            Text(
              '${step.pointsToNext} to ${step.next}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          const Spacer(),
          Row(
            children: [
              _Stat('Wins', record.wins, Colors.greenAccent),
              _Stat('Losses', record.losses, Colors.redAccent),
              _Stat('Draws', record.draws, Colors.white70),
            ],
          ),
          const SizedBox(height: 12),
          if (onOpenProfile != null)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: white,
                  foregroundColor: Colors.black,
                ),
                onPressed: onOpenProfile,
                child: const Text('View profile'),
              ),
            ),
          const SizedBox(height: 4),
          const Text(
            'Tap to flip · drag to tilt',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _Back extends StatelessWidget {
  final UserModel user;
  final BattleRecord record;
  final bool loaded;

  const _Back({required this.user, required this.record, required this.loaded});

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    final rate = record.decided == 0
        ? '–'
        : '${(record.winRate * 100).round()}%';
    final streak = record.streak > 1
        ? '${record.streak} ${record.streakOf == 'won' ? 'wins' : 'losses'} in a row'
        : 'No streak right now';
    Widget line(String label, int n) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          Text(
            '$n',
            style: const TextStyle(
              color: white,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
    return _Shell(
      league: record.league,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '@${user.username}\'s battles',
            style: const TextStyle(
              color: white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                rate,
                style: const TextStyle(
                  color: white,
                  fontSize: 40,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'of decided\nbattles won',
                style: TextStyle(color: Colors.white70, height: 1.2),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(streak, style: const TextStyle(color: white)),
          const Divider(color: Colors.white24, height: 28),
          if (!loaded)
            const Text(
              'Loading the full breakdown…',
              style: TextStyle(color: Colors.white54),
            )
          else ...[
            line('Open challenges', record.counts['open'] ?? 0),
            line('Live battles', record.counts['live'] ?? 0),
            line('Won', record.counts['won'] ?? record.wins),
            line('Lost', record.counts['lost'] ?? record.losses),
            line('Drawn', record.counts['draw'] ?? record.draws),
          ],
          const Spacer(),
          const Center(
            child: Text(
              'Tap to flip back',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _Stat(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          CountUp(
            value: value,
            style: TextStyle(
              color: color,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
