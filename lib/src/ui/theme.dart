import 'package:flutter/material.dart';

/// YinTrace design tokens.
///
/// The palette borrows the mineral pigments of Chinese painting, and every
/// colour carries one meaning:
///
/// * 墨 ink – text, the reference melody, primary actions
/// * 宣纸 paper – the score the melody is written on
/// * 石绿 malachite – on pitch, good
/// * 朱砂 cinnabar – sharp (too high), weak
/// * 石青 azurite – flat (too low)
/// * 藤黄 gamboge – close, unstable
///
/// The singer's voice trace blends azurite → malachite → cinnabar by its
/// deviation in cents, so the direction of an error is visible at a glance.
@immutable
class YtPalette extends ThemeExtension<YtPalette> {
  const YtPalette({
    required this.paper,
    required this.surface,
    required this.ink,
    required this.inkSoft,
    required this.inkFaint,
    required this.hairline,
    required this.staff,
    required this.staffStrong,
    required this.malachite,
    required this.cinnabar,
    required this.azurite,
    required this.gamboge,
    required this.noteStroke,
    required this.noteStrokeFuture,
  });

  final Color paper;
  final Color surface;
  final Color ink;
  final Color inkSoft;
  final Color inkFaint;
  final Color hairline;
  final Color staff;
  final Color staffStrong;
  final Color malachite;
  final Color cinnabar;
  final Color azurite;
  final Color gamboge;

  /// Reference notes already reached / not reached yet.
  final Color noteStroke;
  final Color noteStrokeFuture;

  static const light = YtPalette(
    paper: Color(0xFFFAFAF8),
    surface: Color(0xFFFFFFFF),
    ink: Color(0xFF1E2230),
    inkSoft: Color(0xFF5C6273),
    inkFaint: Color(0xFF9AA0AD),
    hairline: Color(0xFFE6E7EB),
    staff: Color(0xFFEEEFF2),
    staffStrong: Color(0xFFD9DBE1),
    malachite: Color(0xFF179C78),
    cinnabar: Color(0xFFD2452F),
    azurite: Color(0xFF2F5FB3),
    gamboge: Color(0xFFD99A1E),
    noteStroke: Color(0xFF1E2230),
    noteStrokeFuture: Color(0xFF3A4152),
  );

  static const dark = YtPalette(
    paper: Color(0xFF151923),
    surface: Color(0xFF1C212D),
    ink: Color(0xFFEDEEF2),
    inkSoft: Color(0xFFA9AEBB),
    inkFaint: Color(0xFF6E7484),
    hairline: Color(0xFF2A303D),
    staff: Color(0xFF1F2430),
    staffStrong: Color(0xFF2E3442),
    malachite: Color(0xFF2FC197),
    cinnabar: Color(0xFFF0644C),
    azurite: Color(0xFF5B8BE8),
    gamboge: Color(0xFFF0B640),
    noteStroke: Color(0xFFEDEEF2),
    noteStrokeFuture: Color(0xFFC9CDD6),
  );

  /// Colour of a pitch deviation (cents): azurite (flat) → malachite →
  /// cinnabar (sharp). [tolerance] is the "on pitch" half width.
  Color deviation(double cents, {double tolerance = 50}) {
    final a = cents.abs();
    if (a <= tolerance) return malachite;
    final t = ((a - tolerance) / (tolerance * 2)).clamp(0.0, 1.0);
    return Color.lerp(Color.lerp(malachite, gamboge, 0.35)!, cents > 0 ? cinnabar : azurite, t)!;
  }

  /// Colour of a 0..100 score.
  Color score(double s) => s >= 80 ? malachite : (s >= 60 ? gamboge : cinnabar);

  @override
  YtPalette copyWith() => this;

  @override
  YtPalette lerp(YtPalette? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return YtPalette(
      paper: c(paper, other.paper),
      surface: c(surface, other.surface),
      ink: c(ink, other.ink),
      inkSoft: c(inkSoft, other.inkSoft),
      inkFaint: c(inkFaint, other.inkFaint),
      hairline: c(hairline, other.hairline),
      staff: c(staff, other.staff),
      staffStrong: c(staffStrong, other.staffStrong),
      malachite: c(malachite, other.malachite),
      cinnabar: c(cinnabar, other.cinnabar),
      azurite: c(azurite, other.azurite),
      gamboge: c(gamboge, other.gamboge),
      noteStroke: c(noteStroke, other.noteStroke),
      noteStrokeFuture: c(noteStrokeFuture, other.noteStrokeFuture),
    );
  }
}

