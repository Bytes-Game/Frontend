import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// A photo post, filling a reel-shaped space.
///
/// A photo challenge ("who looks better", "which meme is funnier") is
/// judged on the WHOLE picture, so it is never cropped: it sits in the
/// middle at its own shape, and the space around it is filled with a
/// blurred, darkened copy of itself — the way Instagram shows a photo in a
/// story. A video is cropped to fill the screen; a photo is not.
class PhotoFace extends StatelessWidget {
  /// The picture's address. Empty draws black: the side of a battle nobody
  /// has answered yet.
  final String url;

  const PhotoFace({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const ColoredBox(color: Colors.black);
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The same picture, blurred, behind. The very same request as the
          // one in front, on purpose: Flutter keeps pictures by how they
          // were asked for, so a smaller copy here (cacheWidth) would be a
          // second download of the same photo, and the feed fetching it
          // ahead (precacheImage) would warm neither.
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          const ColoredBox(color: Color(0x73000000)),
          Image.network(
            url,
            key: const ValueKey('photo_face_picture'),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white70,
                  ),
                ),
              );
            },
            errorBuilder: (_, _, _) => const _CouldNotLoad(),
          ),
        ],
      ),
    );
  }
}

class _CouldNotLoad extends StatelessWidget {
  const _CouldNotLoad();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: Colors.white38, size: 44),
          SizedBox(height: 6),
          Text(
            'The photo could not load',
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }
}
