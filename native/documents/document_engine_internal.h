#pragma once

#include "document_engine.h"
#include <memory>
#include <stdexcept>
#include <leptonica/allheaders.h>

namespace mobilka::documents {

struct Failure { Error error; };
inline void require(bool condition, Error error) {
  if (!condition) throw Failure{error};
}

struct PixDeleter {
  void operator()(Pix* value) const { pixDestroy(&value); }
};
using Image = std::unique_ptr<Pix, PixDeleter>;

void check_pixels(int width, int height, const Limits& limits, size_t& total);
void append(std::string& text, const char* bytes, size_t size, size_t limit);
std::string recognize(Pix* image, Language language, Bytes eng, Bytes rus, size_t limit);
Result process_pdf(const Request& request, Bytes eng, Bytes rus);
Result process_image(const Request& request, Bytes eng, Bytes rus);

}
