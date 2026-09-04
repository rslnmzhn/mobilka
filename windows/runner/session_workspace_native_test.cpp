#include "session_workspace.h"

#include <windows.h>

#include <string>
#include <vector>

namespace {
constexpr wchar_t kOperationId[] = L"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

bool HasStateTemp(const std::wstring& root) {
  WIN32_FIND_DATAW data{};
  HANDLE find = FindFirstFileW((root + L"\\" + kOperationId + L".state.*.tmp").c_str(),
                               &data);
  if (find == INVALID_HANDLE_VALUE) return false;
  FindClose(find);
  return true;
}
}  // namespace

int wmain() {
  wchar_t temporary[MAX_PATH];
  if (!GetTempPathW(MAX_PATH, temporary)) return 1;
  wchar_t unique[MAX_PATH];
  if (!GetTempFileNameW(temporary, L"mws", 0, unique) ||
      !DeleteFileW(unique)) return 2;
  const std::wstring root = unique;
  if (!CreateDirectoryW(root.c_str(), nullptr)) return 2;
  workspace::Node hidden;
  if (!workspace::OpenDirectoryForMutation(root, &hidden)) {
    RemoveDirectoryW(root.c_str());
    return 3;
  }
  workspace::OperationState state;
  state.token = std::string(43, 'a');
  state.root_identity = "root";
  state.session_identity = "session";
  state.session_key = "key";
  state.operation = "write_file";
  state.path = "a.txt";
  if (!workspace::SaveOperationState(hidden, std::string(32, 'b'), state)) {
    return 4;
  }
  workspace::Node stage;
  std::string stage_hash;
  const std::vector<uint8_t> payload{'p', 'a', 'y', 'l', 'o', 'a', 'd'};
  if (!workspace::WriteFileExact(hidden, L"stage", payload, &stage,
                                 &stage_hash)) {
    return 11;
  }
  const auto stage_id = workspace::Token(stage.id);
  workspace::RenameDurable(&stage, hidden, hidden, L"result");
  stage.handle.Reset();
  const char* error = nullptr;
  workspace::Node result;
  if (!workspace::OpenChild(hidden, L"result", GENERIC_READ | DELETE, false,
                            &result, true, &error)) return 13;
  if (!result.handle.valid() &&
      !workspace::OpenChild(hidden, L"stage", GENERIC_READ | DELETE, false,
                            &result, false, &error)) return 13;
  if (!workspace::VerifyFile(&result, stage_id, stage_hash)) return 15;
  if (!workspace::DeleteNode(&result, false)) return 14;
  result.handle.Reset();
  const std::wstring stale = root + L"\\" + std::wstring(32, L'b') +
                             L".state." + std::wstring(43, L'c') + L".tmp";
  HANDLE crash_temp = CreateFileW(
      stale.c_str(), GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (crash_temp == INVALID_HANDLE_VALUE) return 5;
  CloseHandle(crash_temp);
  if (!DeleteFileW(stale.c_str())) return 5;
  if (!workspace::SaveOperationState(hidden, std::string(32, 'b'), state)) {
    return 5;
  }
  if (HasStateTemp(root)) return 10;
  const std::wstring state_path = root + L"\\" + std::wstring(32, L'b') + L".state";
  HANDLE persisted = CreateFileW(state_path.c_str(), GENERIC_READ,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                 OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT,
                                 nullptr);
  if (persisted == INVALID_HANDLE_VALUE) return 6;
  CloseHandle(persisted);
  if (!DeleteFileW(state_path.c_str())) return 8;
  hidden.handle.Reset();
  return RemoveDirectoryW(root.c_str()) ? 0 : 9;
}
