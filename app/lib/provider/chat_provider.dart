import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/chat.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uuid/uuid.dart';

final chatProvider = ReduxProvider<ChatService, ChatState>((ref) => ChatService(ref));

class ChatService extends ReduxNotifier<ChatState> {
  final Ref _ref;
  ChatService(this._ref);
  Timer? _timer;
  bool _refreshing = false;
  bool _asking = false;
  final Set<String> _pending = {};
  final Set<String> _sending = {};
  final Map<String, void Function()> _cancelConsent = {};
  @override
  ChatState init() => const ChatState();
  @override
  String describeState(ChatState state) => state.toString();
  @override
  void dispose() {
    _timer?.cancel();
    for (final cancel in _cancelConsent.values.toList()) {
      cancel();
    }
    super.dispose();
  }

  Future<Object?> call(ChatTask task) => _ref.redux(parentIsolateProvider).dispatchAsyncTakeResult(IsolateChatAction(task));
  Future<dynamic> db(Map<String, Object?> command) => call(ChatStoreTask(command));
  void reply(String requestId, int status, [Object? receipt]) {
    _ref
        .redux(parentIsolateProvider)
        .dispatch(IsolateChatReplyAction(requestId: requestId, status: status, receiptJson: receipt == null ? null : jsonEncode(receipt)));
  }

  Future<bool> consent(String requestId, String alias) async {
    if (_asking) return false;
    _asking = true;
    final answer = Completer<bool>();
    DialogRoute<bool>? dialogRoute;
    NavigatorState? dialogNavigator;
    void finish(bool accepted) {
      if (!answer.isCompleted) answer.complete(accepted);
      final route = dialogRoute;
      final navigator = dialogNavigator;
      if (route != null && route.isActive && navigator != null && navigator.mounted) {
        navigator.removeRoute(route);
      }
    }

    _cancelConsent[requestId] = () => finish(false);
    final timeout = Timer(const Duration(seconds: 115), () => finish(false));
    try {
      if (checkPlatformHasTray()) await showFromTray();
      if (!_pending.contains(requestId)) return false;
      final context = Routerino.context;
      if (!context.mounted) return false;
      dialogNavigator = Navigator.of(context);
      dialogRoute = DialogRoute<bool>(
        context: context,
        builder: (_) {
          return AlertDialog(
            title: Text(t.chat.contactRequest),
            content: Text(t.chat.contactRequestBody(alias: alias)),
            actions: [
              TextButton(onPressed: () => finish(false), child: Text(t.general.decline)),
              FilledButton(onPressed: () => finish(true), child: Text(t.general.accept)),
            ],
          );
        },
      );
      unawaited(
        dialogNavigator.push(dialogRoute).then((_) {
          if (!answer.isCompleted) answer.complete(false);
        }),
      );
      return await answer.future;
    } finally {
      timeout.cancel();
      _cancelConsent.remove(requestId);
      _asking = false;
    }
  }
}

class InitChatAction extends AsyncReduxAction<ChatService, ChatState> {
  final String path;
  InitChatAction(this.path);
  @override
  Future<ChatState> reduce() async {
    try {
      await notifier.call(ChatOpenTask(path));
      notifier._timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(notifier.redux.dispatchAsync(RefreshChatAction()));
      });
      return state.copyWith(ready: true, clearError: true);
    } catch (_) {
      return state.copyWith(error: t.chat.storageError);
    }
  }
}

