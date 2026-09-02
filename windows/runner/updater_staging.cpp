#include "updater_staging.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <bcrypt.h>

#include <array>
#include <cstddef>
#include <cstring>
#include <iomanip>
#include <map>
#include <memory>
#include <random>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

namespace {
const std::wregex kGenerated(LR"(^mobilka-\d+\.\d+\.\d+-(android|windows)-[A-Za-z0-9_-]+-[0-9a-f]+\.(apk|msi)(\.part)?$)");

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return L"";
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) return L"";
  std::wstring result(size, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(), size) != size) return L"";
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return "";
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return "";
  std::string result(size, '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), size, nullptr, nullptr) != size) return "";
  return result;
}

class Handle {
 public:
  explicit Handle(HANDLE value = INVALID_HANDLE_VALUE) : value_(value) {}
  ~Handle() { Close(); }
  Handle(Handle&& other) noexcept : value_(other.value_) { other.value_ = INVALID_HANDLE_VALUE; }
  Handle& operator=(Handle&& other) noexcept {
    if (this != &other) { Close(); value_ = other.value_; other.value_ = INVALID_HANDLE_VALUE; }
    return *this;
  }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  void Close() { if (value_ != INVALID_HANDLE_VALUE) { CloseHandle(value_); value_ = INVALID_HANDLE_VALUE; } }
  HANDLE get() const { return value_; }
  bool valid() const { return value_ != INVALID_HANDLE_VALUE; }
 private: HANDLE value_;
};

Handle OpenNoFollow(const std::wstring& path, DWORD access, DWORD creation,
                    bool directory = false,
                    DWORD share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE) {
  return Handle(CreateFileW(path.c_str(), access, share, nullptr, creation,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT |
          (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), nullptr));
}

bool Stable(HANDLE handle, bool directory) {
  BY_HANDLE_FILE_INFORMATION info{};
  return GetFileInformationByHandle(handle, &info) &&
      !!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == directory &&
      !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
      (directory || info.nNumberOfLinks == 1);
}

bool ValidateComponents(const std::wstring& path) {
  if (path.size() < 3 || path[1] != L':' || path[2] != L'\\') return false;
  size_t position = 3;
  while (position < path.size()) {
    position = path.find(L'\\', position);
    Handle handle = OpenNoFollow(path.substr(0, position), FILE_READ_ATTRIBUTES,
                                 OPEN_EXISTING, true);
    if (!handle.valid()) return false;
    BY_HANDLE_FILE_INFORMATION info{};
    if (!GetFileInformationByHandle(handle.get(), &info) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    if (position == std::wstring::npos) break;
    ++position;
  }
  return true;
}

bool SafeName(const std::wstring& name) {
  return std::regex_match(name, kGenerated) && name.find(L'\\') == std::wstring::npos &&
         name.find(L'/') == std::wstring::npos;
}

std::string Token(const BY_HANDLE_FILE_INFORMATION& info) {
  return std::to_string(info.dwVolumeSerialNumber) + ":" +
      std::to_string(info.nFileIndexHigh) + ":" + std::to_string(info.nFileIndexLow);
}

struct DownloadSession {
  Handle root;
  Handle file;
  std::wstring path;
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  std::vector<UCHAR> object;
  uint64_t size = 0;
  ~DownloadSession() { if (hash) BCryptDestroyHash(hash); if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0); }
};
std::map<std::string, std::unique_ptr<DownloadSession>> sessions;

std::string RandomId() {
  std::array<unsigned char, 16> bytes{};
  if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return "";
  std::ostringstream out;
  for (auto byte : bytes) out << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(byte);
  return out.str();
}

