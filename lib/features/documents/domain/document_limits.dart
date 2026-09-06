final class DocumentException implements Exception {
  const DocumentException(this.code);

  final String code;

  @override
  String toString() => code;
}

final class DocumentLimits {
  factory DocumentLimits({
    int sourceBytes = 10 * 1024 * 1024,
    int zipEntries = 512,
    int memberBytes = 8 * 1024 * 1024,
    int expandedBytes = 32 * 1024 * 1024,
    int expansionRatio = 100,
    int xmlDepth = 64,
    int xmlEvents = 250000,
    int xmlAttributes = 64,
    int outputBytes = 1024 * 1024,
    int sheets = 32,
    int rows = 10000,
    int columns = 256,
    int cells = 100000,
    int cellBytes = 65536,
    int pdfPages = 100,
    int selectedPages = 25,
    int rasterDimension = 4096,
    int pagePixels = 4000000,
    int totalPixels = 20000000,
    int pageOutputBytes = 262144,
    int wallMilliseconds = 30000,
    int nativeMemoryBytes = 256 * 1024 * 1024,
  }) {
    final values = [
      sourceBytes,
      zipEntries,
      memberBytes,
      expandedBytes,
      expansionRatio,
      xmlDepth,
      xmlEvents,
      xmlAttributes,
      outputBytes,
      sheets,
      rows,
      columns,
      cells,
      cellBytes,
      pdfPages,
      selectedPages,
      rasterDimension,
      pagePixels,
      totalPixels,
      pageOutputBytes,
      wallMilliseconds,
      nativeMemoryBytes,
    ];
    const ceilings = [
      10485760,
      512,
      8388608,
      33554432,
      100,
      64,
      250000,
      64,
      1048576,
      32,
      10000,
      256,
      100000,
      65536,
      100,
      25,
      4096,
      4000000,
      20000000,
      262144,
      30000,
      268435456,
    ];
    for (var i = 0; i < values.length; i++) {
      if (values[i] < 1 || values[i] > ceilings[i]) {
        throw const DocumentException('invalid_document_limits');
      }
    }
    return DocumentLimits._(List.unmodifiable(values));
  }

  DocumentLimits._(this._values);
  final List<int> _values;
  int get pdfPages => _values[14];
  int get selectedPages => _values[15];
  int get rasterDimension => _values[16];
  int get pagePixels => _values[17];
  int get totalPixels => _values[18];
  int get pageOutputBytes => _values[19];
  int get wallMilliseconds => _values[20];
  int get nativeMemoryBytes => _values[21];

  int checkedRasterPixels(int width, int height) {
    if (width < 1 ||
        height < 1 ||
        width > rasterDimension ||
        height > rasterDimension ||
        width > pagePixels ~/ height) {
      throw const DocumentException('document_raster_limit');
    }
    return width * height;
  }

  int get sourceBytes => _values[0];
  int get zipEntries => _values[1];
  int get memberBytes => _values[2];
  int get expandedBytes => _values[3];
  int get expansionRatio => _values[4];
  int get xmlDepth => _values[5];
  int get xmlEvents => _values[6];
  int get xmlAttributes => _values[7];
  int get outputBytes => _values[8];
  int get sheets => _values[9];
  int get rows => _values[10];
  int get columns => _values[11];
  int get cells => _values[12];
  int get cellBytes => _values[13];
}
