import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The Console's colours beyond Material's scheme: warm neutrals, one
/// indigo accent, and status colours that read in both themes.
@immutable
class Tokens extends ThemeExtension<Tokens> {
  const Tokens({
    required this.canvas,
    required this.panel,
    required this.sunken,
    required this.border,
    required this.muted,
    required this.faint,
    required this.ok,
    required this.warn,
    required this.bad,
    required this.info,
    required this.userBubble,
    required this.mono,
    required this.series,
  });

  final Color canvas;
  final Color panel;
  final Color sunken;
  final Color border;
  final Color muted;
  final Color faint;
  final Color ok;
  final Color warn;
  final Color bad;
  final Color info;
  final Color userBubble;

  /// Monospace font family for code and numbers.
  final String? mono;

  /// Chart series colours, in order.
  final List<Color> series;

  static Tokens of(BuildContext context) => Theme.of(context).extension<Tokens>()!;

  @override
  Tokens copyWith() => this;

  @override
  Tokens lerp(Tokens? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    // Colours blend, so switching light/dark fades instead of jumping.
    return Tokens(
      canvas: c(canvas, other.canvas),
      panel: c(panel, other.panel),
      sunken: c(sunken, other.sunken),
      border: c(border, other.border),
      muted: c(muted, other.muted),
      faint: c(faint, other.faint),
      ok: c(ok, other.ok),
      warn: c(warn, other.warn),
      bad: c(bad, other.bad),
      info: c(info, other.info),
      userBubble: c(userBubble, other.userBubble),
      mono: t < .5 ? mono : other.mono,
      series: [for (var i = 0; i < series.length && i < other.series.length; i++) c(series[i], other.series[i])],
    );
  }
}

const _accentLight = Color(0xFF4A5BD4);
const _accentDark = Color(0xFF94A0FF);

Tokens _tokens(Brightness b, String? mono) => b == Brightness.light
    ? Tokens(
        canvas: const Color(0xFFF6F5F2),
        panel: Colors.white,
        sunken: const Color(0xFFF0EEEA),
        border: const Color(0xFFE5E2DC),
        muted: const Color(0xFF6A6761),
        faint: const Color(0xFF9C9890),
        ok: const Color(0xFF23885A),
        warn: const Color(0xFFB7791F),
        bad: const Color(0xFFC8433A),
        info: _accentLight,
        userBubble: const Color(0xFFECEAE4),
        mono: mono,
        series: const [_accentLight, Color(0xFF1F9D8B), Color(0xFFD9822B), Color(0xFFB4549B), Color(0xFF6B7A8F)],
      )
    : Tokens(
        canvas: const Color(0xFF151514),
        panel: const Color(0xFF1D1D1B),
        sunken: const Color(0xFF242422),
        border: const Color(0xFF33322F),
        muted: const Color(0xFFA6A39C),
        faint: const Color(0xFF75726C),
        ok: const Color(0xFF4CC38A),
        warn: const Color(0xFFE5A847),
        bad: const Color(0xFFF07A70),
        info: _accentDark,
        userBubble: const Color(0xFF2A2A27),
        mono: mono,
        series: const [_accentDark, Color(0xFF4CC9B5), Color(0xFFF0A35E), Color(0xFFE07FC6), Color(0xFF9AA8BC)],
      );

/// [fonts] loads Inter and JetBrains Mono from Google Fonts; tests pass
/// false and get the platform fonts.
ThemeData consoleTheme(Brightness b, {bool fonts = true}) {
  final t = _tokens(b, fonts ? GoogleFonts.jetBrainsMono().fontFamily : 'monospace');
  final accent = b == Brightness.light ? _accentLight : _accentDark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: b).copyWith(
    primary: accent,
    onPrimary: b == Brightness.light ? Colors.white : const Color(0xFF10132E),
    surface: t.panel,
    surfaceContainerLowest: t.canvas,
    surfaceContainerLow: t.canvas,
    surfaceContainer: t.sunken,
    surfaceContainerHigh: t.sunken,
    surfaceContainerHighest: t.userBubble,
    outline: t.border,
    outlineVariant: t.border,
    onSurfaceVariant: t.muted,
    error: t.bad,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: b);
  final text = fonts ? GoogleFonts.interTextTheme(base.textTheme) : base.textTheme;
  final onSurface = scheme.onSurface;
  return base.copyWith(
    scaffoldBackgroundColor: t.canvas,
    canvasColor: t.canvas,
    extensions: [t],
    textTheme: text.apply(bodyColor: onSurface, displayColor: onSurface).copyWith(
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -.2, color: onSurface),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: onSurface),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: onSurface),
      bodyMedium: text.bodyMedium?.copyWith(height: 1.45, color: onSurface),
      bodyLarge: text.bodyLarge?.copyWith(height: 1.55, fontSize: 15.5, color: onSurface),
      labelSmall: text.labelSmall?.copyWith(letterSpacing: .2, color: t.muted),
    ),
    dividerTheme: DividerThemeData(color: t.border, thickness: 1, space: 1),
    cardTheme: CardThemeData(
      color: t.panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: t.border)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: t.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: onSurface),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(t.panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.panel,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: t.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: accent, width: 1.4)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: t.border),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: t.sunken,
      side: BorderSide(color: t.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      labelStyle: text.labelMedium?.copyWith(color: onSurface),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(color: onSurface.withValues(alpha: .92), borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(color: t.panel, fontSize: 12),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: t.panel,
      surfaceTintColor: Colors.transparent,
      indicatorColor: accent.withValues(alpha: .14),
      height: 64,
      labelTextStyle: WidgetStatePropertyAll(text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
    ),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent, linearTrackColor: t.sunken),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(t.faint.withValues(alpha: .5)),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(6),
    ),
  );
}
