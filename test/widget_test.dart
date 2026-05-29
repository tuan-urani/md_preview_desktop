import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md_desktop/main.dart';

void main() {
  testWidgets('renders the empty editor state', (tester) async {
    await tester.pumpWidget(const MdPreviewApp());

    expect(find.text('Open Markdown File'), findsOneWidget);
    expect(find.byIcon(Icons.description_outlined), findsWidgets);
  });

  testWidgets('double clicking a preview block reveals its source offset', (
    tester,
  ) async {
    int? revealedOffset;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [EditorThemeColors.darkMode]),
        home: Scaffold(
          body: PreviewPane(
            markdown: '# Intro\n\nSecond paragraph',
            imageDirectory: null,
            onTapLink: (_) async {},
            onRevealSource: (offset) {
              revealedOffset = offset;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Second paragraph'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Second paragraph'));
    await tester.pump();

    expect(revealedOffset, '# Intro\n\n'.length);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('double clicking a list item reveals that source line', (
    tester,
  ) async {
    int? revealedOffset;
    const markdown =
        '## Provider Detail\n'
        'Provider Detail includes:\n'
        '* Header provider\n'
        '* Logo\n'
        '* Country\n'
        '* Language\n';

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [EditorThemeColors.darkMode]),
        home: Scaffold(
          body: PreviewPane(
            markdown: markdown,
            imageDirectory: null,
            onTapLink: (_) async {},
            onRevealSource: (offset) {
              revealedOffset = offset;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Country'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Country'));
    await tester.pump();

    expect(revealedOffset, markdown.indexOf('* Country'));
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('desktop preview uses one selectable region for copying', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [EditorThemeColors.darkMode]),
        home: Scaffold(
          body: PreviewPane(
            markdown: '# Heading\n\nParagraph to copy',
            imageDirectory: null,
            onTapLink: (_) async {},
            onRevealSource: (_) {},
          ),
        ),
      ),
    );

    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('ctrl f opens preview find and reports matches', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [EditorThemeColors.darkMode]),
        home: Scaffold(
          body: PreviewPane(
            markdown: '# Notes\n\nCountry\n\nOther country',
            imageDirectory: null,
            onTapLink: (_) async {},
            onRevealSource: (_) {},
          ),
        ),
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('preview-find-input')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('preview-find-input')),
      'country',
    );
    await tester.pump();

    expect(find.text('1/2'), findsOneWidget);
    expect(_hasTextSpanText(tester, 'Other '), isTrue);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    final findField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('preview-find-input')),
    );
    expect(findField.focusNode?.hasFocus, isTrue);
    expect(find.text('2/2'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('preview-find-input')),
      findsNothing,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('narrow screens use the mobile file browser', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MdPreviewApp());

    expect(find.text('Markdown Files'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('mobile-open-file')),
      findsOneWidget,
    );
    expect(find.text('EXPLORER'), findsNothing);
  });

  testWidgets('mobile preview long press does not reveal source directly', (
    tester,
  ) async {
    int? revealedOffset;
    const markdown =
        '## Provider Detail\n'
        '* Header provider\n'
        '* Country\n'
        '* Language\n';

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [EditorThemeColors.darkMode]),
        home: Scaffold(
          body: PreviewPane(
            showPanelHeader: false,
            selectable: true,
            revealOnDoubleTap: false,
            selectionToolbarEditEnabled: true,
            contentPadding: const EdgeInsets.all(20),
            markdown: markdown,
            imageDirectory: null,
            onTapLink: (_) async {},
            onRevealSource: (offset) {
              revealedOffset = offset;
            },
          ),
        ),
      ),
    );

    await tester.longPress(find.text('Country'));
    await tester.pump();

    expect(revealedOffset, isNull);
  });

  testWidgets('mobile system back returns source to preview', (tester) async {
    var doneCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [EditorThemeColors.darkMode]),
        home: MobileDocumentWorkspace(
          document: MarkdownDocument(
            filePath: '/tmp/notes.md',
            markdown: '# Notes',
            lastModified: null,
          ),
          viewMode: MarkdownViewMode.source,
          isLoading: false,
          onBackToFiles: () {},
          onEditPressed: () {},
          onDonePressed: () {
            doneCount++;
          },
          preview: const SizedBox(),
          source: const SizedBox(),
          onOpenPressed: () {},
        ),
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(doneCount, 1);
  });

  testWidgets('preview keeps its scroll position after switching tabs', (
    tester,
  ) async {
    await tester.pumpWidget(const _PreviewSwitchHarness());

    final previewList = find.byType(ListView).first;
    final scrollable =
        find
            .descendant(of: previewList, matching: find.byType(Scrollable))
            .first;
    await tester.drag(previewList, const Offset(0, -700));
    await tester.pumpAndSettle();
    final beforeSwitch =
        tester.state<ScrollableState>(scrollable).position.pixels;
    expect(beforeSwitch, greaterThan(0));

    await tester.tap(find.text('Source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    final restoredScrollable =
        find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first;
    final restoredPosition =
        tester.state<ScrollableState>(restoredScrollable).position.pixels;
    expect(restoredPosition, closeTo(beforeSwitch, 0.1));
  });

  testWidgets('revealed source near the end is aligned at the top', (
    tester,
  ) async {
    final markdown = List.generate(60, (index) => 'Line $index').join('\n');
    final targetOffset = markdown.indexOf('Line 55');

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          extensions: const [EditorThemeColors.darkMode],
        ),
        home: Scaffold(
          body: SizedBox(
            height: 260,
            child: MarkdownSourceEditor(
              filePath: '/tmp/test.md',
              markdown: markdown,
              onChanged: (_, __) {},
              revealRequest: SourceRevealRequest(id: 1, offset: targetOffset),
            ),
          ),
        ),
      ),
    );
    for (var frame = 0; frame < 14; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    final editorTop =
        tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('source-editor-scroll-view')),
            )
            .dy;
    final targetLineTop = tester.getTopLeft(find.text('56')).dy;

    expect(targetLineTop - editorTop, lessThan(60));
  });

  testWidgets('a consumed source reveal does not replay after tab switches', (
    tester,
  ) async {
    var consumedCount = 0;
    await tester.pumpWidget(
      _SourceRequestSwitchHarness(
        onConsumed: () {
          consumedCount++;
        },
      ),
    );

    for (var frame = 0; frame < 14; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(consumedCount, 1);

    await tester.tap(find.byKey(const ValueKey<String>('show-preview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('show-source')));
    for (var frame = 0; frame < 14; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    expect(consumedCount, 1);
  });

  testWidgets('opening source without a reveal starts at the top', (
    tester,
  ) async {
    final markdown = List.generate(80, (index) => 'Line $index').join('\n');

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [EditorThemeColors.darkMode]),
        home: Scaffold(
          body: SizedBox(
            height: 260,
            child: MarkdownSourceEditor(
              filePath: '/tmp/initial.md',
              markdown: markdown,
              onChanged: (_, __) {},
              revealRequest: null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final sourceScrollable =
        find
            .descendant(
              of: find.byKey(
                const ValueKey<String>('source-editor-scroll-view'),
              ),
              matching: find.byType(Scrollable),
            )
            .first;
    final position =
        tester.state<ScrollableState>(sourceScrollable).position.pixels;

    expect(position, 0);
  });

  testWidgets('ctrl f searches source and retains find focus after enter', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          extensions: const [EditorThemeColors.darkMode],
        ),
        home: Scaffold(
          body: SizedBox(
            height: 260,
            child: MarkdownSourceEditor(
              filePath: '/tmp/search.md',
              markdown: 'Country\nOther\nCountry',
              onChanged: (_, __) {},
              revealRequest: null,
            ),
          ),
        ),
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey<String>('source-find-input')),
      'Country',
    );
    await tester.pump();

    expect(find.text('1/2'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    final findField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('source-find-input')),
    );
    final selectionTheme = tester.widget<TextSelectionTheme>(
      find.byKey(const ValueKey<String>('source-search-selection-theme')),
    );
    expect(findField.focusNode?.hasFocus, isTrue);
    expect(find.text('2/2'), findsOneWidget);
    expect(selectionTheme.data.selectionColor, const Color(0xFFB36B00));

    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('source-find-input')),
      findsNothing,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(find.text('1/2'), findsOneWidget);
  });
}

bool _hasTextSpanText(WidgetTester tester, String text) {
  for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
    if (_textSpanPlainText(richText.text).contains(text)) {
      return true;
    }
  }
  for (final textWidget in tester.widgetList<Text>(find.byType(Text))) {
    final textSpan = textWidget.textSpan;
    if (textSpan != null && _textSpanPlainText(textSpan).contains(text)) {
      return true;
    }
  }
  return false;
}

