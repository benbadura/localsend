//! Fork-specific, certificate-authenticated LAN chat protocol.
use crate::http::dto_v2::RegisterDtoV2;
use serde::{Deserialize, Serialize};

pub const MAX_MESSAGE_BYTES: usize = 64 * 1024;
pub const TTL_SECONDS: [u32; 4] = [300, 3600, 86400, 604800];

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessageRequest {
    pub message_id: String,
    pub info: RegisterDtoV2,
    pub text: String,
    pub ttl_seconds: Option<u32>,
}

impl std::fmt::Debug for ChatMessageRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ChatMessageRequest")
            .field("message_id", &self.message_id)
            .field("text", &"<redacted>")
            .field("ttl_seconds", &self.ttl_seconds)
            .finish()
    }
}

impl ChatMessageRequest {
    pub fn validate(&self) -> bool {
        uuid::Uuid::parse_str(&self.message_id).is_ok_and(|id| id.get_version_num() == 4)
            && !self.text.trim().is_empty()
            && self.text.len() <= MAX_MESSAGE_BYTES
            && self
                .ttl_seconds
                .is_none_or(|ttl| TTL_SECONDS.contains(&ttl))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatReceipt {
    pub message_id: String,
    pub delivered_at_ms: i64,
    pub remaining_ttl_ms: Option<i64>,
    /// delivered, expired, or deleted. A receipt never contains message text.
    pub status: String,
}

#[derive(Debug)]
pub struct ChatReply {
    pub status: u16,
    pub receipt: Option<ChatReceipt>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatCapabilities {
    pub version: u32,
    pub max_message_bytes: u32,
    pub ttl_seconds: Vec<u32>,
}
