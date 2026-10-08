//! Narrow FRB interface; all operations run off the Flutter UI isolate.
use crate::chat_store::ChatStore;
use localsend::http::client::{ClientError, LsHttpClientV2};
use serde_json::json;
use std::sync::Arc;

pub struct RsChatStore {
    inner: Arc<ChatStore>,
}

pub async fn open_chat_store(path: String) -> anyhow::Result<RsChatStore> {
    let inner = tokio::task::spawn_blocking(move || ChatStore::open(&path)).await??;
    Ok(RsChatStore {
        inner: Arc::new(inner),
    })
}
impl RsChatStore {
    pub async fn execute(&self, command: String) -> anyhow::Result<String> {
        let store = self.inner.clone();
        tokio::task::spawn_blocking(move || store.command(&command)).await?
    }
}

/// Returns either {ok:true,value:...} or {ok:false,status:HTTP code or null}.
/// Never returns remote error bodies, message text in errors, or private keys.
pub async fn chat_request(
    private_key: String,
    cert: String,
    fingerprint: String,
    host: String,
    port: u16,
    operation: String,
    payload: String,
) -> anyhow::Result<String> {
    let client = LsHttpClientV2::try_new(
        &private_key,
        &cert,
        Some(fingerprint),
        Some(std::time::Duration::from_secs(125)),
    )?;
    let result = match operation.as_str() {
        "info" => client.chat_info(&host, port).await.map(|v| json!(v)),
        "send" => client
            .chat_send(&host, port, serde_json::from_str(&payload)?)
            .await
            .map(|v| json!(v)),
        "status" => client
            .chat_status(&host, port, &payload)
            .await
            .map(|v| json!(v)),
        _ => anyhow::bail!("Unknown chat operation"),
    };
    Ok(match result {
        Ok(value) => json!({"ok":true,"value":value}),
        Err(ClientError::StatusCode(code)) => json!({"ok":false,"status":code.status}),
        Err(_) => json!({"ok":false,"status":null}),
    }
    .to_string())
}
