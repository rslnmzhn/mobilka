cmake_minimum_required(VERSION 3.22)

add_executable(mobilka_document_worker WIN32
  main.cpp
  protocol.cpp
  sandbox.cpp)
apply_standard_settings(mobilka_document_worker)
target_compile_definitions(mobilka_document_worker PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN
  _ITERATOR_DEBUG_LEVEL=0 _HAS_ITERATOR_DEBUGGING=0)
set_property(TARGET mobilka_document_worker PROPERTY
  MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
target_compile_options(mobilka_document_worker PRIVATE /MD)
target_link_libraries(mobilka_document_worker PRIVATE mobilka_document_engine bcrypt)
set_target_properties(mobilka_document_worker PROPERTIES
  OUTPUT_NAME "document_worker"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/document_worker")
