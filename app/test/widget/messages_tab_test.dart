import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/chat.dart';
import 'package:localsend_app/pages/tabs/messages_tab.dart';
import 'package:localsend_app/provider/chat_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:system_date_time_format/system_date_time_format.dart';

import '../mocks.mocks.dart';

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.pl);
    LocaleSettings.setLocaleSync(AppLocale.en);
  });
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));
  Future<void> mount(WidgetTester tester, Size size, {bool https = true}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('system_date_time_format'), (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('system_date_time_format'), null));
    final persistence = _Persistence();
    when(persistence.isHttps()).thenReturn(https);
    final conversation = ChatConversation.fromJson({'peer': 'A', 'alias': 'Alice', 'trusted': true, 'unread': 0, 'timestamp': 1});
    final message = ChatMessage.fromJson({
      'seq': 1,
      'id': 'id',
      'text': 'Zażółć\n🦀',
      'outgoing': false,
      'timestamp': 1,
      'expires': null,
      'ttl': null,
      'status': 'delivered',
    });
    await tester.pumpWidget(
      RefenaScope(
        overrides: [
          chatProvider.overrideWithInitialState(
            notifier: (ref) => _Chat(ref),
            initialState: ChatState(ready: true, peer: 'A', alias: 'Alice', conversations: [conversation], messages: [message]),
          ),
          settingsProvider.overrideWithNotifier((_) => SettingsService(persistence)),
          nearbyDevicesProvider.overrideWithInitialState(
            notifier: (_) => NearbyDevicesService(
              isolateController: IsolateController(initialState: _ParentState()),
              favoriteService: FavoritesService(persistence),
              discoveryLogs: DiscoveryLogger(),
            ),
            initialState: null,
          ),
        ],
        child: SDTFScope(
          child: MaterialApp(
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const [Locale('en')],
            home: const Scaffold(body: MessagesTab()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('desktop shows history alongside the selected conversation', (tester) async {
    await mount(tester, const Size(1100, 800));
    expect(find.text('Alice'), findsNWidgets(2));
    expect(find.text('Zażółć\n🦀'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small phone renders the conversation and retains a failed draft', (tester) async {
    await mount(tester, const Size(320, 640));
    expect(find.text('Alice'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Keep this draft');
    await tester.pump();
    await tester.tap(find.byTooltip(t.chat.send));
    await tester.pumpAndSettle();
    expect(find.text('Keep this draft'), findsOneWidget);
    expect(find.text(t.chat.storageError), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disappearing durations are selectable and HTTP disables send', (tester) async {
    await mount(tester, const Size(390, 800), https: false);
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    expect(find.text(t.chat.fiveMinutes), findsOneWidget);
    expect(find.text(t.chat.oneHour), findsOneWidget);
    expect(find.text(t.chat.oneDay), findsOneWidget);
    expect(find.text(t.chat.oneWeek), findsOneWidget);
    await tester.tap(find.text(t.chat.fiveMinutes));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Message');
    final button = tester.widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == t.chat.send));
    expect(button.onPressed, isNull);
    expect(find.text(t.chat.requiresHttps), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Polish copy and composer fit a small phone', (tester) async {
    LocaleSettings.setLocaleSync(AppLocale.pl);
    await mount(tester, const Size(320, 640));
    expect(t.chat.title, 'Wiadomości');
    expect(t.chat.writeMessage, 'Napisz wiadomość');
    expect(find.text('Znikanie po dostarczeniu'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _ParentState extends Fake implements ParentIsolateState {}

class _Chat extends ChatService {
  _Chat(super.ref);
  @override
  Future<dynamic> db(Map<String, Object?> command) async => throw StateError('disk full');
}

class _Persistence extends MockPersistenceService {
  @override
  bool getAlwaysOnTop() => false;
}
