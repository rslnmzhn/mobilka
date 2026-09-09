#include "document_engine_internal.h"
#include <fpdfview.h>
#include <fpdf_edit.h>
#include <fpdf_save.h>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <utility>
#ifdef _WIN32
#include <windows.h>
#endif

using namespace mobilka::documents;

namespace {
void check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

Bytes bytes(const std::vector<uint8_t>& value) {
  return {value.data(), value.size()};
}

struct Library {
  Library() { FPDF_InitLibrary(); }
  ~Library() { FPDF_DestroyLibrary(); }
};
template <typename T, auto Close>
struct Handle {
  T value;
  explicit Handle(T handle) : value(handle) {
    check(value != nullptr, "PDFium fixture handle allocation failed");
  }
  ~Handle() { if (value) Close(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
};

struct Writer : FPDF_FILEWRITE {
  std::vector<uint8_t> data;
  Writer() {
    version = 1;
    WriteBlock = [](FPDF_FILEWRITE* writer, const void* input,
                    unsigned long size) -> int {
      auto& output = static_cast<Writer*>(writer)->data;
      try {
        constexpr size_t limit = 1048576;
        if (size > limit - output.size()) return 0;
        const auto* begin = static_cast<const uint8_t*>(input);
        output.insert(output.end(), begin, begin + size);
        return 1;
      } catch (...) {
        return 0;
      }
    };
  }
};

struct LeptFree {
  void operator()(l_uint8* value) const { lept_free(value); }
};
#ifdef _WIN32
struct GdiFixture {
  HDC dc = nullptr;
  HBITMAP bitmap = nullptr;
  HFONT font = nullptr;
  GdiFixture() = default;
  GdiFixture(const GdiFixture&) = delete;
  GdiFixture& operator=(const GdiFixture&) = delete;
  ~GdiFixture() {
    if (dc) DeleteDC(dc);
    if (font) DeleteObject(font);
    if (bitmap) DeleteObject(bitmap);
  }
};

std::vector<uint8_t> russian_fixture() {
  constexpr int width = 1600, height = 360;
  GdiFixture gdi;
  gdi.dc = CreateCompatibleDC(nullptr);
  check(gdi.dc != nullptr, "Russian fixture DC allocation failed");
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  gdi.bitmap = CreateDIBSection(gdi.dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  check(gdi.bitmap != nullptr && pixels != nullptr, "Russian fixture DIB allocation failed");
  const auto old_bitmap = SelectObject(gdi.dc, gdi.bitmap);
  check(old_bitmap != nullptr && old_bitmap != HGDI_ERROR, "Russian fixture bitmap selection failed");
  check(PatBlt(gdi.dc, 0, 0, width, height, WHITENESS) != 0,
        "Russian fixture background failed");
  gdi.font = CreateFontW(-120, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
      RUSSIAN_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
      ANTIALIASED_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
  check(gdi.font != nullptr, "Russian fixture font allocation failed");
  const auto old_font = SelectObject(gdi.dc, gdi.font);
  check(old_font != nullptr && old_font != HGDI_ERROR, "Russian fixture font selection failed");
  check(SetTextColor(gdi.dc, RGB(0, 0, 0)) != CLR_INVALID &&
            SetBkMode(gdi.dc, TRANSPARENT) != 0, "Russian fixture text setup failed");
  const wchar_t text[] = L"\u041f\u0420\u0418\u0412\u0415\u0422 \u041c\u0418\u0420";
  WORD glyphs[sizeof(text) / sizeof(text[0]) - 1]{};
  check(GetGlyphIndicesW(gdi.dc, text, static_cast<int>(sizeof(glyphs) / sizeof(glyphs[0])),
                        glyphs, GGI_MARK_NONEXISTING_GLYPHS) != GDI_ERROR,
        "Russian fixture glyph lookup failed");
  for (const auto glyph : glyphs) check(glyph != 0xffff, "Russian fixture glyph missing");
  RECT rect{80, 40, width - 80, height - 40};
  check(DrawTextW(gdi.dc, text, -1, &rect,
                  DT_SINGLELINE | DT_CENTER | DT_VCENTER | DT_NOPREFIX) > 0 &&
            GdiFlush() != 0, "Russian fixture rendering failed");
  Image image(pixCreate(width, height, 8));
  check(image != nullptr && pixSetResolution(image.get(), 300, 300) == 0,
        "Russian fixture Pix allocation failed");
  const auto* bgra = static_cast<const uint8_t*>(pixels);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const auto* pixel = bgra + (y * width + x) * 4;
      const l_uint32 gray = (77u * pixel[2] + 150u * pixel[1] + 29u * pixel[0]) >> 8;
      check(pixSetPixel(image.get(), x, y, gray) == 0, "Russian fixture pixel failed");
    }
  }
  l_uint8* encoded = nullptr;
  size_t size = 0;
  const int error = pixWriteMemPng(&encoded, &size, image.get(), 0);
  std::unique_ptr<l_uint8, LeptFree> owner(encoded);
  check(error == 0 && encoded != nullptr && size > 0 && size <= 1048576,
        "Russian fixture PNG encoding failed");
  return {encoded, encoded + size};
}
#endif

struct Fixtures {
  std::vector<uint8_t> pdf;
  std::vector<uint8_t> png;
};

Fixtures fixtures() {
  Library library;
  Handle<FPDF_DOCUMENT, FPDF_CloseDocument> document(FPDF_CreateNewDocument());
  Handle<FPDF_FONT, FPDFFont_Close> font(
      FPDFText_LoadStandardFont(document.value, "Helvetica"));
  const unsigned short hello[] = {'H', 'E', 'L', 'L', 'O', 0};
  const unsigned short second[] = {'S', 'E', 'C', 'O', 'N', 'D', 0};
  Fixtures result;
  for (int index = 0; index < 2; ++index) {
    Handle<FPDF_PAGE, FPDF_ClosePage> page(
        FPDFPage_New(document.value, index, 360, 144));
    Handle<FPDF_PAGEOBJECT, FPDFPageObj_Destroy> text(
        FPDFPageObj_CreateTextObj(document.value, font.value, 36));
    check(FPDFText_SetText(text.value, index == 0 ? hello : second) != 0,
          "PDFium fixture text failed");
    check(FPDFPageObj_SetFillColor(text.value, 0, 0, 0, 255) != 0,
          "PDFium fixture text color failed");
    FPDFPageObj_Transform(text.value, 1, 0, 0, 1, 54, 60);
    FPDFPage_InsertObject(page.value, text.value);
    text.value = nullptr;
    check(FPDFPage_GenerateContent(page.value) != 0, "PDF content generation failed");
    if (index == 0) {
      constexpr int width = 1440, height = 576;
      Handle<FPDF_BITMAP, FPDFBitmap_Destroy> bitmap(
          FPDFBitmap_Create(width, height, 0));
      FPDFBitmap_FillRect(bitmap.value, 0, 0, width, height, 0xffffffff);
      FPDF_RenderPageBitmap(bitmap.value, page.value, 0, 0, width, height, 0, 0);
      Image image(pixCreate(width, height, 8));
      check(image != nullptr, "PNG fixture allocation failed");
      check(pixSetResolution(image.get(), 288, 288) == 0, "PNG resolution failed");
      const auto* buffer = static_cast<const uint8_t*>(FPDFBitmap_GetBuffer(bitmap.value));
      check(buffer != nullptr && FPDFBitmap_GetFormat(bitmap.value) == FPDFBitmap_BGRx,
            "Unexpected PDFium fixture bitmap format");
      const int stride = FPDFBitmap_GetStride(bitmap.value);
      for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
          check(pixSetPixel(image.get(), x, y, buffer[y * stride + x * 4]) == 0,
                "PNG fixture pixel failed");
        }
      }
      l_uint8* encoded = nullptr;
      size_t size = 0;
      const int error = pixWriteMemPng(&encoded, &size, image.get(), 0);
      std::unique_ptr<l_uint8, LeptFree> owner(encoded);
      check(error == 0 && encoded && size > 0 && size <= 1048576,
            "PNG fixture encoding failed");
      result.png.assign(encoded, encoded + size);
    }
  }
  Writer writer;
  check(FPDF_SaveAsCopy(document.value, &writer, FPDF_NO_INCREMENTAL) != 0 &&
            writer.data.size() > 16, "PDF fixture save failed");
  result.pdf = std::move(writer.data);
  return result;
}

std::vector<uint8_t> read_data(const char* path) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  check(input.is_open(), "Cannot open configured traineddata");
  const auto size = input.tellg();
  check(size > 0 && size <= 16777216, "Traineddata outside 16 MiB bound");
  std::vector<uint8_t> result(static_cast<size_t>(size));
  input.seekg(0);
  check(static_cast<bool>(input.read(reinterpret_cast<char*>(result.data()),
                                    static_cast<std::streamsize>(result.size()))),
        "Incomplete traineddata read");
  check(input.peek() == std::char_traits<char>::eof() && !input.bad(),
        "Traineddata changed or read failed");
  return result;
}

