import 'package:flutter/material.dart';

/// Shimmer animation that sweeps a highlight across [child].
/// Used as a loading placeholder (skeleton screen).
class ShimmerLoading extends StatefulWidget {
  final Widget child;

  const ShimmerLoading({super.key, required this.child});

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? const Color(0xFF1E2028) : const Color(0xFFE8E8E8);
    final highlight =
        isDark ? const Color(0xFF2A2D38) : const Color(0xFFF5F5F5);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: [base, highlight, base],
              stops: const [0.0, 0.5, 1.0],
              begin: const Alignment(-1.0, -0.3),
              end: const Alignment(1.0, 0.3),
              transform: _SlidingGradientTransform(_controller.value),
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _SlidingGradientTransform extends GradientTransform {
  final double percent;
  const _SlidingGradientTransform(this.percent);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (percent * 2 - 1), 0, 0);
  }
}

/// A single skeleton placeholder bone.
class SkeletonBone extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;

  const SkeletonBone({
    super.key,
    this.width = double.infinity,
    required this.height,
    this.borderRadius = 8,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E2028) : const Color(0xFFE8E8E8),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// Profile page skeleton — avatar + stats + name + buttons.
class ProfileSkeleton extends StatelessWidget {
  const ProfileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SkeletonBone(width: 84, height: 84, borderRadius: 42),
                const SizedBox(width: 20),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: List.generate(
                      3,
                      (_) => const Column(
                        children: [
                          SkeletonBone(width: 40, height: 18, borderRadius: 4),
                          SizedBox(height: 6),
                          SkeletonBone(width: 50, height: 12, borderRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const SkeletonBone(width: 120, height: 18, borderRadius: 4),
            const SizedBox(height: 8),
            const SkeletonBone(width: 80, height: 14, borderRadius: 4),
            const SizedBox(height: 16),
            const SkeletonBone(height: 44, borderRadius: 12),
          ],
        ),
      ),
    );
  }
}

/// List item skeleton — avatar circle + two lines of text.
class ListTileSkeleton extends StatelessWidget {
  const ListTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          SkeletonBone(width: 48, height: 48, borderRadius: 24),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBone(width: 140, height: 14, borderRadius: 4),
                SizedBox(height: 8),
                SkeletonBone(width: 200, height: 12, borderRadius: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Grid skeleton — 3-column grid of square placeholders.
class GridSkeleton extends StatelessWidget {
  final int count;
  const GridSkeleton({super.key, this.count = 9});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 3,
        mainAxisSpacing: 3,
      ),
      itemCount: count,
      itemBuilder: (_, _) => const SkeletonBone(
        height: double.infinity,
        borderRadius: 0,
      ),
    );
  }
}

/// Chat list skeleton — multiple list tile skeletons.
class ChatListSkeleton extends StatelessWidget {
  final int count;
  const ChatListSkeleton({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      // ClipRect + OverflowBox: the Column is allowed to be its natural
      // height but is clipped to the available space so it never triggers
      // a RenderFlex overflow error when placed in a constrained parent
      // such as a TabBarView tab.
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topCenter,
          maxHeight: double.infinity,
          child: Column(
            children: List.generate(count, (_) => const ListTileSkeleton()),
          ),
        ),
      ),
    );
  }
}

/// Search grid skeleton — shimmer over grid placeholders.
class SearchGridSkeleton extends StatelessWidget {
  const SearchGridSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: GridSkeleton(),
    );
  }
}
