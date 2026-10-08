# Chat in this fork

Open **Messages**, start a conversation, and select a nearby HTTPS device. Both devices must run this fork with encryption enabled. The receiver approves the first contact; later messages from the same certificate are accepted automatically. The conversation menu can revoke this permission.

Sent and received messages are kept locally across restarts. Search applies to the selected conversation; older messages load in pages of 50. Deleting a message or clearing history affects this device's copy. Devices that are offline or do not support chat produce an error; **Retry** is manual and checks the receiver before retransmitting.

Choose **Off**, **5 minutes**, **1 hour**, **24 hours**, or **7 days** before sending. The countdown begins when the receiver commits the message to its database. An uncertain delivery uses a provisional local expiry. Expired text and search data are removed, while a receipt without text prevents duplicate or late deliveries from restoring the message.

The local `messages.sqlite` database lives in the application support directory, or next to portable settings. It is not encrypted at rest. Expiration is enforced while the application runs and on startup/resume; an application that is shut down cannot erase its database until it next starts. Copies exported outside the application are unaffected.

Chat uses certificate-authenticated, pinned HTTPS under `/api/localsend/chat/v1` and is independent of file transfer sessions. It does not use WebRTC, the browser interface, or the CLI. Existing text transfers remain in the original receive history.

Validation commands:

```text
cargo test -p rust_lib_localsend_app
cargo test -p localsend --features full
cd app
fvm flutter analyze
fvm flutter test
fvm flutter build windows --debug
```

`packages/localsend_isolates/test/task/chat/native_chat_test.dart` also exercises the actual Dart/Rust bridge, TLS client, event responses, and SQLite. Build the plugin first; set `LOCALSEND_CHAT_TEST_LIBRARY` to its native library path when it is outside `target/debug`.
