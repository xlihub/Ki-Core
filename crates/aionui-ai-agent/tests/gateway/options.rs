use aionui_ai_agent::manager::aionrs::providers::{GatewayAuth, GatewayConfig, create_provider};
use serde_json::json;

use super::support::*;

#[test]
fn gateway_configuration_rejects_conflicting_and_invalid_credentials_without_echoing_them() {
    use aion_providers::openai::OpenAIConfigError;
    use aionui_ai_agent::manager::aionrs::providers::GatewayCreationError;
    let mut cfg = config("http://127.0.0.1:1/chat/completions");
    let cases = [
        (
            vec![("Authorization", "synthetic-secret")],
            OpenAIConfigError::AuthorizationConflict,
        ),
        (
            vec![("X-Key", "first"), ("x-key", "synthetic-secret")],
            OpenAIConfigError::DuplicateHeader { index: 1 },
        ),
        (
            vec![("Host", "synthetic-secret")],
            OpenAIConfigError::ReservedHeader { index: 0 },
        ),
        (
            vec![("X-Key", "synthetic-secret\r\nInjected: yes")],
            OpenAIConfigError::InvalidHeaderValue { index: 0 },
        ),
    ];
    for (headers, expected) in cases {
        let gateway = GatewayConfig {
            headers: headers.into_iter().map(|(k, v)| (k.into(), v.into())).collect(),
            ..Default::default()
        };
        let error = create_provider(&cfg, Some(&gateway)).err().unwrap();
        assert!(!error.to_string().contains("synthetic-secret"));
        assert!(matches!(error, GatewayCreationError::Sdk(actual) if actual == expected));
    }
    cfg.api_key.clear();
    assert!(matches!(
        create_provider(&cfg, Some(&GatewayConfig::default())),
        Err(GatewayCreationError::Sdk(OpenAIConfigError::MissingApiKey))
    ));
    let gateway = GatewayConfig {
        read_timeout_ms: Some(0),
        ..Default::default()
    };
    assert!(matches!(
        create_provider(&cfg, Some(&gateway)),
        Err(GatewayCreationError::InvalidTimeout {
            field: "read_timeout_ms"
        })
    ));
}

#[tokio::test]
async fn configured_read_timeout_stops_a_partial_stream_without_replay() {
    use aion_types::llm::LlmEvent;
    use std::time::Duration;
    let head = b"data:{\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n".to_vec();
    let mut server = server(vec![(head, finished()), (vec![], vec![])], 4096).await;
    let gateway = GatewayConfig {
        read_timeout_ms: Some(100),
        ..Default::default()
    };
    let provider = create_provider(&config(&server.url), Some(&gateway)).unwrap();
    let mut rx = provider.stream(&request()).await.unwrap();
    assert!(matches!(event(&mut rx).await, LlmEvent::TextDelta(text) if text == "partial"));
    assert!(
        matches!(event(&mut rx).await, LlmEvent::Error(message) if message.contains("error decoding response body"))
    );
    assert!(rx.recv().await.is_none());
    server.requests.recv().await.unwrap();
    tokio::time::timeout(Duration::from_secs(2), server.disconnected.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(
        tokio::time::timeout(Duration::from_millis(1500), server.requests.recv())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn serializable_gateway_options_send_custom_auth_to_the_full_endpoint() {
    let mut wire = b"data:{\"choices\":[{\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\n".to_vec();
    wire.extend(b"data:[DONE]\n\n");
    let mut server = server(vec![(wire, vec![])], 1).await;
    let mut cfg = config(&format!("{}?tenant=synthetic", server.url));
    cfg.api_key.clear();
    let gateway: GatewayConfig = serde_json::from_value(json!({
        "auth": "none",
        "headers": [["X-Synthetic-Key", "synthetic-secret"]],
        "include_stream_options": false
    }))
    .unwrap();
    assert_eq!(gateway.auth, GatewayAuth::None);
    assert!(!format!("{gateway:?}").contains("synthetic-secret"));
    let provider = create_provider(&cfg, Some(&gateway)).unwrap();
    let mut rx = provider.stream(&request()).await.unwrap();
    assert!(matches!(event(&mut rx).await, aion_types::llm::LlmEvent::TextDelta(text) if text == "OK"));
    let headers = server.headers.recv().await.unwrap().to_ascii_lowercase();
    assert!(headers.starts_with("post /chat/completions?tenant=synthetic http/1.1"));
    assert!(headers.contains("x-synthetic-key: synthetic-secret\r\n"));
    assert!(!headers.contains("authorization:"));
    let body = server.requests.recv().await.unwrap();
    assert!(body.get("stream_options").is_none());
}