void error_is(const Result& result, Error error, const char* message) {
  check(result.error == error && result.pages.empty() && result.page_count == 0, message);
}

void content_is(const Result& result, int count, int number, const char* text,
                const char* message) {
  check(result.error == Error::none && result.page_count == count &&
            result.pages.size() == 1 && result.pages[0].number == number &&
            result.pages[0].text.find(text) != std::string::npos, message);
}

void run() {
  Request request;
  error_is(process(request, {}, {}), Error::invalid_request, "Empty request accepted");
  const uint8_t invalid[] = {'n', 'o', 't', ' ', 'p', 'd', 'f', '!'};
  request.source = {invalid, sizeof(invalid)};
  error_is(process(request, {}, {}), Error::invalid_document, "Malformed PDF accepted");
  request.limits.output_bytes = 1048577;
  error_is(process(request, {}, {}), Error::invalid_request, "Output ceiling accepted");
  Limits limits;
  size_t total = 0;
  for (int i = 0; i < 5; ++i) check_pixels(2000, 2000, limits, total);
  try {
    check_pixels(1, 1, limits, total);
    check(false, "Cumulative pixel limit not enforced");
  } catch (const Failure& failure) {
    check(failure.error == Error::limit, "Unexpected pixel-limit error");
  }
  std::string text;
  append(text, "abcd", 4, 4);
  try {
    append(text, "e", 1, 4);
    check(false, "Append limit not enforced");
  } catch (const Failure& failure) {
    check(failure.error == Error::limit && text == "abcd", "Append limit changed output");
  }

  const auto fixture = fixtures();
  const auto eng = read_data(DOCUMENTS_ENG_DATA);
  const auto rus = read_data(DOCUMENTS_RUS_DATA);
  request = Request{};
  request.source = bytes(fixture.pdf);
  content_is(process(request, {}, {}), 2, 1, "HELLO", "PDF text/provenance failed");
  request.first_page = 2;
  content_is(process(request, {}, {}), 2, 2, "SECOND", "PDF page selection failed");
  request.first_page = 1;
  request.page_count = 2;
  const auto both = process(request, {}, {});
  check(both.error == Error::none && both.page_count == 2 && both.pages.size() == 2 &&
            both.pages[0].number == 1 && both.pages[1].number == 2 &&
            both.pages[0].text.find("HELLO") != std::string::npos &&
            both.pages[1].text.find("SECOND") != std::string::npos,
        "PDF multi-page ordering/content failed");
  request.limits.output_bytes = both.pages[0].text.size();
  error_is(process(request, {}, {}), Error::limit, "PDF aggregate output not bounded");
  request.limits = Limits{};
  request.first_page = 2;
  error_is(process(request, {}, {}), Error::invalid_request, "PDF range overflow accepted");
  request.first_page = 3;
  request.page_count = 1;
  error_is(process(request, {}, {}), Error::invalid_request, "Missing PDF page accepted");
  request.first_page = 1;
  request.limits.page_output_bytes = 4;
  error_is(process(request, {}, {}), Error::limit, "PDF page output not bounded");
  request.limits = Limits{};
  request.limits.pdf_pages = 1;
  error_is(process(request, {}, {}), Error::limit, "PDF page count not bounded");
  request.limits = Limits{};
  request.source = {fixture.pdf.data(), 16};
  error_is(process(request, {}, {}), Error::invalid_document, "Truncated real PDF accepted");

  for (const auto operation : {Operation::image_ocr, Operation::pdf_ocr}) {
    request = Request{};
    request.operation = operation;
    request.source = bytes(operation == Operation::image_ocr ? fixture.png : fixture.pdf);
    const int count = operation == Operation::image_ocr ? 1 : 2;
    content_is(process(request, bytes(eng), bytes(rus)), count, 1, "HELLO",
               operation == Operation::image_ocr ? "English PNG OCR failed" : "English PDF OCR failed");
    request.limits.page_output_bytes = 4;
    error_is(process(request, bytes(eng), bytes(rus)), Error::limit, "OCR page output not bounded");
    request.limits = Limits{};
    request.limits.output_bytes = 4;
    error_is(process(request, bytes(eng), bytes(rus)), Error::limit, "OCR total output not bounded");
    request.limits = Limits{};
    error_is(process(request, {}, {}), Error::unavailable, "OCR used ambient language data");
    error_is(process(request, {}, bytes(eng)), Error::unavailable, "English read wrong language slot");
    const std::vector<uint8_t> corrupt(32, 0xff);
    error_is(process(request, bytes(corrupt), bytes(rus)), Error::unavailable,
             "Corrupt English data not rejected safely");
    request.language = Language::rus;
    error_is(process(request, bytes(rus), {}), Error::unavailable, "Russian read wrong language slot");
    error_is(process(request, bytes(eng), bytes(corrupt)), Error::unavailable,
             "Corrupt Russian data not rejected safely");
    request.language = Language::eng;
    content_is(process(request, bytes(eng), bytes(rus)), count, 1, "HELLO",
               "OCR did not recover after failed language initialization");
  }
#ifdef _WIN32
  const auto russian_png = russian_fixture();
  request = Request{};
  request.operation = Operation::image_ocr;
  request.language = Language::rus;
  request.source = bytes(russian_png);
  const char* cyrillic = u8"\u041f\u0420\u0418\u0412\u0415\u0422";
  content_is(process(request, {}, bytes(rus)), 1, 1, cyrillic,
             "Russian-only PNG content/provenance failed");
  error_is(process(request, bytes(eng), {}), Error::unavailable,
           "Russian PNG accepted missing Russian data");
  error_is(process(request, bytes(rus), {}), Error::unavailable,
           "Russian PNG accepted Russian data in English slot");
  error_is(process(request, {}, {}), Error::unavailable,
           "Russian PNG used ambient language data");
  content_is(process(request, {}, bytes(rus)), 1, 1, cyrillic,
             "Russian-only PNG recovery failed");
#endif
}
}

int main() {
  try {
    run();
    std::cout << "PASS: PDF text, PNG/PDF English OCR, provenance and fail-closed limits\n";
#ifdef _WIN32
    std::cout << "PASS: Windows Russian-only PNG OCR, provenance and missing-data rejection\n";
#else
    std::cout << "NOT COVERED: Russian recognition (Windows-only fixture)\n";
#endif
    return EXIT_SUCCESS;
  } catch (const std::exception&) {
    std::cerr << "FAIL: native document test exception\n";
  } catch (const Failure&) {
    std::cerr << "FAIL: unexpected engine failure\n";
  } catch (...) {
    std::cerr << "FAIL: unexpected exception\n";
  }
  return EXIT_FAILURE;
}