String _textSpanPlainText(InlineSpan span) {
  if (span is! TextSpan) {
    return '';
  }
  final buffer = StringBuffer(span.text ?? '');
  final children = span.children;
  if (children != null) {
    for (final child in children) {
      buffer.write(_textSpanPlainText(child));
    }
  }
  return buffer.toString();
}

class _PreviewSwitchHarness extends StatefulWidget {
  const _PreviewSwitchHarness();

  @override
  State<_PreviewSwitchHarness> createState() => _PreviewSwitchHarnessState();
}

class _PreviewSwitchHarnessState extends State<_PreviewSwitchHarness> {
  bool _showPreview = true;
  double _previewScrollOffset = 0;

  @override
  Widget build(BuildContext context) {
    final body =
        _showPreview
            ? PreviewPane(
              initialScrollOffset: _previewScrollOffset,
              onScrollPositionChanged: (offset) {
                _previewScrollOffset = offset;
              },
              markdown:
                  List.generate(80, (index) => 'Paragraph $index\n\n').join(),
              imageDirectory: null,
              onTapLink: (_) async {},
              onRevealSource: (_) {},
            )
            : const Center(child: Text('Source content'));

    return MaterialApp(
      theme: ThemeData(extensions: const [EditorThemeColors.darkMode]),
      home: Scaffold(
        appBar: AppBar(
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _showPreview = !_showPreview;
                });
              },
              child: Text(_showPreview ? 'Source' : 'Preview'),
            ),
          ],
        ),
        body: body,
      ),
    );
  }
}

