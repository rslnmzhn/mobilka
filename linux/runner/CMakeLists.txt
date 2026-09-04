cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "session_workspace_common.cc"
  "session_workspace_read.cc"
  "session_workspace_prepare_commit.cc"
  "session_workspace_recovery.cc"
  "session_workspace_state.cc"
  "session_workspace_channel.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

add_executable(session_workspace_native_test
  "session_workspace_native_test.cc"
  "session_workspace_common.cc"
  "session_workspace_read.cc"
  "session_workspace_prepare_commit.cc"
  "session_workspace_recovery.cc"
  "session_workspace_state.cc"
)
apply_standard_settings(session_workspace_native_test)
target_link_libraries(session_workspace_native_test PRIVATE flutter PkgConfig::GTK)
add_test(NAME session_workspace_native_test COMMAND session_workspace_native_test)
