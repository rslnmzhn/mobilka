import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/route_locations.dart';
import '../../models/application/models_controller.dart';
import '../application/chat_controller.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import 'chat_edge_swipe_access.dart';
import 'chat_header.dart';
import 'chat_screen_body.dart';
import 'conversations_drawer.dart';
import '../../shell/presentation/shell_navigation_scope.dart';
import 'conversation_display_title.dart';

export 'chat_composer.dart' show ChatComposer;
export 'chat_header.dart' show ModelPickerSheet;

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final composer = TextEditingController();
  final scrollController = ScrollController();

  /// Auto-follow streaming output while the user is at the bottom; a swipe
  /// up pauses it until they return (roadmap: chat UX).
  var _pinnedToBottom = true;
  var _presentingRoute = false;
  var _programmaticScroll = false;
  var _userScrollActive = false;
  var _navigationHideScheduled = false;

  @override
  void initState() {
    super.initState();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification) {
      _userScrollActive = notification.direction != ScrollDirection.idle;
      if (notification.direction == ScrollDirection.reverse &&
          notification.metrics.axis == Axis.vertical) {
        _scheduleNavigationHide();
      }
      if (_userScrollActive) _updatePinned(notification.metrics);
    } else if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrollActive = true;
    } else if (notification is ScrollUpdateNotification &&
        !_programmaticScroll &&
        (_userScrollActive || notification.dragDetails != null)) {
      _updatePinned(notification.metrics);
    } else if (notification is ScrollEndNotification) {
      if (!_programmaticScroll) _updatePinned(notification.metrics);
      _userScrollActive = false;
    }
    return false;
  }

  void _scheduleNavigationHide() {
    if (_navigationHideScheduled) return;
    final navigation = ShellNavigationScope.maybeOf(context);
    if (!(navigation?.chatNavigationVisible ?? false)) return;
    _navigationHideScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigationHideScheduled = false;
      if (!mounted) return;
      ShellNavigationScope.maybeOf(context)?.hideNavigation();
    });
  }

  void _updatePinned(ScrollMetrics metrics) {
    if (metrics.axis == Axis.vertical) {
      final nearBottom = metrics.pixels <= metrics.minScrollExtent + 80;
      if (nearBottom != _pinnedToBottom) {
        setState(() => _pinnedToBottom = nearBottom);
      }
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _programmaticScroll) return;
    _userScrollActive = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _programmaticScroll) return;
      if (scrollController.hasClients) {
        _updatePinned(scrollController.position);
      }
      _userScrollActive = false;
    });
  }

  void _scrollToBottom() {
    if (!scrollController.hasClients || !_pinnedToBottom) return;
    _programmaticScroll = true;
    scrollController.jumpTo(scrollController.position.minScrollExtent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _programmaticScroll = false;
    });
  }

  Future<String?> _pickModel(ModelsState models) async {
    if (!_canPresentRoute()) return null;
    _presentingRoute = true;
    try {
      return await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => ModelPickerSheet(models: models),
      );
    } finally {
      _presentingRoute = false;
    }
  }

  Future<void> _selectModel(ModelsState models) async {
    final modelId = await _pickModel(models);
    if (modelId == null) return;
    // Applies globally and to the active conversation so this chat actually
    // switches models.
    await ref.read(chatControllerProvider.notifier).applyModel(modelId);
  }

  Future<void> _showArtifacts() async {
    if (!_canPresentRoute()) return;
    final conversationId = ref
        .read(chatControllerProvider)
        .value
        ?.activeConversation
        ?.id;
    if (conversationId == null) return;
    _presentingRoute = true;
    try {
      await context.push<void>(sessionArtifactsLocation(conversationId));
    } finally {
      _presentingRoute = false;
    }
  }

  bool _canPresentRoute() =>
      !_presentingRoute &&
      !(scaffoldKey.currentState?.isDrawerOpen ?? false) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _showHistory() {
    if (!_canPresentRoute()) return;
    scaffoldKey.currentState?.openDrawer();
  }

  Future<void> _createConversation(ModelsState? models) async {
    if (models == null) return;
    var modelId = models.selectedModelId;
    if (!models.visibleModels.any((model) => model.id == modelId)) {
      modelId = await _pickModel(models);
      if (modelId == null) return;
      await ref.read(modelsControllerProvider.notifier).select(modelId);
    }
    final selectedModelId = modelId;
    if (selectedModelId == null) return;
    await ref
        .read(chatControllerProvider.notifier)
        .createConversation(selectedModelId);
  }

  @override
  void dispose() {
    composer.dispose();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    final models = ref.watch(modelsControllerProvider);
    _listenForVisibleMessages();
    return _scaffold(chat, models);
  }

  void _listenForVisibleMessages() {
    ref.listen<AsyncValue<ChatState>>(chatControllerProvider, (previous, next) {
      final before = previous?.valueOrNull?.activeConversation;
      final after = next.valueOrNull?.activeConversation;
      final switched = before?.id != after?.id;
      final visibleChanged =
          _messageFingerprint(before?.messages) !=
          _messageFingerprint(after?.messages);
      if (!switched && !visibleChanged) return;
      if (switched) _pinnedToBottom = true;
      if (_pinnedToBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    });
  }

  Widget _scaffold(
    AsyncValue<ChatState> chat,
    AsyncValue<ModelsState> models,
  ) => Scaffold(
    key: scaffoldKey,
    appBar: _appBar(chat, models),
    drawer: ConversationsDrawer(chat: chat),
    body: _body(chat, models),
  );

  PreferredSizeWidget _appBar(
    AsyncValue<ChatState> chat,
    AsyncValue<ModelsState> models,
  ) => ChatHeaderBar(
    title: _displayTitle(chat.value?.activeConversation),
    modelId: _nonBlank(
      chat.value?.activeConversation?.modelId ?? models.value?.selectedModelId,
    ),
    onModelPressed: models.value == null
        ? () {}
        : () => _selectModel(models.value!),
    onNewChat: models.isLoading
        ? null
        : () => _createConversation(models.value),
  );

  Widget _body(
    AsyncValue<ChatState> chat,
    AsyncValue<ModelsState> models,
  ) => Builder(
    builder: (context) {
      final navigation = ShellNavigationScope.maybeOf(context);
      void requestNavigation() {
        if (_canPresentRoute()) navigation?.showNavigation();
      }

      void hideNavigation() {
        navigation?.hideNavigation();
      }

      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyH, control: true):
              _showHistory,
          const SingleActivator(LogicalKeyboardKey.keyA, control: true):
              _showArtifacts,
          const SingleActivator(
            LogicalKeyboardKey.keyN,
            control: true,
            shift: true,
          ): requestNavigation,
        },
        child: Focus(
          autofocus: true,
          child: Semantics(
            customSemanticsActions: {
              CustomSemanticsAction(label: 'chat.search'.tr()): _showHistory,
              CustomSemanticsAction(label: 'artifacts.open'.tr()):
                  _showArtifacts,
              if (navigation?.chatNavigationVisible ?? false)
                CustomSemanticsAction(label: 'nav.hide'.tr()): hideNavigation
              else if (navigation != null)
                CustomSemanticsAction(label: 'nav.show'.tr()):
                    requestNavigation,
            },
            child: ChatEdgeSwipeAccess(
              canPresent: _canPresentRoute,
              onHistory: _showHistory,
              onArtifacts: _showArtifacts,
              child: ChatScreenBody(
                chat: chat,
                models: models,
                composer: composer,
                scrollController: scrollController,
                onCreateConversation: () => _createConversation(models.value),
                onPointerSignal: _onPointerSignal,
                onScrollNotification: _onScrollNotification,
                onSend: _send,
                onShowNavigation: requestNavigation,
                isNavigationVisible: navigation?.chatNavigationVisible ?? false,
              ),
            ),
          ),
        ),
      );
    },
  );

  void _send(String text, List<ChatAttachment> attachments) {
    composer.clear();
    _pinnedToBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    ref
        .read(chatControllerProvider.notifier)
        .send(text, attachments: attachments);
  }
}

String? _nonBlank(String? value) =>
    value == null || value.trim().isEmpty ? null : value;

String _displayTitle(Conversation? conversation) => conversation == null
    ? 'chatNoConversation'.tr()
    : conversationDisplayTitle(conversation);

String _messageFingerprint(List<ChatMessage>? messages) =>
    (messages ?? const [])
        .where((message) => message.role != ChatRole.tool)
        .map(
          (message) =>
              '${message.id}:${message.status.name}:${message.content.length}',
        )
        .join('|');
