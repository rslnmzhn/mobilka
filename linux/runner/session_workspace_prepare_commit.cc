#include "session_workspace.h"

#include <fcntl.h>
#include <linux/fs.h>
#include <unistd.h>

namespace workspace {
namespace {
bool IsWrite(const std::string& operation) {
  return operation == "write_file" || operation == "apply_patch";
}

bool ValidOperation(const std::string& operation) {
  return IsWrite(operation) || operation == "move_file" ||
         operation == "delete_file" || operation == "make_directory";
}

bool OpenDestination(const Context& context, const OperationState& state,
                     Node* parent, std::string* name, const char** error) {
  std::vector<std::string> parts;
  if (!state.has_destination ||
      !ParseRelative(state.destination, false, &parts)) {
    *error = "invalid_prepared_receipt";
    return false;
  }
  Context destination;
  if (!Duplicate(context.root, &destination.root)) {
    *error = "metadata_changed";
    return false;
  }
  destination.parts = std::move(parts);
  if (!Duplicate(context.session, &destination.session)) {
    *error = "metadata_changed";
    return false;
  }
  return OpenParent(destination, parent, name, error);
}

bool FileProof(const Node& parent, const std::string& name,
               const std::string& identity, const std::string& hash,
               Node* node) {
  std::string actual;
  return OpenFileAt(parent.fd.get(), name, O_RDONLY, node) &&
         Token(node->id) == identity && Stable(*node, S_IFREG) &&
         HashExact(node, &actual) && actual == hash;
}

bool Persist(const Node& hidden, const std::string& id, OperationState* state,
             OperationPhase phase) {
  state->phase = phase;
  return SaveOperationState(hidden, id, *state);
}
}  // namespace

void HandlePrepare(FlMethodCall* call, FlValue* args) {
  std::string id, operation, path, destination, expected_identity, expected_hash;
  bool has_destination = false, expect_missing = false;
  bool has_identity = false, has_hash = false;
  Context context;
  const char* error = nullptr;
  if (!StringArg(args, "operationId", &id) || !SafeOperationId(id) ||
      !StringArg(args, "operation", &operation) || !ValidOperation(operation) ||
      !StringArg(args, "path", &path) ||
      !NullableStringArg(args, "destination", &destination, &has_destination) ||
      !BoolArg(args, "expectMissing", &expect_missing) ||
      !NullableStringArg(args, "expectedIdentity", &expected_identity, &has_identity) ||
      !NullableStringArg(args, "expectedHash", &expected_hash, &has_hash) ||
      (operation == "move_file") != has_destination ||
      !OpenContext(args, true, &context, &error)) {
    RespondError(call, error ? error : "invalid_argument");
    return;
  }
  Node hidden;
  if (!EnsureHidden(&context, &hidden, &error) ||
      !MissingAt(hidden.fd.get(), id + ".state") ||
      !MissingAt(hidden.fd.get(), id + ".stage") ||
      !MissingAt(hidden.fd.get(), id + ".backup")) {
    RespondError(call, error ? error : "operation_exists");
    return;
  }
  Node parent, target;
  std::string name;
  if (!OpenParent(context, &parent, &name, &error)) {
    RespondError(call, error);
    return;
  }
  bool target_is_file = OpenFileAt(parent.fd.get(), name, O_RDONLY, &target);
  Node target_directory;
  bool target_is_directory = !target_is_file &&
      OpenDirAt(parent.fd.get(), name, &target_directory);
  bool exists = target_is_file || target_is_directory;
  if (expect_missing ? exists :
      (!exists || !has_identity ||
       (target_is_file && (!has_hash ||
        !Verify(&target, expected_identity, expected_hash))) ||
       (target_is_directory && Token(target_directory.id) != expected_identity))) {
    RespondError(call, "stale_target");
    return;
  }
  if (target_is_directory && operation != "make_directory") {
    RespondError(call, "workspace_operation_unsupported");
    return;
  }

  OperationState state;
  state.root_identity = Token(context.root.id);
  state.session_identity = Token(context.session.id);
  StringArg(args, "sessionKey", &state.session_key);
  state.operation = operation;
  state.path = path;
  state.destination = destination;
  state.has_destination = has_destination;
  state.expect_missing = expect_missing;
  state.target_directory = target_is_directory;
  state.expected_identity = has_identity ? expected_identity : "";
  state.expected_hash = has_hash ? expected_hash : "";
  if (!RandomToken(&state.token)) {
    RespondError(call, "mutation_indeterminate");
    return;
  }

  if (IsWrite(operation)) {
    auto raw = Lookup(args, "bytes");
    if (!raw || fl_value_get_type(raw) != FL_VALUE_TYPE_UINT8_LIST) {
      RespondError(call, "invalid_argument");
      return;
    }
    Node stage;
    size_t size = fl_value_get_length(raw);
    if (!WriteExact(hidden, id + ".stage", fl_value_get_uint8_list(raw), size,
                    &stage, &state.stage_hash)) {
      RespondError(call, "mutation_indeterminate");
      return;
    }
    state.stage_identity = Token(stage.id);
    state.result_size = size;
  } else if (operation == "move_file" || operation == "delete_file") {
    std::vector<uint8_t> bytes(static_cast<size_t>(target.info.st_size));
    size_t at = 0;
    while (at < bytes.size()) {
      ssize_t count = pread(target.fd.get(), bytes.data() + at,
                            bytes.size() - at, at);
      if (count <= 0) {
        RespondError(call, "metadata_changed");
        return;
      }
      at += static_cast<size_t>(count);
    }
    Node backup;
    if (!WriteExact(hidden, id + ".backup", bytes.data(), bytes.size(),
                    &backup, &state.backup_hash)) {
      RespondError(call, "mutation_indeterminate");
      return;
    }
    state.backup_identity = Token(backup.id);
  } else {
    if (mkdirat(hidden.fd.get(), (id + ".stage").c_str(), 0700) != 0) {
      RespondError(call, "mutation_indeterminate");
      return;
    }
    Node stage;
    if (!OpenDirAt(hidden.fd.get(), id + ".stage", &stage)) {
      RespondError(call, "mutation_indeterminate");
      return;
    }
    state.stage_identity = Token(stage.id);
  }
  if (!SaveOperationState(hidden, id, state)) {
    RespondError(call, "mutation_indeterminate");
    return;
  }
  g_autoptr(FlValue) receipt = Receipt(id, state.token);
  RespondSuccess(call, receipt);
}

void HandleCommit(FlMethodCall* call, FlValue* args) {
  Context context;
  Node hidden;
  OperationState state;
  std::string id;
  const char* error = nullptr;
  if (!Prepared(args, &context, &hidden, &id, &state, &error)) {
    RespondError(call, error);
    return;
  }
  if (state.phase == OperationPhase::committed) {
    RespondSuccess(call);
    return;
  }
  if (state.phase != OperationPhase::prepared) {
    RespondError(call, "invalid_prepared_receipt");
    return;
  }
  Node parent, target;
  std::string name;
  if (!OpenParent(context, &parent, &name, &error)) {
    RespondError(call, error);
    return;
  }
  if (IsWrite(state.operation)) {
    Node stage;
    if (!FileIdentity(hidden, id + ".stage", state.stage_identity, &stage)) {
      RespondError(call, "mutation_indeterminate");
      return;
    }
    bool exists = OpenFileAt(parent.fd.get(), name, O_RDONLY, &target);
    int result = 0;
    if (state.expect_missing) {
      if (exists) { RespondError(call, "stale_target"); return; }
      if (!Persist(hidden, id, &state, OperationPhase::stageInstalling)) {
        RespondError(call, "mutation_indeterminate"); return;
      }
      result = RenameAt2(hidden.fd.get(), (id + ".stage").c_str(),
                         parent.fd.get(), name.c_str(), RENAME_NOREPLACE);
    } else {
      if (!exists || !Verify(&target, state.expected_identity,
                             state.expected_hash)) {
        RespondError(call, "stale_target");
        return;
      }
      if (!Persist(hidden, id, &state,
                   OperationPhase::targetQuarantining)) {
        RespondError(call, "mutation_indeterminate"); return;
      }
      result = RenameAt2(hidden.fd.get(), (id + ".stage").c_str(),
                          parent.fd.get(), name.c_str(), RENAME_EXCHANGE);
    }
    if (result != 0 || fsync(parent.fd.get()) != 0 || fsync(hidden.fd.get()) != 0) {
      RespondError(call, "mutation_indeterminate");
      return;
    }
    if (!state.expect_missing) {
      Node displaced;
      if (!FileProof(hidden, id + ".stage", state.expected_identity,
                     state.expected_hash, &displaced)) {
        if (RenameAt2(hidden.fd.get(), (id + ".stage").c_str(),
                      parent.fd.get(), name.c_str(), RENAME_EXCHANGE) == 0) {
          fsync(parent.fd.get());
          fsync(hidden.fd.get());
        }
        RespondError(call, "mutation_indeterminate");
        return;
      }
    }
  } else if (state.operation == "delete_file") {
    if (!OpenFileAt(parent.fd.get(), name, O_RDONLY, &target) ||
        !Verify(&target, state.expected_identity, state.expected_hash) ||
        !Persist(hidden, id, &state,
                 OperationPhase::targetQuarantining) ||
        RenameAt2(parent.fd.get(), name.c_str(), hidden.fd.get(),
                  (id + ".stage").c_str(), RENAME_NOREPLACE) != 0 ||
        fsync(parent.fd.get()) != 0 || fsync(hidden.fd.get()) != 0) {
      RespondError(call, "mutation_indeterminate");
      return;
    }
    Node quarantined;
    if (!FileProof(hidden, id + ".stage", state.expected_identity,
                   state.expected_hash, &quarantined)) {
      if (RenameAt2(hidden.fd.get(), (id + ".stage").c_str(), parent.fd.get(),
                    name.c_str(), RENAME_NOREPLACE) == 0) {
        fsync(parent.fd.get()); fsync(hidden.fd.get());
      }
      RespondError(call, "mutation_indeterminate"); return;
    }
  } else if (state.operation == "move_file") {
    Node destination_parent;
    std::string destination_name;
    if (!OpenDestination(context, state, &destination_parent, &destination_name,
                         &error) ||
        !OpenFileAt(parent.fd.get(), name, O_RDONLY, &target) ||
        !Verify(&target, state.expected_identity, state.expected_hash) ||
        !Persist(hidden, id, &state, OperationPhase::stageInstalling) ||
        RenameAt2(parent.fd.get(), name.c_str(), destination_parent.fd.get(),
                  destination_name.c_str(), RENAME_NOREPLACE) != 0 ||
        fsync(parent.fd.get()) != 0 || fsync(destination_parent.fd.get()) != 0) {
      RespondError(call, "mutation_indeterminate");
      return;
    }
    Node moved;
    if (!FileProof(destination_parent, destination_name, state.expected_identity,
                   state.expected_hash, &moved)) {
      if (RenameAt2(destination_parent.fd.get(), destination_name.c_str(),
                    parent.fd.get(), name.c_str(), RENAME_NOREPLACE) == 0) {
        fsync(parent.fd.get()); fsync(destination_parent.fd.get());
      }
      RespondError(call, "mutation_indeterminate"); return;
    }
  } else if (state.operation == "make_directory") {
    Node stage;
    if (!OpenDirAt(hidden.fd.get(), id + ".stage", &stage) ||
        Token(stage.id) != state.stage_identity ||
        !Persist(hidden, id, &state, OperationPhase::stageInstalling) ||
        RenameAt2(hidden.fd.get(), (id + ".stage").c_str(), parent.fd.get(),
                  name.c_str(), RENAME_NOREPLACE) != 0 ||
        fsync(parent.fd.get()) != 0 || fsync(hidden.fd.get()) != 0) {
      RespondError(call, "mutation_indeterminate");
      return;
    }
  } else {
    RespondError(call, "invalid_prepared_receipt");
    return;
  }
  if (!Persist(hidden, id, &state, OperationPhase::committed)) {
    RespondError(call, "mutation_indeterminate");
    return;
  }
  RespondSuccess(call);
}

}  // namespace workspace
