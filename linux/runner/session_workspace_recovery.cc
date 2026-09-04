#include "session_workspace.h"

#include <fcntl.h>
#include <linux/fs.h>
#include <unistd.h>

namespace workspace {
namespace {
bool IsWrite(const std::string& operation) {
  return operation == "write_file" || operation == "apply_patch";
}

bool FileProof(const Node& parent, const std::string& name,
               const std::string& identity, const std::string& hash,
               Node* node) {
  std::string actual;
  return OpenFileAt(parent.fd.get(), name, O_RDONLY, node) &&
         Token(node->id) == identity && Stable(*node, S_IFREG) &&
         HashExact(node, &actual) && actual == hash;
}

void ReplyState(FlMethodCall* call, const char* state) {
  g_autoptr(FlValue) value = fl_value_new_string(state);
  RespondSuccess(call, value);
}

bool Persist(const Node& hidden, const std::string& id, OperationState* state,
             OperationPhase phase) {
  state->phase = phase;
  return SaveOperationState(hidden, id, *state);
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
  if (!Duplicate(context.root, &destination.root) ||
      !Duplicate(context.session, &destination.session)) {
    *error = "metadata_changed";
    return false;
  }
  destination.parts = std::move(parts);
  return OpenParent(destination, parent, name, error);
}

bool RemoveIfPresent(const Node& parent, const std::string& name,
                     bool directory) {
  if (MissingAt(parent.fd.get(), name)) return true;
  return unlinkat(parent.fd.get(), name.c_str(), directory ? AT_REMOVEDIR : 0) ==
         0;
}
}  // namespace

// Recovery implementation is appended below from the bounded production split.
void HandleReconcile(FlMethodCall* call, FlValue* args) {
  Context context;
  Node hidden;
  OperationState state;
  std::string id;
  const char* error = nullptr;
  if (!Prepared(args, &context, &hidden, &id, &state, &error)) {
    RespondError(call, error);
    return;
  }
  if (state.phase == OperationPhase::rolledBack) {
    ReplyState(call, "rolledBack");
    return;
  }
  Node parent, source;
  std::string name;
  if (!OpenParent(context, &parent, &name, &error)) {
    RespondError(call, error);
    return;
  }
  bool committed = false;
  if (IsWrite(state.operation)) {
    committed = OpenFileAt(parent.fd.get(), name, O_RDONLY, &source) &&
                Verify(&source, state.stage_identity, state.stage_hash);
  } else if (state.operation == "delete_file") {
    Node quarantined;
    committed = MissingAt(parent.fd.get(), name) &&
                FileProof(hidden, id + ".stage", state.expected_identity,
                          state.expected_hash, &quarantined);
  } else if (state.operation == "move_file") {
    Node destination_parent, moved;
    std::string destination_name;
    committed = MissingAt(parent.fd.get(), name) &&
                OpenDestination(context, state, &destination_parent,
                                &destination_name, &error) &&
                FileProof(destination_parent, destination_name,
                          state.expected_identity, state.expected_hash, &moved);
  } else if (state.operation == "make_directory") {
    Node directory;
    committed = OpenDirAt(parent.fd.get(), name, &directory) &&
                Token(directory.id) == state.stage_identity;
  }
  if (committed) {
    if (state.phase != OperationPhase::committed &&
        !Persist(hidden, id, &state, OperationPhase::committed)) {
      RespondError(call, "mutation_indeterminate");
      return;
    }
    ReplyState(call, "committed");
    return;
  }
  bool before = state.expect_missing && MissingAt(parent.fd.get(), name);
  if (!state.expect_missing &&
      OpenFileAt(parent.fd.get(), name, O_RDONLY, &source)) {
    before = Verify(&source, state.expected_identity, state.expected_hash);
  }
  ReplyState(call, before ? "notCommitted" : "indeterminate");
}

void HandleRollback(FlMethodCall* call, FlValue* args) {
  Context context;
  Node hidden;
  OperationState state;
  std::string id;
  const char* error = nullptr;
  if (!Prepared(args, &context, &hidden, &id, &state, &error)) {
    RespondError(call, error);
    return;
  }
  if (state.phase == OperationPhase::rolledBack) {
    RespondSuccess(call);
    return;
  }
  if (state.phase == OperationPhase::committed) {
    RespondError(call, "already_committed");
    return;
  }
  Node parent, source;
  std::string name;
  if (!OpenParent(context, &parent, &name, &error)) {
    RespondError(call, error);
    return;
  }
  if (state.phase != OperationPhase::prepared) {
    if (IsWrite(state.operation)) {
      Node current, backup;
      const bool has_current =
          OpenFileAt(parent.fd.get(), name, O_RDONLY, &current);
      const bool result_present =
          has_current && Verify(&current, state.stage_identity, state.stage_hash);
      if (state.expect_missing) {
        if (result_present && unlinkat(parent.fd.get(), name.c_str(), 0) != 0) {
          RespondError(call, "mutation_indeterminate");
          return;
        }
      } else if (result_present &&
                 FileProof(hidden, id + ".stage", state.expected_identity,
                           state.expected_hash, &backup)) {
        if (RenameAt2(hidden.fd.get(), (id + ".stage").c_str(), parent.fd.get(),
                      name.c_str(), RENAME_EXCHANGE) != 0) {
          RespondError(call, "mutation_indeterminate");
          return;
        }
      } else if (!has_current &&
                 FileProof(hidden, id + ".stage", state.expected_identity,
                           state.expected_hash, &backup)) {
        if (RenameAt2(hidden.fd.get(), (id + ".stage").c_str(), parent.fd.get(),
                      name.c_str(), RENAME_NOREPLACE) != 0) {
          RespondError(call, "mutation_indeterminate");
          return;
        }
      } else if (!has_current ||
                 !Verify(&current, state.expected_identity,
                         state.expected_hash)) {
        RespondError(call, "mutation_indeterminate");
        return;
      }
    } else if (state.operation == "delete_file") {
      Node quarantined;
      if (MissingAt(parent.fd.get(), name) &&
          FileProof(hidden, id + ".stage", state.expected_identity,
                    state.expected_hash, &quarantined) &&
          RenameAt2(hidden.fd.get(), (id + ".stage").c_str(),
                    parent.fd.get(), name.c_str(), RENAME_NOREPLACE) != 0) {
        RespondError(call, "mutation_indeterminate");
        return;
      }
    } else if (state.operation == "move_file") {
      Node destination_parent, moved;
      std::string destination_name;
      if (!OpenDestination(context, state, &destination_parent,
                           &destination_name, &error)) {
        RespondError(call, error);
        return;
      }
      if (MissingAt(parent.fd.get(), name) &&
          FileProof(destination_parent, destination_name,
                    state.expected_identity, state.expected_hash, &moved) &&
          RenameAt2(destination_parent.fd.get(), destination_name.c_str(),
                    parent.fd.get(), name.c_str(), RENAME_NOREPLACE) != 0) {
        RespondError(call, "mutation_indeterminate");
        return;
      }
    } else if (state.operation == "make_directory") {
      Node directory;
      if (OpenDirAt(parent.fd.get(), name, &directory) &&
          Token(directory.id) == state.stage_identity &&
          unlinkat(parent.fd.get(), name.c_str(), AT_REMOVEDIR) != 0) {
        RespondError(call, "mutation_indeterminate");
        return;
      }
    }
    if (fsync(parent.fd.get()) != 0) {
      RespondError(call, "mutation_indeterminate");
      return;
    }
  }
  if (!Persist(hidden, id, &state, OperationPhase::rolledBack)) {
    RespondError(call, "mutation_indeterminate");
    return;
  }
  RespondSuccess(call);
}

void HandleCleanup(FlMethodCall* call, FlValue* args) {
  auto receipt = Lookup(args, "prepared");
  std::string id, token;
  const char* error = nullptr;
  if (!receipt || fl_value_get_type(receipt) != FL_VALUE_TYPE_MAP ||
      fl_value_get_length(receipt) != 2 ||
      !StringArg(receipt, "operationId", &id) || !SafeOperationId(id) ||
      !StringArg(receipt, "token", &token) || token.size() != 43) {
    RespondError(call, "invalid_prepared_receipt");
    return;
  }
  Context context;
  g_autoptr(FlValue) probe = fl_value_new_map();
  fl_value_set_string_take(probe, "root", fl_value_ref(Lookup(args, "root")));
  fl_value_set_string_take(probe, "sessionKey",
                           fl_value_ref(Lookup(args, "sessionKey")));
  fl_value_set_string_take(probe, "rootIdentity",
                           fl_value_ref(Lookup(args, "rootIdentity")));
  fl_value_set_string_take(probe, "path", fl_value_new_string(""));
  if (!OpenContext(probe, false, &context, &error)) {
    RespondError(call, error);
    return;
  }
  Node hidden;
  if (!EnsureHidden(&context, &hidden, &error)) {
    RespondError(call, error);
    return;
  }
  const bool state_missing = MissingAt(hidden.fd.get(), id + ".state");
  const bool stage_missing = MissingAt(hidden.fd.get(), id + ".stage");
  const bool backup_missing = MissingAt(hidden.fd.get(), id + ".backup");
  if (state_missing) {
    if (stage_missing && backup_missing) {
      RespondSuccess(call);
      return;
    }
    RespondError(call, "mutation_indeterminate");
    return;
  }
  OperationState state;
  if (!LoadOperationState(hidden, id, token, &state) ||
      state.root_identity != Token(context.root.id) ||
      state.session_identity != Token(context.session.id)) {
    RespondError(call, "invalid_prepared_receipt");
    return;
  }
  if (!RemoveIfPresent(hidden, id + ".stage",
                       state.operation == "make_directory") ||
      !RemoveIfPresent(hidden, id + ".backup", false) ||
      !DeleteOperationState(hidden, id)) {
    RespondError(call, "mutation_indeterminate");
    return;
  }
  RespondSuccess(call);
}
}  // namespace workspace
