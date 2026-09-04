#include "session_workspace.h"

#include <algorithm>

namespace workspace {
static Map Entry(const std::string &path, const Node &n, bool dir,
                 const std::string *hash = nullptr) {
  ULARGE_INTEGER size{};
  size.HighPart = n.info.nFileSizeHigh;
  size.LowPart = n.info.nFileSizeLow;
  Map m{{Value("path"), Value(path)},
        {Value("type"), Value(dir ? "directory" : "file")},
        {Value("size"),
         Value(dir ? int64_t(0) : static_cast<int64_t>(size.QuadPart))},
        {Value("identity"), Value(Token(n.id))}};
  if (hash)
    m[Value("sha256")] = Value(*hash);
  return m;
}
void HandleMetadata(const Map &a, Result result) {
  Context c;
  const char *e = nullptr;
  if (!OpenContext(a, false, &c, &e)) {
    if (std::string(e) == "not_found")
      result->Success();
    else
      Error(result, e);
    return;
  }
  Node p, n;
  std::wstring name;
  if (!OpenParent(c, &p, &name, &e)) {
    if (std::string(e) == "parent_missing")
      result->Success();
    else
      Error(result, e);
    return;
  }
  if (!OpenChild(p, name, GENERIC_READ, true, &n, true, &e)) {
    if (!OpenChild(p, name, GENERIC_READ, false, &n, true, &e)) {
      Error(result, e);
      return;
    }
  }
  if (!n.handle.valid()) {
    result->Success();
    return;
  }
  bool dir = (n.info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  std::string path, hash;
  StringArg(a, "path", &path);
  if (!dir) {
    if (!HashExact(&n, &hash)) {
      Error(result, "workspace_file_too_large");
      return;
    }
    result->Success(Value(Entry(path, n, false, &hash)));
  } else
    result->Success(Value(Entry(path, n, true)));
}
static bool ListInto(const Node &d, const std::string &prefix, bool recursive,
                     List *out, const char **err) {
  WIN32_FIND_DATAW data{};
  HANDLE search = FindFirstFileW(Join(d.path, L"*").c_str(), &data);
  if (search == INVALID_HANDLE_VALUE)
    return GetLastError() == ERROR_FILE_NOT_FOUND;
  do {
    std::wstring name = data.cFileName;
    if (name == L"." || name == L".." || name.rfind(L".", 0) == 0)
      continue;
    if (out->size() >= kMaxListEntries) {
      *err = "listing_limit_exceeded";
      FindClose(search);
      return false;
    }
    std::string utf8;
    int count =
        WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, name.data(),
                            (int)name.size(), nullptr, 0, nullptr, nullptr);
    if (count <= 0) {
      *err = "unsafe_child";
      FindClose(search);
      return false;
    }
    utf8.resize(count);
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, name.data(),
                        (int)name.size(), utf8.data(), count, nullptr, nullptr);
    std::vector<std::wstring> check;
    if (!ParseRelative(utf8, false, &check) || check.size() != 1) {
      *err = "unsafe_child";
      FindClose(search);
      return false;
    }
    bool dir = (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    Node child;
    if (!OpenChild(d, name,
                   dir ? FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES
                       : GENERIC_READ,
                   dir, &child, false, err)) {
      FindClose(search);
      return false;
    }
    auto path = prefix.empty() ? utf8 : prefix + "/" + utf8;
    out->emplace_back(Entry(path, child, dir));
    if (recursive && dir && !ListInto(child, path, true, out, err)) {
      FindClose(search);
      return false;
    }
  } while (FindNextFileW(search, &data));
  FindClose(search);
  return Stable(d, true);
}
void HandleList(const Map &a, Result result) {
  bool recursive = false;
  Context c;
  const char *e = nullptr;
  if (!BoolArg(a, "recursive", &recursive)) {
    Error(result, "invalid_argument");
    return;
  }
  if (!OpenContext(a, false, &c, &e)) {
    if (std::string(e) == "not_found")
      result->Success(Value(List{}));
    else
      Error(result, e);
    return;
  }
  Node d;
  if (c.parts.empty()) {
    if (!OpenChild(
            c.sessions,
            c.session.path.substr(c.session.path.find_last_of(L'\\') + 1),
            FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, true, &d, false, &e)) {
      Error(result, e);
      return;
    }
  } else {
    Node p;
    std::wstring name;
    if (!OpenParent(c, &p, &name, &e) ||
        !OpenChild(p, name, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, true,
                   &d, false, &e)) {
      Error(result, e);
      return;
    }
  }
  std::string prefix;
  StringArg(a, "path", &prefix);
  List out;
  if (!ListInto(d, prefix, recursive, &out, &e)) {
    Error(result, e ? e : "metadata_changed");
    return;
  }
  result->Success(Value(out));
}
void HandleRead(const Map &a, Result result) {
  auto off = Find(a, "offset"), max = Find(a, "maxBytes");
  auto oi = off ? std::get_if<int64_t>(off) : nullptr;
  auto mi = max ? std::get_if<int64_t>(max) : nullptr;
  if (!oi || !mi || *oi < 0 || *mi < 0 || *mi > 256 * 1024) {
    Error(result, "invalid_argument");
    return;
  }
  Context c;
  const char *e = nullptr;
  Node p, f;
  std::wstring name;
  if (!OpenContext(a, false, &c, &e) || !OpenParent(c, &p, &name, &e) ||
      !OpenChild(p, name, GENERIC_READ, false, &f, false, &e)) {
    Error(result, e ? e : "not_found");
    return;
  }
  std::string hash;
  uint64_t size;
  if (!HashExact(&f, &hash, &size)) {
    Error(result, "workspace_file_too_large");
    return;
  }
  if ((uint64_t)*oi > size) {
    Error(result, "invalid_utf8_offset");
    return;
  }
  std::vector<uint8_t> whole((size_t)size);
  LARGE_INTEGER z{};
  SetFilePointerEx(f.handle.value, z, nullptr, FILE_BEGIN);
  DWORD got = 0;
  if (!whole.empty() && (!ReadFile(f.handle.value, whole.data(),
                                   (DWORD)whole.size(), &got, nullptr) ||
                         got != whole.size())) {
    Error(result, "metadata_changed");
    return;
  }
  if (!whole.empty() &&
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (char *)whole.data(),
                          (int)whole.size(), nullptr, 0) <= 0) {
    Error(result, "unsupported_text");
    return;
  }
  auto boundary = [&](size_t i) {
    return i == 0 || i == whole.size() || (whole[i] & 0xc0) != 0x80;
  };
  if (!boundary((size_t)*oi)) {
    Error(result, "invalid_utf8_offset");
    return;
  }
  size_t end = std::min<size_t>(whole.size(), (size_t)(*oi + *mi));
  while (end > (size_t)*oi && !boundary(end))
    --end;
  std::vector<uint8_t> chunk(whole.begin() + *oi, whole.begin() + end);
  result->Success(Value(Map{{Value("bytes"), Value(chunk)},
                            {Value("size"), Value((int64_t)size)},
                            {Value("sha256"), Value(hash)},
                            {Value("nextOffset"), Value((int64_t)end)},
                            {Value("truncated"), Value(end < size)},
                            {Value("identity"), Value(Token(f.id))}}));
}
} // namespace workspace
