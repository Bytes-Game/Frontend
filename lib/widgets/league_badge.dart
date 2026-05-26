import 'package:flutter/material.dart';

/// Coloured league badge with gradient background.
/// Used in profile pages, user tiles, and post cards.
class LeagueBadge extends StatelessWidget {
  final String league;
  final bool small;

  const LeagueBadge({super.key, required this.league, this.small = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 8 : 16,
        vertical: small ? 2: 6,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: _gradient(league)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        league,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: small ? 10 : 14,
        ),
      ),
    );
  }

  static List<Color> _gradient(String league) {
    switch (league.toLowerCase()) {
      case 'bronze':
        return const [Color(0xFFCD7F32), Color(0xFF8B4513)];
      case 'silver':
        return const [Color(0xFFC0C0C0), Color(0xFF808080)];
      case 'gold':
        return const [Color(0xFFFFD700), Color(0xFFDAA520)];
      case 'platinum':
        return const [Color(0xFF00CED1), Color(0xFF008B8B)];
      case 'diamond':
        return const [Color(0xFFB9F2FF), Color(0xFF4169E1)];
      default:
        return [Colors.grey, Colors.grey.shade700];
    }
  }

  /// Helper to get a single colour (used elsewhere for simple indicators)
  static Color solidColor(String league) => _gradient(league).first;
}