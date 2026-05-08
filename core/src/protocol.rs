// Jupyter messaging protocol v5.4
// Reference: https://jupyter-client.readthedocs.io/en/stable/messaging.html

use anyhow::{anyhow, Result};
use bytes::Bytes;
use chrono::Utc;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;
use uuid::Uuid;

const PROTOCOL_VERSION: &str = "5.4";
const DELIMITER: &[u8] = b"<IDS|MSG>";

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Header {
    pub msg_id: String,
    pub session: String,
    pub username: String,
    pub date: String,
    pub msg_type: String,
    pub version: String,
}

impl Header {
    pub fn new(msg_type: impl Into<String>, session: impl Into<String>) -> Self {
        Self {
            msg_id: Uuid::new_v4().to_string(),
            session: session.into(),
            username: "notebook_style".to_string(),
            date: Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Micros, true),
            msg_type: msg_type.into(),
            version: PROTOCOL_VERSION.to_string(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Message {
    /// ZMQ identity prefix frames (DEALER routing). Empty for outgoing on DEALER, present on incoming.
    pub identities: Vec<Bytes>,
    pub header: Header,
    pub parent_header: Value, // empty object {} when no parent
    pub metadata: Value,
    pub content: Value,
    pub buffers: Vec<Bytes>,
}

impl Message {
    pub fn new(msg_type: impl Into<String>, session: impl Into<String>, content: Value) -> Self {
        Self {
            identities: Vec::new(),
            header: Header::new(msg_type, session),
            parent_header: json!({}),
            metadata: json!({}),
            content,
            buffers: Vec::new(),
        }
    }

    /// Serialize message to ZMQ frames (with HMAC signing).
    pub fn to_frames(&self, key: &[u8]) -> Result<Vec<Bytes>> {
        let header = serde_json::to_vec(&self.header)?;
        let parent = serde_json::to_vec(&self.parent_header)?;
        let meta = serde_json::to_vec(&self.metadata)?;
        let content = serde_json::to_vec(&self.content)?;

        let signature = if key.is_empty() {
            String::new()
        } else {
            let mut mac =
                HmacSha256::new_from_slice(key).map_err(|e| anyhow!("hmac key error: {e}"))?;
            mac.update(&header);
            mac.update(&parent);
            mac.update(&meta);
            mac.update(&content);
            hex::encode(mac.finalize().into_bytes())
        };

        let mut frames: Vec<Bytes> =
            Vec::with_capacity(7 + self.identities.len() + self.buffers.len());
        for id in &self.identities {
            frames.push(id.clone());
        }
        frames.push(Bytes::from_static(DELIMITER));
        frames.push(Bytes::from(signature.into_bytes()));
        frames.push(Bytes::from(header));
        frames.push(Bytes::from(parent));
        frames.push(Bytes::from(meta));
        frames.push(Bytes::from(content));
        for buf in &self.buffers {
            frames.push(buf.clone());
        }
        Ok(frames)
    }

    /// Deserialize from ZMQ frames, verifying HMAC.
    pub fn from_frames(frames: Vec<Bytes>, key: &[u8]) -> Result<Self> {
        // Split on <IDS|MSG>
        let delim_idx = frames
            .iter()
            .position(|f| f.as_ref() == DELIMITER)
            .ok_or_else(|| anyhow!("missing <IDS|MSG> delimiter"))?;

        let identities: Vec<Bytes> = frames[..delim_idx].to_vec();
        let rest = &frames[delim_idx + 1..];
        if rest.len() < 5 {
            return Err(anyhow!(
                "not enough frames after delimiter ({})",
                rest.len()
            ));
        }
        let signature = &rest[0];
        let header_raw = &rest[1];
        let parent_raw = &rest[2];
        let meta_raw = &rest[3];
        let content_raw = &rest[4];
        let buffers: Vec<Bytes> = rest[5..].to_vec();

        // Verify HMAC if key set
        if !key.is_empty() {
            let mut mac =
                HmacSha256::new_from_slice(key).map_err(|e| anyhow!("hmac key error: {e}"))?;
            mac.update(header_raw);
            mac.update(parent_raw);
            mac.update(meta_raw);
            mac.update(content_raw);
            let expected = hex::encode(mac.finalize().into_bytes());
            let got = std::str::from_utf8(signature).unwrap_or("");
            if expected != got {
                return Err(anyhow!(
                    "HMAC verification failed: expected {expected}, got {got}"
                ));
            }
        }

        let header: Header = serde_json::from_slice(header_raw)?;
        let parent_header: Value = serde_json::from_slice(parent_raw).unwrap_or_else(|_| json!({}));
        let metadata: Value = serde_json::from_slice(meta_raw).unwrap_or_else(|_| json!({}));
        let content: Value = serde_json::from_slice(content_raw).unwrap_or_else(|_| json!({}));

        Ok(Self {
            identities,
            header,
            parent_header,
            metadata,
            content,
            buffers,
        })
    }
}

// ----- Common message content builders -----

pub fn execute_request(code: &str, silent: bool, store_history: bool) -> Value {
    json!({
        "code": code,
        "silent": silent,
        "store_history": store_history,
        "user_expressions": {},
        "allow_stdin": false,
        // false: subsequent queued requests still run even if one errors
        // (matches VSCode's per-cell run model where each cell is independent).
        "stop_on_error": false,
    })
}

pub fn kernel_info_request() -> Value {
    json!({})
}

pub fn interrupt_request() -> Value {
    json!({})
}

pub fn shutdown_request(restart: bool) -> Value {
    json!({ "restart": restart })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signing_roundtrip() {
        let key = b"deadbeefdeadbeef";
        let msg = Message::new(
            "execute_request",
            "sess",
            execute_request("1+1", false, true),
        );
        let frames = msg.to_frames(key).unwrap();
        // Add a fake routing id
        let mut with_id = vec![Bytes::from_static(b"identity")];
        with_id.extend(frames);
        let parsed = Message::from_frames(with_id, key).unwrap();
        assert_eq!(parsed.header.msg_type, "execute_request");
        assert_eq!(parsed.identities.len(), 1);
    }

    #[test]
    fn signing_rejects_tampering() {
        let key = b"deadbeefdeadbeef";
        let msg = Message::new(
            "execute_request",
            "sess",
            execute_request("1+1", false, true),
        );
        let mut frames = msg.to_frames(key).unwrap();
        // Tamper with content frame
        let last = frames.len() - 1;
        frames[last] = Bytes::from_static(b"{\"code\": \"evil\"}");
        let result = Message::from_frames(frames, key);
        assert!(result.is_err());
    }
}
