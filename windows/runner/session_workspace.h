#ifndef RUNNER_SESSION_WORKSPACE_H_
#define RUNNER_SESSION_WORKSPACE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

namespace workspace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using Result = std::unique_ptr<flutter::MethodResult<Value>>;
constexpr uint64_t kMaxFileBytes = 1024 * 1024;
constexpr size_t kMaxListEntries = 500;

struct Handle {
  explicit Handle(HANDLE value = INVALID_HANDLE_VALUE) : value(value) {}
  ~Handle();
  Handle(Handle&& other) noexcept;
  Handle& operator=(Handle&& other) noexcept;
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  void Reset(HANDLE next = INVALID_HANDLE_VALUE);
  bool valid() const { return value != INVALID_HANDLE_VALUE; }
  HANDLE value;
};
struct Identity {
  DWORD volume, high, low;
};
struct Node {
  Handle handle;
  BY_HANDLE_FILE_INFORMATION info{};
  std::wstring path;
  Identity id{};
};
struct Context {
  Node root, sessions, session;
  std::vector<std::wstring> parts;
};
enum class OperationPhase : uint32_t {
  prepared = 1,
  targetQuarantining = 2,
  targetQuarantined = 3,
  stageInstalling = 4,
  committed = 5,
  rolledBack = 6,
};
struct OperationState {
  std::string token, root_identity, session_identity, session_key;
  std::string operation, path, destination;
  bool has_destination = false;
  Map proof;
  OperationPhase phase = OperationPhase::prepared;
};

void Error(Result& result, const char* code);
const Value* Find(const Map& args, const char* key);
bool StringArg(const Map& args, const char* key, std::string* value);
bool BoolArg(const Map& args, const char* key, bool* value);
bool NullableStringArg(const Map&, const char*, std::string*, bool*);
bool ParseRelative(const std::string&, bool, std::vector<std::wstring>*);
bool OpenContext(const Map&, bool, Context*, const char**);
bool OpenRoot(const Map&, Node*, const char**);
bool OpenDirectoryForMutation(const std::wstring&, Node*);
bool OpenParent(const Context&, Node*, std::wstring*, const char**);
bool OpenChild(const Node&, const std::wstring&, DWORD, bool, Node*, bool, const char**);
bool Stable(const Node&, bool);
bool Missing(const std::wstring&);
std::wstring Join(const std::wstring&, const std::wstring&);
std::string Token(const Identity&);
bool HashExact(Node*, std::string*, uint64_t* = nullptr);
bool VerifyFile(Node*, const std::string&, const std::string&);
bool EnsureHidden(Context*, Node*, const char**);
bool SafeOperationId(const std::string&);
bool WriteFileExact(const Node&, const std::wstring&, const std::vector<uint8_t>&,
                    Node*, std::string*);
bool DeleteNode(Node*, bool);
Map Receipt(const std::string&, const std::string&, const std::string&,
             const std::string*, Map);
bool Prepared(const Map&, Map*, std::string*, std::string*, std::string*,
                std::string*, bool*, OperationState*, const char**);
bool SaveOperationState(const Node&, const std::string&, const OperationState&);
bool LoadOperationState(const Node&, const std::string&, const std::string&,
                        OperationState*);
bool DeleteOperationState(const Node&, const std::string&);
bool RandomToken(std::string*);
bool RenameHandleRelative(Node*, const Node&, const std::wstring&, bool);
bool RenameDurable(Node*, const Node&, const Node&, const std::wstring&);
void HandleRootIdentity(const Map&, Result);
void HandleMetadata(const Map&, Result);
void HandleList(const Map&, Result);
void HandleRead(const Map&, Result);
void HandlePrepare(const Map&, Result);
void HandleCommit(const Map&, Result);
void HandleReconcile(const Map&, Result);
void HandleRollback(const Map&, Result);
void HandleCleanup(const Map&, Result);
}

void RegisterSessionWorkspaceChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SESSION_WORKSPACE_H_
