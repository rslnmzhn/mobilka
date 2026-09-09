# Offline native document engine provisioning

This source is loaded only by the Android isolated document service, never by the
application process. Android relies on its separate isolated UID, no worker
permissions, bounded preallocation/input/page/pixel/output checks, watchdog,
Binder death observation, and permanent service-instance invalidation after a
deadline or worker death. Android memory remains OS-managed; no hard 256 MiB or
PID-reaping claim is made.
No cooperative cancellation can preempt PDFium, Leptonica or Tesseract parsing.
The native result text budget excludes transport metadata; a worker adapter must
enforce the 1 MiB total encoded response ceiling as well.

## Required reviewed artifacts

Approved immutable artifact identifiers are recorded in
`dependency-versions.json`. The Android provisioning script downloads only those
pinned HTTPS URLs and rejects every digest mismatch. CMake never downloads or
falls back to system packages. Supply an immutable provisioning manifest with archive, source-tree,
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

Tesseract 5.5.1 declares its CLI target unconditionally; `BUILD_TESSERACT` is
not a supported switch. This recipe builds only `libtesseract`, never Tesseract's
default/all or install target. Training remains disabled, as do curl and archive
support (`DISABLE_CURL=ON`, `DISABLE_ARCHIVE=ON`). The CMake File API identifies
the actual static archive rather than guessing a Unix or Windows filename (the
observed Windows Release name is `tesseract55.lib`). The recipe remains Release
only; it does not search for a possibly stale Debug library. It copies that archive,
`include/tesseract/*.h` public headers and the build-generated
`include/tesseract/version.h` into the explicit prefix. No CLI, training executable
or global install is provisioned. Other dependencies retain their normal local
prefix installation. Android uses its own configured build's artifact path, not
the previously compiled Windows prefix.

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

## Offline local identity and notices (not executed)

After primary review, `provision-local.cmake` may generate files at build time in
a new direct child of a supplied existing absolute temporary directory outside
this repository. It performs no downloads, builds, installs or process execution,
and refuses to overwrite an existing output directory. It measures all files in
the supplied header/source trees in sorted relative-path order, records individual
and tree SHA-256 values, hashes libraries/language data/runtime files, and copies
complete license contents verbatim into `LICENSES.txt` with section labels. It
rejects missing/empty license files and symlinks in trees. It cannot establish
that caller-supplied notices cover every upstream dependency; review that inventory.

This is **local build identity, not official source/archive provenance
verification**. Unknown downloads must not become trusted merely by hashing them.
Supply an already independently reviewed, fixed JSON archive manifest and its
previously approved `DOCUMENTS_PRIOR_ARCHIVE_MANIFEST_SHA256`. Its shape is
`{"archives":{"PDFIUM":{"sha256":"<previously-approved-64-hex>"},...}}`, with
entries for PDFIUM, TESSERACT, LEPTONICA, PNG, JPEG, ZLIB, ENG and RUS. Additional
provenance fields are permitted and retained in the copied input manifest. For
ENG/RUS the archive input can be the original pinned traineddata download. Each
`DOCUMENTS_<NAME>_ARCHIVE` must name the corresponding existing absolute local
file; all eight are checked against those prior hashes, never minted as approvals.
The separately approved hash of the manifest pins the complete provenance input.

Required local inputs (all file/tree paths absolute):

* `DOCUMENTS_TEMP_ROOT`: existing temporary directory;
  `DOCUMENTS_LOCAL_OUTPUT`: new direct child with an alphanumeric/underscore/hyphen
  name. Use a different output and artifact set per target/ABI.
* `DOCUMENTS_PRIOR_ARCHIVE_MANIFEST`, its `_SHA256`, and the eight archive paths.
* `DOCUMENTS_BUILD_IDENTITY`: existing complete build metadata text, including
  platform/ABI, compiler/toolchain versions, CRT, build configuration, build options,
  and references to independently reviewed PDFium no-V8/no-XFA evidence. This text
  is recorded, not interpreted as proof.
* `DOCUMENTS_<NAME>_LIBRARY` and `DOCUMENTS_<NAME>_INCLUDE` for PDFIUM, TESSERACT,
  LEPTONICA, PNG, JPEG and ZLIB; `DOCUMENTS_<NAME>_SOURCE` for the five built
  dependencies. Shared include roots are allowed and measured in full.
* `DOCUMENTS_ENG_DATA`, `DOCUMENTS_RUS_DATA`; `DOCUMENTS_RUNTIME_FILES` is a
  semicolon-separated inventory of all needed DLL/SO files, including PDFium's
  Windows DLL when the library path is an import library and Android's matching
  `libc++_shared.so`. Do not omit actual runtime dependencies.
* Required semicolon-separated `DOCUMENTS_<NAME>_LICENSE_FILES` for PDFIUM,
  PDFIUM_DEPENDENCY, TESSERACT, LEPTONICA, PNG, JPEG, ZLIB, ENG and RUS.
  PDFIUM must include the full existing upstream LICENSE; PDFIUM_DEPENDENCY must
  include every shipped dependency notice/license (supply the actual paths, not
  invented names or a summary). ENG/RUS require their actual language-data license
  paths; the same upstream license file may be supplied for both where applicable.

Runner commands from the repository root, after output-parent approval (replace
placeholders with reviewed existing paths; no shell file writes are needed):

```powershell
cmake "-DDOCUMENTS_TEMP_ROOT=<absolute-existing-temp>" "-DDOCUMENTS_LOCAL_OUTPUT=<absolute-existing-temp>/documents-local-25" "-DDOCUMENTS_PRIOR_ARCHIVE_MANIFEST=<absolute-reviewed-json>" "-DDOCUMENTS_PRIOR_ARCHIVE_MANIFEST_SHA256=<previously-approved-hash>" "-DDOCUMENTS_BUILD_IDENTITY=<absolute-build-metadata>" <required -DDOCUMENTS_* path/list arguments above> -P native/documents/provision-local.cmake
```

The output contains `local-build-identity.txt`, `LICENSES.txt`, a copy of the
prior archive manifest, and `local-config.cmake` with actual paths and measured
`_SHA256` values for the engine's verified-file inputs. The initial cache explicitly
sets `DOCUMENTS_PROVISIONING_REVIEWED=OFF`. Review the generated identity, full
notices, source/header integrity, build metadata and independent upstream
provenance before explicitly overriding it. Do not modify measured inputs between
review and configuration; header/source trees are recorded here but the engine
does not rehash them at configure time. For an isolated Windows check:

```powershell
cmake -S native/documents -B "<absolute-temp-engine-build>" -G Ninja -C "<absolute-existing-temp>/documents-local-25/local-config.cmake" -DCMAKE_BUILD_TYPE=Release -DDOCUMENTS_PROVISIONING_REVIEWED=ON -DDOCUMENTS_BUILD_TESTS=ON
cmake --build "<absolute-temp-engine-build>" --target document_engine_test --parallel 2
ctest --test-dir "<absolute-temp-engine-build>" --output-on-failure
```

These are commands for a separately authorized runner, **not executed checks**.
Concrete invocations require the caller's real local paths and prior hashes;
none are inferred from the earlier Windows build. Android requires separately
provisioned artifacts and the NDK/ABI/toolchain arguments described above; desktop
test execution does not verify Android. Nothing here enables the production engine
or changes the active application.

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
