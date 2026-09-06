cmake_minimum_required(VERSION 3.22)
project(mobilka_documents LANGUAGES CXX)

include(dependencies.cmake)
add_library(mobilka_document_engine STATIC
  document_engine.cpp document_pdf.cpp document_ocr.cpp)
target_compile_features(mobilka_document_engine PUBLIC cxx_std_17)
set_target_properties(mobilka_document_engine PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(mobilka_document_engine PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(mobilka_document_engine PUBLIC
  documents_PDFIUM documents_TESSERACT documents_LEPTONICA)

option(DOCUMENTS_BUILD_TESTS "Build isolated native engine tests" OFF)
if(DOCUMENTS_BUILD_TESTS)
  enable_testing()
  add_executable(document_engine_test tests/document_engine_test.cpp)
  target_link_libraries(document_engine_test PRIVATE mobilka_document_engine)
  add_test(NAME document_engine_test COMMAND document_engine_test)
endif()
