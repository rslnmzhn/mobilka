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
  if (!Prepared(args, proof, id, operation, path, destination, has_destination,
                state, error)) {
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
void HandleReconcile(const Map& args, Result result) {
  Context context;
  Map proof;
  Node hidden, parent, target, stage, old;
  OperationState state;
  std::string id, operation, path, destination;
  bool has_destination = false;
  const char* error = nullptr;
  if (!RecoverySetup(args, &context, &proof, &id, &operation, &path,
                     &destination, &has_destination, &hidden, &state, &error)) {
    Error(result, error ? error : "invalid_prepared_receipt");
    return;
  }
  if (state.phase == OperationPhase::rolledBack) {
    ReplyState(result, "rolledBack");
    return;
  }
  if (state.phase == OperationPhase::targetQuarantining && IsWrite(operation)) {
    Node target_probe, old_probe;
    std::wstring target_name;
    Node target_parent;
    if (!OpenParent(context, &target_parent, &target_name, &error)) {
      Error(result, error);
      return;
    }
    std::string expected_id, expected_hash;
    ProofString(proof, "expectedIdentity", &expected_id);
    ProofString(proof, "expectedHash", &expected_hash);
    OpenFileMaybe(target_parent, target_name, &target_probe);
    OpenFileMaybe(hidden, OwnedName(id, L".old"), &old_probe);
    if (!target_probe.handle.valid() &&
        FileProof(&old_probe, expected_id, expected_hash)) {
      if (!Persist(hidden, id, &state, OperationPhase::targetQuarantined)) {
        Error(result, "mutation_indeterminate");
        return;
      }
    } else if (!FileProof(&target_probe, expected_id, expected_hash) ||
               old_probe.handle.valid()) {
      Error(result, "mutation_indeterminate");
      return;
    }
  }
  std::wstring name;
  if (!OpenParent(context, &parent, &name, &error)) {
    Error(result, error);
    return;
  }
  std::string expected_id, expected_hash, stage_id, stage_hash;
  bool expect_missing = false;
  ProofString(proof, "expectedIdentity", &expected_id);
  ProofString(proof, "expectedHash", &expected_hash);
  ProofString(proof, "stageIdentity", &stage_id);
  ProofString(proof, "resultHash", &stage_hash);
  BoolArg(proof, "expectMissing", &expect_missing);
  OpenFileMaybe(parent, name, &target);
  OpenFileMaybe(hidden, OwnedName(id, L".stage"), &stage);
  OpenFileMaybe(hidden, OwnedName(id, L".old"), &old);

  bool committed = false;
  bool before = false;
  if (IsWrite(operation)) {
    committed = StageProof(&target, stage_id, stage_hash) && !stage.handle.valid() &&
                (expect_missing || FileProof(&old, expected_id, expected_hash));
    before = expect_missing
                 ? !target.handle.valid() && StageProof(&stage, stage_id, stage_hash)
                 : FileProof(&target, expected_id, expected_hash) &&
                       StageProof(&stage, stage_id, stage_hash) &&
                       !old.handle.valid();
    if (!expect_missing && !target.handle.valid() &&
        FileProof(&old, expected_id, expected_hash) &&
        StageProof(&stage, stage_id, stage_hash)) {
      before = true;
    }
  } else if (operation == "delete_file") {
    committed = !target.handle.valid() && FileProof(&stage, expected_id,
                                                    expected_hash);
    before = FileProof(&target, expected_id, expected_hash) &&
             !stage.handle.valid();
  } else if (operation == "move_file") {
    Node destination_parent, moved;
    std::wstring destination_name;
    if (!OpenDestination(context, destination, &destination_parent,
                         &destination_name, &error)) {
      ReplyState(result, "indeterminate");
      return;
    }
    OpenFileMaybe(destination_parent, destination_name, &moved);
    committed = !target.handle.valid() &&
                FileProof(&moved, expected_id, expected_hash);
    before = FileProof(&target, expected_id, expected_hash) &&
             !moved.handle.valid();
  } else if (operation == "make_directory") {
    Node directory, staged;
    OpenChild(parent, name,
              FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE, true,
              &directory, true, &error);
    OpenChild(hidden, OwnedName(id, L".stage"),
              FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE, true,
              &staged, true, &error);
    committed = directory.handle.valid() && Token(directory.id) == stage_id &&
                !staged.handle.valid();
    before = !directory.handle.valid() && staged.handle.valid() &&
             Token(staged.id) == stage_id;
  }
  if (committed) {
    if (state.phase != OperationPhase::committed &&
        !Persist(hidden, id, &state, OperationPhase::committed)) {
      Error(result, "mutation_indeterminate");
      return;
    }
    ReplyState(result, "committed");
  } else {
    ReplyState(result, before ? "notCommitted" : "indeterminate");
  }
}

void HandleRollback(const Map& args, Result result) {
  Context context;
  Map proof;
  Node hidden, parent, target;
  OperationState state;
  std::string id, operation, path, destination;
  bool has_destination = false;
  const char* error = nullptr;
  if (!RecoverySetup(args, &context, &proof, &id, &operation, &path,
                     &destination, &has_destination, &hidden, &state, &error)) {
    Error(result, error);
    return;
  }
  if (state.phase == OperationPhase::rolledBack) {
    result->Success();
    return;
  }
  if (state.phase == OperationPhase::committed) {
    Error(result, "already_committed");
    return;
  }
  std::wstring name;
  if (!OpenParent(context, &parent, &name, &error)) {
    Error(result, error);
    return;
  }
  std::string expected_id, expected_hash, stage_id, stage_hash;
  bool expect_missing = false;
  ProofString(proof, "expectedIdentity", &expected_id);
  ProofString(proof, "expectedHash", &expected_hash);
  ProofString(proof, "stageIdentity", &stage_id);
  ProofString(proof, "resultHash", &stage_hash);
  BoolArg(proof, "expectMissing", &expect_missing);
  OpenFileMaybe(parent, name, &target);

  if (IsWrite(operation)) {
    Node stage, old;
    OpenFileMaybe(hidden, OwnedName(id, L".stage"), &stage);
    OpenFileMaybe(hidden, OwnedName(id, L".old"), &old);
    if (expect_missing) {
      if (StageProof(&target, stage_id, stage_hash)) {
        if (!DeleteNode(&target, false) || !FlushFileBuffers(parent.handle.value)) {
          Error(result, "mutation_indeterminate");
          return;
        }
      } else if (target.handle.valid()) {
        Error(result, "mutation_indeterminate");
        return;
      }
    } else if (FileProof(&old, expected_id, expected_hash)) {
      if (target.handle.valid() && StageProof(&target, stage_id, stage_hash)) {
        if (!DeleteNode(&target, false) ||
            !FlushFileBuffers(parent.handle.value)) {
          Error(result, "mutation_indeterminate");
          return;
        }
      } else if (target.handle.valid()) {
        Error(result, "mutation_indeterminate");
        return;
      }
      if (!RenameDurable(&old, hidden, parent, name)) {
        Error(result, "mutation_indeterminate");
        return;
      }
    } else if (!FileProof(&target, expected_id, expected_hash)) {
      Error(result, "mutation_indeterminate");
      return;
    }
  } else if (operation == "delete_file") {
    Node quarantined;
    OpenFileMaybe(hidden, OwnedName(id, L".stage"), &quarantined);
    if (!target.handle.valid() &&
        FileProof(&quarantined, expected_id, expected_hash) &&
        !RenameDurable(&quarantined, hidden, parent, name)) {
      Error(result, "mutation_indeterminate");
      return;
    }
    if (target.handle.valid() &&
        !FileProof(&target, expected_id, expected_hash)) {
      Error(result, "mutation_indeterminate");
      return;
    }
  } else if (operation == "move_file") {
    Node destination_parent, moved;
    std::wstring destination_name;
    if (!OpenDestination(context, destination, &destination_parent,
                         &destination_name, &error)) {
      Error(result, error);
      return;
    }
    OpenFileMaybe(destination_parent, destination_name, &moved);
    if (!target.handle.valid() && FileProof(&moved, expected_id, expected_hash) &&
        !RenameDurable(&moved, destination_parent, parent, name)) {
      Error(result, "mutation_indeterminate");
      return;
    }
    if (target.handle.valid() &&
        !FileProof(&target, expected_id, expected_hash)) {
      Error(result, "mutation_indeterminate");
      return;
    }
  } else if (operation == "make_directory") {
    Node directory;
    if (OpenChild(parent, name,
                  FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE, true,
                  &directory, true, &error) &&
        directory.handle.valid()) {
      if (Token(directory.id) != stage_id || !DeleteNode(&directory, true) ||
          !FlushFileBuffers(parent.handle.value)) {
        Error(result, "mutation_indeterminate");
        return;
      }
    }
  }
  if (!Persist(hidden, id, &state, OperationPhase::rolledBack)) {
    Error(result, "mutation_indeterminate");
    return;
  }
  result->Success();
}

void HandleCleanup(const Map& args, Result result) {
  const auto* raw = Find(args, "prepared");
  const auto* receipt = raw ? std::get_if<Map>(raw) : nullptr;
  std::string id, token;
  if (!receipt || receipt->size() != 2 ||
      !StringArg(*receipt, "operationId", &id) || !SafeOperationId(id) ||
      !StringArg(*receipt, "token", &token) || token.size() != 43) {
    Error(result, "invalid_prepared_receipt");
    return;
  }
  Map probe = args;
  probe[Value("path")] = Value("");
  Context context;
  const char* error = nullptr;
  if (!OpenContext(probe, false, &context, &error)) {
    if (std::string(error) == "not_found") {
      result->Success();
    } else {
      Error(result, error);
    }
    return;
  }
  Node hidden;
  if (!EnsureHidden(&context, &hidden, &error)) {
    Error(result, error);
    return;
  }
  OperationState state;
  const bool state_present =
      LoadOperationState(hidden, id, token, &state);
  if (!state_present && Missing(Join(hidden.path, OwnedName(id, L".state"))) &&
      Missing(Join(hidden.path, OwnedName(id, L".stage"))) &&
      Missing(Join(hidden.path, OwnedName(id, L".backup"))) &&
      Missing(Join(hidden.path, OwnedName(id, L".old")))) {
    result->Success();
    return;
  }
  if (!state_present || state.root_identity != Token(context.root.id) ||
      state.session_identity != Token(context.session.id)) {
    Error(result, "invalid_prepared_receipt");
    return;
  }
  for (const auto& item :
       {std::pair<const wchar_t*, bool>{L".stage",
                                       state.operation == "make_directory"},
        {L".backup", false}, {L".old", false}}) {
    Node node;
    if (item.second) {
      OpenChild(hidden, OwnedName(id, item.first),
                FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE, true,
                &node, true, &error);
    } else {
      OpenFileMaybe(hidden, OwnedName(id, item.first), &node);
    }
    if (node.handle.valid() && !DeleteNode(&node, item.second)) {
      Error(result, "mutation_indeterminate");
      return;
    }
  }
  if (!DeleteOperationState(hidden, id)) {
    Error(result, "mutation_indeterminate");
    return;
  }
  result->Success();
}
}  // namespace workspace
