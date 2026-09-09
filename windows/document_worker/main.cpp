#include <windows.h>

bool IsDocumentWorkerSandboxed();
int RunDocumentWorker(HANDLE input, HANDLE output);

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  if (!IsDocumentWorkerSandboxed()) return 70;
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (!input || input == INVALID_HANDLE_VALUE || !output ||
      output == INVALID_HANDLE_VALUE) return 71;
  return RunDocumentWorker(input, output);
}
