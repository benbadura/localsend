use super::common::error::AppError;
use super::common::response::{BoxedBody, JsonResponse};
use super::v2::ServerEventV2;
use super::{AppState, RequestClientInfo};
use crate::http::chat::{
    ChatCapabilities, ChatMessageRequest, ChatReply, MAX_MESSAGE_BYTES, TTL_SECONDS,
};
use http_body_util::BodyExt;
use hyper::{body::Incoming, Request, Response, StatusCode};
use tokio::sync::oneshot;
use uuid::Uuid;

pub(crate) async fn handle(
    req: Request<Incoming>,
    state: AppState,
    peer: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = state
        .v2
        .as_ref()
        .filter(|v2| v2.chat_enabled)
        .ok_or(AppError::Status(StatusCode::NOT_FOUND))?;
    let fingerprint = peer
        .cert_fingerprint()
        .ok_or(AppError::Status(StatusCode::FORBIDDEN))?;
    let permit = v2
        .chat_requests
        .clone()
        .try_acquire_owned()
        .map_err(|_| AppError::Status(StatusCode::TOO_MANY_REQUESTS))?;
    let path = req.uri().path().to_owned();
    if req.method() == hyper::Method::GET && path == "/api/localsend/chat/v1/info" {
        return Ok(JsonResponse {
            status: StatusCode::OK,
            body: ChatCapabilities {
                version: 1,
                max_message_bytes: MAX_MESSAGE_BYTES as u32,
                ttl_seconds: TTL_SECONDS.to_vec(),
            },
        }
        .into_response());
    }
    let request_id = Uuid::new_v4().to_string();
    let (reply_tx, reply_rx) = oneshot::channel();
    let event = if req.method() == hyper::Method::POST && path == "/api/localsend/chat/v1/messages"
    {
        // JSON escaping can expand text sixfold. Bound streamed bodies too.
        let mut body = req.into_body();
        let mut bytes = Vec::new();
        while let Some(frame) = body.frame().await {
            if let Ok(data) = frame?.into_data() {
                if bytes.len() + data.len() > 512 * 1024 {
                    return Err(AppError::Status(StatusCode::PAYLOAD_TOO_LARGE));
                }
                bytes.extend_from_slice(&data);
            }
        }
        let message: ChatMessageRequest = serde_json::from_slice(&bytes)
            .map_err(|_| AppError::BadRequest("Invalid chat request".into()))?;
        if !message.validate() {
            return Err(AppError::BadRequest("Invalid message or expiry".into()));
        }
        if message.info.fingerprint.to_ascii_uppercase() != fingerprint {
            return Err(AppError::Status(StatusCode::FORBIDDEN));
        }
        ServerEventV2::ChatMessage {
            request_id: request_id.clone(),
            ip: peer.ip,
            fingerprint,
            message,
            reply_tx,
        }
    } else if req.method() == hyper::Method::GET {
        let id = path
            .strip_prefix("/api/localsend/chat/v1/messages/")
            .filter(|id| Uuid::parse_str(id).is_ok())
            .ok_or(AppError::Status(StatusCode::NOT_FOUND))?;
        ServerEventV2::ChatStatus {
            request_id: request_id.clone(),
            fingerprint,
            message_id: id.to_owned(),
            reply_tx,
        }
    } else {
        return Err(AppError::Status(StatusCode::NOT_FOUND));
    };
    v2.event_tx
        .try_send(event)
        .map_err(|_| AppError::Status(StatusCode::SERVICE_UNAVAILABLE))?;
    let _guard = PendingRequest {
        id: request_id,
        tx: v2.event_tx.clone(),
        _permit: permit,
    };
    let reply: ChatReply = tokio::time::timeout(std::time::Duration::from_secs(120), reply_rx)
        .await
        .map_err(|_| AppError::Status(StatusCode::REQUEST_TIMEOUT))?
        .map_err(|_| AppError::Status(StatusCode::SERVICE_UNAVAILABLE))?;
    let status = StatusCode::from_u16(reply.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    match reply.receipt {
        Some(receipt) if status.is_success() => Ok(JsonResponse {
            status,
            body: receipt,
        }
        .into_response()),
        _ => Err(AppError::Status(status)),
    }
}

struct PendingRequest {
    id: String,
    tx: tokio::sync::mpsc::Sender<ServerEventV2>,
    _permit: tokio::sync::OwnedSemaphorePermit,
}
impl Drop for PendingRequest {
    fn drop(&mut self) {
        let _ = self.tx.try_send(ServerEventV2::ChatRequestEnded {
            request_id: self.id.clone(),
        });
    }
}
