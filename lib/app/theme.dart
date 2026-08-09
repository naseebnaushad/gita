import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Brand palette, lifted from assets/branding — a deep indigo/navy paired
/// with an electric blue and a teal-green accent.
class GitaColors {
  GitaColors._();

  static const navy = Color(0xFF1B2040);
  static const navyDeep = Color(0xFF12152B);
  static const indigo = Color(0xFF2E3568);
  static const blue = Color(0xFF3D5AFE);
  static const blueLight = Color(0xFF6C8CFF);
  static const teal = Color(0xFF00BFA5);
  static const tealLight = Color(0xFF3EEBCB);
  static const green = Color(0xFF22C55E);
  static const amber = Color(0xFFF59E0B);
  static const red = Color(0xFFEF4444);
}

const _profileColorPalette = [
  0xFF3D5AFE,
  0xFF00BFA5,
  0xFFFF6D00,
  0xFFD500F9,
  0xFFC51162,
  0xFF64DD17,
];

List<int> get profileColorPalette => _profileColorPalette;

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;

  final scheme = isDark
      ? const ColorScheme.dark(
          primary: GitaColors.blueLight,
          onPrimary: Color(0xFF0A1030),
          primaryContainer: Color(0xFF29327A),
          onPrimaryContainer: Color(0xFFDCE2FF),
          secondary: GitaColors.tealLight,
          onSecondary: Color(0xFF00352C),
          secondaryContainer: Color(0xFF00534A),
          onSecondaryContainer: Color(0xFFC7FFF3),
          tertiary: GitaColors.amber,
          onTertiary: Color(0xFF402D00),
          error: GitaColors.red,
          onError: Colors.white,
          surface: Color(0xFF13162A),
          onSurface: Color(0xFFE4E6F5),
          surfaceContainerLowest: Color(0xFF0C0E1C),
          surfaceContainerLow: Color(0xFF15182D),
          surfaceContainer: Color(0xFF191C33),
          surfaceContainerHigh: Color(0xFF20233C),
          surfaceContainerHighest: Color(0xFF282C48),
          onSurfaceVariant: Color(0xFFA9ADCC),
          outline: Color(0xFF3C4066),
          outlineVariant: Color(0xFF272B48),
          inverseSurface: Color(0xFFE4E6F5),
          onInverseSurface: Color(0xFF13162A),
        )
      : const ColorScheme.light(
          primary: GitaColors.blue,
          onPrimary: Colors.white,
          primaryContainer: Color(0xFFDCE2FF),
          onPrimaryContainer: Color(0xFF00105C),
          secondary: GitaColors.teal,
          onSecondary: Colors.white,
          secondaryContainer: Color(0xFFC7FFF3),
          onSecondaryContainer: Color(0xFF00201B),
          tertiary: Color(0xFFB45309),
          onTertiary: Colors.white,
          error: GitaColors.red,
          onError: Colors.white,
          surface: Color(0xFFFBFBFF),
          onSurface: Color(0xFF1A1C2A),
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: Color(0xFFF5F6FC),
          surfaceContainer: Color(0xFFEFF0FA),
          surfaceContainerHigh: Color(0xFFE9EAF6),
          surfaceContainerHighest: Color(0xFFE2E3F2),
          onSurfaceVariant: Color(0xFF5B5F78),
          outline: Color(0xFFD4D6E8),
          outlineVariant: Color(0xFFE5E6F3),
          inverseSurface: Color(0xFF2E3047),
          onInverseSurface: Color(0xFFF2F2FA),
        );

  final baseTextTheme = GoogleFonts.interTextTheme(
    isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
  );

  final textTheme = baseTextTheme.copyWith(
    headlineSmall: baseTextTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
    ),
    titleLarge: baseTextTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    titleMedium: baseTextTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    titleSmall: baseTextTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    bodyMedium: baseTextTheme.bodyMedium?.copyWith(height: 1.4),
    labelLarge: baseTextTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: textTheme,
    fontFamily: GoogleFonts.inter().fontFamily,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.headlineSmall?.copyWith(fontSize: 22),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      margin: EdgeInsets.zero,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.error, width: 1.2),
      ),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: scheme.outline),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: textTheme.titleLarge,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    dataTableTheme: DataTableThemeData(
      headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
      dataRowColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
      dividerThickness: 1,
      headingTextStyle: textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? scheme.primary : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary.withValues(alpha: 0.5)
            : null,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
  );
}
