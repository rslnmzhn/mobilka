import 'dart:convert';

enum WorkspaceStorageKind { path, saf }

/// Neutral identity of the owner-selected workspace root.
final class WorkspaceRootLocation {
  const WorkspaceRootLocation({
    required this.kind,
    required this.value,
    required this.identity,
  });

  final WorkspaceStorageKind kind;
  final String value;
  final String identity;

  bool get isContentUri => kind == WorkspaceStorageKind.saf;
}

/// Compile-time marker for a request-scoped storage authority.
abstract interface class WorkspaceBoundaryCapability {}

/// Immutable, serializable identity for an owner-selected workspace grant.
final class WorkspaceBindingSnapshot {
  const WorkspaceBindingSnapshot({
    required this.isContentUri,
    required this.value,
    required this.identity,
    this.rootIdentity,
  });

  final bool isContentUri;
  final String value;
  final String identity;
  final String? rootIdentity;

  WorkspaceBindingSnapshot withRootIdentity(String rootIdentity) =>
      WorkspaceBindingSnapshot(
        isContentUri: isContentUri,
        value: value,
        identity: identity,
        rootIdentity: rootIdentity,
      );

  Map<String, Object?> toJson() => {
    'isContentUri': isContentUri,
    'value': value,
    'identity': identity,
    if (rootIdentity != null) 'rootIdentity': rootIdentity,
  };

  factory WorkspaceBindingSnapshot.fromJson(Map<dynamic, dynamic> source) {
    final json = Map<String, Object?>.from(source);
    if ((json.length != 3 && json.length != 4) ||
        !json.keys.toSet().containsAll(const {
          'isContentUri',
          'value',
          'identity',
        }) ||
        json.keys.any(
          (key) => !const {
            'isContentUri',
            'value',
            'identity',
            'rootIdentity',
          }.contains(key),
        ) ||
        json['isContentUri'] is! bool ||
        json['value'] is! String ||
        json['identity'] is! String ||
        (json['rootIdentity'] != null && json['rootIdentity'] is! String)) {
      throw const FormatException('Invalid workspace binding snapshot.');
    }
    final value = json['value']! as String;
    final identity = json['identity']! as String;
    final rootIdentity = json['rootIdentity'] as String?;
    if (value.isEmpty ||
        identity.isEmpty ||
        utf8.encode(identity).length > 4096 ||
        (rootIdentity != null &&
            (rootIdentity.isEmpty ||
                utf8.encode(rootIdentity).length > 1024))) {
      throw const FormatException('Invalid workspace binding identity.');
    }
    return WorkspaceBindingSnapshot(
      isContentUri: json['isContentUri']! as bool,
      value: value,
      identity: identity,
      rootIdentity: rootIdentity,
    );
  }
}

/// Opaque request-scoped authority. Platform adapters own the capability.
abstract class WorkspaceBinding {
  const WorkspaceBinding();
  const factory WorkspaceBinding.fakeForTest() = TestWorkspaceBinding;
  WorkspaceBoundaryCapability get capability;
  WorkspaceRootLocation get location;
  Future<void> revalidateAccess();
  String get permissionSnapshot;
  WorkspaceBindingSnapshot get snapshot;
}

/// Identity-only binding used by boundary/coordinator tests.
final class TestWorkspaceBinding implements WorkspaceBinding {
  const TestWorkspaceBinding({
    this.testSnapshot = const WorkspaceBindingSnapshot(
      isContentUri: false,
      value: 'test-root',
      identity: 'false:',
      rootIdentity: 'false:',
    ),
  });

  final WorkspaceBindingSnapshot testSnapshot;

  @override
  WorkspaceBoundaryCapability get capability => const _TestCapability();
  @override
  WorkspaceRootLocation get location => WorkspaceRootLocation(
    kind: testSnapshot.isContentUri
        ? WorkspaceStorageKind.saf
        : WorkspaceStorageKind.path,
    value: testSnapshot.value,
    identity: testSnapshot.identity,
  );
  @override
  String get permissionSnapshot => testSnapshot.identity;
  @override
  WorkspaceBindingSnapshot get snapshot => testSnapshot;
  @override
  Future<void> revalidateAccess() async {}
}

final class _TestCapability implements WorkspaceBoundaryCapability {
  const _TestCapability();
}
