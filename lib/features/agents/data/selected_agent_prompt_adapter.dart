import '../../memory/application/context_injector.dart';
import '../domain/agent_catalog.dart';

class SelectedAgentPromptAdapter implements AgentPromptSource {
  const SelectedAgentPromptAdapter(this._catalog);

  final Future<AgentCatalog> _catalog;

  @override
  Future<String?> readActivePrompt() async {
    final catalog = await _catalog;
    return catalog.selected?.definition.prompt;
  }
}
