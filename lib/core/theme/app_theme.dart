import 'package:flutter/material.dart';

enum ThemePreset {
  hermesWorkbench,
  claude,
  darkCyber,
  midnightOled,
  solarized,
  nord,
  classic,
}

extension ThemePresetLabel on ThemePreset {
  String get label => switch (this) {
    ThemePreset.hermesWorkbench => 'Hermes Workbench',
    ThemePreset.claude => 'Claude',
    ThemePreset.darkCyber => 'Dark Cyber',
    ThemePreset.midnightOled => 'Midnight OLED',
    ThemePreset.solarized => 'Solarized',
    ThemePreset.nord => 'Nord',
    ThemePreset.classic => 'Classic',
  };
}

@immutable
class WorkbenchColors extends ThemeExtension<WorkbenchColors> {
  const WorkbenchColors({
    required this.canvas,
    required this.sidebar,
    required this.divider,
    required this.mutedInk,
  });

  final Color canvas;
  final Color sidebar;
  final Color divider;
  final Color mutedInk;

  @override
  WorkbenchColors copyWith({
    Color? canvas,
    Color? sidebar,
    Color? divider,
    Color? mutedInk,
  }) => WorkbenchColors(
    canvas: canvas ?? this.canvas,
    sidebar: sidebar ?? this.sidebar,
    divider: divider ?? this.divider,
    mutedInk: mutedInk ?? this.mutedInk,
  );

  @override
  WorkbenchColors lerp(WorkbenchColors? other, double t) {
    if (other == null) return this;
    return WorkbenchColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      mutedInk: Color.lerp(mutedInk, other.mutedInk, t)!,
    );
  }
}

abstract final class AppTheme {
  static ThemeData build(ThemePreset preset, Brightness brightness) {
    if (preset == ThemePreset.hermesWorkbench) {
      return _hermes(brightness);
    }

    final seed = switch (preset) {
      ThemePreset.hermesWorkbench => throw StateError('Handled above'),
      ThemePreset.claude => const Color(0xFFD97757),
      ThemePreset.darkCyber => const Color(0xFF00D9FF),
      ThemePreset.midnightOled => const Color(0xFF8B5CF6),
      ThemePreset.solarized => const Color(0xFF2AA198),
      ThemePreset.nord => const Color(0xFF88C0D0),
      ThemePreset.classic => const Color(0xFF2563EB),
    };
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final background = switch ((preset, brightness)) {
      (ThemePreset.claude, Brightness.light) => const Color(0xFFF7F4ED),
      (ThemePreset.claude, Brightness.dark) => const Color(0xFF211E1A),
      (ThemePreset.midnightOled, Brightness.dark) => Colors.black,
      (ThemePreset.solarized, Brightness.dark) => const Color(0xFF002B36),
      (ThemePreset.solarized, Brightness.light) => const Color(0xFFFDF6E3),
      (ThemePreset.nord, Brightness.dark) => const Color(0xFF2E3440),
      (ThemePreset.nord, Brightness.light) => const Color(0xFFECEFF4),
      _ => scheme.surface,
    };
    return _baseTheme(scheme, background);
  }

  static ThemeData _hermes(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: dark ? const Color(0xFFD9A074) : const Color(0xFF8A4F32),
      onPrimary: dark ? const Color(0xFF24170F) : const Color(0xFFFFF8F0),
      secondary: dark ? const Color(0xFFBCA68F) : const Color(0xFF765D49),
      onSecondary: dark ? const Color(0xFF211B17) : Colors.white,
      error: dark ? const Color(0xFFFFB4AB) : const Color(0xFF9B2C24),
      onError: dark ? const Color(0xFF690005) : Colors.white,
      surface: dark ? const Color(0xFF1E1E1C) : const Color(0xFFF8F3E9),
      onSurface: dark ? const Color(0xFFEAE4D9) : const Color(0xFF292621),
    );
    final workbench = WorkbenchColors(
      canvas: dark ? const Color(0xFF181817) : const Color(0xFFF2EBDD),
      sidebar: dark ? const Color(0xFF20201E) : const Color(0xFFEAE0D0),
      divider: dark ? const Color(0xFF3A3935) : const Color(0xFFD5C8B5),
      mutedInk: dark ? const Color(0xFFA7A097) : const Color(0xFF71695F),
    );
    final base = _baseTheme(scheme, workbench.canvas);
    final textTheme = base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(
        fontFamily: 'serif',
        fontWeight: FontWeight.w500,
        letterSpacing: -0.8,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontFamily: 'serif',
        fontWeight: FontWeight.w600,
        letterSpacing: -0.35,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontFamily: 'serif',
        fontWeight: FontWeight.w600,
      ),
      labelSmall: base.textTheme.labelSmall?.copyWith(
        letterSpacing: 1.2,
        fontWeight: FontWeight.w700,
      ),
    );
    return base.copyWith(
      textTheme: textTheme,
      extensions: [workbench],
      dividerColor: workbench.divider,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: workbench.divider),
        ),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
        shape: Border(bottom: BorderSide(color: workbench.divider, width: 0.7)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(7)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: workbench.divider),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        elevation: 0,
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.12),
        labelTextStyle: WidgetStatePropertyAll(textTheme.labelSmall),
      ),
    );
  }

  static ThemeData _baseTheme(ColorScheme scheme, Color background) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      visualDensity: VisualDensity.standard,
      dividerTheme: const DividerThemeData(space: 1, thickness: 0.7),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      navigationBarTheme: const NavigationBarThemeData(height: 68),
    );
  }
}
