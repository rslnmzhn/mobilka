import 'package:flutter/material.dart';

enum ThemePreset { claude, darkCyber, midnightOled, solarized, nord, classic }

extension ThemePresetLabel on ThemePreset {
  String get label => switch (this) {
    ThemePreset.claude => 'Claude',
    ThemePreset.darkCyber => 'Dark Cyber',
    ThemePreset.midnightOled => 'Midnight OLED',
    ThemePreset.solarized => 'Solarized',
    ThemePreset.nord => 'Nord',
    ThemePreset.classic => 'Classic',
  };
}

abstract final class AppTheme {
  static ThemeData build(ThemePreset preset, Brightness brightness) {
    final seed = switch (preset) {
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
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(height: 68),
    );
  }
}
