#include "document_engine_internal.h"

#include <algorithm>
#include <mutex>
#include <new>

namespace mobilka::documents {

void check_pixels(int width, int height, const Limits& limits, size_t& total) {
  require(width > 0 && height > 0 && width <= limits.raster_dimension &&
              height <= limits.raster_dimension, Error::limit);
  const size_t pixels = static_cast<size_t>(width) * static_cast<size_t>(height);
  require(pixels <= limits.page_pixels && total <= limits.total_pixels &&
              pixels <= limits.total_pixels - total, Error::limit);
  total += pixels;
}

void append(std::string& text, const char* bytes, size_t size, size_t limit) {
  require(text.size() <= limit && size <= limit - text.size(), Error::limit);
  text.append(bytes, size);
}

Result process(const Request& request, Bytes eng, Bytes rus) noexcept {
  static std::mutex mutex;
  try {
    const std::lock_guard<std::mutex> lock(mutex);
    const auto& l = request.limits;
    const Limits ceiling;
    require(l.source_bytes > 0 && l.source_bytes <= ceiling.source_bytes &&
        l.pdf_pages > 0 && l.pdf_pages <= ceiling.pdf_pages &&
        l.selected_pages > 0 && l.selected_pages <= ceiling.selected_pages &&
        l.raster_dimension > 0 && l.raster_dimension <= ceiling.raster_dimension &&
        l.page_pixels > 0 && l.page_pixels <= ceiling.page_pixels &&
        l.total_pixels >= l.page_pixels && l.total_pixels <= ceiling.total_pixels &&
        l.page_output_bytes > 0 && l.page_output_bytes <= ceiling.page_output_bytes &&
        l.output_bytes > 0 && l.output_bytes <= ceiling.output_bytes,
        Error::invalid_request);
    require(request.source.data && request.source.size > 0 &&
        request.source.size <= l.source_bytes && request.first_page > 0 &&
        request.page_count > 0 && request.page_count <= l.selected_pages,
        Error::invalid_request);
    require(request.language == Language::eng || request.language == Language::rus ||
        request.language == Language::eng_rus, Error::invalid_request);
    switch (request.operation) {
      case Operation::pdf_text:
      case Operation::pdf_ocr: return process_pdf(request, eng, rus);
      case Operation::image_ocr: return process_image(request, eng, rus);
    }
    throw Failure{Error::invalid_request};
  } catch (const Failure& failure) {
    return {failure.error, 0, {}};
  } catch (const std::bad_alloc&) {
    return {Error::limit, 0, {}};
  } catch (...) {
    return {Error::invalid_document, 0, {}};
  }
}

const char* license_notices() noexcept {
  return "PDFium 7520: BSD-3-Clause and bundled third-party licenses; "
         "Tesseract 5.5.1: Apache-2.0; Leptonica 1.85.0: BSD-2-Clause; "
         "tessdata_fast 4.1.0 eng/rus: Apache-2.0. "
         "Full notices must accompany the provisioned native distribution.";
}

}
