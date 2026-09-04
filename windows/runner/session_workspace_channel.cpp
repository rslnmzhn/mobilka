#include "session_workspace.h"
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

void RegisterSessionWorkspaceChannel(flutter::BinaryMessenger* messenger) {
  using namespace workspace;
  static std::unique_ptr<flutter::MethodChannel<Value>> owner;
  owner = std::make_unique<flutter::MethodChannel<Value>>(messenger,
      "mobilka/session_workspace", &flutter::StandardMethodCodec::GetInstance());
  owner->SetMethodCallHandler([](const auto& call, Result result) {
    try {
    const auto* args = std::get_if<Map>(call.arguments());
    if (!args) { Error(result, "invalid_argument"); return; }
    const auto& method = call.method_name();
    if (method == "rootIdentity") HandleRootIdentity(*args, std::move(result));
    else if (method == "metadata") HandleMetadata(*args, std::move(result));
    else if (method == "list") HandleList(*args, std::move(result));
    else if (method == "read") HandleRead(*args, std::move(result));
    else if (method == "prepareMutation") HandlePrepare(*args, std::move(result));
    else if (method == "commitPrepared") HandleCommit(*args, std::move(result));
    else if (method == "reconcilePrepared") HandleReconcile(*args, std::move(result));
    else if (method == "rollbackPrepared") HandleRollback(*args, std::move(result));
    else if (method == "cleanupPrepared") HandleCleanup(*args, std::move(result));
    else result->NotImplemented();
    } catch (...) {
      Error(result, "mutation_indeterminate");
    }
  });
}
