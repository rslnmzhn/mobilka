#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace mobilka::documents {

enum class Operation { pdf_text, pdf_ocr, image_ocr };
enum class Language { eng, rus, eng_rus };
enum class Error { none, invalid_request, unsupported, invalid_document, limit, unavailable };

struct Bytes {
  const uint8_t* data = nullptr;
  size_t size = 0;
};

struct Limits {
  size_t source_bytes = 10485760;
  int pdf_pages = 100;
  int selected_pages = 25;
  int raster_dimension = 4096;
  size_t page_pixels = 4000000;
  size_t total_pixels = 20000000;
  size_t page_output_bytes = 262144;
  size_t output_bytes = 1048576;
};

struct Request {
  Operation operation = Operation::pdf_text;
  Language language = Language::eng;
  int first_page = 1;
  int page_count = 1;
  Limits limits;
  Bytes source;
};

struct Page {
  int number;
  std::string text;
  int width = 0;
  int height = 0;
};

struct Result {
  Error error = Error::none;
  int page_count = 0;
  std::vector<Page> pages;
};

// Only invoke inside a disposable, externally supervised native worker.
Result process(const Request& request, Bytes eng, Bytes rus) noexcept;
const char* license_notices() noexcept;

}
