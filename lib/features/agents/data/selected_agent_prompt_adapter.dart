import '../../memory/application/context_injector.dart';
import 'agent_catalog_storage.dart';
import 'agent_metadata_service.dart';

class SelectedAgentPromptAdapter implements AgentPromptSource {
  const SelectedAgentPromptAdapter(this._storage, this._metadata);

  final AgentCatalogStorage _storage;
  final AgentMetadataService _metadata;

  @override
  Future<String?> readActivePrompt() async {
    final catalog = await _metadata.compose(await _storage.discover());
    return catalog.selected?.definition.prompt;
  }
}
