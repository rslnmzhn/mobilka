#include "document_engine_internal.h"
#include <cstdlib>

using namespace mobilka::documents;

int main() {
  Request request;
  if (process(request, {}, {}).error != Error::invalid_request) return EXIT_FAILURE;
  const uint8_t invalid[] = {'n', 'o', 't', ' ', 'p', 'd', 'f', '!'};
  request.source = {invalid, sizeof(invalid)};
  if (process(request, {}, {}).error != Error::invalid_document) return EXIT_FAILURE;
  request.limits.output_bytes = 1048577;
  if (process(request, {}, {}).error != Error::invalid_request) return EXIT_FAILURE;
  Limits limits;
  size_t total = 0;
  for (int i = 0; i < 5; ++i) check_pixels(2000, 2000, limits, total);
  try {
    check_pixels(1, 1, limits, total);
    return EXIT_FAILURE;
  } catch (const Failure& failure) {
    if (failure.error != Error::limit) return EXIT_FAILURE;
  }
  std::string text;
  append(text, "abcd", 4, 4);
  try {
    append(text, "e", 1, 4);
    return EXIT_FAILURE;
  } catch (const Failure& failure) {
    if (failure.error != Error::limit || text != "abcd") return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}
