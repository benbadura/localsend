//! Real TLS peers exercising the protocol against durable application storage.
use crate::chat_store::{ChatStore, now_ms};
use localsend::crypto::cert::{SelfSignedCert, generate_self_signed};
use localsend::http::chat::{ChatMessageRequest, ChatReceipt, ChatReply};
use localsend::http::client::LsHttpClientV2;
use localsend::http::dto_v2::{PrepareUploadRequestDtoV2, RegisterDtoV2};
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2};
use localsend::http::server::web::{WebConfig, WebMode};
use localsend::http::server::{ServerConfigV2, ServerHandle, TlsConfig, start_with_port};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::ProtocolType;
use localsend::model::transfer::FileDto;
use serde_json::json;
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot};

struct Peer {
    cert: SelfSignedCert,
    store: Arc<ChatStore>,
    handle: ServerHandle,
    stop: oneshot::Sender<()>,
    task: tokio::task::JoinHandle<()>,
}
impl Peer {
    async fn start() -> Self {
        let cert = generate_self_signed().unwrap();
        let store = Arc::new(ChatStore::open(":memory:").unwrap());
        let db = store.clone();
        let (tx, mut rx) = mpsc::channel(16);
        let task = tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                match event {
                    ServerEventV2::PrepareUpload {
                        files, decision_tx, ..
                    } => {
                        let _ = decision_tx.send(PrepareUploadDecisionV2::Accept(
                            files.keys().cloned().collect(),
                        ));
                    }
                    ServerEventV2::ChatMessage {
                        fingerprint,
                        message,
                        reply_tx,
                        ..
                    } => {
                        let result=db.command(&json!({"op":"receive","peer":fingerprint,"alias":message.info.alias,"id":message.message_id,"text":message.text,"ttl":message.ttl_seconds,"approved":true}).to_string());
                        let reply = match result {
                            Ok(v) => ChatReply {
                                status: 200,
                                receipt: Some(serde_json::from_str(&v).unwrap()),
                            },
                            Err(_) => ChatReply {
                                status: 503,
                                receipt: None,
                            },
                        };
                        let _ = reply_tx.send(reply);
                    }
                    ServerEventV2::ChatStatus {
                        fingerprint,
                        message_id,
                        reply_tx,
                        ..
                    } => {
                        let value = db
                            .command(
                                &json!({"op":"receipt","peer":fingerprint,"id":message_id})
                                    .to_string(),
                            )
                            .unwrap();
                        let receipt: Option<ChatReceipt> = serde_json::from_str(&value).unwrap();
                        let _ = reply_tx.send(ChatReply {
                            status: if receipt.is_some() { 200 } else { 404 },
                            receipt,
                        });
                    }
                    _ => {}
                }
            }
        });
        let (stop, stop_rx) = oneshot::channel();
        let handle = start_with_port(
            0,
            Some(TlsConfig {
                cert: cert.certificate_pem.clone(),
                private_key: cert.private_key_pem.clone(),
            }),
            ClientInfo {
                alias: "Peer".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                token: cert.fingerprint.clone(),
            },
            None,
            Some(ServerConfigV2 {
                chat_enabled: true,
                pin: None,
                verify_checksums: true,
                event_tx: tx,
            }),
            WebConfig {
                mode: WebMode::Upload,
                ..WebConfig::default()
            },
            stop_rx,
        )
        .await
        .unwrap();
        Self {
            cert,
            store,
            handle,
            stop,
            task,
        }
    }
    fn client_to(&self, other: &Peer) -> LsHttpClientV2 {
        LsHttpClientV2::try_new(
            &self.cert.private_key_pem,
            &self.cert.certificate_pem,
            Some(other.cert.fingerprint.clone()),
            Some(std::time::Duration::from_secs(10)),
        )
        .unwrap()
    }
    fn message(&self, text: &str) -> ChatMessageRequest {
        ChatMessageRequest {
            message_id: uuid::Uuid::new_v4().to_string(),
            info: RegisterDtoV2 {
                alias: "Sender".into(),
                version: "2.2".into(),
                device_model: None,
                device_type: None,
                fingerprint: self.cert.fingerprint.clone(),
                port: self.handle.port(),
                protocol: ProtocolType::Https,
                download: false,
            },
            text: text.into(),
            ttl_seconds: Some(300),
        }
    }
    async fn close(self) {
        let _ = self.stop.send(());
        self.handle.wait_stopped().await;
        self.task.abort();
    }
}

