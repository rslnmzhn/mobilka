#include "document_engine_internal.h"

#include <tesseract/baseapi.h>
#include <tesseract/resultiterator.h>
#include <algorithm>
#include <cstring>

namespace mobilka::documents {
namespace {
thread_local Bytes english;
thread_local Bytes russian;

bool read_language(const char* filename, std::vector<char>* output) {
  Bytes bytes;
  if (std::strcmp(filename, "/mobilka-memory/eng.traineddata") == 0) bytes = english;
  else if (std::strcmp(filename, "/mobilka-memory/rus.traineddata") == 0) bytes = russian;
  else return false;
  if (!bytes.data || bytes.size == 0 || bytes.size > 16777216) return false;
  output->assign(bytes.data, bytes.data + bytes.size);
  return true;
}

struct LanguageScope {
  LanguageScope(Bytes eng, Bytes rus) { english = eng; russian = rus; }
  ~LanguageScope() { english = {}; russian = {}; }
};
}

std::string recognize(Pix* image, Language language, Bytes eng, Bytes rus, size_t limit) {
  LanguageScope scope(eng, rus);
  tesseract::TessBaseAPI api;
  const char* name = language == Language::eng ? "eng" :
                     language == Language::rus ? "rus" : "eng+rus";
  const std::vector<std::string> variables{"debug_file", "tessedit_write_images"};
  const std::vector<std::string> values{"", "0"};
  require(api.Init("/mobilka-memory/", 0, name, tesseract::OEM_LSTM_ONLY,
      nullptr, 0, &variables, &values, false, read_language) == 0, Error::unavailable);
  api.SetPageSegMode(tesseract::PSM_AUTO);
  api.SetImage(image);
  require(api.Recognize(nullptr) == 0, Error::invalid_document);
  std::unique_ptr<tesseract::ResultIterator> iterator(api.GetIterator());
  std::string text;
  if (!iterator) return text;
  do {
    // Symbol granularity avoids allocating an unbounded full-page UTF-8 result.
    std::unique_ptr<char[]> symbol(iterator->GetUTF8Text(tesseract::RIL_SYMBOL));
    if (!symbol) continue;
    size_t size = 0;
    const size_t remaining = limit - text.size();
    while (size <= remaining && symbol[size] != '\0') ++size;
    append(text, symbol.get(), size, limit);
    if (iterator->IsAtFinalElement(tesseract::RIL_TEXTLINE, tesseract::RIL_SYMBOL)) {
      append(text, "\n", 1, limit);
    } else if (iterator->IsAtFinalElement(tesseract::RIL_WORD, tesseract::RIL_SYMBOL)) {
      append(text, " ", 1, limit);
    }
  } while (iterator->Next(tesseract::RIL_SYMBOL));
  return text;
}

Result process_image(const Request& request, Bytes eng, Bytes rus) {
  require(request.first_page == 1 && request.page_count == 1, Error::invalid_request);
  require(request.source.size >= 12, Error::invalid_document);
  int format = 0;
  require(findFileFormatBuffer(request.source.data, &format) == 0,
          Error::invalid_document);
  require(format == IFF_PNG || format == IFF_JFIF_JPEG, Error::unsupported);
  int width = 0, height = 0, depth = 0, samples = 0, colormap = 0;
  require(pixReadHeaderMem(request.source.data, request.source.size, &format,
      &width, &height, &depth, &samples, &colormap) == 0, Error::invalid_document);
  size_t pixels = 0;
  check_pixels(width, height, request.limits, pixels);
  Image image{pixReadMem(request.source.data, request.source.size)};
  require(image != nullptr && pixGetWidth(image.get()) == width &&
          pixGetHeight(image.get()) == height, Error::invalid_document);
  const auto limit = std::min(request.limits.page_output_bytes, request.limits.output_bytes);
  Result result;
  result.page_count = 1;
  result.pages.push_back({1, recognize(image.get(), request.language, eng, rus, limit)});
  return result;
}

}
