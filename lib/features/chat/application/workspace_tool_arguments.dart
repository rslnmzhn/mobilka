import '../../memory/domain/strict_json_object_parser.dart';
import '../../workspace/domain/workspace_models.dart';

Map<String, Object?> parseWorkspaceArguments(String source) =>
    StrictJsonObjectParser.decode(
      source,
      maxSourceBytes: workspaceMaxToolArgumentsBytes,
      maxNodes: 128,
      maxStringBytes: workspaceMaxTextBytes,
    );

void requireWorkspaceKeys(
  Map<String, Object?> args, {
  required Set<String> required,
  Set<String> optional = const {},
}) {
  final allowed = {...required, ...optional};
  if (!args.keys.toSet().containsAll(required) ||
      args.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('invalid_workspace_arguments');
  }
}
