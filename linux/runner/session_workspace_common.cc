#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "session_workspace.h"
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <glib.h>
#include <linux/openat2.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace workspace {
Fd::~Fd() { Reset(); }
Fd::Fd(Fd &&o) noexcept : value_(o.Release()) {}
Fd &Fd::operator=(Fd &&o) noexcept {
  if (this != &o)
    Reset(o.Release());
  return *this;
}
int Fd::Release() {
  int v = value_;
  value_ = -1;
  return v;
}
void Fd::Reset(int v) {
  if (value_ >= 0)
    close(value_);
  value_ = v;
}
void RespondError(FlMethodCall *c, const char *code) {
  g_autoptr(GError) e = nullptr;
  fl_method_call_respond_error(c, code, "Workspace operation rejected", nullptr,
                               &e);
}
void RespondSuccess(FlMethodCall *c, FlValue *v) {
  g_autoptr(GError) e = nullptr;
  fl_method_call_respond_success(c, v, &e);
}
FlValue *Lookup(FlValue *a, const char *k) {
  return a && fl_value_get_type(a) == FL_VALUE_TYPE_MAP
             ? fl_value_lookup_string(a, k)
             : nullptr;
}
bool StringArg(FlValue *a, const char *k, std::string *out) {
  auto v = Lookup(a, k);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_STRING)
    return false;
  *out = fl_value_get_string(v);
  return true;
}
bool NullableStringArg(FlValue *a, const char *k, std::string *out, bool *p) {
  auto v = Lookup(a, k);
  if (!v || fl_value_get_type(v) == FL_VALUE_TYPE_NULL) {
    *p = false;
    return true;
  }
  if (fl_value_get_type(v) != FL_VALUE_TYPE_STRING)
    return false;
  *p = true;
  *out = fl_value_get_string(v);
  return true;
}
bool BoolArg(FlValue *a, const char *k, bool *out) {
  auto v = Lookup(a, k);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_BOOL)
    return false;
  *out = fl_value_get_bool(v);
  return true;
}
bool IntArg(FlValue *a, const char *k, int64_t *out) {
  auto v = Lookup(a, k);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_INT)
    return false;
  *out = fl_value_get_int(v);
  return true;
}
static bool Part(const std::string &s) {
  if (s.empty() || s.size() > 128 || s[0] == '.' || s == ".." ||
      !g_utf8_validate(s.data(), s.size(), nullptr) || s.back() == '.' ||
      s.back() == ' ')
    return false;
  for (unsigned char c : s)
    if (c < 32 || c == 127 || c == '/' || c == '\\' || c == ':')
      return false;
  std::string stem = s.substr(0, s.find('.'));
  std::transform(stem.begin(), stem.end(), stem.begin(),
                 [](unsigned char c) { return g_ascii_toupper(c); });
  if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL")
    return false;
  return !(stem.size() == 4 &&
           (stem.substr(0, 3) == "COM" || stem.substr(0, 3) == "LPT") &&
           stem[3] >= '1' && stem[3] <= '9');
}
bool ParseRelative(const std::string &s, bool root,
                   std::vector<std::string> *out) {
  out->clear();
  if (s.empty())
    return root;
  if (s.size() > 1024 || s.front() == '/' || s.back() == '/' ||
      s.find('\\') != std::string::npos || s.find(':') != std::string::npos)
    return false;
  size_t p = 0;
  while (p < s.size()) {
    auto e = s.find('/', p);
    auto x = s.substr(p, e - p);
    if (!Part(x))
      return false;
    out->push_back(x);
    if (out->size() > 16)
      return false;
    if (e == std::string::npos)
      break;
    p = e + 1;
  }
  return true;
}
bool Same(Identity a, Identity b) {
  return a.device == b.device && a.inode == b.inode;
}
std::string Token(Identity i) {
  return std::to_string((uint64_t)i.device) + ":" +
         std::to_string((uint64_t)i.inode);
}
static Identity Id(const struct stat &s) { return {s.st_dev, s.st_ino}; }
static int OpenSecure(int p, const char *n, int flags, mode_t mode = 0) {
#ifdef SYS_openat2
  struct open_how h{};
  h.flags = flags;
  h.mode = mode;
  h.resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_SYMLINKS |
              RESOLVE_NO_XDEV;
  return syscall(SYS_openat2, p, n, &h, sizeof(h));
#else
  errno = ENOSYS;
  return -1;
#endif
}
static bool Inspect(Fd fd, mode_t type, Node *out) {
  struct stat s{};
  if (!fd.valid() || fstat(fd.get(), &s) || ((s.st_mode & S_IFMT) != type) ||
      (type == S_IFREG && s.st_nlink != 1))
    return false;
  out->fd = std::move(fd);
  out->info = s;
  out->id = Id(s);
  return true;
}
bool OpenDirAt(int p, const std::string &n, Node *out) {
  return Inspect(
      Fd(OpenSecure(p, n.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)), S_IFDIR,
      out);
}
bool OpenFileAt(int p, const std::string &n, int access, Node *out) {
  return Inspect(Fd(OpenSecure(p, n.c_str(), access | O_CLOEXEC)), S_IFREG,
                 out);
}
bool Stable(const Node &n, mode_t type) {
  struct stat s{};
  return n.fd.valid() && !fstat(n.fd.get(), &s) &&
         (s.st_mode & S_IFMT) == type && (type == S_IFDIR || s.st_nlink == 1) &&
         Same(Id(s), n.id);
}
bool Duplicate(const Node &n, Node *out) {
  Fd fd(fcntl(n.fd.get(), F_DUPFD_CLOEXEC, 0));
  return Inspect(std::move(fd), S_IFDIR, out) && Same(out->id, n.id);
}
bool OpenRoot(FlValue *a, Node *root, const char **e) {
  std::string path;
  if (!StringArg(a, "root", &path) || path.empty() || path[0] != '/' ||
      !Inspect(
          Fd(open(path.c_str(), O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)),
          S_IFDIR, root)) {
    *e = "unsafe_root";
    return false;
  }
  return true;
}
bool OpenContext(FlValue *a, bool create, Context *c, const char **e) {
  std::string key, path, bound;
  std::vector<std::string> kp;
  if (!StringArg(a, "sessionKey", &key) || !StringArg(a, "path", &path) ||
      !StringArg(a, "rootIdentity", &bound) ||
      !ParseRelative(key, false, &kp) || kp.size() != 1 ||
      !ParseRelative(path, true, &c->parts) || !OpenRoot(a, &c->root, e)) {
    *e = "invalid_argument";
    return false;
  }
  if (Token(c->root.id) != bound) {
    *e = "workspace_binding_changed";
    return false;
  }
  if (create && mkdirat(c->root.fd.get(), "sessions", 0700) &&
      errno != EEXIST) {
    *e = "mutation_indeterminate";
    return false;
  }
  if (!OpenDirAt(c->root.fd.get(), "sessions", &c->sessions) ||
      c->sessions.id.device != c->root.id.device) {
    *e = "not_found";
    return false;
  }
  if (create && mkdirat(c->sessions.fd.get(), kp[0].c_str(), 0700) &&
      errno != EEXIST) {
    *e = "mutation_indeterminate";
    return false;
  }
  if (!OpenDirAt(c->sessions.fd.get(), kp[0], &c->session) ||
      c->session.id.device != c->root.id.device) {
    *e = "not_found";
    return false;
  }
  if (!Stable(c->root, S_IFDIR) || !Stable(c->sessions, S_IFDIR)) {
    *e = "metadata_changed";
    return false;
  }
  return true;
}
bool OpenParent(const Context &c, Node *p, std::string *n, const char **e) {
  if (c.parts.empty()) {
    *e = "invalid_argument";
    return false;
  }
  Node cur;
  if (!Duplicate(c.session, &cur)) {
    *e = "metadata_changed";
    return false;
  }
  for (size_t i = 0; i + 1 < c.parts.size(); ++i) {
    Node next;
    if (!OpenDirAt(cur.fd.get(), c.parts[i], &next) ||
        next.id.device != c.root.id.device || !Stable(cur, S_IFDIR)) {
      *e = "parent_missing";
      return false;
    }
    cur = std::move(next);
  }
  *p = std::move(cur);
  *n = c.parts.back();
  return true;
}
bool MissingAt(int p, const std::string &n) {
  struct stat s{};
  return fstatat(p, n.c_str(), &s, AT_SYMLINK_NOFOLLOW) && errno == ENOENT;
}
bool HashExact(Node *f, std::string *out, off_t *size) {
  struct stat before{};
  if (fstat(f->fd.get(), &before) || before.st_size < 0 ||
      before.st_size > kMaxFileBytes)
    return false;
  g_autoptr(GChecksum) c = g_checksum_new(G_CHECKSUM_SHA256);
  unsigned char b[65536];
  off_t pos = 0;
  while (pos < before.st_size) {
    ssize_t n = pread(f->fd.get(), b,
                      std::min<off_t>(sizeof(b), before.st_size - pos), pos);
    if (n <= 0)
      return false;
    g_checksum_update(c, b, n);
    pos += n;
  }
  if (pread(f->fd.get(), b, 1, before.st_size) != 0)
    return false;
  struct stat after{};
  if (fstat(f->fd.get(), &after) || after.st_size != before.st_size ||
      !Same(Id(after), Id(before)))
    return false;
  *out = g_checksum_get_string(c);
  if (size)
    *size = before.st_size;
  return true;
}
bool Verify(Node *f, const std::string &id, const std::string &hash) {
  std::string actual;
  return Token(f->id) == id && hash.size() == 64 && HashExact(f, &actual) &&
         actual == hash && Stable(*f, S_IFREG);
}
bool FileIdentity(const Node &parent, const std::string &name,
                  const std::string &identity, Node *node) {
  return OpenFileAt(parent.fd.get(), name, O_RDONLY, node) &&
         Token(node->id) == identity && Stable(*node, S_IFREG);
}
bool EnsureHidden(Context *c, Node *h, const char **e) {
  if (mkdirat(c->session.fd.get(), ".mobilka-workspace", 0700) &&
      errno != EEXIST) {
    *e = "mutation_indeterminate";
    return false;
  }
  if (!OpenDirAt(c->session.fd.get(), ".mobilka-workspace", h) ||
      !Stable(c->session, S_IFDIR)) {
    *e = "unsafe_path";
    return false;
  }
  return true;
}
bool SafeOperationId(const std::string &s) {
  return s.size() == 32 && std::all_of(s.begin(), s.end(), [](unsigned char c) {
           return g_ascii_isalnum(c) || c == '_' || c == '-';
         });
}
bool WriteExact(const Node &p, const std::string &n, const uint8_t *b,
                size_t len, Node *out, std::string *hash) {
  if (len > kMaxFileBytes)
    return false;
  Fd fd(OpenSecure(p.fd.get(), n.c_str(), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
                   0600));
  if (!Inspect(std::move(fd), S_IFREG, out))
    return false;
  size_t pos = 0;
  while (pos < len) {
    ssize_t x = write(out->fd.get(), b + pos, len - pos);
    if (x <= 0)
      return false;
    pos += x;
  }
  return fsync(out->fd.get()) == 0 && HashExact(out, hash);
}
int RenameAt2(int op, const char *on, int np, const char *nn, unsigned flags) {
#ifdef SYS_renameat2
  return syscall(SYS_renameat2, op, on, np, nn, flags);
#else
  errno = ENOSYS;
  return -1;
#endif
}
FlValue *Receipt(const std::string &id, const std::string &token) {
  FlValue *m = fl_value_new_map();
  fl_value_set_string_take(m, "operationId", fl_value_new_string(id.c_str()));
  fl_value_set_string_take(m, "token", fl_value_new_string(token.c_str()));
  return m;
}
bool Prepared(FlValue *a, Context *c, Node *h, std::string *id,
              OperationState *s, const char **e) {
  auto r = Lookup(a, "prepared");
  std::string token, key, bound;
  if (!r || fl_value_get_type(r) != FL_VALUE_TYPE_MAP ||
      fl_value_get_length(r) != 2 || !StringArg(r, "operationId", id) ||
      !SafeOperationId(*id) || !StringArg(r, "token", &token) ||
      token.size() != 43 || !StringArg(a, "sessionKey", &key) ||
      !StringArg(a, "rootIdentity", &bound)) {
    *e = "invalid_prepared_receipt";
    return false;
  }
  g_autoptr(FlValue) probe = fl_value_new_map();
  fl_value_set_string_take(probe, "root", fl_value_ref(Lookup(a, "root")));
  fl_value_set_string_take(probe, "sessionKey",
                           fl_value_ref(Lookup(a, "sessionKey")));
  fl_value_set_string_take(probe, "rootIdentity",
                           fl_value_ref(Lookup(a, "rootIdentity")));
  fl_value_set_string_take(probe, "path", fl_value_new_string(""));
  if (!OpenContext(probe, false, c, e) || !EnsureHidden(c, h, e) ||
      !LoadOperationState(*h, *id, token, s) || s->root_identity != bound ||
      s->session_identity != Token(c->session.id) || s->session_key != key) {
    *e = "invalid_prepared_receipt";
    return false;
  }
  if (!ParseRelative(s->path, false, &c->parts)) {
    *e = "invalid_prepared_receipt";
    return false;
  }
  return true;
}
void HandleRootIdentity(FlMethodCall *c, FlValue *a) {
  Node root;
  const char *e = nullptr;
  if (!OpenRoot(a, &root, &e)) {
    RespondError(c, e);
    return;
  }
  g_autoptr(FlValue) v = fl_value_new_string(Token(root.id).c_str());
  RespondSuccess(c, v);
}
} // namespace workspace
