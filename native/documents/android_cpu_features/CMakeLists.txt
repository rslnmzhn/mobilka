cmake_minimum_required(VERSION 3.22)
project(mobilka_android_cpu_features LANGUAGES CXX)

add_library(android_cpu_features STATIC cpu-features.cpp)
add_library(CpuFeatures::ndk_compat ALIAS android_cpu_features)
target_compile_features(android_cpu_features PUBLIC cxx_std_17)
target_include_directories(android_cpu_features PUBLIC
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include/ndk_compat>"
  "$<INSTALL_INTERFACE:include/ndk_compat>")
set_target_properties(android_cpu_features PROPERTIES
  EXPORT_NAME ndk_compat
  POSITION_INDEPENDENT_CODE ON)

install(TARGETS android_cpu_features EXPORT CpuFeaturesNdkCompatTargets
  ARCHIVE DESTINATION lib)
install(FILES include/ndk_compat/cpu-features.h DESTINATION include/ndk_compat)
install(EXPORT CpuFeaturesNdkCompatTargets
  FILE CpuFeaturesNdkCompatTargets.cmake
  NAMESPACE CpuFeatures::
  DESTINATION lib/cmake/CpuFeaturesNdkCompat)
install(FILES CpuFeaturesNdkCompatConfig.cmake
  DESTINATION lib/cmake/CpuFeaturesNdkCompat)
