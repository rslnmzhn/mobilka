import 'package:hive/hive.dart';

import '../../memory/data/memory_repository.dart';
import '../../workspace/data/workspace_recovery_journal.dart';
import '../data/conversation_store.dart';
import '../domain/conversation.dart';
import 'chat_workspace_startup_recovery.dart';

final class ChatControllerBootstrapService {
  const ChatControllerBootstrapService({
    required this.conversations,
    required this.memoryRepository,
  });

  final ConversationStore conversations;
  final MemoryRepository memoryRepository;

  Future<List<Conversation>> load() async {
    if (Hive.isBoxOpen('workspace_recovery')) {
      try {
        await ChatWorkspaceStartupRecovery(
          conversations: conversations,
          memoryRepository: memoryRepository,
          journal: HiveWorkspaceRecoveryJournal(),
        ).recover();
      } on Object {
        // Durable recovery remains pending without blocking unrelated chats.
      }
    }
    await conversations.recoverInterrupted();
    return conversations.loadAll();
  }
}
