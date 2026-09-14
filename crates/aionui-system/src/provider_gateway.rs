//! Persistence and validation of optional OpenAI connection settings.
use crate::error::SystemError;
use aionui_api_types::{GatewayAuth, HeaderCredentialUpdate, HeaderCredentialUpdates, ProviderGateway};
use aionui_common::{decrypt_string, encrypt_string};
use std::collections::{HashMap, HashSet};

type Credentials = HashMap<String, String>;

pub(crate) fn read_gateway(raw: Option<&str>) -> Result<Option<ProviderGateway>, SystemError> {
    raw.map(serde_json::from_str)
        .transpose()
        .map_err(|_| SystemError::Internal("Invalid stored gateway configuration".into()))
}

fn read_credentials(raw: Option<&str>, key: &[u8]) -> Result<Credentials, SystemError> {
    raw.map(|raw| {
        let plaintext = decrypt_string(raw, key)
            .map_err(|_| SystemError::Internal("Gateway credentials could not be decrypted".into()))?;
        serde_json::from_str(&plaintext).map_err(|_| SystemError::Internal("Invalid stored gateway credentials".into()))
    })
    .transpose()
    .map(Option::unwrap_or_default)
}

/// Apply one update atomically before any repository mutation.
pub(crate) fn prepare(
    gateway: Option<&ProviderGateway>,
    previous: Option<&str>,
    previous_gateway: Option<&ProviderGateway>,
    updates: &HeaderCredentialUpdates,
    key: &[u8],
) -> Result<Option<String>, SystemError> {
    let mut credentials = read_credentials(previous, key)?;
    let Some(gateway) = gateway else {
        if !updates.is_empty() {
            return Err(bad("header_credentials requires gateway configuration"));
        }
        return Ok(None);
    };
    let mut names = HashSet::new();
    for header in &gateway.headers {
        let name = header.name.to_ascii_lowercase();
        if !names.insert(name.clone()) {
            return Err(bad("Duplicate gateway header (case-insensitive)"));
        }
        reqwest::header::HeaderName::from_bytes(header.name.as_bytes())
            .map_err(|_| bad("Invalid gateway header name"))?;
        if matches!(
            name.as_str(),
            "content-type"
                | "content-length"
                | "transfer-encoding"
                | "host"
                | "connection"
                | "proxy-authorization"
                | "proxy-authenticate"
                | "trailer"
                | "upgrade"
                | "te"
        ) {
            return Err(bad("Gateway header is controlled by the HTTP transport"));
        }
        if name == "authorization" && gateway.auth == GatewayAuth::Bearer {
            return Err(bad("Authorization header conflicts with Bearer authentication"));
        }
        if header.sensitive && header.value.is_some() {
            return Err(bad("Sensitive headers must use header_credentials"));
        }
        if !header.sensitive {
            let value = header
                .value
                .as_deref()
                .ok_or_else(|| bad("Ordinary gateway header requires a value"))?;
            validate_value(value)?;
        }
    }
    let mut update_names = HashSet::new();
    for (name, update) in updates {
        let name = name.to_ascii_lowercase();
        if !update_names.insert(name.clone()) {
            return Err(bad("Duplicate credential update (case-insensitive)"));
        }
        if !gateway
            .headers
            .iter()
            .any(|h| h.sensitive && h.name.eq_ignore_ascii_case(&name))
        {
            return Err(bad("Credential update has no matching sensitive header"));
        }
        match update {
            HeaderCredentialUpdate::Keep => {
                if !credentials.contains_key(&name) {
                    return Err(bad("Cannot keep a missing gateway credential"));
                }
            }
            HeaderCredentialUpdate::Replace { value } => {
                validate_value(value)?;
                if value.trim().is_empty() || value.contains("***") || value.contains('•') || value == "[REDACTED]" {
                    return Err(bad("Gateway credential must be non-empty and cannot be a mask"));
                }
                credentials.insert(name, value.clone());
            }
            HeaderCredentialUpdate::Clear => {
                credentials.remove(&name);
            }
        }
    }
    credentials.retain(|name, _| {
        gateway
            .headers
            .iter()
            .any(|h| h.sensitive && h.name.eq_ignore_ascii_case(name))
    });
    // A newly declared secret needs a value; explicit clear remains a valid unconfigured state.
    for header in gateway.headers.iter().filter(|h| h.sensitive) {
        let name = header.name.to_ascii_lowercase();
        let cleared = updates
            .iter()
            .any(|(n, u)| n.eq_ignore_ascii_case(&name) && matches!(u, HeaderCredentialUpdate::Clear));
        let already_declared = previous_gateway.is_some_and(|old| {
            old.headers
                .iter()
                .any(|h| h.sensitive && h.name.eq_ignore_ascii_case(&name))
        });
        if !credentials.contains_key(&name) && !already_declared && !cleared {
            return Err(bad("Missing gateway credential"));
        }
    }
    let plaintext = serde_json::to_string(&credentials)
        .map_err(|_| SystemError::Internal("Could not encode gateway credentials".into()))?;
    encrypt_string(&plaintext, key)
        .map(Some)
        .map_err(|_| SystemError::Internal("Gateway credential encryption failed".into()))
}

pub(crate) fn public_gateway(
    raw: Option<&str>,
    encrypted: Option<&str>,
    key: &[u8],
) -> Result<Option<ProviderGateway>, SystemError> {
    let mut gateway = read_gateway(raw)?;
    let credentials = read_credentials(encrypted, key)?;
    if let Some(gateway) = &mut gateway {
        for header in &mut gateway.headers {
            header.configured = if header.sensitive {
                credentials.contains_key(&header.name.to_ascii_lowercase())
            } else {
                header.value.is_some()
            };
            if header.sensitive {
                header.value = None;
            }
        }
    }
    Ok(gateway)
}

pub(crate) fn validate_policy(gateway: &ProviderGateway, platform: &str, api_key: &str) -> Result<(), SystemError> {
    if !matches!(platform, "openai" | "custom") {
        return Err(bad("Gateway options require a custom OpenAI connection"));
    }
    if gateway.auth == GatewayAuth::Bearer {
        if api_key.trim().is_empty() {
            return Err(bad("Bearer authentication requires apiKey"));
        }
        validate_value(api_key)?;
    }
    if gateway.headers.len() > 64 {
        return Err(bad("At most 64 gateway headers are supported"));
    }
    for (value, max) in [
        (gateway.connect_timeout_ms, 300_000),
        (gateway.read_timeout_ms, 3_600_000),
        (gateway.request_timeout_ms, 3_600_000),
    ] {
        if value.is_some_and(|v| v == 0 || v > max) {
            return Err(bad("Gateway timeout is outside the allowed millisecond range"));
        }
    }
    Ok(())
}

fn validate_value(value: &str) -> Result<(), SystemError> {
    if value.len() > 8192 || value.bytes().any(|b| b < 32 || b == 127) {
        return Err(bad("Invalid gateway header value"));
    }
    reqwest::header::HeaderValue::from_str(value).map_err(|_| bad("Invalid gateway header value"))?;
    Ok(())
}
fn bad(message: &str) -> SystemError {
    SystemError::BadRequest(message.into())
}