extension YtThemeContext on BuildContext {
  YtPalette get yt => Theme.of(this).extension<YtPalette>() ?? YtPalette.light;
  TextTheme get type => Theme.of(this).textTheme;
}

/// Tabular figures for times and scores.
const tabular = [FontFeature.tabularFigures()];

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? YtPalette.dark : YtPalette.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.ink,
    onPrimary: p.paper,
    secondary: p.malachite,
    onSecondary: Colors.white,
    tertiary: p.azurite,
    onTertiary: Colors.white,
    error: p.cinnabar,
    onError: Colors.white,
    surface: p.paper,
    onSurface: p.ink,
    onSurfaceVariant: p.inkSoft,
    outline: p.inkFaint,
    outlineVariant: p.hairline,
    surfaceContainerLowest: p.surface,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surface,
    surfaceContainerHighest: p.staff,
  );
  const fallback = ['PingFang SC', 'Hiragino Sans GB', 'Noto Sans CJK SC', 'Microsoft YaHei'];
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  TextStyle s(double size, FontWeight w, {double height = 1.3, Color? color, double spacing = 0}) => TextStyle(
        fontSize: size,
        fontWeight: w,
        height: height,
        letterSpacing: spacing,
        color: color ?? p.ink,
        fontFamilyFallback: fallback,
      );
  final scale = TextTheme(
    displayLarge: s(64, FontWeight.w200, height: 1.0, spacing: -1.5),
    displayMedium: s(44, FontWeight.w300, height: 1.05, spacing: -0.8),
    headlineLarge: s(32, FontWeight.w700, height: 1.15, spacing: -0.4),
    headlineMedium: s(30, FontWeight.w700, height: 1.15, spacing: -0.3),
    headlineSmall: s(22, FontWeight.w600, height: 1.25),
    titleLarge: s(19, FontWeight.w600, height: 1.3),
    titleMedium: s(17, FontWeight.w600, height: 1.35),
    titleSmall: s(15, FontWeight.w600, height: 1.35),
    bodyLarge: s(17, FontWeight.w400, height: 1.45),
    bodyMedium: s(15, FontWeight.w400, height: 1.45, color: p.inkSoft),
    bodySmall: s(13, FontWeight.w400, height: 1.4, color: p.inkSoft),
    labelLarge: s(16, FontWeight.w600, height: 1.2),
    labelMedium: s(13, FontWeight.w500, height: 1.2, color: p.inkSoft),
    labelSmall: s(11, FontWeight.w500, height: 1.2, color: p.inkFaint),
  );
  // Keep the platform's font family (San Francisco / PingFang on iOS).
  final text = base.textTheme.merge(scale);
  return base.copyWith(
    scaffoldBackgroundColor: p.paper,
    canvasColor: p.paper,
    textTheme: text,
    extensions: [p],
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: p.paper,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    dividerTheme: DividerThemeData(color: p.hairline, thickness: 0.8, space: 0.8),
    iconTheme: IconThemeData(color: p.ink, size: 24),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.ink,
        foregroundColor: p.paper,
        disabledBackgroundColor: p.staffStrong,
        disabledForegroundColor: p.inkFaint,
        minimumSize: const Size(64, 52),
        textStyle: text.labelLarge,
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        minimumSize: const Size(64, 48),
        side: BorderSide(color: p.staffStrong),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: p.ink, textStyle: text.labelLarge),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      hintStyle: text.bodyMedium?.copyWith(color: p.inkFaint),
      labelStyle: text.bodyMedium,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.hairline)),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.hairline)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.ink, width: 1.4)),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.ink,
      inactiveTrackColor: p.staffStrong,
      thumbColor: p.ink,
      overlayColor: p.ink.withValues(alpha: 0.08),
      trackHeight: 3,
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) return p.staff;
        return s.contains(WidgetState.selected) ? p.malachite : p.staffStrong;
      }),
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? p.staffStrong : Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall,
      iconColor: p.inkSoft,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.paper,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: p.staffStrong,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.ink,
      contentTextStyle: text.bodyMedium?.copyWith(color: p.paper),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.ink, linearTrackColor: p.staffStrong),
    dialogTheme: DialogThemeData(backgroundColor: p.paper, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(color: p.surface, surfaceTintColor: Colors.transparent),
  );
}
