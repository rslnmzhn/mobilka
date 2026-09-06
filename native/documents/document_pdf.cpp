#include "document_engine_internal.h"

#include <fpdfview.h>
#include <fpdf_text.h>
#include <algorithm>
#include <cmath>

namespace mobilka::documents {
namespace {
struct Library {
  Library() { FPDF_InitLibrary(); }
  ~Library() { FPDF_DestroyLibrary(); }
};
struct Document {
  FPDF_DOCUMENT value;
  ~Document() { if (value) FPDF_CloseDocument(value); }
};
struct PdfPage {
  FPDF_PAGE value;
  ~PdfPage() { if (value) FPDF_ClosePage(value); }
};
struct TextPage {
  FPDF_TEXTPAGE value;
  ~TextPage() { if (value) FPDFText_ClosePage(value); }
};
struct Bitmap {
  FPDF_BITMAP value;
  ~Bitmap() { if (value) FPDFBitmap_Destroy(value); }
};

void append_unicode(std::string& text, uint32_t value, size_t limit) {
  require(value <= 0x10ffff && !(value >= 0xd800 && value <= 0xdfff),
          Error::invalid_document);
  char bytes[4];
  size_t count;
  if (value < 0x80) { bytes[0] = static_cast<char>(value); count = 1; }
  else if (value < 0x800) {
    bytes[0] = static_cast<char>(0xc0 | (value >> 6));
    bytes[1] = static_cast<char>(0x80 | (value & 63)); count = 2;
  } else if (value < 0x10000) {
    bytes[0] = static_cast<char>(0xe0 | (value >> 12));
    bytes[1] = static_cast<char>(0x80 | ((value >> 6) & 63));
    bytes[2] = static_cast<char>(0x80 | (value & 63)); count = 3;
  } else {
    bytes[0] = static_cast<char>(0xf0 | (value >> 18));
    bytes[1] = static_cast<char>(0x80 | ((value >> 12) & 63));
    bytes[2] = static_cast<char>(0x80 | ((value >> 6) & 63));
    bytes[3] = static_cast<char>(0x80 | (value & 63)); count = 4;
  }
  append(text, bytes, count, limit);
}
}

Result process_pdf(const Request& request, Bytes eng, Bytes rus) {
  Library library;
  Document document{FPDF_LoadMemDocument64(request.source.data, request.source.size, nullptr)};
  require(document.value != nullptr, Error::invalid_document);
  const int pages = FPDF_GetPageCount(document.value);
  require(pages > 0 && pages <= request.limits.pdf_pages, Error::limit);
  require(request.first_page <= pages && request.page_count <= pages - request.first_page + 1,
          Error::invalid_request);
  Result result;
  result.page_count = pages;
  size_t output = 0;
  size_t pixels = 0;
  for (int index = 0; index < request.page_count; ++index) {
    const int number = request.first_page + index;
    PdfPage page{FPDF_LoadPage(document.value, number - 1)};
    require(page.value != nullptr, Error::invalid_document);
    const size_t limit = std::min(request.limits.page_output_bytes,
                                  request.limits.output_bytes - output);
    std::string text;
    if (request.operation == Operation::pdf_text) {
      TextPage characters{FPDFText_LoadPage(page.value)};
      require(characters.value != nullptr, Error::invalid_document);
      const int count = FPDFText_CountChars(characters.value);
      require(count >= 0 && static_cast<size_t>(count) <= limit, Error::limit);
      for (int i = 0; i < count; ++i) {
        const auto value = FPDFText_GetUnicode(characters.value, i);
        if (value != 0) append_unicode(text, value, limit);
      }
    } else {
      const double width = FPDF_GetPageWidthF(page.value) * 2.0;
      const double height = FPDF_GetPageHeightF(page.value) * 2.0;
      require(std::isfinite(width) && std::isfinite(height) && width > 0 && height > 0 &&
          width <= request.limits.raster_dimension && height <= request.limits.raster_dimension,
          Error::limit);
      const int w = static_cast<int>(std::ceil(width));
      const int h = static_cast<int>(std::ceil(height));
      check_pixels(w, h, request.limits, pixels);
      std::vector<uint8_t> raster(static_cast<size_t>(w) * h * 4);
      Bitmap bitmap{FPDFBitmap_CreateEx(w, h, FPDFBitmap_BGRA, raster.data(), w * 4)};
      require(bitmap.value != nullptr, Error::limit);
      FPDFBitmap_FillRect(bitmap.value, 0, 0, w, h, 0xffffffff);
      FPDF_RenderPageBitmap(bitmap.value, page.value, 0, 0, w, h, 0, 0);
      Image image{pixCreate(w, h, 32)};
      require(image != nullptr, Error::limit);
      for (int y = 0; y < h; ++y) {
        auto* row = pixGetData(image.get()) + y * pixGetWpl(image.get());
        for (int x = 0; x < w; ++x) {
          const auto* p = raster.data() + (static_cast<size_t>(y) * w + x) * 4;
          row[x] = (static_cast<uint32_t>(p[2]) << 24) |
                   (static_cast<uint32_t>(p[1]) << 16) | (static_cast<uint32_t>(p[0]) << 8);
        }
      }
      text = recognize(image.get(), request.language, eng, rus, limit);
    }
    output += text.size();
    result.pages.push_back({number, std::move(text)});
  }
  return result;
}

}
