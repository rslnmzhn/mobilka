cmake_minimum_required(VERSION 3.22)

# Run with cmake -D... -P; each upstream gets its own build tree.
if(NOT DOCUMENTS_SOURCES_REVIEWED)
  message(FATAL_ERROR "First verify archive digests and extracted source trees against the approved manifest")
endif()
foreach(path DOCUMENTS_BUILD_ROOT DOCUMENTS_INSTALL_PREFIX)
  if(NOT IS_ABSOLUTE "${${path}}")
    message(FATAL_ERROR "${path} must be an absolute path")
  endif()
endforeach()
if(NOT DOCUMENTS_TARGET MATCHES "^(windows-x64|android)$")
  message(FATAL_ERROR "DOCUMENTS_TARGET must be windows-x64 or android")
endif()
if(NOT IS_ABSOLUTE "${DOCUMENTS_NINJA}" OR NOT EXISTS "${DOCUMENTS_NINJA}")
  message(FATAL_ERROR "DOCUMENTS_NINJA must identify the reviewed Ninja executable")
endif()
if(NOT DEFINED DOCUMENTS_PARALLEL)
  set(DOCUMENTS_PARALLEL 2)
endif()
if(NOT DOCUMENTS_PARALLEL MATCHES "^[1-8]$")
  message(FATAL_ERROR "DOCUMENTS_PARALLEL must be an integer from 1 through 8")
endif()
file(READ "${CMAKE_CURRENT_LIST_DIR}/dependency-versions.json" versions)
file(SHA256 "${CMAKE_CURRENT_LIST_FILE}" recipe_sha256)
file(SHA256 "${CMAKE_CURRENT_LIST_DIR}/dependency-versions.json" dependency_lock_sha256)
foreach(dep ZLIB PNG JPEG LEPTONICA TESSERACT)
  if(NOT IS_ABSOLUTE "${DOCUMENTS_${dep}_SOURCE}" OR
      NOT EXISTS "${DOCUMENTS_${dep}_SOURCE}/CMakeLists.txt")
    message(FATAL_ERROR "Required extracted local source: DOCUMENTS_${dep}_SOURCE")
  endif()
  string(JSON version_file GET "${versions}" sources ${dep} version_file)
  string(JSON version_pattern GET "${versions}" sources ${dep} version_pattern)
  file(READ "${DOCUMENTS_${dep}_SOURCE}/${version_file}" content)
  if(NOT content MATCHES "${version_pattern}")
    message(FATAL_ERROR "Unexpected ${dep} version in ${version_file}")
  endif()
endforeach()

set(common -G Ninja
  "-DCMAKE_MAKE_PROGRAM=${DOCUMENTS_NINJA}"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DCMAKE_INSTALL_PREFIX=${DOCUMENTS_INSTALL_PREFIX}"
  "-DCMAKE_INSTALL_LIBDIR=lib"
  "-DCMAKE_PREFIX_PATH=${DOCUMENTS_INSTALL_PREFIX}"
  "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
  "-DBUILD_SHARED_LIBS=OFF"
  "-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF"
  "-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF"
  "-DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON")
if(DOCUMENTS_TARGET STREQUAL "android")
  if(NOT EXISTS "${DOCUMENTS_NDK}/build/cmake/android.toolchain.cmake" OR
      NOT DOCUMENTS_ABI MATCHES "^(arm64-v8a|armeabi-v7a|x86_64)$")
    message(FATAL_ERROR "Supply DOCUMENTS_NDK and a supported DOCUMENTS_ABI")
  endif()
  list(APPEND common
    "-DCMAKE_TOOLCHAIN_FILE=${DOCUMENTS_NDK}/build/cmake/android.toolchain.cmake"
    "-DANDROID_ABI=${DOCUMENTS_ABI}" "-DANDROID_PLATFORM=android-29"
    "-DANDROID_STL=c++_shared")
else()
  list(APPEND common "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"
    "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW")
endif()

function(run)
  execute_process(COMMAND ${ARGV} RESULT_VARIABLE result)
  if(NOT result STREQUAL "0")
    message(FATAL_ERROR "Dependency command failed (${result}): ${ARGV}")
  endif()
endfunction()

