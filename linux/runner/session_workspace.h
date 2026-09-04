#ifndef FLUTTER_SESSION_WORKSPACE_H_
#define FLUTTER_SESSION_WORKSPACE_H_

#include <flutter_linux/flutter_linux.h>

#include <sys/stat.h>
#include <cstdint>
#include <string>
#include <vector>

namespace workspace {
constexpr off_t kMaxFileBytes = 1024 * 1024;
constexpr size_t kMaxListEntries = 500;
class Fd { public: explicit Fd(int value=-1):value_(value){} ~Fd(); Fd(Fd&&) noexcept; Fd& operator=(Fd&&) noexcept; Fd(const Fd&)=delete; int get()const{return value_;} bool valid()const{return value_>=0;} int Release(); void Reset(int=-1); private:int value_; };
struct Identity { dev_t device=0; ino_t inode=0; };
struct Node { Fd fd; struct stat info{}; Identity id; };
struct Context { Node root,sessions,session; std::vector<std::string> parts; };
enum class OperationPhase : uint32_t {
  prepared = 1,
  targetQuarantining = 2,
  targetQuarantined = 3,
  stageInstalling = 4,
  committed = 5,
  rolledBack = 6,
};
struct OperationState {
  std::string token,root_identity,session_identity,session_key;
  std::string operation,path,destination,expected_identity,expected_hash;
  std::string stage_identity,stage_hash,backup_identity,backup_hash;
  bool has_destination=false,expect_missing=false,target_directory=false;
  uint64_t result_size=0;
  OperationPhase phase=OperationPhase::prepared;
};
void Error(FlMethodCall*,const char*); void Success(FlMethodCall*,FlValue* = nullptr);
FlValue* Lookup(FlValue*,const char*); bool StringArg(FlValue*,const char*,std::string*);
bool NullableStringArg(FlValue*,const char*,std::string*,bool*); bool BoolArg(FlValue*,const char*,bool*);
bool IntArg(FlValue*,const char*,int64_t*); bool ParseRelative(const std::string&,bool,std::vector<std::string>*);
bool OpenContext(FlValue*,bool,Context*,const char**); bool Duplicate(const Node&,Node*);
bool OpenRoot(FlValue*,Node*,const char**);
bool OpenParent(const Context&,Node*,std::string*,const char**); bool OpenDirAt(int,const std::string&,Node*);
bool OpenFileAt(int,const std::string&,int,Node*); bool Stable(const Node&,mode_t);
bool FileIdentity(const Node&, const std::string&, const std::string&, Node*);
std::string Token(Identity); bool Same(Identity,Identity); bool MissingAt(int,const std::string&);
bool HashExact(Node*,std::string*,off_t* = nullptr); bool Verify(Node*,const std::string&,const std::string&);
bool EnsureHidden(Context*,Node*,const char**); bool SafeOperationId(const std::string&);
bool WriteExact(const Node&,const std::string&,const uint8_t*,size_t,Node*,std::string*);
int RenameAt2(int,const char*,int,const char*,unsigned);
bool RandomToken(std::string*);
bool SaveOperationState(const Node&,const std::string&,const OperationState&);
bool LoadOperationState(const Node&,const std::string&,const std::string&,OperationState*);
bool DeleteOperationState(const Node&,const std::string&);
bool Prepared(FlValue*,Context*,Node*,std::string*,OperationState*,const char**);
FlValue* Receipt(const std::string&,const std::string&);
void HandleMetadata(FlMethodCall*,FlValue*); void HandleList(FlMethodCall*,FlValue*); void HandleRead(FlMethodCall*,FlValue*);
void HandlePrepare(FlMethodCall*,FlValue*); void HandleCommit(FlMethodCall*,FlValue*); void HandleReconcile(FlMethodCall*,FlValue*); void HandleRollback(FlMethodCall*,FlValue*); void HandleCleanup(FlMethodCall*,FlValue*);
void HandleRootIdentity(FlMethodCall*,FlValue*);
}

FlMethodChannel* register_session_workspace_channel(FlBinaryMessenger* messenger);

#endif  // FLUTTER_SESSION_WORKSPACE_H_