bool InitHash(DownloadSession* session) {
  DWORD object_size = 0, result = 0;
  if (BCryptOpenAlgorithmProvider(&session->algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0 ||
      BCryptGetProperty(session->algorithm, BCRYPT_OBJECT_LENGTH,
          reinterpret_cast<PUCHAR>(&object_size), sizeof(object_size), &result, 0) != 0) return false;
  session->object.resize(object_size);
  return BCryptCreateHash(session->algorithm, &session->hash, session->object.data(), object_size,
                          nullptr, 0, 0) == 0;
}

flutter::EncodableMap Identity(HANDLE file, const std::wstring& name,
                               const std::string& hash) {
  BY_HANDLE_FILE_INFORMATION info{};
  GetFileInformationByHandle(file, &info);
  ULARGE_INTEGER size{}; size.HighPart = info.nFileSizeHigh; size.LowPart = info.nFileSizeLow;
  ULARGE_INTEGER time{}; time.HighPart = info.ftLastWriteTime.dwHighDateTime;
  time.LowPart = info.ftLastWriteTime.dwLowDateTime;
  const int64_t millis = static_cast<int64_t>((time.QuadPart - 116444736000000000ULL) / 10000ULL);
  return {{flutter::EncodableValue("basename"), flutter::EncodableValue(WideToUtf8(name))},
          {flutter::EncodableValue("size"), flutter::EncodableValue(static_cast<int64_t>(size.QuadPart))},
          {flutter::EncodableValue("modifiedMillis"), flutter::EncodableValue(millis)},
          {flutter::EncodableValue("sha256"), flutter::EncodableValue(hash)},
          {flutter::EncodableValue("identityToken"), flutter::EncodableValue(Token(info))}};
}

std::string HashHandle(HANDLE file) {
  LARGE_INTEGER zero{};
  if (!SetFilePointerEx(file, zero, nullptr, FILE_BEGIN)) return "";
  BCRYPT_ALG_HANDLE algorithm = nullptr; BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0, result = 0; std::vector<UCHAR> object; std::array<UCHAR, 32> digest{};
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return "";
  if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_size),
                        sizeof(object_size), &result, 0) != 0) {
    BCryptCloseAlgorithmProvider(algorithm, 0); return "";
  }
  object.resize(object_size);
  if (BCryptCreateHash(algorithm, &hash, object.data(), object_size,
                       nullptr, 0, 0) != 0) {
    BCryptCloseAlgorithmProvider(algorithm, 0); return "";
  }
  std::array<UCHAR, 65536> buffer{}; DWORD read = 0;
  bool ok = true;
  do {
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &read, nullptr)) { ok = false; break; }
    if (read && BCryptHashData(hash, buffer.data(), read, 0) != 0) {
      ok = false; break;
    }
  } while (read);
  if (ok) ok = BCryptFinishHash(hash, digest.data(),
                                static_cast<ULONG>(digest.size()), 0) == 0;
  BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(algorithm, 0);
  if (!ok) return "";
  std::ostringstream out; for (auto byte : digest) out << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(byte);
  return out.str();
}

std::wstring StringArg(const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return L"";
  const auto* value = std::get_if<std::string>(&it->second);
  return value ? Utf8ToWide(*value) : L"";
}

