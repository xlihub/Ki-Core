use serde::{Deserialize, Serialize};
use std::{collections::HashMap, fmt};

/// SDK Bearer authentication uses only the existing provider API key.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GatewayAuth {
    #[default]
    Bearer,
    None,
}

/// Default uses reqwest's configured proxy discovery; direct disables proxies.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GatewayProxy {
    #[default]
    Default,
    Direct,
}

/// Public header metadata. Sensitive values are written through header_credentials.
#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GatewayHeader {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(default)]
    pub sensitive: bool,
    /// Read-only credential presence; ignored on input.
    #[serde(default)]
    pub configured: bool,
}

impl fmt::Debug for GatewayHeader {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GatewayHeader")
            .field("sensitive", &self.sensitive)
            .field("configured", &self.configured)
            .finish_non_exhaustive()
    }
}

/// Optional settings for an existing custom OpenAI Chat Completions connection.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ProviderGateway {
    pub auth: GatewayAuth,
    pub headers: Vec<GatewayHeader>,
    pub include_stream_options: Option<bool>,
    pub proxy: GatewayProxy,
    /// Milliseconds, 1..=300000; absent means 10000.
    pub connect_timeout_ms: Option<u64>,
    /// Milliseconds per network read, 1..=3600000; absent means 30000.
    pub read_timeout_ms: Option<u64>,
    /// Milliseconds per SDK HTTP attempt, 1..=3600000; absent means no total limit.
    pub request_timeout_ms: Option<u64>,
}

/// Credential writes are explicit; omission preserves the encrypted value.
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum HeaderCredentialUpdate {
    Keep,
    Replace { value: String },
    Clear,
}
impl fmt::Debug for HeaderCredentialUpdate {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Keep => "Keep",
            Self::Replace { .. } => "Replace([redacted])",
            Self::Clear => "Clear",
        })
    }
}

/// Keys are case-insensitive header names. Never returned by read endpoints.
pub type HeaderCredentialUpdates = HashMap<String, HeaderCredentialUpdate>;
