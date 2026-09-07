import 'dart:io';

import 'package:image/image.dart' as img;

/// Run from the repository root. Does not change the original artwork.
void main() {
  final source = File('mobilka-icon.jpeg');
  final decoded = img.decodeJpg(source.readAsBytesSync());
  if (decoded == null) {
    throw StateError('The icon source is not a valid JPEG');
  }
  final artwork = img.bakeOrientation(decoded);
  if (artwork.width != artwork.height || artwork.width < 256) {
    throw StateError('Use a square icon source of at least 256 pixels');
  }
  const androidSizes = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  final targets = [
    for (final density in androidSizes.keys)
      File('android/app/src/main/res/mipmap-$density/ic_launcher.png'),
    File('windows/runner/resources/app_icon.ico'),
  ];
  for (final target in targets) {
    if (!target.existsSync() || !target.parent.existsSync()) {
      throw StateError('Expected existing icon target: ${target.path}');
    }
  }
  img.Image resize(int size) => img.copyResize(
    artwork,
    width: size,
    height: size,
    interpolation: img.Interpolation.average,
  );
  var index = 0;
  for (final size in androidSizes.values) {
    targets[index++].writeAsBytesSync(img.encodePng(resize(size)));
  }
  targets.last.writeAsBytesSync(
    img.IcoEncoder().encodeImages([
      for (final size in [16, 24, 32, 48, 64, 128, 256]) resize(size),
    ]),
  );
  stdout.writeln('Generated Android and Windows icons from ${source.path}.');
}
