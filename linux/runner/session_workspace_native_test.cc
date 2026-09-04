#include "session_workspace.h"

#include <fcntl.h>
#include <linux/fs.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>

int main() {
  char root[] = "/tmp/mobilka-native-XXXXXX";
  if (!mkdtemp(root)) return 1;
  workspace::Fd root_fd(open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW));
  if (!root_fd.valid() || mkdirat(root_fd.get(), "session", 0700) != 0 ||
      mkdirat(root_fd.get(), "nested", 0700) != 0) return 2;
  workspace::Node session, nested;
  if (!workspace::OpenDirAt(root_fd.get(), "session", &session) ||
      !workspace::OpenDirAt(root_fd.get(), "nested", &nested)) {
    return 3;
  }
  workspace::Node stage;
  std::string hash;
  const uint8_t payload[] = {'p', 'a', 'y', 'l', 'o', 'a', 'd'};
  if (!workspace::WriteExact(session, "stage", payload, sizeof(payload), &stage,
                             &hash)) return 3;
  const auto identity = workspace::Token(stage.id);
  stage.fd.Reset();
  if (workspace::RenameAt2(session.fd.get(), "stage", nested.fd.get(), "result",
                           RENAME_NOREPLACE) != 0 ||
      fsync(session.fd.get()) != 0 || fsync(nested.fd.get()) != 0) return 4;
  workspace::Node result;
  if (!workspace::OpenFileAt(nested.fd.get(), "result", O_RDONLY, &result) ||
      !workspace::Verify(&result, identity, hash)) return 4;
  result.fd.Reset();
  int tamper = openat(nested.fd.get(), "result", O_WRONLY | O_TRUNC | O_NOFOLLOW);
  if (tamper < 0 || write(tamper, "tampered", 8) != 8 || fsync(tamper) != 0) {
    return 5;
  }
  close(tamper);
  if (!workspace::OpenFileAt(nested.fd.get(), "result", O_RDONLY, &result) ||
      workspace::Verify(&result, identity, hash)) return 6;
  result.fd.Reset();
  unlinkat(nested.fd.get(), "result", 0);
  nested.fd.Reset();
  session.fd.Reset();
  unlinkat(root_fd.get(), "nested", AT_REMOVEDIR);
  unlinkat(root_fd.get(), "session", AT_REMOVEDIR);
  root_fd.Reset();
  rmdir(root);
  return 0;
}
