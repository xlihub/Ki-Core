use std::{fmt, sync::Arc, time::Duration};

use aion_config::{
    compat::OpenAiApiMode,
    config::{Config, ProviderType},
};
use aion_providers::{
    LlmProvider,
    openai::{OpenAIAuth, OpenAIConfigError, OpenAIOptions, OpenAIProvider},
};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Serializable authentication policy; credentials are resolved separately.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GatewayAuth {
    #[default]
    Bearer,
    None,
}

/// Optional Chat Completions connection data. This is not a protocol selector.
/// Header values must be resolved from credential storage before construction.
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct GatewayConfig {
    pub auth: GatewayAuth,
    pub headers: Vec<(String, String)>,
    pub include_stream_options: Option<bool>,
    pub connect_timeout_ms: Option<u64>,
    pub read_timeout_ms: Option<u64>,
    pub request_timeout_ms: Option<u64>,
}

impl fmt::Debug for GatewayConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GatewayConfig")
            .field("auth", &self.auth)
            .field("header_count", &self.headers.len())
            .field("include_stream_options", &self.include_stream_options)
            .field("connect_timeout_ms", &self.connect_timeout_ms)
            .field("read_timeout_ms", &self.read_timeout_ms)
            .field("request_timeout_ms", &self.request_timeout_ms)
            .finish()
    }
}

/// Construction failures contain no URL, request body or credentials.
#[derive(Debug, Error)]
pub enum GatewayCreationError {
    #[error("Gateway options require the openai provider family")]
    UnsupportedProvider,
    #[error("Gateway options require Chat Completions, not Responses mode")]
    UnsupportedApiMode,
    #[error("Gateway timeout must be greater than zero: {field}")]
    InvalidTimeout { field: &'static str },
    #[error("Failed to build gateway HTTP client")]
    HttpClient,
    #[error(transparent)]
    Sdk(#[from] OpenAIConfigError),
}

/// Shared provider entry for chat, new/resumed sessions and health probes.
/// The SDK owns all message projection, SSE parsing and stream event handling.
pub fn create_provider(
    config: &Config,
    gateway: Option<&GatewayConfig>,
) -> Result<Arc<dyn LlmProvider>, GatewayCreationError> {
    let Some(gateway) = gateway else {
        tracing::info!(gateway = false, "Creating Core model provider");
        return Ok(aion_providers::create_provider(config));
    };
    if config.provider != ProviderType::OpenAI {
        return Err(GatewayCreationError::UnsupportedProvider);
    }
    if config.compat.openai_api_mode() != OpenAiApiMode::ChatCompletions {
        return Err(GatewayCreationError::UnsupportedApiMode);
    }
    for (field, value) in [
        ("connect_timeout_ms", gateway.connect_timeout_ms),
        ("read_timeout_ms", gateway.read_timeout_ms),
        ("request_timeout_ms", gateway.request_timeout_ms),
    ] {
        if value == Some(0) {
            return Err(GatewayCreationError::InvalidTimeout { field });
        }
    }
    let mut client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .connect_timeout(Duration::from_millis(gateway.connect_timeout_ms.unwrap_or(10_000)))
        .read_timeout(Duration::from_millis(gateway.read_timeout_ms.unwrap_or(30_000)));
    if let Some(timeout) = gateway.request_timeout_ms {
        client = client.timeout(Duration::from_millis(timeout));
    }
    let client = client.build().map_err(|_| GatewayCreationError::HttpClient)?;
    let mut compat = config.compat.clone();
    if let Some(include) = gateway.include_stream_options {
        compat.transport.include_stream_options = Some(include);
    }
    let provider = OpenAIProvider::with_options(
        Some(&config.api_key),
        &config.base_url,
        compat,
        OpenAIOptions {
            auth: match gateway.auth {
                GatewayAuth::Bearer => OpenAIAuth::Bearer,
                GatewayAuth::None => OpenAIAuth::None,
            },
            headers: gateway.headers.clone(),
            client: Some(client),
        },
    )?;
    tracing::info!(gateway = true, "Creating Core model provider");
    Ok(Arc::new(provider))
}
