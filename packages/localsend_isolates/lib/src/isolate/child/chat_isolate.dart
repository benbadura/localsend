import 'dart:convert';

import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/rust/api/chat.dart' as rust;
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/child/sync_provider.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:typed_isolates/typed_isolates.dart';

sealed class ChatTask {}

class ChatOpenTask extends ChatTask {
  final String path;
  ChatOpenTask(this.path);
}

class ChatStoreTask extends ChatTask {
  final Map<String, Object?> command;
  ChatStoreTask(this.command);
  @override
  String toString() => 'ChatStoreTask(${command['op']})';
}

class ChatNetworkTask extends ChatTask {
  final Device target;
  final String operation;
  final Map<String, Object?>? message;
  final String? messageId;
  ChatNetworkTask({required this.target, required this.operation, this.message, this.messageId});
  @override
  String toString() => 'ChatNetworkTask($operation)';
}

class ChatResult {
  final Object? value;
  ChatResult(this.value);
  @override
  String toString() => 'ChatResult(<redacted>)';
}

Future<void> setupChatIsolate(
  Stream<SendToIsolateData<IsolateTask<ChatTask>>> receiveFromMain,
  void Function(IsolateTaskStreamResult<ChatResult>) sendToMain,
  InitialData initialData,
) async {
  rust.RsChatStore? store;
  await setupChildIsolateHelper(
    debugLabel: 'ChatIsolate',
    receiveFromMain: receiveFromMain,
    sendToMain: sendToMain,
    initialData: initialData,
    handler: (ref, task) async {
      try {
        Object? value;
        switch (task.data) {
          case ChatOpenTask(:final path):
            store = await rust.openChatStore(path: path);
            value = true;
          case ChatStoreTask(:final command):
            if (store == null) throw StateError('Chat storage unavailable');
            value = jsonDecode(await store!.execute(command: jsonEncode(command)));
          case ChatNetworkTask(:final target, :final operation, :final message, :final messageId):
            if (!target.https || target.ip == null) throw StateError('Chat requires a LAN HTTPS channel');
            final sync = ref.read(syncProvider);
            final payload = message == null
                ? messageId ?? ''
                : jsonEncode({
                    ...message,
                    'info': {
                      'alias': sync.alias,
                      'version': '2.2',
                      'fingerprint': sync.securityContext.certificateHash,
                      'port': sync.port,
                      'protocol': 'https',
                      'download': false,
                    },
                  });
            value = jsonDecode(
              await rust.chatRequest(
                privateKey: sync.securityContext.privateKey,
                cert: sync.securityContext.certificate,
                fingerprint: target.fingerprint,
                host: target.ip!,
                port: target.port,
                operation: operation,
                payload: payload,
              ),
            );
        }
        sendToMain(IsolateTaskStreamResult.event(id: task.id, data: ChatResult(value)));
        sendToMain(IsolateTaskStreamResult.done(id: task.id));
      } catch (_) {
        // Send only a fixed error: input and native exceptions can contain private data.
        sendToMain(IsolateTaskStreamResult.error(id: task.id, error: 'Chat operation failed'));
      }
    },
  );
}
