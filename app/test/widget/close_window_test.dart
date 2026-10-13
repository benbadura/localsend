import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/animation_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/window_dimensions_provider.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/widget/dialogs/close_window_dialog.dart';
import 'package:localsend_app/widget/watcher/window_watcher.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../mocks.mocks.dart';

void main() {
  const windowChannel = MethodChannel('window_manager');
  const trayChannel = MethodChannel('tray_manager');
  late RefenaContainer container;
  late _DimensionsController dimensions;
  late List<String> nativeCalls;
  late BuildContext contentContext;

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.pl);
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    nativeCalls = [];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      nativeCalls.add('window.${call.method}');
      if (call.method == 'getBounds') return {'x': 120.0, 'y': 80.0, 'width': 900.0, 'height': 600.0};
      if (call.method == 'isMinimized') return false;
      return null;
    });
    messenger.setMockMethodCallHandler(trayChannel, (call) async {
      nativeCalls.add('tray.${call.method}');
      return null;
    });
  });

  tearDown(() {
    container.disposeContainer();
    LocaleSettings.setLocaleSync(AppLocale.en);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, null);
    messenger.setMockMethodCallHandler(trayChannel, null);
  });

  Future<void> mount(WidgetTester tester, TargetPlatform platform, {bool minimizeToTray = false}) async {
    final persistence = _Persistence();
    when(persistence.isMinimizeToTray()).thenReturn(minimizeToTray);
    dimensions = _DimensionsController();
    container = RefenaContainer(
      overrides: [
        windowDimensionProvider.overrideWithValue(dimensions),
        settingsProvider.overrideWithNotifier((_) => SettingsService(persistence)),
      ],
    );
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: WindowWatcher(
          child: MaterialApp(
            navigatorKey: container.read(navigationProvider).key,
            theme: ThemeData(platform: platform),
            locale: LocaleSettings.currentLocale.flutterLocale,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: Builder(
              builder: (context) {
                contentContext = context;
                return const Scaffold(body: Text('LocalSend'));
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(nativeCalls, platform == TargetPlatform.android ? isEmpty : contains('window.setPreventClose'));
    nativeCalls.clear();
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    testWidgets('$platform cancel leaves the window open and allows another close attempt', (tester) async {
      await mount(tester, platform, minimizeToTray: true);
      final closing = WindowWatcher.closeWindow(contentContext);
      await tester.pumpAndSettle();
      expect(find.byType(CloseWindowDialog), findsOneWidget);
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      await closing;
      expect(nativeCalls, isEmpty);
      expect(dimensions.saved, isEmpty);

      final retry = WindowWatcher.closeWindow(contentContext);
      await tester.pumpAndSettle();
      expect(find.byType(CloseWindowDialog), findsOneWidget);
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      await retry;
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(platform));

    testWidgets('$platform hide keeps the app alive and can be restored from the tray', (tester) async {
      await mount(tester, platform);
      final closing = WindowWatcher.closeWindow(contentContext);
      await tester.pumpAndSettle();
      final hideLabel = platform == TargetPlatform.macOS ? t.dialogs.closeWindow.minimizeToMenuBar : t.dialogs.closeWindow.minimizeToTray;
      await tester.tap(find.text(hideLabel));
      await tester.pumpAndSettle();
      await closing;
      expect(nativeCalls, ['window.getBounds', 'window.getBounds', 'window.hide', if (platform == TargetPlatform.macOS) 'window.setSkipTaskbar']);
      expect(dimensions.saved.single.position, const Offset(120, 80));
      expect(dimensions.saved.single.size, const Size(900, 600));
      expect(container.read(sleepProvider), isTrue);

      await showFromTray();
      expect(nativeCalls, containsAllInOrder(['window.show', 'window.focus', if (platform == TargetPlatform.macOS) 'window.setSkipTaskbar']));
      expect(container.read(sleepProvider), isFalse);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(platform));

    testWidgets('$platform quit destroys the tray and exits even with the legacy minimize setting enabled', (tester) async {
      await mount(tester, platform, minimizeToTray: true);
      final exitCodes = <int>[];
      final closing = IOOverrides.runZoned(
        () => WindowWatcher.closeWindow(contentContext),
        exit: (code) {
          exitCodes.add(code);
          throw const _ExitRequested();
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.tray.close));
      await tester.pumpAndSettle();
      await closing;
      expect(exitCodes, [0]);
      expect(nativeCalls, ['window.getBounds', 'window.getBounds', 'tray.destroy']);
      expect(dimensions.saved, hasLength(1));
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(platform));

    testWidgets('$platform repeated native close events open only one dialog', (tester) async {
      await mount(tester, platform);
      windowManager.listeners.single.onWindowClose();
      windowManager.listeners.single.onWindowClose();
      await tester.pumpAndSettle();
      expect(find.byType(CloseWindowDialog), findsOneWidget);
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      expect(find.byType(CloseWindowDialog), findsNothing);
      expect(nativeCalls, isEmpty);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(platform));

    testWidgets('$platform Polish close dialog fits the minimum window size', (tester) async {
      LocaleSettings.setLocaleSync(AppLocale.pl);
      tester.view.physicalSize = const Size(400, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, platform);
      final closing = WindowWatcher.closeWindow(contentContext);
      await tester.pumpAndSettle();
      expect(find.text('Zamknąć LocalSend?'), findsOneWidget);
      expect(find.text(platform == TargetPlatform.macOS ? 'Ukryj na pasku menu' : 'Ukryj w trayu'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      await closing;
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('Escape dismisses the close prompt without hiding or quitting', (tester) async {
    await mount(tester, TargetPlatform.windows);
    final closing = WindowWatcher.closeWindow(contentContext);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await closing;
    expect(find.byType(CloseWindowDialog), findsNothing);
    expect(nativeCalls, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Linux retains automatic minimize when enabled', (tester) async {
    await mount(tester, TargetPlatform.linux, minimizeToTray: true);
    await WindowWatcher.closeWindow(contentContext);
    await tester.pumpAndSettle();
    expect(find.byType(CloseWindowDialog), findsNothing);
    expect(nativeCalls, ['window.getBounds', 'window.getBounds', 'window.hide']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Linux retains automatic quit when minimize is disabled', (tester) async {
    await mount(tester, TargetPlatform.linux);
    final exitCodes = <int>[];
    await IOOverrides.runZoned(
      () => WindowWatcher.closeWindow(contentContext),
      exit: (code) {
        exitCodes.add(code);
        throw const _ExitRequested();
      },
    );
    expect(find.byType(CloseWindowDialog), findsNothing);
    expect(exitCodes, [0]);
    expect(nativeCalls, ['window.getBounds', 'window.getBounds']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('mobile ignores desktop window close actions', (tester) async {
    await mount(tester, TargetPlatform.android);
    await WindowWatcher.closeWindow(contentContext);
    await tester.pumpAndSettle();
    expect(find.byType(CloseWindowDialog), findsNothing);
    expect(nativeCalls, isEmpty);
    expect(dimensions.saved, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

class _DimensionsController extends WindowDimensionsController {
  _DimensionsController() : super(MockPersistenceService());

  final saved = <WindowDimensions>[];

  @override
  Future<void> storeDimensions({required Offset windowOffset, required Size windowSize}) async {
    saved.add(WindowDimensions(position: windowOffset, size: windowSize));
  }
}

class _ExitRequested implements Exception {
  const _ExitRequested();
}

class _Persistence extends MockPersistenceService {
  @override
  bool getAlwaysOnTop() => false;
}