int64_t IntArg(const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return -1;
  if (const auto* value = std::get_if<int64_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  return -1;
}

bool IsMsiName(const std::wstring& name, bool allow_part) {
  if (!std::regex_match(name, kGenerated)) return false;
  const bool part = name.size() > 5 &&
                    name.compare(name.size() - 5, 5, L".part") == 0;
  const size_t extension = part ? name.size() - 9 : name.size() - 4;
  return name.compare(extension, 4, L".msi") == 0 && (allow_part || !part);
}

void Register(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.rslnmzhn.mobilka/windows_updater_staging", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "getTrustedSystemPaths") {
      std::array<wchar_t, MAX_PATH + 1> system{};
      const UINT length = GetSystemDirectoryW(system.data(), static_cast<UINT>(system.size()));
      if (!length || length >= system.size()) { result->Error("systemPath", "System directory unavailable"); return; }
      const std::wstring root(system.data(), length);
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("powershell"), flutter::EncodableValue(WideToUtf8(root + L"\\WindowsPowerShell\\v1.0\\powershell.exe"))},
          {flutter::EncodableValue("msiexec"), flutter::EncodableValue(WideToUtf8(root + L"\\msiexec.exe"))}}));
      return;
    }
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) { result->Error("invalidArgument", "Arguments required"); return; }
    const auto method = call.method_name();
    if (method == "writeDownload" || method == "finishDownload" || method == "abortDownload") {
      const auto session_id = WideToUtf8(StringArg(*args, "session"));
      auto found = sessions.find(session_id);
      if (found == sessions.end()) { result->Error("invalidSession", "Unknown download session"); return; }
      auto* session = found->second.get();
      if (method == "writeDownload") {
        auto chunk_it = args->find(flutter::EncodableValue("chunk"));
        const auto* chunk = chunk_it == args->end() ? nullptr : std::get_if<std::vector<uint8_t>>(&chunk_it->second);
        DWORD written = 0;
        if (!chunk || !WriteFile(session->file.get(), chunk->data(), static_cast<DWORD>(chunk->size()), &written, nullptr) || written != chunk->size() ||
            BCryptHashData(session->hash, const_cast<PUCHAR>(chunk->data()), static_cast<ULONG>(chunk->size()), 0) != 0) {
          result->Error("writeFailed", "Native download write failed"); return;
        }
        session->size += written; result->Success(); return;
      }
      if (method == "finishDownload") {
        std::array<UCHAR, 32> digest{};
        if (!FlushFileBuffers(session->file.get()) || BCryptFinishHash(session->hash, digest.data(), static_cast<ULONG>(digest.size()), 0) != 0) {
          result->Error("finishFailed", "Native download finish failed"); return;
        }
        std::ostringstream hash;
        for (auto byte : digest) hash << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(byte);
        const auto name = session->path.substr(session->path.find_last_of(L'\\') + 1);
        result->Success(flutter::EncodableValue(Identity(session->file.get(), name, hash.str())));
        sessions.erase(found); return;
      }
      FILE_DISPOSITION_INFO disposition{TRUE};
      if (!SetFileInformationByHandle(session->file.get(), FileDispositionInfo,
                                      &disposition, sizeof(disposition))) {
        result->Error("abortFailed", "Native download abort failed"); return;
      }
      sessions.erase(found); result->Success(); return;
    }

    const auto root = StringArg(*args, "updatesRoot");
    const auto name = StringArg(*args, "basename");
    const auto separator = root.find_last_of(L'\\');
    const auto parent = separator == std::wstring::npos ? L"" : root.substr(0, separator);
    if (!ValidateComponents(parent)) { result->Error("unsafePath", "Unsafe updates ancestor"); return; }
    if (GetFileAttributesW(root.c_str()) == INVALID_FILE_ATTRIBUTES && !CreateDirectoryW(root.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
      result->Error("unsafePath", "Could not create updates root"); return;
    }
    Handle root_handle = OpenNoFollow(root, FILE_LIST_DIRECTORY, OPEN_EXISTING, true);
    if (!ValidateComponents(root) || !root_handle.valid() || !Stable(root_handle.get(), true)) {
      result->Error("unsafePath", "Unsafe updates root"); return;
    }
    if (method == "safeList") {
      flutter::EncodableList entries; WIN32_FIND_DATAW data{};
      HANDLE search = FindFirstFileW((root + L"\\*").c_str(), &data);
      if (search != INVALID_HANDLE_VALUE) {
        do {
          const std::wstring child_name(data.cFileName);
          if (!SafeName(child_name) || !IsMsiName(child_name, true)) continue;
          Handle file = OpenNoFollow(root + L"\\" + child_name, GENERIC_READ, OPEN_EXISTING);
          if (file.valid() && Stable(file.get(), false)) entries.emplace_back(Identity(file.get(), child_name, HashHandle(file.get())));
        } while (FindNextFileW(search, &data));
        FindClose(search);
      }
      result->Success(flutter::EncodableValue(entries)); return;
    }
    if (method == "verifyUpdate") {
      const int64_t expected_size = IntArg(*args, "expectedSize");
      const std::string expected_hash =
          WideToUtf8(StringArg(*args, "expectedSha256"));
      if (expected_size < 0 || expected_hash.size() != 64 ||
          !IsMsiName(name, true)) {
        result->Success(); return;
      }
      Handle file = OpenNoFollow(root + L"\\" + name, GENERIC_READ,
                                 OPEN_EXISTING);
      BY_HANDLE_FILE_INFORMATION info{};
      if (!file.valid() || !Stable(file.get(), false) ||
          !GetFileInformationByHandle(file.get(), &info)) {
        result->Success(); return;
      }
      ULARGE_INTEGER size{};
      size.HighPart = info.nFileSizeHigh;
      size.LowPart = info.nFileSizeLow;
      const std::string hash = HashHandle(file.get());
      const std::string expected_identity =
          WideToUtf8(StringArg(*args, "identityToken"));
      if (size.QuadPart != static_cast<uint64_t>(expected_size) ||
          hash != expected_hash ||
          (!expected_identity.empty() && Token(info) != expected_identity)) {
        result->Success(); return;
      }
      result->Success(flutter::EncodableValue(Identity(file.get(), name, hash)));
      return;
    }
    if (method == "finalizeUpdate") {
      const std::wstring partial = StringArg(*args, "partialName");
      const int64_t expected_size = IntArg(*args, "expectedSize");
      const std::string expected_hash =
          WideToUtf8(StringArg(*args, "expectedSha256"));
      if (expected_size < 0 || expected_hash.size() != 64 ||
          !IsMsiName(name, false) || partial != name + L".part" ||
          !IsMsiName(partial, true)) {
        result->Error("invalid", "Unsafe finalize request"); return;
      }
      Handle file = OpenNoFollow(root + L"\\" + partial,
                                 GENERIC_READ | DELETE, OPEN_EXISTING);
      BY_HANDLE_FILE_INFORMATION info{};
      if (!file.valid() || !Stable(file.get(), false) ||
          !GetFileInformationByHandle(file.get(), &info)) {
        result->Error("invalid", "Unsafe partial"); return;
      }
      ULARGE_INTEGER size{};
      size.HighPart = info.nFileSizeHigh;
      size.LowPart = info.nFileSizeLow;
      const std::string hash = HashHandle(file.get());
      if (size.QuadPart != static_cast<uint64_t>(expected_size) ||
          hash != expected_hash) {
        result->Error("invalid", "Partial digest mismatch"); return;
      }
      const DWORD name_bytes = static_cast<DWORD>(name.size() * sizeof(wchar_t));
      std::vector<unsigned char> rename_buffer(
          offsetof(FILE_RENAME_INFO, FileName) + name_bytes);
      auto* rename = reinterpret_cast<FILE_RENAME_INFO*>(rename_buffer.data());
      rename->ReplaceIfExists = FALSE;
      rename->RootDirectory = root_handle.get();
      rename->FileNameLength = name_bytes;
      std::memcpy(rename->FileName, name.data(), name_bytes);
      if (!SetFileInformationByHandle(file.get(), FileRenameInfo, rename,
                                      static_cast<DWORD>(rename_buffer.size()))) {
        result->Error("io", "Atomic finalize failed"); return;
      }
      result->Success(flutter::EncodableValue(Identity(file.get(), name, hash)));
      return;
    }
    if (!SafeName(name)) { result->Error("unsafePath", "Unsafe basename"); return; }
    const auto child = root + L"\\" + name;
    if (method == "beginDownload") {
      if (name.size() < 5 || name.substr(name.size() - 5) != L".part") { result->Error("unsafePath", "Part required"); return; }
      auto session = std::make_unique<DownloadSession>(); session->root = std::move(root_handle); session->path = child;
      session->file = OpenNoFollow(child, GENERIC_READ | GENERIC_WRITE | DELETE, CREATE_NEW, 0);
      const auto id = RandomId();
      if (id.empty() || !session->file.valid() || !Stable(session->file.get(), false) || !InitHash(session.get())) {
        result->Error("createFailed", "Exclusive download creation failed"); return;
      }
      sessions[id] = std::move(session); result->Success(flutter::EncodableValue(id)); return;
    }
    Handle file = OpenNoFollow(child, GENERIC_READ | DELETE, OPEN_EXISTING);
    if (!file.valid() || !Stable(file.get(), false)) { result->Error("unsafePath", "Unsafe staged child"); return; }
    if (method == "delete") {
      BY_HANDLE_FILE_INFORMATION info{}; GetFileInformationByHandle(file.get(), &info);
      ULARGE_INTEGER size{}; size.HighPart = info.nFileSizeHigh; size.LowPart = info.nFileSizeLow;
      const auto expected_token = WideToUtf8(StringArg(*args, "identityToken"));
      const auto expected_hash = WideToUtf8(StringArg(*args, "expectedSha256"));
      if (!IsMsiName(name, true) ||
          IntArg(*args, "expectedSize") != static_cast<int64_t>(size.QuadPart) ||
          expected_token != Token(info) || expected_hash != HashHandle(file.get())) {
        result->Error("identityChanged", "Staged identity changed"); return;
      }
      FILE_DISPOSITION_INFO disposition{TRUE};
      if (!SetFileInformationByHandle(file.get(), FileDispositionInfo, &disposition, sizeof(disposition))) {
        result->Error("deleteFailed", "Handle delete failed"); return;
      }
      result->Success(); return;
    }
    result->Success(flutter::EncodableValue(Identity(file.get(), name, HashHandle(file.get()))));
  });
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> owner;
  owner = std::move(channel);
}
}  // namespace

void RegisterUpdaterStagingChannel(flutter::BinaryMessenger* messenger) { Register(messenger); }
