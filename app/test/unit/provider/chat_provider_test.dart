import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/chat.dart';
import 'package:localsend_app/provider/chat_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  late RefenaContainer container;
  late _Chat service;
  setUp(() {
    container = RefenaContainer();
    service = _Chat(container);
    ReduxNotifier.test(
      redux: service,
      initialState: const ChatState(ready: true, peer: 'A', alias: 'Alice', visible: true),
    );
  });
  tearDown(() {
    service.dispose();
    container.disposeContainer();
  });

  HttpServerChatEvent message() => HttpServerChatEvent(
    requestId: 'request',
    fingerprint: 'A',
    messageId: 'id',
    alias: 'Alice',
    text: 'Zażółć\n🦀',
    ttlSeconds: 300,
  );

  test('acknowledges only after the receive transaction completes', () async {
    final commit = Completer<Object?>();
    service.receive = () => commit.future;
    final action = service.redux.dispatchAsync(ReceiveChatAction(message()));
    await Future<void>.delayed(Duration.zero);
    expect(service.replies, isEmpty);
    expect(service.commands.last['op'], 'receive');
    expect(service.commands.last['approved'], isTrue);
    expect(service.commands.last['text'], 'Zażółć\n🦀');
    commit.complete({'messageId': 'id', 'status': 'delivered'});
    await action;
    expect(service.replies.single.$1, 200);
    expect(service.replies.single.$2, {'messageId': 'id', 'status': 'delivered'});
  });

  test('storage failure never produces a delivery receipt', () async {
    service.receive = () async => throw StateError('disk full');
    await service.redux.dispatchAsync(ReceiveChatAction(message()));
    expect(service.replies.single.$1, 503);
    expect(service.replies.single.$2, isNull);
    expect(service.state.error, t.chat.storageError);
  });

  test('replayed deleted messages return the receipt without another consent or save', () async {
    service.receipt = {'messageId': 'id', 'status': 'deleted'};
    await service.redux.dispatchAsync(ReceiveChatAction(message()));
    expect(service.replies.single.$1, 200);
    expect(service.replies.single.$2, service.receipt);
    expect(service.prompts, 0);
    expect(service.commands.map((c) => c['op']), ['receipt']);
  });

  test('a disconnected request cannot be accepted by a late dialog answer', () async {
    final consent = Completer<bool>();
    service.answer = () => consent.future;
    final action = service.redux.dispatchAsync(ReceiveChatAction(message()));
    await Future<void>.delayed(Duration.zero);
    service.redux.dispatch(ChatRequestEndedAction('request'));
    consent.complete(true);
    await action;
    expect(service.commands.any((c) => c['op'] == 'receive'), isFalse);
    expect(service.replies, isEmpty);
  });

  test('declining first contact stores no message', () async {
    service.answer = () async => false;
    await service.redux.dispatchAsync(ReceiveChatAction(message()));
    expect(service.replies.single.$1, 403);
    expect(service.commands.any((c) => c['op'] == 'receive'), isFalse);
  });

  test('composer preserves a draft when its durable save fails', () async {
    service.failCreate = true;
    final saved = await service.redux.dispatchAsyncTakeResult(ComposeChatAction(text: 'draft'));
    expect(saved, isFalse);
    expect(service.state.error, t.chat.storageError);
  });

  test('message length is checked in UTF-8 bytes before storage', () async {
    final saved = await service.redux.dispatchAsyncTakeResult(ComposeChatAction(text: '🦀' * 16385));
    expect(saved, isFalse);
    expect(service.state.error, t.chat.tooLong);
    expect(service.commands, isEmpty);
  });

  test('refresh removes expired text from visible state', () async {
    service.messages = [
      {'seq': 1, 'id': 'id', 'text': 'temporary secret', 'outgoing': false, 'timestamp': 1, 'expires': 2, 'ttl': 300, 'status': 'delivered'},
    ];
    await service.redux.dispatchAsync(RefreshChatAction());
    expect(service.state.messages.single.text, 'temporary secret');
    service.messages = [];
    await service.redux.dispatchAsync(RefreshChatAction());
    expect(service.state.messages, isEmpty);
    expect(service.commands.map((c) => c['op']), contains('purge'));
    expect(service.state.toString(), isNot(contains('temporary secret')));
  });
}

class _Chat extends ChatService {
  _Chat(super.ref);
  final commands = <Map<String, Object?>>[];
  final replies = <(int, Object?)>[];
  int prompts = 0;
  bool failCreate = false;
  Object? receipt;
  List<Map<String, Object?>> messages = [];
  Future<bool> Function() answer = () async => true;
  Future<Object?> Function() receive = () async => {'messageId': 'id', 'status': 'delivered'};
  @override
  Future<dynamic> db(Map<String, Object?> command) async {
    commands.add(command);
    return switch (command['op']) {
      'receipt' => receipt,
      'trusted' => false,
      'receive' => await receive(),
      'create' when failCreate => throw StateError('disk full'),
      'conversations' => [],
      'messages' => messages,
      _ => null,
    };
  }

  @override
  Future<bool> consent(String requestId, String alias) {
    prompts++;
    return answer();
  }

  @override
  void reply(String requestId, int status, [Object? receipt]) => replies.add((status, receipt));
}
