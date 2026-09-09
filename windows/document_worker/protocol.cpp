#include <windows.h>
#include <bcrypt.h>

#include <array>
#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <limits>
#include <string>
#include <vector>

#include "document_engine.h"

namespace {
constexpr size_t kHeader = 108;
constexpr size_t kMaxSource = 10 * 1024 * 1024;
constexpr size_t kMaxResponse = 1024 * 1024;

uint16_t U16(const uint8_t* p) { return uint16_t(p[0]) << 8 | p[1]; }
uint32_t U32(const uint8_t* p) {
  return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 |
         uint32_t(p[2]) << 8 | p[3];
}
void Put32(std::vector<uint8_t>& out, uint32_t value) {
  out.push_back(static_cast<uint8_t>(value >> 24));
  out.push_back(static_cast<uint8_t>(value >> 16));
  out.push_back(static_cast<uint8_t>(value >> 8));
  out.push_back(static_cast<uint8_t>(value));
}
bool ReadExact(HANDLE handle, void* destination, size_t length) {
  auto* cursor = static_cast<uint8_t*>(destination);
  while (length) {
    DWORD read = 0;
    const DWORD part = static_cast<DWORD>((std::min)(length, size_t{65536}));
    if (!ReadFile(handle, cursor, part, &read, nullptr) || read == 0) return false;
    cursor += read;
    length -= read;
  }
  return true;
}
bool WriteExact(HANDLE handle, const void* source, size_t length) {
  const auto* cursor = static_cast<const uint8_t*>(source);
  while (length) {
    DWORD written = 0;
    const DWORD part = static_cast<DWORD>((std::min)(length, size_t{65536}));
    if (!WriteFile(handle, cursor, part, &written, nullptr) || written == 0) return false;
    cursor += written;
    length -= written;
  }
  return true;
}
std::vector<uint8_t> ReadData(const wchar_t* name, size_t ceiling) {
  std::array<wchar_t, 32768> module{};
  const DWORD count = GetModuleFileNameW(nullptr, module.data(),
                                         static_cast<DWORD>(module.size()));
  if (!count || count == static_cast<DWORD>(module.size())) return {};
  const auto path = std::filesystem::path(module.data()).parent_path() / name;
  std::error_code error;
  const auto size = std::filesystem::file_size(path, error);
  if (error || size == 0 || size > ceiling) return {};
  std::ifstream stream(path, std::ios::binary);
  std::vector<uint8_t> bytes(static_cast<size_t>(size));
  if (!stream.read(reinterpret_cast<char*>(bytes.data()),
                   static_cast<std::streamsize>(bytes.size()))) return {};
  return bytes;
}
void Frame(std::vector<uint8_t>& out, const uint8_t* job, uint8_t kind,
           uint32_t index, uint32_t page, uint8_t status, uint32_t width,
           uint32_t height, const std::string& text) {
  Put32(out, static_cast<uint32_t>(47 + text.size()));
  out.push_back(1); out.push_back(kind);
  out.insert(out.end(), job, job + 16);
  Put32(out, index); Put32(out, page); Put32(out, 0); out.push_back(status);
  Put32(out, 0); Put32(out, width); Put32(out, height);
  Put32(out, static_cast<uint32_t>(text.size()));
  out.insert(out.end(), text.begin(), text.end());
}
}  // namespace

int RunDocumentWorker(HANDLE input, HANDLE output) {
  std::array<uint8_t, kHeader> header{};
  if (!ReadExact(input, header.data(), header.size()) ||
      header[0] != 'M' || header[1] != 'D' || header[2] != 'W' || header[3] != 1)
    return 72;
  const uint32_t source_size = U32(header.data() + 60);
  if (source_size == 0 || source_size > kMaxSource ||
      header[52] > 2 || header[53] > 2 || U16(header.data() + 58) != 0)
    return 73;
  std::array<uint32_t, 10> limits{};
  const std::array<uint32_t, 10> ceilings = {10485760,100,25,4096,4000000,
      20000000,262144,1048576,120000,65536};
  for (size_t i = 0; i < limits.size(); ++i) {
    limits[i] = U32(header.data() + 64 + i * 4);
    if (!limits[i] || limits[i] > ceilings[i]) return 74;
  }
  if (source_size > limits[0]) return 75;
  std::vector<uint8_t> source(source_size);
  if (!ReadExact(input, source.data(), source.size())) return 76;
  std::array<uint8_t, 32> digest{};
  BCRYPT_ALG_HANDLE sha256 = nullptr;
  if (BCryptOpenAlgorithmProvider(&sha256, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0 ||
      BCryptHash(sha256, nullptr, 0,
                 source.data(), static_cast<ULONG>(source.size()),
                  digest.data(), static_cast<ULONG>(digest.size())) < 0) {
    if (sha256) BCryptCloseAlgorithmProvider(sha256, 0);
    return 77;
  }
  BCryptCloseAlgorithmProvider(sha256, 0);
  if (!std::equal(digest.begin(), digest.end(), header.begin() + 20)) return 77;

  using namespace mobilka::documents;
  Request request;
  request.operation = static_cast<Operation>(header[52]);
  request.language = static_cast<Language>(header[53]);
  request.first_page = U16(header.data() + 54);
  request.page_count = U16(header.data() + 56);
  request.limits = {limits[0], static_cast<int>(limits[1]),
      static_cast<int>(limits[2]), static_cast<int>(limits[3]), limits[4],
      limits[5], limits[6], limits[7]};
  request.source = {source.data(), source.size()};
  auto eng = ReadData(L"eng.traineddata", 32 * 1024 * 1024);
  auto rus = ReadData(L"rus.traineddata", 32 * 1024 * 1024);
  const Result result = process(request, {eng.data(), eng.size()}, {rus.data(), rus.size()});
  std::vector<uint8_t> response;
  uint32_t index = 0;
  for (const auto& page : result.pages) {
    if (page.text.size() > limits[6]) return 78;
    Frame(response, header.data() + 4, 1, index++, page.number, 0,
          page.width, page.height, page.text);
    if (response.size() > kMaxResponse) return 79;
  }
  Frame(response, header.data() + 4, 2, index, 0,
        static_cast<uint8_t>(result.error), 0, 0, "");
  if (response.size() > limits[7] || response.size() > kMaxResponse) return 80;
  return WriteExact(output, response.data(), response.size()) ? 0 : 81;
}
