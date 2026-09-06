# Offline native document engine provisioning

This source is not deployed or runtime-enabled. Never load it in the application
process. Compilation, hostile-input tests, OS worker isolation, output framing,
memory limits and hard worker termination must pass before enabling availability.
No cooperative cancellation can preempt PDFium, Leptonica or Tesseract parsing.
The native result text budget excludes transport metadata; a worker adapter must
enforce the 1 MiB total encoded response ceiling as well.

## Required reviewed artifacts

No authoritative digests have been established in this task. Obtain and approve
SHA-256 values separately; do not compute a digest from an untrusted download and
treat that alone as provenance. CMake never downloads or falls back to system
packages. Supply an immutable provisioning manifest with archive, source-tree,
header, binary, runtime DLL/SO, codec, language-data and notice hashes, build
toolchain identities and all build options. Verify extracted trees against that
manifest externally before setting `DOCUMENTS_PROVISIONING_REVIEWED=ON`.

* PDFium release `chromium/7520`, plain flavor, not `pdfium-v8`:
  `https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F7520/pdfium-android-arm64.tgz`
  and `https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F7520/pdfium-win-x64.tgz`.
  Other target architectures need their own independently reviewed artifacts.
  Verify release build provenance has `pdf_enable_v8=false` and
  `pdf_enable_xfa=false`; the plain asset name alone is not proof of both flags.
  Reject any binary without that evidence. Preserve all shipped PDFium notices.
* Tesseract 5.5.1 source:
  `https://github.com/tesseract-ocr/tesseract/archive/refs/tags/5.5.1.tar.gz`.
* Leptonica 1.85.0 source:
  `https://github.com/DanBloomberg/leptonica/archive/refs/tags/1.85.0.tar.gz`.
* English and Russian fast language data:
  `https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/4.1.0/eng.traineddata`
  and `https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/4.1.0/rus.traineddata`.

Build dependencies separately from verified local source directories. Disable
Tesseract CLI, training, tests, legacy engine, OpenMP, curl and archive support:
`BUILD_TRAINING_TOOLS=OFF`, `BUILD_TESTS=OFF`, `BUILD_TESSERACT=OFF`,
`DISABLED_LEGACY_ENGINE=ON`, `OPENMP_BUILD=OFF`, `DISABLE_CURL=ON`,
`DISABLE_ARCHIVE=ON`, `SW_BUILD=OFF`. Check the exact upstream cache and reject
unused options rather than assuming they took effect. Leptonica:
`BUILD_PROG=OFF`, `SW_BUILD=OFF`, `ENABLE_PNG=ON`, `ENABLE_JPEG=ON`,
`ENABLE_ZLIB=ON`, and GIF/TIFF/WEBP/OPENJPEG support OFF. The codec versions are
libpng 1.6.47, libjpeg-turbo 3.1.0 and zlib 1.3.1. Exact source URLs and version
checks are recorded in `dependency-versions.json`. Its null hashes explicitly
mean unapproved; supply authoritative reviewed hashes externally. These fixed
versions are build inputs, not a claim of current security support.
`dependencies.cmake` models the static Tesseract → Leptonica → PNG/JPEG/zlib
link closure. PDFium remains a separately provisioned shared library.

## Offline dependency build commands to request

`build-dependencies.cmake` is a CMake script, not an included project. It performs
no downloads, extraction, Git operations or installs of toolchains. It builds and
installs native libraries into the explicit local prefix. It checks source version
markers before any build. Archive hashes and extracted tree integrity must first
be verified externally. Use fresh build/prefix directories per ABI and compiler;
never reuse a desktop prefix for Android. The terminal runner must verify parent
directories and approve output locations before running these commands.

Prerequisites: CMake 3.22–3.x, Ninja, and either an x64 MSVC developer environment
or the project's pinned Android NDK. No NASM is needed (`WITH_SIMD=OFF`). All
five extracted source directories must already exist. Set the five
`DOCUMENTS_<NAME>_SOURCE` paths, where NAME is ZLIB, PNG, JPEG, LEPTONICA or
TESSERACT. For example, from the repository root in an x64 MSVC environment:

```
cmake -DDOCUMENTS_TARGET=windows-x64 -DDOCUMENTS_SOURCES_REVIEWED=ON -DDOCUMENTS_BUILD_ROOT=<absolute-build-root> -DDOCUMENTS_INSTALL_PREFIX=<absolute-prefix> -DDOCUMENTS_ZLIB_SOURCE=<absolute-zlib-source> -DDOCUMENTS_PNG_SOURCE=<absolute-png-source> -DDOCUMENTS_JPEG_SOURCE=<absolute-jpeg-source> -DDOCUMENTS_LEPTONICA_SOURCE=<absolute-leptonica-source> -DDOCUMENTS_TESSERACT_SOURCE=<absolute-tesseract-source> -P native/documents/build-dependencies.cmake
```

