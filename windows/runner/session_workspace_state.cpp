#include "session_workspace.h"

#include <bcrypt.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <cwchar>

namespace workspace {
namespace {
constexpr uint32_t kMagic = 0x3153574d;
constexpr uint32_t kVersion = 2;
constexpr uint32_t kMaxStateBytes = 64 * 1024;

void Append32(std::vector<uint8_t>* out, uint32_t value) {
  for (int i = 0; i < 4; ++i) out->push_back((value >> (i * 8)) & 0xff);
}

void AppendString(std::vector<uint8_t>* out, const std::string& value) {
  Append32(out, static_cast<uint32_t>(value.size()));
  out->insert(out->end(), value.begin(), value.end());
}

bool Read32(const std::vector<uint8_t>& bytes, size_t* at, uint32_t* value) {
  if (*at + 4 > bytes.size()) return false;
  *value = 0;
  for (int i = 0; i < 4; ++i) *value |= bytes[(*at)++] << (i * 8);
  return true;
}

bool ReadString(const std::vector<uint8_t>& bytes, size_t* at,
                std::string* value) {
  uint32_t size = 0;
  if (!Read32(bytes, at, &size) || size > 4096 || *at + size > bytes.size()) {
    return false;
  }
  value->assign(reinterpret_cast<const char*>(bytes.data() + *at), size);
  *at += size;
  return true;
}

std::wstring StateName(const std::string& id) {
  return std::wstring(id.begin(), id.end()) + L".state";
}

bool CleanupStateTemps(const Node& hidden, const std::string& id) {
  const auto prefix = StateName(id) + L".";
  const auto pattern = Join(hidden.path, prefix + L"*.tmp");
  if (FlushFileBuffers(hidden.handle.value) == FALSE) return false;
  WIN32_FIND_DATAW data{};
  HANDLE raw = FindFirstFileW(pattern.c_str(), &data);
  if (raw == INVALID_HANDLE_VALUE) return true;
  size_t count = 0;
  bool ok = true;
  do {
    const std::wstring name(data.cFileName);
    if (++count > 16 || name.rfind(prefix, 0) != 0 ||
        name.size() < prefix.size() + 4 ||
        name.substr(name.size() - 4) != L".tmp") {
      ok = false;
      break;
    }
    const auto path = Join(hidden.path, name);
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & (FILE_ATTRIBUTE_DIRECTORY |
                       FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
        !DeleteFileW(path.c_str())) {
      ok = false;
      break;
    }
  } while (FindNextFileW(raw, &data));
  const DWORD final_error = GetLastError();
  FindClose(raw);
  return ok && final_error == ERROR_NO_MORE_FILES &&
         FlushFileBuffers(hidden.handle.value) != FALSE;
}

bool DeleteTemporary(const Node& hidden, const std::wstring& name) {
  const auto path = Join(hidden.path, name);
  const DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) return true;
  return (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ==
             0 &&
         DeleteFileW(path.c_str()) != FALSE;
}

bool ReplaceStateFile(const std::wstring& state_path,
                      const std::wstring& temporary_path) {
  const DWORD attributes = GetFileAttributesW(state_path.c_str());
  if (attributes != INVALID_FILE_ATTRIBUTES &&
      (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
    if (ReplaceFileW(state_path.c_str(), temporary_path.c_str(), nullptr,
                     REPLACEFILE_WRITE_THROUGH, nullptr, nullptr)) {
      return true;
    }
  }
  return MoveFileExW(temporary_path.c_str(), state_path.c_str(),
                     MOVEFILE_WRITE_THROUGH | MOVEFILE_REPLACE_EXISTING) !=
         FALSE;
}
}  // namespace

bool RandomToken(std::string* token) {
  std::array<uint8_t, 32> bytes{};
  if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    return false;
  }
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  token->clear();
  uint32_t bits = 0;
  int count = 0;
  for (uint8_t byte : bytes) {
    bits = (bits << 8) | byte;
    count += 8;
    while (count >= 6) {
      count -= 6;
      token->push_back(alphabet[(bits >> count) & 63]);
    }
  }
  if (count) token->push_back(alphabet[(bits << (6 - count)) & 63]);
  return token->size() == 43;
}

bool SaveOperationState(const Node& hidden, const std::string& id,
                         const OperationState& state) {
  if (!CleanupStateTemps(hidden, id)) return false;
  std::vector<uint8_t> bytes;
  Append32(&bytes, kMagic);
  Append32(&bytes, kVersion);
  Append32(&bytes, static_cast<uint32_t>(state.phase));
  for (const auto* value : {&state.token, &state.root_identity,
                            &state.session_identity, &state.session_key,
                            &state.operation, &state.path,
                            &state.destination}) {
    AppendString(&bytes, *value);
  }
  bytes.push_back(state.has_destination ? 1 : 0);
  Append32(&bytes, static_cast<uint32_t>(state.proof.size()));
  for (const auto& pair : state.proof) {
    auto key = std::get_if<std::string>(&pair.first);
    if (!key) return false;
    AppendString(&bytes, *key);
    if (auto text = std::get_if<std::string>(&pair.second)) {
      bytes.push_back(1); AppendString(&bytes, *text);
    } else if (auto boolean = std::get_if<bool>(&pair.second)) {
      bytes.push_back(2); bytes.push_back(*boolean ? 1 : 0);
    } else if (auto integer = std::get_if<int64_t>(&pair.second)) {
      bytes.push_back(3); AppendString(&bytes, std::to_string(*integer));
    } else if (std::holds_alternative<std::monostate>(pair.second)) {
      bytes.push_back(0);
    } else {
      return false;
    }
  }
  if (bytes.size() > kMaxStateBytes) return false;
  Node file;
  std::string hash;
  std::string nonce;
  if (!RandomToken(&nonce)) return false;
  auto temporary = StateName(id) + L"." +
                   std::wstring(nonce.begin(), nonce.end()) + L".tmp";
  if (!WriteFileExact(hidden, temporary, bytes, &file, &hash)) return false;
  file.handle.Reset();
  const auto temporary_path = Join(hidden.path, temporary);
  const auto state_path = Join(hidden.path, StateName(id));
  if (!ReplaceStateFile(state_path, temporary_path)) {
    DeleteTemporary(hidden, temporary);
    return false;
  }
  return FlushFileBuffers(hidden.handle.value) != FALSE;
}

bool LoadOperationState(const Node& hidden, const std::string& id,
                         const std::string& token, OperationState* state) {
  const char* error = nullptr;
  Node file;
  if (!OpenChild(hidden, StateName(id), GENERIC_READ, false, &file, false,
                 &error)) return false;
  uint64_t size = 0; std::string hash;
  if (!HashExact(&file, &hash, &size) || size > kMaxStateBytes) return false;
  std::vector<uint8_t> bytes(static_cast<size_t>(size));
  LARGE_INTEGER zero{}; DWORD read = 0;
  if (!SetFilePointerEx(file.handle.value, zero, nullptr, FILE_BEGIN) ||
      (size && (!ReadFile(file.handle.value, bytes.data(),
                          static_cast<DWORD>(bytes.size()), &read,
                          nullptr) || read != bytes.size()))) return false;
  size_t at = 0; uint32_t magic = 0, version = 0, phase = 0, count = 0;
  if (!Read32(bytes, &at, &magic) || magic != kMagic ||
      !Read32(bytes, &at, &version) || version != kVersion ||
      !Read32(bytes, &at, &phase) || phase < 1 || phase > 6 ||
      !ReadString(bytes, &at, &state->token) || state->token != token ||
      !ReadString(bytes, &at, &state->root_identity) ||
      !ReadString(bytes, &at, &state->session_identity) ||
      !ReadString(bytes, &at, &state->session_key) ||
      !ReadString(bytes, &at, &state->operation) ||
      !ReadString(bytes, &at, &state->path) ||
      !ReadString(bytes, &at, &state->destination) || at >= bytes.size()) {
    return false;
  }
  state->phase = static_cast<OperationPhase>(phase);
  state->has_destination = bytes[at++] == 1;
  if (!Read32(bytes, &at, &count) || count > 32) return false;
  state->proof.clear();
  for (uint32_t i = 0; i < count; ++i) {
    std::string key, value;
    if (!ReadString(bytes, &at, &key) || at >= bytes.size()) return false;
    uint8_t type = bytes[at++];
    if (type == 0) state->proof[Value(key)] = Value();
    else if (type == 1 && ReadString(bytes, &at, &value))
      state->proof[Value(key)] = Value(value);
    else if (type == 2 && at < bytes.size())
      state->proof[Value(key)] = Value(bytes[at++] != 0);
    else if (type == 3 && ReadString(bytes, &at, &value))
      state->proof[Value(key)] = Value(static_cast<int64_t>(std::stoll(value)));
    else return false;
  }
  if (at != bytes.size()) return false;
  file.handle.Reset();
  return true;
}

bool DeleteOperationState(const Node& hidden, const std::string& id) {
  const char* error = nullptr; Node file;
  if (!OpenChild(hidden, StateName(id), DELETE, false, &file, true, &error)) {
    return false;
  }
  return !file.handle.valid() || DeleteNode(&file, false);
}

bool RenameHandleRelative(Node* source, const Node& parent,
                          const std::wstring& name, bool replace) {
  const size_t bytes = sizeof(FILE_RENAME_INFO) + name.size() * sizeof(wchar_t);
  std::vector<uint8_t> storage(bytes);
  auto* info = reinterpret_cast<FILE_RENAME_INFO*>(storage.data());
  info->ReplaceIfExists = replace ? TRUE : FALSE;
  info->RootDirectory = parent.handle.value;
  info->FileNameLength = static_cast<DWORD>(name.size() * sizeof(wchar_t));
  memcpy(info->FileName, name.data(), info->FileNameLength);
  return SetFileInformationByHandle(source->handle.value, FileRenameInfo, info,
                                    static_cast<DWORD>(bytes)) != FALSE;
}
}  // namespace workspace
