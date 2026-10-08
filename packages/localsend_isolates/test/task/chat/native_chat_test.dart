@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/chat.dart';
import 'package:localsend_isolates/rust/api/crypto.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';

void main() {
  test('native Dart bridge delivers, stores, deduplicates, searches and deletes chat', () async {
    final name = Platform.isWindows
        ? 'rust_lib_localsend_app.dll'
        : Platform.isMacOS
        ? 'librust_lib_localsend_app.dylib'
        : 'librust_lib_localsend_app.so';
    final library = File(Platform.environment['LOCALSEND_CHAT_TEST_LIBRARY'] ?? '${Directory.current.path}/../../target/debug/$name');
    if (!library.existsSync()) {
      markTestSkipped('Build the Rust plugin or set LOCALSEND_CHAT_TEST_LIBRARY to the built library');
      return;
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
    final sender = await generateSecurityContext();
    final receiver = await generateSecurityContext();
    final directory = await Directory.systemTemp.createTemp('localsend_chat_bridge_');
    final store = await openChatStore(path: '${directory.path}/chat.sqlite3');
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final server = await startServer(
      port: port,
      tls: TlsConfig(cert: receiver.certificate, privateKey: receiver.privateKey),
      alias: 'Receiver',
      version: '2.2',
      fingerprint: receiver.certificateHash,
      verifyChecksums: true,
      chatEnabled: true,
      web: const WebParams(
        mode: WebMode.disabled(),
        i18N: WebI18n(
          waiting: '',
          enterPin: '',
          invalidPin: '',
          tooManyAttempts: '',
          rejected: '',
          uploadRejected: '',
          busy: '',
          files: '',
          fileName: '',
          size: '',
          dropHint: '',
        ),
        pages: WebPages(),
      ),
    );
    Future<dynamic> db(Map<String, Object?> command) async => jsonDecode(await store.execute(command: jsonEncode(command)));
    final errors = <Object>[];
    final events = server.listen().listen((event) async {
      try {
        switch (event) {
          case RsServerEvent_ChatMessage(:final requestId, :final fingerprint, :final info, :final messageId, :final text, :final ttlSeconds):
            final receipt = await db({
              'op': 'receive',
              'peer': fingerprint,
              'alias': info.alias,
              'id': messageId,
              'text': text,
              'ttl': ttlSeconds,
              'approved': true,
            });
            await server.respondChat(requestId: requestId, status: 200, receiptJson: jsonEncode(receipt));
          case RsServerEvent_ChatStatus(:final requestId, :final fingerprint, :final messageId):
            final receipt = await db({'op': 'receipt', 'peer': fingerprint, 'id': messageId});
            await server.respondChat(
              requestId: requestId,
              status: receipt == null ? 404 : 200,
              receiptJson: receipt == null ? null : jsonEncode(receipt),
            );
          default:
            break;
        }
      } catch (error) {
        errors.add(error);
      }
    });
    try {
      Future<Map> request(String operation, String payload) async =>
          jsonDecode(
                await chatRequest(
                  privateKey: sender.privateKey,
                  cert: sender.certificate,
                  fingerprint: receiver.certificateHash,
                  host: '127.0.0.1',
                  port: port,
                  operation: operation,
                  payload: payload,
                ),
              )
              as Map;
      const id = '02c81f9a-2d1b-4a6b-b12a-d4e07b4234a8';
      final payload = jsonEncode({
        'messageId': id,
        'text': 'Zażółć\n🦀',
        'ttlSeconds': 300,
        'info': {'alias': 'Sender', 'version': '2.2', 'fingerprint': sender.certificateHash, 'port': port, 'protocol': 'https'},
      });
      expect((await request('info', ''))['value']['version'], 1);
      final first = await request('send', payload);
      expect(first['ok'], isTrue);
      expect((await request('send', payload))['value']['deliveredAtMs'], first['value']['deliveredAtMs']);
      expect((await request('status', id))['value']['messageId'], id);
      final messages = await db({'op': 'messages', 'peer': sender.certificateHash, 'before': null, 'search': 'ZAŻÓŁĆ'}) as List;
      expect(messages, hasLength(1));
      expect(messages.single['text'], 'Zażółć\n🦀');
      await db({'op': 'delete', 'peer': sender.certificateHash, 'id': id});
      expect((await request('send', payload))['value']['status'], 'deleted');
      expect(await db({'op': 'messages', 'peer': sender.certificateHash, 'before': null, 'search': ''}), isEmpty);
      expect(errors, isEmpty);
    } finally {
      await server.stop();
      // The native server handle retains its event channel after stop.
      unawaited(events.cancel());
      store.dispose();
      await directory.delete(recursive: true);
    }
  });
}