class RefreshChatAction extends AsyncReduxAction<ChatService, ChatState> {
  @override
  Future<ChatState> reduce() async {
    if (!state.ready || notifier._refreshing) return state;
    notifier._refreshing = true;
    final peer = state.peer;
    final search = state.search;
    final limit = state.limit;
    try {
      await notifier.db({'op': 'purge'});
      if (peer != null && state.visible) await notifier.db({'op': 'read', 'peer': peer});
      final conversations = (await notifier.db({'op': 'conversations'}) as List)
          .map((v) => ChatConversation.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
      final messages = <ChatMessage>[];
      bool more = false;
      if (peer != null) {
        int? before;
        do {
          final page = (await notifier.db({'op': 'messages', 'peer': peer, 'before': before, 'search': search}) as List)
              .map((v) => ChatMessage.fromJson(Map<String, dynamic>.from(v as Map)))
              .toList();
          messages.addAll(page);
          more = page.length == 50;
          before = page.lastOrNull?.seq;
        } while (more && messages.length < limit);
      }
      if (peer != state.peer || search != state.search) return state.copyWith(conversations: conversations);
      return state.copyWith(conversations: conversations, messages: messages, hasMore: more);
    } catch (_) {
      return state.copyWith(error: t.chat.storageError);
    } finally {
      notifier._refreshing = false;
    }
  }
}

class SelectChatAction extends ReduxAction<ChatService, ChatState> {
  final String? peer;
  final String alias;
  SelectChatAction({this.peer, this.alias = ''});
  @override
  ChatState reduce() =>
      state.copyWith(peer: peer, close: peer == null, alias: alias, messages: [], search: '', limit: 50, hasMore: false, clearError: true);
  @override
  void after() {
    unawaited(notifier.redux.dispatchAsync(RefreshChatAction()));
  }
}

class ChatVisibilityAction extends ReduxAction<ChatService, ChatState> {
  final bool visible;
  ChatVisibilityAction(this.visible);
  @override
  ChatState reduce() => state.copyWith(visible: visible);
}

class ChatSearchAction extends ReduxAction<ChatService, ChatState> {
  final String search;
  final bool more;
  ChatSearchAction(this.search, {this.more = false});
  @override
  ChatState reduce() => state.copyWith(search: search, limit: more ? state.limit + 50 : 50, messages: more ? state.messages : []);
  @override
  void after() {
    unawaited(notifier.redux.dispatchAsync(RefreshChatAction()));
  }
}

class ChatEditHistoryAction extends AsyncReduxAction<ChatService, ChatState> {
  final String peer;
  final String? id;
  final bool revoke;
  ChatEditHistoryAction({required this.peer, this.id, this.revoke = false});
  @override
  Future<ChatState> reduce() async {
    try {
      await notifier.db(revoke ? {'op': 'trust', 'peer': peer, 'value': false} : {'op': 'delete', 'peer': peer, 'id': id});
      await dispatchAsync(RefreshChatAction());
      return state;
    } catch (_) {
      return state.copyWith(error: t.chat.storageError);
    }
  }
}

class ChatRequestEndedAction extends ReduxAction<ChatService, ChatState> {
  final String requestId;
  ChatRequestEndedAction(this.requestId);
  @override
  ChatState reduce() {
    notifier._pending.remove(requestId);
    notifier._cancelConsent[requestId]?.call();
    return state;
  }
}

class ReceiveChatAction extends AsyncReduxAction<ChatService, ChatState> {
  final HttpServerChatEvent event;
  ReceiveChatAction(this.event);
  @override
  Future<ChatState> reduce() async {
    notifier._pending.add(event.requestId);
    try {
      final receipt = await notifier.db({'op': 'receipt', 'peer': event.fingerprint, 'id': event.messageId});
      if (event.text == null || receipt != null) {
        notifier.reply(event.requestId, receipt == null ? 404 : 200, receipt);
        return state;
      }
      final trusted = await notifier.db({'op': 'trusted', 'peer': event.fingerprint}) as bool;
      bool approved = false;
      if (!trusted) approved = await notifier.consent(event.requestId, event.alias ?? event.fingerprint);
      if (!notifier._pending.contains(event.requestId)) return state;
      if (!trusted && !approved) {
        notifier.reply(event.requestId, 403);
        return state;
      }
      final saved = await notifier.db({
        'op': 'receive',
        'peer': event.fingerprint,
        'alias': event.alias ?? '',
        'id': event.messageId,
        'text': event.text,
        'ttl': event.ttlSeconds,
        'approved': approved,
      });
      notifier.reply(event.requestId, 200, saved);
      await dispatchAsync(RefreshChatAction());
      return state;
    } catch (_) {
      notifier.reply(event.requestId, 503);
      return state.copyWith(error: t.chat.storageError);
    } finally {
      notifier._pending.remove(event.requestId);
    }
  }
}

class SendChatAction extends AsyncReduxAction<ChatService, ChatState> {
  final String text;
  final int? ttl;
  final String? messageId;
  SendChatAction({required this.text, this.ttl, this.messageId});
  @override
  Future<ChatState> reduce() async {
    final peer = state.peer;
    if (!state.ready || peer == null || text.trim().isEmpty) return state;
    if (utf8.encode(text).length > 65536) return state.copyWith(error: t.chat.tooLong);
    final id = messageId ?? const Uuid().v4();
    if (!notifier._sending.add(id)) return state;
    try {
      if (messageId == null) await notifier.db({'op': 'create', 'peer': peer, 'alias': state.alias, 'id': id, 'text': text, 'ttl': ttl});
      final target = notifier._ref
          .read(nearbyDevicesProvider)
          .allDevices
          .values
          .firstWhereOrNull((d) => d.fingerprint == peer && d.ip != null && d.https);
      if (!notifier._ref.read(settingsProvider).https || target == null) return state.copyWith(error: t.chat.offline);
      Future<Map> request(String operation, {Map<String, Object?>? message}) async =>
          (await notifier.call(ChatNetworkTask(target: target, operation: operation, messageId: id, message: message))) as Map;
      final info = await request('info');
      if (info['ok'] != true || (info['value'] as Map?)?['version'] != 1) return state.copyWith(error: t.chat.unavailable);
      if (messageId != null) {
        final existing = await request('status');
        if (existing['ok'] != true) return state.copyWith(error: t.chat.unconfirmed);
        if (existing['value'] != null) {
          await notifier.db({'op': 'confirm', 'peer': peer, 'id': id, 'receipt': existing['value']});
          return state.copyWith(clearError: true);
        }
      }
      await notifier.db({'op': 'trust', 'peer': peer, 'value': true});
      await notifier.db({'op': 'attempt', 'peer': peer, 'id': id});
      await dispatchAsync(RefreshChatAction());
      final result = await request('send', message: {'messageId': id, 'text': text, 'ttlSeconds': ttl});
      if (result['ok'] == true) {
        await notifier.db({'op': 'confirm', 'peer': peer, 'id': id, 'receipt': result['value']});
        return state.copyWith(clearError: true);
      }
      // A lost response/timeout/5xx can follow a committed receive transaction.
      final code = result['status'] as int?;
      final uncertain = code == null || code == 408 || code >= 500;
      if (uncertain) {
        final status = await request('status');
        if (status['ok'] == true && status['value'] != null) {
          await notifier.db({'op': 'confirm', 'peer': peer, 'id': id, 'receipt': status['value']});
          return state.copyWith(clearError: true);
        }
      }
      await notifier.db({
        'op': 'status',
        'peer': peer,
        'id': id,
        'status': uncertain
            ? 'unconfirmed'
            : code == 403
            ? 'declined'
            : 'failed',
      });
      return state.copyWith(
        error: uncertain
            ? t.chat.unconfirmed
            : code == 403
            ? t.chat.declined
            : t.chat.sendError,
      );
    } catch (_) {
      // Preserve a provisional expiry when an earlier attempt may have arrived.
      try {
        await notifier.db({'op': 'status', 'peer': peer, 'id': id, 'status': 'unconfirmed'});
      } catch (_) {}
      return state.copyWith(error: t.chat.unconfirmed);
    } finally {
      notifier._sending.remove(id);
      unawaited(notifier.redux.dispatchAsync(RefreshChatAction()));
    }
  }
}

class DismissChatErrorAction extends ReduxAction<ChatService, ChatState> {
  @override
  ChatState reduce() => state.copyWith(clearError: true);
}

/// Persist the draft before clearing the composer, then send it asynchronously.
class ComposeChatAction extends AsyncReduxActionWithResult<ChatService, ChatState, bool> {
  final String text;
  final int? ttl;
  ComposeChatAction({required this.text, this.ttl});
  @override
  Future<(ChatState, bool)> reduce() async {
    final peer = state.peer;
    if (!state.ready || peer == null || text.trim().isEmpty) return (state, false);
    if (utf8.encode(text).length > 65536) return (state.copyWith(error: t.chat.tooLong), false);
    try {
      final id = const Uuid().v4();
      await notifier.db({'op': 'create', 'peer': peer, 'alias': state.alias, 'id': id, 'text': text, 'ttl': ttl});
      if (state.peer == peer) {
        unawaited(dispatchAsync(SendChatAction(text: text, ttl: ttl, messageId: id)));
      }
      unawaited(dispatchAsync(RefreshChatAction()));
      return (state, true);
    } catch (_) {
      return (state.copyWith(error: t.chat.storageError), false);
    }
  }
}
