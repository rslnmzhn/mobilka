import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../storage/app_boxes.dart';
import 'app_theme.dart';

part 'theme_controller.g.dart';

class ThemeState {
  const ThemeState({required this.preset, required this.mode});
  final ThemePreset preset;
  final ThemeMode mode;
}

@Riverpod(keepAlive: true)
class ThemeController extends _$ThemeController {
  @override
  ThemeState build() {
    final presetName =
        preferencesBox.get('themePreset', defaultValue: 'claude') as String;
    final dark = preferencesBox.get('darkMode', defaultValue: true) as bool;
    return ThemeState(
      preset: ThemePreset.values.firstWhere(
        (value) => value.name == presetName,
        orElse: () => ThemePreset.claude,
      ),
      mode: dark ? ThemeMode.dark : ThemeMode.light,
    );
  }

  Future<void> setPreset(ThemePreset preset) async {
    await preferencesBox.put('themePreset', preset.name);
    state = ThemeState(preset: preset, mode: state.mode);
  }

  Future<void> setDarkMode(bool enabled) async {
    await preferencesBox.put('darkMode', enabled);
    state = ThemeState(
      preset: state.preset,
      mode: enabled ? ThemeMode.dark : ThemeMode.light,
    );
  }
}