#[tokio::test]
async fn two_authenticated_peers_deliver_reply_deduplicate_and_preserve_deleted_receipts() {
    let a = Peer::start().await;
    let b = Peer::start().await;
    let ab = a.client_to(&b);
    let ba = b.client_to(&a);
    // Keep a file session open: chat must not consume its single-session slot.
    let transfer = ab
        .prepare_upload(
            ProtocolType::Https,
            "127.0.0.1",
            b.handle.port(),
            None,
            PrepareUploadRequestDtoV2 {
                info: a.message("").info,
                files: std::collections::HashMap::from([(
                    "file".into(),
                    FileDto {
                        id: "file".into(),
                        file_name: "test.txt".into(),
                        size: 4,
                        file_type: "text/plain".into(),
                        sha256: None,
                        preview: None,
                        metadata: None,
                    },
                )]),
            },
            None,
            tokio_util::sync::CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(transfer.status_code, 200);
    assert_eq!(
        ab.chat_info("127.0.0.1", b.handle.port())
            .await
            .unwrap()
            .version,
        1
    );
    let message = a.message("Hello\nZażółć 🦀");
    let receipt = ab
        .chat_send("127.0.0.1", b.handle.port(), message.clone())
        .await
        .unwrap();
    let duplicate = ab
        .chat_send("127.0.0.1", b.handle.port(), message.clone())
        .await
        .unwrap();
    assert_eq!(receipt.delivered_at_ms, duplicate.delivered_at_ms);
    assert!(duplicate.remaining_ttl_ms.unwrap() <= receipt.remaining_ttl_ms.unwrap());
    let rows = b
        .store
        .command(
            &json!({"op":"messages","peer":a.cert.fingerprint,"before":null,"search":"ZAŻÓŁĆ"})
                .to_string(),
        )
        .unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&rows)
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        1
    );
    ba.chat_send("127.0.0.1", a.handle.port(), b.message("Reply"))
        .await
        .unwrap();
    // A receipt is visible only to the certificate that sent that message.
    let outsider = generate_self_signed().unwrap();
    let client = LsHttpClientV2::try_new(
        &outsider.private_key_pem,
        &outsider.certificate_pem,
        Some(b.cert.fingerprint.clone()),
        None,
    )
    .unwrap();
    assert!(
        client
            .chat_status("127.0.0.1", b.handle.port(), &message.message_id)
            .await
            .unwrap()
            .is_none()
    );
    let mut spoofed = a.message("spoofed");
    spoofed.info.fingerprint = b.cert.fingerprint.clone();
    assert!(
        ab.chat_send("127.0.0.1", b.handle.port(), spoofed)
            .await
            .is_err()
    );
    let mut invalid = a.message("invalid");
    invalid.ttl_seconds = Some(1);
    assert!(
        ab.chat_send("127.0.0.1", b.handle.port(), invalid)
            .await
            .is_err()
    );
    let mut large = a.message("large");
    large.text = "x".repeat(65537);
    assert!(
        ab.chat_send("127.0.0.1", b.handle.port(), large)
            .await
            .is_err()
    );
    assert!(
        LsHttpClientV2::try_new_without_cert()
            .unwrap()
            .chat_info("127.0.0.1", b.handle.port())
            .await
            .is_err()
    );
    b.store
        .command(
            &json!({"op":"delete","peer":a.cert.fingerprint,"id":message.message_id}).to_string(),
        )
        .unwrap();
    assert_eq!(
        ab.chat_send("127.0.0.1", b.handle.port(), message)
            .await
            .unwrap()
            .status,
        "deleted"
    );
    a.close().await;
    b.close().await;
}

#[test]
fn restart_pagination_and_secure_delete() {
    let file = std::env::temp_dir().join(format!("localsend-chat-{}.sqlite", uuid::Uuid::new_v4()));
    let now = now_ms();
    {
        let store = ChatStore::open(file.to_str().unwrap()).unwrap();
        for index in 0..75 {
            store.command(&json!({"op":"create","peer":"A","alias":"Alice","id":uuid::Uuid::new_v4().to_string(),"text":format!("message {index}"),"ttl":null}).to_string()).unwrap();
        }
        let command = json!({"op":"receive","peer":"A","alias":"Alice","id":uuid::Uuid::new_v4().to_string(),"text":"unique-sensitive-body-to-scrub","ttl":300,"approved":true});
        // A deadline already elapsed when the process next opens the database.
        store
            .command_at_for_test(&command.to_string(), now - 300001)
            .unwrap();
    }
    {
        let store = ChatStore::open(file.to_str().unwrap()).unwrap();
        let first: serde_json::Value = serde_json::from_str(
            &store
                .command(&json!({"op":"messages","peer":"A","before":null,"search":""}).to_string())
                .unwrap(),
        )
        .unwrap();
        assert_eq!(first.as_array().unwrap().len(), 50);
        let cursor = first.as_array().unwrap().last().unwrap()["seq"]
            .as_i64()
            .unwrap();
        let second: serde_json::Value = serde_json::from_str(
            &store
                .command(
                    &json!({"op":"messages","peer":"A","before":cursor,"search":""}).to_string(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(second.as_array().unwrap().len(), 25);
    }
    let bytes = std::fs::read(&file).unwrap();
    assert!(
        !bytes
            .windows(b"unique-sensitive-body-to-scrub".len())
            .any(|bytes| bytes == b"unique-sensitive-body-to-scrub")
    );
    std::fs::remove_file(file).unwrap();
}