For Android use the same command with `DOCUMENTS_TARGET=android`, plus
`-DDOCUMENTS_NDK=<absolute-ndk>` and `-DDOCUMENTS_ABI=arm64-v8a` (or
`armeabi-v7a`, `x86_64`). API 29 and `c++_shared` are explicit. Stage the matching
NDK `libc++_shared.so` alongside PDFium only in the future worker package.
Windows dependencies use Release `/MD`; configure the engine with the same CRT.

The script prints the five resolved static-library paths. Record and approve
their hashes after the trusted local build; these are output identity checks,
not independent upstream provenance. Supply all five paths to the engine cache,
including `DOCUMENTS_PNG_LIBRARY`, `DOCUMENTS_JPEG_LIBRARY` and
`DOCUMENTS_ZLIB_LIBRARY`, each with `_SHA256`. All include roots normally point
to `<prefix>/include`, except PDFium's own include root. Verify Tesseract and
Leptonica installed headers actually occupy `tesseract/` and `leptonica/` there.

zlib 1.3.1 builds a shared target too; the recipe explicitly selects the static
archive for every consumer. Do not package the unused zlib shared output.
Capture all configure output, especially unused manually specified variables;
compilation has not yet validated upstream option behavior. If configuration
fails, provide the exact configure log and these complete official source files
as local readable files: each project's `CMakeLists.txt`, Leptonica's
`cmake/Configure.cmake`, its generated `LeptonicaConfig.cmake`, and Tesseract's
`cmake/FindLeptonica.cmake` if present. Do not enable SW package downloading or
substitute system libraries to get past a failure.

## Engine configuration plan (not executed)

Supply these local file variables and a matching `_SHA256` for each:
`DOCUMENTS_PDFIUM_LIBRARY`, `DOCUMENTS_TESSERACT_LIBRARY`,
`DOCUMENTS_LEPTONICA_LIBRARY`, `DOCUMENTS_ENG_DATA`, `DOCUMENTS_RUS_DATA`,
`DOCUMENTS_PROVISIONING_MANIFEST`, `DOCUMENTS_LICENSES`.
Supply include roots `DOCUMENTS_PDFIUM_INCLUDE`, `DOCUMENTS_TESSERACT_INCLUDE`,
`DOCUMENTS_LEPTONICA_INCLUDE`; their contents must be covered by external manifest
verification. On Windows, imported library paths are link/import libraries;
review and stage their matching runtime DLLs separately.

Use an externally prepared CMake initial-cache file containing the verified
absolute paths and digests:

```
cmake -S native/documents -B <existing-build-parent>/documents -C <reviewed-cache.cmake> -DDOCUMENTS_BUILD_TESTS=ON
cmake --build <existing-build-parent>/documents --config Release
ctest --test-dir <existing-build-parent>/documents -C Release --output-on-failure
```

For Android, add the pinned NDK toolchain, `ANDROID_ABI=arm64-v8a` and
`ANDROID_PLATFORM=android-29`, and use Android dependency binaries. No Gradle
wiring is authorized yet. Native tests currently cover malformed input, request
limits, pixel aggregation and output overflow only. Valid PDF fixtures, OCR
RU/EN fixtures, image header adversarial cases, callback rejection, encoded output
and deadline/memory worker tests remain required.

## Resource-loading audit still required

The official 5.5.1 `baseapi.h:211-215` declares the memory/reader overload.
`baseapi.cpp:329-342` stores the supplied reader, constructs `TessdataManager`
with it and passes that manager to `init_tesseract`. The engine supplies no
config files and accepts only two exact synthetic language names in its reader.
The reader never opens files. Before deployment, inspect
`src/ccutil/tessdatamanager.cpp` (Init/GetComponent reader failure paths),
`src/ccutil/serialis.cpp` (TFile::Open), and `src/ccmain/tessedit.cpp`
(sub-language initialization and embedded config handling) to prove no downstream
filesystem fallback. That proof was not completed by this task. Trusted language
data must also be audited for embedded external resource configuration.

Full upstream licenses, third-party notices, codec notices and tessdata licenses
must accompany packaging; `license_notices()` is an identification API, not a
replacement for those full texts.