function(build dep)
  string(JSON source_sha256 GET "${versions}" sources ${dep} sha256)
  set(identity_input "${recipe_sha256}|${dependency_lock_sha256}|${DOCUMENTS_TARGET}|${DOCUMENTS_ABI}|${source_sha256}|${common}|${ARGN}")
  if(DOCUMENTS_TARGET STREQUAL "android")
    file(SHA256 "${DOCUMENTS_NDK}/source.properties" ndk_sha256)
    string(APPEND identity_input "|${ndk_sha256}")
  endif()
  string(SHA256 identity "${identity_input}")
  set(marker "${DOCUMENTS_BUILD_ROOT}/${dep}.complete")
  if(EXISTS "${marker}")
    file(STRINGS "${marker}" marker_lines)
    list(LENGTH marker_lines marker_count)
    if(marker_count EQUAL 5)
      list(GET marker_lines 0 saved_identity)
      list(GET marker_lines 1 saved_output)
      list(GET marker_lines 2 saved_output_sha)
      list(GET marker_lines 3 saved_header)
      list(GET marker_lines 4 saved_header_sha)
      string(REGEX REPLACE "^[^=]*=" "" saved_identity "${saved_identity}")
      string(REGEX REPLACE "^[^=]*=" "" saved_output "${saved_output}")
      string(REGEX REPLACE "^[^=]*=" "" saved_output_sha "${saved_output_sha}")
      string(REGEX REPLACE "^[^=]*=" "" saved_header "${saved_header}")
      string(REGEX REPLACE "^[^=]*=" "" saved_header_sha "${saved_header_sha}")
      cmake_path(IS_PREFIX DOCUMENTS_INSTALL_PREFIX "${saved_output}" NORMALIZE output_in_prefix)
      cmake_path(IS_PREFIX DOCUMENTS_INSTALL_PREFIX "${saved_header}" NORMALIZE header_in_prefix)
      if(saved_identity STREQUAL identity AND output_in_prefix AND header_in_prefix AND
          EXISTS "${saved_output}" AND EXISTS "${saved_header}")
        file(SHA256 "${saved_output}" actual_output_sha)
        file(SHA256 "${saved_header}" actual_header_sha)
        if(actual_output_sha STREQUAL saved_output_sha AND
            actual_header_sha STREQUAL saved_header_sha)
          message(STATUS "[documents] ${DOCUMENTS_ABI}: ${dep} already complete")
          set(${dep}_LIBRARY "${saved_output}" PARENT_SCOPE)
          set(${dep}_SKIPPED TRUE PARENT_SCOPE)
          return()
        endif()
      endif()
    endif()
  endif()
  message(STATUS "[documents] ${DOCUMENTS_ABI}: configuring ${dep}")
  set(${dep}_IDENTITY "${identity}" PARENT_SCOPE)
  set(${dep}_MARKER "${marker}" PARENT_SCOPE)
  set(${dep}_SKIPPED FALSE PARENT_SCOPE)
  if(dep STREQUAL "TESSERACT")
    file(MAKE_DIRECTORY "${DOCUMENTS_BUILD_ROOT}/${dep}/.cmake/api/v1/query")
    file(WRITE "${DOCUMENTS_BUILD_ROOT}/${dep}/.cmake/api/v1/query/codemodel-v2" "")
  endif()
  run("${CMAKE_COMMAND}" -S "${DOCUMENTS_${dep}_SOURCE}"
    -B "${DOCUMENTS_BUILD_ROOT}/${dep}" ${common} ${ARGN})
  if(dep STREQUAL "TESSERACT")
    run("${CMAKE_COMMAND}" --build "${DOCUMENTS_BUILD_ROOT}/${dep}"
      --target libtesseract --config Release --parallel "${DOCUMENTS_PARALLEL}")
    set(reply "${DOCUMENTS_BUILD_ROOT}/${dep}/.cmake/api/v1/reply")
    file(GLOB indexes "${reply}/index-*.json")
    list(SORT indexes)
    list(POP_BACK indexes index)
    file(READ "${index}" index_json)
    string(JSON model_file GET "${index_json}" reply codemodel-v2 jsonFile)
    file(READ "${reply}/${model_file}" model)
    string(JSON count LENGTH "${model}" configurations 0 targets)
    math(EXPR last "${count} - 1")
    set(archive "")
    foreach(i RANGE 0 ${last})
      string(JSON name GET "${model}" configurations 0 targets ${i} name)
      if(name STREQUAL "libtesseract")
        string(JSON target_file GET "${model}" configurations 0 targets ${i} jsonFile)
        file(READ "${reply}/${target_file}" target)
        string(JSON type GET "${target}" type)
        string(JSON artifact_count LENGTH "${target}" artifacts)
        if(NOT type STREQUAL "STATIC_LIBRARY" OR NOT artifact_count EQUAL 1)
          message(FATAL_ERROR "Expected one static libtesseract artifact")
        endif()
        string(JSON archive GET "${target}" artifacts 0 path)
      endif()
    endforeach()
    if(archive STREQUAL "")
      message(FATAL_ERROR "libtesseract artifact missing from CMake codemodel")
    endif()
    if(NOT IS_ABSOLUTE "${archive}")
      set(archive "${DOCUMENTS_BUILD_ROOT}/${dep}/${archive}")
    endif()
    set(headers "${DOCUMENTS_${dep}_SOURCE}/include/tesseract")
    set(version "${DOCUMENTS_BUILD_ROOT}/${dep}/include/tesseract/version.h")
    if(NOT EXISTS "${archive}" OR NOT EXISTS "${headers}/baseapi.h" OR
        NOT EXISTS "${version}")
      message(FATAL_ERROR "Missing Tesseract archive, public headers or generated version.h")
    endif()
    file(INSTALL "${archive}" DESTINATION "${DOCUMENTS_INSTALL_PREFIX}/lib" TYPE FILE)
    file(INSTALL "${headers}/" DESTINATION "${DOCUMENTS_INSTALL_PREFIX}/include/tesseract"
      TYPE DIRECTORY FILES_MATCHING PATTERN "*.h")
    file(INSTALL "${version}" DESTINATION "${DOCUMENTS_INSTALL_PREFIX}/include/tesseract" TYPE FILE)
    get_filename_component(archive_name "${archive}" NAME)
    set(installed_archive "${DOCUMENTS_INSTALL_PREFIX}/lib/${archive_name}")
    set(installed_header "${DOCUMENTS_INSTALL_PREFIX}/include/tesseract/baseapi.h")
    file(SHA256 "${installed_archive}" output_sha)
    file(SHA256 "${installed_header}" header_sha)
    file(WRITE "${marker}"
      "identity=${identity}\noutput=${installed_archive}\noutput_sha256=${output_sha}\nheader=${installed_header}\nheader_sha256=${header_sha}\n")
    message(STATUS "[documents] ${DOCUMENTS_ABI}: ${dep} complete")
    set(TESSERACT_LIBRARY "${installed_archive}" PARENT_SCOPE)
    return()
  endif()
  run("${CMAKE_COMMAND}" --build "${DOCUMENTS_BUILD_ROOT}/${dep}"
    --parallel "${DOCUMENTS_PARALLEL}")
  run("${CMAKE_COMMAND}" --install "${DOCUMENTS_BUILD_ROOT}/${dep}")
