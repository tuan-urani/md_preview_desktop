import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:watcher/watcher.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isMacOS || Platform.isWindows) {
    await windowManager.ensureInitialized();

    final windowOptions = WindowOptions(
      size: Size(1280, 820),
      minimumSize: Size(920, 560),
      center: true,
      title: 'MD Preview',
      titleBarStyle:
          Platform.isMacOS ? TitleBarStyle.hidden : TitleBarStyle.normal,
      windowButtonVisibility: Platform.isMacOS,
      backgroundColor: const Color(0xFF1E1E1E),
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const MdPreviewApp());
}

class MdPreviewApp extends StatefulWidget {
  const MdPreviewApp({super.key});

  @override
  State<MdPreviewApp> createState() => _MdPreviewAppState();
}

class _MdPreviewAppState extends State<MdPreviewApp> {
  static const _themePreferenceKey = 'theme_mode';

  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    unawaited(_loadThemeMode());
  }

  Future<void> _loadThemeMode() async {
    final preferences = await SharedPreferences.getInstance();
    final savedMode = preferences.getString(_themePreferenceKey);
    final themeMode = savedMode == 'light' ? ThemeMode.light : ThemeMode.dark;

    if (!mounted) {
      return;
    }

    setState(() {
      _themeMode = themeMode;
    });
  }

  Future<void> _toggleThemeMode() async {
    final nextMode =
        _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;

    setState(() {
      _themeMode = nextMode;
    });

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _themePreferenceKey,
      nextMode == ThemeMode.light ? 'light' : 'dark',
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MD Preview',
      theme: _buildAppTheme(EditorThemeColors.lightMode, Brightness.light),
      darkTheme: _buildAppTheme(EditorThemeColors.darkMode, Brightness.dark),
      themeMode: _themeMode,
      home: MarkdownStudioPage(
        currentThemeMode: _themeMode,
        onToggleThemeMode: _toggleThemeMode,
      ),
    );
  }
}

class MarkdownStudioPage extends StatefulWidget {
  const MarkdownStudioPage({
    super.key,
    required this.currentThemeMode,
    required this.onToggleThemeMode,
  });

  final ThemeMode currentThemeMode;
  final VoidCallback onToggleThemeMode;

  @override
  State<MarkdownStudioPage> createState() => _MarkdownStudioPageState();
}

class MarkdownDocument {
  MarkdownDocument({
    required this.filePath,
    required this.markdown,
    required this.lastModified,
    this.errorMessage,
    this.isDirty = false,
  });

  final String filePath;
  String markdown;
  DateTime? lastModified;
  String? errorMessage;
  bool isDirty;

  String get fileName => p.basename(filePath);
  String get folderName => p.basename(p.dirname(filePath));
}

enum MarkdownViewMode { source, preview }

enum EditorGroupId { primary, split }

enum SplitDropSide { left, right }

class MarkdownEditorTab {
  const MarkdownEditorTab({required this.filePath, required this.viewMode});

  final String filePath;
  final MarkdownViewMode viewMode;
}

class SourceRevealRequest {
  const SourceRevealRequest({required this.id, required this.offset});

  final int id;
  final int offset;
}

class EditorTabDragPayload {
  const EditorTabDragPayload({required this.groupId, required this.tabIndex});

  final EditorGroupId groupId;
  final int tabIndex;
}

class _MarkdownStudioPageState extends State<MarkdownStudioPage> {
  static const double _mobileBreakpoint = 700;
  static const double _defaultExplorerWidth = 250;
  static const double _minExplorerWidth = 180;
  static const double _maxExplorerWidth = 420;
  static const Duration _autoSaveDelay = Duration(milliseconds: 700);

  final GlobalKey _editorAreaKey = GlobalKey();

  StreamSubscription<WatchEvent>? _watchSubscription;
  Timer? _reloadDebounce;
  final Map<String, Timer> _autoSaveDebounces = {};
  final Map<String, double> _previewScrollOffsets = {};
  final Map<String, double> _sourceScrollOffsets = {};
  final Map<String, GlobalKey<_PreviewPaneState>> _mobilePreviewKeys = {};
  final Map<String, GlobalKey<_MarkdownSourceEditorState>>
  _mobileSourceEditorKeys = {};

  final List<MarkdownDocument> _documents = [];
  final List<MarkdownEditorTab> _tabs = [];
  final List<MarkdownEditorTab> _splitTabs = [];
  final Map<String, SourceRevealRequest> _sourceRevealRequests = {};
  int _nextSourceRevealRequestId = 0;
  int _activeTabIndex = -1;
  int _activeSplitTabIndex = -1;
  EditorGroupId _activeGroupId = EditorGroupId.primary;
  SplitDropSide _splitSide = SplitDropSide.right;
  SplitDropSide? _dragSplitSide;
  double _leftEditorFraction = 0.5;
  bool _isLoading = false;
  final bool _autoReload = true;
  bool _isExplorerVisible = true;
  double _explorerWidth = _defaultExplorerWidth;
  bool _isMobileDocumentVisible = false;
  MarkdownViewMode _mobileViewMode = MarkdownViewMode.preview;

  MarkdownEditorTab? get _activeTab {
    final tabs = _tabsForGroup(_activeGroupId);
    final activeIndex = _activeIndexForGroup(_activeGroupId);

    if (activeIndex < 0 || activeIndex >= tabs.length) {
      return null;
    }

    return tabs[activeIndex];
  }

  MarkdownDocument? get _activeDocument {
    final filePath = _activeTab?.filePath;
    if (filePath == null) {
      return null;
    }

    return _documentForPath(filePath);
  }

  MarkdownViewMode get _activeViewMode =>
      _activeTab?.viewMode ?? MarkdownViewMode.preview;

  String? get _filePath => _activeDocument?.filePath;

  @override
  void initState() {
    super.initState();
    NativeFileOpenBridge.attach(onOpenFiles: _openNativeFiles);
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    for (final timer in _autoSaveDebounces.values) {
      timer.cancel();
    }
    _watchSubscription?.cancel();
    super.dispose();
  }

  void _openNativeFiles(List<String> paths) {
    if (paths.isEmpty) {
      return;
    }

    final supportedPaths = paths.where(_isMarkdownPath).toList();
    if (supportedPaths.isEmpty) {
      return;
    }

    unawaited(_openFiles(supportedPaths));
  }

  Future<void> _openFiles(Iterable<String> filePaths) async {
    for (final filePath in filePaths) {
      await _openFile(filePath);
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open Markdown File',
      type: FileType.custom,
      allowedExtensions: const ['md', 'markdown', 'mdown', 'mkd', 'txt'],
      allowMultiple: true,
      withData: false,
    );

    final selectedPaths =
        result?.files
            .map((file) => file.path)
            .whereType<String>()
            .toList(growable: false) ??
        const <String>[];

    if (selectedPaths.isEmpty) {
      return;
    }

    await _openFiles(selectedPaths);
  }

  Future<void> _openFile(String filePath) async {
    final normalizedPath = File(filePath).absolute.path;
    final existingIndex = _indexOfDocument(normalizedPath);
    _cancelAutoSave(normalizedPath);

    setState(() {
      if (existingIndex != -1) {
        _ensureEditorTabsForFile(normalizedPath);
        _activeTabIndex = _indexOfTab(normalizedPath, MarkdownViewMode.preview);
        _activeGroupId = EditorGroupId.primary;
        _isMobileDocumentVisible = true;
        _mobileViewMode = MarkdownViewMode.preview;
      }
      _isLoading = true;
    });

    try {
      final file = File(normalizedPath);
      if (!await file.exists()) {
        throw FileSystemException('File does not exist', normalizedPath);
      }

      final text = await file.readAsString();
      final stat = await file.stat();

      if (!mounted) {
        return;
      }

      final updatedDocument = MarkdownDocument(
        filePath: normalizedPath,
        markdown: text,
        lastModified: stat.modified,
      );

      setState(() {
        final index = _indexOfDocument(normalizedPath);
        if (index == -1) {
          _documents.add(updatedDocument);
        } else {
          _documents[index] = updatedDocument;
        }
        _ensureEditorTabsForFile(normalizedPath);
        _activeTabIndex = _indexOfTab(normalizedPath, MarkdownViewMode.preview);
        _activeGroupId = EditorGroupId.primary;
        _isMobileDocumentVisible = true;
        _mobileViewMode = MarkdownViewMode.preview;
        _isLoading = false;
      });

      await _restartWatcherForActiveDocument();
      await _setWindowTitle(normalizedPath);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        final index = _indexOfDocument(normalizedPath);
        final failedDocument = MarkdownDocument(
          filePath: normalizedPath,
          markdown: '',
          lastModified: null,
          errorMessage: error.toString(),
        );

        if (index == -1) {
          _documents.add(failedDocument);
        } else {
          _documents[index] = failedDocument;
        }
        _ensureEditorTabsForFile(normalizedPath);
        _activeTabIndex = _indexOfTab(normalizedPath, MarkdownViewMode.preview);
        _activeGroupId = EditorGroupId.primary;
        _isMobileDocumentVisible = true;
        _mobileViewMode = MarkdownViewMode.preview;
        _isLoading = false;
      });

