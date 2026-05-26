import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Single source of truth for the app's design system.
///
/// Aesthetic: gaming / futuristic — deep space backgrounds with vibrant
/// purple→pink→cyan neon gradients, glassmorphic surfaces, and subtle glows
/// on interactive elements. Inspired by TikTok + PlayStation + modern gaming
/// UIs.
///
/// Exposes design tokens (colors, spacing, radii, gradients, shadows) as
/// static members so individual screens can build consistent custom widgets
/// on top of the theme.
class AppTheme {
  AppTheme._();

  // ═══════════════════════════════════════════════════════════════════════
  // CORE PALETTE
  // ═══════════════════════════════════════════════════════════════════════

  /// Primary brand color — vibrant purple. Used for CTAs, highlights, accents.
  static const Color primary = Color(0xFF8B5CF6);

  /// Hot pink accent — for highlights, likes, alerts, gradient endpoints.
  static const Color accentPink = Color(0xFFEC4899);

  /// Neon cyan — for secondary highlights, online status, futuristic details.
  static const Color accentCyan = Color(0xFF06B6D4);

  /// Electric blue — for links, info states.
  static const Color accentBlue = Color(0xFF3B82F6);

  /// Success green.
  static const Color success = Color(0xFF10B981);

  /// Warning amber.
  static const Color warning = Color(0xFFF59E0B);

  /// Error red.
  static const Color error = Color(0xFFEF4444);

  // ─── Dark surfaces ────────────────────────────────────────────────────
  /// Deepest background — near-black with a faint purple undertone.
  static const Color bgDark = Color(0xFF0A0B1E);

  /// Elevated surface (cards, sheets).
  static const Color surfaceDark = Color(0xFF141629);

  /// Higher-elevation surface (dialogs, modals, popups).
  static const Color surfaceDarkHigh = Color(0xFF1B1E3B);

  /// Subtle border for dark surfaces.
  static const Color borderDark = Color(0xFF2A2D4F);

  /// Muted text on dark.
  static const Color textMutedDark = Color(0xFF8B8FA7);

  // ─── Light surfaces ───────────────────────────────────────────────────
  static const Color bgLight = Color(0xFFF8F9FC);
  static const Color surfaceLight = Colors.white;
  static const Color surfaceLightHigh = Color(0xFFF1F3F9);
  static const Color borderLight = Color(0xFFE5E7EF);
  static const Color textMutedLight = Color(0xFF6B7280);

  // ═══════════════════════════════════════════════════════════════════════
  // GRADIENTS — the soul of the design system
  // ═══════════════════════════════════════════════════════════════════════

