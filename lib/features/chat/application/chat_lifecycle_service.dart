import '../../memory/application/update_memory_file_service.dart';
import '../domain/pending_memory_proposal.dart';
import 'chat_streaming_coordinator.dart';
import 'chat_tool_runtime.dart';
import 'pending_workspace_binding_store.dart';
import 'conversation_mutation.dart';

typedef ChatLifecycleGenerationFactory =
    ChatLifecycleGeneration Function(
      int locationRevision,
      PendingWorkspaceBindingStore workspaceBindings,
      PersistConversationMutation persistMutation,
    );

class ChatLifecycleGeneration {
  const ChatLifecycleGeneration({
    required this.coordinator,
    required this.memoryRuntime,
    required this.memoryUpdates,
  });

  final ChatStreamingCoordinator coordinator;
  final MemoryProposalRuntime? memoryRuntime;
  final UpdateMemoryFileService? memoryUpdates;
}

class MemoryDecisionServices {
  const MemoryDecisionServices({
    required this.coordinator,
    required this.runtime,
    required this.updates,
  });

  final ChatStreamingCoordinator coordinator;
  final MemoryProposalRuntime? runtime;
  final UpdateMemoryFileService? updates;
}

/// Owns revision-sensitive streaming infrastructure without owning chat state.
///
/// Canonical conversations remain in [ChatController]. Generations are kept
/// only while their request is running or one of their proposals is pending,
/// so location changes cannot redirect request-scoped workspace authority.
class ChatLifecycleService {
  ChatLifecycleService({
    required ChatLifecycleGenerationFactory generationFactory,
    required PersistConversationMutation persistMutation,
  }) : _generationFactory = generationFactory,
       _persistMutation = persistMutation;

  final ChatLifecycleGenerationFactory _generationFactory;
  final PersistConversationMutation _persistMutation;
  final PendingWorkspaceBindingStore _workspaceBindings =
      PendingWorkspaceBindingStore();
  final List<_Generation> _generations = [];
  final List<_PendingDecision> _pendingDecisions = [];
  _Generation? _current;
  bool _disposed = false;

  ChatStreamingCoordinator coordinatorForRequest(int locationRevision) {
    _checkNotDisposed();
    final current = _current;
    if (current == null || current.locationRevision != locationRevision) {
      _current = _createGeneration(locationRevision);
      _disposeUnusedGenerations();
    }
    return _current!.value.coordinator;
  }

  ChatStreamingCoordinator currentCoordinator(int locationRevision) =>
      coordinatorForRequest(locationRevision);

  Future<void> run(
    ChatStreamRequest request, {
    required int locationRevision,
  }) async {
    final generation = _generationForCoordinator(
      coordinatorForRequest(locationRevision),
    );
    await generation.value.coordinator.run(request);
    _disposeUnusedGenerations();
  }

  MemoryDecisionServices servicesForDecision(
    String conversationId,
    PendingMemoryProposal proposal, {
    required int locationRevision,
  }) {
    _checkNotDisposed();
    _Generation? generation;
    for (final entry in _pendingDecisions) {
      if (entry.conversationId == conversationId &&
          entry.proposal.hasSameIdentity(proposal)) {
        generation = entry.generation;
        break;
      }
    }
    final selected =
        generation ??
        _generationForCoordinator(currentCoordinator(locationRevision));
    if (generation == null) {
      _pendingDecisions.add(
        _PendingDecision(conversationId, proposal, selected),
      );
    }
    return MemoryDecisionServices(
      coordinator: selected.value.coordinator,
      runtime: selected.value.memoryRuntime,
      updates: selected.value.memoryUpdates,
    );
  }

  void completeDecision(String conversationId, PendingMemoryProposal proposal) {
    _pendingDecisions.removeWhere(
      (entry) =>
          entry.conversationId == conversationId &&
          entry.proposal.hasSameIdentity(proposal),
    );
    _disposeUnusedGenerations();
  }

  void cancel(String conversationId) {
    for (final generation in _generations) {
      generation.value.coordinator.cancel(conversationId);
    }
  }

  Future<void> cancelAndWait(String conversationId) async {
    for (final generation in List<_Generation>.of(_generations)) {
      await generation.value.coordinator.cancelAndWait(conversationId);
    }
    _pendingDecisions.removeWhere(
      (entry) => entry.conversationId == conversationId,
    );
    _disposeUnusedGenerations();
  }

  ChatStreamingCoordinator coordinatorForRetry(int locationRevision) =>
      coordinatorForRequest(locationRevision);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final generation in _generations) {
      generation.value.coordinator.dispose();
    }
    _generations.clear();
    _pendingDecisions.clear();
    _workspaceBindings.reset();
    _current = null;
  }

  _Generation _createGeneration(int revision) {
    late final _Generation generation;
    final value = _generationFactory(revision, _workspaceBindings, (
      conversationId,
      mutation,
    ) async {
      final conversation = await _persistMutation(conversationId, mutation);
      if (conversation == null) return null;
      final proposal = conversation.pendingMemoryProposal;
      if (proposal != null &&
          !_pendingDecisions.any(
            (entry) =>
                entry.conversationId == conversation.id &&
                entry.proposal.hasSameIdentity(proposal),
          )) {
        _pendingDecisions.add(
          _PendingDecision(conversation.id, proposal, generation),
        );
      }
      return conversation;
    });
    generation = _Generation(revision, value);
    _generations.add(generation);
    return generation;
  }

  _Generation _generationForCoordinator(ChatStreamingCoordinator coordinator) =>
      _generations.firstWhere(
        (generation) => identical(generation.value.coordinator, coordinator),
      );

  void _disposeUnusedGenerations() {
    final unused = _generations
        .where(
          (generation) =>
              !identical(generation, _current) &&
              !_pendingDecisions.any(
                (decision) => identical(decision.generation, generation),
              ),
        )
        .toList();
    for (final generation in unused) {
      generation.value.coordinator.dispose();
      _generations.remove(generation);
    }
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('Chat lifecycle service is disposed');
  }
}

class _Generation {
  const _Generation(this.locationRevision, this.value);

  final int locationRevision;
  final ChatLifecycleGeneration value;
}

class _PendingDecision {
  const _PendingDecision(this.conversationId, this.proposal, this.generation);

  final String conversationId;
  final PendingMemoryProposal proposal;
  final _Generation generation;
}
