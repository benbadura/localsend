import 'package:localsend_app/provider/chat_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:refena_inspector_client/refena_inspector_client.dart';

final _logger = Logger('Refena');

class CustomRefenaObserver extends RefenaMultiObserver {
  CustomRefenaObserver()
    : super(
        observers: [
          RefenaDebugObserver(
            onLine: (line) => _logger.info(line),
            exclude: _exclude,
          ),
          RefenaTracingObserver(
            limit: 100,
            exclude: _exclude,
          ),
          RefenaInspectorObserver(),
        ],
      );
}

bool _exclude(RefenaEvent event) {
  return switch (event) {
    ChangeEvent() =>
      event.notifier is ChatService ||
          event.notifier is DiscoveryLogger ||
          event.notifier is LocalIpService ||
          event.notifier is FileTransferNotifier,
    ActionDispatchedEvent() =>
      event.notifier is ChatService || event.action is IsolateChatAction || event.action.runtimeType.toString() == '_FetchLocalIpAction',
    ActionFinishedEvent() =>
      event.action.notifier is ChatService || event.action is IsolateChatAction || event.action.runtimeType.toString() == '_FetchLocalIpAction',
    ActionErrorEvent() => event.action.notifier is ChatService || event.action is IsolateChatAction,
    _ => false,
  };
}
