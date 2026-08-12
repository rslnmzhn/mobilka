// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'agents_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$agentCatalogStorageHash() =>
    r'b196041953263807ff114a55109f7ed870c301e6';

/// See also [agentCatalogStorage].
@ProviderFor(agentCatalogStorage)
final agentCatalogStorageProvider = Provider<AgentCatalogStorage>.internal(
  agentCatalogStorage,
  name: r'agentCatalogStorageProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$agentCatalogStorageHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef AgentCatalogStorageRef = ProviderRef<AgentCatalogStorage>;
String _$agentMetadataServiceHash() =>
    r'f0b852c163628aaca4f12d7baa107a3b3457f908';

/// See also [agentMetadataService].
@ProviderFor(agentMetadataService)
final agentMetadataServiceProvider = Provider<AgentMetadataService>.internal(
  agentMetadataService,
  name: r'agentMetadataServiceProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$agentMetadataServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef AgentMetadataServiceRef = ProviderRef<AgentMetadataService>;
String _$agentImportPickerHash() => r'e6bd03a5c2b644b90e6781424a12fb40243ef18d';

/// See also [agentImportPicker].
@ProviderFor(agentImportPicker)
final agentImportPickerProvider = Provider<AgentImportPicker>.internal(
  agentImportPicker,
  name: r'agentImportPickerProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$agentImportPickerHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef AgentImportPickerRef = ProviderRef<AgentImportPicker>;
String _$selectedAgentPromptAdapterHash() =>
    r'94a222b77c96712a687af0f65f2771cd51db4d1d';

/// See also [selectedAgentPromptAdapter].
@ProviderFor(selectedAgentPromptAdapter)
final selectedAgentPromptAdapterProvider =
    Provider<SelectedAgentPromptAdapter>.internal(
      selectedAgentPromptAdapter,
      name: r'selectedAgentPromptAdapterProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$selectedAgentPromptAdapterHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef SelectedAgentPromptAdapterRef = ProviderRef<SelectedAgentPromptAdapter>;
String _$agentsControllerHash() => r'24da8d92ea34c4a685e8593344e7c431b40702c4';

/// See also [AgentsController].
@ProviderFor(AgentsController)
final agentsControllerProvider =
    AutoDisposeAsyncNotifierProvider<AgentsController, AgentCatalog>.internal(
      AgentsController.new,
      name: r'agentsControllerProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$agentsControllerHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$AgentsController = AutoDisposeAsyncNotifier<AgentCatalog>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member
