#include "session_workspace.h"

#include <fcntl.h>
#include <sys/random.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <cstring>

namespace workspace {
namespace {
constexpr uint32_t kMagic = 0x3253574d;
constexpr uint32_t kVersion = 1;
constexpr size_t kMaxStateBytes = 64 * 1024;
constexpr size_t kMaxStringBytes = 4096;

void Append32(std::vector<uint8_t>* out, uint32_t value) {
  for (int i = 0; i < 4; ++i) out->push_back((value >> (i * 8)) & 0xff);
}

void Append64(std::vector<uint8_t>* out, uint64_t value) {
  for (int i = 0; i < 8; ++i) out->push_back((value >> (i * 8)) & 0xff);
}

void AppendString(std::vector<uint8_t>* out, const std::string& value) {
  Append32(out, static_cast<uint32_t>(value.size()));
  out->insert(out->end(), value.begin(), value.end());
}

bool Read32(const std::vector<uint8_t>& bytes, size_t* at, uint32_t* value) {
  if (*at + 4 > bytes.size()) return false;
  *value = 0;
  for (int i = 0; i < 4; ++i) *value |= uint32_t(bytes[(*at)++]) << (i * 8);
  return true;
}

bool Read64(const std::vector<uint8_t>& bytes, size_t* at, uint64_t* value) {
  if (*at + 8 > bytes.size()) return false;
  *value = 0;
  for (int i = 0; i < 8; ++i) *value |= uint64_t(bytes[(*at)++]) << (i * 8);
  return true;
}

bool ReadString(const std::vector<uint8_t>& bytes, size_t* at,
                std::string* value) {
  uint32_t size = 0;
  if (!Read32(bytes, at, &size) || size > kMaxStringBytes ||
      *at + size > bytes.size()) return false;
  value->assign(reinterpret_cast<const char*>(bytes.data() + *at), size);
  *at += size;
  return true;
}

bool WriteAll(int fd, const std::vector<uint8_t>& bytes) {
  size_t at = 0;
  while (at < bytes.size()) {
    ssize_t count = write(fd, bytes.data() + at, bytes.size() - at);
    if (count <= 0) return false;
    at += static_cast<size_t>(count);
  }
  return true;
}

std::string StateName(const std::string& id) { return id + ".state"; }
}  // namespace

bool RandomToken(std::string* token) {
  std::array<uint8_t, 32> bytes{};
  size_t at = 0;
  while (at < bytes.size()) {
    ssize_t count = getrandom(bytes.data() + at, bytes.size() - at, 0);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return false;
    at += static_cast<size_t>(count);
  }
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  token->clear();
  uint32_t bits = 0;
  int available = 0;
  for (uint8_t byte : bytes) {
    bits = (bits << 8) | byte;
    available += 8;
    while (available >= 6) {
      available -= 6;
      token->push_back(alphabet[(bits >> available) & 63]);
    }
  }
  if (available) token->push_back(alphabet[(bits << (6 - available)) & 63]);
  return token->size() == 43;
}

bool SaveOperationState(const Node& hidden, const std::string& id,
                        const OperationState& state) {
  std::vector<uint8_t> bytes;
  Append32(&bytes, kMagic);
  Append32(&bytes, kVersion);
  Append32(&bytes, static_cast<uint32_t>(state.phase));
  uint32_t flags = (state.has_destination ? 1 : 0) |
                   (state.expect_missing ? 2 : 0) |
                   (state.target_directory ? 4 : 0);
  Append32(&bytes, flags);
  Append64(&bytes, state.result_size);
  for (const auto* value : {
           &state.token, &state.root_identity, &state.session_identity,
           &state.session_key, &state.operation, &state.path,
           &state.destination, &state.expected_identity, &state.expected_hash,
           &state.stage_identity, &state.stage_hash, &state.backup_identity,
           &state.backup_hash}) {
    if (value->size() > kMaxStringBytes) return false;
    AppendString(&bytes, *value);
  }
  if (bytes.size() > kMaxStateBytes) return false;

  OperationState current;
  bool state_exists = !MissingAt(hidden.fd.get(), StateName(id));
  bool loaded = LoadOperationState(hidden, id, state.token, &current);
  if (state_exists && !loaded) return false;
  if (loaded && current.phase != state.phase) {
    const bool forward = state.phase == OperationPhase::committed ||
        state.phase == OperationPhase::rolledBack ||
                         (current.phase == OperationPhase::prepared &&
                          (state.phase == OperationPhase::targetQuarantining ||
                           state.phase == OperationPhase::stageInstalling)) ||
                         (current.phase == OperationPhase::targetQuarantining &&
                          state.phase == OperationPhase::targetQuarantined) ||
                         (current.phase == OperationPhase::targetQuarantined &&
                          state.phase == OperationPhase::stageInstalling);
    if (!forward) return false;
  }

  std::array<uint8_t, 8> random{};
  if (getrandom(random.data(), random.size(), 0) !=
      static_cast<ssize_t>(random.size())) return false;
  std::string temporary = id + ".state.tmp.";
  static constexpr char hex[] = "0123456789abcdef";
  for (uint8_t byte : random) {
    temporary.push_back(hex[byte >> 4]);
    temporary.push_back(hex[byte & 15]);
  }
  int fd = openat(hidden.fd.get(), temporary.c_str(),
                  O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) return false;
  bool ok = WriteAll(fd, bytes) && fsync(fd) == 0;
  int saved = errno;
  close(fd);
  errno = saved;
  if (ok) ok = renameat(hidden.fd.get(), temporary.c_str(), hidden.fd.get(),
                        StateName(id).c_str()) == 0 && fsync(hidden.fd.get()) == 0;
  if (!ok) unlinkat(hidden.fd.get(), temporary.c_str(), 0);
  return ok;
}

bool LoadOperationState(const Node& hidden, const std::string& id,
                        const std::string& token, OperationState* state) {
  Node file;
  if (!OpenFileAt(hidden.fd.get(), StateName(id), O_RDONLY, &file) ||
      file.info.st_size < 0 || file.info.st_size > static_cast<off_t>(kMaxStateBytes)) {
    return false;
  }
  std::vector<uint8_t> bytes(static_cast<size_t>(file.info.st_size));
  size_t read_at = 0;
  while (read_at < bytes.size()) {
    ssize_t count = pread(file.fd.get(), bytes.data() + read_at,
                          bytes.size() - read_at, read_at);
    if (count <= 0) return false;
    read_at += static_cast<size_t>(count);
  }
  struct stat after{};
  if (fstat(file.fd.get(), &after) || after.st_size != file.info.st_size ||
      !Same(file.id, {after.st_dev, after.st_ino})) return false;

  size_t at = 0;
  uint32_t magic = 0, version = 0, phase = 0, flags = 0;
  if (!Read32(bytes, &at, &magic) || magic != kMagic ||
      !Read32(bytes, &at, &version) || version != kVersion ||
       !Read32(bytes, &at, &phase) || phase < 1 || phase > 6 ||
      !Read32(bytes, &at, &flags) || (flags & ~7u) != 0 ||
      !Read64(bytes, &at, &state->result_size)) return false;
  state->phase = static_cast<OperationPhase>(phase);
  state->has_destination = (flags & 1) != 0;
  state->expect_missing = (flags & 2) != 0;
  state->target_directory = (flags & 4) != 0;
  for (auto* value : {
           &state->token, &state->root_identity, &state->session_identity,
           &state->session_key, &state->operation, &state->path,
           &state->destination, &state->expected_identity,
           &state->expected_hash, &state->stage_identity, &state->stage_hash,
           &state->backup_identity, &state->backup_hash}) {
    if (!ReadString(bytes, &at, value)) return false;
  }
  return at == bytes.size() && state->token == token && Stable(file, S_IFREG);
}

bool DeleteOperationState(const Node& hidden, const std::string& id) {
  if (unlinkat(hidden.fd.get(), StateName(id).c_str(), 0) != 0 && errno != ENOENT)
    return false;
  return fsync(hidden.fd.get()) == 0;
}
}  // namespace workspace
