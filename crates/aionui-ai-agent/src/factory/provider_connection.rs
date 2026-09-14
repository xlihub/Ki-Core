//! Resolve one persisted connection for both Agent construction and health probes.
use super::aionrs::{map_aionrs_provider, resolve_aionrs_url_and_compat_with_mode, resolve_model_compat_overrides};
use crate::manager::aionrs::providers::GatewayConfig;
use crate::{error::AgentError, types::AionrsCompatOverrides};
use aion_config::compat::OpenAiApiMode;
use aionui_api_types::ProviderGateway;
use aionui_db::models::Provider;
use std::collections::HashMap;

pub(crate) struct ResolvedConnection {
    pub provider: String,
    pub api_key: String,
    pub base_url: Option<String>,
    pub compat: AionrsCompatOverrides,
}

pub(crate) fn resolve(row: &Provider, model: &str, key: &[u8; 32]) -> Result<ResolvedConnection, AgentError> {
    let api_key = aionui_common::decrypt_string(&row.api_key_encrypted, key)
        .map_err(|_| AgentError::bad_request("Provider API key could not be decrypted"))?;
    let gateway: Option<ProviderGateway> = row
        .gateway
        .as_deref()
        .map(serde_json::from_str)
        .transpose()
        .map_err(|_| AgentError::bad_request("Invalid stored gateway configuration"))?;
    let manual = row.model_mode == "manual";
    let provider = if manual {
        let models: Vec<String> =
            serde_json::from_str(&row.models).map_err(|_| AgentError::bad_request("Invalid stored models"))?;
        if !models.iter().any(|id| id == model) {
            return Err(AgentError::bad_request(
                "Model is not configured on this manual connection",
            ));
        }
        if !matches!(row.platform.as_str(), "custom" | "openai") || !row.is_full_url {
            return Err(AgentError::bad_request("Invalid manual OpenAI connection"));
        }
        "openai".to_owned()
    } else {
        map_aionrs_provider(&row.platform, model, row.model_protocols.as_deref())?
    };
    let overrides = resolve_model_compat_overrides(model, &row.model_settings)?;
    if (manual || gateway.is_some()) && overrides.openai_api_mode == Some(OpenAiApiMode::Responses) {
        return Err(AgentError::bad_request(
            "Gateway and manual connections require Chat Completions",
        ));
    }
    let (base_url, mut compat) = if manual || (gateway.is_some() && row.is_full_url) {
        let compat = AionrsCompatOverrides {
            api_path: Some(String::new()),
            openai_api_mode: Some(OpenAiApiMode::ChatCompletions),
            ..Default::default()
        };
        (Some(row.base_url.clone()), compat)
    } else {
        resolve_aionrs_url_and_compat_with_mode(
            &row.platform,
            &row.base_url,
            &provider,
            model,
            row.is_full_url,
            if gateway.is_some() {
                Some(OpenAiApiMode::ChatCompletions)
            } else {
                overrides.openai_api_mode
            },
        )
    };
    compat.image_input = overrides.image_input;
    if let Some(gateway) = gateway {
        let credentials: HashMap<String, String> = match row.header_credentials_encrypted.as_deref() {
            Some(ciphertext) => {
                let plaintext = aionui_common::decrypt_string(ciphertext, key)
                    .map_err(|_| AgentError::bad_request("Gateway credentials could not be decrypted"))?;
                serde_json::from_str(&plaintext)
                    .map_err(|_| AgentError::bad_request("Invalid stored gateway credentials"))?
            }
            None => HashMap::new(),
        };
        let headers = gateway
            .headers
            .iter()
            .map(|header| {
                let value = if header.sensitive {
                    credentials.get(&header.name.to_ascii_lowercase())
                } else {
                    header.value.as_ref()
                };
                let value = value
                    .filter(|v| !header.sensitive || !v.trim().is_empty())
                    .ok_or_else(|| AgentError::bad_request("Missing gateway credential or header value"))?;
                Ok((header.name.clone(), value.clone()))
            })
            .collect::<Result<_, AgentError>>()?;
        compat.gateway = Some(GatewayConfig {
            auth: gateway.auth,
            headers,
            include_stream_options: gateway.include_stream_options,
            proxy: gateway.proxy,
            connect_timeout_ms: gateway.connect_timeout_ms,
            read_timeout_ms: gateway.read_timeout_ms,
            request_timeout_ms: gateway.request_timeout_ms,
        });
    }
    Ok(ResolvedConnection {
        provider,
        api_key,
        base_url,
        compat,
    })
}
