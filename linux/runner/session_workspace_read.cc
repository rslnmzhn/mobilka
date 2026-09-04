#include "session_workspace.h"
#include <algorithm>
#include <dirent.h>
#include <fcntl.h>
#include <glib.h>
#include <unistd.h>

namespace workspace {
static FlValue *Entry(const std::string &p, const Node &n, bool dir,
                      const std::string *h = nullptr) {
  FlValue *m = fl_value_new_map();
  fl_value_set_string_take(m, "path", fl_value_new_string(p.c_str()));
  fl_value_set_string_take(m, "type",
                           fl_value_new_string(dir ? "directory" : "file"));
  fl_value_set_string_take(m, "size",
                           fl_value_new_int(dir ? 0 : n.info.st_size));
  fl_value_set_string_take(m, "identity",
                           fl_value_new_string(Token(n.id).c_str()));
  if (h)
    fl_value_set_string_take(m, "sha256", fl_value_new_string(h->c_str()));
  return m;
}
void HandleMetadata(FlMethodCall *c, FlValue *a) {
  Context x;
  const char *e = nullptr;
  if (!OpenContext(a, false, &x, &e)) {
    if (!strcmp(e, "not_found"))
      Success(c);
    else
      Error(c, e);
    return;
  }
  Node p, n;
  std::string name;
  if (!OpenParent(x, &p, &name, &e)) {
    if (!strcmp(e, "parent_missing"))
      Success(c);
    else
      Error(c, e);
    return;
  }
  struct stat s{};
  if (fstatat(p.fd.get(), name.c_str(), &s, AT_SYMLINK_NOFOLLOW)) {
    if (errno == ENOENT)
      Success(c);
    else
      Error(c, "unsafe_path");
    return;
  }
  bool dir = S_ISDIR(s.st_mode);
  if ((dir && !OpenDirAt(p.fd.get(), name, &n)) ||
      (!dir && !OpenFileAt(p.fd.get(), name, O_RDONLY, &n))) {
    Error(c, "unsafe_path");
    return;
  }
  std::string path, hash;
  StringArg(a, "path", &path);
  if (!dir) {
    if (!HashExact(&n, &hash)) {
      Error(c, "workspace_file_too_large");
      return;
    }
    g_autoptr(FlValue) m = Entry(path, n, false, &hash);
    Success(c, m);
  } else {
    g_autoptr(FlValue) m = Entry(path, n, true);
    Success(c, m);
  }
}
static bool ListInto(const Node &d, const std::string &prefix, bool recursive,
                     FlValue *out, const char **e) {
  Fd duplicate(fcntl(d.fd.get(), F_DUPFD_CLOEXEC, 0));
  DIR *dir = duplicate.valid() ? fdopendir(duplicate.Release()) : nullptr;
  if (!dir) {
    *e = "io_error";
    return false;
  }
  std::vector<std::string> names;
  while (auto ent = readdir(dir)) {
    std::string n = ent->d_name;
    if (n == "." || n == ".." || n[0] == '.')
      continue;
    if (names.size() == kMaxListEntries) {
      closedir(dir);
      *e = "too_many_entries";
      return false;
    }
    struct stat listed{};
    if (fstatat(d.fd.get(), n.c_str(), &listed, AT_SYMLINK_NOFOLLOW) ||
        listed.st_dev != d.id.device) {
      closedir(dir);
      *e = "unsafe_child";
      return false;
    }
    std::vector<std::string> check;
    if (!ParseRelative(n, false, &check) || check.size() != 1) {
      closedir(dir);
      *e = "unsafe_child";
      return false;
    }
    names.push_back(n);
  }
  closedir(dir);
  std::sort(names.begin(), names.end());
  for (auto &n : names) {
    if (fl_value_get_length(out) >= kMaxListEntries) {
      *e = "too_many_entries";
      return false;
    }
    struct stat s{};
    if (fstatat(d.fd.get(), n.c_str(), &s, AT_SYMLINK_NOFOLLOW) ||
        s.st_dev != d.id.device) {
      *e = "metadata_changed";
      return false;
    }
    bool isdir = S_ISDIR(s.st_mode);
    Node child;
    if ((isdir && !OpenDirAt(d.fd.get(), n, &child)) ||
        (!isdir && !OpenFileAt(d.fd.get(), n, O_RDONLY, &child))) {
      *e = "unsafe_child";
      return false;
    }
    auto path = prefix.empty() ? n : prefix + "/" + n;
    fl_value_append_take(out, Entry(path, child, isdir));
    if (recursive && isdir && !ListInto(child, path, true, out, e))
      return false;
  }
  return Stable(d, S_IFDIR);
}
void HandleList(FlMethodCall *c, FlValue *a) {
  bool recursive = false;
  Context x;
  const char *e = nullptr;
  if (!BoolArg(a, "recursive", &recursive)) {
    Error(c, "invalid_argument");
    return;
  }
  if (!OpenContext(a, false, &x, &e)) {
    if (!strcmp(e, "not_found")) {
      g_autoptr(FlValue) o = fl_value_new_list();
      Success(c, o);
    } else
      Error(c, e);
    return;
  }
  Node d;
  if (x.parts.empty()) {
    if (!Duplicate(x.session, &d)) {
      Error(c, "metadata_changed");
      return;
    }
  } else {
    Node p;
    std::string n;
    if (!OpenParent(x, &p, &n, &e) || !OpenDirAt(p.fd.get(), n, &d)) {
      Error(c, e ? e : "not_found");
      return;
    }
  }
  std::string prefix;
  StringArg(a, "path", &prefix);
  g_autoptr(FlValue) o = fl_value_new_list();
  if (!ListInto(d, prefix, recursive, o, &e)) {
    Error(c, e ? e : "metadata_changed");
    return;
  }
  Success(c, o);
}
void HandleRead(FlMethodCall *c, FlValue *a) {
  int64_t offset = -1, max = -1;
  Context x;
  const char *e = nullptr;
  if (!IntArg(a, "offset", &offset) || !IntArg(a, "maxBytes", &max) ||
      offset < 0 || max < 0 || max > 256 * 1024 ||
      !OpenContext(a, false, &x, &e)) {
    Error(c, e ? e : "invalid_argument");
    return;
  }
  Node p, f;
  std::string n;
  if (!OpenParent(x, &p, &n, &e) || !OpenFileAt(p.fd.get(), n, O_RDONLY, &f)) {
    Error(c, e ? e : "not_found");
    return;
  }
  std::string hash;
  off_t size;
  if (!HashExact(&f, &hash, &size)) {
    Error(c, "workspace_file_too_large");
    return;
  }
  std::vector<uint8_t> bytes(size);
  if (size && pread(f.fd.get(), bytes.data(), size, 0) != size) {
    Error(c, "metadata_changed");
    return;
  }
  if (!g_utf8_validate(size ? (char *)bytes.data() : "", size, nullptr)) {
    Error(c, "unsupported_text");
    return;
  }
  if (offset > size) {
    Error(c, "invalid_utf8_offset");
    return;
  }
  auto boundary = [&](size_t i) {
    return i == 0 || i == bytes.size() || (bytes[i] & 0xc0) != 0x80;
  };
  if (!boundary(offset)) {
    Error(c, "invalid_utf8_offset");
    return;
  }
  size_t end = std::min<size_t>(bytes.size(), offset + max);
  while (end > (size_t)offset && !boundary(end))
    --end;
  g_autoptr(FlValue) m = fl_value_new_map();
  fl_value_set_string_take(
      m, "bytes", fl_value_new_uint8_list(bytes.data() + offset, end - offset));
  fl_value_set_string_take(m, "size", fl_value_new_int(size));
  fl_value_set_string_take(m, "sha256", fl_value_new_string(hash.c_str()));
  fl_value_set_string_take(m, "nextOffset", fl_value_new_int(end));
  fl_value_set_string_take(m, "truncated",
                           fl_value_new_bool(end < (size_t)size));
  fl_value_set_string_take(m, "identity",
                           fl_value_new_string(Token(f.id).c_str()));
  Success(c, m);
}
} // namespace workspace