  /// Primary CTA gradient — purple to pink (Instagram story ring vibe).
  static const LinearGradient gradientPrimary = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)],
  );

  /// Hero gradient — 3-stop for banners, login backgrounds, feature cards.
  static const LinearGradient gradientHero = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFEC4899), Color(0xFF8B5CF6), Color(0xFF06B6D4)],
  );

  /// Futuristic accent gradient — cyan to purple.
  static const LinearGradient gradientCyber = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF06B6D4), Color(0xFF8B5CF6)],
  );

  /// Subtle surface gradient — for elevated cards with depth.
  static const LinearGradient gradientSurface = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1B1E3B), Color(0xFF141629)],
  );

  /// Vertical dim-to-transparent gradient — for video overlays & hero bottoms.
  static const LinearGradient gradientVideoOverlay = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Colors.transparent, Color(0xCC000000)],
  );

  // ═══════════════════════════════════════════════════════════════════════
  // LEAGUE COLORS — gaming-inspired tier gradients
  // ═══════════════════════════════════════════════════════════════════════

  /// Returns a gradient for a given league name (Bronze, Silver, etc.).
  static LinearGradient leagueGradient(String league) {
    switch (league.toLowerCase()) {
      case 'bronze':
        return const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFCD7F32), Color(0xFF8B4513)],
        );
      case 'silver':
        return const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE8E8E8), Color(0xFF9CA3AF)],
        );
      case 'gold':
        return const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFDE047), Color(0xFFCA8A04)],
        );
      case 'platinum':
        return const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE0F2FE), Color(0xFF7DD3FC)],
        );
      case 'diamond':
      case 'dianond': // typo tolerance for seeded data
        return const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF67E8F9), Color(0xFF8B5CF6)],
        );
      default:
        return gradientPrimary;
    }
  }

  /// Solid tint color for a league (used for backgrounds, borders).
  static Color leagueColor(String league) {
    switch (league.toLowerCase()) {
      case 'bronze':
        return const Color(0xFFCD7F32);
      case 'silver':
        return const Color(0xFFC0C5CE);
      case 'gold':
        return const Color(0xFFFDE047);
      case 'platinum':
        return const Color(0xFF7DD3FC);
      case 'diamond':
      case 'dianond':
        return const Color(0xFF67E8F9);
      default:
        return primary;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // GLOW / SHADOW HELPERS
  // ═══════════════════════════════════════════════════════════════════════

  /// Soft purple glow for primary buttons and highlighted elements.
  static List<BoxShadow> glowPrimary({double intensity = 0.35}) => [
        BoxShadow(
          color: primary.withValues(alpha: intensity),
          blurRadius: 24,
          spreadRadius: -4,
          offset: const Offset(0, 8),
        ),
      ];

  /// Pink glow — for likes, important alerts.
  static List<BoxShadow> glowPink({double intensity = 0.35}) => [
        BoxShadow(
          color: accentPink.withValues(alpha: intensity),
          blurRadius: 24,
          spreadRadius: -4,
          offset: const Offset(0, 8),
        ),
      ];

  /// Cyan glow — for online status, futuristic accents.
  static List<BoxShadow> glowCyan({double intensity = 0.35}) => [
        BoxShadow(
          color: accentCyan.withValues(alpha: intensity),
          blurRadius: 24,
          spreadRadius: -4,
          offset: const Offset(0, 8),
        ),
      ];

  /// Standard elevation shadow — for cards on dark backgrounds.
  static final List<BoxShadow> elevationShadow = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.4),
      blurRadius: 20,
      spreadRadius: -2,
      offset: const Offset(0, 8),
    ),
  ];

  // ═══════════════════════════════════════════════════════════════════════
  // SPACING TOKENS
  // ═══════════════════════════════════════════════════════════════════════

  static const double space2 = 2;
  static const double space4 = 4;
  static const double space8 = 8;
  static const double space12 = 12;
  static const double space16 = 16;
  static const double space20 = 20;
  static const double space24 = 24;
  static const double space32 = 32;
  static const double space40 = 40;
  static const double space48 = 48;
  static const double space64 = 64;

  // ═══════════════════════════════════════════════════════════════════════
  // BORDER RADIUS TOKENS
  // ═══════════════════════════════════════════════════════════════════════

  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 20;
  static const double radiusXxl = 28;
  static const double radiusFull = 999;

  // ═══════════════════════════════════════════════════════════════════════
  // TEXT THEME
  // ═══════════════════════════════════════════════════════════════════════

  static TextTheme _buildTextTheme(Color onSurface, Color muted) {
    return TextTheme(
      // Display — for hero titles, big stats
      displayLarge: GoogleFonts.poppins(
        fontSize: 40,
        fontWeight: FontWeight.w800,
        color: onSurface,
        letterSpacing: -1,
        height: 1.1,
      ),
      displayMedium: GoogleFonts.poppins(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        color: onSurface,
        letterSpacing: -0.5,
        height: 1.15,
      ),
      displaySmall: GoogleFonts.poppins(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        color: onSurface,
        letterSpacing: -0.25,
      ),

      // Headline — section headers
      headlineLarge: GoogleFonts.poppins(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: onSurface,
      ),
      headlineMedium: GoogleFonts.poppins(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: onSurface,
      ),
      headlineSmall: GoogleFonts.poppins(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),

      // Title — cards, list items, app bars
      titleLarge: GoogleFonts.poppins(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      titleMedium: GoogleFonts.poppins(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      titleSmall: GoogleFonts.poppins(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),

      // Body — paragraphs, descriptions
      bodyLarge: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: onSurface,
        height: 1.5,
      ),
      bodyMedium: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: onSurface,
        height: 1.5,
      ),
      bodySmall: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: muted,
        height: 1.4,
      ),

      // Label — buttons, chips, captions
      labelLarge: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: onSurface,
        letterSpacing: 0.2,
      ),
      labelMedium: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: muted,
        letterSpacing: 0.3,
      ),
      labelSmall: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: muted,
        letterSpacing: 0.5,
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // DARK THEME (primary — matches the gaming aesthetic)
  // ═══════════════════════════════════════════════════════════════════════

  static final ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: bgDark,
    canvasColor: bgDark,
    colorScheme: const ColorScheme.dark(
      brightness: Brightness.dark,
      primary: primary,
      onPrimary: Colors.white,
      secondary: accentPink,
      onSecondary: Colors.white,
      tertiary: accentCyan,
      onTertiary: Colors.white,
      error: error,
      onError: Colors.white,
      surface: surfaceDark,
      onSurface: Colors.white,
      surfaceContainerHighest: surfaceDarkHigh,
      outline: borderDark,
      outlineVariant: Color(0xFF3A3D5F),
    ),
    textTheme: _buildTextTheme(Colors.white, textMutedDark),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      backgroundColor: bgDark,
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: GoogleFonts.poppins(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Colors.white,
        letterSpacing: -0.2,
      ),
      iconTheme: const IconThemeData(color: Colors.white, size: 24),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      elevation: 0,
      backgroundColor: surfaceDark,
      surfaceTintColor: Colors.transparent,
      indicatorColor: primary.withValues(alpha: 0.18),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const IconThemeData(color: primary, size: 26);
        }
        return IconThemeData(color: textMutedDark, size: 24);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: primary,
          );
        }
        return GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: textMutedDark,
        );
      }),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: surfaceDark,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLg),
        side: const BorderSide(color: borderDark, width: 1),
      ),
      margin: EdgeInsets.zero,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: primary,
        disabledBackgroundColor: surfaceDarkHigh,
        disabledForegroundColor: textMutedDark,
        elevation: 0,
        shadowColor: primary.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: space24,
          vertical: space16,
        ),
        textStyle: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: space24,
          vertical: space16,
        ),
        textStyle: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: borderDark, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: space24,
          vertical: space16,
        ),
        textStyle: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primary,
        padding: const EdgeInsets.symmetric(
          horizontal: space16,
          vertical: space8,
        ),
        textStyle: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceDark,
      hintStyle: GoogleFonts.inter(
        fontSize: 14,
        color: textMutedDark,
        fontWeight: FontWeight.w400,
      ),
      labelStyle: GoogleFonts.inter(
        fontSize: 14,
        color: textMutedDark,
        fontWeight: FontWeight.w500,
      ),
      floatingLabelStyle: GoogleFonts.inter(
        fontSize: 14,
        color: primary,
        fontWeight: FontWeight.w600,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: borderDark, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: borderDark, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: error, width: 1),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: error, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: space20,
        vertical: space16,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surfaceDarkHigh,
      selectedColor: primary,
      disabledColor: surfaceDark,
      labelStyle: GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      padding: const EdgeInsets.symmetric(horizontal: space12, vertical: space8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusFull),
        side: const BorderSide(color: borderDark),
      ),
      side: const BorderSide(color: borderDark),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surfaceDarkHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusXl),
        side: const BorderSide(color: borderDark),
      ),
      titleTextStyle: GoogleFonts.poppins(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
      contentTextStyle: GoogleFonts.inter(
        fontSize: 14,
        color: Colors.white,
        height: 1.5,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: surfaceDarkHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(radiusXxl)),
      ),
      showDragHandle: true,
      dragHandleColor: borderDark,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: surfaceDarkHigh,
      contentTextStyle: GoogleFonts.inter(
        fontSize: 14,
        color: Colors.white,
        fontWeight: FontWeight.w500,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        side: const BorderSide(color: borderDark),
      ),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
    ),
    dividerTheme: const DividerThemeData(
      color: borderDark,
      thickness: 1,
      space: 1,
    ),
    iconTheme: const IconThemeData(color: Colors.white, size: 24),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: borderDark,
      circularTrackColor: borderDark,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.white;
        return textMutedDark;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return primary;
        return surfaceDarkHigh;
      }),
    ),
    splashFactory: InkRipple.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      },
    ),
  );

  // ═══════════════════════════════════════════════════════════════════════
  // LIGHT THEME (alternative — cleaner, more Apple-like)
  // ═══════════════════════════════════════════════════════════════════════

  static final ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: bgLight,
    canvasColor: bgLight,
    colorScheme: const ColorScheme.light(
      brightness: Brightness.light,
      primary: primary,
      onPrimary: Colors.white,
      secondary: accentPink,
      onSecondary: Colors.white,
      tertiary: accentCyan,
      onTertiary: Colors.white,
      error: error,
      onError: Colors.white,
      surface: surfaceLight,
      onSurface: Color(0xFF111827),
      surfaceContainerHighest: surfaceLightHigh,
      outline: borderLight,
    ),
    textTheme: _buildTextTheme(const Color(0xFF111827), textMutedLight),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      backgroundColor: surfaceLight,
      foregroundColor: const Color(0xFF111827),
      surfaceTintColor: Colors.transparent,
      titleTextStyle: GoogleFonts.poppins(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: const Color(0xFF111827),
        letterSpacing: -0.2,
      ),
      iconTheme: const IconThemeData(color: Color(0xFF111827), size: 24),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      elevation: 0,
      backgroundColor: surfaceLight,
      surfaceTintColor: Colors.transparent,
      indicatorColor: primary.withValues(alpha: 0.12),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const IconThemeData(color: primary, size: 26);
        }
        return IconThemeData(color: textMutedLight, size: 24);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: primary,
          );
        }
        return GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: textMutedLight,
        );
      }),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: surfaceLight,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLg),
        side: const BorderSide(color: borderLight, width: 1),
      ),
      margin: EdgeInsets.zero,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: primary,
        disabledBackgroundColor: surfaceLightHigh,
        disabledForegroundColor: textMutedLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: space24,
          vertical: space16,
        ),
        textStyle: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: space24,
          vertical: space16,
        ),
        textStyle: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF111827),
        side: const BorderSide(color: borderLight, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: space24,
          vertical: space16,
        ),
        textStyle: GoogleFonts.inter(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primary,
        padding: const EdgeInsets.symmetric(
          horizontal: space16,
          vertical: space8,
        ),
        textStyle: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceLightHigh,
      hintStyle: GoogleFonts.inter(
        fontSize: 14,
        color: textMutedLight,
        fontWeight: FontWeight.w400,
      ),
      labelStyle: GoogleFonts.inter(
        fontSize: 14,
        color: textMutedLight,
        fontWeight: FontWeight.w500,
      ),
      floatingLabelStyle: GoogleFonts.inter(
        fontSize: 14,
        color: primary,
        fontWeight: FontWeight.w600,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: borderLight, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: borderLight, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: const BorderSide(color: error, width: 1),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: space20,
        vertical: space16,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surfaceLightHigh,
      selectedColor: primary,
      labelStyle: GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      padding: const EdgeInsets.symmetric(horizontal: space12, vertical: space8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusFull),
        side: const BorderSide(color: borderLight),
      ),
      side: const BorderSide(color: borderLight),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surfaceLight,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusXl),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: surfaceLight,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(radiusXxl)),
      ),
      showDragHandle: true,
      dragHandleColor: borderLight,
    ),
    dividerTheme: const DividerThemeData(
      color: borderLight,
      thickness: 1,
      space: 1,
    ),
    splashFactory: InkRipple.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      },
    ),
  );

  // ═══════════════════════════════════════════════════════════════════════
  // BACKWARDS-COMPAT ALIASES (kept to avoid breaking existing screens)
  // ═══════════════════════════════════════════════════════════════════════

  /// @deprecated Use [primary] instead.
  static const Color brandPurple = primary;

  /// @deprecated Use [accentPink] instead.
  static const Color brandRed = accentPink;

  /// @deprecated Use [bgDark] instead.
  static const Color brandDark = bgDark;
}
