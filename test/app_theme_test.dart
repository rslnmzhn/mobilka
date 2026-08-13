import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/core/theme/app_theme.dart';

void main() {
  test('mobilka Workbench has distinct paper and charcoal palettes', () {
    final light = AppTheme.build(
      ThemePreset.mobilkaWorkbench,
      Brightness.light,
    );
    final dark = AppTheme.build(ThemePreset.mobilkaWorkbench, Brightness.dark);

    expect(light.extension<WorkbenchColors>(), isNotNull);
    expect(dark.extension<WorkbenchColors>(), isNotNull);
    expect(light.scaffoldBackgroundColor, const Color(0xFFF2EBDD));
    expect(dark.scaffoldBackgroundColor, const Color(0xFF181817));
    expect(light.cardTheme.elevation, 0);
    expect(dark.appBarTheme.surfaceTintColor, Colors.transparent);
  });
}
