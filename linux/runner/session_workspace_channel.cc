#include "session_workspace.h"

#include <cstring>

namespace {
void MethodCall(FlMethodChannel*, FlMethodCall* call, gpointer) {
  try {
  FlValue* args = fl_method_call_get_args(call);
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    workspace::RespondError(call, "invalid_argument");
    return;
  }
  const char* method = fl_method_call_get_name(call);
  if (!strcmp(method, "rootIdentity"))
    workspace::HandleRootIdentity(call, args);
  else if (!strcmp(method, "metadata"))
    workspace::HandleMetadata(call, args);
  else if (!strcmp(method, "list"))
    workspace::HandleList(call, args);
  else if (!strcmp(method, "read"))
    workspace::HandleRead(call, args);
  else if (!strcmp(method, "prepareMutation"))
    workspace::HandlePrepare(call, args);
  else if (!strcmp(method, "commitPrepared"))
    workspace::HandleCommit(call, args);
  else if (!strcmp(method, "reconcilePrepared"))
    workspace::HandleReconcile(call, args);
  else if (!strcmp(method, "rollbackPrepared"))
    workspace::HandleRollback(call, args);
  else if (!strcmp(method, "cleanupPrepared"))
    workspace::HandleCleanup(call, args);
  else {
    g_autoptr(GError) error = nullptr;
    fl_method_call_respond_not_implemented(call, &error);
  }
  } catch (...) {
    workspace::RespondError(call, "mutation_indeterminate");
  }
}
}  // namespace

FlMethodChannel* register_session_workspace_channel(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  auto channel = fl_method_channel_new(
      messenger, "mobilka/session_workspace", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, MethodCall, nullptr, nullptr);
  return channel;
}