endfunction()

function(library dep)
  if(${dep}_SKIPPED)
    return()
  endif()
  unset(found CACHE)
  # Script-mode lookup uses the build host, not the Android toolchain. Require
  # archives explicitly so a host's shared zlib symlink cannot be selected.
  set(CMAKE_FIND_LIBRARY_SUFFIXES ".a" ".lib")
  find_library(found NAMES ${ARGN} PATHS "${DOCUMENTS_INSTALL_PREFIX}/lib"
    NO_DEFAULT_PATH REQUIRED)
  if(IS_SYMLINK "${found}")
    message(FATAL_ERROR "Expected a regular static archive for ${dep}")
  endif()
  if(dep STREQUAL "ZLIB")
    set(header "${DOCUMENTS_INSTALL_PREFIX}/include/zlib.h")
  elseif(dep STREQUAL "PNG")
    set(header "${DOCUMENTS_INSTALL_PREFIX}/include/png.h")
  elseif(dep STREQUAL "JPEG")
    set(header "${DOCUMENTS_INSTALL_PREFIX}/include/jpeglib.h")
  elseif(dep STREQUAL "LEPTONICA")
    set(header "${DOCUMENTS_INSTALL_PREFIX}/include/leptonica/allheaders.h")
  else()
    set(header "${DOCUMENTS_INSTALL_PREFIX}/include/tesseract/baseapi.h")
  endif()
  if(NOT EXISTS "${header}")
    message(FATAL_ERROR "Installed header missing for ${dep}")
  endif()
  file(SHA256 "${found}" output_sha)
  file(SHA256 "${header}" header_sha)
  file(WRITE "${${dep}_MARKER}"
    "identity=${${dep}_IDENTITY}\noutput=${found}\noutput_sha256=${output_sha}\nheader=${header}\nheader_sha256=${header_sha}\n")
  message(STATUS "[documents] ${DOCUMENTS_ABI}: ${dep} complete")
  set(${dep}_LIBRARY "${found}" PARENT_SCOPE)
