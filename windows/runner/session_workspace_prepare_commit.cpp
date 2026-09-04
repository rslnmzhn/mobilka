#include "session_workspace.h"

namespace workspace {
namespace {
bool IsWrite(const std::string& operation) {
  return operation == "write_file" || operation == "apply_patch";
}

bool ProofString(const Map& proof, const char* key, std::string* value) {
  return StringArg(proof, key, value);
}

std::wstring OwnedName(const std::string& id, const wchar_t* suffix) {
  return std::wstring(id.begin(), id.end()) + suffix;
}

bool OpenFileMaybe(const Node& parent, const std::wstring& name, Node* file) {
  const char* error = nullptr;
  return OpenChild(parent, name, GENERIC_READ | DELETE, false, file, true,
                   &error);
}

bool FileProof(Node* file, const std::string& identity,
               const std::string& hash) {
  return file->handle.valid() && VerifyFile(file, identity, hash);
}

bool StageProof(Node* file, const std::string& identity,
                const std::string& hash) {
  std::string actual;
  return file->handle.valid() && Token(file->id) == identity &&
         HashExact(file, &actual) && actual == hash;
}

bool Persist(const Node& hidden, const std::string& id, OperationState* state,
             OperationPhase phase) {
  state->phase = phase;
  return SaveOperationState(hidden, id, *state);
}

bool GetPreparedContext(const Map& args, Context* context, Map* proof,
                        std::string* id, std::string* operation,
                        std::string* path, std::string* destination,
                        bool* has_destination, OperationState* state,
                        const char** error) {
  if (!Prepared(args, proof, id, operation, path, destination,
                has_destination, state, error)) {
    return false;
  }
  Map context_args = args;
  context_args[Value("path")] = Value(*path);
  return OpenContext(context_args, false, context, error);
}

bool RecoverySetup(const Map& args, Context* context, Map* proof,
                   std::string* id, std::string* operation,
                   std::string* path, std::string* destination,
                   bool* has_destination, Node* hidden,
                   OperationState* state, const char** error) {
  return GetPreparedContext(args, context, proof, id, operation, path,
                            destination, has_destination, state, error) &&
         EnsureHidden(context, hidden, error);
}

bool OpenDestination(const Context& context, const std::string& destination,
                     Node* parent, std::wstring* name, const char** error) {
  std::vector<std::wstring> parts;
  if (!ParseRelative(destination, false, &parts)) return false;
  Context target;
  target.session.path = context.session.path;
  target.session.id = context.session.id;
  target.parts = std::move(parts);
  return OpenParent(target, parent, name, error);
}

void ReplyState(Result& result, const char* state) {
  result->Success(Value(state));
}
}  // namespace

bool RenameDurable(Node* source, const Node& source_parent,
                   const Node& destination_parent, const std::wstring& name) {
  if (!RenameHandleRelative(source, destination_parent, name, false) ||
      !FlushFileBuffers(source_parent.handle.value)) {
    return false;
  }
  return Token(source_parent.id) == Token(destination_parent.id) ||
         FlushFileBuffers(destination_parent.handle.value);
}

void HandlePrepare(const Map& args, Result result) {
  std::string id, operation, path, destination, expected_id, expected_hash;
  bool has_destination = false, expect_missing = false;
  bool has_id = false, has_hash = false;
  const char* error = nullptr;
  Context context;
  if (!StringArg(args, "operationId", &id) || !SafeOperationId(id) ||
      !StringArg(args, "operation", &operation) ||
      !StringArg(args, "path", &path) ||
      !NullableStringArg(args, "destination", &destination,
                         &has_destination) ||
      !BoolArg(args, "expectMissing", &expect_missing) ||
      !NullableStringArg(args, "expectedIdentity", &expected_id, &has_id) ||
      !NullableStringArg(args, "expectedHash", &expected_hash, &has_hash) ||
      (operation == "move_file") != has_destination ||
      !OpenContext(args, true, &context, &error)) {
    Error(result, error ? error : "invalid_argument");
    return;
  }
  Node hidden;
  const auto stage_name = OwnedName(id, L".stage");
  const auto backup_name = OwnedName(id, L".backup");
  const auto old_name = OwnedName(id, L".old");
  if (!EnsureHidden(&context, &hidden, &error) ||
      !Missing(Join(hidden.path, stage_name)) ||
      !Missing(Join(hidden.path, backup_name)) ||
      !Missing(Join(hidden.path, old_name))) {
    Error(result, error ? error : "operation_exists");
    return;
  }
  Node parent, current;
  std::wstring name;
  bool directory = false;
  if (!OpenParent(context, &parent, &name, &error)) {
    Error(result, error);
    return;
  }
  if (!OpenChild(parent, name, GENERIC_READ | DELETE, false, &current, true,
                 &error)) {
    if (!OpenChild(parent, name,
                   FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE, true,
                   &current, true, &error)) {
      Error(result, error);
      return;
    }
    directory = current.handle.valid();
  }
  if (expect_missing) {
    if (current.handle.valid()) {
      Error(result, "stale_target");
      return;
    }
  } else if (!current.handle.valid() || !has_id ||
             Token(current.id) != expected_id ||
             (directory ? has_hash
                        : (!has_hash || !VerifyFile(&current, expected_id,
                                                    expected_hash)))) {
    Error(result, "stale_target");
    return;
  }

  Map proof{{Value("expectedIdentity"), has_id ? Value(expected_id) : Value()},
            {Value("expectedHash"), has_hash ? Value(expected_hash) : Value()},
            {Value("expectMissing"), Value(expect_missing)},
            {Value("targetDirectory"), Value(directory)}};
  if (IsWrite(operation)) {
    const auto* raw = Find(args, "bytes");
    const auto* bytes = raw ? std::get_if<std::vector<uint8_t>>(raw) : nullptr;
    Node stage;
    std::string hash;
    if (!bytes || !WriteFileExact(hidden, stage_name, *bytes, &stage, &hash)) {
      if (stage.handle.valid()) {
        DeleteNode(&stage, false);
        FlushFileBuffers(hidden.handle.value);
      }
      Error(result, "mutation_indeterminate");
      return;
    }
    proof[Value("stageIdentity")] = Value(Token(stage.id));
    proof[Value("resultHash")] = Value(hash);
    proof[Value("resultSize")] = Value(static_cast<int64_t>(bytes->size()));
  } else if (operation == "move_file" || operation == "delete_file") {
    if (directory) {
      Error(result, "workspace_operation_unsupported");
      return;
    }
    uint64_t size = 0;
    std::string hash;
    if (!HashExact(&current, &hash, &size)) {
      Error(result, "stale_target");
      return;
    }
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    LARGE_INTEGER zero{};
    DWORD read = 0;
    if (!SetFilePointerEx(current.handle.value, zero, nullptr, FILE_BEGIN) ||
        (size && (!ReadFile(current.handle.value, bytes.data(),
                            static_cast<DWORD>(bytes.size()), &read, nullptr) ||
                    read != bytes.size()))) {
      Error(result, "metadata_changed");
      return;
    }
    Node backup;
    std::string backup_hash;
    if (!WriteFileExact(hidden, backup_name, bytes, &backup, &backup_hash)) {
      if (backup.handle.valid()) {
        DeleteNode(&backup, false);
        FlushFileBuffers(hidden.handle.value);
      }
      Error(result, "mutation_indeterminate");
      return;
    }
    proof[Value("backupIdentity")] = Value(Token(backup.id));
    proof[Value("backupHash")] = Value(backup_hash);
  } else if (operation == "make_directory") {
    if (!CreateDirectoryW(Join(hidden.path, stage_name).c_str(), nullptr)) {
      Error(result, "mutation_indeterminate");
      return;
    }
    Node stage;
    if (!OpenChild(hidden, stage_name,
                   FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE, true,
                   &stage, false, &error)) {
      Error(result, "mutation_indeterminate");
      return;
    }
    proof[Value("stageIdentity")] = Value(Token(stage.id));
  } else {
    Error(result, "invalid_argument");
    return;
  }

  std::string token, root, key;
  if (!RandomToken(&token) || !StringArg(args, "rootIdentity", &root) ||
      !StringArg(args, "sessionKey", &key)) {
    Error(result, "mutation_indeterminate");
    return;
  }
  OperationState state{token, root, Token(context.session.id), key, operation,
                       path, destination, has_destination, std::move(proof)};
  if (!SaveOperationState(hidden, id, state)) {
    for (const auto& item : {
           std::pair<std::wstring, bool>{stage_name,
                                         operation == "make_directory"},
           {backup_name, false}}) {
      Node node;
      if (item.second) {
        OpenChild(hidden, item.first,
                  FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE, true,
                  &node, true, &error);
      } else {
        OpenFileMaybe(hidden, item.first, &node);
      }
      if (node.handle.valid()) DeleteNode(&node, item.second);
    }
    FlushFileBuffers(hidden.handle.value);
    Error(result, "mutation_indeterminate");
    return;
  }
  result->Success(Value(Receipt(id, token, path, nullptr, {})));
}

void HandleCommit(const Map& args, Result result) {
  Context context;
  Map proof;
  OperationState state;
  std::string id, operation, path, destination;
  bool has_destination = false;
  const char* error = nullptr;
  if (!GetPreparedContext(args, &context, &proof, &id, &operation, &path,
                          &destination, &has_destination, &state, &error)) {
    Error(result, error);
    return;
  }
  Node hidden, parent, target;
  std::wstring name;
  if (!EnsureHidden(&context, &hidden, &error) ||
      !OpenParent(context, &parent, &name, &error)) {
    Error(result, error);
    return;
  }
  if (state.phase == OperationPhase::committed) {
    result->Success();
    return;
  }
  std::string expected_id, expected_hash, stage_id, stage_hash;
  bool expect_missing = false;
  ProofString(proof, "expectedIdentity", &expected_id);
  ProofString(proof, "expectedHash", &expected_hash);
  ProofString(proof, "stageIdentity", &stage_id);
  ProofString(proof, "resultHash", &stage_hash);
  BoolArg(proof, "expectMissing", &expect_missing);
  const auto stage_name = OwnedName(id, L".stage");
  const auto old_name = OwnedName(id, L".old");

  if (IsWrite(operation)) {
    Node stage, old;
    OpenFileMaybe(hidden, stage_name, &stage);
    OpenFileMaybe(hidden, old_name, &old);
    OpenFileMaybe(parent, name, &target);
    if (!expect_missing && state.phase == OperationPhase::prepared) {
      if (!FileProof(&target, expected_id, expected_hash) || old.handle.valid() ||
          !Persist(hidden, id, &state, OperationPhase::targetQuarantining) ||
          !RenameDurable(&target, parent, hidden, old_name)) {
        Error(result, "mutation_indeterminate");
        return;
      }
      target.handle.Reset();
      OpenFileMaybe(hidden, old_name, &old);
      if (!FileProof(&old, expected_id, expected_hash) ||
          !Persist(hidden, id, &state, OperationPhase::targetQuarantined)) {
        Error(result, "mutation_indeterminate");
        return;
      }
    }
    if (expect_missing && state.phase == OperationPhase::prepared) {
      if (target.handle.valid()) {
        Error(result, "stale_target");
        return;
      }
    } else if (!expect_missing &&
               state.phase == OperationPhase::targetQuarantining) {
      if (!target.handle.valid() && FileProof(&old, expected_id, expected_hash)) {
        if (!Persist(hidden, id, &state,
                     OperationPhase::targetQuarantined)) {
          Error(result, "mutation_indeterminate");
          return;
        }
      } else {
        Error(result, "mutation_indeterminate");
        return;
      }
    }
    if (state.phase == OperationPhase::prepared ||
        state.phase == OperationPhase::targetQuarantined) {
      if (!StageProof(&stage, stage_id, stage_hash) || target.handle.valid() ||
          !Persist(hidden, id, &state, OperationPhase::stageInstalling) ||
          !RenameDurable(&stage, hidden, parent, name)) {
        Error(result, "mutation_indeterminate");
        return;
      }
    } else if (state.phase != OperationPhase::stageInstalling) {
      Error(result, "invalid_prepared_receipt");
      return;
    }
  } else if (operation == "delete_file") {
    if (state.phase == OperationPhase::prepared) {
      if (!OpenFileMaybe(parent, name, &target) ||
          !FileProof(&target, expected_id, expected_hash) ||
          !Missing(Join(hidden.path, stage_name)) ||
          !Persist(hidden, id, &state, OperationPhase::targetQuarantining) ||
          !RenameDurable(&target, parent, hidden, stage_name) ||
          !Persist(hidden, id, &state, OperationPhase::targetQuarantined)) {
        Error(result, "mutation_indeterminate");
        return;
      }
    } else if (state.phase != OperationPhase::targetQuarantined) {
      Error(result, "mutation_indeterminate");
      return;
    }
  } else if (operation == "move_file") {
    Node destination_parent;
    std::wstring destination_name;
    if (!has_destination ||
        !OpenDestination(context, destination, &destination_parent,
                         &destination_name, &error)) {
      Error(result, "invalid_prepared_receipt");
      return;
    }
    if (state.phase == OperationPhase::prepared) {
      if (!OpenFileMaybe(parent, name, &target) ||
          !FileProof(&target, expected_id, expected_hash) ||
          !Missing(Join(destination_parent.path, destination_name)) ||
          !Persist(hidden, id, &state, OperationPhase::stageInstalling) ||
          !RenameDurable(&target, parent, destination_parent,
                         destination_name)) {
        Error(result, "mutation_indeterminate");
        return;
      }
    } else if (state.phase != OperationPhase::stageInstalling) {
      Error(result, "mutation_indeterminate");
      return;
    }
  } else if (operation == "make_directory") {
    Node stage;
    if (state.phase == OperationPhase::prepared) {
      if (!OpenChild(hidden, stage_name,
                     FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE,
                     true, &stage, false, &error) ||
          Token(stage.id) != stage_id || !Missing(Join(parent.path, name)) ||
          !Persist(hidden, id, &state, OperationPhase::stageInstalling) ||
          !RenameDurable(&stage, hidden, parent, name)) {
        Error(result, "mutation_indeterminate");
        return;
      }
    } else if (state.phase != OperationPhase::stageInstalling) {
      Error(result, "mutation_indeterminate");
      return;
    }
  } else {
    Error(result, "invalid_prepared_receipt");
    return;
  }
  if (!Persist(hidden, id, &state, OperationPhase::committed)) {
    Error(result, "mutation_indeterminate");
    return;
  }
  result->Success();
}

}  // namespace workspace
