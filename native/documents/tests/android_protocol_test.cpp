#include "document_engine.h"

#include <cassert>
#include <cstdint>
#include <vector>

int main() {
  using namespace mobilka::documents;
  std::vector<uint8_t> oversized(Limits{}.source_bytes + 1, 0);
  Request request;
  request.operation = Operation::image_ocr;
  request.source = {oversized.data(), oversized.size()};
  const Result result = process(request, {}, {});
  assert(result.error == Error::invalid_request);
  return 0;
}