endfunction()

if(DOCUMENTS_TARGET STREQUAL "android")
  set(cpu_features_source "${CMAKE_CURRENT_LIST_DIR}/android_cpu_features")
  set(cpu_features_config
    "${DOCUMENTS_INSTALL_PREFIX}/lib/cmake/CpuFeaturesNdkCompat")
  run("${CMAKE_COMMAND}" -S "${cpu_features_source}"
    -B "${DOCUMENTS_BUILD_ROOT}/CPU_FEATURES" ${common})
  run("${CMAKE_COMMAND}" --build "${DOCUMENTS_BUILD_ROOT}/CPU_FEATURES"
    --target install --config Release --parallel "${DOCUMENTS_PARALLEL}")
endif()

build(ZLIB -DZLIB_BUILD_EXAMPLES=OFF)
# zlib 1.3.1 also builds a shared target; consumers are pinned to this static archive.
library(ZLIB zlibstatic z)
build(PNG -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
  "-DZLIB_LIBRARY=${ZLIB_LIBRARY}" "-DZLIB_INCLUDE_DIR=${DOCUMENTS_INSTALL_PREFIX}/include")
library(PNG libpng16_static png16)
build(JPEG -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF
  -DWITH_TOOLS=OFF -DWITH_TESTS=OFF -DWITH_SIMD=OFF -DWITH_CRT_DLL=ON)
library(JPEG jpeg-static jpeg)
build(LEPTONICA -DSW_BUILD=OFF -DBUILD_PROG=OFF -DENABLE_ZLIB=ON
  -DENABLE_PNG=ON -DENABLE_JPEG=ON -DENABLE_GIF=OFF -DENABLE_TIFF=OFF
  -DENABLE_WEBP=OFF -DENABLE_OPENJPEG=OFF
  "-DZLIB_LIBRARY=${ZLIB_LIBRARY}" "-DZLIB_INCLUDE_DIR=${DOCUMENTS_INSTALL_PREFIX}/include"
  "-DPNG_LIBRARY=${PNG_LIBRARY}" "-DPNG_PNG_INCLUDE_DIR=${DOCUMENTS_INSTALL_PREFIX}/include"
  "-DJPEG_LIBRARY=${JPEG_LIBRARY}" "-DJPEG_INCLUDE_DIR=${DOCUMENTS_INSTALL_PREFIX}/include")
library(LEPTONICA leptonica-1.85.0 leptonica lept)
build(TESSERACT -DSW_BUILD=OFF -DBUILD_TRAINING_TOOLS=OFF -DBUILD_TESTS=OFF
  "-DCpuFeaturesNdkCompat_DIR=${cpu_features_config}"
  -DDISABLED_LEGACY_ENGINE=ON -DOPENMP_BUILD=OFF
  -DDISABLE_CURL=ON -DDISABLE_ARCHIVE=ON -DDISABLE_TIFF=ON
  -DLEPT_TIFF_RESULT=1 -DLEPT_TIFF_COMPILE_SUCCESS=TRUE
  -DCMAKE_DISABLE_FIND_PACKAGE_LibArchive=ON
  "-DLeptonica_DIR=${DOCUMENTS_INSTALL_PREFIX}/lib/cmake/leptonica")
foreach(dep ZLIB PNG JPEG LEPTONICA TESSERACT)
  message(STATUS "DOCUMENTS_${dep}_LIBRARY=${${dep}_LIBRARY}")
endforeach()