      await _restartWatcherForActiveDocument();
      await _setWindowTitle(normalizedPath);
    }
  }

  Future<void> _reloadCurrentFile({bool silent = false}) async {
    final filePath = _filePath;
    if (filePath == null) {
      return;
    }

    await _reloadFile(filePath, silent: silent);
  }

  Future<void> _reloadFile(String filePath, {bool silent = false}) async {
    final document = _documentForPath(filePath);
    if (silent &&
        (document?.isDirty == true || _hasPendingAutoSave(filePath))) {
      return;
    }

    if (!silent && mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      final file = File(filePath);
      final text = await file.readAsString();
      final stat = await file.stat();

      if (!mounted) {
        return;
      }

      setState(() {
        final index = _indexOfDocument(filePath);
        if (index != -1) {
          _documents[index].markdown = text;
          _documents[index].lastModified = stat.modified;
          _documents[index].errorMessage = null;
          _documents[index].isDirty = false;
        }
        _isLoading = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        final index = _indexOfDocument(filePath);
        if (index != -1) {
          _documents[index].errorMessage = error.toString();
        }
        _isLoading = false;
      });
    }
  }

  Future<void> _saveDocument(String filePath) async {
    final documentIndex = _indexOfDocument(filePath);
    if (documentIndex == -1) {
      return;
    }

    final markdownToSave = _documents[documentIndex].markdown;

    try {
      final file = File(filePath);
      await file.writeAsString(markdownToSave);
      final stat = await file.stat();

      if (!mounted) {
        return;
      }

      setState(() {
        final index = _indexOfDocument(filePath);
        if (index != -1) {
          _documents[index].lastModified = stat.modified;
          _documents[index].errorMessage = null;
          if (_documents[index].markdown == markdownToSave) {
            _documents[index].isDirty = false;
          }
        }
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        final index = _indexOfDocument(filePath);
        if (index != -1) {
          _documents[index].errorMessage = error.toString();
        }
      });
    }
  }

  void _updateDocumentMarkdown(String filePath, String markdown) {
    final index = _indexOfDocument(filePath);
    if (index == -1) {
      return;
    }

    if (_documents[index].markdown == markdown) {
      return;
    }

    setState(() {
      _documents[index].markdown = markdown;
      _documents[index].errorMessage = null;
      _documents[index].isDirty = true;
    });

    _scheduleAutoSave(filePath);
  }

  void _scheduleAutoSave(String filePath) {
    _autoSaveDebounces[filePath]?.cancel();
    _autoSaveDebounces[filePath] = Timer(_autoSaveDelay, () {
      _autoSaveDebounces.remove(filePath);
      unawaited(_saveDocument(filePath));
    });
  }

  void _cancelAutoSave(String filePath) {
    _autoSaveDebounces.remove(filePath)?.cancel();
  }

  bool _hasPendingAutoSave(String filePath) {
    return _autoSaveDebounces.containsKey(filePath);
  }

  void _startWatching(String filePath) {
    if (!_autoReload) {
      return;
    }

    _watchSubscription = FileWatcher(filePath).events.listen((event) {
      if (event.type == ChangeType.MODIFY) {
        _reloadDebounce?.cancel();
        _reloadDebounce = Timer(
          const Duration(milliseconds: 180),
          () => _reloadFile(filePath, silent: true),
        );
      }
    });
  }

  Future<void> _restartWatcherForActiveDocument() async {
    await _watchSubscription?.cancel();
    _watchSubscription = null;

    final filePath = _filePath;
    if (filePath != null) {
      _startWatching(filePath);
    }
  }

  Future<void> _setWindowTitle(String? filePath) async {
    if (!Platform.isMacOS) {
      return;
    }

    final title =
        filePath == null
            ? 'MD Preview'
            : '${p.basename(filePath)} - MD Preview';
    await windowManager.setTitle(title);
  }

  void _toggleExplorer() {
    setState(() {
      _isExplorerVisible = !_isExplorerVisible;
    });
  }

  void _resizeExplorerByDelta(double delta) {
    setState(() {
      _explorerWidth =
          (_explorerWidth + delta)
              .clamp(_minExplorerWidth, _maxExplorerWidth)
              .toDouble();
    });
  }

  void _resetExplorerWidth() {
    setState(() {
      _explorerWidth = _defaultExplorerWidth;
    });
  }

  void _activateEditorTab(EditorGroupId groupId, int index) {
    final tabs = _tabsForGroup(groupId);
    if (index < 0 || index >= tabs.length) {
      return;
    }

    if (groupId == _activeGroupId && index == _activeIndexForGroup(groupId)) {
      return;
    }

    setState(() {
      _activeGroupId = groupId;
      _setActiveIndexForGroup(groupId, index);
      _isLoading = false;
    });

    unawaited(_restartWatcherForActiveDocument());
    unawaited(_setWindowTitle(_filePath));
  }

  void _activateOrOpenSiblingTab() {
    final filePath = _filePath;
    if (filePath == null) {
      return;
    }

    final nextViewMode =
        _activeViewMode == MarkdownViewMode.source
            ? MarkdownViewMode.preview
            : MarkdownViewMode.source;

    var tabIndex = _indexOfTabInGroup(_activeGroupId, filePath, nextViewMode);
    if (tabIndex == -1) {
      setState(() {
        final tabs = _tabsForGroup(_activeGroupId);
        tabs.add(MarkdownEditorTab(filePath: filePath, viewMode: nextViewMode));
        tabIndex = tabs.length - 1;
      });
    }

    _activateEditorTab(_activeGroupId, tabIndex);
  }

  void _revealSourceFromPreview(
    EditorGroupId previewGroupId,
    String filePath,
    int offset,
  ) {
    final otherGroupId =
        previewGroupId == EditorGroupId.primary
            ? EditorGroupId.split
            : EditorGroupId.primary;
    final otherSourceIndex = _indexOfTabInGroup(
      otherGroupId,
      filePath,
      MarkdownViewMode.source,
    );
    final previewGroupSourceIndex = _indexOfTabInGroup(
      previewGroupId,
      filePath,
      MarkdownViewMode.source,
    );

    final targetGroupId =
        otherSourceIndex != -1 ? otherGroupId : previewGroupId;
    var targetIndex =
        otherSourceIndex != -1 ? otherSourceIndex : previewGroupSourceIndex;

    setState(() {
      if (targetIndex == -1) {
        final targetTabs = _tabsForGroup(targetGroupId);
        targetTabs.add(
          MarkdownEditorTab(
            filePath: filePath,
            viewMode: MarkdownViewMode.source,
          ),
        );
        targetIndex = targetTabs.length - 1;
      }

      _sourceRevealRequests[filePath] = SourceRevealRequest(
        id: _nextSourceRevealRequestId++,
        offset: offset,
      );
      _activeGroupId = targetGroupId;
      _setActiveIndexForGroup(targetGroupId, targetIndex);
      _isLoading = false;
    });

    unawaited(_restartWatcherForActiveDocument());
    unawaited(_setWindowTitle(_filePath));
  }

  void _consumeSourceRevealRequest(String filePath, int requestId) {
    final request = _sourceRevealRequests[filePath];
    if (request?.id == requestId) {
      _sourceRevealRequests.remove(filePath);
    }
  }

  void _showMobileFiles() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _isMobileDocumentVisible = false;
      _mobileViewMode = MarkdownViewMode.preview;
    });
  }

  void _openDocumentForMobile(String filePath) {
    final previewIndex = _indexOfTabInGroup(
      EditorGroupId.primary,
      filePath,
      MarkdownViewMode.preview,
    );

    setState(() {
      _ensureEditorTabsForFile(filePath);
      _activeGroupId = EditorGroupId.primary;
      _activeTabIndex =
          previewIndex == -1
              ? _indexOfTab(filePath, MarkdownViewMode.preview)
              : previewIndex;
      _isMobileDocumentVisible = true;
      _mobileViewMode = MarkdownViewMode.preview;
      _isLoading = false;
    });

    unawaited(_restartWatcherForActiveDocument());
    unawaited(_setWindowTitle(_filePath));
  }

  void _openMobileSource() {
    if (_activeDocument == null) {
      return;
    }

    setState(() {
      _mobileViewMode = MarkdownViewMode.source;
    });
  }

  void _revealMobileSource(String filePath, int offset) {
    setState(() {
      _sourceRevealRequests[filePath] = SourceRevealRequest(
        id: _nextSourceRevealRequestId++,
        offset: offset,
      );
      _mobileViewMode = MarkdownViewMode.source;
    });
  }

  void _showMobilePreview() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _mobileViewMode = MarkdownViewMode.preview;
    });
  }

  void _closeEditorTab(EditorGroupId groupId, int tabIndex) {
    final tabs = _tabsForGroup(groupId);
    if (tabIndex < 0 || tabIndex >= tabs.length) {
      return;
    }

    setState(() {
      tabs.removeAt(tabIndex);

      _normalizeActiveIndexForGroup(groupId, removedIndex: tabIndex);
      _normalizeActiveGroupAfterTabChange();

      _isLoading = false;
    });

    unawaited(_restartWatcherForActiveDocument());
    unawaited(_setWindowTitle(_filePath));
  }

  void _activateDocumentFromExplorer(String filePath) {
    final activeGroupIndex = _indexOfTabInGroup(
      _activeGroupId,
      filePath,
      _activeViewMode,
    );
    if (activeGroupIndex != -1) {
      _activateEditorTab(_activeGroupId, activeGroupIndex);
      return;
    }

    for (final groupId in [EditorGroupId.primary, EditorGroupId.split]) {
      final previewIndex = _indexOfTabInGroup(
        groupId,
        filePath,
        MarkdownViewMode.preview,
      );
      if (previewIndex != -1) {
        _activateEditorTab(groupId, previewIndex);
        return;
      }

      final sourceIndex = _indexOfTabInGroup(
        groupId,
        filePath,
        MarkdownViewMode.source,
      );
      if (sourceIndex != -1) {
        _activateEditorTab(groupId, sourceIndex);
        return;
      }
    }

    setState(() {
      _ensureEditorTabsForFile(filePath);
      _activeGroupId = EditorGroupId.primary;
      _activeTabIndex = _indexOfTab(filePath, MarkdownViewMode.preview);
      _isLoading = false;
    });

    unawaited(_restartWatcherForActiveDocument());
    unawaited(_setWindowTitle(_filePath));
  }

  void _removeDocumentFromExplorer(String filePath) {
    final oldPrimaryActiveTab = _activeTabForGroup(EditorGroupId.primary);
    final oldSplitActiveTab = _activeTabForGroup(EditorGroupId.split);
    _cancelAutoSave(filePath);
    _sourceRevealRequests.remove(filePath);
    for (final groupId in EditorGroupId.values) {
      _previewScrollOffsets.remove('${groupId.name}:$filePath');
      _sourceScrollOffsets.remove('${groupId.name}:$filePath');
    }
    _previewScrollOffsets.remove('mobile-preview:$filePath');
    _sourceScrollOffsets.remove('mobile-source:$filePath');
    _mobilePreviewKeys.remove(filePath);
    _mobileSourceEditorKeys.remove(filePath);

    setState(() {
      _documents.removeWhere((document) => document.filePath == filePath);
      _tabs.removeWhere((tab) => tab.filePath == filePath);
      _splitTabs.removeWhere((tab) => tab.filePath == filePath);

      _activeTabIndex = _resolveActiveIndexAfterRemoval(
        _tabs,
        _activeTabIndex,
        oldPrimaryActiveTab,
      );
      _activeSplitTabIndex = _resolveActiveIndexAfterRemoval(
        _splitTabs,
        _activeSplitTabIndex,
        oldSplitActiveTab,
      );
      _normalizeActiveGroupAfterTabChange();
      if (_documents.isEmpty) {
        _isMobileDocumentVisible = false;
      }
      _isLoading = false;
    });

    unawaited(_restartWatcherForActiveDocument());
    unawaited(_setWindowTitle(_filePath));
  }

  void _reorderDocumentInExplorer(String filePath, int targetIndex) {
    final currentIndex = _indexOfDocument(filePath);
    if (currentIndex == -1) {
      return;
    }

    setState(() {
      final document = _documents.removeAt(currentIndex);
      final adjustedTargetIndex =
          currentIndex < targetIndex ? targetIndex - 1 : targetIndex;
      final insertIndex = adjustedTargetIndex.clamp(0, _documents.length);
      _documents.insert(insertIndex, document);
    });
  }

  int _indexOfDocument(String filePath) {
    return _documents.indexWhere((document) => document.filePath == filePath);
  }

  MarkdownDocument? _documentForPath(String filePath) {
    final index = _indexOfDocument(filePath);
    if (index == -1) {
      return null;
    }

    return _documents[index];
  }

  List<MarkdownEditorTab> _tabsForGroup(EditorGroupId groupId) {
    return switch (groupId) {
      EditorGroupId.primary => _tabs,
      EditorGroupId.split => _splitTabs,
    };
  }

  int _activeIndexForGroup(EditorGroupId groupId) {
    return switch (groupId) {
      EditorGroupId.primary => _activeTabIndex,
      EditorGroupId.split => _activeSplitTabIndex,
    };
  }

  void _setActiveIndexForGroup(EditorGroupId groupId, int index) {
    switch (groupId) {
      case EditorGroupId.primary:
        _activeTabIndex = index;
      case EditorGroupId.split:
        _activeSplitTabIndex = index;
    }
  }

  int _indexOfTab(String filePath, MarkdownViewMode viewMode) {
    return _tabs.indexWhere(
      (tab) => tab.filePath == filePath && tab.viewMode == viewMode,
    );
  }

  MarkdownEditorTab? _activeTabForGroup(EditorGroupId groupId) {
    final tabs = _tabsForGroup(groupId);
    final activeIndex = _activeIndexForGroup(groupId);
    if (activeIndex < 0 || activeIndex >= tabs.length) {
      return null;
    }

    return tabs[activeIndex];
  }

  int _resolveActiveIndexAfterRemoval(
    List<MarkdownEditorTab> tabs,
    int previousIndex,
    MarkdownEditorTab? previousActiveTab,
  ) {
    if (tabs.isEmpty) {
      return -1;
    }

    if (previousActiveTab != null) {
      final preservedIndex = tabs.indexWhere(
        (tab) =>
            tab.filePath == previousActiveTab.filePath &&
            tab.viewMode == previousActiveTab.viewMode,
      );
      if (preservedIndex != -1) {
        return preservedIndex;
      }
    }

    return previousIndex.clamp(0, tabs.length - 1).toInt();
  }

  int _indexOfTabInGroup(
    EditorGroupId groupId,
    String filePath,
    MarkdownViewMode viewMode,
  ) {
    return _tabsForGroup(
      groupId,
    ).indexWhere((tab) => tab.filePath == filePath && tab.viewMode == viewMode);
  }

  void _ensureEditorTabsForFile(String filePath) {
    if (_indexOfTab(filePath, MarkdownViewMode.source) == -1) {
      _tabs.add(
        MarkdownEditorTab(
          filePath: filePath,
          viewMode: MarkdownViewMode.source,
        ),
      );
    }

    if (_indexOfTab(filePath, MarkdownViewMode.preview) == -1) {
      _tabs.add(
        MarkdownEditorTab(
          filePath: filePath,
          viewMode: MarkdownViewMode.preview,
        ),
      );
    }
  }

  void _normalizeActiveIndexForGroup(
    EditorGroupId groupId, {
    required int removedIndex,
  }) {
    final tabs = _tabsForGroup(groupId);
    final activeIndex = _activeIndexForGroup(groupId);

    if (tabs.isEmpty) {
      _setActiveIndexForGroup(groupId, -1);
    } else if (removedIndex < activeIndex) {
      _setActiveIndexForGroup(groupId, activeIndex - 1);
    } else if (removedIndex == activeIndex) {
      _setActiveIndexForGroup(
        groupId,
        removedIndex >= tabs.length ? tabs.length - 1 : removedIndex,
      );
    } else if (activeIndex >= tabs.length) {
      _setActiveIndexForGroup(groupId, tabs.length - 1);
    }
  }

  void _normalizeActiveGroupAfterTabChange() {
    if (_tabsForGroup(_activeGroupId).isNotEmpty) {
      return;
    }

    if (_tabs.isNotEmpty) {
      _activeGroupId = EditorGroupId.primary;
    } else if (_splitTabs.isNotEmpty) {
      _activeGroupId = EditorGroupId.split;
    } else {
      _activeGroupId = EditorGroupId.primary;
    }
  }

  void _moveTabToGroup(
    EditorTabDragPayload payload,
    EditorGroupId targetGroup,
  ) {
    final sourceTabs = _tabsForGroup(payload.groupId);
    if (payload.tabIndex < 0 || payload.tabIndex >= sourceTabs.length) {
      return;
    }

    final movingTab = sourceTabs[payload.tabIndex];
    final existingTargetIndex = _indexOfTabInGroup(
      targetGroup,
      movingTab.filePath,
      movingTab.viewMode,
    );

    setState(() {
      if (payload.groupId == targetGroup) {
        _activeGroupId = targetGroup;
        _setActiveIndexForGroup(targetGroup, payload.tabIndex);
        return;
      }

      sourceTabs.removeAt(payload.tabIndex);
      _normalizeActiveIndexForGroup(
        payload.groupId,
        removedIndex: payload.tabIndex,
      );

      if (existingTargetIndex == -1) {
        final targetTabs = _tabsForGroup(targetGroup);
        targetTabs.add(movingTab);
        _setActiveIndexForGroup(targetGroup, targetTabs.length - 1);
      } else {
        _setActiveIndexForGroup(targetGroup, existingTargetIndex);
      }

      _activeGroupId = targetGroup;
      _normalizeActiveGroupAfterTabChange();
      _isLoading = false;
    });

    unawaited(_restartWatcherForActiveDocument());
    unawaited(_setWindowTitle(_filePath));
  }

  void _moveTabToEmptySide(
    EditorTabDragPayload payload,
    SplitDropSide droppedSide,
  ) {
    final targetGroup =
        payload.groupId == EditorGroupId.primary
            ? EditorGroupId.split
            : EditorGroupId.primary;

    final splitSide =
        targetGroup == EditorGroupId.split
            ? droppedSide
            : _oppositeSplitSide(droppedSide);

    setState(() {
      _splitSide = splitSide;
    });

    _moveTabToGroup(payload, targetGroup);
  }

  SplitDropSide _oppositeSplitSide(SplitDropSide side) {
    return side == SplitDropSide.left
        ? SplitDropSide.right
        : SplitDropSide.left;
  }

  void _reorderEditorTab(
    EditorTabDragPayload payload,
    EditorGroupId targetGroup,
    int targetIndex,
  ) {
    final sourceTabs = _tabsForGroup(payload.groupId);
    final targetTabs = _tabsForGroup(targetGroup);

    if (payload.tabIndex < 0 || payload.tabIndex >= sourceTabs.length) {
      return;
    }

    final movingTab = sourceTabs[payload.tabIndex];
    if (payload.groupId == targetGroup && payload.tabIndex == targetIndex) {
      _activateEditorTab(targetGroup, targetIndex);
      return;
    }

    setState(() {
      if (payload.groupId == targetGroup) {
        sourceTabs.removeAt(payload.tabIndex);
        final adjustedTargetIndex =
            payload.tabIndex < targetIndex ? targetIndex - 1 : targetIndex;
        final insertIndex = adjustedTargetIndex.clamp(0, sourceTabs.length);
        sourceTabs.insert(insertIndex, movingTab);
        _setActiveIndexForGroup(targetGroup, insertIndex);
      } else {
        final sourceActiveTab = _activeTabForGroup(payload.groupId);
        sourceTabs.removeAt(payload.tabIndex);
        _setActiveIndexForGroup(
          payload.groupId,
          _resolveActiveIndexAfterRemoval(
            sourceTabs,
            _activeIndexForGroup(payload.groupId),
            sourceActiveTab,
          ),
        );

        final existingTargetIndex = _indexOfTabInGroup(
          targetGroup,
          movingTab.filePath,
          movingTab.viewMode,
        );
        if (existingTargetIndex == -1) {
          final insertIndex = targetIndex.clamp(0, targetTabs.length);
          targetTabs.insert(insertIndex, movingTab);
          _setActiveIndexForGroup(targetGroup, insertIndex);
        } else {
          _setActiveIndexForGroup(targetGroup, existingTargetIndex);
        }
      }

      _activeGroupId = targetGroup;
      _normalizeActiveGroupAfterTabChange();
      _isLoading = false;
    });

    unawaited(_restartWatcherForActiveDocument());
    unawaited(_setWindowTitle(_filePath));
  }

  Future<void> _openMarkdownLinkForFile(String filePath, String? href) async {
    if (href == null || href.trim().isEmpty) {
      return;
    }

    final uri = Uri.tryParse(href);
    if (uri != null && uri.hasScheme) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }

    final targetWithoutFragment = href.split('#').first;
    if (targetWithoutFragment.isEmpty) {
      return;
    }

    final targetPath = p.normalize(
      p.join(p.dirname(filePath), targetWithoutFragment),
    );

    if (_isMarkdownPath(targetPath) && await File(targetPath).exists()) {
      await _openFile(targetPath);
      return;
    }

    if ((Platform.isMacOS || Platform.isWindows) &&
        await File(targetPath).exists()) {
      await launchUrl(
        Uri.file(targetPath),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  String _imageDirectoryForFile(String filePath) {
    final directoryPath = '${p.dirname(filePath)}${Platform.pathSeparator}';
    return Uri.file(directoryPath).toString();
  }

  String get _fileName {
    final filePath = _filePath;
    return filePath == null ? 'Welcome' : p.basename(filePath);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final colors = context.editorColors;
        final isMobile = constraints.maxWidth < _mobileBreakpoint;

        return Scaffold(
          body: ColoredBox(
            color: colors.background,
            child:
                isMobile
                    ? _buildMobileWorkspace()
                    : _buildDesktopWorkspace(colors),
          ),
        );
      },
    );
  }

  Widget _buildDesktopWorkspace(EditorThemeColors colors) {
    final singleVisibleGroup = _singleVisibleEditorGroup;

    return Column(
      children: [
        EditorWindowBar(
          fileName: _fileName,
          onOpenPressed: _pickFile,
          onReloadPressed:
              _filePath == null ? null : () => _reloadCurrentFile(),
          activeViewMode: _activeViewMode,
          onToggleViewMode:
              _filePath == null ? null : _activateOrOpenSiblingTab,
          currentThemeMode: widget.currentThemeMode,
          onToggleThemeMode: widget.onToggleThemeMode,
        ),
        Expanded(
          child: Row(
            children: [
              ActivityRail(
                isExplorerVisible: _isExplorerVisible,
                onExplorerPressed: _toggleExplorer,
              ),
              if (_isExplorerVisible) ...[
                SizedBox(
                  width: _explorerWidth,
                  child: ExplorerPane(
                    documents: _documents,
                    activeFilePath: _filePath,
                    onOpenPressed: _pickFile,
                    onSelectDocument: _activateDocumentFromExplorer,
                    onRemoveDocument: _removeDocumentFromExplorer,
                    onReorderDocument: _reorderDocumentInExplorer,
                  ),
                ),
                SplitResizeDivider(
                  onDragDelta: _resizeExplorerByDelta,
                  onReset: _resetExplorerWidth,
                ),
              ],
              Expanded(
                child: Column(
                  children: [
                    if (singleVisibleGroup != null)
                      _buildEditorTabBar(singleVisibleGroup),
                    Expanded(
                      child: _buildEditorGroups(
                        showTabBar: singleVisibleGroup == null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMobileWorkspace() {
    final activeDocument = _activeDocument;
    if (!_isMobileDocumentVisible || activeDocument == null) {
      return MobileFileBrowser(
        documents: _documents,
        onOpenPressed: _pickFile,
        onSelectDocument: _openDocumentForMobile,
        onRemoveDocument: _removeDocumentFromExplorer,
      );
    }

    return MobileDocumentWorkspace(
      document: activeDocument,
      viewMode: _mobileViewMode,
      isLoading: _isLoading,
      onBackToFiles: _showMobileFiles,
      onEditPressed: _openMobileSource,
      onDonePressed: _showMobilePreview,
      onSearchPressed:
          _mobileViewMode == MarkdownViewMode.source
              ? () =>
                  _mobileSourceEditorKeys[activeDocument.filePath]?.currentState
                      ?._openFind()
              : () =>
                  _mobilePreviewKeys[activeDocument.filePath]?.currentState
                      ?._openFind(),
      preview: _buildMobilePreview(activeDocument),
      source: _buildMobileSource(activeDocument),
      onOpenPressed: _pickFile,
    );
  }

  Widget _buildMobilePreview(MarkdownDocument document) {
    final scrollKey = 'mobile-preview:${document.filePath}';
    return PreviewPane(
      key:
          _mobilePreviewKeys[document.filePath] ??=
              GlobalKey<_PreviewPaneState>(),
      showPanelHeader: false,
      selectable: true,
      revealOnDoubleTap: false,
      selectionToolbarEditEnabled: true,
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
      initialScrollOffset: _previewScrollOffsets[scrollKey] ?? 0,
      onScrollPositionChanged:
          (offset) => _previewScrollOffsets[scrollKey] = offset,
      markdown: document.markdown,
      imageDirectory: _imageDirectoryForFile(document.filePath),
      onTapLink: (href) => _openMarkdownLinkForFile(document.filePath, href),
      onRevealSource:
          (offset) => _revealMobileSource(document.filePath, offset),
      onOpenSource: _openMobileSource,
    );
  }

  Widget _buildMobileSource(MarkdownDocument document) {
    final scrollKey = 'mobile-source:${document.filePath}';
    return SourcePane(
      key: ValueKey<String>(scrollKey),
      editorKey:
          _mobileSourceEditorKeys[document.filePath] ??=
              GlobalKey<_MarkdownSourceEditorState>(),
      showPanelHeader: false,
      filePath: document.filePath,
      markdown: document.markdown,
      onChanged: _updateDocumentMarkdown,
      initialScrollOffset: _sourceScrollOffsets[scrollKey] ?? 0,
      onScrollPositionChanged:
          (offset) => _sourceScrollOffsets[scrollKey] = offset,
      revealRequest: _sourceRevealRequests[document.filePath],
      onRevealConsumed:
          (requestId) =>
              _consumeSourceRevealRequest(document.filePath, requestId),
    );
  }

  EditorGroupId? get _singleVisibleEditorGroup {
    if (_tabs.isEmpty && _splitTabs.isEmpty) {
      return EditorGroupId.primary;
    }

    if (_tabs.isEmpty) {
      return EditorGroupId.split;
    }

    if (_splitTabs.isEmpty) {
      return EditorGroupId.primary;
    }

    return null;
  }

  Widget _buildEditorGroups({required bool showTabBar}) {
    final singleVisibleGroup = _singleVisibleEditorGroup;
    if (singleVisibleGroup != null) {
      return _buildSingleEditorGroup(
        singleVisibleGroup,
        showTabBar: showTabBar,
      );
    }

    final leftGroup =
        _splitSide == SplitDropSide.left
            ? EditorGroupId.split
            : EditorGroupId.primary;
    final rightGroup =
        _splitSide == SplitDropSide.left
            ? EditorGroupId.primary
            : EditorGroupId.split;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth - SplitResizeDivider.width;
        final leftWidth = availableWidth * _leftEditorFraction;
        final rightWidth = availableWidth - leftWidth;

        return Row(
          children: [
            SizedBox(width: leftWidth, child: _buildEditorGroup(leftGroup)),
            SplitResizeDivider(
              onDragDelta:
                  (delta) => _resizeSplitByDelta(delta, constraints.maxWidth),
              onReset: _resetSplitSize,
            ),
            SizedBox(width: rightWidth, child: _buildEditorGroup(rightGroup)),
          ],
        );
      },
    );
  }

  Widget _buildSingleEditorGroup(
    EditorGroupId visibleGroup, {
    required bool showTabBar,
  }) {
    return DragTarget<EditorTabDragPayload>(
      onWillAcceptWithDetails:
          (details) => details.data.groupId == visibleGroup,
      onMove: _handleSplitPreviewDragMove,
      onLeave: (_) => _setDragSplitSide(null),
      onAcceptWithDetails: (details) {
        final splitSide = _splitSideForOffset(details.offset);
        _setDragSplitSide(null);

        if (splitSide != null) {
          _moveTabToEmptySide(details.data, splitSide);
        }
      },
      builder: (context, candidateData, rejectedData) {
        return Stack(
          key: _editorAreaKey,
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: _buildEditorGroup(visibleGroup, showTabBar: showTabBar),
            ),
            if (_dragSplitSide != null)
              Positioned.fill(
                child: SplitPreviewOverlay(side: _dragSplitSide!),
              ),
          ],
        );
      },
    );
  }

  void _handleSplitPreviewDragMove(
    DragTargetDetails<EditorTabDragPayload> details,
  ) {
    _setDragSplitSide(_splitSideForOffset(details.offset));
  }

  SplitDropSide? _splitSideForOffset(Offset globalOffset) {
    final context = _editorAreaKey.currentContext;
    if (context == null) {
      return null;
    }

    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.hasSize) {
      return null;
    }

    final localOffset = renderBox.globalToLocal(globalOffset);
    if (localOffset.dx < 0 ||
        localOffset.dx > renderBox.size.width ||
        localOffset.dy < 0 ||
        localOffset.dy > renderBox.size.height) {
      return null;
    }

    return localOffset.dx < renderBox.size.width / 2
        ? SplitDropSide.left
        : SplitDropSide.right;
  }

  void _setDragSplitSide(SplitDropSide? side) {
    if (_dragSplitSide == side) {
      return;
    }

    setState(() {
      _dragSplitSide = side;
    });
  }

  void _resizeSplitByDelta(double delta, double totalWidth) {
    final availableWidth = totalWidth - SplitResizeDivider.width;
    if (availableWidth <= 0) {
      return;
    }

    setState(() {
      _leftEditorFraction =
          (_leftEditorFraction + delta / availableWidth)
              .clamp(0.18, 0.82)
              .toDouble();
    });
  }

  void _resetSplitSize() {
    setState(() {
      _leftEditorFraction = 0.5;
    });
  }

  Widget _buildEditorTabBar(EditorGroupId groupId) {
    final tabs = _tabsForGroup(groupId);
    final activeIndex = _activeIndexForGroup(groupId);

    return EditorTabBar(
      documents: _documents,
      tabs: tabs,
      activeTabIndex: activeIndex,
      groupId: groupId,
      onSelectTab: (index) => _activateEditorTab(groupId, index),
      onCloseTab: (index) => _closeEditorTab(groupId, index),
      onReorderTab:
          (payload, targetIndex) =>
              _reorderEditorTab(payload, groupId, targetIndex),
    );
  }

  Widget _buildEditorGroup(EditorGroupId groupId, {bool showTabBar = true}) {
    return Column(
      children: [
        if (showTabBar) _buildEditorTabBar(groupId),
        Expanded(
          child: DragTarget<EditorTabDragPayload>(
            onWillAcceptWithDetails:
                (details) => details.data.groupId != groupId,
            onAcceptWithDetails:
                (details) => _moveTabToGroup(details.data, groupId),
            builder: (context, candidateData, rejectedData) {
              final isHovering = candidateData.isNotEmpty;
              final colors = context.editorColors;

              return DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isHovering ? colors.accent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: _buildEditorContentForGroup(groupId),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEditorContentForGroup(EditorGroupId groupId) {
    final tabs = _tabsForGroup(groupId);
    final activeIndex = _activeIndexForGroup(groupId);

    if (tabs.isEmpty || activeIndex < 0 || activeIndex >= tabs.length) {
      return EmptyEditorState(onOpenPressed: _pickFile);
    }

    final activeTab = tabs[activeIndex];
    final activeDocument = _documentForPath(activeTab.filePath);

    if (_isLoading && activeDocument == null) {
      return const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (activeDocument == null) {
      return EmptyEditorState(onOpenPressed: _pickFile);
    }

    if (_isLoading &&
        activeDocument.markdown.isEmpty &&
        activeDocument.errorMessage == null) {
      return const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (activeDocument.errorMessage != null &&
        activeDocument.markdown.isEmpty) {
      return ErrorState(
        message: activeDocument.errorMessage!,
        onOpenPressed: _pickFile,
      );
    }

    final previewScrollKey = '${groupId.name}:${activeDocument.filePath}';
    final previewPane = PreviewPane(
      key: ValueKey<String>(previewScrollKey),
      initialScrollOffset: _previewScrollOffsets[previewScrollKey] ?? 0,
      onScrollPositionChanged:
          (offset) => _previewScrollOffsets[previewScrollKey] = offset,
      markdown: activeDocument.markdown,
      imageDirectory: _imageDirectoryForFile(activeDocument.filePath),
      onTapLink:
          (href) => _openMarkdownLinkForFile(activeDocument.filePath, href),
      onRevealSource:
          (offset) => _revealSourceFromPreview(
            groupId,
            activeDocument.filePath,
            offset,
          ),
    );

    if (activeTab.viewMode == MarkdownViewMode.preview) {
      return previewPane;
    }

    final sourceScrollKey = '${groupId.name}:${activeDocument.filePath}';
    return SourcePane(
      key: ValueKey<String>('source:$sourceScrollKey'),
      filePath: activeDocument.filePath,
      markdown: activeDocument.markdown,
      onChanged: _updateDocumentMarkdown,
      initialScrollOffset: _sourceScrollOffsets[sourceScrollKey] ?? 0,
      onScrollPositionChanged:
          (offset) => _sourceScrollOffsets[sourceScrollKey] = offset,
      revealRequest: _sourceRevealRequests[activeDocument.filePath],
      onRevealConsumed:
          (requestId) =>
              _consumeSourceRevealRequest(activeDocument.filePath, requestId),
    );
  }
}

class NativeFileOpenBridge {
  static const MethodChannel _channel = MethodChannel('md_desktop/file_open');

  static Future<void> attach({
    required void Function(List<String> paths) onOpenFiles,
  }) async {
    if (!Platform.isMacOS && !Platform.isWindows) {
      return;
    }

    if (Platform.isWindows) {
      final launchPaths = _pathsFromArguments(Platform.executableArguments);
      if (launchPaths.isNotEmpty) {
        onOpenFiles(launchPaths);
      }
    }

    _channel.setMethodCallHandler((call) async {
      if (call.method != 'openFiles') {
        return null;
      }

      final paths = _pathsFromArguments(call.arguments);
      if (paths.isNotEmpty) {
        onOpenFiles(paths);
      }

      return null;
    });

    try {
      final pendingPaths = await _channel.invokeListMethod<String>(
        'consumePendingFilePaths',
      );

      if (pendingPaths != null && pendingPaths.isNotEmpty) {
        onOpenFiles(pendingPaths);
      }
    } on MissingPluginException {
      // Native open-file bridges exist only on desktop runners that implement it.
    }
  }

  static List<String> _pathsFromArguments(Object? arguments) {
    if (arguments is String) {
      return [arguments];
    }

    if (arguments is List) {
      return arguments.whereType<String>().toList(growable: false);
    }

    return const [];
  }
}

class MobileFileBrowser extends StatelessWidget {
  const MobileFileBrowser({
    super.key,
    required this.documents,
    required this.onOpenPressed,
    required this.onSelectDocument,
    required this.onRemoveDocument,
  });

  final List<MarkdownDocument> documents;
  final VoidCallback onOpenPressed;
  final ValueChanged<String> onSelectDocument;
  final ValueChanged<String> onRemoveDocument;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return SafeArea(
      child: Column(
        children: [
          MobileTopBar(
            title: 'Markdown Files',
            trailing: IconButton(
              key: const ValueKey<String>('mobile-open-file'),
              onPressed: onOpenPressed,
              icon: const Icon(Icons.add),
              color: colors.primaryText,
            ),
          ),
          Expanded(
            child:
                documents.isEmpty
                    ? EmptyEditorState(onOpenPressed: onOpenPressed)
                    : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                      itemCount: documents.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final document = documents[index];
                        return ListTile(
                          key: ValueKey<String>(
                            'mobile-document:${document.filePath}',
                          ),
                          onTap: () => onSelectDocument(document.filePath),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          tileColor: colors.panelHeader,
                          leading: Icon(
                            Icons.description_outlined,
                            color: colors.markdownIcon,
                          ),
                          title: Text(
                            document.fileName,
                            style: TextStyle(color: colors.primaryText),
                          ),
                          subtitle: Text(
                            document.folderName,
                            style: TextStyle(color: colors.secondaryText),
                          ),
                          trailing: IconButton(
                            onPressed:
                                () => onRemoveDocument(document.filePath),
                            icon: const Icon(Icons.close, size: 18),
                            color: colors.secondaryText,
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}

class MobileDocumentWorkspace extends StatelessWidget {
  const MobileDocumentWorkspace({
    super.key,
    required this.document,
    required this.viewMode,
    required this.isLoading,
    required this.onBackToFiles,
    required this.onEditPressed,
    required this.onDonePressed,
    this.onSearchPressed,
    required this.preview,
    required this.source,
    required this.onOpenPressed,
  });

  final MarkdownDocument document;
  final MarkdownViewMode viewMode;
  final bool isLoading;
  final VoidCallback onBackToFiles;
  final VoidCallback onEditPressed;
  final VoidCallback onDonePressed;
  final VoidCallback? onSearchPressed;
  final Widget preview;
  final Widget source;
  final VoidCallback onOpenPressed;

  @override
  Widget build(BuildContext context) {
    final isSource = viewMode == MarkdownViewMode.source;

    Widget content = isSource ? source : preview;
    if (isLoading &&
        document.markdown.isEmpty &&
        document.errorMessage == null) {
      content = const Center(child: CircularProgressIndicator(strokeWidth: 2));
    } else if (document.errorMessage != null && document.markdown.isEmpty) {
      content = ErrorState(
        message: document.errorMessage!,
        onOpenPressed: onOpenPressed,
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        if (isSource) {
          onDonePressed();
        } else {
          onBackToFiles();
        }
      },
      child: SafeArea(
        child: Column(
          children: [
            MobileTopBar(
              title: document.fileName,
              leading: IconButton(
                key: ValueKey<String>(
                  isSource ? 'mobile-back-preview' : 'mobile-back-files',
                ),
                onPressed: isSource ? onDonePressed : onBackToFiles,
                icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              ),
              trailingWidth: 128,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: ValueKey<String>(
                      isSource
                          ? 'mobile-source-search'
                          : 'mobile-preview-search',
                    ),
                    tooltip: 'Find',
                    onPressed: onSearchPressed,
                    icon: const Icon(Icons.search, size: 20),
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                  TextButton(
                    key: ValueKey<String>(
                      isSource ? 'mobile-done' : 'mobile-edit',
                    ),
                    onPressed: isSource ? onDonePressed : onEditPressed,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(58, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(isSource ? 'Done' : 'Edit'),
                  ),
                ],
              ),
            ),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }
}

class MobileTopBar extends StatelessWidget {
  const MobileTopBar({
    super.key,
    required this.title,
    this.leading,
    this.trailing,
    this.trailingWidth = 64,
  });

  final String title;
  final Widget? leading;
  final Widget? trailing;
  final double trailingWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: colors.titleBar,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          SizedBox(width: 52, child: leading),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.primaryText,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
          SizedBox(width: trailingWidth, child: Center(child: trailing)),
        ],
      ),
    );
  }
}

class EditorWindowBar extends StatelessWidget {
  const EditorWindowBar({
    super.key,
    required this.fileName,
    required this.onOpenPressed,
    required this.onReloadPressed,
    required this.activeViewMode,
    required this.onToggleViewMode,
    required this.currentThemeMode,
    required this.onToggleThemeMode,
  });

  final String fileName;
  final VoidCallback onOpenPressed;
  final VoidCallback? onReloadPressed;
  final MarkdownViewMode activeViewMode;
  final VoidCallback? onToggleViewMode;
  final ThemeMode currentThemeMode;
  final VoidCallback onToggleThemeMode;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return DragToMoveArea(
      child: Container(
        height: 48,
        padding: const EdgeInsets.only(left: 78, right: 10),
        decoration: BoxDecoration(
          color: colors.titleBar,
          border: Border(bottom: BorderSide(color: colors.border, width: 1)),
        ),
        child: Row(
          children: [
            Icon(Icons.description_outlined, size: 16, color: colors.mutedText),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.primaryText,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            EditorToolbarButton(
              tooltip: 'Open Markdown File',
              icon: Icons.folder_open_outlined,
              onPressed: onOpenPressed,
            ),
            EditorToolbarButton(
              tooltip: 'Reload',
              icon: Icons.refresh,
              onPressed: onReloadPressed,
            ),
            EditorToolbarButton(
              tooltip:
                  currentThemeMode == ThemeMode.dark
                      ? 'Switch to Light Mode'
                      : 'Switch to Dark Mode',
              icon:
                  currentThemeMode == ThemeMode.dark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
              onPressed: onToggleThemeMode,
            ),
            EditorToolbarButton(
              tooltip:
                  activeViewMode == MarkdownViewMode.source
                      ? 'Open Preview Tab'
                      : 'Open Source Tab',
              icon:
                  activeViewMode == MarkdownViewMode.source
                      ? Icons.visibility_outlined
                      : Icons.article_outlined,
              onPressed: onToggleViewMode,
              selected: activeViewMode == MarkdownViewMode.preview,
            ),
          ],
        ),
      ),
    );
  }
}

class EditorToolbarButton extends StatelessWidget {
  const EditorToolbarButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      color: selected ? colors.primaryText : colors.secondaryText,
      disabledColor: colors.disabledText,
      style: IconButton.styleFrom(
        backgroundColor: selected ? colors.selection : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        fixedSize: const Size.square(34),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

class ActivityRail extends StatelessWidget {
  const ActivityRail({
    super.key,
    required this.isExplorerVisible,
    required this.onExplorerPressed,
  });

  final bool isExplorerVisible;
  final VoidCallback onExplorerPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return Container(
      width: 50,
      color: colors.activityRail,
      child: Column(
        children: [
          const SizedBox(height: 12),
          RailIcon(
            icon: Icons.copy_all_outlined,
            selected: isExplorerVisible,
            tooltip: 'Explorer',
            onPressed: onExplorerPressed,
          ),
        ],
      ),
    );
  }
}

class RailIcon extends StatelessWidget {
  const RailIcon({
    super.key,
    required this.icon,
    required this.selected,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final bool selected;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          hoverColor: colors.panelHeader,
          child: Container(
            width: 50,
            height: 48,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: selected ? colors.accent : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Icon(
              icon,
              color: selected ? colors.primaryText : colors.mutedText,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

class ExplorerPane extends StatelessWidget {
  const ExplorerPane({
    super.key,
    required this.documents,
    required this.activeFilePath,
    required this.onOpenPressed,
    required this.onSelectDocument,
    required this.onRemoveDocument,
    required this.onReorderDocument,
  });

  final List<MarkdownDocument> documents;
  final String? activeFilePath;
  final VoidCallback onOpenPressed;
  final ValueChanged<String> onSelectDocument;
  final ValueChanged<String> onRemoveDocument;
  final void Function(String filePath, int targetIndex) onReorderDocument;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return Container(
      decoration: BoxDecoration(color: colors.sidebar),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Text(
              'EXPLORER',
              style: TextStyle(
                color: colors.secondaryText,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton.icon(
              onPressed: onOpenPressed,
              icon: const Icon(Icons.folder_open_outlined, size: 17),
              label: const Text('Open File'),
              style: TextButton.styleFrom(
                foregroundColor: colors.primaryText,
                alignment: Alignment.centerLeft,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (documents.isNotEmpty) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 6),
              child: Text(
                'OPEN EDITORS',
                style: TextStyle(
                  color: colors.secondaryText,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ),
            for (var index = 0; index < documents.length; index++)
              ExplorerDocumentTile(
                document: documents[index],
                selected: documents[index].filePath == activeFilePath,
                onTap: () => onSelectDocument(documents[index].filePath),
                onRemove: () => onRemoveDocument(documents[index].filePath),
                onAcceptDocument:
                    (filePath) => onReorderDocument(filePath, index),
              ),
            ExplorerDocumentDropZone(
              onAcceptDocument:
                  (filePath) => onReorderDocument(filePath, documents.length),
            ),
          ],
        ],
      ),
    );
  }
}

class ExplorerDocumentTile extends StatelessWidget {
  const ExplorerDocumentTile({
    super.key,
    required this.document,
    required this.selected,
    required this.onTap,
    required this.onRemove,
    required this.onAcceptDocument,
  });

  final MarkdownDocument document;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final ValueChanged<String> onAcceptDocument;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    final tile = Material(
      color: selected ? colors.selection : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.panelHeader,
        child: Container(
          height: 30,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Icon(
                document.errorMessage != null
                    ? Icons.error_outline
                    : Icons.description_outlined,
                size: 15,
                color:
                    document.errorMessage == null
                        ? colors.markdownIcon
                        : colors.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  document.fileName,
                  textAlign: TextAlign.left,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? colors.primaryText : colors.secondaryText,
                    fontSize: 13,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Remove from Open Editors',
                onPressed: onRemove,
                icon: const Icon(Icons.remove, size: 15),
                color: colors.danger,
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(24),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != document.filePath,
      onAcceptWithDetails: (details) => onAcceptDocument(details.data),
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        final decoratedTile = DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: isHovering ? colors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: tile,
        );

        return Draggable<String>(
          data: document.filePath,
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(
              opacity: 0.9,
              child: SizedBox(width: 250, height: 30, child: tile),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.42, child: decoratedTile),
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: decoratedTile,
          ),
        );
      },
    );
  }
}

class ExplorerDocumentDropZone extends StatelessWidget {
  const ExplorerDocumentDropZone({super.key, required this.onAcceptDocument});

  final ValueChanged<String> onAcceptDocument;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onAcceptDocument(details.data),
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: isHovering ? 18 : 6,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: isHovering ? colors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}

class EditorTabBar extends StatelessWidget {
  const EditorTabBar({
    super.key,
    required this.documents,
    required this.tabs,
    required this.activeTabIndex,
    required this.groupId,
    required this.onSelectTab,
    required this.onCloseTab,
    required this.onReorderTab,
  });

  final List<MarkdownDocument> documents;
  final List<MarkdownEditorTab> tabs;
  final int activeTabIndex;
  final EditorGroupId groupId;
  final ValueChanged<int> onSelectTab;
  final ValueChanged<int> onCloseTab;
  final void Function(EditorTabDragPayload payload, int targetIndex)
  onReorderTab;

  MarkdownDocument? _documentForTab(MarkdownEditorTab tab) {
    for (final document in documents) {
      if (document.filePath == tab.filePath) {
        return document;
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;
    final tabWidgets = [
      for (var index = 0; index < tabs.length; index++)
        Builder(
          builder: (context) {
            final document = _documentForTab(tabs[index]);
            if (document == null) {
              return const SizedBox.shrink();
            }

            return DocumentTab(
              document: document,
              viewMode: tabs[index].viewMode,
              selected: index == activeTabIndex,
              dragPayload: EditorTabDragPayload(
                groupId: groupId,
                tabIndex: index,
              ),
              onSelect: () => onSelectTab(index),
              onClose: () => onCloseTab(index),
              onAcceptTab: (payload) => onReorderTab(payload, index),
            );
          },
        ),
      TabReorderDropZone(
        onAcceptTab: (payload) => onReorderTab(payload, tabs.length),
      ),
    ];

    return Container(
      height: 36,
      color: colors.tabBar,
      alignment: Alignment.centerLeft,
      child:
          tabs.isEmpty
              ? const Row(children: [WelcomeTab(), Expanded(child: SizedBox())])
              : ListView(
                scrollDirection: Axis.horizontal,
                children: tabWidgets,
              ),
    );
  }
}

class TabReorderDropZone extends StatelessWidget {
  const TabReorderDropZone({super.key, required this.onAcceptTab});

  final ValueChanged<EditorTabDragPayload> onAcceptTab;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return DragTarget<EditorTabDragPayload>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onAcceptTab(details.data),
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: isHovering ? 44 : 24,
          height: 36,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: isHovering ? colors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}

class WelcomeTab extends StatelessWidget {
  const WelcomeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return Container(
      width: 180,
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colors.editor,
        border: Border(right: BorderSide(color: colors.border, width: 1)),
      ),
      child: Row(
        children: [
          Icon(Icons.home_outlined, size: 15, color: colors.mutedText),
          const SizedBox(width: 8),
          Text(
            'Welcome',
            style: TextStyle(color: colors.primaryText, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class DocumentTab extends StatelessWidget {
  const DocumentTab({
    super.key,
    required this.document,
    required this.viewMode,
    required this.selected,
    required this.dragPayload,
    required this.onSelect,
    required this.onClose,
    required this.onAcceptTab,
  });

  final MarkdownDocument document;
  final MarkdownViewMode viewMode;
  final bool selected;
  final EditorTabDragPayload dragPayload;
  final VoidCallback onSelect;
  final VoidCallback onClose;
  final ValueChanged<EditorTabDragPayload> onAcceptTab;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    final tab = Material(
      color: selected ? colors.editor : colors.tabBar,
      child: InkWell(
        onTap: onSelect,
        hoverColor: colors.panelHeader,
        child: Container(
          width: viewMode == MarkdownViewMode.source ? 190 : 230,
          height: 36,
          padding: const EdgeInsets.only(left: 12, right: 4),
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: colors.border, width: 1)),
          ),
          child: Row(
            children: [
              Icon(
                document.errorMessage != null
                    ? Icons.error_outline
                    : viewMode == MarkdownViewMode.source
                    ? Icons.description_outlined
                    : Icons.visibility_outlined,
                size: 15,
                color:
                    document.errorMessage == null
                        ? colors.markdownIcon
                        : colors.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  viewMode == MarkdownViewMode.source
                      ? document.fileName
                      : 'Preview ${document.fileName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? colors.primaryText : colors.secondaryText,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 15),
                color: selected ? colors.secondaryText : colors.mutedText,
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(28),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return DragTarget<EditorTabDragPayload>(
      onWillAcceptWithDetails: (details) {
        final payload = details.data;
        return payload.groupId != dragPayload.groupId ||
            payload.tabIndex != dragPayload.tabIndex;
      },
      onAcceptWithDetails: (details) => onAcceptTab(details.data),
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        final decoratedTab = DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: isHovering ? colors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: tab,
        );

        return Draggable<EditorTabDragPayload>(
          data: dragPayload,
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(
              opacity: 0.88,
              child: SizedBox(
                width: viewMode == MarkdownViewMode.source ? 190 : 230,
                height: 36,
                child: tab,
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.45, child: decoratedTab),
          child: decoratedTab,
        );
      },
    );
  }
}

class SplitResizeDivider extends StatefulWidget {
  const SplitResizeDivider({
    super.key,
    required this.onDragDelta,
    required this.onReset,
  });

  static const double width = 9;

  final ValueChanged<double> onDragDelta;
  final VoidCallback onReset;

  @override
  State<SplitResizeDivider> createState() => _SplitResizeDividerState();
}

class _SplitResizeDividerState extends State<SplitResizeDivider> {
  bool _isHovered = false;
  bool _isDragging = false;

  bool get _isActive => _isHovered || _isDragging;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;
    final dividerColor = _isActive ? colors.accent : colors.border;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) {
        setState(() {
          _isHovered = true;
        });
      },
      onExit: (_) {
        setState(() {
          _isHovered = false;
        });
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: widget.onReset,
        onHorizontalDragStart: (_) {
          setState(() {
            _isDragging = true;
          });
        },
        onHorizontalDragUpdate:
            (details) => widget.onDragDelta(details.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() {
            _isDragging = false;
          });
        },
        onHorizontalDragCancel: () {
          setState(() {
            _isDragging = false;
          });
        },
        child: SizedBox(
          width: SplitResizeDivider.width,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color:
                  _isActive
                      ? colors.accent.withValues(alpha: 0.12)
                      : Colors.transparent,
              border: Border(
                left: BorderSide(color: dividerColor, width: _isActive ? 2 : 1),
              ),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class SplitPreviewOverlay extends StatelessWidget {
  const SplitPreviewOverlay({super.key, required this.side});

  final SplitDropSide side;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Row(
        children:
            side == SplitDropSide.left
                ? [_highlightedPane(), _dimmedPane()]
                : [_dimmedPane(), _highlightedPane()],
      ),
    );
  }

  Widget _dimmedPane() {
    return Builder(
      builder: (context) {
        final colors = context.editorColors;

        return Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.background.withValues(alpha: 0.56),
            ),
          ),
        );
      },
    );
  }

  Widget _highlightedPane() {
    return Builder(
      builder: (context) {
        final colors = context.editorColors;

        return Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: colors.selection.withValues(alpha: 0.68),
              border: Border.all(color: colors.accent, width: 2),
            ),
            child: Center(
              child: Icon(
                Icons.vertical_split_outlined,
                color: colors.primaryText,
                size: 32,
              ),
            ),
          ),
        );
      },
    );
  }
}

class SourcePane extends StatelessWidget {
  const SourcePane({
    super.key,
    this.editorKey,
    this.showPanelHeader = true,
    required this.filePath,
    required this.markdown,
    required this.onChanged,
    required this.initialScrollOffset,
    required this.onScrollPositionChanged,
    required this.revealRequest,
    required this.onRevealConsumed,
  });

  final Key? editorKey;
  final bool showPanelHeader;
  final String filePath;
  final String markdown;
  final void Function(String filePath, String markdown) onChanged;
  final double initialScrollOffset;
  final ValueChanged<double> onScrollPositionChanged;
  final SourceRevealRequest? revealRequest;
  final ValueChanged<int> onRevealConsumed;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (showPanelHeader) const PanelHeader(title: 'SOURCE'),
        Expanded(
          child: MarkdownSourceEditor(
            key: editorKey,
            filePath: filePath,
            markdown: markdown,
            onChanged: onChanged,
            initialScrollOffset: initialScrollOffset,
            onScrollPositionChanged: onScrollPositionChanged,
            revealRequest: revealRequest,
            onRevealConsumed: onRevealConsumed,
          ),
        ),
      ],
    );
  }
}

class MarkdownSourceEditor extends StatefulWidget {
  const MarkdownSourceEditor({
    super.key,
    required this.filePath,
    required this.markdown,
    required this.onChanged,
    this.initialScrollOffset = 0,
    this.onScrollPositionChanged,
    required this.revealRequest,
    this.onRevealConsumed,
  });

  final String filePath;
  final String markdown;
  final void Function(String filePath, String markdown) onChanged;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollPositionChanged;
  final SourceRevealRequest? revealRequest;
  final ValueChanged<int>? onRevealConsumed;

  @override
  State<MarkdownSourceEditor> createState() => _MarkdownSourceEditorState();
}

class _SearchHighlightTextController extends TextEditingController {
  _SearchHighlightTextController({super.text});

  List<int> _matchOffsets = const [];
  int _currentMatchIndex = -1;
  int _queryLength = 0;
  Color _matchColor = Colors.transparent;
  Color _currentMatchColor = Colors.transparent;

  void updateSearchHighlights({
    required List<int> matchOffsets,
    required int currentMatchIndex,
    required int queryLength,
    required Color matchColor,
    required Color currentMatchColor,
  }) {
    final shouldNotify =
        !_listEquals(_matchOffsets, matchOffsets) ||
        _currentMatchIndex != currentMatchIndex ||
        _queryLength != queryLength ||
        _matchColor != matchColor ||
        _currentMatchColor != currentMatchColor;

    if (!shouldNotify) {
      return;
    }

    _matchOffsets = List<int>.of(matchOffsets);
    _currentMatchIndex = currentMatchIndex;
    _queryLength = queryLength;
    _matchColor = matchColor;
    _currentMatchColor = currentMatchColor;
    notifyListeners();
  }

  void clearSearchHighlights() {
    updateSearchHighlights(
      matchOffsets: const [],
      currentMatchIndex: -1,
      queryLength: 0,
      matchColor: Colors.transparent,
      currentMatchColor: Colors.transparent,
    );
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (_matchOffsets.isEmpty || _queryLength <= 0 || text.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final children = <TextSpan>[];
    var cursor = 0;

    for (var index = 0; index < _matchOffsets.length; index++) {
      final start = _matchOffsets[index].clamp(0, text.length);
      final end = (start + _queryLength).clamp(0, text.length);
      if (start < cursor || start >= end) {
        continue;
      }

      if (cursor < start) {
        children.add(TextSpan(text: text.substring(cursor, start)));
      }

      children.add(
        TextSpan(
          text: text.substring(start, end),
          style: TextStyle(
            backgroundColor:
                index == _currentMatchIndex ? _currentMatchColor : _matchColor,
          ),
        ),
      );
      cursor = end;
    }

    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor)));
    }

    return TextSpan(style: style, children: children);
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) {
      return false;
    }
  }
  return true;
}

class _MarkdownSourceEditorState extends State<MarkdownSourceEditor> {
  late final _SearchHighlightTextController _textController;
  late final ScrollController _scrollController;
  late final FocusNode _focusNode;
  late final FocusNode _shortcutFocusNode;
  late final FocusNode _findFocusNode;
  late final TextEditingController _findController;
  final GlobalKey _revealedLineKey = GlobalKey();
  final GlobalKey _scrollViewportKey = GlobalKey();
  Timer? _revealScrollTimer;
  int? _revealedLineIndex;
  int? _activeRevealRequestId;
  List<int> _searchMatchOffsets = const [];
  int _currentSearchMatchIndex = -1;
  bool _isFindVisible = false;

  @override
  void initState() {
    super.initState();
    _textController = _SearchHighlightTextController(text: widget.markdown);
    _scrollController = ScrollController(
      initialScrollOffset: widget.initialScrollOffset,
    )..addListener(_handleScroll);
    _focusNode = FocusNode();
    _shortcutFocusNode = FocusNode();
    _findFocusNode = FocusNode();
    _findController = TextEditingController();
    _updateRevealedLine(widget.revealRequest);
    _scheduleRevealRequest(widget.revealRequest);
  }

  @override
  void didUpdateWidget(covariant MarkdownSourceEditor oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.markdown != _textController.text) {
      final oldSelection = _textController.selection;
      final selectionOffset = oldSelection.baseOffset.clamp(
        0,
        widget.markdown.length,
      );

      _textController.value = TextEditingValue(
        text: widget.markdown,
        selection: TextSelection.collapsed(offset: selectionOffset),
      );
      if (_isFindVisible) {
        _updateSourceSearch(_findController.text);
      }
    }

    if (widget.revealRequest != null &&
        widget.revealRequest?.id != oldWidget.revealRequest?.id) {
      _updateRevealedLine(widget.revealRequest);
      _scheduleRevealRequest(widget.revealRequest);
    }
  }

  @override
  void dispose() {
    _revealScrollTimer?.cancel();
    _textController.dispose();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _focusNode.dispose();
    _shortcutFocusNode.dispose();
    _findFocusNode.dispose();
    _findController.dispose();
    super.dispose();
  }

  void _scheduleRevealRequest(SourceRevealRequest? request) {
    if (request == null) {
      return;
    }

    _activeRevealRequestId = request.id;
    _revealScrollTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activeRevealRequestId != request.id) {
        return;
      }

      final offset =
          request.offset.clamp(0, _textController.text.length).toInt();
      _textController.selection = TextSelection.collapsed(offset: offset);
      _focusNode.requestFocus();
      widget.onRevealConsumed?.call(request.id);

      _revealScrollTimer = Timer(const Duration(milliseconds: 180), () {
        if (!mounted ||
            _activeRevealRequestId != request.id ||
            !_scrollController.hasClients) {
          return;
        }
        _alignRevealedLine();
      });
    });
  }

  void _alignRevealedLine() {
    if (!_scrollController.hasClients) {
      return;
    }

    final lineContext = _revealedLineKey.currentContext;
    final viewportContext = _scrollViewportKey.currentContext;
    if (lineContext == null || viewportContext == null) {
      return;
    }
    if (!lineContext.mounted || !viewportContext.mounted) {
      return;
    }

    final lineBox = lineContext.findRenderObject() as RenderBox;
    final viewportBox = viewportContext.findRenderObject() as RenderBox;
    final lineOffsetFromTop =
        lineBox.localToGlobal(Offset.zero).dy -
        viewportBox.localToGlobal(Offset.zero).dy;
    final targetOffset =
        (_scrollController.offset + lineOffsetFromTop - 18)
            .clamp(0.0, _scrollController.position.maxScrollExtent)
            .toDouble();
    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  void _handleScroll() {
    widget.onScrollPositionChanged?.call(_scrollController.offset);
  }

  void _updateRevealedLine(SourceRevealRequest? request) {
    if (request == null) {
      _revealedLineIndex = null;
      return;
    }

    final offset = request.offset.clamp(0, widget.markdown.length).toInt();
    _revealedLineIndex =
        '\n'.allMatches(widget.markdown.substring(0, offset)).length;
  }

  void _openFind() {
    setState(() {
      _isFindVisible = true;
    });
    if (_findController.text.trim().isNotEmpty) {
      _updateSourceSearch(_findController.text);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _findFocusNode.requestFocus();
      _findController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _findController.text.length,
      );
    });
  }

  void _closeFind() {
    if (!_isFindVisible) {
      return;
    }

    setState(() {
      _isFindVisible = false;
      _searchMatchOffsets = const [];
      _currentSearchMatchIndex = -1;
      _revealedLineIndex = null;
    });
    _textController.clearSearchHighlights();
    _focusNode.requestFocus();
  }

  void _updateSourceSearch(String query) {
    final normalizedQuery = query.trim().toLowerCase();
    final source = _textController.text.toLowerCase();
    final matches = <int>[];

    if (normalizedQuery.isNotEmpty) {
      var searchOffset = 0;
      while (searchOffset <= source.length - normalizedQuery.length) {
        final offset = source.indexOf(normalizedQuery, searchOffset);
        if (offset == -1) {
          break;
        }
        matches.add(offset);
        searchOffset = offset + normalizedQuery.length;
      }
    }

    setState(() {
      _searchMatchOffsets = matches;
      _currentSearchMatchIndex = matches.isEmpty ? -1 : 0;
    });
    _showCurrentSourceSearchMatch();
  }

  void _moveSourceSearchMatch(int change) {
    if (_searchMatchOffsets.isEmpty) {
      return;
    }

    setState(() {
      _currentSearchMatchIndex =
          (_currentSearchMatchIndex + change) % _searchMatchOffsets.length;
      if (_currentSearchMatchIndex < 0) {
        _currentSearchMatchIndex += _searchMatchOffsets.length;
      }
    });
    _showCurrentSourceSearchMatch();
  }

  void _showCurrentSourceSearchMatch() {
    if (_currentSearchMatchIndex < 0 ||
        _currentSearchMatchIndex >= _searchMatchOffsets.length) {
      return;
    }

    final offset = _searchMatchOffsets[_currentSearchMatchIndex];
    final queryLength = _findController.text.trim().length;
    _textController.selection = TextSelection(
      baseOffset: offset,
      extentOffset: offset + queryLength,
    );
    setState(() {
      _revealedLineIndex =
          '\n'.allMatches(_textController.text.substring(0, offset)).length;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _alignRevealedLine();
        _findFocusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;
    final sourceSearchHighlight =
        Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFFB36B00)
            : const Color(0xFFFFC928);
    final sourceSearchMatchHighlight =
        Theme.of(context).brightness == Brightness.dark
            ? const Color(0x665A4520)
            : const Color(0x66FFE58A);
    _textController.updateSearchHighlights(
      matchOffsets: _isFindVisible ? _searchMatchOffsets : const [],
      currentMatchIndex: _currentSearchMatchIndex,
      queryLength: _findController.text.trim().length,
      matchColor: sourceSearchMatchHighlight,
      currentMatchColor: sourceSearchHighlight,
    );
    final lineCount =
        _textController.text.isEmpty
            ? 1
            : '\n'.allMatches(_textController.text).length + 1;

    return LayoutBuilder(
      builder: (context, constraints) {
        return DecoratedBox(
          decoration: BoxDecoration(color: colors.editor),
          child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                  _openFind,
              const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                  _openFind,
              const SingleActivator(LogicalKeyboardKey.escape): _closeFind,
            },
            child: Focus(
              autofocus: true,
              focusNode: _shortcutFocusNode,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      child: SizedBox(
                        key: _scrollViewportKey,
                        child: SingleChildScrollView(
                          key: const ValueKey<String>(
                            'source-editor-scroll-view',
                          ),
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(0, 18, 24, 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 62,
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 12),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          for (
                                            var line = 1;
                                            line <= lineCount;
                                            line++
                                          )
                                            Text(
                                              key:
                                                  line - 1 == _revealedLineIndex
                                                      ? _revealedLineKey
                                                      : null,
                                              '$line',
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                color: colors.lineNumber,
                                                fontFamily: 'Menlo',
                                                fontSize: 13,
                                                height: 1.55,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: TextSelectionTheme(
                                      key: const ValueKey<String>(
                                        'source-search-selection-theme',
                                      ),
                                      data: TextSelectionThemeData(
                                        selectionColor: sourceSearchHighlight,
                                      ),
                                      child: TextField(
                                        controller: _textController,
                                        focusNode: _focusNode,
                                        autofocus: false,
                                        minLines: null,
                                        maxLines: null,
                                        keyboardType: TextInputType.multiline,
                                        cursorColor: colors.accent,
                                        style: TextStyle(
                                          color: colors.primaryText,
                                          fontFamily: 'Menlo',
                                          fontSize: 13,
                                          height: 1.55,
                                        ),
                                        decoration: const InputDecoration(
                                          border: InputBorder.none,
                                          isCollapsed: true,
                                          contentPadding: EdgeInsets.zero,
                                        ),
                                        onChanged: (value) {
                                          widget.onChanged(
                                            widget.filePath,
                                            value,
                                          );
                                          if (_isFindVisible) {
                                            _updateSourceSearch(
                                              _findController.text,
                                            );
                                          }
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: constraints.maxHeight),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_isFindVisible)
                    _EditorFindBar(
                      keyPrefix: 'source',
                      controller: _findController,
                      focusNode: _findFocusNode,
                      matchCount: _searchMatchOffsets.length,
                      currentMatchIndex: _currentSearchMatchIndex,
                      onChanged: _updateSourceSearch,
                      onPrevious: () => _moveSourceSearchMatch(-1),
                      onNext: () => _moveSourceSearchMatch(1),
                      onClose: _closeFind,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class PreviewPane extends StatefulWidget {
  const PreviewPane({
    super.key,
    this.showPanelHeader = true,
    this.selectable = true,
    this.revealOnDoubleTap = true,
    this.selectionToolbarEditEnabled = false,
    this.contentPadding = const EdgeInsets.fromLTRB(52, 28, 52, 52),
    this.initialScrollOffset = 0,
    this.onScrollPositionChanged,
    required this.markdown,
    required this.imageDirectory,
    required this.onTapLink,
    required this.onRevealSource,
    this.onOpenSource,
    this.onLongPressSource,
  });

  final bool showPanelHeader;
  final bool selectable;
  final bool revealOnDoubleTap;
  final bool selectionToolbarEditEnabled;
  final EdgeInsets contentPadding;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollPositionChanged;
  final String markdown;
  final String? imageDirectory;
  final Future<void> Function(String? href) onTapLink;
  final ValueChanged<int> onRevealSource;
  final VoidCallback? onOpenSource;
  final ValueChanged<int>? onLongPressSource;

  @override
  State<PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends State<PreviewPane> {
  late final ScrollController _scrollController;
  late final FocusNode _previewFocusNode;
  late final FocusNode _findFocusNode;
  late final TextEditingController _findController;
  final List<GlobalKey> _blockKeys = [];
  List<_PreviewSearchMatch> _searchMatches = const [];
  int _currentSearchMatchIndex = -1;
  int? _lastInteractionSourceOffset;
  String _searchQuery = '';
  bool _isFindVisible = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: widget.initialScrollOffset,
    )..addListener(_handleScroll);
    _previewFocusNode = FocusNode();
    _findFocusNode = FocusNode();
    _findController = TextEditingController();
  }

  @override
  void didUpdateWidget(covariant PreviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.markdown != oldWidget.markdown && _isFindVisible) {
      _updateSearch(_findController.text);
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _previewFocusNode.dispose();
    _findFocusNode.dispose();
    _findController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    widget.onScrollPositionChanged?.call(_scrollController.offset);
  }

  void _openFind() {
    if (!widget.selectable) {
      return;
    }

    setState(() {
      _isFindVisible = true;
    });
    if (_findController.text.trim().isNotEmpty) {
      _updateSearch(_findController.text);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _findFocusNode.requestFocus();
      _findController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _findController.text.length,
      );
    });
  }

  void _closeFind() {
    if (!_isFindVisible) {
      return;
    }

    setState(() {
      _isFindVisible = false;
      _searchQuery = '';
      _searchMatches = const [];
      _currentSearchMatchIndex = -1;
    });
    _previewFocusNode.requestFocus();
  }

  void _updateSearch(String query) {
    final normalizedQuery = query.trim().toLowerCase();
    final matches = <_PreviewSearchMatch>[];

    if (normalizedQuery.isNotEmpty) {
      final blocks = _splitMarkdownPreviewBlocks(widget.markdown);
      for (var blockIndex = 0; blockIndex < blocks.length; blockIndex++) {
        final source = blocks[blockIndex].markdown.toLowerCase();
        var searchOffset = 0;
        var occurrenceIndexInBlock = 0;
        while (searchOffset <= source.length - normalizedQuery.length) {
          final offset = source.indexOf(normalizedQuery, searchOffset);
          if (offset == -1) {
            break;
          }
          matches.add(
            _PreviewSearchMatch(
              blockIndex: blockIndex,
              occurrenceIndexInBlock: occurrenceIndexInBlock,
            ),
          );
          occurrenceIndexInBlock++;
          searchOffset = offset + normalizedQuery.length;
        }
      }
    }

    setState(() {
      _searchQuery = query.trim();
      _searchMatches = matches;
      _currentSearchMatchIndex = matches.isEmpty ? -1 : 0;
    });
    _scrollToCurrentSearchMatch();
  }

  void _moveSearchMatch(int change) {
    if (_searchMatches.isEmpty) {
      return;
    }

    setState(() {
      _currentSearchMatchIndex =
          (_currentSearchMatchIndex + change) % _searchMatches.length;
      if (_currentSearchMatchIndex < 0) {
        _currentSearchMatchIndex += _searchMatches.length;
      }
    });
    _scrollToCurrentSearchMatch();
  }

  void _scrollToCurrentSearchMatch() {
    if (_currentSearchMatchIndex < 0 ||
        _currentSearchMatchIndex >= _searchMatches.length) {
      return;
    }

    final blockIndex = _searchMatches[_currentSearchMatchIndex].blockIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || blockIndex >= _blockKeys.length) {
        return;
      }
      final blockContext = _blockKeys[blockIndex].currentContext;
      if (blockContext == null) {
        return;
      }
      Scrollable.ensureVisible(
        blockContext,
        alignment: 0.1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _buildSelectionContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    final buttonItems = List<ContextMenuButtonItem>.of(
      selectableRegionState.contextMenuButtonItems,
    );

    if (widget.selectionToolbarEditEnabled) {
      buttonItems.add(
        ContextMenuButtonItem(
          label: 'Edit',
          onPressed: () {
            selectableRegionState.hideToolbar();
            final sourceOffset = _lastInteractionSourceOffset;
            if (sourceOffset == null) {
              widget.onOpenSource?.call();
              return;
            }
            widget.onRevealSource(sourceOffset);
          },
        ),
      );
    }

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;
    final blocks = _splitMarkdownPreviewBlocks(widget.markdown);
    final styleSheet = buildMarkdownStyleSheet(colors);
    final normalizedSearchQuery = _searchQuery;
    final previewSearchHighlight =
        Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFFB36B00)
            : const Color(0xFFFFC928);
    while (_blockKeys.length < blocks.length) {
      _blockKeys.add(GlobalKey());
    }
    if (_blockKeys.length > blocks.length) {
      _blockKeys.removeRange(blocks.length, _blockKeys.length);
    }

    final currentBlockIndex =
        _currentSearchMatchIndex < 0
            ? -1
            : _searchMatches[_currentSearchMatchIndex].blockIndex;
    final scrollContent = ListView(
      controller: _scrollController,
      padding: widget.contentPadding,
      children: [
        for (var index = 0; index < blocks.length; index++) ...[
          if (blocks[index].addSpacingBefore)
            SizedBox(height: styleSheet.blockSpacing ?? 0),
          DecoratedBox(
            key: _blockKeys[index],
            decoration: BoxDecoration(
              color: Colors.transparent,
              border: Border.all(color: Colors.transparent, width: 1.5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.text,
              child: Listener(
                onPointerDown: (_) {
                  _lastInteractionSourceOffset = blocks[index].sourceOffset;
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapDown:
                      (_) =>
                          _lastInteractionSourceOffset =
                              blocks[index].sourceOffset,
                  onDoubleTap:
                      widget.revealOnDoubleTap
                          ? () =>
                              widget.onRevealSource(blocks[index].sourceOffset)
                          : null,
                  onLongPress:
                      widget.onLongPressSource == null
                          ? null
                          : () => widget.onLongPressSource!(
                            blocks[index].sourceOffset,
                          ),
                  child: MarkdownBody(
                    key: ValueKey<String>(
                      'preview-markdown:$index:$normalizedSearchQuery:'
                      '$_currentSearchMatchIndex',
                    ),
                    selectable: false,
                    data: blocks[index].markdown,
                    imageDirectory: widget.imageDirectory,
                    onTapLink: (_, href, __) => widget.onTapLink(href),
                    styleSheet: styleSheet,
                    builders:
                        normalizedSearchQuery.isEmpty
                            ? const <String, MarkdownElementBuilder>{}
                            : {
                              for (final tag in _previewSearchTextTags)
                                tag: _MarkdownSearchHighlightBuilder(
                                  query: normalizedSearchQuery,
                                  currentMatchOccurrenceIndex:
                                      currentBlockIndex == index
                                          ? _searchMatches[_currentSearchMatchIndex]
                                              .occurrenceIndexInBlock
                                          : null,
                                  currentMatchColor: previewSearchHighlight,
                                ),
                            },
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
    final previewContent =
        widget.selectable
            ? SelectionArea(
              contextMenuBuilder: _buildSelectionContextMenu,
              child: scrollContent,
            )
            : scrollContent;

    return Column(
      children: [
        if (widget.showPanelHeader) const PanelHeader(title: 'PREVIEW'),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(color: colors.preview),
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                    _openFind,
                const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                    _openFind,
                const SingleActivator(LogicalKeyboardKey.escape): _closeFind,
              },
              child: Focus(
                autofocus: widget.selectable,
                focusNode: _previewFocusNode,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Listener(
                        onPointerDown: (_) => _previewFocusNode.requestFocus(),
                        child: previewContent,
                      ),
                    ),
                    if (_isFindVisible)
                      _EditorFindBar(
                        keyPrefix: 'preview',
                        controller: _findController,
                        focusNode: _findFocusNode,
                        matchCount: _searchMatches.length,
                        currentMatchIndex: _currentSearchMatchIndex,
                        onChanged: _updateSearch,
                        onPrevious: () => _moveSearchMatch(-1),
                        onNext: () => _moveSearchMatch(1),
                        onClose: _closeFind,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewSearchMatch {
  const _PreviewSearchMatch({
    required this.blockIndex,
    required this.occurrenceIndexInBlock,
  });

  final int blockIndex;
  final int occurrenceIndexInBlock;
}

const List<String> _previewSearchTextTags = [
  'p',
  'li',
  'blockquote',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'strong',
  'em',
  'del',
  'code',
];

class _MarkdownSearchHighlightBuilder extends MarkdownElementBuilder {
  _MarkdownSearchHighlightBuilder({
    required this.query,
    required this.currentMatchOccurrenceIndex,
    required this.currentMatchColor,
  });

  final String query;
  final int? currentMatchOccurrenceIndex;
  final Color currentMatchColor;
  int _visitedOccurrenceCount = 0;

  @override
  Widget? visitText(dynamic text, TextStyle? preferredStyle) {
    final source = text.text as String;
    final normalizedQuery = query.toLowerCase();
    if (normalizedQuery.isEmpty || source.isEmpty) {
      return null;
    }

    final normalizedSource = source.toLowerCase();
    final spans = <TextSpan>[];
    var cursor = 0;
    var searchOffset = 0;

    while (searchOffset <= normalizedSource.length - normalizedQuery.length) {
      final start = normalizedSource.indexOf(normalizedQuery, searchOffset);
      if (start == -1) {
        break;
      }
      final end = start + normalizedQuery.length;

      if (cursor < start) {
        spans.add(
          TextSpan(
            text: source.substring(cursor, start),
            style: preferredStyle,
          ),
        );
      }

      final isCurrent = _visitedOccurrenceCount == currentMatchOccurrenceIndex;
      final highlightColor = isCurrent ? currentMatchColor : null;
      spans.add(
        TextSpan(
          text: source.substring(start, end),
          style:
              highlightColor == null
                  ? preferredStyle
                  : (preferredStyle ?? const TextStyle()).copyWith(
                    backgroundColor: highlightColor,
                  ),
        ),
      );

      _visitedOccurrenceCount++;
      cursor = end;
      searchOffset = end;
    }

    if (spans.isEmpty) {
      return Text.rich(TextSpan(text: source, style: preferredStyle));
    }

    if (cursor < source.length) {
      spans.add(
        TextSpan(text: source.substring(cursor), style: preferredStyle),
      );
    }

    return Text.rich(TextSpan(children: spans));
  }
}

class _EditorFindBar extends StatelessWidget {
  const _EditorFindBar({
    required this.keyPrefix,
    required this.controller,
    required this.focusNode,
    required this.matchCount,
    required this.currentMatchIndex,
    required this.onChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final String keyPrefix;
  final TextEditingController controller;
  final FocusNode focusNode;
  final int matchCount;
  final int currentMatchIndex;
  final ValueChanged<String> onChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;
    final resultText =
        controller.text.trim().isEmpty
            ? ''
            : matchCount == 0
            ? 'No results'
            : '${currentMatchIndex + 1}/$matchCount';

    return Positioned(
      key: ValueKey<String>('$keyPrefix-find-bar'),
      top: 10,
      left: 14,
      right: 14,
      child: Align(
        alignment: Alignment.topRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 330),
          child: Material(
            color: colors.panelHeader,
            borderRadius: BorderRadius.circular(6),
            elevation: 5,
            child: Container(
              height: 40,
              padding: const EdgeInsets.only(left: 10, right: 4),
              decoration: BoxDecoration(
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: ValueKey<String>('$keyPrefix-find-input'),
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        hintText: 'Find',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      onChanged: onChanged,
                      onSubmitted: (_) {
                        onNext();
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          focusNode.requestFocus();
                        });
                      },
                    ),
                  ),
                  SizedBox(
                    width: 58,
                    child: Text(
                      resultText,
                      key: ValueKey<String>('$keyPrefix-find-results'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colors.secondaryText,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Previous match',
                    icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                    onPressed: onPrevious,
                  ),
                  IconButton(
                    tooltip: 'Next match',
                    icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                    onPressed: onNext,
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MarkdownPreviewBlock {
  const _MarkdownPreviewBlock({
    required this.sourceOffset,
    required this.markdown,
    required this.addSpacingBefore,
  });

  final int sourceOffset;
  final String markdown;
  final bool addSpacingBefore;
}

List<_MarkdownPreviewBlock> _splitMarkdownPreviewBlocks(String markdown) {
  final blocks = <_MarkdownPreviewBlock>[];
  final lines = RegExp(r'.*(?:\n|$)')
      .allMatches(markdown)
      .where((match) => match.group(0)!.isNotEmpty)
      .toList(growable: false);
  var index = 0;
  var needsSpacing = false;
  var previousWasListItem = false;

  while (index < lines.length) {
    final line = lines[index].group(0)!;
    final text = line.trimRight();

    if (text.trim().isEmpty) {
      needsSpacing = blocks.isNotEmpty;
      previousWasListItem = false;
      index++;
      continue;
    }

    final startIndex = index;
    final isListItem = _markdownListMarker.firstMatch(text) != null;

    if (_markdownFenceMarker.hasMatch(text)) {
      index++;
      while (index < lines.length) {
        final nextText = lines[index].group(0)!.trimRight();
        index++;
        if (_markdownFenceMarker.hasMatch(nextText)) {
          break;
        }
      }
    } else if (isListItem) {
      final baseIndent = _leadingWhitespaceLength(text);
      index++;
      while (index < lines.length) {
        final nextText = lines[index].group(0)!.trimRight();
        if (nextText.trim().isEmpty) {
          break;
        }

        final nextListMatch = _markdownListMarker.firstMatch(nextText);
        if (nextListMatch != null &&
            _leadingWhitespaceLength(nextText) <= baseIndent) {
          break;
        }
        if (_startsStandaloneMarkdownBlock(nextText)) {
          break;
        }
        index++;
      }
    } else if (_isSingleLineMarkdownBlock(text)) {
      index++;
    } else if (_markdownBlockquote.hasMatch(text)) {
      index++;
      while (index < lines.length &&
          _markdownBlockquote.hasMatch(lines[index].group(0)!.trimRight())) {
        index++;
      }
    } else if (_looksLikeTableRow(text)) {
      index++;
      while (index < lines.length &&
          _looksLikeTableRow(lines[index].group(0)!.trimRight())) {
        index++;
      }
    } else {
      index++;
      while (index < lines.length) {
        final nextText = lines[index].group(0)!.trimRight();
        if (nextText.trim().isEmpty ||
            _startsStandaloneMarkdownBlock(nextText)) {
          break;
        }
        index++;
      }
    }

    final source = StringBuffer();
    for (var lineIndex = startIndex; lineIndex < index; lineIndex++) {
      source.write(lines[lineIndex].group(0)!);
    }

    blocks.add(
      _MarkdownPreviewBlock(
        sourceOffset: lines[startIndex].start,
        markdown: source.toString(),
        addSpacingBefore:
            blocks.isNotEmpty &&
            (needsSpacing || !isListItem || !previousWasListItem),
      ),
    );
    needsSpacing = false;
    previousWasListItem = isListItem;
  }

  return blocks;
}

final RegExp _markdownFenceMarker = RegExp(r'^\s*(`{3,}|~{3,})');
final RegExp _markdownListMarker = RegExp(
  r'^(\s*)(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?',
);
final RegExp _markdownHeading = RegExp(r'^\s{0,3}#{1,6}\s+');
final RegExp _markdownHorizontalRule = RegExp(
  r'^\s{0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$',
);
final RegExp _markdownBlockquote = RegExp(r'^\s{0,3}>\s?');

bool _startsStandaloneMarkdownBlock(String line) {
  return _markdownFenceMarker.hasMatch(line) ||
      _markdownListMarker.hasMatch(line) ||
      _isSingleLineMarkdownBlock(line) ||
      _markdownBlockquote.hasMatch(line) ||
      _looksLikeTableRow(line);
}

bool _isSingleLineMarkdownBlock(String line) {
  return _markdownHeading.hasMatch(line) ||
      _markdownHorizontalRule.hasMatch(line);
}

bool _looksLikeTableRow(String line) {
  return line.trimLeft().startsWith('|') && line.contains('|');
}

int _leadingWhitespaceLength(String line) {
  return RegExp(r'^\s*').firstMatch(line)!.group(0)!.length;
}

class PanelHeader extends StatelessWidget {
  const PanelHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: colors.panelHeader,
        border: Border(bottom: BorderSide(color: colors.border, width: 1)),
      ),
      child: Text(
        title,
        style: TextStyle(
          color: colors.secondaryText,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class EmptyEditorState extends StatelessWidget {
  const EmptyEditorState({super.key, required this.onOpenPressed});

  final VoidCallback onOpenPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.description_outlined, size: 46, color: colors.mutedText),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onOpenPressed,
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('Open Markdown File'),
          ),
        ],
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    required this.onOpenPressed,
  });

  final String message;
  final VoidCallback onOpenPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 38, color: colors.error),
              const SizedBox(height: 14),
              SelectableText(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.primaryText,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: onOpenPressed,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Open Another File'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class StatusBar extends StatelessWidget {
  const StatusBar({
    super.key,
    required this.filePath,
    required this.lineCount,
    required this.wordCount,
    required this.lastModified,
    required this.autoReload,
    required this.onAutoReloadChanged,
  });

  final String? filePath;
  final int lineCount;
  final int wordCount;
  final DateTime? lastModified;
  final bool autoReload;
  final ValueChanged<bool> onAutoReloadChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.editorColors;

    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: colors.accent,
      child: Row(
        children: [
          const Icon(Icons.check, size: 14, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            filePath == null ? 'Ready' : p.basename(filePath!),
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          const Spacer(),
          Text(
            '$lineCount lines',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          const SizedBox(width: 16),
          Text(
            '$wordCount words',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          const SizedBox(width: 16),
          if (lastModified != null)
            Text(
              'Modified ${_formatTime(lastModified!)}',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          const SizedBox(width: 16),
          Row(
            children: [
              const Text(
                'Auto reload',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
              Transform.scale(
                scale: 0.75,
                child: Switch(
                  value: autoReload,
                  activeThumbColor: Colors.white,
                  activeTrackColor: Colors.white38,
                  inactiveThumbColor: Colors.white70,
                  inactiveTrackColor: Colors.black26,
                  onChanged: onAutoReloadChanged,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

bool _isMarkdownPath(String path) {
  final extension = p.extension(path).replaceFirst('.', '').toLowerCase();
  return const {'md', 'markdown', 'mdown', 'mkd', 'txt'}.contains(extension);
}

MarkdownStyleSheet buildMarkdownStyleSheet(EditorThemeColors colors) {
  return MarkdownStyleSheet(
    p: TextStyle(color: colors.primaryText, fontSize: 15, height: 1.55),
    a: TextStyle(
      color: colors.link,
      fontSize: 15,
      height: 1.55,
      decoration: TextDecoration.underline,
      decorationColor: colors.link,
    ),
    h1: TextStyle(
      color: colors.primaryText,
      fontSize: 30,
      height: 1.25,
      fontWeight: FontWeight.w800,
    ),
    h1Padding: const EdgeInsets.only(top: 8, bottom: 12),
    h2: TextStyle(
      color: colors.primaryText,
      fontSize: 22,
      height: 1.35,
      fontWeight: FontWeight.w700,
    ),
    h2Padding: const EdgeInsets.only(top: 20, bottom: 8),
    h3: TextStyle(
      color: colors.primaryText,
      fontSize: 18,
      height: 1.4,
      fontWeight: FontWeight.w700,
    ),
    h3Padding: const EdgeInsets.only(top: 16, bottom: 6),
    h4: TextStyle(
      color: colors.primaryText,
      fontSize: 16,
      height: 1.45,
      fontWeight: FontWeight.w700,
    ),
    h5: TextStyle(
      color: colors.primaryText,
      fontSize: 15,
      height: 1.45,
      fontWeight: FontWeight.w700,
    ),
    h6: TextStyle(
      color: colors.secondaryText,
      fontSize: 14,
      height: 1.45,
      fontWeight: FontWeight.w700,
    ),
    strong: const TextStyle(fontWeight: FontWeight.w800),
    em: const TextStyle(fontStyle: FontStyle.italic),
    code: TextStyle(
      color: colors.codeText,
      backgroundColor: colors.inlineCodeBackground,
      fontFamily: 'Menlo',
      fontSize: 13,
      height: 1.45,
    ),
    codeblockPadding: const EdgeInsets.all(14),
    codeblockDecoration: BoxDecoration(
      color: colors.codeBlockBackground,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: colors.border),
    ),
    blockquote: TextStyle(
      color: colors.secondaryText,
      fontSize: 15,
      height: 1.55,
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(16, 10, 14, 10),
    blockquoteDecoration: BoxDecoration(
      color: colors.panelHeader,
      border: Border(left: BorderSide(color: colors.accent, width: 3)),
    ),
    tableHead: TextStyle(
      color: colors.primaryText,
      fontWeight: FontWeight.w700,
    ),
    tableBody: TextStyle(color: colors.primaryText, fontSize: 14, height: 1.45),
    tableBorder: TableBorder.all(color: colors.border),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    listBullet: TextStyle(color: colors.primaryText, fontSize: 15),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: colors.border, width: 1)),
    ),
  );
}

ThemeData _buildAppTheme(EditorThemeColors colors, Brightness brightness) {
  return ThemeData(
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: colors.accent,
      brightness: brightness,
      surface: colors.background,
    ),
    fontFamily: 'SF Pro Text',
    scaffoldBackgroundColor: colors.background,
    useMaterial3: true,
    extensions: [colors],
  );
}

@immutable
class EditorThemeColors extends ThemeExtension<EditorThemeColors> {
  const EditorThemeColors({
    required this.background,
    required this.titleBar,
    required this.activityRail,
    required this.sidebar,
    required this.tabBar,
    required this.editor,
    required this.preview,
    required this.panelHeader,
    required this.border,
    required this.selection,
    required this.accent,
    required this.primaryText,
    required this.secondaryText,
    required this.mutedText,
    required this.disabledText,
    required this.lineNumber,
    required this.markdownIcon,
    required this.codeText,
    required this.inlineCodeBackground,
    required this.codeBlockBackground,
    required this.link,
    required this.error,
    required this.danger,
  });

  static const darkMode = EditorThemeColors(
    background: Color(0xFF1E1E1E),
    titleBar: Color(0xFF2D2D2D),
    activityRail: Color(0xFF333333),
    sidebar: Color(0xFF252526),
    tabBar: Color(0xFF2D2D2D),
    editor: Color(0xFF1E1E1E),
    preview: Color(0xFF1F1F1F),
    panelHeader: Color(0xFF242424),
    border: Color(0xFF3C3C3C),
    selection: Color(0xFF37373D),
    accent: Color(0xFF007ACC),
    primaryText: Color(0xFFD4D4D4),
    secondaryText: Color(0xFFBDBDBD),
    mutedText: Color(0xFF858585),
    disabledText: Color(0xFF5F5F5F),
    lineNumber: Color(0xFF6E7681),
    markdownIcon: Color(0xFFD7BA7D),
    codeText: Color(0xFFDCDCAA),
    inlineCodeBackground: Color(0xFF3A3324),
    codeBlockBackground: Color(0xFF252526),
    link: Color(0xFF4FC1FF),
    error: Color(0xFFF48771),
    danger: Color(0xFFFF5F57),
  );

  static const lightMode = EditorThemeColors(
    background: Color(0xFFF5F5F5),
    titleBar: Color(0xFFEDEDED),
    activityRail: Color(0xFFE3E3E3),
    sidebar: Color(0xFFF0F0F0),
    tabBar: Color(0xFFE7E7E7),
    editor: Color(0xFFFFFFFF),
    preview: Color(0xFFFAFAFA),
    panelHeader: Color(0xFFF3F3F3),
    border: Color(0xFFD2D2D2),
    selection: Color(0xFFDDEEFF),
    accent: Color(0xFF007ACC),
    primaryText: Color(0xFF1F1F1F),
    secondaryText: Color(0xFF4F4F4F),
    mutedText: Color(0xFF7A7A7A),
    disabledText: Color(0xFF9C9C9C),
    lineNumber: Color(0xFF8C8C8C),
    markdownIcon: Color(0xFF8A6A1F),
    codeText: Color(0xFF7A3E00),
    inlineCodeBackground: Color(0xFFF2E8D8),
    codeBlockBackground: Color(0xFFF4F4F4),
    link: Color(0xFF005FB8),
    error: Color(0xFFC0392B),
    danger: Color(0xFFE74C3C),
  );

  final Color background;
  final Color titleBar;
  final Color activityRail;
  final Color sidebar;
  final Color tabBar;
  final Color editor;
  final Color preview;
  final Color panelHeader;
  final Color border;
  final Color selection;
  final Color accent;
  final Color primaryText;
  final Color secondaryText;
  final Color mutedText;
  final Color disabledText;
  final Color lineNumber;
  final Color markdownIcon;
  final Color codeText;
  final Color inlineCodeBackground;
  final Color codeBlockBackground;
  final Color link;
  final Color error;
  final Color danger;

  @override
  EditorThemeColors copyWith({
    Color? background,
    Color? titleBar,
    Color? activityRail,
    Color? sidebar,
    Color? tabBar,
    Color? editor,
    Color? preview,
    Color? panelHeader,
    Color? border,
    Color? selection,
    Color? accent,
    Color? primaryText,
    Color? secondaryText,
    Color? mutedText,
    Color? disabledText,
    Color? lineNumber,
    Color? markdownIcon,
    Color? codeText,
    Color? inlineCodeBackground,
    Color? codeBlockBackground,
    Color? link,
    Color? error,
    Color? danger,
  }) {
    return EditorThemeColors(
      background: background ?? this.background,
      titleBar: titleBar ?? this.titleBar,
      activityRail: activityRail ?? this.activityRail,
      sidebar: sidebar ?? this.sidebar,
      tabBar: tabBar ?? this.tabBar,
      editor: editor ?? this.editor,
      preview: preview ?? this.preview,
      panelHeader: panelHeader ?? this.panelHeader,
      border: border ?? this.border,
      selection: selection ?? this.selection,
      accent: accent ?? this.accent,
      primaryText: primaryText ?? this.primaryText,
      secondaryText: secondaryText ?? this.secondaryText,
      mutedText: mutedText ?? this.mutedText,
      disabledText: disabledText ?? this.disabledText,
      lineNumber: lineNumber ?? this.lineNumber,
      markdownIcon: markdownIcon ?? this.markdownIcon,
      codeText: codeText ?? this.codeText,
      inlineCodeBackground: inlineCodeBackground ?? this.inlineCodeBackground,
      codeBlockBackground: codeBlockBackground ?? this.codeBlockBackground,
      link: link ?? this.link,
      error: error ?? this.error,
      danger: danger ?? this.danger,
    );
  }

  @override
  EditorThemeColors lerp(ThemeExtension<EditorThemeColors>? other, double t) {
    if (other is! EditorThemeColors) {
      return this;
    }

    return EditorThemeColors(
      background: Color.lerp(background, other.background, t)!,
      titleBar: Color.lerp(titleBar, other.titleBar, t)!,
      activityRail: Color.lerp(activityRail, other.activityRail, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      tabBar: Color.lerp(tabBar, other.tabBar, t)!,
      editor: Color.lerp(editor, other.editor, t)!,
      preview: Color.lerp(preview, other.preview, t)!,
      panelHeader: Color.lerp(panelHeader, other.panelHeader, t)!,
      border: Color.lerp(border, other.border, t)!,
      selection: Color.lerp(selection, other.selection, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      primaryText: Color.lerp(primaryText, other.primaryText, t)!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
      mutedText: Color.lerp(mutedText, other.mutedText, t)!,
      disabledText: Color.lerp(disabledText, other.disabledText, t)!,
      lineNumber: Color.lerp(lineNumber, other.lineNumber, t)!,
      markdownIcon: Color.lerp(markdownIcon, other.markdownIcon, t)!,
      codeText: Color.lerp(codeText, other.codeText, t)!,
      inlineCodeBackground:
          Color.lerp(inlineCodeBackground, other.inlineCodeBackground, t)!,
      codeBlockBackground:
          Color.lerp(codeBlockBackground, other.codeBlockBackground, t)!,
      link: Color.lerp(link, other.link, t)!,
      error: Color.lerp(error, other.error, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

extension EditorThemeContext on BuildContext {
  EditorThemeColors get editorColors =>
      Theme.of(this).extension<EditorThemeColors>()!;
}
