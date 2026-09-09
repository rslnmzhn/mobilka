#include <windows.h>

bool IsDocumentWorkerSandboxed() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  DWORD app_container = 0;
  DWORD size = sizeof(app_container);
  const BOOL ok = GetTokenInformation(token, TokenIsAppContainer,
                                      &app_container, size, &size);
  CloseHandle(token);
  return ok && app_container != 0;
}
