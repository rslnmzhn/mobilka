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
file(READ "${CMAKE_CURRENT_LIST_DIR}/dependency-versions.json" versions)
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
  run("${CMAKE_COMMAND}" -S "${DOCUMENTS_${dep}_SOURCE}"
    -B "${DOCUMENTS_BUILD_ROOT}/${dep}" ${common} ${ARGN})
  run("${CMAKE_COMMAND}" --build "${DOCUMENTS_BUILD_ROOT}/${dep}" --parallel 2)
  run("${CMAKE_COMMAND}" --install "${DOCUMENTS_BUILD_ROOT}/${dep}")
endfunction()

function(library dep)
  unset(found CACHE)
  find_library(found NAMES ${ARGN} PATHS "${DOCUMENTS_INSTALL_PREFIX}/lib"
    NO_DEFAULT_PATH REQUIRED)
  set(${dep}_LIBRARY "${found}" PARENT_SCOPE)
endfunction()

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
  -DBUILD_TESSERACT=OFF -DDISABLED_LEGACY_ENGINE=ON -DOPENMP_BUILD=OFF
  -DDISABLE_CURL=ON -DDISABLE_ARCHIVE=ON
  "-DLeptonica_DIR=${DOCUMENTS_INSTALL_PREFIX}/lib/cmake/leptonica")
library(TESSERACT tesseract55 tesseract)
foreach(dep ZLIB PNG JPEG LEPTONICA TESSERACT)
  message(STATUS "DOCUMENTS_${dep}_LIBRARY=${${dep}_LIBRARY}")
endforeach()