class _SourceRequestSwitchHarness extends StatefulWidget {
  const _SourceRequestSwitchHarness({required this.onConsumed});

  final VoidCallback onConsumed;

  @override
  State<_SourceRequestSwitchHarness> createState() =>
      _SourceRequestSwitchHarnessState();
}

class _SourceRequestSwitchHarnessState
    extends State<_SourceRequestSwitchHarness> {
  final String _markdown = List.generate(
    60,
    (index) => 'Line $index',
  ).join('\n');
  late SourceRevealRequest? _request = SourceRevealRequest(
    id: 1,
    offset: _markdown.indexOf('Line 55'),
  );
  bool _showSource = true;
  double _sourceScrollOffset = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(extensions: const [EditorThemeColors.darkMode]),
      home: Scaffold(
        appBar: AppBar(
          actions: [
            TextButton(
              key: const ValueKey<String>('show-preview'),
              onPressed: () {
                setState(() {
                  _showSource = false;
                });
              },
              child: const Text('Show Preview'),
            ),
            TextButton(
              key: const ValueKey<String>('show-source'),
              onPressed: () {
                setState(() {
                  _showSource = true;
                });
              },
              child: const Text('Show Source'),
            ),
          ],
        ),
        body:
            _showSource
                ? SizedBox(
                  height: 260,
                  child: MarkdownSourceEditor(
                    filePath: '/tmp/replay.md',
                    markdown: _markdown,
                    onChanged: (_, __) {},
                    initialScrollOffset: _sourceScrollOffset,
                    onScrollPositionChanged: (offset) {
                      _sourceScrollOffset = offset;
                    },
                    revealRequest: _request,
                    onRevealConsumed: (_) {
                      setState(() {
                        _request = null;
                      });
                      widget.onConsumed();
                    },
                  ),
                )
                : const Center(child: Text('Preview content')),
      ),
    );
  }
}
