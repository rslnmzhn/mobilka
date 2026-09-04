#include "session_workspace.h"

#include <algorithm>
#include <array>
#include <bcrypt.h>
#include <climits>
#include <cwctype>
#include <iomanip>
#include <sstream>

namespace workspace {
Handle::~Handle() { Reset(); }
Handle::Handle(Handle &&other) noexcept : value(other.value) {
  other.value = INVALID_HANDLE_VALUE;
}
Handle &Handle::operator=(Handle &&other) noexcept {
  if (this != &other) {
    Reset(other.value);
    other.value = INVALID_HANDLE_VALUE;
  }
  return *this;
}
void Handle::Reset(HANDLE next) {
  if (valid())
    CloseHandle(value);
  value = next;
}
void Error(Result &result, const char *code) {
  result->Error(code, "Workspace operation rejected");
}
const Value *Find(const Map &args, const char *key) {
  auto it = args.find(Value(key));
  return it == args.end() ? nullptr : &it->second;
}
bool StringArg(const Map &args, const char *key, std::string *out) {
  auto p = Find(args, key);
  auto s = p ? std::get_if<std::string>(p) : nullptr;
  if (!s)
    return false;
  *out = *s;
  return true;
}
bool BoolArg(const Map &args, const char *key, bool *out) {
  auto p = Find(args, key);
  auto b = p ? std::get_if<bool>(p) : nullptr;
  if (!b)
    return false;
  *out = *b;
  return true;
}
bool NullableStringArg(const Map &a, const char *k, std::string *o,
                       bool *present) {
  auto p = Find(a, k);
  if (!p || std::holds_alternative<std::monostate>(*p)) {
    *present = false;
    return true;
  }
  auto s = std::get_if<std::string>(p);
  if (!s)
    return false;
  *present = true;
  *o = *s;
  return true;
}
static bool ToWide(const std::string &s, std::wstring *o) {
  if (s.empty()) {
    o->clear();
    return true;
  }
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                              (int)s.size(), nullptr, 0);
  if (n <= 0)
    return false;
  o->resize(n);
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                             (int)s.size(), o->data(), n) == n;
}
static bool Same(Identity a, Identity b) {
  return a.volume == b.volume && a.high == b.high && a.low == b.low;
}
static Identity Id(const BY_HANDLE_FILE_INFORMATION &i) {
  return {i.dwVolumeSerialNumber, i.nFileIndexHigh, i.nFileIndexLow};
}
std::string Token(const Identity &i) {
  return std::to_string(i.volume) + ":" + std::to_string(i.high) + ":" +
         std::to_string(i.low);
}
static bool SafePart(const std::string &s, std::wstring *w) {
  if (s.empty() || s.size() > 128 || s[0] == '.' || s == ".." ||
      !ToWide(s, w) || w->back() == L'.' || w->back() == L' ')
    return false;
  for (auto c : *w)
    if (c < 32 || c == 127 || c == L'/' || c == L'\\' || c == L':')
      return false;
  std::wstring stem = w->substr(0, w->find(L'.'));
  std::transform(stem.begin(), stem.end(), stem.begin(), towupper);
  if (stem == L"CON" || stem == L"PRN" || stem == L"AUX" || stem == L"NUL")
    return false;
  return !(stem.size() == 4 &&
           (stem.substr(0, 3) == L"COM" || stem.substr(0, 3) == L"LPT") &&
           stem[3] >= L'1' && stem[3] <= L'9');
}
bool ParseRelative(const std::string &s, bool root,
                   std::vector<std::wstring> *out) {
  out->clear();
  if (s.empty())
    return root;
  if (s.size() > 1024 || s.front() == '/' || s.back() == '/' ||
      s.find('\\') != std::string::npos || s.find(':') != std::string::npos)
    return false;
  size_t p = 0;
  while (p < s.size()) {
    auto e = s.find('/', p);
    std::wstring w;
    if (!SafePart(s.substr(p, e - p), &w))
      return false;
    out->push_back(w);
    if (out->size() > 16)
      return false;
    if (e == std::string::npos)
      break;
    p = e + 1;
  }
  return true;
}
std::wstring Join(const std::wstring &a, const std::wstring &b) {
  return a + L"\\" + b;
}
static bool Canonical(HANDLE h, std::wstring *out) {
  DWORD n = GetFinalPathNameByHandleW(h, nullptr, 0,
                                      FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!n)
    return false;
  out->resize(n);
  DWORD got = GetFinalPathNameByHandleW(h, out->data(), n,
                                        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (!got || got >= n)
    return false;
  out->resize(got);
  if (out->rfind(L"\\\\?\\UNC\\", 0) == 0)
    *out = L"\\\\" + out->substr(8);
  else if (out->rfind(L"\\\\?\\", 0) == 0)
    *out = out->substr(4);
  return true;
}
static bool Open(const std::wstring &p, DWORD access, bool dir, Node *out,
                 DWORD create = OPEN_EXISTING) {
  DWORD flags =
      FILE_FLAG_OPEN_REPARSE_POINT | (dir ? FILE_FLAG_BACKUP_SEMANTICS : 0);
  Handle h(CreateFileW(p.c_str(), access, FILE_SHARE_READ | FILE_SHARE_WRITE,
                       nullptr, create, flags, nullptr));
  BY_HANDLE_FILE_INFORMATION i{};
  if (!h.valid() || !GetFileInformationByHandle(h.value, &i) ||
      !!(i.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != dir ||
      (i.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      (!dir && i.nNumberOfLinks != 1))
    return false;
  std::wstring actual;
  if (!Canonical(h.value, &actual) ||
      CompareStringOrdinal(actual.data(), (int)actual.size(), p.data(),
                           (int)p.size(), TRUE) != CSTR_EQUAL)
    return false;
  out->handle = std::move(h);
  out->info = i;
  out->path = p;
  out->id = Id(i);
  return true;
}
bool OpenDirectoryForMutation(const std::wstring &path, Node *out) {
  return Open(path, GENERIC_READ | GENERIC_WRITE | DELETE, true, out);
}
bool Stable(const Node &n, bool dir) {
  BY_HANDLE_FILE_INFORMATION i{};
  return n.handle.valid() && GetFileInformationByHandle(n.handle.value, &i) &&
         !!(i.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == dir &&
         !(i.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
         Same(Id(i), n.id) && (dir || i.nNumberOfLinks == 1);
}
bool Missing(const std::wstring &p) {
  DWORD a = GetFileAttributesW(p.c_str());
  return a == INVALID_FILE_ATTRIBUTES &&
         (GetLastError() == ERROR_FILE_NOT_FOUND ||
          GetLastError() == ERROR_PATH_NOT_FOUND);
}
bool OpenRoot(const Map &a, Node *root, const char **err) {
  std::string value;
  std::wstring path;
  if (!StringArg(a, "root", &value) || !ToWide(value, &path) ||
      path.size() < 3) {
    *err = "invalid_argument";
    return false;
  }
  std::replace(path.begin(), path.end(), L'/', L'\\');
  while (path.size() > 3 && path.back() == L'\\')
    path.pop_back();
  if (!Open(path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, true, root)) {
    *err = "unsafe_root";
    return false;
  }
  root->path.clear();
  if (!Canonical(root->handle.value, &root->path)) {
    *err = "unsafe_root";
    return false;
  }
  return true;
}
bool OpenContext(const Map &a, bool create, Context *c, const char **err) {
  std::string key, path, bound;
  std::vector<std::wstring> kp;
  if (!StringArg(a, "sessionKey", &key) || !StringArg(a, "path", &path) ||
      !StringArg(a, "rootIdentity", &bound) ||
      !ParseRelative(key, false, &kp) || kp.size() != 1 ||
      !ParseRelative(path, true, &c->parts)) {
    *err = "invalid_argument";
    return false;
  }
  std::string root_value;
  std::wstring root_path;
  if (create) {
    if (!StringArg(a, "root", &root_value) || !ToWide(root_value, &root_path)) {
      *err = "invalid_argument";
      return false;
    }
    std::replace(root_path.begin(), root_path.end(), L'/', L'\\');
    while (root_path.size() > 3 && root_path.back() == L'\\')
      root_path.pop_back();
    if (!OpenDirectoryForMutation(root_path, &c->root)) {
      *err = "unsafe_root";
      return false;
    }
    c->root.path.clear();
    if (!Canonical(c->root.handle.value, &c->root.path)) {
      *err = "unsafe_root";
      return false;
    }
  } else if (!OpenRoot(a, &c->root, err)) {
    return false;
  }
  if (Token(c->root.id) != bound) {
    *err = "workspace_binding_changed";
    return false;
  }
  auto sessions = Join(c->root.path, L"sessions");
  if (create && !CreateDirectoryW(sessions.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    *err = "mutation_indeterminate";
    return false;
  }
  if (!(create ? OpenDirectoryForMutation(sessions, &c->sessions)
               : Open(sessions, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
                      true, &c->sessions))) {
    *err = "not_found";
    return false;
  }
  auto session = Join(sessions, kp[0]);
  if (create && !CreateDirectoryW(session.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    *err = "mutation_indeterminate";
    return false;
  }
  if (!(create ? OpenDirectoryForMutation(session, &c->session)
               : Open(session, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, true,
                      &c->session))) {
    *err = "not_found";
    return false;
  }
  if (!Stable(c->root, true) || !Stable(c->sessions, true)) {
    *err = "metadata_changed";
    return false;
  }
  return true;
}
bool OpenParent(const Context &c, Node *p, std::wstring *name,
                const char **err) {
  if (c.parts.empty()) {
    *err = "invalid_argument";
    return false;
  }
  Node cur;
  if (!OpenDirectoryForMutation(c.session.path, &cur) ||
      !Same(cur.id, c.session.id)) {
    *err = "metadata_changed";
    return false;
  }
  for (size_t i = 0; i + 1 < c.parts.size(); ++i) {
    Node next;
    if (!OpenDirectoryForMutation(Join(cur.path, c.parts[i]), &next) ||
        !Stable(cur, true)) {
      *err = "parent_missing";
      return false;
    }
    cur = std::move(next);
  }
  *p = std::move(cur);
  *name = c.parts.back();
  return true;
}
bool OpenChild(const Node &p, const std::wstring &n, DWORD access, bool dir,
               Node *out, bool missing, const char **err) {
  if (Open(Join(p.path, n), access, dir, out) && Stable(p, true))
    return true;
  DWORD e = GetLastError();
  if (missing && (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND)) {
    out->handle.Reset();
    return true;
  }
  *err = (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND)
             ? "not_found"
             : "unsafe_path";
  return false;
}
bool HashExact(Node *f, std::string *out, uint64_t *size) {
  BY_HANDLE_FILE_INFORMATION before{};
  if (!GetFileInformationByHandle(f->handle.value, &before))
    return false;
  ULARGE_INTEGER sz;
  sz.HighPart = before.nFileSizeHigh;
  sz.LowPart = before.nFileSizeLow;
  if (sz.QuadPart > kMaxFileBytes)
    return false;
  LARGE_INTEGER z{};
  if (!SetFilePointerEx(f->handle.value, z, nullptr, FILE_BEGIN))
    return false;
  BCRYPT_ALG_HANDLE alg = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD os = 0, n = 0;
  std::vector<UCHAR> obj;
  std::array<UCHAR, 32> d{};
  bool ok = BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr,
                                        0) == 0 &&
            BCryptGetProperty(alg, BCRYPT_OBJECT_LENGTH, (PUCHAR)&os,
                              sizeof(os), &n, 0) == 0;
  obj.resize(os);
  ok = ok && BCryptCreateHash(alg, &hash, obj.data(), os, nullptr, 0, 0) == 0;
  std::array<UCHAR, 65536> b{};
  uint64_t total = 0;
  while (ok && total < sz.QuadPart) {
    DWORD ask = (DWORD)std::min<uint64_t>(b.size(), sz.QuadPart - total),
          got = 0;
    ok = ReadFile(f->handle.value, b.data(), ask, &got, nullptr) && got > 0 &&
         BCryptHashData(hash, b.data(), got, 0) == 0;
    total += got;
  }
  DWORD extra = 0;
  ok = ok && ReadFile(f->handle.value, b.data(), 1, &extra, nullptr) &&
       extra == 0 && total == sz.QuadPart &&
       BCryptFinishHash(hash, d.data(), 32, 0) == 0;
  BY_HANDLE_FILE_INFORMATION after{};
  ok = ok && GetFileInformationByHandle(f->handle.value, &after) &&
       Same(Id(before), Id(after)) &&
       before.nFileSizeHigh == after.nFileSizeHigh &&
       before.nFileSizeLow == after.nFileSizeLow;
  if (hash)
    BCryptDestroyHash(hash);
  if (alg)
    BCryptCloseAlgorithmProvider(alg, 0);
  if (!ok)
    return false;
  std::ostringstream s;
  for (auto x : d)
    s << std::hex << std::setw(2) << std::setfill('0') << (int)x;
  *out = s.str();
  if (size)
    *size = sz.QuadPart;
  return true;
}
bool VerifyFile(Node *f, const std::string &id, const std::string &hash) {
  std::string actual;
  return Token(f->id) == id && hash.size() == 64 && HashExact(f, &actual) &&
         actual == hash && Stable(*f, false);
}
bool EnsureHidden(Context *c, Node *h, const char **err) {
  auto p = Join(c->session.path, L".mobilka-workspace");
  if (!CreateDirectoryW(p.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    *err = "mutation_indeterminate";
    return false;
  }
  if (!OpenDirectoryForMutation(p, h) || !Stable(c->session, true)) {
    *err = "unsafe_path";
    return false;
  }
  return true;
}
bool SafeOperationId(const std::string &s) {
  return s.size() == 32 && std::all_of(s.begin(), s.end(), [](unsigned char c) {
           return std::isalnum(c) || c == '_' || c == '-';
         });
}
bool WriteFileExact(const Node &p, const std::wstring &n,
                    const std::vector<uint8_t> &bytes, Node *out,
                    std::string *hash) {
  if (bytes.size() > kMaxFileBytes)
    return false;
  auto path = Join(p.path, n);
  if (!Open(path, GENERIC_READ | GENERIC_WRITE | DELETE, false, out,
            CREATE_NEW))
    return false;
  DWORD wrote = 0;
  if ((!bytes.empty() && (!WriteFile(out->handle.value, bytes.data(),
                                     (DWORD)bytes.size(), &wrote, nullptr) ||
                          wrote != bytes.size())) ||
      !FlushFileBuffers(out->handle.value) || !HashExact(out, hash))
    return false;
  return true;
}
bool DeleteNode(Node *n, bool dir) {
  FILE_DISPOSITION_INFO d{TRUE};
  return Stable(*n, dir) &&
         SetFileInformationByHandle(n->handle.value, FileDispositionInfo, &d,
                                    sizeof(d));
}
Map Receipt(const std::string &id, const std::string &token,
            const std::string &, const std::string *, Map) {
  return {{Value("operationId"), Value(id)}, {Value("token"), Value(token)}};
}
bool Prepared(const Map &a, Map *p, std::string *id, std::string *op,
              std::string *path, std::string *dest, bool *has_dest,
              OperationState *out, const char **err) {
  auto raw = Find(a, "prepared");
  auto m = raw ? std::get_if<Map>(raw) : nullptr;
  std::string token, key, bound;
  if (!m || m->size() != 2 || !StringArg(*m, "operationId", id) ||
      !SafeOperationId(*id) || !StringArg(*m, "token", &token) ||
      token.size() != 43 || !StringArg(a, "sessionKey", &key) ||
      !StringArg(a, "rootIdentity", &bound)) {
    *err = "invalid_prepared_receipt";
    return false;
  }
  Map probe = a;
  probe[Value("path")] = Value("");
  Context c;
  if (!OpenContext(probe, false, &c, err))
    return false;
  Node hidden;
  if (!EnsureHidden(&c, &hidden, err))
    return false;
  OperationState state;
  if (!LoadOperationState(hidden, *id, token, &state) ||
      state.root_identity != bound ||
      state.session_identity != Token(c.session.id) ||
      state.session_key != key) {
    *err = "invalid_prepared_receipt";
    return false;
  }
  *p = state.proof;
  *op = state.operation;
  *path = state.path;
  *dest = state.destination;
  *has_dest = state.has_destination;
  *out = std::move(state);
  return true;
}
void HandleRootIdentity(const Map &a, Result result) {
  Node root;
  const char *e = nullptr;
  if (!OpenRoot(a, &root, &e)) {
    Error(result, e);
    return;
  }
  result->Success(Value(Token(root.id)));
}
} // namespace workspace
