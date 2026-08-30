import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:mobilka/core/links/external_link_launcher.dart';
import 'package:mobilka/features/artifacts/application/artifact_link_opener.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/presentation/chat_message_widgets.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  testWidgets('Markdown link and autolink launch canonical external URI', (
    tester,
  ) async {
    final launcher = _RecordingLauncher();
    await _pumpMessage(
      tester,
      '[Example](https://Example.COM:443/path) <https://example.org:443/a>',
      launcher,
    );
    _tapMarkdownLink(tester, 'Example', 'https://Example.COM:443/path');
    await tester.pump();
    _tapMarkdownLink(
      tester,
      'https://example.org:443/a',
      'https://example.org:443/a',
    );
    await tester.pump();
    expect(launcher.uris.map((uri) => uri.toString()), [
      'https://example.com/path',
      'https://example.org/a',
    ]);
  });

  testWidgets('invalid scheme never launches and shows safe feedback', (
    tester,
  ) async {
    final launcher = _RecordingLauncher();
    await _pumpMessage(tester, '[bad](javascript:alert(1))', launcher);
    await tester.tap(find.text('bad'));
    await tester.pump();
    expect(launcher.uris, isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('false and throwing launchers show failure feedback', (
    tester,
  ) async {
    for (final launcher in [
      _RecordingLauncher(result: false),
      _RecordingLauncher(error: StateError('private failure')),
    ]) {
      await _pumpMessage(tester, '[Example](https://example.com)', launcher);
      await tester.tap(find.text('Example'));
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('private failure'), findsNothing);
    }
  });

  testWidgets('links stay selectable, semantic, styled, and fit 320 pixels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpMessage(
      tester,
      '[Example](https://example.com/a)',
      _RecordingLauncher(),
    );
    expect(find.byType(SelectableText), findsWidgets);
    expect(tester.takeException(), isNull);
    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(markdown.selectable, isTrue);
    expect(markdown.onTapLink, isNotNull);
    expect(markdown.styleSheet?.a?.decoration, TextDecoration.underline);
    expect(markdown.styleSheet?.a?.color, isNotNull);
  });

  testWidgets('delayed launcher completion after unmount is ignored safely', (
    tester,
  ) async {
    final completer = Completer<bool>();
    await _pumpMessage(
      tester,
      '[Example](https://example.com)',
      _DelayedLauncher(completer.future),
    );
    await tester.tap(find.text('Example'));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    completer.complete(false);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('canonical internal link uses captured conversation only', (
    tester,
  ) async {
    final external = _RecordingLauncher();
    final calls = <({String id, String? conversation})>[];
    await _pumpMessage(
      tester,
      '[Report](mobilka-artifact:1-artifact?representation=docx)',
      external,
      conversationId: 'conversation-a',
      artifactOpen: (link, {required scope, conversationId}) async {
        calls.add((id: link.artifactId, conversation: conversationId));
        return ArtifactLinkOpenResult.opened;
      },
    );
    _tapMarkdownLink(
      tester,
      'Report',
      'mobilka-artifact:1-artifact?representation=docx',
    );
    await tester.pump();
    expect(calls, [(id: '1-artifact', conversation: 'conversation-a')]);
    expect(external.uris, isEmpty);
  });

  testWidgets('malformed internal variants never launch externally', (
    tester,
  ) async {
    final external = _RecordingLauncher();
    await _pumpMessage(tester, '[x](https://example.com)', external);
    for (final href in [
      'Mobilka-Artifact:1-artifact?representation=md',
      'mobilka-artifact:1-artifact?representation=md&extra=1',
      'mobilka-artifact:1-artifact?representation=md#fragment',
      'mobilka-artifact-lookalike:https://example.com',
    ]) {
      _tapMarkdownLink(tester, 'x', href);
      await tester.pump();
    }
    expect(external.uris, isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('delayed artifact completion after unmount is ignored', (
    tester,
  ) async {
    final completer = Completer<ArtifactLinkOpenResult>();
    await _pumpMessage(
      tester,
      '[Report](mobilka-artifact:1-artifact?representation=md)',
      _RecordingLauncher(),
      conversationId: 'conversation-a',
      artifactOpen: (link, {required scope, conversationId}) =>
          completer.future,
    );
    _tapMarkdownLink(
      tester,
      'Report',
      'mobilka-artifact:1-artifact?representation=md',
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    completer.complete(ArtifactLinkOpenResult.nativeOpenFailed);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test(
    'production adapter always requests external application mode',
    () async {
      LaunchMode? capturedMode;
      final launcher = UrlExternalLinkLauncher(
        launchFunction: (uri, mode) async {
          capturedMode = mode;
          return true;
        },
      );
      await launcher.launch(Uri.parse('https://example.com/'));
      expect(capturedMode, LaunchMode.externalApplication);
    },
  );
}

Future<void> _pumpMessage(
  WidgetTester tester,
  String content,
  ExternalLinkLauncher launcher, {
  String? conversationId,
  ArtifactLinkOpenCallback? artifactOpen,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: MessageCard(
        message: ChatMessage(
          id: 'message',
          role: ChatRole.assistant,
          content: content,
          createdAt: DateTime(2026),
        ),
        externalLinkLauncher: launcher,
        renderingConversationId: conversationId,
        artifactLinkOpen: artifactOpen,
      ),
    ),
  ),
);

void _tapMarkdownLink(WidgetTester tester, String text, String href) {
  final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
  markdown.onTapLink!(text, href, '');
}

class _RecordingLauncher implements ExternalLinkLauncher {
  _RecordingLauncher({this.result = true, this.error});
  final bool result;
  final Object? error;
  final uris = <Uri>[];

  @override
  Future<bool> launch(Uri uri) async {
    uris.add(uri);
    if (error != null) throw error!;
    return result;
  }
}

class _DelayedLauncher implements ExternalLinkLauncher {
  const _DelayedLauncher(this.result);
  final Future<bool> result;

  @override
  Future<bool> launch(Uri uri) => result;
}
