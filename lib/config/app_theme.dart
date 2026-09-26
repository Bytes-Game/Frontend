import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Single source of truth for the app's design system.
///
/// Aesthetic: calm and professional, the way Apple's own apps look. Black
/// and white, greys for anything secondary, and one accent colour — Apple's
/// blue — for the thing on a screen you are meant to press. Red, green and
/// orange appear only where they MEAN something: a like, a win, a loss, a
/// warning. No neon, no glows, no rainbow gradients.
///
/// The colour values are Apple's own system colours (dark-mode variants,
/// which also read well on white).
///
/// Exposes design tokens (colors, spacing, radii, gradients, shadows) as
/// static members so individual screens can build consistent custom widgets
/// on top of the theme.
class AppTheme {
  AppTheme._();

  // ═══════════════════════════════════════════════════════════════════════
  // CORE PALETTE
  // ═══════════════════════════════════════════════════════════════════════

  /// The one accent: Apple's system blue. Buttons, links, selection, your
  /// own chat bubbles.
  static const Color primary = Color(0xFF0A84FF);

  /// Red, for likes and anything that needs attention. (The name is kept
  /// from the old palette so existing screens keep compiling.)
  static const Color accentPink = Color(0xFFFF375F);

  /// Light blue — the soft Apple blue — for small details like read ticks
  /// and online state.
  static const Color accentCyan = Color(0xFF64D2FF);

  /// Links and info: the same blue as [primary].
  static const Color accentBlue = primary;

  /// Success green.
  static const Color success = Color(0xFF30D158);

  /// Warning orange.
  static const Color warning = Color(0xFFFF9F0A);

  /// Error red.
  static const Color error = Color(0xFFFF453A);

  // ─── Dark surfaces ────────────────────────────────────────────────────
  /// True black, like an iPhone in dark mode.
  static const Color bgDark = Color(0xFF000000);

  /// Elevated surface (cards, sheets).
  static const Color surfaceDark = Color(0xFF1C1C1E);

  /// Higher-elevation surface (dialogs, modals, popups).
  static const Color surfaceDarkHigh = Color(0xFF2C2C2E);

  /// Hairline separators on dark.
  static const Color borderDark = Color(0xFF38383A);

  /// Secondary text on dark.
  static const Color textMutedDark = Color(0xFF8E8E93);

  // ─── Light surfaces ───────────────────────────────────────────────────
  static const Color bgLight = Colors.white;
  static const Color surfaceLight = Colors.white;
  static const Color surfaceLightHigh = Color(0xFFF2F2F7);
  static const Color borderLight = Color(0xFFE5E5EA);
  static const Color textMutedLight = Color(0xFF6E6E73);

  // ═══════════════════════════════════════════════════════════════════════
  // GRADIENTS — kept quiet: one hue at a time, never a rainbow
  // ═══════════════════════════════════════════════════════════════════════

  /// Primary: the accent, with the slightest shading.
  static const LinearGradient gradientPrimary = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0A84FF), Color(0xFF0071E3)],
  );

  /// Hero — for banners and the login background: charcoal to black.
  static const LinearGradient gradientHero = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF1C1C1E), Color(0xFF000000)],
  );

  /// Secondary accent: blue to the soft light blue.
  static const LinearGradient gradientCyber = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0A84FF), Color(0xFF64D2FF)],
  );

  /// Subtle surface gradient — for elevated cards with depth.
  static const LinearGradient gradientSurface = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF2C2C2E), Color(0xFF1C1C1E)],
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
  // SHADOW HELPERS
  //
  // These used to be coloured glows. They are soft neutral shadows now:
  // something lifted off the page casts a shadow, it does not light up.
  // The names are kept so existing screens keep compiling.
  // ═══════════════════════════════════════════════════════════════════════

  static List<BoxShadow> _soft(double intensity) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: intensity * 0.6),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ];

  static List<BoxShadow> glowPrimary({double intensity = 0.35}) =>
      _soft(intensity);

  static List<BoxShadow> glowPink({double intensity = 0.35}) =>
      _soft(intensity);

  static List<BoxShadow> glowCyan({double intensity = 0.35}) =>
      _soft(intensity);

  /// Standard elevation shadow — for cards on dark backgrounds.
  static final List<BoxShadow> elevationShadow = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.3),
      blurRadius: 16,
      offset: const Offset(0, 6),
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
      displayLarge: GoogleFonts.inter(
        fontSize: 40,
        fontWeight: FontWeight.w800,
        color: onSurface,
        letterSpacing: -1,
        height: 1.1,
      ),
      displayMedium: GoogleFonts.inter(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        color: onSurface,
        letterSpacing: -0.5,
        height: 1.15,
      ),
      displaySmall: GoogleFonts.inter(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        color: onSurface,
        letterSpacing: -0.25,
      ),

      // Headline — section headers
      headlineLarge: GoogleFonts.inter(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: onSurface,
      ),
      headlineMedium: GoogleFonts.inter(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: onSurface,
      ),
      headlineSmall: GoogleFonts.inter(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),

      // Title — cards, list items, app bars
      titleLarge: GoogleFonts.inter(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      titleMedium: GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      titleSmall: GoogleFonts.inter(
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
      outlineVariant: Color(0xFF48484A),
    ),
    textTheme: _buildTextTheme(Colors.white, textMutedDark),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      backgroundColor: bgDark,
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: GoogleFonts.inter(
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
      titleTextStyle: GoogleFonts.inter(
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
      titleTextStyle: GoogleFonts.inter(
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
